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

    func post(url: String, json: String) -> HttpResult {
        urls.append(url)
        raw.append(json)
        return HttpResult(status: status, retryAfterSec: retryAfter)
    }

    func get(url: String, etag: String?) -> HttpResult {
        configCalls += 1
        lastEtag = etag
        urls.append(url)
        return HttpResult(status: configStatus, body: configStatus == 200 ? configBody : nil, etag: configEtag)
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

private final class Rig {
    let store = FakeStore()
    let queue = FakeQueue()
    let transport = FakeTransport()
    let env = FakeEnv()
    var options: SmartBeeOptions

    init(_ options: SmartBeeOptions = SmartBeeOptions(debug: true)) {
        self.options = options
    }

    func core() -> Core {
        let core = Core(key: key, options: options, store: store, queue: queue, transport: transport, env: env)
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
        let rig = Rig(SmartBeeOptions(consent: Consent(analytics: false, ads: false)))
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
        rig.transport.configStatus = 404
        core.refreshConfig(force: true)
        XCTAssertFalse(core.config.enabled)
        core.track("Lead", props: nil, eventId: nil)
        XCTAssertEqual(rig.queue.count, 0)
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
        XCTAssertEqual(config?.flushIntervalMs, 1000)
        XCTAssertEqual(config?.blockedEvents, ["A"])
        XCTAssertEqual(config?.auto("screens"), false)
        XCTAssertEqual(config?.auto("lifecycle"), true)
    }

    // MARK: - Audit (AUDIT.md, bölmə 6)

    func testUrlCleaningMatchesWebAndAndroid() {
        XCTAssertEqual(
            Util.cleanUrl("myapp://u/Farid.Test@Example.com/orders?ref=a%40b.az&x=1&refresh_token=zz&API_KEY=k"),
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
        let core = Core(key: key, options: SmartBeeOptions(), store: FileStore(directory: dir), queue: queue, transport: transport, env: env)
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
        XCTAssertEqual(URLSessionTransport(debug: false).post(url: "http://example.invalid/v1/e", json: "{}").status, 400)
        XCTAssertEqual(URLSessionTransport(debug: false).get(url: "http://example.invalid/v1/x/config", etag: nil).status, 400)
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
}
