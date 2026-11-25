import Foundation
import XCTest
@testable import SmartBeePixel

private let key = "demo0ios01"

private final class FakeStore: Store {
    var map: [String: String] = [:]
    func get(_ key: String) -> String? { return map[key] }
    func put(_ key: String, _ value: String) { map[key] = value }
    func remove(_ key: String) { map[key] = nil }
}

private final class FakeQueue: EventQueue {
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

private final class FakeTransport: Transport {
    var raw: [String] = []
    var urls: [String] = []
    var status = 200
    var retryAfter: Int64?
    var configStatus = 200
    var configBody: String?
    var configEtag: String? = "W/\"1\""
    var configCalls = 0
    var lastEtag: String?
    /// Verilibsə cavab statusunu toplunun özünə görə təyin edir; rədd olunan toplular `raw`-a düşmür.
    var respond: (([String: Any]) -> Int)?
    /// Rədd cavabının gövdəsi (toplu və konfiq sorğuları üçün).
    var postError: String?
    var configError: String?

    func post(url: String, json: String) -> HttpResult {
        urls.append(url)
        var code = status
        if let respond = respond { code = respond(Util.parseObject(json) ?? [:]) }
        if respond == nil || (code >= 200 && code <= 299) { raw.append(json) }
        return HttpResult(status: code, body: (code >= 200 && code <= 299) ? nil : postError, retryAfterSec: retryAfter)
    }

    func get(url: String, etag: String?) -> HttpResult {
        configCalls += 1
        lastEtag = etag
        urls.append(url)
        return HttpResult(status: configStatus, body: configStatus == 200 ? configBody : configError, etag: configEtag)
    }

    var posts: [[String: Any]] { return raw.compactMap { Util.parseObject($0) } }
    var events: [[String: Any]] { return posts.flatMap { $0["events"] as? [[String: Any]] ?? [] } }
    var names: [String] {
        return events.map { ($0["type"] as? String) == "track" ? ($0["name"] as? String ?? "?") : ($0["type"] as? String ?? "?") }
    }
}

private final class FakeEnv: Env {
    var time: Int64 = 1_795_590_000_000
    var version = "1.2.3"
    var build = "45"
    private var counter = 0
    var logs: [String] = []
    /// ATT vəziyyəti və IDFA; susmaya görə heç biri yoxdur (köhnə testlərin konteksti dəyişmir).
    var attStatus: String?
    var idfa: String?
    /// `advertising` çağırışlarının `includeId` dəyərləri.
    var adCalls: [Bool] = []
    /// true: sistem izləmə üçün ATT icazəsi tələb edir (iOS 14+). Susmaya görə iOS 13 kimi davranır.
    var attNeeded = false
    /// Fasilələrin kənarlaşması: 0.0 ən qısa fasiləni verir (Retry-After dəqiq, backoff -20%).
    var randomValue = 0.0

    func attRequired() -> Bool { return attNeeded }
    func random() -> Double { return randomValue }

    func advertising(includeId: Bool) -> AdvertisingInfo {
        adCalls.append(includeId)
        // Saxta mühit identifikatoru həmişə qaytarır: onu göndərib-göndərməməyi Core özü həll etməlidir.
        return AdvertisingInfo(status: attStatus, idfa: idfa)
    }

    func now() -> Int64 { return time }
    func uuid() -> String {
        counter += 1
        let tail = String(counter)
        return "00000000-0000-4000-8000-" + String(repeating: "0", count: 12 - tail.count) + tail
    }
    func log(_ message: String) { logs.append(message) }
    func deviceContext() -> [String: Any] {
        return [
            "locale": "az-AZ", "tz": "Asia/Baku",
            "screen": ["w": 1179, "h": 2556, "density": 3.0],
            "app": ["id": "az.smartbee.demo", "version": version, "build": build],
            "os": ["name": "iOS", "version": "18.1"],
            "device": ["manufacturer": "Apple", "model": "iPhone16,1", "type": "phone"],
            "ids": ["idfv": "6D92078A-8246-4BA4-AE5B-76104861E7DC"],
        ]
    }
}

/// Susmaya görə konfiq artıq bir dəfə alınıb keşlənmiş tətbiqi təqlid edir.
/// `fresh = true`: ilk işə düşmə, konfiq hələ heç vaxt alınmayıb.
private final class Rig {
    let store = FakeStore()
    let queue = FakeQueue()
    let transport = FakeTransport()
    let env = FakeEnv()
    let gate = ConsentGate()
    var options: SmartBeeOptions

    init(_ options: SmartBeeOptions = SmartBeeOptions(debug: true), fresh: Bool = false) {
        self.options = options
        if !fresh {
            // Keş açara və ünvana bağlıdır: bağlantısız konfiq başqa açarın konfiqi sayılıb atılardı.
            store.map[Core.Keys.binding] = Core.binding(key: key, endpoint: options.endpoint)
            store.map[Core.Keys.config] = "{\"enabled\":true}"
        }
    }

    func core() -> Core {
        let core = Core(key: key, options: options, store: store, queue: queue, transport: transport, env: env, gate: gate)
        core.start()
        return core
    }
}

final class CoreTests: XCTestCase {
    /// Göndərilən toplular CI-da ortaq JSON sxemi ilə yoxlanmaq üçün fayla yazılır.
    fileprivate static var dumped: [String] = []

    private func keep(_ rig: Rig) {
        CoreTests.dumped.append(contentsOf: rig.transport.raw)
    }

    override class func tearDown() {
        if let path = ProcessInfo.processInfo.environment["SB_DUMP_FILE"], !dumped.isEmpty {
            try? dumped.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        super.tearDown()
    }

    private var specDir: URL {
        // mobile/ios/Tests/SmartBeePixelTests/CoreTests.swift -> repo kökü
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("spec")
    }

    private func dict(_ value: Any?) -> [String: Any] { return value as? [String: Any] ?? [:] }

    func testFirstStartSendsInstallAndWellFormedBatch() {
        let rig = Rig()
        let core = rig.core()
        core.track("Purchase", props: ["value": 250, "currency": "AZN", "contents": [["id": "p1", "quantity": 2]]], eventId: "order:A-1001")
        core.flush(force: true)
        keep(rig)

        XCTAssertEqual(rig.transport.posts.count, 1)
        let batch = rig.transport.posts[0]
        XCTAssertEqual(rig.transport.urls.last, "https://c.cdnsb.net/v1/e")
        XCTAssertEqual(batch["v"] as? Int, 1)
        XCTAssertEqual(batch["key"] as? String, key)
        XCTAssertEqual(dict(batch["sdk"])["name"] as? String, "ios")
        XCTAssertEqual(batch["sent_at"] as? String, "2026-11-25T07:00:00.000Z")
        let ctx = dict(batch["ctx"])
        XCTAssertEqual(ctx["platform"] as? String, "ios")
        XCTAssertEqual(dict(ctx["app"])["id"] as? String, "az.smartbee.demo")
        XCTAssertEqual(dict(ctx["consent"])["analytics"] as? Bool, true)
        XCTAssertEqual(dict(ctx["ids"])["idfv"] as? String, "6D92078A-8246-4BA4-AE5B-76104861E7DC")
        XCTAssertEqual(rig.transport.names, ["SessionStart", "AppInstall", "Purchase"])

        let purchase = rig.transport.events[2]
        XCTAssertEqual(purchase["id"] as? String, "order:A-1001")
        XCTAssertEqual(dict(purchase["props"])["value"] as? Int, 250)
        XCTAssertNil(purchase["origin"])
        XCTAssertEqual(rig.transport.events[0]["origin"] as? String, "auto")
        let seqs = rig.transport.events.compactMap { $0["seq"] as? Int }
        XCTAssertEqual(seqs, seqs.sorted())
        XCTAssertEqual(seqs.count, 3)
        XCTAssertEqual(rig.queue.count, 0)
    }

    func testSecondStartHasNoInstallAndVersionChangeSendsUpdate() {
        let rig = Rig()
        rig.core().flush(force: true)
        rig.transport.raw.removeAll()

        rig.core().flush(force: true)
        XCTAssertEqual(rig.transport.names, [])

        rig.env.version = "1.3.0"
        rig.env.build = "46"
        rig.core().flush(force: true)
        keep(rig)
        XCTAssertEqual(rig.transport.names, ["AppUpdate"])
        let props = dict(rig.transport.events[0]["props"])
        XCTAssertEqual(props["previous_version"] as? String, "1.2.3")
        XCTAssertEqual(props["previous_build"] as? String, "45")
    }

    func testIdentityAndSessionPersistAndSessionExpires() {
        let rig = Rig()
        let first = rig.core()
        first.track("Lead", props: nil, eventId: nil)
        let second = rig.core()
        second.track("Lead", props: nil, eventId: nil)
        rig.env.time += 31 * 60_000
        second.track("Lead", props: nil, eventId: nil)
        second.flush(force: true)
        keep(rig)

        let leads = rig.transport.events.filter { ($0["name"] as? String) == "Lead" }
        XCTAssertEqual(leads.count, 3)
        XCTAssertEqual(leads[0]["anon_id"] as? String, leads[1]["anon_id"] as? String)
        XCTAssertEqual(leads[0]["session_id"] as? String, leads[1]["session_id"] as? String)
        XCTAssertNotEqual(leads[1]["session_id"] as? String, leads[2]["session_id"] as? String)
        XCTAssertEqual(rig.transport.names.filter { $0 == "SessionStart" }.count, 2)
        XCTAssertEqual(first.anonymousId, second.anonymousId)
    }

    func testPropsAreSanitized() {
        let rig = Rig()
        let core = rig.core()
        let props: [String: Any?] = [
            "email": "a@b.az", "Password": "x", "nan": Double.nan, "object": NSObject(), "nothing": nil, "flag": true, "count": 3,
            "nested": ["phone": "1", "ok": 1, "deep": ["a": ["b": ["c": 1]]]],
            "list": [1, ["token": "t", "keep": true]],
        ]
        core.track("Lead", props: props, eventId: nil)
        core.flush(force: true)
        keep(rig)

        let out = dict(rig.transport.events.last?["props"])
        XCTAssertEqual(Set(out.keys), ["nested", "list", "nothing", "flag", "count"])
        XCTAssertTrue(out["nothing"] is NSNull)
        XCTAssertEqual(out["flag"] as? Bool, true)
        XCTAssertEqual(out["count"] as? Int, 3)
        let nested = dict(out["nested"])
        XCTAssertEqual(Set(nested.keys), ["ok", "deep"])
        XCTAssertEqual(dict(dict(nested["deep"])["a"]).count, 0)
        let list = out["list"] as? [Any] ?? []
        XCTAssertEqual(Set(dict(list.last).keys), ["keep"])
        XCTAssertTrue(rig.transport.raw[0].contains("\"flag\":true"))
        XCTAssertTrue(rig.transport.raw[0].contains("\"count\":3"))
    }

    func testInvalidNamesBlockedAndOversizedEventsAreDropped() {
        let rig = Rig()
        rig.store.put(Core.Keys.config, "{\"enabled\":true,\"blocked_events\":[\"Search\"]}")
        let core = rig.core()
        core.track("my event!", props: nil, eventId: nil)
        core.track("", props: nil, eventId: nil)
        core.track(nil, props: nil, eventId: nil)
        core.track("Search", props: nil, eventId: nil)
        core.track("Lead", props: ["blob": String(repeating: "x", count: 40_000)], eventId: nil)
        core.track("Contact", props: nil, eventId: "bad id with spaces")
        core.flush(force: true)
        keep(rig)
        XCTAssertEqual(rig.transport.names, ["SessionStart", "AppInstall", "Contact"])
        XCTAssertTrue((rig.transport.events.last?["id"] as? String ?? "").hasPrefix("00000000-"))
    }

    func testIdentifyHashesEmailAndPhoneUsingSpecVectors() throws {
        let data = try Data(contentsOf: specDir.appendingPathComponent("vectors/hashing.json"))
        let vectors = dict(try JSONSerialization.jsonObject(with: data, options: []))
        let emails = vectors["email"] as? [[String: Any]] ?? []
        let phones = vectors["phone"] as? [[String: Any]] ?? []
        XCTAssertFalse(emails.isEmpty)
        XCTAssertEqual(emails.count, phones.count)
        for index in emails.indices {
            let rig = Rig()
            let core = rig.core()
            core.identify("user-42", traits: ["email": emails[index]["input"], "phone": phones[index]["input"], "plan": "pro"])
            core.track("Lead", props: nil, eventId: nil)
            core.flush(force: true)
            keep(rig)
            let identify = rig.transport.events.first { ($0["type"] as? String) == "identify" } ?? [:]
            let traits = dict(identify["traits"])
            XCTAssertEqual(Set(traits.keys), ["plan", "email_sha256", "phone_sha256"])
            XCTAssertEqual(traits["email_sha256"] as? String, emails[index]["sha256"] as? String)
            XCTAssertEqual(traits["phone_sha256"] as? String, phones[index]["sha256"] as? String)
            XCTAssertEqual(rig.transport.events.last?["user_id"] as? String, "user-42")
            let normalized = emails[index]["normalized"] as? String ?? "missing"
            XCTAssertFalse(rig.transport.raw.joined().contains(normalized))
        }
    }

    func testInvalidUserIdIsIgnored() {
        let rig = Rig()
        let core = rig.core()
        core.identify("", traits: nil)
        core.identify(nil, traits: nil)
        core.identify(String(repeating: "x", count: 129), traits: nil)
        core.flush(force: true)
        XCTAssertFalse(rig.transport.names.contains("identify"))
    }

    func testWithoutAnalyticsConsentNothingIsSentOrStored() {
        let rig = Rig(SmartBeeOptions(consent: SmartBeeConsent(analytics: false, ads: false)))
        let core = rig.core()
        core.track("Lead", props: nil, eventId: nil)
        core.identify("user-1", traits: nil)
        core.onForeground()
        core.onDeepLink("myapp://open?utm_source=fb")
        core.flush(force: true)
        XCTAssertEqual(rig.transport.raw.count, 0)
        XCTAssertEqual(rig.queue.count, 0)
        XCTAssertNil(core.anonymousId)
        XCTAssertNil(rig.store.get(Core.Keys.anon))
        XCTAssertNil(rig.store.get(Core.Keys.user))
        XCTAssertNil(rig.store.get(Core.Keys.campaign))

        core.setConsent(analytics: true, ads: nil)
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        keep(rig)
        XCTAssertTrue(rig.transport.names.contains("Lead"))
        XCTAssertEqual(core.anonymousId, rig.store.get(Core.Keys.anon))
    }

    func testRevokingConsentClearsQueueAndIdentityAndIsRemembered() {
        let rig = Rig()
        let core = rig.core()
        core.identify("user-1", traits: nil)
        core.track("Lead", props: nil, eventId: nil)
        core.setConsent(analytics: false, ads: false)
        XCTAssertEqual(rig.queue.count, 0)
        XCTAssertNil(rig.store.get(Core.Keys.anon))
        XCTAssertNil(rig.store.get(Core.Keys.user))
        core.flush(force: true)
        XCTAssertEqual(rig.transport.raw.count, 0)

        let restarted = rig.core()
        restarted.track("Lead", props: nil, eventId: nil)
        restarted.flush(force: true)
        XCTAssertEqual(rig.transport.raw.count, 0)
    }

    func testWithoutAdsConsentDeviceAndClickIdsAreNotSent() {
        let rig = Rig()
        let core = rig.core()
        core.onDeepLink("https://shop.az/p/1?utm_source=fb&fbclid=FB1&gclid=G1&token=SECRET#frag")
        core.flush(force: true)
        // Başlanğıc eventləri keçiddən əvvəl növbəyə düşüb, ona görə kampaniyasız ayrıca topludadır.
        let campaign = dict(dict(rig.transport.posts.last?["ctx"])["campaign"])
        XCTAssertEqual(Set(campaign.keys), ["utm_source", "fbclid", "gclid"])
        let link = rig.transport.events.first { ($0["name"] as? String) == "DeepLinkOpen" } ?? [:]
        XCTAssertEqual(dict(link["props"])["url"] as? String, "https://shop.az/p/1?utm_source=fb&fbclid=FB1&gclid=G1")
        XCTAssertFalse(rig.transport.raw.joined().contains("SECRET"))
        keep(rig)

        rig.transport.raw.removeAll()
        core.setConsent(analytics: nil, ads: false)
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        keep(rig)
        let ctx = dict(rig.transport.posts[0]["ctx"])
        XCTAssertEqual(Set(dict(ctx["campaign"]).keys), ["utm_source"])
        XCTAssertNil(ctx["ids"])
        XCTAssertEqual(dict(ctx["consent"])["ads"] as? Bool, false)
    }

    func testRetryableFailuresKeepEventsAndBackOff() {
        let rig = Rig()
        let core = rig.core()
        core.track("Lead", props: nil, eventId: nil)
        let queued = rig.queue.count

        for status in [500, 429, 408, -1] {
            rig.transport.status = status
            core.flush(force: true)
            XCTAssertEqual(rig.queue.count, queued, "status \(status)")
        }
        let attempts = rig.transport.raw.count
        // Fasilə bitməmiş adi flush yeni cəhd etmir.
        core.flush()
        XCTAssertEqual(rig.transport.raw.count, attempts)

        rig.env.time += 2 * Core.backoffMaxMs
        rig.transport.status = 200
        core.flush()
        XCTAssertEqual(rig.queue.count, 0)
        // Təkrar göndərişdə event ID-ləri eynidir (server dedup edir).
        let ids = Set(rig.transport.posts.compactMap { ($0["events"] as? [[String: Any]])?.first?["id"] as? String })
        XCTAssertEqual(ids.count, 1)
    }

    func testRetryAfterIsHonouredAndNonRetryableRejectionDropsBatch() {
        let rig = Rig()
        let core = rig.core()
        core.track("Lead", props: nil, eventId: nil)
        rig.transport.status = 429
        rig.transport.retryAfter = 120
        core.flush(force: true)
        rig.transport.status = 200
        rig.env.time += 119_000
        core.flush()
        XCTAssertTrue(rig.queue.count > 0)
        rig.env.time += 2_000
        core.flush()
        XCTAssertEqual(rig.queue.count, 0)

        core.track("Lead", props: nil, eventId: nil)
        rig.transport.status = 403
        rig.transport.postError = "{\"ok\":false,\"error\":\"app_not_allowed\"}"
        rig.transport.retryAfter = nil
        let before = rig.transport.raw.count
        core.flush(force: true)
        XCTAssertEqual(rig.queue.count, 0)
        XCTAssertEqual(rig.transport.raw.count, before + 1)
    }

    func testQueueIsBoundedAndBatchesSplitByContext() {
        let rig = Rig()
        rig.store.put(Core.Keys.config, "{\"enabled\":true,\"flush\":{\"max_batch\":100,\"max_queue\":10}}")
        rig.transport.status = 500
        let core = rig.core()
        for index in 0..<30 { core.track("Lead", props: ["i": index], eventId: nil) }
        XCTAssertEqual(rig.queue.count, 10)

        rig.env.version = "2.0.0"
        core.track("Contact", props: nil, eventId: nil)
        rig.transport.status = 200
        rig.transport.raw.removeAll()
        rig.env.time += 2 * Core.backoffMaxMs
        core.flush(force: true)
        keep(rig)
        XCTAssertEqual(rig.transport.posts.count, 2)
        let indexes = rig.transport.events.compactMap { dict($0["props"])["i"] as? Int }
        XCTAssertEqual(indexes, Array(21..<30))
        XCTAssertEqual(dict(dict(rig.transport.posts[1]["ctx"])["app"])["version"] as? String, "2.0.0")
    }

    func testLargeQueueIsSplitBySize() {
        let rig = Rig()
        rig.store.put(Core.Keys.config, "{\"enabled\":true,\"flush\":{\"max_batch\":100,\"max_queue\":1000}}")
        rig.transport.status = 500
        let core = rig.core()
        for _ in 0..<40 { core.track("Lead", props: ["blob": String(repeating: "x", count: 20_000)], eventId: nil) }
        rig.transport.status = 200
        rig.transport.raw.removeAll()
        rig.env.time += 2 * Core.backoffMaxMs
        core.flush(force: true)
        XCTAssertTrue(rig.transport.raw.count >= 2)
        for body in rig.transport.raw { XCTAssertTrue(body.utf8.count <= 500 * 1024) }
        XCTAssertEqual(rig.transport.events.filter { ($0["name"] as? String) == "Lead" }.count, 40)
    }

    func testRemoteConfigIsFetchedCachedAndCanDisableSdk() {
        let rig = Rig()
        rig.transport.configBody = "{\"v\":1,\"key\":\"\(key)\",\"rev\":2,\"enabled\":true,\"ttl_s\":3600,\"sample\":1,\"unknown_field\":{\"x\":1}}"
        let core = rig.core()
        core.refreshConfig()
        XCTAssertEqual(rig.transport.configCalls, 1)
        XCTAssertEqual(rig.transport.urls.last, "https://c.cdnsb.net/v1/\(key)/config")
        core.refreshConfig()
        XCTAssertEqual(rig.transport.configCalls, 1, "ttl bitməyib")

        rig.env.time += 3_600_001
        rig.transport.configStatus = 304
        core.refreshConfig()
        XCTAssertEqual(rig.transport.configCalls, 2)
        XCTAssertEqual(rig.transport.lastEtag, "W/\"1\"")
        XCTAssertTrue(core.config.enabled)

        // Kill-switch: konfiq enabled=false qaytarır.
        core.track("Lead", props: nil, eventId: nil)
        rig.env.time += 3_600_001
        rig.transport.configStatus = 200
        rig.transport.configBody = "{\"v\":1,\"key\":\"\(key)\",\"rev\":3,\"enabled\":false}"
        core.refreshConfig()
        XCTAssertFalse(core.config.enabled)
        XCTAssertEqual(rig.queue.count, 0)
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        XCTAssertEqual(rig.transport.raw.count, 0)
        XCTAssertFalse(rig.core().config.enabled)
    }

    func testUnknownKeyDisablesSdkAndNetworkErrorKeepsOldConfig() {
        let rig = Rig()
        let core = rig.core()
        rig.transport.configStatus = -1
        core.refreshConfig()
        XCTAssertTrue(core.config.enabled)
        // Gövdəsiz 404 (ingress, CDN) açarı söndürmür.
        rig.transport.configStatus = 404
        core.refreshConfig(force: true)
        XCTAssertFalse(core.paused)
        rig.transport.configError = "{\"ok\":false,\"error\":\"unknown_key\"}"
        core.refreshConfig(force: true)
        XCTAssertTrue(core.paused)
        // Söndürülmüş açarla yeni event yığılmır (növbə isə silinmir).
        core.track("Lead", props: nil, eventId: nil)
        XCTAssertFalse(rig.queue.rows.contains { $0.payload.contains("Lead") })
    }

    func testSamplingZeroDropsEverything() {
        let rig = Rig()
        rig.store.put(Core.Keys.config, "{\"enabled\":true,\"sample\":0}")
        let core = rig.core()
        core.track("Lead", props: nil, eventId: nil)
        core.identify("u", traits: nil)
        core.flush(force: true)
        XCTAssertEqual(rig.transport.raw.count, 0)
    }

    func testScreenLifecycleAndAutoEventSwitches() {
        let rig = Rig()
        let core = rig.core()
        core.onForeground()
        core.screen("ProductDetail", props: nil, origin: Core.originAuto)
        core.track("AddToCart", props: nil, eventId: nil)
        core.screen("Cart", props: ["items": 2])
        core.onBackground()
        keep(rig)
        XCTAssertEqual(rig.transport.names, ["SessionStart", "AppInstall", "AppOpen", "ScreenView", "AddToCart", "ScreenView"])
        let events = rig.transport.events
        XCTAssertNil(events[2]["screen"])
        XCTAssertEqual(dict(events[4]["screen"])["name"] as? String, "ProductDetail")
        XCTAssertEqual(events[3]["origin"] as? String, "auto")
        XCTAssertNil(events[5]["origin"])

        let local = Rig(SmartBeeOptions(autoEvents: false))
        let a = local.core()
        a.onForeground()
        a.screen("Home", props: nil, origin: Core.originAuto)
        a.onDeepLink("myapp://x?utm_source=fb")
        a.track("Lead", props: nil, eventId: nil)
        a.flush(force: true)
        XCTAssertEqual(local.transport.names, ["Lead"])

        let remote = Rig()
        remote.store.put(Core.Keys.config, "{\"enabled\":true,\"auto\":{\"lifecycle\":false,\"screens\":false,\"deeplinks\":false}}")
        let b = remote.core()
        b.onForeground()
        b.screen("Home", props: nil, origin: Core.originAuto)
        b.onDeepLink("myapp://x?utm_source=fb")
        b.track("Lead", props: nil, eventId: nil)
        b.flush(force: true)
        XCTAssertEqual(remote.transport.names, ["SessionStart", "Lead"])
    }

    func testResetCreatesNewIdentityAndWrapperIsReported() {
        let rig = Rig(SmartBeeOptions(endpoint: "https://proxy.example.com/", wrapper: "flutter", wrapperVersion: "1.0.0"))
        let core = rig.core()
        core.identify("user-42", traits: nil)
        let before = core.anonymousId
        core.reset()
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        keep(rig)
        let lead = rig.transport.events.last ?? [:]
        XCTAssertNotEqual(before, lead["anon_id"] as? String)
        XCTAssertNil(lead["user_id"])
        XCTAssertEqual(core.anonymousId, rig.store.get(Core.Keys.anon))
        XCTAssertEqual(rig.transport.urls.last, "https://proxy.example.com/v1/e")
        let sdk = dict(rig.transport.posts[0]["sdk"])
        XCTAssertEqual(sdk["wrapper"] as? String, "flutter")
        XCTAssertEqual(sdk["wrapper_version"] as? String, "1.0.0")
    }

    func testHelpers() {
        XCTAssertEqual(Util.iso(1_795_590_005_120), "2026-11-25T07:00:05.120Z")
        XCTAssertEqual(Util.cleanUrl("myapp://open?token=1&Email=a%40b.az#x"), "myapp://open")
        XCTAssertEqual(Util.cleanUrl("https://a.az/p?x=1&sid=9", extraStrip: ["sid"]), "https://a.az/p?x=1")
        XCTAssertNil(Util.campaignOf("https://a.az/p?x=1"))
        // Veb tracker və Android ilə eyni FNV-1a dəyərləri.
        XCTAssertEqual(Util.fraction(""), 2_166_136_261.0 / 4_294_967_296.0, accuracy: 1e-12)
        XCTAssertEqual(Util.fraction("a"), 3_826_002_220.0 / 4_294_967_296.0, accuracy: 1e-12)
        XCTAssertTrue(Util.isValidName("Purchase_2"))
        XCTAssertFalse(Util.isValidName("2Purchase"))
        XCTAssertFalse(Util.isValidName(String(repeating: "a", count: 65)))
        XCTAssertTrue(Util.isValidId("order:A-1001"))
        XCTAssertFalse(Util.isValidId("has space"))
        XCTAssertTrue(Util.isValidKey("demo0ios01"))
        XCTAssertFalse(Util.isValidKey("SHORT"))
        XCTAssertEqual(Util.sha256("a@b.az").count, 64)

        XCTAssertNil(RemoteConfig.parse(nil))
        XCTAssertNil(RemoteConfig.parse("not json"))
        let config = RemoteConfig.parse("{\"sample\":5,\"ttl_s\":1,\"flush\":{\"max_batch\":9999,\"interval_s\":0},\"blocked_events\":[1,\"A\"],\"auto\":{\"screens\":false}}")
        XCTAssertEqual(config?.sample, 1.0)
        XCTAssertEqual(config?.ttlMs, 60_000)
        XCTAssertEqual(config?.maxBatch, 100)
        XCTAssertEqual(config?.flushIntervalMs, 10_000)
        XCTAssertEqual(config?.blockedEvents, ["A"])
        XCTAssertEqual(config?.auto("screens"), false)
        XCTAssertEqual(config?.auto("lifecycle"), true)
    }

    // MARK: - Audit tapıntıları üçün testlər

    func testUrlCleaningMatchesWebAndAndroid() {
        XCTAssertEqual(
            Util.cleanUrl("myapp://u/User.Test@Example.com/orders?ref=a%40b.az&x=1&refresh_token=zz&API_KEY=k"),
            "myapp://u/[redacted]/orders?ref=[redacted]&x=1"
        )
        XCTAssertEqual(Util.cleanUrl("https://user:pass@shop.az/p?client_secret=1&otp=2"), "https://shop.az/p")
        XCTAssertEqual(Util.cleanUrl("https://mail.shop.az/x#frag"), "https://mail.shop.az/x")
        XCTAssertEqual(Util.cleanUrl("https://a.az/p?PIN=9&ID_TOKEN=z&I=1", extraStrip: ["pin"]), "https://a.az/p?I=1")
    }

    func testLocaleTag() {
        XCTAssertEqual(Util.localeTag("az_AZ"), "az-AZ")
        XCTAssertEqual(Util.localeTag("en_US@rg=azzzzz"), "en-US")
        XCTAssertEqual(Util.localeTag("az_Latn_AZ@calendar=gregorian"), "az-Latn-AZ")
    }

    func testFileStorePersistsAndIsExcludedFromBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-store-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = FileStore(directory: dir)
        first.put("anon_id", "id-1")
        first.put("anon_id", "id-2")
        first.put("consent", "10")
        first.put("gone", "x")
        first.remove("gone")
        first.remove("never-existed")

        let second = FileStore(directory: dir)
        XCTAssertEqual(second.get("anon_id"), "id-2")
        XCTAssertEqual(second.get("consent"), "10")
        XCTAssertNil(second.get("gone"))
        let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        // Pozulmuş fayl SDK-nı sındırmır: boş yaddaşla başlayır.
        try Data("not json".utf8).write(to: dir.appendingPathComponent("store.json"))
        XCTAssertNil(FileStore(directory: dir).get("anon_id"))
        try Data("[1,2]".utf8).write(to: dir.appendingPathComponent("queue.json"))
        XCTAssertEqual(FileQueue(directory: dir).count, 0)
    }

    func testCoreWorksOnTopOfRealStorage() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-core-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = FakeTransport()
        let env = FakeEnv()
        let queue = FileQueue(directory: dir)
        let store = FileStore(directory: dir)
        // Keş açara və ünvana bağlıdır: bağlantısız konfiq başqa açarın konfiqi sayılıb atılardı.
        store.put(Core.Keys.binding, Core.binding(key: key, endpoint: SmartBeeOptions().endpoint))
        store.put(Core.Keys.config, "{\"enabled\":true}")
        let core = Core(key: key, options: SmartBeeOptions(), store: store, queue: queue, transport: transport, env: env)
        core.start()
        core.track("Purchase", props: ["value": 250, "currency": "AZN"], eventId: "order:A-1")
        queue.persist()

        // Proses yenidən başlayır: növbə və identifikator diskdən oxunur, AppInstall təkrarlanmır.
        let reopened = FileQueue(directory: dir)
        XCTAssertEqual(reopened.count, queue.count)
        let again = Core(key: key, options: SmartBeeOptions(), store: FileStore(directory: dir), queue: reopened, transport: transport, env: env)
        again.start()
        XCTAssertEqual(again.anonymousId, core.anonymousId)
        again.flush(force: true)
        CoreTests.dumped.append(contentsOf: transport.raw)
        XCTAssertEqual(transport.names, ["SessionStart", "AppInstall", "Purchase"])
        XCTAssertEqual(reopened.count, 0)
    }

    func testTransportAllowsOnlyHttps() {
        XCTAssertNotNil(URLSessionTransport.allowed("https://c.cdnsb.net/v1/e", debug: false))
        XCTAssertNil(URLSessionTransport.allowed("http://c.cdnsb.net/v1/e", debug: false))
        XCTAssertNil(URLSessionTransport.allowed("http://c.cdnsb.net/v1/e", debug: true))
        XCTAssertNil(URLSessionTransport.allowed("http://localhost:8787/v1/e", debug: false))
        XCTAssertNotNil(URLSessionTransport.allowed("http://localhost:8787/v1/e", debug: true))
        XCTAssertNil(URLSessionTransport.allowed("not a url", debug: true))
        // İcazəsiz ünvana sorğu göndərilmir: şəbəkəyə çıxmadan rədd olunur.
        XCTAssertEqual(URLSessionTransport(debug: false).post(url: "http://example.invalid/v1/e", json: "{}").status, -1)
        XCTAssertEqual(URLSessionTransport(debug: false).get(url: "http://example.invalid/v1/x/config", etag: nil).status, -1)
    }

    func testDeviceContextSnapshotCanBeExtendedLater() {
        let env = AppleEnv(snapshot: AppleEnv.captureBase())
        let before = env.deviceContext()
        XCTAssertNotNil(before["app"])
        XCTAssertNotNil(before["os"])
        XCTAssertNil(before["screen"])
        env.merge(["screen": ["w": 1179, "h": 2556, "density": 3.0]])
        XCTAssertNotNil(env.deviceContext()["screen"])
        XCTAssertFalse((env.deviceContext()["locale"] as? String ?? "_").contains("_"))
    }

    func testFileQueuePersistsAcrossInstances() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-queue-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = FileQueue(directory: dir)
        first.add(ctx: "{}", payload: "{\"n\":1}")
        first.add(ctx: "{}", payload: "{\"n\":2}")
        first.add(ctx: "{}", payload: "{\"n\":3}")
        first.remove([first.peek(1)[0].id])
        first.persist()

        let second = FileQueue(directory: dir)
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(second.peek(10).map { $0.payload }, ["{\"n\":2}", "{\"n\":3}"])
        second.trim(1)
        XCTAssertEqual(second.peek(10).map { $0.payload }, ["{\"n\":3}"])
        second.clear()
        second.persist()
        XCTAssertEqual(FileQueue(directory: dir).count, 0)
    }

    // MARK: - Yaddaşın oxunmaması

    func testMissingAndCorruptFilesAreNotUnreadable() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sb-first-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        // Fayl yoxdur: ilk işə salınma.
        XCTAssertFalse(FileStore(directory: dir).unreadable)
        XCTAssertFalse(FileQueue(directory: dir).unreadable)
        // Oxunan, amma pozulmuş fayl: boş yaddaşla başlanır.
        try Data("not json".utf8).write(to: dir.appendingPathComponent("store.json"))
        try Data("not json".utf8).write(to: dir.appendingPathComponent("queue.json"))
        XCTAssertFalse(FileStore(directory: dir).unreadable)
        XCTAssertFalse(FileQueue(directory: dir).unreadable)
    }

    func testPathThatCannotBeReadIsUnreadable() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sb-dir-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        // Fayl əvəzinə qovluq: mövcuddur, amma məzmunu oxunmur.
        try fm.createDirectory(at: dir.appendingPathComponent("store.json"), withIntermediateDirectories: true, attributes: nil)
        try fm.createDirectory(at: dir.appendingPathComponent("queue.json"), withIntermediateDirectories: true, attributes: nil)
        let store = FileStore(directory: dir)
        XCTAssertTrue(store.unreadable)
        store.put("anon_id", "fresh")
        XCTAssertEqual(store.get("anon_id"), "fresh")
        let queue = FileQueue(directory: dir)
        XCTAssertTrue(queue.unreadable)
        queue.add(ctx: "{}", payload: "{\"n\":1}")
        queue.persist()
        XCTAssertEqual(queue.count, 1)
    }

    func testUnreadableStorageIsNeverOverwritten() throws {
        // root istənilən faylı oxuyur, ona görə icazə ilə kilidləmə onda işləmir.
        if geteuid() == 0 { return }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sb-locked-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let seeded = FileStore(directory: dir)
        seeded.put("consent", "00")
        seeded.put("config_etag", "W/\"9\"")
        let seededQueue = FileQueue(directory: dir)
        seededQueue.add(ctx: "{}", payload: "{\"n\":1}")
        seededQueue.persist()

        // Cihaz yenidən başlayıb, kilidi hələ açılmayıb: fayllar var, amma oxunmur.
        let storePath = dir.appendingPathComponent("store.json").path
        let queuePath = dir.appendingPathComponent("queue.json").path
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: storePath)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: queuePath)

        let store = FileStore(directory: dir)
        XCTAssertTrue(store.unreadable)
        XCTAssertNil(store.get("consent"))
        store.put("consent", "11")
        store.put("anon_id", "fresh")
        store.remove("consent")
        let queue = FileQueue(directory: dir)
        XCTAssertTrue(queue.unreadable)
        XCTAssertEqual(queue.count, 0)
        queue.add(ctx: "{}", payload: "{\"n\":2}")
        queue.persist()
        queue.clear()
        queue.persist()

        // Kilid açıldı: əvvəlki məlumat yerindədir.
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: storePath)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: queuePath)
        let reopened = FileStore(directory: dir)
        XCTAssertFalse(reopened.unreadable)
        XCTAssertEqual(reopened.get("consent"), "00")
        XCTAssertEqual(reopened.get("config_etag"), "W/\"9\"")
        XCTAssertNil(reopened.get("anon_id"))
        let reopenedQueue = FileQueue(directory: dir)
        XCTAssertFalse(reopenedQueue.unreadable)
        XCTAssertEqual(reopenedQueue.peek(10).map { $0.payload }, ["{\"n\":1}"])
    }

    // MARK: - Razılıq

    func testFetchedConsentDefaultAppliesInFirstSession() {
        let denied = "{\"enabled\":true,\"consent_default\":{\"analytics\":false,\"ads\":false}}"
        let rig = Rig()
        rig.transport.configBody = denied
        let core = rig.core()
        core.identify("user-1", traits: nil)
        core.onDeepLink("myapp://x?utm_source=fb")
        XCTAssertTrue(rig.queue.count > 0)
        XCTAssertNotNil(core.anonymousId)

        core.refreshConfig()
        XCTAssertEqual(rig.queue.count, 0)
        XCTAssertNil(core.anonymousId)
        for name in [Core.Keys.anon, Core.Keys.user, Core.Keys.session, Core.Keys.seq, Core.Keys.campaign] {
            XCTAssertNil(rig.store.get(name), name)
        }
        // Bu, istifadəçinin seçimi deyil: razılıq kimi saxlanmır.
        XCTAssertNil(rig.store.get(Core.Keys.consent))
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        XCTAssertEqual(rig.transport.raw.count, 0)

        // İstifadəçinin sonrakı seçimi konfiqdən üstündür.
        core.setConsent(analytics: true, ads: true)
        rig.env.time += 3_600_001
        core.refreshConfig()
        XCTAssertEqual(rig.transport.configCalls, 2)
        XCTAssertNotNil(core.anonymousId)
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        XCTAssertTrue(rig.transport.names.contains("Lead"))
        XCTAssertNil(rig.transport.events.last?["user_id"])

        // Tətbiqin verdiyi razılıq da konfiqdən üstündür.
        let explicit = Rig(SmartBeeOptions(consent: SmartBeeConsent(analytics: true, ads: true)))
        explicit.transport.configBody = denied
        let granted = explicit.core()
        granted.refreshConfig()
        XCTAssertNotNil(granted.anonymousId)
        XCTAssertTrue(explicit.queue.count > 0)

        // Yalnız reklam razılığı söndürülüb: eventlər gedir, cihaz identifikatoru getmir.
        let partial = Rig()
        partial.transport.configBody = "{\"enabled\":true,\"consent_default\":{\"analytics\":true,\"ads\":false}}"
        let limited = partial.core()
        limited.refreshConfig()
        limited.track("Lead", props: nil, eventId: nil)
        limited.flush(force: true)
        let ctx = dict(partial.transport.posts.last?["ctx"])
        XCTAssertEqual(dict(ctx["consent"])["ads"] as? Bool, false)
        XCTAssertNil(ctx["ids"])
    }

    func testRegrantingConsentUsesNewAnonymousId() {
        let rig = Rig()
        let core = rig.core()
        let before = core.anonymousId
        XCTAssertNotNil(before)
        core.setConsent(analytics: false, ads: nil)
        XCTAssertNil(core.anonymousId)
        core.setConsent(analytics: true, ads: nil)
        XCTAssertNotNil(core.anonymousId)
        XCTAssertNotEqual(core.anonymousId, before)
        XCTAssertEqual(core.anonymousId, rig.store.get(Core.Keys.anon))
    }

    // MARK: - Xarici mətnlər

    func testHostileDeepLinkCannotPoisonTheContext() {
        let rig = Rig()
        let core = rig.core()
        // 300 dənə "e + birləşən vurğu": 300 `Character`, amma 600 kod nöqtəsi.
        let combining = String(repeating: "e%CC%81", count: 300)
        core.onDeepLink("myapp://x?utm_source=a%00b&utm_campaign=" + combining + "&gclid=%00")
        core.flush(force: true)
        let campaign = dict(dict(rig.transport.posts.last?["ctx"])["campaign"])
        XCTAssertEqual(Set(campaign.keys), ["utm_source", "utm_campaign"])
        XCTAssertEqual(campaign["utm_source"] as? String, "ab")
        // Hədd veb tracker-dəki kimi 512 UTF-16 vahididir.
        XCTAssertEqual((campaign["utm_campaign"] as? String ?? "").utf16.count, 512)
        XCTAssertFalse(rig.transport.raw.joined().contains("\\u0000"))

        // Bütün kampaniya dəyərləri ən böyük ölçüdədir: kontekst 8 KB-ı aşardı, ona görə kampaniya atılır.
        // 8192 simvoldan uzun ünvan heç emal olunmur, ona görə belə kampaniya yalnız saxlanmış dəyərdən gələ bilər
        // (köhnə versiyadan qalan və ya pozulmuş yaddaş).
        let emoji = String(repeating: "\u{1F600}", count: 300)
        let names = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "fbclid", "gclid", "gbraid", "wbraid", "ttclid", "msclkid"]
        var stored: [String: String] = [:]
        for name in names { stored[name] = emoji }
        let json = (try? JSONSerialization.data(withJSONObject: stored)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let big = Rig()
        big.store.put(Core.Keys.campaign, json)
        big.store.put(Core.Keys.campaignAt, String(big.env.time))
        let second = big.core()
        second.track("Lead", props: nil, eventId: nil)
        XCTAssertFalse(big.queue.rows.isEmpty)
        for row in big.queue.rows { XCTAssertTrue(row.ctx.utf8.count <= Core.maxCtxBytes) }
        second.flush(force: true)
        XCTAssertTrue(big.transport.names.contains("Lead"))
        for post in big.transport.posts { XCTAssertNil(dict(post["ctx"])["campaign"]) }
    }

    func testStoredCampaignIsSanitizedBeforeSending() {
        let rig = Rig()
        rig.store.put(Core.Keys.campaign, "{\"utm_source\":\"fb\",\"utm_medium\":5,\"utm_term\":\"" + String(repeating: "x", count: 600) + "\",\"utm_content\":\"write to a@b.az\"}")
        rig.store.put(Core.Keys.campaignAt, String(rig.env.time))
        let core = rig.core()
        core.flush(force: true)
        let campaign = dict(dict(rig.transport.posts.last?["ctx"])["campaign"])
        XCTAssertEqual(Set(campaign.keys), ["utm_source", "utm_term", "utm_content"])
        XCTAssertEqual((campaign["utm_term"] as? String ?? "").utf16.count, 512)
        XCTAssertEqual(campaign["utm_content"] as? String, "write to [redacted]")
    }

    func testOutgoingStringsAreStrippedOfNulAndLimitedByCodePoints() {
        XCTAssertEqual(Util.text("a\u{0}b\u{0}"), "ab")
        XCTAssertEqual(Util.text("abc"), "abc")
        XCTAssertEqual(Util.text(String(repeating: "e\u{301}", count: 10), limit: 5).unicodeScalars.count, 5)

        let rig = Rig()
        let core = rig.core()
        core.identify("user\u{0}-1", traits: ["plan": "p\u{0}ro"])
        // 100 `Character`, amma 200 UTF-16 vahidi: 128 həddini aşır.
        core.identify(String(repeating: "e\u{301}", count: 100), traits: nil)
        core.identify("\u{0}", traits: nil)
        core.screen(String(repeating: "e\u{301}", count: 100), props: ["q\u{0}": "x\u{0}y"])
        core.flush(force: true)

        let identifies = rig.transport.events.filter { ($0["type"] as? String) == "identify" }
        XCTAssertEqual(identifies.count, 1)
        XCTAssertEqual(identifies.first?["user_id"] as? String, "user-1")
        XCTAssertEqual(dict(identifies.first?["traits"])["plan"] as? String, "pro")
        XCTAssertEqual(rig.store.get(Core.Keys.user), "user-1")
        let view = rig.transport.events.last ?? [:]
        XCTAssertEqual(view["name"] as? String, "ScreenView")
        XCTAssertEqual((dict(view["screen"])["name"] as? String ?? "").unicodeScalars.count, 128)
        XCTAssertEqual(dict(view["props"])["q"] as? String, "xy")
        XCTAssertEqual(view["user_id"] as? String, "user-1")
        XCTAssertFalse(rig.transport.raw.joined().contains("\\u0000"))
    }

    func testNonFiniteDatesAreDroppedInsteadOfCrashing() {
        let rig = Rig()
        let core = rig.core()
        let props: [String: Any?] = [
            "ok": Date(timeIntervalSince1970: 1_795_590_000),
            "inf": Date(timeIntervalSince1970: Double.infinity),
            "nan": Date(timeIntervalSince1970: Double.nan),
            "far": Date(timeIntervalSince1970: 1.0e300),
        ]
        core.track("Lead", props: props, eventId: nil)
        core.identify("user-1", traits: ["since": Date(timeIntervalSince1970: -Double.infinity), "plan": "pro"])
        core.flush(force: true)
        let lead = rig.transport.events.first { ($0["name"] as? String) == "Lead" } ?? [:]
        let out = dict(lead["props"])
        XCTAssertEqual(Set(out.keys), ["ok"])
        XCTAssertEqual(out["ok"] as? String, "2026-11-25T07:00:00.000Z")
        XCTAssertEqual(Set(dict(rig.transport.events.last?["traits"]).keys), ["plan"])
    }

    // MARK: - Hədlər və pozulmuş məlumat

    func testQueueIsBoundedByCountAndBytes() {
        XCTAssertEqual(RemoteConfig.parse("{\"flush\":{\"max_queue\":100000}}")?.maxQueue, 5000)
        XCTAssertEqual(RemoteConfig.parse("{\"flush\":{\"max_queue\":200}}")?.maxQueue, 200)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-bytes-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = FileQueue(directory: dir, maxBytes: 250)
        // Hər sətir 100 baytdır (kontekst 2 + event 98).
        let payload = String(repeating: "x", count: 98)
        for _ in 0..<5 { queue.add(ctx: "{}", payload: payload) }
        queue.trim(1000)
        XCTAssertEqual(queue.count, 2)

        // Həddən böyük tək sətir atılmır, ondan əvvəlkilər atılır.
        queue.add(ctx: "{}", payload: String(repeating: "y", count: 1000))
        queue.trim(1000)
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.peek(1).first?.payload.count, 1000)

        // Silinən sətirlərin ölçüsü hesabdan çıxılır.
        queue.remove(queue.peek(1).map { $0.id })
        for _ in 0..<2 { queue.add(ctx: "{}", payload: payload) }
        queue.trim(1000)
        XCTAssertEqual(queue.count, 2)
        queue.trim(1)
        XCTAssertEqual(queue.count, 1)

        // Diskdən oxunan növbənin ölçüsü də sayılır.
        for _ in 0..<2 { queue.add(ctx: "{}", payload: payload) }
        queue.persist()
        let reopened = FileQueue(directory: dir, maxBytes: 250)
        XCTAssertEqual(reopened.count, 3)
        reopened.trim(1000)
        XCTAssertEqual(reopened.count, 2)
        reopened.clear()
        reopened.add(ctx: "{}", payload: payload)
        reopened.trim(1000)
        XCTAssertEqual(reopened.count, 1)
    }

    func testResponseHeadersAreCaseInsensitive() throws {
        let url = try XCTUnwrap(URL(string: "https://c.cdnsb.net/v1/demo0ios01/config"))
        let lower = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/2", headerFields: ["etag": "W/\"7\"", "retry-after": " 30 "]))
        let result = URLSessionTransport.result(lower, Data("{}".utf8))
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(result.etag, "W/\"7\"")
        XCTAssertEqual(result.retryAfterSec, 30)
        XCTAssertEqual(result.body, "{}")

        let mixed = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "120", "ETag": "x"]))
        let limited = URLSessionTransport.result(mixed, Data("ignored".utf8))
        XCTAssertEqual(limited.retryAfterSec, 120)
        XCTAssertEqual(limited.etag, "x")
        // Xəta cavabının gövdəsi də oxunur: SDK serverin JSON xəta kodunu yalnız ondan tanıyır.
        XCTAssertEqual(limited.body, "ignored")
    }

    func testCorruptStoredNumbersDoNotCrash() {
        let rig = Rig()
        rig.store.put(Core.Keys.seq, String(Int64.max))
        rig.store.put(Core.Keys.session, "abc|" + String(Int64.min))
        rig.store.put(Core.Keys.configAt, String(Int64.min))
        let core = rig.core()
        core.refreshConfig()
        XCTAssertEqual(rig.transport.configCalls, 1)
        core.track("Lead", props: nil, eventId: nil)

        rig.store.put(Core.Keys.seq, "-5")
        rig.store.put(Core.Keys.session, "abc|" + String(Int64.max))
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        XCTAssertEqual(rig.transport.names, ["SessionStart", "AppInstall", "Lead", "SessionStart", "Lead"])
        XCTAssertEqual(rig.transport.events.compactMap { $0["seq"] as? Int }, [0, 1, 2, 0, 1])
    }

    func testCallerTimestampIsKeptAndDoesNotSplitTheSession() {
        let rig = Rig()
        let core = rig.core()
        let captured = rig.env.time + 10_000
        // Növbə 90 saniyə məşğul olub: bu arada başqa event indiki vaxtla işlənib.
        rig.env.time += 90_000
        core.track("Contact", props: nil, eventId: nil)
        core.track("Lead", props: nil, eventId: nil, at: captured)
        core.identify("user-1", traits: nil, at: captured)
        core.screen("Home", props: nil, at: captured)
        core.flush(force: true)
        let events = rig.transport.events
        XCTAssertEqual(rig.transport.names, ["SessionStart", "AppInstall", "Contact", "Lead", "identify", "ScreenView"])
        XCTAssertEqual(events[2]["ts"] as? String, Util.iso(rig.env.time))
        for index in 3..<6 { XCTAssertEqual(events[index]["ts"] as? String, Util.iso(captured)) }
        XCTAssertEqual(Set(events.compactMap { $0["session_id"] as? String }).count, 1)

        // Cihazın saatı geri çəkilibsə yeni sessiya başlayır.
        rig.transport.raw.removeAll()
        rig.env.time -= 600_000
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        XCTAssertEqual(rig.transport.names, ["SessionStart", "Lead"])
    }

    func testConfigBooleansMustBeRealJsonBooleans() {
        let numeric = RemoteConfig.parse("{\"enabled\":0,\"consent_default\":{\"analytics\":0,\"ads\":0},\"auto\":{\"screens\":0,\"lifecycle\":1}}")
        XCTAssertEqual(numeric?.enabled, true)
        // `consent_default`-da boolean olmayan dəyər razılıq sayılmır (PROTOCOL.md 8).
        XCTAssertEqual(numeric?.consentAnalytics, false)
        XCTAssertEqual(numeric?.consentAds, false)
        XCTAssertEqual(numeric?.auto("screens"), true)

        let real = RemoteConfig.parse("{\"enabled\":false,\"consent_default\":{\"analytics\":false,\"ads\":false},\"auto\":{\"screens\":false,\"lifecycle\":true}}")
        XCTAssertEqual(real?.enabled, false)
        XCTAssertEqual(real?.consentAnalytics, false)
        XCTAssertEqual(real?.consentAds, false)
        XCTAssertEqual(real?.auto("screens"), false)
        XCTAssertEqual(real?.auto("lifecycle"), true)
    }
    // MARK: - Razılıq: serverin consent_default dəyəri

    private let identityKeys = [Core.Keys.anon, Core.Keys.user, Core.Keys.session, Core.Keys.seq, Core.Keys.campaign]

    private func leads(_ rig: Rig) -> [[String: Any]] {
        return rig.transport.events.filter { ($0["name"] as? String) == "Lead" }
    }

    func testFirstLaunchStoresAndSendsNothingUntilConfigArrives() {
        let rig = Rig(fresh: true)
        rig.transport.configStatus = -1
        let core = rig.core()
        core.onForeground()
        core.identify("user-1", traits: nil)
        core.onDeepLink("https://shop.az/?utm_source=fb")
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        core.onBackground()

        XCTAssertEqual(rig.transport.raw.count, 0)
        XCTAssertEqual(rig.queue.count, 0)
        XCTAssertNil(core.anonymousId)
        XCTAssertTrue(rig.store.map.isEmpty, "diskə heç nə yazılmamalıdır: \(rig.store.map)")

        // Server analitikaya susmaya görə icazə vermir: gözləyən hər şey atılır.
        rig.transport.configStatus = 200
        rig.transport.configBody = "{\"enabled\":true,\"consent_default\":{\"analytics\":false,\"ads\":false}}"
        rig.env.time += Core.backoffMaxMs
        core.flush()
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        XCTAssertEqual(rig.transport.raw.count, 0)
        XCTAssertEqual(rig.queue.count, 0)
        XCTAssertNil(core.anonymousId)
        for name in identityKeys + [Core.Keys.appVersion] { XCTAssertNil(rig.store.get(name), name) }
        // Server seçimi istifadəçi seçimi kimi saxlanmır.
        XCTAssertNil(rig.store.get(Core.Keys.consent))

        // Növbəti işə düşmədə keşdəki konfiq dərhal tətbiq olunur.
        let again = rig.core()
        again.track("Lead", props: nil, eventId: nil)
        again.flush(force: true)
        XCTAssertEqual(rig.transport.raw.count, 0)
        XCTAssertNil(rig.store.get(Core.Keys.anon))
    }

    func testFirstLaunchReleasesHeldEventsWhenConfigAllowsAnalytics() {
        let rig = Rig(fresh: true)
        rig.transport.configStatus = -1
        let core = rig.core()
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        XCTAssertEqual(rig.transport.raw.count, 0)
        // Uğursuz cəhddən sonra konfiq hər flush-da yenidən istənmir.
        let calls = rig.transport.configCalls
        XCTAssertEqual(calls, 1)
        core.flush(force: true)
        XCTAssertEqual(rig.transport.configCalls, calls)

        rig.transport.configStatus = 200
        rig.transport.configBody = "{\"enabled\":true,\"consent_default\":{\"analytics\":true,\"ads\":false}}"
        rig.env.time += 60_000
        core.flush()
        keep(rig)
        XCTAssertNil(rig.transport.lastEtag)
        XCTAssertEqual(rig.transport.names, ["SessionStart", "AppInstall", "Lead"])
        XCTAssertEqual(rig.transport.posts.count, 1)
        let consent = dict(dict(rig.transport.posts.first?["ctx"])["consent"])
        XCTAssertEqual(consent["analytics"] as? Bool, true)
        XCTAssertEqual(consent["ads"] as? Bool, false)
        XCTAssertNotNil(core.anonymousId)
        XCTAssertEqual(core.anonymousId, rig.store.get(Core.Keys.anon))
        XCTAssertEqual(core.anonymousId, rig.transport.events.first?["anon_id"] as? String)
    }

    func testHeldEventsAreBoundedAndExplicitConsentSettlesThem() {
        let granted = Rig(fresh: true)
        granted.transport.configStatus = -1
        let a = granted.core()
        for index in 0..<(Core.maxHeld + 50) { a.track("Lead", props: ["i": index], eventId: nil) }
        XCTAssertEqual(granted.queue.count, 0)
        a.setConsent(analytics: true, ads: true)
        XCTAssertEqual(granted.queue.count, Core.maxHeld)
        XCTAssertEqual(granted.store.get(Core.Keys.consent), "11")
        XCTAssertNotNil(a.anonymousId)
        XCTAssertEqual(a.anonymousId, granted.store.get(Core.Keys.anon))
        a.flush(force: true)
        XCTAssertEqual(dict(granted.transport.events.last?["props"])["i"] as? Int, Core.maxHeld + 49)

        let denied = Rig(fresh: true)
        denied.transport.configStatus = -1
        let b = denied.core()
        b.track("Lead", props: nil, eventId: nil)
        b.setConsent(analytics: false, ads: false)
        b.flush(force: true)
        XCTAssertEqual(denied.queue.count, 0)
        XCTAssertEqual(denied.transport.raw.count, 0)
        XCTAssertEqual(denied.store.map, [Core.Keys.consent: "00"])
    }

    func testInitConsentOptionSkipsTheWaitOnFirstLaunch() {
        let rig = Rig(SmartBeeOptions(consent: SmartBeeConsent(analytics: true, ads: true)), fresh: true)
        rig.transport.configStatus = -1
        let core = rig.core()
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        XCTAssertEqual(rig.transport.names, ["SessionStart", "AppInstall", "Lead"])
        XCTAssertNotNil(core.anonymousId)
        XCTAssertEqual(core.anonymousId, rig.store.get(Core.Keys.anon))
    }

    func testFirstLaunchWritesNoFilesUntilConsentIsKnown() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sb-wait-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let transport = FakeTransport()
        transport.configStatus = -1
        let queue = FileQueue(directory: dir)
        let core = Core(key: key, options: SmartBeeOptions(), store: FileStore(directory: dir), queue: queue, transport: transport, env: FakeEnv())
        core.start()
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        queue.persist()
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("store.json").path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("queue.json").path))

        core.setConsent(analytics: true, ads: true)
        queue.persist()
        XCTAssertEqual(FileStore(directory: dir).get(Core.Keys.anon), core.anonymousId)
        XCTAssertEqual(FileQueue(directory: dir).count, 3)
    }

    func testConsentDefaultRegrantedByConfigUsesNewAnonymousId() {
        let rig = Rig()
        let core = rig.core()
        core.identify("user-1", traits: nil)
        core.track("Lead", props: nil, eventId: nil)
        let before = core.anonymousId
        XCTAssertNotNil(before)

        rig.transport.configBody = "{\"enabled\":true,\"consent_default\":{\"analytics\":false,\"ads\":false}}"
        core.refreshConfig()
        XCTAssertEqual(rig.queue.count, 0)
        XCTAssertNil(core.anonymousId)

        // Server yenidən icazə verəndə köhnə identifikator qayıtmır.
        rig.env.time += 3_600_001
        rig.transport.configBody = "{\"enabled\":true,\"consent_default\":{\"analytics\":true,\"ads\":true}}"
        core.refreshConfig()
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        let lead = rig.transport.events.last ?? [:]
        XCTAssertNotNil(lead["anon_id"] as? String)
        XCTAssertNotEqual(lead["anon_id"] as? String, before)
        XCTAssertNil(lead["user_id"])
        XCTAssertEqual(lead["anon_id"] as? String, rig.store.get(Core.Keys.anon))
    }

    func testStartWipesLeftoverIdentityWhenAnalyticsResolvesToFalse() {
        let rig = Rig()
        rig.store.put(Core.Keys.config, "{\"enabled\":true,\"consent_default\":{\"analytics\":false,\"ads\":false}}")
        rig.store.put(Core.Keys.anon, "old-anon")
        rig.store.put(Core.Keys.user, "user-1")
        rig.store.put(Core.Keys.session, "s1|1")
        rig.store.put(Core.Keys.seq, "7")
        rig.store.put(Core.Keys.campaign, "{\"utm_source\":\"fb\"}")
        rig.queue.add(ctx: "{}", payload: "{\"id\":\"x\"}")
        let core = rig.core()
        XCTAssertNil(core.anonymousId)
        XCTAssertEqual(rig.queue.count, 0)
        for name in identityKeys { XCTAssertNil(rig.store.get(name), name) }
    }

    func testConsentChangeWithoutRegrantKeepsAnonymousId() {
        let rig = Rig()
        let core = rig.core()
        let current = core.anonymousId
        XCTAssertNotNil(current)
        // Razılıq dəyişmədən təkrar çağırış identifikatoru dəyişmir.
        core.setConsent(analytics: true, ads: false)
        XCTAssertEqual(core.anonymousId, current)
        XCTAssertEqual(rig.store.get(Core.Keys.anon), current)
    }

    // MARK: - Keçidlər

    func testOnlyRealLinksAreTrackedAsDeepLinks() {
        let rig = Rig()
        let core = rig.core()
        let rejected = [
            "tel:+994501234567", "tel://+994501234567?utm_source=x", "sms:+994501234567?body=hi", "smsto:+994501234567",
            "mms://+994501234567", "mmsto://+994501234567", "mailto:user@example.com?subject=x&utm_source=x",
            "mailto://user@example.com?utm_source=x", "geo:40.4093,49.8671?q=home", "geo://40.4093,49.8671?utm_source=x",
            "content://contacts/people/1?utm_source=x", "file:///private/var/secret.pdf", "data:text/plain;base64,QQ==",
            "data://text/plain?utm_source=x", "intent://scan/#Intent;scheme=zxing;end", "blob://shop.az/1?utm_source=x",
            "javascript://alert(1)?utm_source=x", "about://blank?utm_source=x", "CONTENT://media/external/images/1",
            "myapp:product/1", "product/1?utm_source=x", "1app://product/1", "",
        ]
        for url in rejected { core.onDeepLink(url) }
        core.onDeepLink(nil)
        core.flush(force: true)
        XCTAssertFalse(rig.transport.names.contains("DeepLinkOpen"))
        XCTAssertNil(rig.store.get(Core.Keys.campaign))
        XCTAssertFalse(rig.transport.raw.joined().contains("994501234567"))

        core.onDeepLink("https://shop.az/p/1?utm_source=fb")
        core.onDeepLink("HTTP://shop.az/p/2")
        core.onDeepLink("myapp://product/3")
        core.onDeepLink("my.app+x-1:///product/4")
        core.flush(force: true)
        let urls = rig.transport.events.filter { ($0["name"] as? String) == "DeepLinkOpen" }.compactMap { dict($0["props"])["url"] as? String }
        XCTAssertEqual(urls, ["https://shop.az/p/1?utm_source=fb", "HTTP://shop.az/p/2", "myapp://product/3", "my.app+x-1:///product/4"])
        XCTAssertEqual(rig.store.get(Core.Keys.campaign), "{\"utm_source\":\"fb\"}")
    }

    func testRepeatedDeepLinkWithinFiveSecondsCountsOnce() {
        let rig = Rig()
        let core = rig.core()
        core.onDeepLink("myapp://product/1?utm_source=fb")
        rig.env.time += 4_999
        core.onDeepLink("myapp://product/1?utm_source=fb")
        core.onDeepLink("myapp://product/2")
        rig.env.time += Core.linkRepeatMs
        core.onDeepLink("myapp://product/2")
        core.flush(force: true)
        let urls = rig.transport.events.filter { ($0["name"] as? String) == "DeepLinkOpen" }.compactMap { dict($0["props"])["url"] as? String }
        XCTAssertEqual(urls, ["myapp://product/1?utm_source=fb", "myapp://product/2", "myapp://product/2"])
    }

    // MARK: - Şəxsi məlumat

    /// `identify` / `track` nüvədən keçəndə də ortaq vektorlardakı dəyərlər göndərilir (bax SanitizeVectorsTests;
    /// Android-dəki `coreSendsTheSameValuesAsTheVectors` ilə eyni yoxlama).
    func testCoreSendsTheSameValuesAsTheVectors() {
        var failed: [String] = []
        let identities = SanitizeVectors.cases("identity.json")
        XCTAssertGreaterThanOrEqual(identities.count, 25)
        for item in identities {
            let rig = Rig()
            let core = rig.core()
            core.identify(item["input"] as? String, traits: nil)
            core.flush(force: true)
            let event = rig.transport.events.last { ($0["type"] as? String) == "identify" }
            if let difference = SanitizeVectors.difference(item, event?["user_id"]) { failed.append("identity: " + difference) }
        }
        let objects = SanitizeVectors.cases("sanitize-props.json")
        XCTAssertGreaterThanOrEqual(objects.count, 40)
        for item in objects {
            let traits = (item["kind"] as? String) == "traits"
            let input = item["input"] as? [String: Any] ?? [:]
            let rig = Rig()
            let core = rig.core()
            // kind: label — ekran adı: giriş və nəticə mətndir, `screen` çağırışından keçir.
            if (item["kind"] as? String) == "label" {
                core.screen(item["input"] as? String, props: nil)
                core.flush(force: true)
                let view = rig.transport.events.last { sent in
                    return (sent["name"] as? String) == "ScreenView"
                }
                let screen = view?["screen"] as? [String: Any]
                if let difference = SanitizeVectors.difference(item, screen?["name"]) { failed.append("label: " + difference) }
                continue
            }
            if traits {
                core.identify("vector-user", traits: input)
            } else {
                core.track("VectorEvent", props: input, eventId: nil)
            }
            core.flush(force: true)
            let event = rig.transport.events.last { sent in
                return traits ? (sent["type"] as? String) == "identify" : (sent["name"] as? String) == "VectorEvent"
            }
            if let difference = SanitizeVectors.difference(item, event?[traits ? "traits" : "props"]) { failed.append("props: " + difference) }
        }
        XCTAssertTrue(failed.isEmpty, "\(failed.count) vectors differ when sent through Core:\n" + failed.joined(separator: "\n"))
    }

    func testEmailAndPhoneAreHashedWhateverTheKeyCaseOrNumberType() {
        let expectedPhone = Util.sha256("994501234567")
        let expectedEmail = Util.sha256("user@example.com")
        let cases: [[String: Any?]] = [
            ["Email": " User@Example.com ", "PHONE": "+994 50 123 45 67"],
            ["email": "user@example.com", "phone": 994_501_234_567.0],
            ["EMAIL": "user@example.com", "Phone": Int64(994_501_234_567)],
            ["email": "user@example.com", "phone": NSDecimalNumber(mantissa: 994_501_234_567, exponent: 0, isNegative: false)],
        ]
        for (index, traits) in cases.enumerated() {
            let rig = Rig()
            let core = rig.core()
            core.identify("user-1", traits: traits)
            core.flush(force: true)
            keep(rig)
            let identify = rig.transport.events.first { ($0["type"] as? String) == "identify" } ?? [:]
            let out = dict(identify["traits"])
            XCTAssertEqual(Set(out.keys), ["email_sha256", "phone_sha256"], "case \(index)")
            XCTAssertEqual(out["email_sha256"] as? String, expectedEmail, "case \(index)")
            XCTAssertEqual(out["phone_sha256"] as? String, expectedPhone, "case \(index)")
        }
        XCTAssertEqual(Util.phoneText(1.0e21), "1000000000000000000000")
        XCTAssertEqual(Util.phoneText(12.5), "12.5")
        XCTAssertEqual(Util.phoneText(50), "50")
        XCTAssertNil(Util.phoneText(Double.nan))
        XCTAssertNil(Util.phoneText(Double.infinity))
        XCTAssertNil(Util.phoneText(true))
        XCTAssertNil(Util.phoneText(nil))
    }

    // MARK: - Göndərmə

    func testBatchSizeIsMeasuredInUtf8Bytes() {
        let rig = Rig()
        rig.store.put(Core.Keys.config, "{\"enabled\":true,\"flush\":{\"max_batch\":100,\"max_queue\":1000}}")
        rig.transport.status = 500
        let core = rig.core()
        // Hər event ~10 000 simvol, amma ~26 KB-dır (iki və üç baytlıq hərflər).
        let blob = String(repeating: "ə", count: 4_000) + String(repeating: "ა", count: 6_000)
        for _ in 0..<40 { core.track("Lead", props: ["blob": blob], eventId: nil) }
        rig.transport.status = 200
        rig.transport.raw.removeAll()
        rig.env.time += 2 * Core.backoffMaxMs
        core.flush(force: true)
        XCTAssertTrue(rig.transport.raw.count >= 3)
        for body in rig.transport.raw { XCTAssertTrue(body.utf8.count <= 500 * 1024, "\(body.utf8.count)") }
        XCTAssertEqual(leads(rig).count, 40)

        // Tək eventin həddi də baytla sayılır: 12 000 simvol, amma 36 KB.
        // Uzun fasilədən sonra yeni sessiya başlaya bilər, ona görə növbənin sayı yox, eventin özü yoxlanır.
        core.track("Contact", props: ["blob": String(repeating: "ა", count: 12_000)], eventId: nil)
        core.flush(force: true)
        XCTAssertTrue(rig.transport.events.filter { ($0["name"] as? String) == "Contact" }.isEmpty)
    }

    func testPayloadTooLargeSplitsTheBatchInsteadOfDroppingIt() {
        let rig = Rig()
        rig.store.put(Core.Keys.config, "{\"enabled\":true,\"flush\":{\"max_batch\":100,\"max_queue\":1000}}")
        rig.transport.status = 500
        let core = rig.core()
        for index in 0..<16 { core.track("Lead", props: ["i": index], eventId: nil) }
        let queued = rig.queue.count
        rig.transport.raw.removeAll()
        rig.env.time += 2 * Core.backoffMaxMs
        rig.transport.respond = { batch in (batch["events"] as? [Any] ?? []).count > 3 ? 413 : 200 }
        core.flush(force: true)
        core.flush(force: true)
        XCTAssertEqual(rig.queue.count, 0)
        XCTAssertEqual(rig.transport.events.count, queued)
        XCTAssertEqual(leads(rig).compactMap { dict($0["props"])["i"] as? Int }, Array(0..<16))

        // Tək event də sığmırsa yalnız o atılır, amma yalnız serverin öz tanınan cavabı ilə (PROTOCOL.md 5.6).
        rig.transport.respond = { _ in 413 }
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        XCTAssertTrue(rig.queue.count > 0, "tanınan gövdəsi olmayan 413 müvəqqətidir")
        rig.transport.postError = "{\"ok\":false,\"error\":\"body_too_large\"}"
        rig.env.time += 2 * Core.backoffMaxMs
        core.flush(force: true)
        XCTAssertEqual(rig.queue.count, 0)
        XCTAssertEqual(rig.transport.events.count, queued)
    }

    func testRedirectResponseKeepsTheBatch() {
        for status in [301, 302, 307, 308] {
            let rig = Rig()
            let core = rig.core()
            core.track("Lead", props: nil, eventId: nil)
            let queued = rig.queue.count
            rig.transport.status = status
            core.flush(force: true)
            XCTAssertEqual(rig.queue.count, queued, "status \(status)")
            rig.transport.status = 200
            core.flush(force: true)
            XCTAssertEqual(rig.queue.count, 0, "status \(status)")
        }
    }

    func testForcedFlushHonoursRetryAfter() {
        let rig = Rig()
        let core = rig.core()
        core.track("Lead", props: nil, eventId: nil)
        rig.transport.status = 429
        rig.transport.retryAfter = 120
        core.flush(force: true)
        let attempts = rig.transport.raw.count
        rig.transport.status = 200
        rig.env.time += 60_000
        core.flush(force: true)
        core.onBackground()
        XCTAssertEqual(rig.transport.raw.count, attempts)
        XCTAssertTrue(rig.queue.count > 0)
        rig.env.time += 61_000
        core.flush(force: true)
        XCTAssertEqual(rig.queue.count, 0)

        // Retry-After olmayan uğursuzluqdan sonra məcburi flush dərhal yenidən cəhd edir.
        rig.transport.retryAfter = nil
        rig.transport.status = 500
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        rig.transport.status = 200
        core.flush(force: true)
        XCTAssertEqual(rig.queue.count, 0)
    }

    func testCorruptedQueueRowsAreDroppedNotRetriedForever() {
        let rig = Rig()
        let core = rig.core()
        core.flush(force: true)
        rig.queue.add(ctx: "{}", payload: "not json")
        rig.queue.add(ctx: "not json", payload: "{\"id\":\"x\"}")
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        XCTAssertEqual(rig.queue.count, 0)
        XCTAssertTrue(rig.transport.names.contains("Lead"))

        // Diskdən oxunan pozulmuş sətirlər növbəyə ümumiyyətlə düşmür.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-rows-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = FileQueue(directory: dir)
        let file = "[{\"ctx\":\"{}\",\"payload\":\"{\\\"n\\\":1}\"},{\"ctx\":5,\"payload\":\"x\"},{\"payload\":\"x\"}]"
        try? Data(file.utf8).write(to: dir.appendingPathComponent("queue.json"))
        XCTAssertEqual(FileQueue(directory: dir).peek(10).map { $0.payload }, ["{\"n\":1}"])
    }

    // MARK: - Sessiya

    func testSessionSurvivesLongForegroundAndRenewsAfterLongBackground() {
        let rig = Rig()
        let core = rig.core()
        core.onForeground()
        core.track("Lead", props: nil, eventId: nil)
        // Ön planda 45 dəqiqə fəaliyyətsizlik sessiyanı bitirmir.
        rig.env.time += 45 * 60_000
        core.track("Lead", props: nil, eventId: nil)
        core.onBackground()
        // Arxa fonda 10 dəqiqə: sessiya eynidir (son eventdən 55 dəqiqə keçsə də).
        rig.env.time += 10 * 60_000
        core.onForeground()
        core.track("Lead", props: nil, eventId: nil)
        core.onBackground()
        // Arxa fonda 31 dəqiqə: yeni sessiya.
        rig.env.time += 31 * 60_000
        core.onForeground()
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        keep(rig)

        let sessions = leads(rig).compactMap { $0["session_id"] as? String }
        XCTAssertEqual(sessions.count, 4)
        guard sessions.count == 4 else { return }
        XCTAssertEqual(sessions[0], sessions[1])
        XCTAssertEqual(sessions[0], sessions[2])
        XCTAssertNotEqual(sessions[0], sessions[3])
        XCTAssertEqual(rig.transport.names.filter { $0 == "SessionStart" }.count, 2)
        XCTAssertEqual(rig.transport.names.filter { $0 == "AppOpen" }.count, 3)
    }

    func testSessionFallsBackToInactivityWhenLifecycleIsNotTracked() {
        let rig = Rig()
        let core = rig.core()
        core.onForeground(tracked: false)
        core.track("Lead", props: nil, eventId: nil)
        rig.env.time += 31 * 60_000
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        let sessions = leads(rig).compactMap { $0["session_id"] as? String }
        XCTAssertEqual(sessions.count, 2)
        guard sessions.count == 2 else { return }
        XCTAssertNotEqual(sessions[0], sessions[1])
        XCTAssertEqual(rig.transport.names.filter { $0 == "AppOpen" }.count, 1)
    }

    func testBackgroundTimeIsMeasuredFromLeavingNotFromLastEvent() {
        let rig = Rig()
        let core = rig.core()
        core.onForeground()
        core.track("Lead", props: nil, eventId: nil)
        // Son eventdən 29 dəqiqə sonra arxa fona keçid, orada daha 29 dəqiqə: sessiya davam edir.
        rig.env.time += 29 * 60_000
        core.onBackground()
        rig.env.time += 29 * 60_000
        core.onForeground()
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        let sessions = leads(rig).compactMap { $0["session_id"] as? String }
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(Set(sessions).count, 1)
    }

    // MARK: - Yeni SDK versiyası xəbərdarlığı

    private func notices(_ rig: Rig) -> [String] {
        return rig.env.logs.filter { $0.contains("is available") }
    }

    func testNewerSdkVersionIsLoggedOnceAcrossConfigRefreshes() {
        let rig = Rig()
        rig.transport.configBody = "{\"enabled\":true,\"sdk_latest\":\"99.0.3\"}"
        let core = rig.core()
        XCTAssertEqual(notices(rig).count, 0, "keşdəki konfiqdə sdk_latest yoxdur")

        core.refreshConfig()
        XCTAssertEqual(notices(rig), ["SmartBee Pixel 99.0.3 is available (this app uses \(pixelSdkVersion)). Update the dependency to get fixes."])

        rig.env.time += 3_600_001
        core.refreshConfig()
        rig.transport.configBody = "{\"enabled\":true,\"sdk_latest\":\"99.1.0\"}"
        core.refreshConfig(force: true)
        core.refreshConfig(force: true)
        XCTAssertEqual(rig.transport.configCalls, 4)
        XCTAssertEqual(notices(rig).count, 1)

        // Keşlənmiş konfiqdəki dəyər növbəti işə düşmədə şəbəkə cavabını gözləmədən oxunur, yenə bir dəfə.
        let cached = Rig()
        cached.store.put(Core.Keys.config, "{\"enabled\":true,\"sdk_latest\":\"99.0.0\"}")
        cached.transport.configBody = "{\"enabled\":true,\"sdk_latest\":\"99.0.0\"}"
        let again = cached.core()
        XCTAssertEqual(notices(cached).count, 1)
        again.refreshConfig(force: true)
        XCTAssertEqual(notices(cached).count, 1)
    }

    func testEqualOlderMalformedOrMissingSdkVersionIsNotLogged() {
        let values = [
            "\"\(pixelSdkVersion)\"", "\"0.0.1\"", "\"1.0\"", "\"99\"", "\"99.0.0.1\"", "\"99.0.0-beta\"", "\"v99.0.0\"",
            "\" 99.0.0\"", "\"99..0\"", "\"99.0.x\"", "\"-99.0.0\"", "\"99999999999999999999.0.0\"", "\"\"",
            "99", "99.5", "true", "null", "[\"99.0.0\"]", "{\"v\":\"99.0.0\"}",
        ]
        for value in values {
            let rig = Rig()
            rig.transport.configBody = "{\"enabled\":true,\"sdk_latest\":\(value)}"
            let core = rig.core()
            core.refreshConfig()
            XCTAssertEqual(rig.transport.configCalls, 1)
            XCTAssertTrue(core.config.enabled, value)
            XCTAssertEqual(notices(rig), [], value)
            // Konfiqin qalan hissəsi əvvəlki kimi işləyir.
            core.track("Lead", props: nil, eventId: nil)
            core.flush(force: true)
            XCTAssertEqual(leads(rig).count, 1, value)
        }

        let missing = Rig()
        missing.transport.configBody = "{\"enabled\":true}"
        missing.core().refreshConfig()
        XCTAssertEqual(notices(missing), [])
    }

    func testSdkVersionNoticeIsSilentWithoutDebug() {
        let rig = Rig(SmartBeeOptions(debug: false))
        rig.store.put(Core.Keys.config, "{\"enabled\":true,\"sdk_latest\":\"99.0.0\"}")
        rig.transport.configBody = "{\"enabled\":true,\"sdk_latest\":\"99.0.0\"}"
        let core = rig.core()
        core.refreshConfig(force: true)
        XCTAssertEqual(rig.transport.configCalls, 1)
        XCTAssertEqual(rig.env.logs, [])
    }

    func testVersionsAreComparedNumerically() {
        XCTAssertTrue(Util.isNewer("1.10.0", than: "1.9.0"))
        XCTAssertFalse(Util.isNewer("1.9.0", than: "1.10.0"))
        XCTAssertTrue(Util.isNewer("2.0.0", than: "1.99.99"))
        XCTAssertTrue(Util.isNewer("1.0.1", than: "1.0.0"))
        XCTAssertTrue(Util.isNewer("1.1.0", than: "1.0.9"))
        XCTAssertFalse(Util.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(Util.isNewer("0.9.9", than: "1.0.0"))
        XCTAssertFalse(Util.isNewer("1.0", than: "0.0.1"))
        XCTAssertFalse(Util.isNewer("9.0.0", than: "garbage"))
        XCTAssertFalse(Util.isNewer("99999999999999999999.0.0", than: "1.0.0"))
        XCTAssertEqual(Util.semver("1.20.300") ?? [], [1, 20, 300])
        XCTAssertNil(Util.semver("1.2"))
        XCTAssertNil(Util.semver("1.2.3.4"))
        XCTAssertNil(Util.semver("1.2.3-rc1"))
        XCTAssertNil(Util.semver("1.+2.3"))
        XCTAssertNil(Util.semver(""))
    }

    // MARK: - Reklam identifikatoru (IDFA) və ATT

    private let idfa = "EA7583CD-A667-48BC-B806-42ECB2B48606"
    private let idfv = "6D92078A-8246-4BA4-AE5B-76104861E7DC"

    /// Bir event göndərir və onun toplusundakı `ctx.ids` obyektini qaytarır.
    private func idsOfNextEvent(_ rig: Rig, _ core: Core) -> [String: Any] {
        rig.transport.raw.removeAll()
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        keep(rig)
        return dict(dict(rig.transport.posts.last?["ctx"])["ids"])
    }

    func testAdvertisingIdIsSentOnlyWhenTrackingIsAuthorized() {
        let rig = Rig()
        rig.env.attNeeded = true
        rig.env.attStatus = "authorized"
        rig.env.idfa = idfa
        let core = rig.core()
        var ids = idsOfNextEvent(rig, core)
        XCTAssertEqual(ids["idfa"] as? String, idfa)
        XCTAssertEqual(ids["att"] as? String, "authorized")
        XCTAssertEqual(ids["idfv"] as? String, idfv)
        XCTAssertEqual(adsFlag(dict(rig.transport.posts.last?["ctx"])), true)
        XCTAssertFalse(rig.env.adCalls.isEmpty)

        // Vəziyyət hər eventdə yenidən oxunur. İcazə yoxdursa toplu reklama yararsızdır: nə IDFA, nə IDFV gedir,
        // `consent.ads` reklam razılığı olsa belə false-dur (yalnız ATT vəziyyəti bildirilir).
        for status in ["denied", "restricted", "not_determined"] {
            rig.env.attStatus = status
            ids = idsOfNextEvent(rig, core)
            XCTAssertEqual(Set(ids.keys), ["att"], status)
            XCTAssertEqual(ids["att"] as? String, status)
            XCTAssertEqual(adsFlag(dict(rig.transport.posts.last?["ctx"])), false, status)
            XCTAssertFalse(rig.transport.raw.joined().contains(idfa), status)
            XCTAssertFalse(rig.transport.raw.joined().contains(idfv), status)
        }

        // İstifadəçi icazə pəncərəsinə sonradan cavab verdi.
        rig.env.attStatus = "authorized"
        ids = idsOfNextEvent(rig, core)
        XCTAssertEqual(ids["idfa"] as? String, idfa)
        XCTAssertEqual(ids["att"] as? String, "authorized")
        XCTAssertEqual(adsFlag(dict(rig.transport.posts.last?["ctx"])), true)

        // Tanınmayan və ya oxunmayan vəziyyət icazə sayılmır.
        for status in ["something_new", nil] as [String?] {
            rig.env.attStatus = status
            ids = idsOfNextEvent(rig, core)
            XCTAssertTrue(ids.isEmpty)
            XCTAssertEqual(adsFlag(dict(rig.transport.posts.last?["ctx"])), false)
        }

        // iOS 13: ATT yoxdur, mühit IDFA-nı yalnız sistem izləməyə icazə verəndə qaytarır.
        rig.env.attNeeded = false
        rig.env.attStatus = nil
        ids = idsOfNextEvent(rig, core)
        XCTAssertEqual(Set(ids.keys), ["idfv", "idfa"])
        XCTAssertEqual(ids["idfa"] as? String, idfa)
        XCTAssertEqual(adsFlag(dict(rig.transport.posts.last?["ctx"])), true)
        rig.env.idfa = nil
        ids = idsOfNextEvent(rig, core)
        XCTAssertEqual(Set(ids.keys), ["idfv"])
    }

    func testZeroOrInvalidAdvertisingIdIsNotSent() {
        let rig = Rig()
        rig.env.attStatus = "authorized"
        let core = rig.core()
        for value in ["00000000-0000-0000-0000-000000000000", "not-a-uuid", "", "EA7583CD-A667-48BC-B806"] {
            rig.env.idfa = value
            let ids = idsOfNextEvent(rig, core)
            XCTAssertNil(ids["idfa"], value)
            XCTAssertEqual(ids["att"] as? String, "authorized")
        }
        rig.env.idfa = idfa.lowercased()
        XCTAssertEqual(idsOfNextEvent(rig, core)["idfa"] as? String, idfa)

        XCTAssertNil(Util.advertisingId(nil))
        XCTAssertNil(Util.advertisingId("00000000-0000-0000-0000-000000000000"))
        XCTAssertEqual(Util.advertisingId(idfa), idfa)
    }

    func testWithoutAdsConsentAdvertisingIdAndStatusAreNotSent() {
        let rig = Rig(SmartBeeOptions(consent: SmartBeeConsent(analytics: true, ads: false), debug: true))
        rig.env.attStatus = "authorized"
        rig.env.idfa = idfa
        let core = rig.core()
        XCTAssertTrue(idsOfNextEvent(rig, core).isEmpty)
        XCTAssertFalse(rig.transport.raw.joined().contains(idfa))
        XCTAssertFalse(rig.transport.raw.joined().contains("\"att\""))
        XCTAssertTrue(rig.env.adCalls.isEmpty, "reklam razılığı yoxdursa identifikator oxunmur")

        // Razılıq verildi, sonra sessiyanın ortasında geri alındı.
        core.setConsent(analytics: nil, ads: true)
        let granted = idsOfNextEvent(rig, core)
        XCTAssertEqual(granted["idfa"] as? String, idfa)
        XCTAssertEqual(granted["att"] as? String, "authorized")

        core.setConsent(analytics: nil, ads: false)
        XCTAssertTrue(idsOfNextEvent(rig, core).isEmpty)
        XCTAssertFalse(rig.transport.raw.joined().contains(idfa))
        XCTAssertFalse(rig.transport.raw.joined().contains("\"att\""))

        // Seçim saxlanır: yenidən başlayandan sonra da göndərilmir.
        let restarted = rig.core()
        XCTAssertTrue(idsOfNextEvent(rig, restarted).isEmpty)
        XCTAssertFalse(rig.transport.raw.joined().contains(idfa))
    }

    func testWithdrawingAdsConsentStripsIdentifiersFromQueuedEvents() {
        let rig = Rig()
        rig.env.attStatus = "authorized"
        rig.env.idfa = idfa
        rig.transport.status = 500
        let core = rig.core()
        core.onDeepLink("https://shop.az/p/1?utm_source=fb&fbclid=FB1")
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        let queued = rig.queue.rows.map { $0.ctx }.joined()
        XCTAssertTrue(queued.contains(idfa))
        XCTAssertTrue(queued.contains(idfv))
        XCTAssertTrue(queued.contains("FB1"))

        core.setConsent(analytics: nil, ads: false)
        rig.transport.status = 200
        rig.transport.raw.removeAll()
        rig.env.time += 2 * Core.backoffMaxMs
        core.flush(force: true)
        keep(rig)

        XCTAssertEqual(rig.queue.count, 0)
        XCTAssertEqual(leads(rig).count, 1)
        XCTAssertFalse(rig.transport.posts.isEmpty)
        for post in rig.transport.posts {
            XCTAssertNil(dict(post["ctx"])["ids"])
        }
        let sent = rig.transport.raw.joined()
        XCTAssertFalse(sent.contains(idfa))
        XCTAssertFalse(sent.contains(idfv))
        XCTAssertFalse(sent.contains("\"att\""))
        XCTAssertFalse(sent.contains("\"fbclid\""))
        XCTAssertTrue(sent.contains("\"utm_source\""))
    }

    // MARK: - Reklam razılığının geri alınması və növbədəki eventlər

    private let campaignLink = "https://shop.az/p/1?utm_source=fb&utm_campaign=spring&fbclid=FB1&gclid=G1"

    private func eventNames(_ post: [String: Any]) -> [String] {
        let events = post["events"] as? [[String: Any]] ?? []
        return events.map { $0["name"] as? String ?? "" }
    }

    /// `name` eventinin getdiyi toplunun konteksti.
    private func context(_ rig: Rig, of name: String) -> [String: Any] {
        let post = rig.transport.posts.last(where: { eventNames($0).contains(name) })
        return dict(post?["ctx"])
    }

    private func adsFlag(_ ctx: [String: Any]) -> Bool? {
        return dict(ctx["consent"])["ads"] as? Bool
    }

    private func assertStripped(_ ctx: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(ctx["ids"], file: file, line: line)
        XCTAssertEqual(adsFlag(ctx), false, file: file, line: line)
        XCTAssertEqual(dict(ctx["consent"])["analytics"] as? Bool, true, file: file, line: line)
        let campaign = dict(ctx["campaign"])
        for id in Util.clickIds { XCTAssertNil(campaign[id], id, file: file, line: line) }
    }

    func testRowsQueuedBeforeAdsWithdrawalAreSentStrippedAndMarkedAdsFalse() {
        let rig = Rig()
        rig.env.attStatus = "authorized"
        rig.env.idfa = idfa
        let core = rig.core()
        core.onDeepLink(campaignLink)
        core.track("Queued", props: nil, eventId: nil)
        let stored = rig.queue.rows.map { $0.ctx }
        let last = Util.parseObject(stored.last ?? "") ?? [:]
        XCTAssertEqual(adsFlag(last), true)
        XCTAssertEqual(Set(dict(last["campaign"]).keys), ["utm_source", "utm_campaign", "fbclid", "gclid"])
        XCTAssertEqual(dict(last["ids"])["idfa"] as? String, idfa)

        core.setConsent(analytics: nil, ads: false)
        // Reklam məlumatı növbədəki sətirlərdən də dərhal silinir (göndəriş anını gözləmir).
        XCTAssertEqual(rig.queue.rows.count, stored.count)
        for row in rig.queue.rows {
            assertStripped(Util.parseObject(row.ctx) ?? [:])
        }
        XCTAssertFalse(rig.queue.rows.map { $0.ctx }.joined().contains(idfa))
        // Uğursuz göndəriş: gövdə təmizlənmiş gedir, sətirlər növbədə qalır.
        rig.transport.status = 500
        core.flush(force: true)
        XCTAssertEqual(rig.queue.rows.count, stored.count)
        XCTAssertFalse(rig.transport.raw.isEmpty)

        rig.transport.status = 200
        rig.env.time += 2 * Core.backoffMaxMs
        core.flush(force: true)
        keep(rig)
        XCTAssertEqual(rig.queue.count, 0)

        XCTAssertFalse(rig.transport.posts.isEmpty)
        for post in rig.transport.posts {
            assertStripped(dict(post["ctx"]))
        }
        let sent = rig.transport.raw.joined()
        XCTAssertFalse(sent.contains(idfa))
        XCTAssertFalse(sent.contains(idfv))
        XCTAssertFalse(sent.contains("\"att\""))
        // UTM parametrləri qalır.
        let campaign = dict(context(rig, of: "Queued")["campaign"])
        XCTAssertEqual(Set(campaign.keys), ["utm_source", "utm_campaign"])
        XCTAssertEqual(campaign["utm_campaign"] as? String, "spring")
    }

    func testCampaignWithOnlyClickIdsDisappearsFromQueuedRows() {
        let rig = Rig()
        let core = rig.core()
        core.onDeepLink("https://shop.az/p/1?fbclid=FB1")
        core.track("Queued", props: nil, eventId: nil)
        XCTAssertTrue((rig.queue.rows.last?.ctx ?? "").contains("FB1"))
        core.setConsent(analytics: nil, ads: false)
        core.flush(force: true)
        keep(rig)
        let ctx = context(rig, of: "Queued")
        XCTAssertNil(ctx["campaign"])
        assertStripped(ctx)
    }

    func testRowsQueuedWithoutAdsConsentStayAdsFalseAfterRegrant() {
        let rig = Rig(SmartBeeOptions(consent: SmartBeeConsent(analytics: true, ads: false), debug: true))
        rig.env.attStatus = "authorized"
        rig.env.idfa = idfa
        let core = rig.core()
        core.onDeepLink(campaignLink)
        core.track("WhileOff", props: nil, eventId: nil)
        core.setConsent(analytics: nil, ads: true)
        core.track("AfterGrant", props: nil, eventId: nil)
        core.flush(force: true)
        keep(rig)

        let off = context(rig, of: "WhileOff")
        assertStripped(off)
        XCTAssertEqual(Set(dict(off["campaign"]).keys), ["utm_source", "utm_campaign"])

        let on = context(rig, of: "AfterGrant")
        XCTAssertEqual(adsFlag(on), true)
        XCTAssertEqual(dict(on["ids"])["idfa"] as? String, idfa)
        // Reklam razılığı olmadan gələn klik ID-ləri diskə yazılmır: razılıq sonradan veriləndə üzə çıxmır.
        XCTAssertEqual(Set(dict(on["campaign"]).keys), ["utm_source", "utm_campaign"])
        let granted = rig.transport.posts.last(where: { eventNames($0).contains("AfterGrant") }) ?? [:]
        XCTAssertFalse(eventNames(granted).contains("WhileOff"))
    }

    /// Növbə: razılıqla, razılıqsız və yenidən razılıqla yaranmış sətirlər (hamısı eyni kampaniya ilə).
    private func mixedQueue() -> (rig: Rig, core: Core) {
        let rig = Rig()
        rig.env.attStatus = "authorized"
        rig.env.idfa = idfa
        let core = rig.core()
        core.onDeepLink(campaignLink)
        core.track("A", props: nil, eventId: nil)
        core.setConsent(analytics: nil, ads: false)
        core.track("B", props: nil, eventId: nil)
        core.setConsent(analytics: nil, ads: true)
        core.track("C", props: nil, eventId: nil)
        XCTAssertEqual(rig.transport.raw.count, 0)
        return (rig: rig, core: core)
    }

    func testMixedQueueKeepsRowConsentWhileAdsConsentIsGranted() {
        let mixed = mixedQueue()
        let rig = mixed.rig
        mixed.core.flush(force: true)
        keep(rig)
        // Razılıq geri alınanda növbədə olan sətirlər (A) diskdə təmizlənir və razılıq yenidən veriləndən sonra da
        // reklama yararsız gedir; yalnız yenidən veriləndən sonra yaranan sətir (C) yararlıdır.
        assertStripped(context(rig, of: "SessionStart"))
        assertStripped(context(rig, of: "A"))
        assertStripped(context(rig, of: "B"))
        XCTAssertEqual(adsFlag(context(rig, of: "C")), true)
        let last = rig.transport.posts.last ?? [:]
        XCTAssertEqual(eventNames(last), ["C"])
        XCTAssertEqual(linkUrls(rig), ["https://shop.az/p/1?utm_source=fb&utm_campaign=spring"])
        // Razılıq geri alınanda saxlanmış klik ID-ləri diskdən də silinir və yenidən veriləndə qayıtmır.
        XCTAssertNil(dict(context(rig, of: "C")["campaign"])["fbclid"])
        XCTAssertEqual(dict(context(rig, of: "C")["ids"])["idfa"] as? String, idfa)
    }

    func testMixedQueueCollapsesIntoOneContextAfterWithdrawal() {
        let mixed = mixedQueue()
        let rig = mixed.rig
        mixed.core.setConsent(analytics: nil, ads: false)
        mixed.core.flush(force: true)
        keep(rig)
        // Kampaniyasız başlanğıc eventləri ayrıca topludadır; qalanları indi yalnız reklam sahələri ilə fərqlənirdi.
        XCTAssertEqual(rig.transport.posts.map { eventNames($0) }, [["SessionStart", "AppInstall"], ["DeepLinkOpen", "A", "B", "C"]])
        for post in rig.transport.posts {
            assertStripped(dict(post["ctx"]))
        }
        XCTAssertFalse(rig.transport.raw.joined().contains(idfa))
        XCTAssertEqual(Set(dict(context(rig, of: "C")["campaign"]).keys), ["utm_source", "utm_campaign"])
        let seqs = rig.transport.events.compactMap { $0["seq"] as? Int }
        XCTAssertEqual(seqs, seqs.sorted())
        XCTAssertEqual(seqs.count, 6)
    }

    func testContextIsSentUnchangedWhileAdsConsentStaysGranted() {
        let rig = Rig()
        rig.env.attStatus = "authorized"
        rig.env.idfa = idfa
        let core = rig.core()
        core.onDeepLink(campaignLink)
        core.track("Lead", props: nil, eventId: nil)
        var stored: [String] = []
        for row in rig.queue.rows where stored.last != row.ctx { stored.append(row.ctx) }
        XCTAssertEqual(stored.count, 2)
        core.flush(force: true)
        keep(rig)

        XCTAssertEqual(rig.transport.posts.count, 2)
        for (index, post) in rig.transport.posts.enumerated() where index < stored.count {
            let before = Util.parseObject(stored[index]) ?? [:]
            XCTAssertEqual(before as NSDictionary, dict(post["ctx"]) as NSDictionary)
        }
        let ctx = context(rig, of: "Lead")
        XCTAssertEqual(adsFlag(ctx), true)
        XCTAssertEqual(dict(ctx["ids"])["idfa"] as? String, idfa)
        XCTAssertEqual(Set(dict(ctx["campaign"]).keys), ["utm_source", "utm_campaign", "fbclid", "gclid"])
    }

    func testAdvertisingIdCanBeTurnedOffByOption() {
        XCTAssertTrue(SmartBeeOptions().collectAdvertisingId)
        // iOS 14+: seçim sönülüdürsə nə IDFA, nə IDFV, nə də ATT vəziyyəti oxunur; icazə məlum olmadığından
        // toplu reklama yararsızdır.
        let rig = Rig(SmartBeeOptions(debug: true, collectAdvertisingId: false))
        rig.env.attNeeded = true
        rig.env.attStatus = "authorized"
        rig.env.idfa = idfa
        let core = rig.core()
        core.onDeepLink(campaignLink)
        XCTAssertTrue(idsOfNextEvent(rig, core).isEmpty)
        XCTAssertEqual(adsFlag(dict(rig.transport.posts.last?["ctx"])), false)
        let sent = rig.transport.raw.joined()
        XCTAssertFalse(sent.contains(idfa))
        XCTAssertFalse(sent.contains(idfv))
        XCTAssertFalse(sent.contains("\"att\""))
        XCTAssertFalse(sent.contains("FB1"))
        XCTAssertTrue(rig.env.adCalls.isEmpty, "seçim sönülüdürsə sistemdən heç nə oxunmur")

        // iOS 13 (ATT yoxdur): razılıq kifayətdir, identifikatorlar yenə göndərilmir.
        let old = Rig(SmartBeeOptions(debug: true, collectAdvertisingId: false))
        old.env.idfa = idfa
        let oldCore = old.core()
        XCTAssertTrue(idsOfNextEvent(old, oldCore).isEmpty)
        XCTAssertEqual(adsFlag(dict(old.transport.posts.last?["ctx"])), true)
        XCTAssertFalse(old.transport.raw.joined().contains(idfv))
        XCTAssertTrue(old.env.adCalls.isEmpty)
    }

    // MARK: - İzləmə icazəsi (ATT) növbədəki eventlərdən sonra geri alınıb

    /// IDFA ilə növbəyə düşmüş eventi icazənin yeni vəziyyətində göndərir və onun toplusundakı `ctx.ids` obyektini qaytarır.
    private func idsAfterPermissionChange(from: String?, to: String?, idfaAfter: String?) -> [String: Any] {
        let rig = Rig()
        // Vəziyyəti olan mühit iOS 14+-dır; nil iOS 13-dür (ATT yoxdur).
        rig.env.attNeeded = from != nil
        rig.env.attStatus = from
        rig.env.idfa = idfa
        let core = rig.core()
        core.track("Queued", props: nil, eventId: nil)
        XCTAssertTrue(rig.queue.rows.map { $0.ctx }.joined().contains(idfa))

        rig.env.attStatus = to
        rig.env.idfa = idfaAfter
        core.flush(force: true)
        keep(rig)
        XCTAssertEqual(rig.queue.count, 0)
        let ctx = context(rig, of: "Queued")
        // Toplu yalnız icazə yerində qalanda reklama yararlıdır.
        XCTAssertEqual(adsFlag(ctx), to == nil || to == "authorized")
        return dict(ctx["ids"])
    }

    func testRevokedTrackingPermissionRemovesIdfaFromQueuedRows() {
        let rig = Rig()
        rig.env.attNeeded = true
        rig.env.attStatus = "authorized"
        rig.env.idfa = idfa
        let core = rig.core()
        core.onDeepLink(campaignLink)
        core.track("Queued", props: nil, eventId: nil)
        let stored = rig.queue.rows.map { $0.ctx }
        XCTAssertTrue(stored.joined().contains(idfa))

        // İstifadəçi Ayarlarda izləmə icazəsini geri aldı. Saxta mühit identifikatoru yenə qaytarır:
        // onu göndərib-göndərməməyi Core özü həll etməlidir.
        rig.env.attStatus = "denied"
        // Uğursuz göndəriş: gövdə artıq reklam məlumatsız gedir və reklam məlumatı növbədəki sətirlərdən də silinir.
        rig.transport.status = 500
        core.flush(force: true)
        XCTAssertEqual(rig.queue.rows.count, stored.count)
        let kept = rig.queue.rows.map { $0.ctx }.joined()
        XCTAssertFalse(kept.contains(idfa))
        XCTAssertFalse(kept.contains(idfv))
        XCTAssertFalse(kept.contains("FB1"))
        XCTAssertFalse(rig.transport.raw.isEmpty)
        XCTAssertFalse(rig.transport.raw.joined().contains(idfa))

        rig.transport.status = 200
        rig.transport.raw.removeAll()
        rig.env.time += 2 * Core.backoffMaxMs
        core.track("After", props: nil, eventId: nil)
        core.flush(force: true)
        keep(rig)
        XCTAssertEqual(rig.queue.count, 0)
        let sent = rig.transport.raw.joined()
        XCTAssertFalse(sent.contains(idfa))
        XCTAssertFalse(sent.contains(idfv))
        XCTAssertFalse(sent.contains("FB1"))
        XCTAssertFalse(sent.contains("G1"))

        // İcazəsiz toplu reklama yararsızdır: yalnız ATT vəziyyəti, klik ID-lərsiz kampaniya, `consent.ads = false`.
        let ctx = context(rig, of: "Queued")
        let ids = dict(ctx["ids"])
        XCTAssertEqual(Set(ids.keys), ["att"])
        XCTAssertEqual(ids["att"] as? String, "denied")
        XCTAssertEqual(adsFlag(ctx), false)
        XCTAssertEqual(Set(dict(ctx["campaign"]).keys), ["utm_source", "utm_campaign"])
        // Köhnə sətir indi icazəsiz yaranmış sətirlə eyni kontekstdədir və eyni topluda gedir.
        let post = rig.transport.posts.last(where: { eventNames($0).contains("Queued") }) ?? [:]
        XCTAssertTrue(eventNames(post).contains("After"))
    }

    func testQueuedIdfaFollowsThePermissionStateAtSendTime() {
        for status in ["denied", "restricted", "not_determined"] {
            let ids = idsAfterPermissionChange(from: "authorized", to: status, idfaAfter: idfa)
            XCTAssertEqual(Set(ids.keys), ["att"], status)
            XCTAssertEqual(ids["att"] as? String, status)
        }

        // İcazə yerindədir, amma sistem identifikator vermir (sıfır UUID).
        var ids = idsAfterPermissionChange(from: "authorized", to: "authorized", idfaAfter: "00000000-0000-0000-0000-000000000000")
        XCTAssertEqual(Set(ids.keys), ["idfv", "att"])
        XCTAssertEqual(ids["att"] as? String, "authorized")

        // iOS 13 (ATT yoxdur): «Reklam izləməsini məhdudlaşdır» açılıb, sistem identifikatoru qaytarmır.
        ids = idsAfterPermissionChange(from: nil, to: nil, idfaAfter: nil)
        XCTAssertEqual(Set(ids.keys), ["idfv"])

        // İcazə dəyişməyibsə IDFA yerində qalır.
        ids = idsAfterPermissionChange(from: "authorized", to: "authorized", idfaAfter: idfa)
        XCTAssertEqual(ids["idfa"] as? String, idfa)
        XCTAssertEqual(ids["att"] as? String, "authorized")
        ids = idsAfterPermissionChange(from: nil, to: nil, idfaAfter: idfa)
        XCTAssertEqual(Set(ids.keys), ["idfv", "idfa"])
    }

    func testQueuedIdfaIsDroppedWhenCollectionIsTurnedOffInTheNextRun() {
        let rig = Rig()
        rig.env.attNeeded = true
        rig.env.attStatus = "authorized"
        rig.env.idfa = idfa
        rig.core().track("Queued", props: nil, eventId: nil)
        XCTAssertTrue(rig.queue.rows.map { $0.ctx }.joined().contains(idfa))

        // Tətbiqin yeni versiyası identifikatorun toplanmasını söndürüb; növbə əvvəlki işə düşmədən qalıb.
        rig.options.collectAdvertisingId = false
        rig.env.adCalls.removeAll()
        rig.core().flush(force: true)
        keep(rig)
        XCTAssertEqual(rig.queue.count, 0)
        XCTAssertFalse(rig.transport.raw.joined().contains(idfa))
        XCTAssertFalse(rig.transport.raw.joined().contains(idfv))
        let ctx = context(rig, of: "Queued")
        XCTAssertNil(ctx["ids"])
        XCTAssertEqual(adsFlag(ctx), false)
        XCTAssertTrue(rig.env.adCalls.isEmpty, "seçim sönülüdürsə sistemdən heç nə oxunmur")
    }

    // MARK: - DeepLinkOpen eventinin ünvanı və reklam razılığı

    private func linkUrls(_ rig: Rig) -> [String] {
        return rig.transport.events.filter { ($0["name"] as? String) == "DeepLinkOpen" }.compactMap { dict($0["props"])["url"] as? String }
    }

    private func assertNoClickIds(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        for id in Util.clickIds { XCTAssertFalse(text.contains(id), id, file: file, line: line) }
    }

    func testDeepLinkUrlHasNoClickIdsWhenQueuedWithoutAdsConsent() {
        let rig = Rig(SmartBeeOptions(consent: SmartBeeConsent(analytics: true, ads: false), debug: true))
        let core = rig.core()
        core.onDeepLink("https://shop.az/p/1?a=1&fbclid=FB1&utm_source=fb&GCLID=G1&gbraid=GB&wbraid=WB&ttclid=TT&msclkid=MS&q=a%20b+c#frag")
        // Klik ID-ləri növbəyə (diskə) də düşmür.
        assertNoClickIds(rig.queue.rows.last?.payload ?? "fbclid")
        assertNoClickIds(rig.queue.rows.last?.ctx ?? "fbclid")

        // Razılıq sonradan verilsə də razılıqsız yaranmış sətir dəyişmir.
        core.setConsent(analytics: nil, ads: true)
        core.flush(force: true)
        keep(rig)
        XCTAssertEqual(linkUrls(rig), ["https://shop.az/p/1?a=1&utm_source=fb&q=a%20b+c"])
        assertNoClickIds(rig.transport.raw.joined())
    }

    func testQueuedDeepLinkUrlLosesClickIdsWhenAdsConsentIsWithdrawn() {
        let rig = Rig()
        let core = rig.core()
        core.onDeepLink(campaignLink)
        core.track("Lead", props: ["url": campaignLink], eventId: nil)
        let stored = rig.queue.rows.map { $0.payload }
        XCTAssertTrue(stored.joined().contains("fbclid"))

        core.setConsent(analytics: nil, ads: false)
        // Klik ID-ləri növbədəki sətirlərdən dərhal silinir: DeepLinkOpen-dən də, tətbiqin öz eventinin ünvan dəyərindən də.
        XCTAssertEqual(rig.queue.rows.count, stored.count)
        for row in rig.queue.rows {
            let event = Util.parseObject(row.payload) ?? [:]
            let url = dict(event["props"])["url"] as? String
            if (event["name"] as? String) == "DeepLinkOpen" {
                XCTAssertEqual(url, "https://shop.az/p/1?utm_source=fb&utm_campaign=spring")
            } else if (event["name"] as? String) == "Lead" {
                XCTAssertEqual(url, "https://shop.az/p/1?utm_source=fb&utm_campaign=spring")
            }
        }
        // Uğursuz göndəriş: sətirlər növbədə qalır.
        rig.transport.status = 500
        core.flush(force: true)
        XCTAssertEqual(rig.queue.rows.count, stored.count)

        rig.transport.status = 200
        rig.transport.raw.removeAll()
        rig.env.time += 2 * Core.backoffMaxMs
        core.flush(force: true)
        keep(rig)
        XCTAssertEqual(rig.queue.count, 0)
        XCTAssertEqual(linkUrls(rig), ["https://shop.az/p/1?utm_source=fb&utm_campaign=spring"])
        for post in rig.transport.posts {
            assertStripped(dict(post["ctx"]))
        }
        // Tətbiqin öz eventinin ünvan dəyərindən də klik ID-ləri silinir (veb tracker-in scrubEvents funksiyası kimi).
        XCTAssertEqual(leads(rig).count, 1)
        XCTAssertEqual(dict(leads(rig).first?["props"])["url"] as? String, "https://shop.az/p/1?utm_source=fb&utm_campaign=spring")
    }

    func testHeldDeepLinkLosesClickIdsWhenServerDefaultDeniesAds() {
        // İlk işə düşmə: razılıq hələ məlum deyil, keçid yaddaşda gözləyir; konfiq reklam razılığını rədd edir.
        let rig = Rig(fresh: true)
        rig.transport.configBody = "{\"enabled\":true,\"consent_default\":{\"analytics\":true,\"ads\":false}}"
        let core = rig.core()
        core.onDeepLink(campaignLink)
        XCTAssertEqual(rig.queue.count, 0)
        core.flush(force: true)
        keep(rig)
        XCTAssertEqual(linkUrls(rig), ["https://shop.az/p/1?utm_source=fb&utm_campaign=spring"])
        assertNoClickIds(rig.transport.raw.joined())
    }

    func testClickIdsAreStrippedFromUrlWithoutTouchingTheRest() {
        XCTAssertEqual(Util.stripClickIds("https://a.az/?fbclid=1"), "https://a.az/")
        // Hash marşrutunun query-sindən də çıxır; marşrut olmayan fraqment ünvanda qalmır (veb tracker ilə eyni qayda).
        XCTAssertEqual(Util.stripClickIds("https://a.az/p?x=1&fbclid=1#/f?gclid=2&y=1"), "https://a.az/p?x=1#/f?y=1")
        XCTAssertEqual(Util.stripClickIds("https://a.az/p?x=1&fbclid=1#f?gclid=2"), "https://a.az/p?x=1")
        XCTAssertEqual(Util.stripClickIds("myapp://p?FbClId=1&utm_source=fb"), "myapp://p?utm_source=fb")
        XCTAssertEqual(Util.stripClickIds("https://a.az/p?%66bclid=1&gclid=2&gbraid=3&wbraid=4&ttclid=5&msclkid=6"), "https://a.az/p")
        XCTAssertEqual(Util.stripClickIds("https://a.az/p?a=1&gclid&b=2"), "https://a.az/p?a=1&b=2")
        let unchanged = [
            "https://a.az/p?x=%41&y=a+b&utm_source=fb&z=%D9%85", "https://a.az/p?fbclidx=1&xfbclid=2", "https://a.az/p",
            "https://a.az/p?a==1", "myapp://p#/x", "",
        ]
        for url in unchanged { XCTAssertEqual(Util.stripClickIds(url), url) }
    }

    // MARK: - Nüvə başlamamış arxa fona keçid

    func testForegroundQueuedBeforeStartIsSkippedWhenAppLeftMeanwhile() {
        let rig = Rig()
        let gate = LaunchGate()
        // Gözləmə siyahısı: tətbiq açıldı və nüvə başlamamış arxa fona keçdi.
        var pending: [(Core) -> Void] = [gate.foreground()]
        gate.leftBeforeStart()
        pending.append({ $0.onBackground() })

        let core = rig.core()
        for call in pending { call(core) }
        // Arxa fona keçid növbəni göndərir; AppOpen arxa fonda göndərilmir.
        XCTAssertEqual(rig.transport.names, ["SessionStart", "AppInstall"])
        XCTAssertEqual(rig.queue.count, 0)

        // Nüvə özünü ön planda saymır: arxa fonda uzun fasilədən sonra sessiya yenilənir.
        rig.env.time += 1_800_001
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        XCTAssertEqual(rig.transport.names, ["SessionStart", "AppInstall", "SessionStart", "Lead"])

        // Qayıdış: yeni ön plan keçidi işləyir və AppOpen bir dəfə gedir.
        gate.foreground()(core)
        core.flush(force: true)
        keep(rig)
        XCTAssertEqual(rig.transport.names.filter { $0 == "AppOpen" }.count, 1)
    }

    func testForegroundQueuedBeforeStartRunsWhenAppStayedOpen() {
        let rig = Rig()
        let gate = LaunchGate()
        let open = gate.foreground()
        let core = rig.core()
        open(core)
        core.flush(force: true)
        XCTAssertEqual(rig.transport.names, ["SessionStart", "AppInstall", "AppOpen"])

        // Yalnız arxa fona keçiddən əvvəl verilmiş çağırışlar köhnəlir.
        let stale = gate.foreground()
        gate.leftBeforeStart()
        let live = gate.foreground()
        stale(core)
        core.flush(force: true)
        XCTAssertEqual(rig.transport.names.filter { $0 == "AppOpen" }.count, 1)
        live(core)
        core.flush(force: true)
        XCTAssertEqual(rig.transport.names.filter { $0 == "AppOpen" }.count, 2)
    }

    func testAppleEnvReadsNoAdvertisingIdOutsideIos() {
        let info = AppleEnv(snapshot: [:]).advertising(includeId: true)
        #if os(macOS)
        XCTAssertNil(info.status)
        XCTAssertNil(info.idfa)
        #else
        // iOS / tvOS: IDFA yalnız `authorized` vəziyyətində (və ya ATT olmayan sistemdə) qaytarılır.
        if let status = info.status {
            XCTAssertTrue(Core.attStatuses.contains(status))
            if status != Core.attAuthorized { XCTAssertNil(info.idfa) }
        }
        #endif
    }
}
