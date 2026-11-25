import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// SDK-nın fayllarının yeri: tətbiqin Application Support qovluğunda ayrıca qovluq.
/// Qovluq ehtiyat nüsxədən (iCloud / kompüter) çıxarılır ki, anonim ID başqa cihaza bərpa olunub
/// iki cihazda eyni olmasın.
enum Storage {
    static func directory(_ override: URL? = nil) -> URL? {
        let fm = FileManager.default
        guard var dir = override ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("az.smartbee.pixel", isDirectory: true) else { return nil }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
            return dir
        } catch {
            return nil
        }
    }

    /// Faylı atomik yazır. iOS-da cihaz ilk dəfə açılandan sonra oxuna bilən qoruma sinfi ilə
    /// (arxa fonda göndəriş işləsin deyə tam kilidli sinif seçilmir).
    static func write(_ data: Data, to file: URL) -> Bool {
        do {
            #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: file, options: [.atomic])
            #endif
            return true
        } catch {
            return false
        }
    }
}

/// Açar-dəyər yaddaşı: kiçik JSON faylı. Dəyərlər yaddaşda keşlənir, hər dəyişiklik dərhal yazılır.
final class FileStore: Store {
    private var values: [String: String] = [:]
    private let file: URL?

    init(directory: URL? = nil) {
        file = Storage.directory(directory)?.appendingPathComponent("store.json")
        if let file = file, let data = try? Data(contentsOf: file),
           let saved = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: String] {
            values = saved
        }
    }

    func get(_ key: String) -> String? { return values[key] }

    func put(_ key: String, _ value: String) {
        if values[key] == value { return }
        values[key] = value
        save()
    }

    func remove(_ key: String) {
        if values.removeValue(forKey: key) != nil { save() }
    }

    private func save() {
        guard let file = file, let data = try? JSONSerialization.data(withJSONObject: values, options: []) else { return }
        _ = Storage.write(data, to: file)
    }
}

/// Event növbəsi: yaddaşda saxlanır və fayla yazılır.
/// Fayl hər dəyişiklikdə yox, qısa fasilə ilə yazılır; qəfil çökmədə son bir neçə saniyənin eventləri itə bilər.
final class FileQueue: EventQueue {
    private var rows: [QueuedEvent] = []
    private var nextId: Int64 = 1
    private var dirty = false
    private var lastPersist = Date.distantPast
    private let file: URL?

    init(directory: URL? = nil) {
        file = Storage.directory(directory)?.appendingPathComponent("queue.json")
        load()
    }

    private func load() {
        guard let file = file, let data = try? Data(contentsOf: file),
              let list = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [[String: Any]] else { return }
        for item in list {
            guard let ctx = item["ctx"] as? String, let payload = item["payload"] as? String else { continue }
            rows.append(QueuedEvent(id: nextId, ctx: ctx, payload: payload))
            nextId += 1
        }
    }

    func add(ctx: String, payload: String) {
        rows.append(QueuedEvent(id: nextId, ctx: ctx, payload: payload))
        nextId += 1
        dirty = true
    }

    func peek(_ limit: Int) -> [QueuedEvent] { return Array(rows.prefix(max(limit, 0))) }

    func remove(_ ids: [Int64]) {
        if ids.isEmpty { return }
        let set = Set(ids)
        rows.removeAll { set.contains($0.id) }
        dirty = true
    }

    var count: Int { return rows.count }

    func trim(_ max: Int) {
        if rows.count > max, max >= 0 {
            rows.removeFirst(rows.count - max)
            dirty = true
        }
    }

    func clear() {
        if !rows.isEmpty {
            rows.removeAll()
            dirty = true
        }
    }

    /// Dəyişiklik varsa və son yazıdan ən azı 2 saniyə keçibsə fayla yazır.
    func persistSoon() {
        if dirty, Date().timeIntervalSince(lastPersist) >= 2 { persist() }
    }

    /// Dəyişiklik varsa dərhal fayla yazır (atomik).
    func persist() {
        guard dirty, let file = file else { return }
        let list: [[String: Any]] = rows.map { ["ctx": $0.ctx, "payload": $0.payload] }
        guard JSONSerialization.isValidJSONObject(list), let data = try? JSONSerialization.data(withJSONObject: list, options: []) else { return }
        // Disk dolu və ya əlçatmazdırsa növbə yaddaşda qalır, sonra yenidən cəhd edilir.
        if Storage.write(data, to: file) {
            dirty = false
            lastPersist = Date()
        }
    }
}

/// Yönləndirmələri izləmir: toplu yalnız konfiqdəki ünvana göndərilir.
final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// URLSession üzərində nəqliyyat. Yalnız HTTPS; sazlama rejimində lokal ünvanlara HTTP icazəlidir.
final class URLSessionTransport: Transport {
    static let maxConfigBytes = 256 * 1024

    private let debug: Bool
    private let session: URLSession

    init(debug: Bool) {
        self.debug = debug
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: RedirectBlocker(), delegateQueue: nil)
    }

    /// Yalnız HTTPS; sazlama rejimində lokal ünvanlara HTTP icazəlidir.
    static func allowed(_ address: String, debug: Bool) -> URL? {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), let host = url.host else { return nil }
        let local = host == "localhost" || host == "127.0.0.1"
        return scheme == "https" || (debug && local && scheme == "http") ? url : nil
    }

    private func request(_ address: String) -> URLRequest? {
        guard let url = URLSessionTransport.allowed(address, debug: debug) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("SmartBeePixel-iOS/" + sdkVersion, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Növbə axınında sinxron icra olunur (əsas axında heç vaxt çağırılmır).
    private func send(_ request: URLRequest) -> HttpResult {
        let done = DispatchSemaphore(value: 0)
        var result = HttpResult(status: -1)
        let task = session.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            guard error == nil, let http = response as? HTTPURLResponse else { return }
            var body: String?
            if http.statusCode == 200, let data = data, data.count <= URLSessionTransport.maxConfigBytes {
                body = String(data: data, encoding: .utf8)
            }
            let retryAfter = (http.allHeaderFields["Retry-After"] as? String).flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
            result = HttpResult(status: http.statusCode, body: body, etag: http.allHeaderFields["Etag"] as? String ?? http.allHeaderFields["ETag"] as? String, retryAfterSec: retryAfter)
        }
        task.resume()
        if done.wait(timeout: .now() + 35) == .timedOut {
            task.cancel()
            return HttpResult(status: -1)
        }
        return result
    }

    func post(url: String, json: String) -> HttpResult {
        guard var request = request(url) else { return HttpResult(status: 400) }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(json.utf8)
        return send(request)
    }

    func get(url: String, etag: String?) -> HttpResult {
        guard var request = request(url) else { return HttpResult(status: 400) }
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag = etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return send(request)
    }
}

final class AppleEnv: Env {
    private let lock = NSLock()
    private var snapshot: [String: Any]

    init(snapshot: [String: Any]) {
        self.snapshot = snapshot
    }

    /// UIKit-dən oxunan sahələri sonradan əlavə edir (SDK əsas axından kənarda başladılanda).
    func merge(_ extra: [String: Any]) {
        lock.lock()
        for (key, value) in extra { snapshot[key] = value }
        lock.unlock()
    }

    func now() -> Int64 { return Int64(Date().timeIntervalSince1970 * 1000) }
    func uuid() -> String { return UUID().uuidString.lowercased() }
    func log(_ message: String) { NSLog("[SmartBee] %@", message) }

    func deviceContext() -> [String: Any] {
        lock.lock()
        var ctx = snapshot
        lock.unlock()
        ctx["locale"] = Util.localeTag(Locale.current.identifier)
        ctx["tz"] = TimeZone.current.identifier
        return ctx
    }

    /// Dəyişməyən tətbiq və cihaz məlumatı; istənilən axında oxuna bilər.
    static func captureBase() -> [String: Any] {
        var ctx: [String: Any] = [:]
        let info = Bundle.main.infoDictionary ?? [:]
        var app: [String: Any] = ["id": Bundle.main.bundleIdentifier ?? "unknown"]
        if let version = info["CFBundleShortVersionString"] as? String { app["version"] = version }
        if let build = info["CFBundleVersion"] as? String { app["build"] = build }
        ctx["app"] = app

        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if os(iOS)
        let osName = "iOS"
        #elseif os(tvOS)
        let osName = "tvOS"
        #else
        let osName = "macOS"
        #endif
        ctx["os"] = ["name": osName, "version": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"]
        ctx["device"] = ["manufacturer": "Apple", "model": machine(), "type": "phone"]
        return ctx
    }

    /// UIKit-dən oxunan sahələr. Yalnız əsas axında çağırılmalıdır.
    static func captureUI() -> [String: Any] {
        var ctx: [String: Any] = [:]
        #if canImport(UIKit) && !os(watchOS)
        let device = UIDevice.current
        ctx["device"] = ["manufacturer": "Apple", "model": machine(), "type": device.userInterfaceIdiom == .pad ? "tablet" : "phone"]
        let bounds = UIScreen.main.nativeBounds
        ctx["screen"] = ["w": Int(bounds.width), "h": Int(bounds.height), "density": Double(UIScreen.main.scale)]
        // Satıcı identifikatoru; reklam razılığı yoxdursa Core onu göndərmir.
        if let idfv = device.identifierForVendor?.uuidString { ctx["ids"] = ["idfv": idfv] }
        #endif
        return ctx
    }

    private static func machine() -> String {
        var system = utsname()
        guard uname(&system) == 0 else { return "unknown" }
        return withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
    }
}
