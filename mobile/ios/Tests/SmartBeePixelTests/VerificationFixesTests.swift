import Foundation
import XCTest
@testable import SmartBeePixel

private let verifyKey = "demo0ios01"
private let verifyIdfa = "EA7583CD-A667-48BC-B806-42ECB2B48606"
private let verifyIdfv = "6D92078A-8246-4BA4-AE5B-76104861E7DC"

private final class VerifyStore: Store {
    var map: [String: String] = [:]
    /// Yaddaş faylı pozulmuş kimi davranır.
    var broken = false
    func get(_ key: String) -> String? { return map[key] }
    func put(_ key: String, _ value: String) { map[key] = value }
    func remove(_ key: String) { map[key] = nil }
    var corrupt: Bool { return broken }
}

private final class VerifyQueue: EventQueue {
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

private final class VerifyTransport: Transport {
    /// Qəbul olunmuş toplular.
    var raw: [String] = []
    var attempts = 0
    var status = 200
    var postError: String?
    var configStatus = 200
    var configBody: String?
    var configCalls = 0
    /// Hər toplu sorğusundan sonra, cavab qaytarılmazdan əvvəl çağırılır (arqument: sorğunun sıra nömrəsi, 1-dən).
    var onPost: ((Int) -> Void)?

    func post(url: String, json: String) -> HttpResult {
        attempts += 1
        let accepted = status >= 200 && status <= 299
        if accepted { raw.append(json) }
        onPost?(attempts)
        return HttpResult(status: status, body: accepted ? nil : postError)
    }

    func get(url: String, etag: String?) -> HttpResult {
        configCalls += 1
        return HttpResult(status: configStatus, body: configStatus == 200 ? configBody : nil, etag: "W/\"1\"")
    }

    var posts: [[String: Any]] { return raw.compactMap { Util.parseObject($0) } }
    var events: [[String: Any]] { return posts.flatMap { $0["events"] as? [[String: Any]] ?? [] } }
}

private final class VerifyEnv: Env {
    var time: Int64 = 1_795_590_000_000
    private var counter = 0
    var logs: [String] = []
    var attStatus: String?
    var idfa: String?
    var attNeeded = false

    func advertising(includeId: Bool) -> AdvertisingInfo {
        return AdvertisingInfo(status: attStatus, idfa: idfa)
    }

    func attRequired() -> Bool { return attNeeded }
    func random() -> Double { return 0.0 }
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
            "app": ["id": "az.smartbee.demo", "version": "1.2.3", "build": "45"],
            "os": ["name": "iOS", "version": "18.1"],
            "device": ["manufacturer": "Apple", "model": "iPhone16,1", "type": "phone"],
            "ids": ["idfv": verifyIdfv],
        ]
    }
}

/// Susmaya görə konfiq artıq bir dəfə alınıb keşlənmiş tətbiqi təqlid edir; `fresh = true`: ilk işə düşmə.
private final class VerifyRig {
    let store = VerifyStore()
    let queue = VerifyQueue()
    let transport = VerifyTransport()
    let env = VerifyEnv()
    let gate = ConsentGate()
    var options: SmartBeeOptions

    init(_ options: SmartBeeOptions = SmartBeeOptions(debug: true), fresh: Bool = false) {
        self.options = options
        if !fresh {
            store.map[Core.Keys.binding] = Core.binding(key: verifyKey, endpoint: options.endpoint)
            store.map[Core.Keys.config] = "{\"enabled\":true}"
        }
    }

    /// `mark`: əvvəlki prosesdən qalmış rədd nişanı.
    func core(mark: ConsentMark? = nil) -> Core {
        let core = Core(key: verifyKey, options: options, store: store, queue: queue, transport: transport, env: env, gate: gate, mark: mark)
        core.start()
        return core
    }

    /// Növbədəki bütün sətirlərin mətni (kontekst və yük).
    var stored: String {
        return queue.rows.map { $0.ctx + $0.payload }.joined()
    }
}

/// Xarici auditdən əvvəlki yoxlamanın tapıntılarının (B1, B2, B3, B5, B6, B8) sınaqları. Android-də eyni sınaqlar var
/// (VerificationFixesTest.kt).
final class VerificationFixesTests: XCTestCase {
    private let granted = SmartBeeOptions(consent: SmartBeeConsent(analytics: true, ads: true), debug: true)
    private let link = "https://shop.az/p/1?utm_source=fb&gclid=GVAL9&fbclid=FVAL9"

    private func dict(_ value: Any?) -> [String: Any] { return value as? [String: Any] ?? [:] }

    private func adsFlag(_ ctx: [String: Any]) -> Bool? {
        return dict(ctx["consent"])["ads"] as? Bool
    }

    private func tempDir(_ name: String) -> URL {
        return FileManager.default.temporaryDirectory.appendingPathComponent("sb-" + name + "-" + UUID().uuidString, isDirectory: true)
    }

    /// Reklama yararlı vəziyyət: razılıq var, izləmə icazəsi verilib.
    private func adsRig() -> VerifyRig {
        let rig = VerifyRig(granted)
        rig.env.attStatus = "authorized"
        rig.env.idfa = verifyIdfa
        return rig
    }

    private func assertNoAdData(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(text.contains(verifyIdfa), "idfa", file: file, line: line)
        XCTAssertFalse(text.contains(verifyIdfv), "idfv", file: file, line: line)
        XCTAssertFalse(text.contains("GVAL9"), "gclid", file: file, line: line)
        XCTAssertFalse(text.contains("FVAL9"), "fbclid", file: file, line: line)
    }

    // MARK: - B1. Reklam razılığı göndəriş ortasında geri alınır

    func testAdsWithdrawnMidFlushStripsTheRemainingBatches() {
        let rig = adsRig()
        let core = rig.core()
        core.track("A", props: nil, eventId: nil)
        // Kampaniya konteksti dəyişir: sonrakı eventlər ayrıca topluda gedir.
        core.onDeepLink(link)
        core.track("B", props: nil, eventId: nil)
        XCTAssertTrue(rig.stored.contains(verifyIdfa))
        XCTAssertTrue(rig.stored.contains("GVAL9"))

        // Birinci toplu göndərilən anda istifadəçi (başqa axında) reklam razılığını geri alır.
        rig.transport.onPost = { attempt in
            if attempt == 1 { rig.gate.hold(denyAnalytics: false, denyAds: true) }
        }
        core.flush(force: true)

        XCTAssertEqual(rig.transport.posts.count, 2)
        XCTAssertEqual(rig.queue.count, 0)
        guard rig.transport.posts.count == 2 else { return }
        XCTAssertEqual(adsFlag(dict(rig.transport.posts[0]["ctx"])), true)
        let later = dict(rig.transport.posts[1]["ctx"])
        XCTAssertEqual(adsFlag(later), false)
        XCTAssertNil(later["ids"])
        XCTAssertEqual(dict(later["campaign"])["utm_source"] as? String, "fb")
        assertNoAdData(rig.transport.raw[1])
    }

    func testAnalyticsWithdrawnMidFlushStopsBeforeTheNextRequest() {
        let rig = adsRig()
        let core = rig.core()
        core.track("A", props: nil, eventId: nil)
        core.onDeepLink(link)
        core.track("B", props: nil, eventId: nil)
        rig.transport.onPost = { attempt in
            if attempt == 1 { rig.gate.hold(denyAnalytics: true, denyAds: false) }
        }
        core.flush(force: true)
        XCTAssertEqual(rig.transport.attempts, 1, "razılıq geri alınandan sonra ikinci sorğu göndərilmir")
        XCTAssertTrue(rig.queue.count > 0)
    }

    // MARK: - B2. Rədd çağıran axında diskə yazılır və başlanğıcda icra olunur

    func testConsentMarkTextRoundTripsAndCorruptTextIsStrictest() {
        let marks = [
            ConsentMark(wipe: true, scrub: true, consent: "00"),
            ConsentMark(wipe: true, scrub: false, consent: "11"),
            ConsentMark(wipe: false, scrub: true, consent: "10"),
            ConsentMark(wipe: true, scrub: false, consent: nil),
        ]
        for mark in marks {
            XCTAssertEqual(ConsentMark.parse(mark.text), mark, mark.text)
        }
        XCTAssertEqual(ConsentMark.parse("10--\n"), ConsentMark(wipe: true, scrub: false, consent: nil))
        for text in ["", "1", "garbage", "2011", "1012", "10-1", "10111"] {
            XCTAssertEqual(ConsentMark.parse(text), ConsentMark.strictest, text)
        }
        // Rədd bayraqları yalnız artır, razılıq dəyəri ən son çağırışınkıdır.
        let denied = ConsentMark(wipe: false, scrub: false, consent: nil).adding(denyAnalytics: true, denyAds: true, consent: "00")
        XCTAssertEqual(denied, ConsentMark(wipe: true, scrub: true, consent: "00"))
        XCTAssertEqual(denied.adding(denyAnalytics: false, denyAds: false, consent: "11"), ConsentMark(wipe: true, scrub: true, consent: "11"))
        XCTAssertEqual(denied.adding(denyAnalytics: false, denyAds: false, consent: nil), denied)
    }

    func testTombstoneIsWrittenImmediatelyAndSurvivesTheProcess() {
        let dir = tempDir("tomb")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tomb = ConsentTombstone(directory: dir)
        XCTAssertNil(tomb.current().mark)
        // Heç nəyi rədd etməyən çağırış nişan yazmır.
        XCTAssertEqual(tomb.record(denyAnalytics: false, denyAds: false, consent: "11"), 0)
        XCTAssertNil(ConsentTombstone(directory: dir).current().mark)

        _ = tomb.record(denyAnalytics: true, denyAds: true, consent: "00")
        // Yeni proses: nüvə rəddi icra etməyib, amma nişan diskdədir.
        let reopened = ConsentTombstone(directory: dir)
        XCTAssertFalse(reopened.unreadable)
        XCTAssertEqual(reopened.current().mark, ConsentMark(wipe: true, scrub: true, consent: "00"))
    }

    func testTombstoneIsClearedOnlyByItsLatestGeneration() {
        let dir = tempDir("tomb-gen")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tomb = ConsentTombstone(directory: dir)
        let first = tomb.record(denyAnalytics: true, denyAds: false, consent: "01")
        // Rəddən sonra razılıq yenidən verilir: nişan qalır, amma razılıq dəyəri yenilənir.
        let second = tomb.record(denyAnalytics: false, denyAds: false, consent: "11")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(ConsentTombstone(directory: dir).current().mark, ConsentMark(wipe: true, scrub: false, consent: "11"))

        // Köhnə çağırış icra olundu, yenisi hələ gözləyir: nişan silinmir.
        tomb.settle(first)
        XCTAssertNotNil(ConsentTombstone(directory: dir).current().mark)
        tomb.settle(second)
        XCTAssertNil(tomb.current().mark)
        XCTAssertNil(ConsentTombstone(directory: dir).current().mark)
    }

    func testCorruptTombstoneFileIsTheStrictestMark() throws {
        let dir = tempDir("tomb-bad")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        try Data("not a mark".utf8).write(to: dir.appendingPathComponent("consent.mark"))
        XCTAssertEqual(ConsentTombstone(directory: dir).current().mark, ConsentMark.strictest)
    }

    func testAnalyticsTombstoneErasesQueueAndIdentifiersBeforeAnythingIsSent() {
        let rig = adsRig()
        rig.store.map[Core.Keys.consent] = "11"
        let first = rig.core()
        first.identify("user-1", traits: nil)
        first.track("Lead", props: nil, eventId: nil)
        XCTAssertTrue(rig.queue.count > 0)
        XCTAssertNotNil(rig.store.map[Core.Keys.anon])

        // Proses ölüb: `setConsent(false, false)` çağırılmışdı, amma nüvə onu icra etməyib. Diskdə köhnə razılıq qalıb.
        let calls = rig.transport.configCalls
        let second = rig.core(mark: ConsentMark(wipe: true, scrub: true, consent: "00"))
        XCTAssertEqual(rig.queue.count, 0)
        XCTAssertNil(second.anonymousId)
        XCTAssertEqual(rig.store.map[Core.Keys.consent], "00")
        for name in [Core.Keys.anon, Core.Keys.user, Core.Keys.session, Core.Keys.seq] {
            XCTAssertNil(rig.store.map[name], name)
        }
        second.onForeground()
        second.track("Later", props: nil, eventId: nil)
        second.flush(force: true)
        XCTAssertEqual(rig.transport.attempts, 0)
        XCTAssertEqual(rig.transport.configCalls, calls, "rədd ediləndən sonra şəbəkəyə çıxılmır")
        XCTAssertEqual(rig.queue.count, 0)
    }

    func testRegrantAfterDenialIsKeptButTheOldQueueIsStillErased() {
        let rig = adsRig()
        let first = rig.core()
        first.track("Old", props: nil, eventId: nil)
        let oldId = first.anonymousId
        XCTAssertNotNil(oldId)

        // Rədd, sonra yenidən razılıq (hər ikisi icra olunmadan proses ölüb): razılıq qüvvədədir, köhnə məlumat silinir.
        let second = rig.core(mark: ConsentMark(wipe: true, scrub: true, consent: "11"))
        XCTAssertEqual(rig.store.map[Core.Keys.consent], "11")
        XCTAssertNotNil(second.anonymousId)
        XCTAssertNotEqual(second.anonymousId, oldId)
        second.track("New", props: nil, eventId: nil)
        second.flush(force: true)
        let names = rig.transport.events.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("New"))
        XCTAssertFalse(names.contains("Old"))
        XCTAssertFalse(rig.transport.raw.joined().contains(oldId ?? "-"))
    }

    func testAdsTombstoneScrubsQueuedRowsAndForcesAdsOff() {
        let rig = adsRig()
        let first = rig.core()
        first.onDeepLink(link)
        first.track("Lead", props: nil, eventId: nil)
        let count = rig.queue.count
        XCTAssertTrue(rig.stored.contains(verifyIdfa))

        // `setConsent(true, false)` icra olunmadan proses ölüb.
        let second = rig.core(mark: ConsentMark(wipe: false, scrub: true, consent: "10"))
        XCTAssertEqual(rig.queue.count, count, "analitika razılığı qalır: növbə silinmir")
        assertNoAdData(rig.stored)
        assertNoAdData(rig.store.map[Core.Keys.campaign] ?? "")
        XCTAssertEqual(rig.store.map[Core.Keys.consent], "10")
        second.track("After", props: nil, eventId: nil)
        second.flush(force: true)
        XCTAssertFalse(rig.transport.posts.isEmpty)
        for post in rig.transport.posts {
            XCTAssertEqual(adsFlag(dict(post["ctx"])), false)
        }
        assertNoAdData(rig.transport.raw.joined())
    }

    // MARK: - B3. Reklam razılığı geri alınanda növbədəki sətirlər diskdə təmizlənir

    func testAdsWithdrawalRewritesQueuedRowsAtRest() {
        let rig = adsRig()
        let core = rig.core()
        core.onDeepLink(link)
        core.track("Lead", props: ["url": link], eventId: nil)
        let count = rig.queue.count
        XCTAssertTrue(rig.stored.contains(verifyIdfa))
        XCTAssertTrue(rig.stored.contains(verifyIdfv))

        core.setConsent(analytics: true, ads: false)
        // Göndəriş gözlənilmir: sətirlər artıq növbədə təmizdir.
        XCTAssertEqual(rig.queue.count, count)
        XCTAssertEqual(rig.transport.attempts, 0)
        for row in rig.queue.rows {
            let ctx = Util.parseObject(row.ctx) ?? [:]
            XCTAssertNil(ctx["ids"])
            XCTAssertEqual(adsFlag(ctx), false)
            XCTAssertEqual(dict(ctx["consent"])["analytics"] as? Bool, true)
            for id in Util.clickIds { XCTAssertNil(dict(ctx["campaign"])[id], id) }
            let event = Util.parseObject(row.payload) ?? [:]
            let url = dict(event["props"])["url"] as? String
            if (event["name"] as? String) == "DeepLinkOpen" {
                // Ünvandan klik ID-ləri silinir, UTM qalır.
                XCTAssertEqual(url, "https://shop.az/p/1?utm_source=fb")
            } else if (event["name"] as? String) == "Lead" {
                // Tətbiqin öz eventinin ünvan dəyərindən də klik ID-ləri silinir.
                XCTAssertEqual(url, "https://shop.az/p/1?utm_source=fb")
            }
        }
        XCTAssertFalse(rig.queue.rows.map { $0.ctx }.joined().contains("GVAL9"))

        // Razılıq göndərişdən əvvəl yenidən verilir: köhnə sətirlər reklama yararlı olmur.
        core.setConsent(analytics: true, ads: true)
        core.track("AfterRegrant", props: nil, eventId: nil)
        core.flush(force: true)
        XCTAssertEqual(rig.queue.count, 0)
        for post in rig.transport.posts {
            let names = (post["events"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            let ctx = dict(post["ctx"])
            if names.contains("AfterRegrant") {
                XCTAssertEqual(names, ["AfterRegrant"])
                XCTAssertEqual(adsFlag(ctx), true)
            } else {
                XCTAssertEqual(adsFlag(ctx), false, "\(names)")
                XCTAssertNil(ctx["ids"], "\(names)")
            }
        }
    }

    func testRepeatedInitializeWithoutAdsAlsoRewritesQueuedRows() {
        let rig = adsRig()
        let core = rig.core()
        core.onDeepLink(link)
        core.track("Lead", props: nil, eventId: nil)
        XCTAssertTrue(rig.stored.contains(verifyIdfa))
        core.restrict(consent: SmartBeeConsent(analytics: true, ads: false), collectAdvertisingId: true)
        assertNoAdData(rig.stored)
    }

    func testFileQueueRewritesRowsInPlaceAndPersistsThem() {
        let dir = tempDir("rewrite")
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = FileQueue(directory: dir)
        queue.add(ctx: "{\"a\":1}", payload: "{\"n\":1}")
        queue.add(ctx: "{\"a\":2}", payload: "{\"n\":2}")
        queue.add(ctx: "{\"a\":3}", payload: "{\"n\":3}")
        XCTAssertTrue(queue.persist())
        let ids = queue.peek(10).map { $0.id }

        var seen = 0
        queue.update { row in
            seen += 1
            if row.payload == "{\"n\":2}" { return (ctx: "{}", payload: "{\"n\":20}") }
            return nil
        }
        XCTAssertEqual(seen, 3)
        XCTAssertEqual(queue.peek(10).map { $0.id }, ids, "sıra və ID-lər qalır")
        XCTAssertEqual(queue.peek(10).map { $0.payload }, ["{\"n\":1}", "{\"n\":20}", "{\"n\":3}"])
        XCTAssertEqual(queue.peek(10).map { $0.ctx }, ["{\"a\":1}", "{}", "{\"a\":3}"])
        XCTAssertTrue(queue.persist())
        let reopened = FileQueue(directory: dir)
        XCTAssertEqual(reopened.peek(10).map { $0.payload }, ["{\"n\":1}", "{\"n\":20}", "{\"n\":3}"])
        XCTAssertEqual(reopened.peek(10).map { $0.ctx }, ["{\"a\":1}", "{}", "{\"a\":3}"])
    }

    func testClickIdsOfALinkReceivedBeforeConsentIsKnownNeverReachDiskWithoutAdsConsent() {
        // İlk işə düşmə: razılıq hələ məlum deyil, keçid yalnız yaddaşdadır.
        let rig = VerifyRig(fresh: true)
        rig.transport.configStatus = -1
        let core = rig.core()
        core.onDeepLink(link)
        XCTAssertTrue(rig.store.map.isEmpty, "\(rig.store.map)")
        XCTAssertEqual(rig.queue.count, 0)

        // Konfiq reklam razılığını rədd edir: klik ID-ləri diskə yazılmazdan əvvəl silinir.
        rig.transport.configStatus = 200
        rig.transport.configBody = "{\"enabled\":true,\"consent_default\":{\"analytics\":true,\"ads\":false}}"
        rig.env.time += Core.backoffMaxMs
        core.refreshConfig(force: true)
        XCTAssertTrue(rig.queue.count > 0)
        assertNoAdData(rig.stored)
        assertNoAdData(rig.store.map[Core.Keys.campaign] ?? "")
        XCTAssertTrue((rig.store.map[Core.Keys.campaign] ?? "").contains("utm_source"))
        core.flush(force: true)
        XCTAssertFalse(rig.transport.raw.isEmpty)
        assertNoAdData(rig.transport.raw.joined())
    }

    // MARK: - B5. Rədd cavabları PROTOCOL.md 5.6 cədvəli ilə dəqiq uyğundur

    func testVerdictMatchesTheProtocolTableExactly() {
        func verdict(_ status: Int, _ error: String? = nil, events: Int = 3) -> Verdict {
            var body: String?
            if let error = error { body = "{\"ok\":false,\"error\":\"" + error + "\"}" }
            return HttpResult(status: status, body: body).verdict(events: events)
        }
        for status in [200, 201, 202, 204, 299] { XCTAssertEqual(verdict(status), .accepted, "\(status)") }

        // 413: birdən çox event varsa toplu bölünür (gövdədən asılı olmayaraq).
        XCTAssertEqual(verdict(413, nil, events: 2), .split)
        XCTAssertEqual(verdict(413, "blocked", events: 2), .split)
        XCTAssertEqual(HttpResult(status: 413, body: "<html>too large</html>").verdict(events: 50), .split)
        // Tək event yalnız serverin öz kodu ilə silinir.
        for code in ["body_too_large", "context_too_large", "too_many_events"] {
            XCTAssertEqual(verdict(413, code, events: 1), .drop, code)
        }
        XCTAssertEqual(verdict(413, nil, events: 1), .retry)
        XCTAssertEqual(verdict(413, "blocked", events: 1), .retry)
        XCTAssertEqual(verdict(413, "bad_batch", events: 1), .retry)

        // 400: yalnız zərfin kodları qətidir.
        for code in ["empty_body", "bad_gzip", "bad_json", "bad_batch", "bad_chars"] {
            XCTAssertEqual(verdict(400, code), .drop, code)
        }
        for code in ["blocked", "unknown_key", "app_not_allowed", "body_too_large", "rate_limited"] {
            XCTAssertEqual(verdict(400, code), .retry, code)
        }
        XCTAssertEqual(verdict(400), .retry)

        // 403.
        XCTAssertEqual(verdict(403, "unknown_key"), .keyOff)
        for code in ["origin_not_allowed", "app_not_allowed", "platform_not_enabled", "unknown_platform", "browser_not_allowed"] {
            XCTAssertEqual(verdict(403, code), .drop, code)
        }
        for code in ["blocked", "forbidden", "bad_batch", "not_found"] {
            XCTAssertEqual(verdict(403, code), .retry, code)
        }
        XCTAssertEqual(verdict(403), .retry)

        // 404: yalnız `unknown_key` açarı söndürür.
        XCTAssertEqual(verdict(404, "unknown_key"), .keyOff)
        for code in ["not_found", "app_not_allowed", "bad_batch"] {
            XCTAssertEqual(verdict(404, code), .retry, code)
        }
        XCTAssertEqual(verdict(404), .retry)

        // 422 və qalan hər status müvəqqətidir, gövdədə tanınan kod olsa belə.
        for status in [-1, 0, 301, 302, 304, 401, 402, 405, 408, 409, 410, 418, 422, 429, 451, 500, 502, 503, 504] {
            XCTAssertEqual(verdict(status), .retry, "\(status)")
            for code in ["bad_batch", "unknown_key", "app_not_allowed", "body_too_large"] {
                XCTAssertEqual(verdict(status, code), .retry, "\(status) \(code)")
                XCTAssertEqual(verdict(status, code, events: 1), .retry, "\(status) \(code)")
            }
        }
    }

    func testOnlyRecognisedServerRejectionsDropTheBatch() {
        // Aradakı qatın (WAF, proksi) cavabları: toplu saxlanır.
        let transient: [(Int, String?)] = [
            (400, "{\"error\":\"blocked\"}"),
            (400, nil),
            (422, "{\"ok\":false,\"error\":\"bad_batch\"}"),
            (413, "<html>Request Entity Too Large</html>"),
            (403, "{\"error\":\"forbidden\"}"),
            (404, "{\"ok\":false,\"error\":\"not_found\"}"),
        ]
        for item in transient {
            let rig = VerifyRig(granted)
            let core = rig.core()
            core.track("Lead", props: nil, eventId: nil)
            let before = rig.queue.count
            rig.transport.status = item.0
            rig.transport.postError = item.1
            core.flush(force: true)
            XCTAssertEqual(rig.queue.count, before, "\(item.0) \(item.1 ?? "-")")
            XCTAssertFalse(core.paused, "\(item.0)")
            // Fasilədən sonra yenidən cəhd olunur və eventlər çatır.
            rig.transport.status = 200
            rig.env.time += 2 * Core.backoffMaxMs
            core.flush(force: true)
            XCTAssertEqual(rig.queue.count, 0, "\(item.0)")
            XCTAssertTrue(rig.transport.events.contains(where: { ($0["name"] as? String) == "Lead" }), "\(item.0)")
        }

        // Serverin öz qəti cavabları: toplu silinir.
        let terminal: [(Int, String)] = [
            (400, "{\"ok\":false,\"error\":\"bad_batch\"}"),
            (403, "{\"ok\":false,\"error\":\"app_not_allowed\"}"),
        ]
        for item in terminal {
            let rig = VerifyRig(granted)
            let core = rig.core()
            core.track("Lead", props: nil, eventId: nil)
            rig.transport.status = item.0
            rig.transport.postError = item.1
            core.flush(force: true)
            XCTAssertEqual(rig.queue.count, 0, "\(item.0) \(item.1)")
            XCTAssertFalse(core.paused)
        }

        // `unknown_key`: 403 və 404 açarı söndürür.
        for status in [403, 404] {
            let rig = VerifyRig(granted)
            let core = rig.core()
            core.track("Lead", props: nil, eventId: nil)
            rig.transport.status = status
            rig.transport.postError = "{\"ok\":false,\"error\":\"unknown_key\"}"
            core.flush(force: true)
            XCTAssertTrue(core.paused, "\(status)")
        }
    }

    // MARK: - B6. Cavabın ölçüsü, gözləmə siyahısı, platforma adları

    func testResponseBodyIsReadInChunksAndCapped() {
        XCTAssertEqual(ResponseJob.limit(status: 200), URLSessionTransport.maxConfigBytes)
        XCTAssertEqual(ResponseJob.limit(status: 403), URLSessionTransport.maxErrorBytes)
        XCTAssertEqual(ResponseJob.limit(status: 500), URLSessionTransport.maxErrorBytes)
        XCTAssertEqual(ResponseJob.limit(status: 204), 0)
        XCTAssertEqual(ResponseJob.limit(status: 304), 0)
        XCTAssertEqual(URLSessionTransport.maxErrorBytes, HttpResult.maxErrorChars)

        // Konfiq: həddə qədər saxlanır, həddi keçəndə gövdə atılır və oxu dayandırılır.
        let config = ResponseJob()
        XCTAssertTrue(config.begin(nil, status: 200, expected: -1))
        XCTAssertTrue(config.accept(Data(count: 1000)))
        XCTAssertEqual(config.body?.count, 1000)
        XCTAssertTrue(config.accept(Data(count: URLSessionTransport.maxConfigBytes - 1000)))
        XCTAssertEqual(config.body?.count, URLSessionTransport.maxConfigBytes)
        XCTAssertFalse(config.accept(Data(count: 1)))
        XCTAssertNil(config.body)
        XCTAssertTrue(config.stopped)
        XCTAssertEqual(config.data.count, 0, "atılmış gövdə yaddaşda saxlanmır")

        // Rədd cavabı: yalnız kiçik gövdə saxlanır; böyüyü atılır, amma oxu ümumi həddə qədər davam edir.
        let rejected = ResponseJob()
        XCTAssertTrue(rejected.begin(nil, status: 403, expected: 100))
        XCTAssertTrue(rejected.accept(Data(count: URLSessionTransport.maxErrorBytes)))
        XCTAssertEqual(rejected.body?.count, URLSessionTransport.maxErrorBytes)
        XCTAssertTrue(rejected.accept(Data(count: 1)))
        XCTAssertNil(rejected.body)
        XCTAssertFalse(rejected.stopped)
        XCTAssertTrue(rejected.accept(Data(count: 10)))
        XCTAssertNil(rejected.body, "həddi aşmış gövdə sonrakı hissə ilə geri qayıtmır")

        // Elan olunmuş ölçü həddən böyükdür: gövdə heç oxunmur.
        let huge = ResponseJob()
        XCTAssertFalse(huge.begin(nil, status: 200, expected: Int64(URLSessionTransport.maxConfigBytes) + 1))
        XCTAssertNil(huge.body)
        XCTAssertTrue(huge.stopped)

        // Gövdəsi lazım olmayan cavab: heç nə saxlanmır.
        let empty = ResponseJob()
        XCTAssertTrue(empty.begin(nil, status: 204, expected: -1))
        XCTAssertEqual(empty.body?.count, 0)
        XCTAssertTrue(empty.accept(Data(count: 10)))
        XCTAssertNil(empty.body)
        XCTAssertEqual(empty.data.count, 0)
    }

    func testConsecutivePendingRestrictsMergeIntoOneBoundedEntry() {
        var released = 0
        func limits(analytics: Bool, ads: Bool, noAdId: Bool, token: Int?) -> RestrictLimits {
            let slot = RestrictLimits.slot(denyAnalytics: analytics, denyAds: ads)
            return RestrictLimits(analytics: analytics, ads: ads, noAdId: noAdId, token: token, releases: [slot: { released += 1 }])
        }
        var merged = limits(analytics: false, ads: true, noAdId: false, token: 1)
        var redundant = 0
        // Yüz təkrar `initialize`: yazı böyümür, artıq qadağalar dərhal götürülür.
        for index in 0..<100 {
            let next = limits(analytics: index % 2 == 0, ads: index % 3 == 0, noAdId: index == 50, token: index + 2)
            let result = merged.merging(next)
            merged = result.limits
            redundant += result.redundant.count
            for release in result.redundant { release() }
        }
        XCTAssertTrue(merged.analytics)
        XCTAssertTrue(merged.ads)
        XCTAssertTrue(merged.noAdId)
        XCTAssertEqual(merged.token, 101)
        XCTAssertTrue(merged.releases.count <= 4, "\(merged.releases.count)")
        XCTAssertEqual(redundant + merged.releases.count, 101)
        XCTAssertEqual(released, redundant)
        for release in merged.releases.values { release() }
        XCTAssertEqual(released, 101, "hər çağırışın qadağası bir dəfə götürülür")

        // Nişansız çağırış nəsil nömrəsini dəyişmir.
        let plain = limits(analytics: false, ads: false, noAdId: true, token: nil)
        XCTAssertEqual(merged.merging(plain).limits.token, 101)
        XCTAssertEqual(plain.merging(merged).limits.token, 101)
    }

    func testPlatformIsNotMisreported() {
        let base = AppleEnv.captureBase()
        XCTAssertEqual(dict(base["os"])["name"] as? String, AppleEnv.osName)
        XCTAssertEqual(dict(base["device"])["type"] as? String, AppleEnv.deviceType)
        XCTAssertTrue(["iOS", "tvOS", "watchOS", "macOS", "visionOS"].contains(AppleEnv.osName), AppleEnv.osName)
        XCTAssertTrue(["phone", "tv", "desktop", "watch", "headset"].contains(AppleEnv.deviceType), AppleEnv.deviceType)
        // Sxem: `os.name` ən çox 32, `device.type` ən çox 16 simvol.
        XCTAssertTrue(AppleEnv.osName.count <= 32)
        XCTAssertTrue(AppleEnv.deviceType.count <= 16)
        #if os(macOS)
        // Testlər macOS-da işləyir: nə `iOS`, nə `phone`.
        XCTAssertEqual(AppleEnv.osName, "macOS")
        XCTAssertEqual(AppleEnv.deviceType, "desktop")
        #endif
        #if os(tvOS)
        XCTAssertEqual(AppleEnv.deviceType, "tv")
        #endif
    }

    // MARK: - B8. Pozulmuş yaddaş saxlanmış rəddi unutdurmur

    func testCorruptStoreFileIsReportedAndMissingFileIsNot() throws {
        let dir = tempDir("corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(FileStore(directory: dir).corrupt, "fayl yoxdur: ilk işə salınma")
        let valid = FileStore(directory: dir)
        valid.put("consent", "00")
        XCTAssertFalse(FileStore(directory: dir).corrupt)

        try Data("{\"consent\":".utf8).write(to: dir.appendingPathComponent("store.json"))
        let broken = FileStore(directory: dir)
        XCTAssertTrue(broken.corrupt)
        XCTAssertFalse(broken.unreadable)
        XCTAssertNil(broken.get("consent"))
        // Dəyərləri sətir olmayan fayl da pozulmuş sayılır.
        try Data("{\"consent\":1}".utf8).write(to: dir.appendingPathComponent("store.json"))
        XCTAssertTrue(FileStore(directory: dir).corrupt)
    }

    func testCorruptStoreMeansDeniedUntilConsentIsStatedAgain() {
        // Yaddaş pozulub: saxlanmış rədd itmiş ola bilər. Konfiq razılıq versə belə heç nə yığılmır və göndərilmir.
        let rig = VerifyRig(fresh: true)
        rig.store.broken = true
        rig.transport.configBody = "{\"enabled\":true,\"consent_default\":{\"analytics\":true,\"ads\":true}}"
        let core = rig.core()
        core.onForeground()
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        XCTAssertNil(core.anonymousId)
        XCTAssertEqual(rig.queue.count, 0)
        XCTAssertEqual(rig.transport.attempts, 0)
        XCTAssertEqual(rig.transport.configCalls, 0, "rədd edilmiş sayılır: şəbəkəyə çıxılmır")
        // Yalnız «oxunmur» qeydi saxlanır ki, növbəti açılışda da rədd sayılsın.
        XCTAssertEqual(rig.store.map, [Core.Keys.consent: Core.consentUnreadable])

        // `setConsent` razılığı yenidən bildirir.
        core.setConsent(analytics: true, ads: true)
        XCTAssertNotNil(core.anonymousId)
        core.track("Lead", props: nil, eventId: nil)
        core.flush(force: true)
        XCTAssertTrue(rig.transport.events.contains(where: { ($0["name"] as? String) == "Lead" }))
        XCTAssertEqual(adsFlag(dict(rig.transport.posts.last?["ctx"])), true)

        // `initialize`-in `consent` seçimi itmiş rəddi yumşalda bilmir: yalnız `setConsent` (Android ilə eyni qayda).
        let stated = VerifyRig(granted, fresh: true)
        stated.store.broken = true
        let statedCore = stated.core()
        XCTAssertNil(statedCore.anonymousId)
        statedCore.track("Lead", props: nil, eventId: nil)
        XCTAssertEqual(stated.queue.count, 0)
        XCTAssertEqual(stated.transport.configCalls, 0)
        statedCore.setConsent(analytics: true, ads: true)
        XCTAssertNotNil(statedCore.anonymousId)
    }

    func testCorruptStoreOnDiskStaysDeniedAcrossLaunches() throws {
        let dir = tempDir("corrupt-core")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("store.json"))
        for _ in 0..<2 {
            let transport = VerifyTransport()
            transport.configBody = "{\"enabled\":true}"
            let queue = FileQueue(directory: dir)
            let core = Core(key: verifyKey, options: SmartBeeOptions(debug: true), store: FileStore(directory: dir), queue: queue, transport: transport, env: VerifyEnv())
            core.start()
            core.onForeground()
            core.track("Lead", props: nil, eventId: nil)
            core.flush(force: true)
            XCTAssertNil(core.anonymousId)
            XCTAssertEqual(queue.count, 0)
            XCTAssertEqual(transport.attempts, 0)
            XCTAssertEqual(transport.configCalls, 0)
        }
    }

    func testMalformedStoredConsentIsDeniedNotUnstated() {
        for value in ["", "1", "yes", "12", "111", "true"] {
            let rig = VerifyRig()
            rig.store.map[Core.Keys.consent] = value
            let core = rig.core()
            core.track("Lead", props: nil, eventId: nil)
            XCTAssertNil(core.anonymousId, value)
            XCTAssertEqual(rig.queue.count, 0, value)
            // Yararsız dəyər diskdə qalır: növbəti açılışda da rədd sayılır.
            XCTAssertEqual(rig.store.map[Core.Keys.consent], value)
            let again = rig.core()
            XCTAssertNil(again.anonymousId, value)
            again.setConsent(analytics: true, ads: false)
            XCTAssertNotNil(again.anonymousId, value)
            XCTAssertEqual(rig.store.map[Core.Keys.consent], "10")
        }
        // Yararlı dəyərlər əvvəlki kimi oxunur.
        let valid = VerifyRig()
        valid.store.map[Core.Keys.consent] = "10"
        XCTAssertNotNil(valid.core().anonymousId)
    }

    func testConsentDefaultMembersAreTrueOnlyWhenJsonTrue() {
        func parse(_ consent: String?) -> RemoteConfig? {
            var json = "{\"enabled\":true"
            if let consent = consent { json += ",\"consent_default\":" + consent }
            return RemoteConfig.parse(json + "}")
        }
        func check(_ consent: String?, _ analytics: Bool, _ ads: Bool, line: UInt = #line) {
            let config = parse(consent)
            XCTAssertNotNil(config, line: line)
            XCTAssertEqual(config?.consentAnalytics, analytics, consent ?? "absent", line: line)
            XCTAssertEqual(config?.consentAds, ads, consent ?? "absent", line: line)
        }
        // Yoxdursa susmaya görə dəyərlər qalır.
        check(nil, true, true)
        // Var, amma obyekt deyil: hər iki məqsəd false.
        check("\"yes\"", false, false)
        check("true", false, false)
        check("null", false, false)
        check("[true,true]", false, false)
        check("1", false, false)
        // Çatışmayan və ya boolean olmayan üzv false-dur.
        check("{}", false, false)
        check("{\"analytics\":true}", true, false)
        check("{\"ads\":true}", false, true)
        check("{\"analytics\":1,\"ads\":\"true\"}", false, false)
        check("{\"analytics\":null,\"ads\":true}", false, true)
        check("{\"analytics\":true,\"ads\":true}", true, true)
        check("{\"analytics\":false,\"ads\":false}", false, false)
    }
}
