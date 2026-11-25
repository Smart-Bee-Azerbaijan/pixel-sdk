import CryptoKit
import Foundation

let sdkVersion = "1.0.0"
let defaultEndpoint = "https://c.cdnsb.net"

// MARK: - Asılılıqlar (Apple tətbiqi Platform.swift-dədir; testlərdə saxta tətbiqlər işlədilir)

/// Kiçik açar-dəyər yaddaşı (identifikatorlar, razılıq, konfiq).
protocol Store: AnyObject {
    func get(_ key: String) -> String?
    func put(_ key: String, _ value: String)
    func remove(_ key: String)
}

struct QueuedEvent {
    let id: Int64
    let ctx: String
    let payload: String
}

/// Diskdə saxlanan event növbəsi. Sıra əlavə olunma sırasıdır.
protocol EventQueue: AnyObject {
    func add(ctx: String, payload: String)
    func peek(_ limit: Int) -> [QueuedEvent]
    func remove(_ ids: [Int64])
    var count: Int { get }
    /// Ən köhnə eventləri ataraq növbəni `max` ölçüsünə endirir.
    func trim(_ max: Int)
    func clear()
}

struct HttpResult {
    let status: Int
    var body: String?
    var etag: String?
    var retryAfterSec: Int64?

    init(status: Int, body: String? = nil, etag: String? = nil, retryAfterSec: Int64? = nil) {
        self.status = status
        self.body = body
        self.etag = etag
        self.retryAfterSec = retryAfterSec
    }

    var ok: Bool { return status >= 200 && status <= 299 }
    /// Şəbəkə xətası (status -1), 408, 429 və 5xx: toplu saxlanır və təkrar göndərilir.
    var retryable: Bool { return status == -1 || status == 408 || status == 429 || status >= 500 }
}

protocol Transport: AnyObject {
    func post(url: String, json: String) -> HttpResult
    func get(url: String, etag: String?) -> HttpResult
}

protocol Env: AnyObject {
    /// Unix vaxtı, millisaniyə ilə.
    func now() -> Int64
    func uuid() -> String
    /// Cihaz və tətbiq konteksti: locale, tz, screen, app, os, device (PROTOCOL.md 5.4).
    func deviceContext() -> [String: Any]
    func log(_ message: String)
}

// MARK: - Uzaqdan konfiq (PROTOCOL.md 8)

struct RemoteConfig {
    var enabled = true
    var sample = 1.0
    var ttlMs: Int64 = 3_600_000
    var sessionTimeoutMs: Int64 = 1_800_000
    var consentAnalytics = true
    var consentAds = true
    var auto: [String: Bool] = [:]
    var blockedEvents: Set<String> = []
    var stripParams: Set<String> = []
    var flushIntervalMs: Int64 = 30_000
    var maxBatch = 50
    var maxQueue = 1000

    static let standard = RemoteConfig()
    static var disabled: RemoteConfig {
        var config = RemoteConfig()
        config.enabled = false
        config.ttlMs = 86_400_000
        return config
    }

    /// Konfiqdə açıq şəkildə `false` verilməyibsə avtomatik event açıqdır.
    func auto(_ name: String) -> Bool {
        return auto[name] != false
    }

    /// Tanınmayan sahələr ötürülür; yararsız JSON üçün nil.
    static func parse(_ json: String?) -> RemoteConfig? {
        guard let json = json, !json.isEmpty, let o = Util.parseObject(json) else { return nil }
        var config = RemoteConfig()
        if let v = o["enabled"] as? Bool { config.enabled = v }
        if let v = Util.double(o["sample"]), !v.isNaN { config.sample = min(max(v, 0), 1) }
        if let v = Util.int(o["ttl_s"]) { config.ttlMs = min(max(v, 60), 7 * 86_400) * 1000 }
        if let v = Util.int(o["session_timeout_s"]) { config.sessionTimeoutMs = min(max(v, 60), 86_400) * 1000 }
        if let consent = o["consent_default"] as? [String: Any] {
            if let v = consent["analytics"] as? Bool { config.consentAnalytics = v }
            if let v = consent["ads"] as? Bool { config.consentAds = v }
        }
        if let auto = o["auto"] as? [String: Any] {
            for (name, value) in auto {
                if let flag = value as? Bool { config.auto[name] = flag }
            }
        }
        if let list = o["blocked_events"] as? [Any] { config.blockedEvents = Set(list.compactMap { $0 as? String }) }
        if let list = o["strip_params"] as? [Any] { config.stripParams = Set(list.compactMap { ($0 as? String)?.lowercased() }) }
        if let flush = o["flush"] as? [String: Any] {
            if let v = Util.int(flush["interval_s"]) { config.flushIntervalMs = min(max(v, 1), 3600) * 1000 }
            if let v = Util.int(flush["max_batch"]) { config.maxBatch = Int(min(max(v, 1), 100)) }
            if let v = Util.int(flush["max_queue"]) { config.maxQueue = Int(min(max(v, 1), 100_000)) }
        }
        return config
    }
}

// MARK: - Köməkçilər

enum Util {
    private static let forbidden: Set<String> = ["email", "phone", "password", "pass", "token", "card", "card_number", "cvv", "pin", "fin"]
    private static let strip: Set<String> = [
        "token", "password", "pass", "email", "phone", "access_token", "id_token", "refresh_token", "code",
        "secret", "client_secret", "auth", "api_key", "apikey", "otp", "reset_token",
    ]
    private static let originRegex = try? NSRegularExpression(pattern: "^[a-zA-Z][a-zA-Z0-9+.-]*://[^/?#]*", options: [])
    private static let userinfoRegex = try? NSRegularExpression(pattern: "//[^/@]*@", options: [])
    private static let emailRegex = try? NSRegularExpression(pattern: "[^/?&=#\\s]+(?:@|%40)[^/?&=#\\s]+\\.[A-Za-z]{2,}", options: [])

    private static func replace(_ regex: NSRegularExpression?, in text: String, with template: String) -> String {
        guard let regex = regex else { return text }
        return regex.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Sistem dil identifikatorunu (`az_AZ@calendar=…`) BCP 47-yə yaxın formaya (`az-AZ`) gətirir.
    static func localeTag(_ identifier: String) -> String {
        let base = identifier.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? identifier
        return String(base.replacingOccurrences(of: "_", with: "-").prefix(35))
    }
    private static let campaignKeys: Set<String> = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content"]
    static let clickIds = ["fbclid", "gclid", "gbraid", "wbraid", "ttclid", "msclkid"]

    private static func isLetter(_ c: UInt8) -> Bool { return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    private static func isDigit(_ c: UInt8) -> Bool { return c >= 48 && c <= 57 }

    /// `^[A-Za-z][A-Za-z0-9_]{0,63}$`
    static func isValidName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard let first = bytes.first, bytes.count <= 64, isLetter(first) else { return false }
        return bytes.allSatisfy { isLetter($0) || isDigit($0) || $0 == 95 }
    }

    /// `^[A-Za-z0-9_.:-]{1,64}$`
    static func isValidId(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard !bytes.isEmpty, bytes.count <= 64 else { return false }
        return bytes.allSatisfy { isLetter($0) || isDigit($0) || $0 == 95 || $0 == 46 || $0 == 58 || $0 == 45 }
    }

    /// `^[a-z0-9]{8,16}$`
    static func isValidKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        guard bytes.count >= 8, bytes.count <= 16 else { return false }
        return bytes.allSatisfy { ($0 >= 97 && $0 <= 122) || isDigit($0) }
    }

    static func iso(_ millis: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000.0))
    }

    static func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// PROTOCOL.md 6.1: boşluqlar silinir, kiçik hərfə çevrilir.
    static func normalizeEmail(_ email: String) -> String {
        return email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// PROTOCOL.md 6.1: yalnız rəqəmlər.
    static func normalizePhone(_ phone: String) -> String {
        return String(String.UnicodeScalarView(phone.unicodeScalars.filter { $0.value >= 48 && $0.value <= 57 }))
    }

    /// anon_id-dən [0,1) aralığında sabit ədəd (nümunələmə üçün). Veb tracker ilə eyni alqoritm: FNV-1a 32 bit.
    static func fraction(_ text: String) -> Double {
        var hash: UInt32 = 0x811c_9dc5
        for unit in text.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 0x0100_0193
        }
        return Double(hash) / 4_294_967_296.0
    }

    static func int(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, !isBool(number) else { return nil }
        let double = number.doubleValue
        guard double.isFinite, abs(double) < 9.0e18 else { return nil }
        return Int64(double)
    }

    static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isBool(number) else { return nil }
        return number.doubleValue
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Atılan dəyər üçün işarə.
    private struct Drop {}

    /// İstifadəçi məlumatını JSON-a çevrilə bilən dəyərə gətirir. Qadağan olunmuş açarlar,
    /// dərinliyi aşan və JSON-a çevrilməyən dəyərlər atılır.
    private static func clean(_ value: Any?, depth: Int, log: (String) -> Void) -> Any {
        guard let value = value else { return NSNull() }
        if value is NSNull { return NSNull() }
        if let string = value as? String { return string }
        if let number = value as? NSNumber {
            if isBool(number) { return number.boolValue }
            return number.doubleValue.isFinite ? number : Drop()
        }
        if let date = value as? Date {
            return iso(Int64(date.timeIntervalSince1970 * 1000))
        }
        if let dict = value as? [String: Any?] {
            if depth <= 0 { return Drop() }
            var out: [String: Any] = [:]
            for (key, item) in dict {
                if forbidden.contains(key.lowercased()) {
                    log("dropped forbidden key: \(key)")
                    continue
                }
                let cleaned = clean(item, depth: depth - 1, log: log)
                if !(cleaned is Drop) { out[key] = cleaned }
            }
            return out
        }
        if let array = value as? [Any?] {
            if depth <= 0 { return Drop() }
            var out: [Any] = []
            for item in array {
                let cleaned = clean(item, depth: depth - 1, log: log)
                if !(cleaned is Drop) { out.append(cleaned) }
            }
            return out
        }
        return Drop()
    }

    /// Lüğəti təmiz JSON obyektinə çevirir; boşdursa nil.
    static func cleanObject(_ dict: [String: Any?]?, log: (String) -> Void = { _ in }) -> [String: Any]? {
        guard let dict = dict else { return nil }
        guard let out = clean(dict, depth: 4, log: log) as? [String: Any], !out.isEmpty else { return nil }
        return out
    }

    /// Obyekti JSON sətirinə çevirir. Açarlar sıralanır ki, eyni məzmun eyni sətir versin.
    static func jsonString(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func parseObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    private static func decode(_ text: String) -> String {
        return text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text
    }

    private static func queryPairs(_ query: String) -> [(String, String)] {
        return query.split(separator: "&").map { part -> (String, String) in
            let text = String(part)
            if let eq = text.firstIndex(of: "=") {
                return (decode(String(text[text.startIndex..<eq])), decode(String(text[text.index(after: eq)...])))
            }
            return (decode(text), "")
        }
    }

    /// Keçiddən həssas query parametrlərini, fraqmenti, istifadəçi adı / parol hissəsini silir və
    /// host-dan sonrakı hissədə e-poçta bənzər mətni gizlədir (veb tracker və Android ilə eyni qayda).
    static func cleanUrl(_ url: String, extraStrip: Set<String> = []) -> String {
        let stripped = stripQuery(url, extraStrip: extraStrip)
        var origin = ""
        if let regex = originRegex,
           let match = regex.firstMatch(in: stripped, options: [], range: NSRange(stripped.startIndex..., in: stripped)),
           let range = Range(match.range, in: stripped) {
            origin = String(stripped[range])
        }
        let head = replace(userinfoRegex, in: origin, with: "//")
        let rest = String(stripped.dropFirst(origin.count))
        return String((head + replace(emailRegex, in: rest, with: "[redacted]")).prefix(2048))
    }

    private static func stripQuery(_ url: String, extraStrip: Set<String>) -> String {
        var base = url
        if let hash = base.firstIndex(of: "#") { base = String(base[base.startIndex..<hash]) }
        if let q = base.firstIndex(of: "?") {
            let query = String(base[base.index(after: q)...])
            let kept = query.split(separator: "&").map(String.init).filter { part in
                let rawName = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? part
                let name = decode(rawName).lowercased()
                return !strip.contains(name) && !extraStrip.contains(name)
            }
            base = String(base[base.startIndex..<q]) + (kept.isEmpty ? "" : "?" + kept.joined(separator: "&"))
        }
        return base
    }

    /// Keçiddəki UTM və klik ID parametrləri (PROTOCOL.md 5.4 `campaign`).
    static func campaignOf(_ url: String) -> [String: Any]? {
        var base = url
        if let hash = base.firstIndex(of: "#") { base = String(base[base.startIndex..<hash]) }
        guard let q = base.firstIndex(of: "?") else { return nil }
        var out: [String: Any] = [:]
        for (name, value) in queryPairs(String(base[base.index(after: q)...])) {
            if !value.isEmpty, campaignKeys.contains(name) || clickIds.contains(name) {
                out[name] = String(value.prefix(512))
            }
        }
        return out.isEmpty ? nil : out
    }
}
