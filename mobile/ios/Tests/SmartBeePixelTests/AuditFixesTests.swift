import Foundation
import XCTest
@testable import SmartBeePixel

private let auditKey = "demo0ios01"
private let unknownKey = "{\"ok\":false,\"error\":\"unknown_key\"}"
private let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abcDEF123_-x"

private final class AuditStore: Store {
    var map: [String: String] = [:]
    func get(_ key: String) -> String? { return map[key] }
    func put(_ key: String, _ value: String) { map[key] = value }
    func remove(_ key: String) { map[key] = nil }
}

private final class AuditQueue: EventQueue {
    var rows: [QueuedEvent] = []
    private var nextId: Int64 = 1
    func add(ctx: String, payload: String) {
        rows.append(QueuedEvent(id: nextId, ctx: ctx, payload: payload))
        nextId += 1
    }
    func peek(_ limit: Int) -> [QueuedEvent] { return Array(rows.prefix(limit)) }
    func remove(_ ids: [Int64]) { rows.removeAll { ids.contains($0.id) } }
    var count: Int { return rows.count }
    func trim(_ max: Int) { if rows.count > max { rows.removeFirst(rows.count - max) } }
    func clear() { rows.removeAll() }
    func update(_ change: (QueuedEvent) -> (ctx: String, payload: String)?) {
        rows = rows.map { row in
            guard let fresh = change(row) else { return row }
            return QueuedEvent(id: row.id, ctx: fresh.ctx, payload: fresh.payload)
        }
    }
}

private final class AuditTransport: Transport {
    var raw: [String] = []
    var attempts = 0
    var status = 200
    var retryAfter: Int64?
    var postError: String?
    var configStatus = 200
    var configBody: String?
    var configError: String?
    var configCalls = 0
    var lastEtag: String?
    /// Konfiq sorğusu gələn anda çağırılır.
    var onConfig: (() -> Void)?

    func post(url: String, json: String) -> HttpResult {
        attempts += 1
        let accepted = status >= 200 && status <= 299
        if accepted { raw.append(json) }
        return HttpResult(status: status, body: accepted ? nil : postError, retryAfterSec: retryAfter)
    }

    func get(url: String, etag: String?) -> HttpResult {
        onConfig?()
        configCalls += 1
        lastEtag = etag
        return HttpResult(status: configStatus, body: configStatus == 200 ? configBody : configError, etag: "W/\"1\"")
    }

    var posts: [[String: Any]] { return raw.compactMap { Util.parseObject($0) } }
    var events: [[String: Any]] { return posts.flatMap { $0["events"] as? [[String: Any]] ?? [] } }
    var names: [String] {
        return events.map { ($0["type"] as? String) == "track" ? ($0["name"] as? String ?? "?") : ($0["type"] as? String ?? "?") }
    }
}

private final class AuditEnv: Env {
    var time: Int64 = 1_795_590_000_000
    private var counter = 0
    var logs: [String] = []
    var attStatus: String?
    var idfa: String?
    var attNeeded = false
    var adCalls = 0
    var randomValue = 0.0
    /// Verilibsə cihaz konteksti buradan götürülür.
    var context: [String: Any]?

    func advertising(includeId: Bool) -> AdvertisingInfo {
        adCalls += 1
        return AdvertisingInfo(status: attStatus, idfa: idfa)
    }

    func attRequired() -> Bool { return attNeeded }
    func random() -> Double { return randomValue }
    func now() -> Int64 { return time }
    func uuid() -> String {
        counter += 1
        let tail = String(counter)
        return "00000000-0000-4000-8000-" + String(repeating: "0", count: 12 - tail.count) + tail
    }
    func log(_ message: String) { logs.append(message) }
    func deviceContext() -> [String: Any] {
        if let custom = context { return custom }
        return [
            "locale": "az-AZ", "tz": "Asia/Baku",
            "screen": ["w": 1179, "h": 2556, "density": 3.0],
            "app": ["id": "az.smartbee.demo", "version": "1.2.3", "build": "45"],
            "os": ["name": "iOS", "version": "18.1"],
            "device": ["manufacturer": "Apple", "model": "iPhone16,1", "type": "phone"],
            "ids": ["idfv": "6D92078A-8246-4BA4-AE5B-76104861E7DC"],
        ]
    }
}

/// Susmaya görə konfiq artıq bir dəfə alınıb keşlənmiş tətbiqi təqlid edir; `fresh = true`: ilk işə düşmə.
private final class AuditRig {
    let store = AuditStore()
    let queue = AuditQueue()
    let transport = AuditTransport()
    let env = AuditEnv()
    let gate = ConsentGate()
    var options: SmartBeeOptions

    init(_ options: SmartBeeOptions = SmartBeeOptions(debug: true), fresh: Bool = false) {
        self.options = options
        if !fresh {
            store.map[Core.Keys.binding] = Core.binding(key: auditKey, endpoint: options.endpoint)
            store.map[Core.Keys.config] = "{\"enabled\":true}"
        }
    }

    func core() -> Core {
        let core = Core(key: auditKey, options: options, store: store, queue: queue, transport: transport, env: env, gate: gate)
        core.start()
        return core
    }

    var queued: [String] {
        return queue.rows.map { (Util.parseObject($0.payload)?["name"] as? String) ?? "" }
    }

    func event(_ name: String) -> [String: Any] {
        return transport.events.first { ($0["name"] as? String) == name } ?? [:]
    }

    func ctx(of name: String) -> [String: Any] {
        let found = transport.posts.first { item in
            let events = item["events"] as? [[String: Any]] ?? []
            return events.contains { ($0["name"] as? String) == name }
        }
        return found?["ctx"] as? [String: Any] ?? [:]
    }
}

/// İlk buraxılışdan əvvəlki auditin (AUDIT.md, H / I / J bölmələri) tapıntılarının sınaqları. Android-də eyni vektorlar var
/// (AuditFixesTest.kt).
final class AuditFixesTests: XCTestCase {
    private let granted = SmartBeeOptions(consent: SmartBeeConsent(analytics: true, ads: true), debug: true)

    private func dict(_ value: Any?) -> [String: Any] { return value as? [String: Any] ?? [:] }

    private func adsFlag(_ ctx: [String: Any]) -> Bool? {
        return dict(ctx["consent"])["ads"] as? Bool
    }

    // MARK: - 1. Kontekst sxemin hədlərinə gətirilir

    func testContextIsClampedToSchemaLimits() {
        let long = String(repeating: "x", count: 5000)
        let rig = AuditRig(SmartBeeOptions(consent: SmartBeeConsent(analytics: true, ads: true), wrapper: "React Native!", wrapperVersion: long))
        rig.env.context = [
            "locale": "az_Latn_AZ-u-ca-gregory" + long,
            "tz": long,
            "ua": long,
            "screen": ["w": -5, "h": "tall", "density": -1.5] as [String: Any],
            "app": ["id": long, "version": long, "build": long],
            "os": ["name": long, "version": 14] as [String: Any],
            "device": ["manufacturer": long, "model": long + "\u{0}", "type": long],
            "ids": ["idfv": long, "n": 5] as [String: Any],
        ]
        let core = rig.core()
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)

        XCTAssertEqual(rig.transport.posts.count, 1)
        let batch = rig.transport.posts.first ?? [:]
        let ctx = dict(batch["ctx"])
        // spec/schema/batch.v1.schema.json: hər sahənin həddi (kod nöqtəsi ilə).
        XCTAssertEqual(ctx["locale"] as? String, "az-Latn-AZ")
        XCTAssertEqual((ctx["tz"] as? String)?.unicodeScalars.count, 64)
        XCTAssertEqual((ctx["ua"] as? String)?.unicodeScalars.count, 1024)
        let app = dict(ctx["app"])
        XCTAssertEqual((app["id"] as? String)?.unicodeScalars.count, 255)
        XCTAssertEqual((app["version"] as? String)?.unicodeScalars.count, 64)
        XCTAssertEqual((app["build"] as? String)?.unicodeScalars.count, 64)
        let os = dict(ctx["os"])
        XCTAssertEqual((os["name"] as? String)?.unicodeScalars.count, 32)
        XCTAssertNil(os["version"], "yanlış tipli sahə atılır")
        let device = dict(ctx["device"])
        XCTAssertEqual((device["manufacturer"] as? String)?.unicodeScalars.count, 64)
        XCTAssertEqual((device["model"] as? String)?.unicodeScalars.count, 64)
        XCTAssertEqual((device["type"] as? String)?.unicodeScalars.count, 16)
        XCTAssertTrue(dict(ctx["screen"]).isEmpty)
        let ids = dict(ctx["ids"])
        XCTAssertEqual((ids["idfv"] as? String)?.unicodeScalars.count, 256)
        XCTAssertNil(ids["n"])
        // Yararsız örtük adı göndərilmir (versiyası ilə birlikdə).
        let sdk = dict(batch["sdk"])
        XCTAssertNil(sdk["wrapper"])
        XCTAssertNil(sdk["wrapper_version"])
        XCTAssertEqual(sdk["version"] as? String, SmartBee.sdkVersion)
    }

    func testLocaleTagDropsUnicodeExtensions() {
        XCTAssertEqual(Util.localeTag("az_AZ@calendar=gregorian"), "az-AZ")
        XCTAssertEqual(Util.localeTag("en-US-u-hc-h12"), "en-US")
        XCTAssertEqual(Util.localeTag("az-Latn-AZ-U-nu-latn"), "az-Latn-AZ")
        XCTAssertEqual(Util.localeTag(String(repeating: "x", count: 100)).count, 35)
    }

    // MARK: - 2. Söndürmə yalnız serverin açıq cavabı ilə

    func testConfigFailuresWithoutRecognisedBodyAreTransient() {
        let bodies: [String?] = [nil, "<html>Not Found</html>", "{\"ok\":false,\"error\":\"not_found\"}", "{\"error\":5}"]
        for status in [404, 403, 401, 400, 410, 500, 503, 302] {
            for body in bodies {
                let rig = AuditRig()
                let core = rig.core()
                core.track("Lead", props: nil, eventId: nil)
                let before = rig.queue.count
                rig.transport.configStatus = status
                rig.transport.configError = body
                core.refreshConfig(force: true)
                XCTAssertFalse(core.paused, "\(status)")
                XCTAssertTrue(core.config.enabled)
                XCTAssertEqual(rig.queue.count, before)
                XCTAssertEqual(rig.store.map[Core.Keys.config], "{\"enabled\":true}")
            }
        }
    }

    func testUnknownKeyPausesWithoutClearingQueueAndIsRecheckedAfterOneHour() {
        let rig = AuditRig()
        let core = rig.core()
        core.track("Lead", props: nil, eventId: nil)
        let before = rig.queue.count
        rig.transport.configStatus = 404
        rig.transport.configError = unknownKey
        core.refreshConfig(force: true)

        XCTAssertTrue(core.paused)
        XCTAssertEqual(rig.queue.count, before, "növbə silinmir")
        XCTAssertEqual(rig.store.map[Core.Keys.config], "{\"enabled\":true}", "keşlənmiş konfiq qalır")
        core.track("WhilePaused", props: nil, eventId: nil)
        core.flush(force: true)
        XCTAssertEqual(rig.queue.count, before)
        XCTAssertEqual(rig.transport.attempts, 0)

        // Vəziyyət prosesin yenidən başlamasından sonra da qalır.
        XCTAssertTrue(rig.core().paused)

        // Bir saat ərzində yenidən soruşulmur.
        let calls = rig.transport.configCalls
        rig.env.time += 59 * 60_000
        core.flush()
        core.onForeground()
        XCTAssertEqual(rig.transport.configCalls, calls)

        // Bir saatdan sonra yoxlanır: açar yenidən aktivdirsə növbə göndərilir.
        rig.transport.configStatus = 200
        rig.transport.configBody = "{\"enabled\":true}"
        rig.env.time += 2 * 60_000
        core.flush()
        XCTAssertFalse(core.paused)
        XCTAssertNil(rig.store.map[Core.Keys.keyOffAt])
        XCTAssertTrue(rig.transport.names.contains("Lead"))
        XCTAssertFalse(rig.transport.names.contains("WhilePaused"))
        XCTAssertEqual(rig.queue.count, 0)
    }

    func testPostVerdictFollowsTheProtocolTable() {
        func verdict(_ status: Int, _ error: String? = nil, events: Int = 3) -> Verdict {
            var body: String?
            if let error = error { body = "{\"ok\":false,\"error\":\"" + error + "\"}" }
            return HttpResult(status: status, body: body).verdict(events: events)
        }
        XCTAssertEqual(verdict(200), .accepted)
        XCTAssertEqual(verdict(204), .accepted)
        for code in ["empty_body", "bad_gzip", "bad_json", "bad_batch", "bad_chars"] { XCTAssertEqual(verdict(400, code), .drop, code) }
        XCTAssertEqual(verdict(403, "unknown_key"), .keyOff)
        for code in ["origin_not_allowed", "app_not_allowed", "platform_not_enabled", "unknown_platform", "browser_not_allowed"] {
            XCTAssertEqual(verdict(403, code), .drop, code)
        }
        XCTAssertEqual(verdict(413, "body_too_large", events: 2), .split)
        XCTAssertEqual(verdict(413, nil, events: 2), .split)
        for code in ["body_too_large", "context_too_large", "too_many_events"] { XCTAssertEqual(verdict(413, code, events: 1), .drop, code) }
        XCTAssertEqual(verdict(413, nil, events: 1), .retry)
        XCTAssertEqual(verdict(413, "blocked", events: 1), .retry)
        XCTAssertEqual(verdict(400, "blocked"), .retry)
        XCTAssertEqual(verdict(422), .retry)
        XCTAssertEqual(verdict(422, "bad_batch"), .retry)
        XCTAssertEqual(verdict(404, "unknown_key"), .keyOff)
        XCTAssertEqual(verdict(404, "app_not_allowed"), .retry)
        XCTAssertEqual(verdict(429, "rate_limited"), .retry)
        XCTAssertEqual(verdict(404, "not_found"), .retry)
        XCTAssertEqual(verdict(403, "some_future_code"), .retry)
        // Tanınan gövdəsi olmayan hər 4xx (WAF, ingress, proksi), 3xx, 5xx və şəbəkə xətası müvəqqətidir.
        for status in [-1, 301, 302, 400, 401, 403, 404, 405, 407, 408, 409, 410, 418, 429, 451, 500, 502, 503, 504] {
            XCTAssertEqual(verdict(status), .retry, "\(status)")
            XCTAssertEqual(HttpResult(status: status, body: "<html>blocked</html>").verdict(events: 3), .retry, "\(status)")
        }
        XCTAssertNil(HttpResult(status: 403, body: String(repeating: "x", count: 5000)).error)
        XCTAssertNil(HttpResult(status: 403, body: "[\"unknown_key\"]").error)
    }

    func testProxyErrorsHoldTheBatchAndServerRejectionsDropIt() {
        for status in [401, 403, 404, 407, 400] {
            let rig = AuditRig()
            let core = rig.core()
            core.track("Lead", props: nil, eventId: nil)
            let before = rig.queue.count
            rig.transport.status = status
            core.flush(force: true)
            XCTAssertEqual(rig.queue.count, before, "\(status)")
            XCTAssertEqual(rig.transport.attempts, 1)
            // Fasilədən sonra yenidən cəhd olunur və eventlər çatır.
            rig.transport.status = 200
            rig.env.time += 10_000
            core.flush()
            XCTAssertEqual(rig.queue.count, 0)
            XCTAssertFalse(core.paused)
        }

        let rig = AuditRig()
        let core = rig.core()
        core.track("Lead", props: nil, eventId: nil)
        rig.transport.status = 403
        rig.transport.postError = unknownKey
        core.flush(force: true)
        XCTAssertEqual(rig.queue.count, 0, "rədd edilmiş toplu silinir")
        XCTAssertTrue(core.paused, "403 unknown_key açarı söndürür")
        core.track("Later", props: nil, eventId: nil)
        XCTAssertEqual(rig.queue.count, 0)
    }

    // MARK: - 3. Keş açara və ünvana bağlıdır

    func testCachedConfigAndQueueOfAnotherKeyOrEndpointAreDiscarded() {
        let proxy = SmartBeeOptions(debug: true, endpoint: "https://proxy.example.com/")
        let cases: [(String, SmartBeeOptions)] = [
            (Core.binding(key: "otherkey01", endpoint: defaultEndpoint), SmartBeeOptions(debug: true)),
            (Core.binding(key: auditKey, endpoint: defaultEndpoint), proxy),
        ]
        for (oldBinding, options) in cases {
            let rig = AuditRig(options)
            rig.store.map[Core.Keys.binding] = oldBinding
            rig.store.map[Core.Keys.config] = "{\"enabled\":true,\"blocked_events\":[\"Lead\"]}"
            rig.store.map[Core.Keys.configEtag] = "W/\"old\""
            rig.store.map[Core.Keys.configAt] = String(rig.env.time)
            rig.store.map[Core.Keys.keyOffAt] = String(rig.env.time)
            rig.store.map[Core.Keys.anon] = "anon-kept"
            rig.queue.add(ctx: "{\"platform\":\"ios\"}", payload: "{\"name\":\"Old\"}")

            let core = rig.core()
            XCTAssertTrue(rig.queue.rows.isEmpty, "başqa açarın sətirləri atılır")
            XCTAssertFalse(core.paused)
            XCTAssertTrue(core.config.blockedEvents.isEmpty)
            XCTAssertNil(rig.store.map[Core.Keys.config])
            XCTAssertNil(rig.store.map[Core.Keys.configEtag])
            XCTAssertEqual(rig.store.map[Core.Keys.anon], "anon-kept", "identifikatorlar qalır")

            rig.transport.configBody = "{\"enabled\":true}"
            core.refreshConfig()
            XCTAssertNil(rig.transport.lastEtag, "köhnə ETag göndərilmir")
            XCTAssertEqual(rig.store.map[Core.Keys.binding], Core.binding(key: auditKey, endpoint: options.endpoint))
            core.track("Lead", props: nil, eventId: nil)
            core.flush(force: true)
            XCTAssertTrue(rig.transport.names.contains("Lead"))
        }
        // Eyni açar və ünvan: keş və növbə qalır.
        let same = AuditRig()
        same.queue.add(ctx: "{\"platform\":\"ios\"}", payload: "{\"name\":\"Kept\"}")
        _ = same.core()
        XCTAssertEqual(same.queue.rows.filter { $0.payload.contains("Kept") }.count, 1)
    }

    // MARK: - 4. Yaddaş: yazı alınmayanda və növbənin kilidi

    func testFileStoreKeepsNewValueAndRetriesWhenTheWriteFails() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-audit-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileStore(directory: dir)
        store.put("consent", "11")
        XCTAssertFalse(store.unsaved)
        XCTAssertEqual(FileStore(directory: dir).get("consent"), "11")

        // Faylın yerində qovluq var: atomik yazı alınmır.
        let file = dir.appendingPathComponent("store.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file.appendingPathComponent("blocker"), withIntermediateDirectories: true, attributes: nil)
        store.put("consent", "00")
        XCTAssertEqual(store.get("consent"), "00", "yazı alınmasa da yeni dəyər yaddaşda qüvvədədir")
        XCTAssertTrue(store.unsaved)

        // Maneə aradan qalxanda yazı təkrarlanır.
        try FileManager.default.removeItem(at: file)
        store.retrySave()
        XCTAssertFalse(store.unsaved)
        XCTAssertEqual(FileStore(directory: dir).get("consent"), "00")
    }

    func testFileQueueReportsWhetherATrailingWriteIsNeeded() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-audit-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = FileQueue(directory: dir)
        XCTAssertTrue(queue.persistSoon(), "dəyişiklik yoxdur")
        queue.add(ctx: "{}", payload: "{\"n\":1}")
        XCTAssertTrue(queue.persistSoon(), "ilk yazı dərhal gedir")
        queue.add(ctx: "{}", payload: "{\"n\":2}")
        XCTAssertFalse(queue.persistSoon(), "son yazıdan 2 saniyə keçməyib: çağıran yazını planlaşdırmalıdır")
        XCTAssertEqual(FileQueue(directory: dir).count, 1)
        queue.persist()
        XCTAssertEqual(FileQueue(directory: dir).count, 2)

        // Növbə bir neçə axından eyni vaxtda işlənə bilər (tətbiq bağlananda əsas axından yazılır).
        let group = DispatchGroup()
        for index in 0..<8 {
            DispatchQueue.global().async(group: group) {
                for item in 0..<50 {
                    queue.add(ctx: "{}", payload: "{\"n\":\(index * 100 + item)}")
                    if item % 10 == 0 { queue.persist() }
                    _ = queue.peek(5)
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        XCTAssertEqual(queue.count, 402)
        queue.persist()
        XCTAssertEqual(FileQueue(directory: dir).count, 402)
    }

    // MARK: - 5. Pozuq sətir yalnız özü atılır

    func testCorruptQueueRowIsSkippedAndTheRestOfTheBatchIsSent() {
        let rig = AuditRig()
        let core = rig.core()
        core.track("A", props: nil, eventId: nil)
        let ctx = rig.queue.rows.last?.ctx ?? "{}"
        rig.queue.add(ctx: ctx, payload: "{not json")
        rig.queue.add(ctx: "{broken ctx", payload: "{\"name\":\"Lost\"}")
        core.track("B", props: nil, eventId: nil)
        core.flush(force: true)
        XCTAssertEqual(rig.queue.count, 0)
        XCTAssertTrue(rig.transport.names.contains("A"))
        XCTAssertTrue(rig.transport.names.contains("B"))
        XCTAssertTrue(rig.env.logs.contains { $0.contains("corrupt queue rows") })
    }

    // MARK: - 6. Keçidlər: uzunluq həddi və xətti e-poçt axtarışı

    func testOverlongDeepLinkIsRejectedBeforeAnyProcessing() {
        let rig = AuditRig(granted)
        let core = rig.core()
        let url = "https://shop.az/p?utm_source=fb&q=" + String(repeating: "a@", count: 5000)
        XCTAssertTrue(url.utf16.count > Util.maxUrlLength)
        core.onDeepLink(url)
        XCTAssertFalse(rig.queued.contains("DeepLinkOpen"))
        XCTAssertNil(rig.store.map[Core.Keys.campaign])
        XCTAssertTrue(rig.env.logs.contains { $0.contains("longer than 8192") })
        XCTAssertFalse(Util.isLink(url))
        // Təmizləmə funksiyaları veb tracker-dəki kimi uzun ünvanı qısaldır (query atılır); kampaniya oxunur.
        XCTAssertEqual(Util.cleanUrl(url), "https://shop.az/p")
        XCTAssertEqual(Util.stripClickIds(url), "https://shop.az/p")
        XCTAssertEqual(Util.campaignOf(url)?["utm_source"] as? String, "fb")

        // Həddə qədər olan keçid qəbul olunur.
        let ok = "https://shop.az/p?q=" + String(repeating: "a", count: Util.maxUrlLength - 20)
        XCTAssertEqual(ok.utf16.count, Util.maxUrlLength)
        core.onDeepLink(ok)
        XCTAssertTrue(rig.queued.contains("DeepLinkOpen"))
    }

    func testEmailRedactionIsLinearOnPathologicalInput() {
        let inputs = [
            String(repeating: "a@", count: 4000),
            String(repeating: "@", count: 100_000),
            String(repeating: "a@b", count: 50_000),
            String(repeating: "%40", count: 50_000),
            "a@" + String(repeating: ".", count: 100_000),
            String(repeating: "a@b." + String(repeating: "c", count: 10), count: 10_000),
            String(repeating: "x", count: 200_000) + "@",
        ]
        let started = Date()
        for input in inputs {
            _ = Util.redactEmails(input)
            _ = Util.cleanObject(["text": input])
            let head = String(input.prefix(Util.maxUrlLength - 20))
            _ = Util.secretSegment(head, hint: 1, path: true)
            _ = Util.cleanUrl("https://shop.az/" + head)
            _ = Util.stripClickIds("https://shop.az/" + head)
            _ = Util.campaignOf("https://shop.az/?utm_term=" + String(input.prefix(4000)))
        }
        let seconds = Date().timeIntervalSince(started)
        // Köhnə regex 2000 «@» üçün saniyələr çəkirdi; xətti axtarış bütün girişləri millisaniyələrdə bitirir.
        // Hədd sazlama (optimallaşdırılmamış) yığımı və yüklü CI maşını üçün genişdir.
        XCTAssertLessThan(seconds, 5.0)
    }

    func testEmailRedactionMatchesTheWebTracker() {
        XCTAssertEqual(Util.redactEmails("a@b.az"), "[redacted]")
        XCTAssertEqual(Util.redactEmails("/u/a@b.az/x"), "/u/[redacted]/x")
        XCTAssertEqual(Util.redactEmails("?m=a%40b.com&n=1"), "?m=[redacted]&n=1")
        XCTAssertEqual(Util.redactEmails("write to User.Test@Example.COM please"), "write to [redacted] please")
        // `@` hissənin birinci simvoludursa və ya domenə oxşayan davam yoxdursa toxunulmur.
        XCTAssertEqual(Util.redactEmails("@handle"), "@handle")
        XCTAssertEqual(Util.redactEmails("a@b"), "a@b")
        XCTAssertEqual(Util.redactEmails("a@b.c"), "a@b.c")
        XCTAssertEqual(Util.redactEmails("a@.az"), "a@.az")
        XCTAssertEqual(Util.redactEmails("no mail here"), "no mail here")
    }

    // MARK: - 7. Çağırış anındakı surət

    func testSnapshotIsBoundedAndDetachedFromMutableContainers() {
        let huge: [String: Any] = ["items": Array(0..<100_000)]
        XCTAssertTrue(Util.snapshot(huge).oversized)
        XCTAssertNil(Util.snapshot(huge).value)
        XCTAssertTrue(Util.snapshot(["text": String(repeating: "x", count: Util.maxSnapshotChars + 1)]).oversized)
        XCTAssertFalse(Util.snapshot(nil).oversized)
        XCTAssertNil(Util.snapshot(nil).value)

        // Dəyişən Foundation konteynerləri çağırış anında kopyalanır: sonrakı dəyişiklik eventə düşmür.
        let list = NSMutableArray(array: ["x"])
        let inner = NSMutableDictionary(dictionary: ["c": true])
        let text = NSMutableString(string: "before")
        let copy = Util.snapshot(["a": 1, "list": list, "inner": inner, "text": text])
        list.add("added later")
        inner["later"] = 1
        text.append(" and after")
        XCTAssertFalse(copy.oversized)
        let cleaned = Util.cleanObject(copy.value) ?? [:]
        XCTAssertEqual(cleaned["a"] as? Int, 1)
        XCTAssertEqual((cleaned["list"] as? [Any])?.count, 1)
        XCTAssertEqual(dict(cleaned["inner"]).count, 1)
        XCTAssertEqual(cleaned["text"] as? String, "before")
    }

    // MARK: - 8. Konfiq hədləri, Retry-After, saat

    func testRemoteConfigValuesAreClampedToSafeBounds() {
        let low = RemoteConfig.parse("{\"ttl_s\":1,\"session_timeout_s\":1,\"flush\":{\"interval_s\":1,\"max_batch\":1,\"max_queue\":1}}")
        XCTAssertEqual(low?.ttlMs, 60_000)
        XCTAssertEqual(low?.sessionTimeoutMs, 60_000)
        XCTAssertEqual(low?.flushIntervalMs, 10_000)
        XCTAssertEqual(low?.maxBatch, 10)
        XCTAssertEqual(low?.maxQueue, 10)
        let high = RemoteConfig.parse("{\"ttl_s\":99999999,\"session_timeout_s\":99999999,\"flush\":{\"interval_s\":99999,\"max_batch\":9999,\"max_queue\":100000}}")
        XCTAssertEqual(high?.ttlMs, 7 * 86_400_000)
        XCTAssertEqual(high?.sessionTimeoutMs, 86_400_000)
        XCTAssertEqual(high?.flushIntervalMs, 3_600_000)
        XCTAssertEqual(high?.maxBatch, 100)
        XCTAssertEqual(high?.maxQueue, 5000)
    }

    func testRetryAfterGetsPositiveJitter() {
        let rig = AuditRig()
        rig.env.randomValue = 1.0
        let core = rig.core()
        core.track("Lead", props: nil, eventId: nil)
        rig.transport.status = 429
        rig.transport.retryAfter = 100
        core.flush(force: true)
        rig.transport.status = 200
        // 100 s + 20%: 119 saniyədə hələ gözlənilir (məcburi flush da), 121-də göndərilir.
        rig.env.time += 119_000
        core.flush(force: true)
        XCTAssertTrue(rig.queue.count > 0)
        rig.env.time += 2_000
        core.flush()
        XCTAssertEqual(rig.queue.count, 0)
    }

    func testBackoffSurvivesClockMovingBackwards() {
        let rig = AuditRig()
        let core = rig.core()
        core.track("Lead", props: nil, eventId: nil)
        rig.transport.status = 503
        core.flush(force: true)
        rig.transport.status = 200
        // Saat on gün geri çəkilib: köhnə hədd sonsuz gözlətmir.
        rig.env.time -= 10 * 86_400_000
        core.flush()
        XCTAssertEqual(rig.queue.count, 0)
    }

    func testNotModifiedResetsTheConfigFailureCounter() {
        let rig = AuditRig()
        let core = rig.core()
        rig.transport.configStatus = 500
        for _ in 0..<5 { core.refreshConfig(force: true) }
        rig.transport.configStatus = 304
        core.refreshConfig(force: true)
        // Konfiqin ömrü bitəndən sonrakı ilk uğursuzluq yenə ən qısa fasilə ilə təkrarlanır.
        rig.env.time += 3_600_001
        rig.transport.configStatus = 500
        core.refreshConfig()
        let calls = rig.transport.configCalls
        rig.env.time += 5_000
        core.refreshConfig()
        XCTAssertEqual(rig.transport.configCalls, calls + 1)
    }

    func testForegroundRespectsConfigBackoff() {
        let rig = AuditRig()
        let core = rig.core()
        rig.transport.configStatus = 500
        core.onForeground()
        let calls = rig.transport.configCalls
        core.onBackground()
        core.onForeground()
        core.flush()
        XCTAssertEqual(rig.transport.configCalls, calls, "fasilə bitməmiş konfiq yenidən soruşulmur")
    }

    // MARK: - 9. Razılığın geri alınması dərhaldır

    func testGateBlocksNetworkAndAdDataImmediately() {
        let rig = AuditRig(granted)
        let core = rig.core()
        core.onDeepLink("https://shop.az/?utm_source=fb&gclid=GVAL9")
        core.track("Lead", props: nil, eventId: nil)
        XCTAssertTrue(rig.queue.rows.map { $0.ctx }.joined().contains("GVAL9"))

        // Açıq çağırış qadağanı çağıran axında qoyub, nüvə hələ `setConsent`-i icra etməyib.
        rig.gate.hold(denyAnalytics: true, denyAds: false)
        let calls = rig.transport.configCalls
        core.flush(force: true)
        core.refreshConfig(force: true)
        core.onForeground()
        XCTAssertEqual(rig.transport.attempts, 0)
        XCTAssertEqual(rig.transport.configCalls, calls)
        rig.gate.release(denyAnalytics: true, denyAds: false)

        rig.gate.hold(denyAnalytics: false, denyAds: true)
        core.flush(force: true)
        XCTAssertFalse(rig.transport.posts.isEmpty)
        for post in rig.transport.posts {
            let ctx = dict(post["ctx"])
            XCTAssertEqual(adsFlag(ctx), false)
            XCTAssertNil(ctx["ids"])
        }
        XCTAssertFalse(rig.transport.raw.joined().contains("GVAL9"))
        XCTAssertFalse(rig.transport.raw.joined().contains("6D92078A"))
    }

    func testConsentGateCountsOutstandingDenials() {
        let gate = ConsentGate()
        XCTAssertFalse(gate.analyticsDenied)
        gate.hold(denyAnalytics: true, denyAds: true)
        gate.hold(denyAnalytics: true, denyAds: false)
        gate.release(denyAnalytics: true, denyAds: true)
        XCTAssertTrue(gate.analyticsDenied, "ikinci geri alınma hələ icra olunmayıb")
        XCTAssertFalse(gate.adsDenied)
        gate.release(denyAnalytics: true, denyAds: false)
        XCTAssertFalse(gate.analyticsDenied)
        gate.release(denyAnalytics: true, denyAds: true)
        XCTAssertFalse(gate.analyticsDenied)
    }

    // MARK: - 10. Razılığın üstünlük sırası

    func testMostRestrictiveOfStoredAndInitConsentWins() {
        // Saxlanmış «hə», initialize-də açıq «yox»: yox.
        let denied = AuditRig(SmartBeeOptions(consent: SmartBeeConsent(analytics: false, ads: false), debug: true))
        denied.store.map[Core.Keys.consent] = "11"
        denied.store.map[Core.Keys.anon] = "anon-old"
        let deniedCore = denied.core()
        deniedCore.track("Lead", props: nil, eventId: nil)
        XCTAssertNil(deniedCore.anonymousId)
        XCTAssertEqual(denied.queue.count, 0)
        XCTAssertNil(denied.store.map[Core.Keys.anon])

        // Saxlanmış «hə, hə», initialize-də reklam «yox».
        let noAds = AuditRig(SmartBeeOptions(consent: SmartBeeConsent(analytics: true, ads: false), debug: true))
        noAds.store.map[Core.Keys.consent] = "11"
        let noAdsCore = noAds.core()
        noAdsCore.track("Lead", props: nil, eventId: nil)
        noAdsCore.flush(force: true)
        XCTAssertEqual(adsFlag(noAds.ctx(of: "Lead")), false)
        XCTAssertEqual(dict(noAds.ctx(of: "Lead")["consent"])["analytics"] as? Bool, true)

        // Saxlanmış «yox», initialize-də «hə»: yox.
        let stored = AuditRig(granted)
        stored.store.map[Core.Keys.consent] = "00"
        let storedCore = stored.core()
        storedCore.track("Lead", props: nil, eventId: nil)
        XCTAssertEqual(stored.queue.count, 0)

        // Sonrakı açıq `setConsent` ən təzə seçimdir və initialize-dəki dəyəri əvəz edir.
        storedCore.setConsent(analytics: true, ads: true)
        storedCore.track("Lead", props: nil, eventId: nil)
        storedCore.flush(force: true)
        XCTAssertEqual(adsFlag(stored.ctx(of: "Lead")), true)
        deniedCore.setConsent(analytics: true, ads: false)
        deniedCore.track("Lead", props: nil, eventId: nil)
        deniedCore.flush(force: true)
        XCTAssertEqual(adsFlag(denied.ctx(of: "Lead")), false)
    }

    func testRemoteDefaultNeverOverridesStatedConsent() {
        for remote in ["{\"analytics\":true,\"ads\":true}", "{\"analytics\":false,\"ads\":false}"] {
            let rig = AuditRig(SmartBeeOptions(consent: SmartBeeConsent(analytics: true, ads: false), debug: true))
            rig.transport.configBody = "{\"enabled\":true,\"consent_default\":" + remote + "}"
            let core = rig.core()
            core.refreshConfig(force: true)
            core.track("Lead", props: nil, eventId: nil)
            core.flush(force: true)
            let consent = dict(rig.ctx(of: "Lead")["consent"])
            XCTAssertEqual(consent["analytics"] as? Bool, true, remote)
            XCTAssertEqual(consent["ads"] as? Bool, false, remote)
        }
        // Heç kim razılıq bildirməyibsə konfiqin dəyəri işləyir (susmaya görə davranış dəyişməyib).
        XCTAssertTrue(consentWhenUnstated)
        let unstated = AuditRig()
        unstated.transport.configBody = "{\"enabled\":true,\"consent_default\":{\"analytics\":true,\"ads\":false}}"
        let core = unstated.core()
        core.refreshConfig(force: true)
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        XCTAssertEqual(adsFlag(unstated.ctx(of: "Lead")), false)
    }

    // MARK: - 11. Açıq rədd: nə şəbəkə, nə identifikator

    func testNoNetworkWhileAnalyticsIsExplicitlyDenied() {
        let byInit = AuditRig(SmartBeeOptions(consent: SmartBeeConsent(analytics: false, ads: false), debug: true), fresh: true)
        let byUser = AuditRig(SmartBeeOptions(debug: true), fresh: true)
        byUser.store.map[Core.Keys.consent] = "00"
        for rig in [byInit, byUser] {
            rig.env.attNeeded = true
            rig.env.attStatus = "authorized"
            let core = rig.core()
            core.onForeground()
            core.track("Lead", props: nil, eventId: nil)
            core.flush(force: true)
            core.refreshConfig(force: true)
            XCTAssertEqual(rig.transport.configCalls, 0)
            XCTAssertEqual(rig.transport.attempts, 0)
            XCTAssertEqual(rig.env.adCalls, 0, "ATT vəziyyəti və IDFA oxunmur")
            XCTAssertTrue(rig.store.map.keys.filter { $0 != Core.Keys.consent }.isEmpty, "\(rig.store.map)")

            // Razılıq veriləndə konfiq dərhal alınır.
            rig.transport.configBody = "{\"enabled\":true}"
            core.setConsent(analytics: true, ads: true)
            XCTAssertEqual(rig.transport.configCalls, 1)
            XCTAssertNotNil(core.anonymousId)
        }
    }

    func testDisabledAnswerWhileUndecidedCommitsNoIdentifiers() {
        let identifiers: Set<String> = [Core.Keys.anon, Core.Keys.user, Core.Keys.session, Core.Keys.seq, Core.Keys.campaign, Core.Keys.appVersion]

        let unknown = AuditRig(fresh: true)
        unknown.transport.configStatus = 404
        unknown.transport.configError = unknownKey
        let first = unknown.core()
        first.identify("user-1", traits: nil)
        first.onDeepLink("https://shop.az/?utm_source=fb")
        first.onForeground()
        first.flush(force: true)
        XCTAssertTrue(first.paused)
        XCTAssertTrue(identifiers.isDisjoint(with: Set(unknown.store.map.keys)), "\(unknown.store.map)")
        XCTAssertEqual(unknown.queue.count, 0)
        XCTAssertEqual(unknown.transport.attempts, 0)

        let disabled = AuditRig(fresh: true)
        disabled.transport.configBody = "{\"enabled\":false}"
        let second = disabled.core()
        second.identify("user-1", traits: nil)
        second.onForeground()
        second.flush(force: true)
        XCTAssertFalse(second.config.enabled)
        XCTAssertTrue(identifiers.isDisjoint(with: Set(disabled.store.map.keys)), "\(disabled.store.map)")
        XCTAssertEqual(disabled.transport.attempts, 0)

        // Açar aktivləşəndə SDK işə düşür və identifikatorlar yalnız onda yazılır.
        disabled.transport.configBody = "{\"enabled\":true}"
        second.refreshConfig(force: true)
        second.track("Lead", props: nil, eventId: nil)
        second.flush(force: true)
        XCTAssertNotNil(disabled.store.map[Core.Keys.anon])
        XCTAssertTrue(disabled.transport.names.contains("Lead"))
    }

    // MARK: - 12. reset

    func testResetClearsCampaignSequenceScreenAndIdentity() {
        let rig = AuditRig(granted)
        let core = rig.core()
        core.onDeepLink("https://shop.az/?utm_source=fb&gclid=G1")
        core.screen("Home", props: nil)
        core.identify("user-1", traits: nil)
        core.track("Before", props: nil, eventId: nil)
        let oldAnon = core.anonymousId
        core.reset(newId: "11111111-2222-4333-8444-555555555555")

        XCTAssertEqual(core.anonymousId, "11111111-2222-4333-8444-555555555555")
        XCTAssertNotEqual(core.anonymousId, oldAnon)
        for name in [Core.Keys.user, Core.Keys.campaign, Core.Keys.campaignAt, Core.Keys.seq, Core.Keys.session] {
            XCTAssertNil(rig.store.map[name], name)
        }
        core.track("After", props: nil, eventId: nil)
        core.flush(force: true)
        let after = rig.event("After")
        XCTAssertEqual(after["anon_id"] as? String, "11111111-2222-4333-8444-555555555555")
        XCTAssertNil(after["user_id"])
        XCTAssertNil(after["screen"], "ekran adı silinir")
        XCTAssertNil(rig.ctx(of: "After")["campaign"])
        let restarted = rig.transport.events.last { ($0["name"] as? String) == "SessionStart" } ?? [:]
        XCTAssertEqual(restarted["seq"] as? Int, 0, "sıra nömrəsi yenidən başlayır")
        XCTAssertEqual(after["seq"] as? Int, 1)
        // Yararsız ID verilərsə nüvə özü yaradır.
        core.reset(newId: "not a valid id!")
        XCTAssertTrue(Util.isValidId(core.anonymousId ?? ""))
    }

    // MARK: - 13. Kampaniya

    func testClickIdsAreNotPersistedWithoutAdsConsent() {
        let link = "https://shop.az/?utm_source=fb&gclid=GVAL9&fbclid=FVAL9&dclid=DVAL9&twclid=TVAL9&yclid=YVAL9&li_fat_id=LVAL9"
        let off = AuditRig(SmartBeeOptions(consent: SmartBeeConsent(analytics: true, ads: false), debug: true))
        let offCore = off.core()
        offCore.onDeepLink(link)
        XCTAssertEqual(Set((Util.parseObject(off.store.map[Core.Keys.campaign] ?? "") ?? [:]).keys), ["utm_source"])
        let stored = off.queue.rows.map { $0.ctx + $0.payload }.joined()
        for id in ["GVAL9", "FVAL9", "DVAL9", "TVAL9", "YVAL9", "LVAL9"] { XCTAssertFalse(stored.contains(id), id) }

        let on = AuditRig(granted)
        let onCore = on.core()
        onCore.onDeepLink(link)
        XCTAssertEqual(
            Set((Util.parseObject(on.store.map[Core.Keys.campaign] ?? "") ?? [:]).keys),
            ["utm_source", "gclid", "fbclid", "dclid", "twclid", "yclid", "li_fat_id"]
        )
        // Razılıq geri alınanda klik ID-ləri diskdən də silinir.
        onCore.setConsent(analytics: true, ads: false)
        XCTAssertEqual(Set((Util.parseObject(on.store.map[Core.Keys.campaign] ?? "") ?? [:]).keys), ["utm_source"])
    }

    func testStoredCampaignExpiresAfterNinetyDays() {
        let rig = AuditRig(granted)
        let core = rig.core()
        core.onDeepLink("https://shop.az/?utm_source=fb&utm_campaign=spring")
        XCTAssertNotNil(rig.store.map[Core.Keys.campaignAt])
        rig.env.time += 89 * 86_400_000
        core.track("Fresh", props: nil, eventId: nil)
        rig.env.time += 2 * 86_400_000
        core.track("Stale", props: nil, eventId: nil)
        core.flush(force: true)
        XCTAssertEqual(dict(rig.ctx(of: "Fresh")["campaign"])["utm_source"] as? String, "fb")
        XCTAssertNil(rig.ctx(of: "Stale")["campaign"])
        XCTAssertNil(rig.store.map[Core.Keys.campaign])
        XCTAssertNil(rig.store.map[Core.Keys.campaignAt])

        // Vaxtı yazılmamış (köhnə formatlı) kampaniya da atılır.
        rig.store.map[Core.Keys.campaign] = "{\"utm_source\":\"old\"}"
        core.track("Legacy", props: nil, eventId: nil)
        XCTAssertNil(rig.store.map[Core.Keys.campaign])
    }

    func testCampaignValuesAreSanitised() {
        let campaign = Util.campaignOf("https://shop.az/?utm_source=news&utm_term=a%40b.az&utm_content=" + String(repeating: "c", count: 600) + "&utm_medium=mail;x") ?? [:]
        XCTAssertEqual(campaign["utm_term"] as? String, "[redacted]")
        XCTAssertEqual((campaign["utm_content"] as? String)?.utf16.count, 512)
        // Kampaniya oxunanda yalnız `&` ayırıcıdır (veb tracker ilə eyni qayda).
        XCTAssertEqual(campaign["utm_medium"] as? String, "mail;x")
        // JWT gizlədilir, dəyəri ünvan olan parametr ünvan kimi təmizlənir.
        let scrubbed = Util.campaignOf("https://shop.az/?utm_content=" + jwt + "&utm_source=https%3A%2F%2Fu%3Ap%40ref.az%2Fx%3Ftoken%3D1%26a%3D2") ?? [:]
        XCTAssertEqual(scrubbed["utm_content"] as? String, "[redacted]")
        XCTAssertEqual(scrubbed["utm_source"] as? String, "https://ref.az/x?a=2")
        XCTAssertNil(Util.campaignOf("https://shop.az/?gclid=G1", withClickIds: false))
    }

    // MARK: - 14. Ünvanların təmizlənməsi (Android-dəki `urlSanitisingVectors` ilə eyni vektorlar)

    func testUrlSanitisingVectors() {
        let vectors: [(String, String)] = [
            // Həssas adlar: hissə kimi, registrdən asılı olmadan.
            ("https://shop.az/p?oobCode=abc&auth_code=1&jwt=x&sig=1&utm_source=fb&q=shoes", "https://shop.az/p?utm_source=fb&q=shoes"),
            ("https://shop.az/p?Access_Token=1&ID_TOKEN=2&refreshToken=3&x=1", "https://shop.az/p?x=1"),
            ("https://shop.az/p?password=1&passwd=2&pwd=3&client_secret=4&api_key=5&apiKey=6&x=1", "https://shop.az/p?x=1"),
            ("https://shop.az/p?sessionId=1&PHPSESSID=2&sid=3&otp=4&x=1", "https://shop.az/p?x=1"),
            ("https://shop.az/p?phone=1&tel=2&msisdn=3&mobile=456&card=5&pan=6&iban=7&fin=8&email=9&x=1", "https://shop.az/p?x=1"),
            ("https://shop.az/p?X-Amz-Signature=abc&X-Amz-Credential=def&key=1&x=1", "https://shop.az/p?x=1"),
            // Qısa sözlər yalnız bütöv söz kimi tutulur: adi adlar qalır.
            ("https://shop.az/p?inside=1&hotel=2&company=3&keyword=shoes&design=4&final=5&pinned=6",
             "https://shop.az/p?inside=1&hotel=2&company=3&keyword=shoes&design=4&final=5&pinned=6"),
            // UTM və klik ID-ləri qalır.
            ("https://shop.az/p?utm_source=fb&utm_campaign=code_red&gclid=G1&fbclid=F1&msclkid=M1",
             "https://shop.az/p?utm_source=fb&utm_campaign=code_red&gclid=G1&fbclid=F1&msclkid=M1"),
            // `;` ayırıcısı, mötərizəli və faizlə kodlanmış adlar.
            ("https://shop.az/p?a=1;token=zz;b=2", "https://shop.az/p?a=1;b=2"),
            ("https://shop.az/p?user%5Bemail%5D=x&pass%77ord=1&%2574oken=2&ok=1", "https://shop.az/p?ok=1"),
            // Dəyəri ünvan olan parametr eyni qaydalarla təmizlənir.
            ("https://shop.az/r?next=https%3A%2F%2Fa.az%2Fcb%3Ftoken%3Dabc%26x%3D1&y=2", "https://shop.az/r?next=https%3A%2F%2Fa.az%2Fcb%3Fx%3D1&y=2"),
            ("https://shop.az/r?next=%2Freset%3Fcode%3D123%26lang%3Daz", "https://shop.az/r?next=%2Freset%3Flang%3Daz"),
            ("https://shop.az/r?next=https%3A%2F%2Fa.az%2Fhome", "https://shop.az/r?next=https%3A%2F%2Fa.az%2Fhome"),
            // Dəyəri JWT olan parametrin adı qalır, dəyəri gizlədilir; başqa «sirrə oxşayan» dəyərlərə toxunulmur.
            ("https://shop.az/p?state=" + jwt + "&x=1", "https://shop.az/p?state=[redacted]&x=1"),
            ("https://shop.az/p?order=1234567890123&ref=0123456789abcdef0123456789ABCDEF",
             "https://shop.az/p?order=1234567890123&ref=[redacted]"),
            // Yolun sirrə oxşayan hissələri.
            ("https://shop.az/reset/" + jwt + "/done", "https://shop.az/reset/[redacted]/done"),
            ("https://shop.az/u/0123456789abcdef0123456789ABCDEF", "https://shop.az/u/[redacted]"),
            ("https://shop.az/o/994501234567", "https://shop.az/o/994501234567"),
            // Sirr sözü olan hissədən (reset, verify, otp …) sonrakı hissə daha sərt yoxlanır.
            ("https://shop.az/verify/994501234567", "https://shop.az/verify/[redacted]"),
            ("https://shop.az/reset-password/9f8a7b6c5d4e/done", "https://shop.az/reset-password/[redacted]/done"),
            ("https://shop.az/reset/summer-sale-2026", "https://shop.az/reset/summer-sale-2026"),
            ("https://shop.az/card/4111111111111111", "https://shop.az/card/[redacted]"),
            ("https://shop.az/o/%2B994501234567/x", "https://shop.az/o/[redacted]/x"),
            ("https://shop.az/t/dGhpcyBpcyBhIHNlY3JldCB0b2tlbiB2YWx1ZSAxMjM0NTY3ODkw", "https://shop.az/t/[redacted]"),
            // Adi slug-lar, tirelərlə UUID və qısa ədədi ID-lər qalır.
            ("https://shop.az/blog/my-great-post-2024", "https://shop.az/blog/my-great-post-2024"),
            ("https://shop.az/item/550e8400-e29b-41d4-a716-446655440000", "https://shop.az/item/550e8400-e29b-41d4-a716-446655440000"),
            ("https://shop.az/order/123456789", "https://shop.az/order/123456789"),
            ("https://shop.az/kateqoriya/yeni-mehsullar-2026-qis-kolleksiyasi-endirimler-burada",
             "https://shop.az/kateqoriya/yeni-mehsullar-2026-qis-kolleksiyasi-endirimler-burada"),
            // Böyük və kiçik hərf, rəqəm qarışıq, ayırıcısı az olan 32+ simvolluq hissə base64url token sayılır.
            ("https://shop.az/Kateqoriya/Yeni-Mehsullar-2026-Qis-Kolleksiyasi-Endirimler-Burada", "https://shop.az/Kateqoriya/[redacted]"),
            // Hash marşrutu yol kimi təmizlənir, başqa fraqment atılır.
            ("myapp://open#/reset/9f8a7b6c5d4e?token=1&tab=2", "myapp://open#/reset/[redacted]?tab=2"),
            // İstifadəçi adı / parol, fraqment, e-poçt.
            ("https://user:pw@shop.az/a?x=1#frag", "https://shop.az/a?x=1"),
            ("myapp://open/a@b.az/x?m=c%40d.com", "myapp://open/[redacted]/x?m=[redacted]"),
            ("myapp://product/42?ref=home", "myapp://product/42?ref=home"),
        ]
        for (input, expected) in vectors { XCTAssertEqual(Util.cleanUrl(input), expected, input) }
        // Konfiqin `strip_params` siyahısı da tətbiq olunur.
        XCTAssertEqual(Util.cleanUrl("https://shop.az/p?Ref=1&b=2", extraStrip: ["ref"]), "https://shop.az/p?b=2")
        // Təmizləmə təkrar tətbiq olunanda nəticə dəyişmir.
        for (_, expected) in vectors { XCTAssertEqual(Util.cleanUrl(expected), expected, expected) }
    }

    func testClickIdStrippingKnowsNewIdsAndSeparators() {
        XCTAssertEqual(Util.stripClickIds("https://shop.az/p?a=1&dclid=D&utm_source=fb&twclid=T&yclid=Y&li_fat_id=L"), "https://shop.az/p?a=1&utm_source=fb")
        XCTAssertEqual(Util.stripClickIds("https://shop.az/p?a=1;GCLID=G;b=2#/x"), "https://shop.az/p?a=1;b=2#/x")
        XCTAssertEqual(Util.stripClickIds("https://shop.az/p?gclid=G"), "https://shop.az/p")
        // İç-içə ünvanlardan (iki səviyyə), hash marşrutunun query-sindən və matris parametrlərindən də çıxır.
        XCTAssertEqual(
            Util.stripClickIds("https://shop.az/p;gclid=M;v=2?r=https%3A%2F%2Fb.az%2F%3Fgclid%3DN%26a%3D1#/list?ttclid=T&tab=1"),
            "https://shop.az/p;v=2?r=https%3A%2F%2Fb.az%2F%3Fa%3D1#/list?tab=1"
        )
    }

    func testDeepLinkEventCarriesSanitisedUrl() {
        let rig = AuditRig(granted)
        let core = rig.core()
        core.onDeepLink("https://shop.az/reset/" + jwt + "?auth_code=1&utm_source=fb&gclid=G1")
        core.flush(force: true)
        XCTAssertEqual(dict(rig.event("DeepLinkOpen")["props"])["url"] as? String, "https://shop.az/reset/[redacted]?utm_source=fb&gclid=G1")
    }

    // MARK: - 15. Şəxsi məlumat

    func testPiiKeysAreMatchedByPattern() {
        let mail = ["email", "Email", "E-Mail", "user_email", "contactEmail", "e_mail", "MAIL", "mailAddress"]
        let phone = ["phone", "Phone_Number", "phoneNumber", "msisdn", "MSISDN", "mobile", "userMobile", "tel", "Tel", "home_tel"]
        let forbidden = [
            "password", "Password", "pass", "card", "card_number", "cardNumber", "CVV", "pin", "PIN", "fin", "FIN", "token", "accessToken",
        ]
        // Sirr hissəsi olan adlar (dəqiq siyahıda olmayanlar) dəyər bayraq olanda saxlanır (`has_password: true`).
        let secretParts = ["user_password", "passwd", "pwd", "passport", "passportNo", "cvc", "iban", "IBAN_no", "secret", "has_cvv"]
        let allowed = [
            "value", "currency", "order_id", "passengers", "hotel", "final_price", "pinned", "finish", "telemetry", "title",
            "name", "plan", "", "card_type", "tokens", "smartphone", "token_count", "phone_model", "gift_card", "pin_color",
        ]
        // E-poçt / telefon adlı açar yalnız dəyər bayraq (true / false / nil) olmayanda atılır (veb tracker ilə eyni
        // qayda); dəqiq `email` / `phone` açarları və sirr adları dəyərdən asılı olmayaraq atılır.
        let exact: Set<String> = ["email", "phone"]
        let flags: [Any?] = [true, false, nil, NSNull()]
        for key in mail + phone {
            XCTAssertTrue(Util.forbiddenKey(key, "x"), key)
            XCTAssertTrue(Util.forbiddenKey(key, 5_000_000), key)
            for flag in flags { XCTAssertEqual(Util.forbiddenKey(key, flag), exact.contains(key.lowercased()), key) }
        }
        let values: [Any?] = ["x", true, nil]
        for key in forbidden { for value in values { XCTAssertTrue(Util.forbiddenKey(key, value), key) } }
        for key in secretParts {
            XCTAssertTrue(Util.forbiddenKey(key, "x"), key)
            XCTAssertTrue(Util.forbiddenKey(key, 5), key)
            for flag in flags { XCTAssertFalse(Util.forbiddenKey(key, flag), key) }
        }
        for key in allowed { XCTAssertFalse(Util.forbiddenKey(key, "x"), key) }
        // Qısa çoxmənalı sözlər (adın son sözü kimi) yalnız dəyər bayraq olmayanda atılır.
        for key in ["otp", "sms_otp", "ssn", "auth", "session", "cookie"] {
            XCTAssertTrue(Util.forbiddenKey(key, "x"), key)
            XCTAssertTrue(Util.forbiddenKey(key, 482913), key)
            for flag in flags { XCTAssertFalse(Util.forbiddenKey(key, flag), key) }
        }
        // `*_sha256` açarı yalnız 64 simvolluq hex dəyərlə saxlanır; başqa dəyərdə ad sonluqsuz yoxlanır.
        let hash = String(repeating: "ab", count: 32)
        let kept = Util.cleanObject(["email_sha256": hash, "Email-SHA256": hash, "phone_sha256": "+994501234567", "password_sha256": "hunter2"]) ?? [:]
        XCTAssertEqual(Set(kept.keys), ["email_sha256", "Email-SHA256"])
        // Kiçik ədəd sayğacdır (emails_sent: 5), bayraq dəyəri olan çoxmənalı açar qalır.
        XCTAssertFalse(Util.forbiddenKey("emails_sent", 5))
        XCTAssertFalse(Util.forbiddenKey("otp_sent", true))
        XCTAssertTrue(Util.forbiddenKey("user_otp", "482913"))
    }

    func testPropsDropPiiKeysAtAllDepthsAndRedactEmailValues() {
        let rig = AuditRig()
        let core = rig.core()
        let nested: [String: Any] = [
            "phoneNumber": "+994501234567",
            "deep": ["card-number": "4111"],
            "list": [["Otp": 1, "keep": "x@y.com"] as [String: Any]],
        ]
        let props: [String: Any?] = [
            "value": 5,
            "User_Email": "a@b.az",
            "note": "contact a@b.az now",
            "nul\u{0}l": "ok",
            "pass\u{0}word": "secret-after-nul-strip",
            "nested": nested,
        ]
        core.track("Lead", props: props, eventId: "bad id!")
        core.flush(force: true)
        let lead = rig.event("Lead")
        let sent = dict(lead["props"])
        XCTAssertEqual(sent["value"] as? Int, 5)
        XCTAssertNil(sent["User_Email"])
        XCTAssertEqual(sent["note"] as? String, "contact [redacted] now")
        XCTAssertEqual(sent["null"] as? String, "ok")
        XCTAssertNil(sent["password"], "NUL silinəndən sonra yoxlanır")
        let inner = dict(sent["nested"])
        XCTAssertNil(inner["phoneNumber"])
        XCTAssertTrue(dict(inner["deep"]).isEmpty)
        let item = (inner["list"] as? [[String: Any]])?.first ?? [:]
        XCTAssertNil(item["Otp"])
        XCTAssertEqual(item["keep"] as? String, "[redacted]")
        XCTAssertFalse(rig.transport.raw.joined().contains("a@b.az"))
        // Atılan açarlar və yararsız eventId sazlama loquna yazılır; yararsız ID yerinə UUID gedir.
        XCTAssertTrue(rig.env.logs.contains { $0.contains("dropped forbidden key: User_Email") })
        XCTAssertTrue(rig.env.logs.contains { $0.contains("invalid eventId") })
        XCTAssertTrue(Util.isValidId(lead["id"] as? String ?? ""))
        XCTAssertNotEqual(lead["id"] as? String, "bad id!")
    }

    func testTraitsHashEmailAndPhoneUnderAnyKeySpelling() {
        let email = "5112b461d32844f6fc0ea92e45d08556471d1e9425bb23cffdb2f27898375f5b"
        let phone = "6878509fec498b26fdbf7db3495a7e4e0bceda9e9170b399baff6de3d933ba77"
        let spellings = [("email", "phone"), ("E-Mail", "Phone_Number"), ("userEmail", "msisdn"), ("contact_mail", "mobile"), ("MAIL", "tel")]
        for (mailKey, phoneKey) in spellings {
            let rig = AuditRig()
            let core = rig.core()
            // spec/vectors/hashing.json girişləri.
            core.identify("user-1", traits: [mailKey: "  A@B.az ", phoneKey: "+994 (50) 123-45-67", "plan": "pro", "bio": "me: x@y.com"])
            core.flush(force: true)
            let identify = rig.transport.events.first { ($0["type"] as? String) == "identify" } ?? [:]
            let traits = dict(identify["traits"])
            XCTAssertEqual(traits["email_sha256"] as? String, email, mailKey)
            XCTAssertEqual(traits["phone_sha256"] as? String, phone, phoneKey)
            XCTAssertEqual(Set(traits.keys), ["email_sha256", "phone_sha256", "plan", "bio"])
            XCTAssertEqual(traits["bio"] as? String, "me: [redacted]")
        }
        // Artıq hash olunmuş dəyər toxunulmaz ötürülür.
        let rig = AuditRig()
        let core = rig.core()
        core.identify("user-1", traits: ["email_sha256": String(repeating: "ab", count: 32)])
        core.flush(force: true)
        let identify = rig.transport.events.first { ($0["type"] as? String) == "identify" } ?? [:]
        XCTAssertEqual(dict(identify["traits"])["email_sha256"] as? String, String(repeating: "ab", count: 32))
    }

    func testEmailOrPhoneShapedUserIdIsHashed() {
        let cases: [(String, String)] = [
            ("  User@Example.COM ", Util.sha256("user@example.com")),
            ("a@b.az", Util.sha256("a@b.az")),
            ("+994 (50) 123-45-67", Util.sha256("994501234567")),
            ("+994501234567", Util.sha256("994501234567")),
            ("050.123.45.67", Util.sha256("0501234567")),
            ("012345678", Util.sha256("012345678")),
            ("050 123 45 67", Util.sha256("0501234567")),
            ("994501234567", Util.sha256("994501234567")),
            // Adi ID-lər olduğu kimi qalır: qısa ədədlər, hərfli ID-lər, UUID.
            ("user-42", "user-42"),
            ("1234567", "1234567"),
            ("123456789", "123456789"),
            ("u_994501234567", "u_994501234567"),
            ("550e8400-e29b-41d4-a716-446655440000", "550e8400-e29b-41d4-a716-446655440000"),
            ("@handle", "@handle"),
            ("12345678901234567890", "12345678901234567890"),
        ]
        for (input, expected) in cases {
            let rig = AuditRig()
            let core = rig.core()
            core.identify(input, traits: nil)
            core.track("Lead", props: nil, eventId: nil)
            core.flush(force: true)
            XCTAssertEqual(rig.event("Lead")["user_id"] as? String, expected, input)
            XCTAssertEqual(rig.store.map[Core.Keys.user], expected, input)
            if expected != input {
                XCTAssertFalse(rig.transport.raw.joined().contains(input.trimmingCharacters(in: .whitespaces)), input)
                XCTAssertTrue(rig.env.logs.contains { $0.contains("its sha256 is sent instead") })
            }
        }
        XCTAssertEqual(Util.sha256("user@example.com"), "b4c9a289323b21a01c3e940f150eb9b8c542587f1abfd8f0e1cc1ffc5e475514")
    }

    // MARK: - 16. ATT icazəsi olmadan toplu reklama yararsızdır

    func testWithoutTrackingAuthorizationNothingAdRelatedLeavesTheDevice() {
        let idfa = "EA7583CD-A667-48BC-B806-42ECB2B48606"
        for status in ["denied", "restricted", "not_determined"] {
            // Reklam razılığı verilib, amma iOS 14+-da izləmə icazəsi yoxdur.
            let rig = AuditRig(granted)
            rig.env.attNeeded = true
            rig.env.attStatus = status
            rig.env.idfa = idfa
            let core = rig.core()
            core.onDeepLink("https://shop.az/p?utm_source=fb&gclid=GVAL9&fbclid=FVAL9")
            core.identify("user-1", traits: ["email": "a@b.az"])
            core.track("Purchase", props: ["value": 1], eventId: nil)
            core.flush(force: true)

            XCTAssertFalse(rig.transport.posts.isEmpty)
            for post in rig.transport.posts {
                let ctx = dict(post["ctx"])
                XCTAssertEqual(adsFlag(ctx), false, status)
                XCTAssertEqual(dict(ctx["consent"])["analytics"] as? Bool, true)
                XCTAssertEqual(Set(dict(ctx["ids"]).keys), ["att"], status)
                XCTAssertEqual(dict(ctx["ids"])["att"] as? String, status)
                for id in Util.clickIds { XCTAssertNil(dict(ctx["campaign"])[id], id) }
            }
            let sent = rig.transport.raw.joined()
            XCTAssertFalse(sent.contains(idfa), status)
            XCTAssertFalse(sent.contains("6D92078A"), "IDFV göndərilmir")
            XCTAssertFalse(sent.contains("GVAL9"), status)
            XCTAssertFalse(sent.contains("FVAL9"), status)
            XCTAssertEqual(dict(rig.ctx(of: "Purchase")["campaign"])["utm_source"] as? String, "fb", "UTM qalır")
            // Klik ID-ləri diskə də yazılmır: icazə sonradan veriləndə üzə çıxmır.
            XCTAssertFalse((rig.store.map[Core.Keys.campaign] ?? "").contains("GVAL9"))

            // İcazə verildi: yalnız bundan sonra yaranan eventlər reklama yararlıdır; köhnələr yüksəldilmir.
            rig.transport.status = 500
            core.track("QueuedWhileDenied", props: nil, eventId: nil)
            core.flush(force: true)
            rig.env.attStatus = "authorized"
            rig.transport.status = 200
            rig.env.time += 2 * Core.backoffMaxMs
            core.track("AfterAuthorization", props: nil, eventId: nil)
            core.flush(force: true)
            XCTAssertEqual(adsFlag(rig.ctx(of: "QueuedWhileDenied")), false)
            XCTAssertNil(dict(rig.ctx(of: "QueuedWhileDenied")["ids"])["idfv"])
            let after = rig.ctx(of: "AfterAuthorization")
            XCTAssertEqual(adsFlag(after), true)
            XCTAssertEqual(dict(after["ids"])["idfa"] as? String, idfa)
            XCTAssertNotNil(dict(after["ids"])["idfv"])
        }
    }

    // MARK: - 18–20. Vaxt, təkrar initialize, AppInstall

    func testAppOpenIsRecordedBeforeTheConfigFetchWithTheNotificationTime() {
        let rig = AuditRig(granted)
        let core = rig.core()
        var queuedAtFetch: [String] = []
        rig.transport.onConfig = { queuedAtFetch = rig.queued }
        let notified = rig.env.time
        rig.env.time += 20_000
        core.onForeground(at: notified)
        XCTAssertTrue(queuedAtFetch.contains("AppOpen"))
        core.flush(force: true)
        XCTAssertEqual(rig.event("AppOpen")["ts"] as? String, Util.iso(notified))
    }

    func testRepeatedInitializeOnlyTightens() {
        let rig = AuditRig(granted)
        rig.env.attNeeded = true
        rig.env.attStatus = "authorized"
        rig.env.idfa = "EA7583CD-A667-48BC-B806-42ECB2B48606"
        let core = rig.core()

        // Daha yumşaq seçimlər heç nəyi dəyişmir.
        core.restrict(consent: SmartBeeConsent(analytics: true, ads: true), collectAdvertisingId: true)
        core.restrict(consent: nil, collectAdvertisingId: true)
        core.track("Open", props: nil, eventId: nil)
        core.flush(force: true)
        XCTAssertNotNil(dict(rig.ctx(of: "Open")["ids"])["idfa"])

        core.restrict(consent: nil, collectAdvertisingId: false)
        let reads = rig.env.adCalls
        core.track("NoAdId", props: nil, eventId: nil)
        core.flush(force: true)
        XCTAssertNil(rig.ctx(of: "NoAdId")["ids"])
        XCTAssertEqual(adsFlag(rig.ctx(of: "NoAdId")), false, "icazə oxunmur: iOS 14+-da toplu reklama yararsızdır")
        XCTAssertEqual(rig.env.adCalls, reads, "söndürüləndən sonra sistemdən heç nə oxunmur")

        core.restrict(consent: SmartBeeConsent(analytics: true, ads: false), collectAdvertisingId: true)
        core.restrict(consent: SmartBeeConsent(analytics: true, ads: true), collectAdvertisingId: true)
        core.track("NoAds", props: nil, eventId: nil)
        core.flush(force: true)
        XCTAssertEqual(adsFlag(rig.ctx(of: "NoAds")), false)

        core.restrict(consent: SmartBeeConsent(analytics: false, ads: true), collectAdvertisingId: true)
        XCTAssertNil(core.anonymousId)
        core.track("Denied", props: nil, eventId: nil)
        XCTAssertEqual(rig.queue.count, 0)
        let calls = rig.transport.configCalls
        core.refreshConfig(force: true)
        XCTAssertEqual(rig.transport.configCalls, calls)
    }

    func testAppInstallIsEvaluatedWhenConsentIsGrantedLater() {
        let rig = AuditRig(SmartBeeOptions(consent: SmartBeeConsent(analytics: false, ads: false), debug: true))
        let core = rig.core()
        XCTAssertEqual(rig.queue.count, 0)
        core.setConsent(analytics: true, ads: true)
        XCTAssertEqual(rig.queued.filter { $0 == "AppInstall" }.count, 1)
        // Yenə yalnız bir dəfə.
        core.setConsent(analytics: false, ads: false)
        core.setConsent(analytics: true, ads: true)
        core.flush(force: true)
        XCTAssertEqual(rig.transport.names.filter { $0 == "AppInstall" }.count, 0)
    }

    // MARK: - 19, 22. Açıq API

    func testPublicOptionsHaveNoWrapperAndSdkVersionIsExposed() {
        let options = SmartBeeOptions(consent: SmartBeeConsent(analytics: true, ads: false), debug: true, collectAdvertisingId: false)
        XCTAssertNil(options.wrapper)
        XCTAssertEqual(options.consent, SmartBeeConsent(analytics: true, ads: false))
        XCTAssertEqual(options.endpoint, defaultEndpoint)
        XCTAssertEqual(SmartBee.sdkVersion, pixelSdkVersion)
        XCTAssertNotNil(Util.semver(SmartBee.sdkVersion))
        XCTAssertEqual(Util.wrapperName("flutter"), "flutter")
        XCTAssertNil(Util.wrapperName("Not Valid"))
        XCTAssertEqual(Util.wrapperVersion(String(repeating: "v", count: 100))?.count, 32)
        XCTAssertNil(Util.wrapperVersion("  "))
    }

    func testLaunchGatePassesTheNotificationTime() {
        let rig = AuditRig(granted)
        let core = rig.core()
        let gate = LaunchGate()
        let notified = rig.env.time - 7_000
        let call = gate.foreground(at: notified)
        call(core)
        core.flush(force: true)
        XCTAssertEqual(rig.event("AppOpen")["ts"] as? String, Util.iso(notified))

        // Tətbiq nüvə başlamamış arxa fona keçibsə gözləyən ön plan keçidi icra olunmur.
        let stale = gate.foreground(at: notified)
        gate.leftBeforeStart()
        stale(core)
        core.flush(force: true)
        XCTAssertEqual(rig.transport.names.filter { $0 == "AppOpen" }.count, 1)
    }
}
