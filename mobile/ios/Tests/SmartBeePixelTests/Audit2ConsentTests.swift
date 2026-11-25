import Foundation
import XCTest
@testable import SmartBeePixel

private let auditKey = "demo0ios01"

private final class AuditStore: Store {
    var map: [String: String] = [:]
    /// Yaddaş faylı pozulmuş kimi davranır.
    var broken = false
    func get(_ key: String) -> String? { return map[key] }
    func put(_ key: String, _ value: String) { map[key] = value }
    func remove(_ key: String) { map[key] = nil }
    var corrupt: Bool { return broken }
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
    /// Yalnız qəbul olunmuş toplular.
    var raw: [String] = []
    var attempts = 0
    var status = 200
    var postError: String?
    var configStatus = 200
    var configBody: String?
    var configCalls = 0
    /// Verilibsə cavab statusunu toplunun özünə görə təyin edir.
    var respond: (([String: Any]) -> Int)?

    func post(url: String, json: String) -> HttpResult {
        attempts += 1
        var code = status
        if let respond = respond { code = respond(Util.parseObject(json) ?? [:]) }
        let accepted = code >= 200 && code <= 299
        if accepted { raw.append(json) }
        return HttpResult(status: code, body: accepted ? nil : postError)
    }

    func get(url: String, etag: String?) -> HttpResult {
        configCalls += 1
        return HttpResult(status: configStatus, body: configStatus == 200 ? configBody : nil, etag: "W/\"1\"")
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
    var attNeeded = false

    func advertising(includeId: Bool) -> AdvertisingInfo {
        return AdvertisingInfo(status: attStatus, idfa: nil)
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

    /// `mark`: əvvəlki prosesdən qalmış rədd nişanı.
    func core(mark: ConsentMark? = nil) -> Core {
        let core = Core(key: auditKey, options: options, store: store, queue: queue, transport: transport, env: env, gate: gate, mark: mark)
        core.start()
        return core
    }

    /// Növbədəki bütün sətirlərin mətni (kontekst və yük).
    var stored: String {
        return queue.rows.map { $0.ctx + $0.payload }.joined(separator: "\n")
    }

    /// Göndərilmiş eventlərdən adı (və ya tipi) verilən birincisi.
    func event(_ name: String) -> [String: Any] {
        for event in transport.events {
            if (event["name"] as? String) == name || (event["type"] as? String) == name { return event }
        }
        return [:]
    }
}

/// İkinci müstəqil auditin razılıq / çatdırılma tapıntıları (C1–C4, C6–C8). Android-də eyni ssenarilər
/// `Audit2ConsentTest.kt` və `Audit2ConsentAndroidTest.kt`-dədir.
final class Audit2ConsentTests: XCTestCase {
    private let granted = SmartBeeOptions(consent: SmartBeeConsent(analytics: true, ads: true), debug: true)

    private func dict(_ value: Any?) -> [String: Any] { return value as? [String: Any] ?? [:] }

    private func adsFlag(_ post: [String: Any]) -> Bool? {
        return dict(dict(post["ctx"])["consent"])["ads"] as? Bool
    }

    // MARK: - C1. props / traits içindəki klik ID-ləri reklam razılığı geri alınanda silinir

    func testC1ClickIdsInQueuedPropsAndTraitsAreRemovedWhenAdsConsentIsWithdrawn() {
        let rig = AuditRig(granted)
        rig.transport.status = 500
        let core = rig.core()
        core.track("ViewItem", props: ["link": "https://shop.az/p?gclid=G1SECRET&utm_source=fb&x=1", "value": 250, "name": "Çay dəsti"], eventId: nil)
        core.identify("u1", traits: ["landing": "https://shop.az/?fbclid=FB1SECRET&utm_medium=cpc", "plan": "pro", "email": "a@b.az"])
        core.flush(force: true)
        XCTAssertTrue(rig.stored.contains("G1SECRET"))
        XCTAssertTrue(rig.stored.contains("FB1SECRET"))

        core.setConsent(analytics: true, ads: false)
        // Diskdəki sətirlər dərhal təmizlənir.
        XCTAssertFalse(rig.stored.contains("G1SECRET"))
        XCTAssertFalse(rig.stored.contains("FB1SECRET"))

        rig.transport.status = 200
        rig.env.time += 2 * Core.backoffMaxMs
        core.flush(force: true)
        let sent = rig.transport.raw.joined(separator: "\n")
        XCTAssertFalse(sent.contains("G1SECRET"))
        XCTAssertFalse(sent.contains("FB1SECRET"))
        XCTAssertFalse(rig.transport.posts.isEmpty)
        for post in rig.transport.posts { XCTAssertEqual(adsFlag(post), false) }
        // Adi analitika zədələnmir: UTM, qalan parametrlər və hash-lər yerindədir.
        let props = dict(rig.event("ViewItem")["props"])
        XCTAssertEqual(props["link"] as? String, "https://shop.az/p?utm_source=fb&x=1")
        XCTAssertEqual(props["value"] as? Int, 250)
        XCTAssertEqual(props["name"] as? String, "Çay dəsti")
        let traits = dict(rig.event("identify")["traits"])
        XCTAssertEqual(traits["landing"] as? String, "https://shop.az/?utm_medium=cpc")
        XCTAssertEqual(traits["plan"] as? String, "pro")
        XCTAssertEqual(traits["email_sha256"] as? String, Util.sha256("a@b.az"))
        XCTAssertNil(traits["email"])
    }

    func testC1ReCleaningDoesNotTouchRowsWithoutClickIds() {
        let rig = AuditRig(granted)
        rig.transport.status = 500
        let core = rig.core()
        core.track("Purchase", props: ["value": 12.5, "currency": "AZN", "items": [["id": "p1", "qty": 2]], "page": "https://shop.az/cart?step=2"], eventId: nil)
        core.identify("u1", traits: ["email": "a@b.az", "phone": "+994501234567", "plan": "pro"])
        core.flush(force: true)
        let before = rig.queue.rows.map { $0.payload }
        core.setConsent(analytics: true, ads: false)
        XCTAssertEqual(rig.queue.rows.map { $0.payload }, before)
    }

    func testC1UndecidedEventsAreCleanedBeforeTheyReachTheDiskWhenConfigDeniesAds() {
        let rig = AuditRig(SmartBeeOptions(debug: true), fresh: true)
        rig.transport.configStatus = 500
        let core = rig.core()
        core.track("ViewItem", props: ["link": "https://shop.az/p?gclid=G1SECRET&x=1"], eventId: nil)
        core.identify("u1", traits: ["landing": "https://shop.az/?fbclid=FB1SECRET"])
        XCTAssertEqual(rig.queue.count, 0)

        rig.transport.configStatus = 200
        rig.transport.configBody = "{\"enabled\":true,\"consent_default\":{\"analytics\":true,\"ads\":false}}"
        rig.env.time += 2 * Core.backoffMaxMs
        core.refreshConfig(force: true)
        XCTAssertTrue(rig.queue.count > 0)
        XCTAssertFalse(rig.stored.contains("G1SECRET"))
        XCTAssertFalse(rig.stored.contains("FB1SECRET"))
        core.flush(force: true)
        let sent = rig.transport.raw.joined(separator: "\n")
        XCTAssertFalse(sent.contains("G1SECRET"))
        XCTAssertFalse(sent.contains("FB1SECRET"))
        XCTAssertEqual(dict(rig.event("ViewItem")["props"])["link"] as? String, "https://shop.az/p?x=1")
    }

    // MARK: - C2. track / identify klik ID-lərini reklama yararlılığa görə təmizləyir (razılığa görə yox)

    func testC2TrackAndIdentifyDropClickIdsWhenTrackingIsNotAuthorized() {
        for status in ["denied", "restricted", "not_determined"] {
            let rig = AuditRig(granted)
            rig.env.attNeeded = true
            rig.env.attStatus = status
            let core = rig.core()
            core.track("ViewItem", props: ["link": "https://shop.az/p?gclid=G1SECRET&utm_source=fb"], eventId: nil)
            core.identify("u1", traits: ["landing": "https://shop.az/?fbclid=FB1SECRET&utm_medium=cpc"])
            // Klik ID-ləri növbəyə (diskə) də düşmür.
            XCTAssertFalse(rig.stored.contains("G1SECRET"), status)
            XCTAssertFalse(rig.stored.contains("FB1SECRET"), status)
            core.flush(force: true)
            XCTAssertEqual(dict(rig.event("ViewItem")["props"])["link"] as? String, "https://shop.az/p?utm_source=fb", status)
            XCTAssertEqual(dict(rig.event("identify")["traits"])["landing"] as? String, "https://shop.az/?utm_medium=cpc", status)
            for post in rig.transport.posts { XCTAssertEqual(adsFlag(post), false, status) }
        }
        // İcazə verilibsə klik ID-ləri qalır.
        let rig = AuditRig(granted)
        rig.env.attNeeded = true
        rig.env.attStatus = "authorized"
        let core = rig.core()
        core.track("ViewItem", props: ["link": "https://shop.az/p?gclid=G1SECRET&utm_source=fb"], eventId: nil)
        core.identify("u1", traits: ["landing": "https://shop.az/?fbclid=FB1SECRET"])
        core.flush(force: true)
        XCTAssertEqual(dict(rig.event("ViewItem")["props"])["link"] as? String, "https://shop.az/p?gclid=G1SECRET&utm_source=fb")
        XCTAssertEqual(dict(rig.event("identify")["traits"])["landing"] as? String, "https://shop.az/?fbclid=FB1SECRET")
    }

    // MARK: - C3. Yarımçıq nişan və pozulmuş razılıq

    func testC3UnparsableMarkIsAUserRefusalThatInitConsentCannotLoosen() {
        for text in ["", " ", "1 1", "garbage"] {
            XCTAssertEqual(ConsentMark.parse(text), ConsentMark.strictest, text)
            let rig = AuditRig(granted)
            rig.store.map[Core.Keys.consent] = "00"
            let core = rig.core(mark: ConsentMark.parse(text))
            core.track("AfterTorn", props: nil, eventId: nil)
            core.flush(force: true)
            XCTAssertEqual(rig.store.map[Core.Keys.consent], "00", text)
            XCTAssertNil(core.anonymousId, text)
            XCTAssertEqual(rig.transport.attempts, 0, text)
            XCTAssertEqual(rig.transport.configCalls, 0, text)

            // Növbəti açılışda da (nişan artıq silinib) `initialize`-in razılığı rəddi yumşaltmır.
            let next = AuditRig(granted)
            next.store.map[Core.Keys.consent] = rig.store.map[Core.Keys.consent]
            XCTAssertNil(next.core().anonymousId, text)
        }
    }

    func testC3CorruptStoredConsentWithInitConsentStaysDeniedUntilSetConsent() {
        for stored in ["??", "", "1", "yes"] {
            let rig = AuditRig(granted)
            rig.store.map[Core.Keys.consent] = stored
            let core = rig.core()
            core.onForeground()
            core.track("X", props: nil, eventId: nil)
            core.flush(force: true)
            XCTAssertNil(core.anonymousId, stored)
            XCTAssertEqual(rig.transport.attempts, 0, stored)
            XCTAssertEqual(rig.transport.configCalls, 0, stored)
            XCTAssertEqual(rig.queue.count, 0, stored)

            core.setConsent(analytics: true, ads: true)
            core.track("AfterSetConsent", props: nil, eventId: nil)
            core.flush(force: true)
            XCTAssertTrue(rig.transport.names.contains("AfterSetConsent"), stored)
            XCTAssertEqual(rig.store.map[Core.Keys.consent], "11", stored)
        }
    }

    func testC3CorruptStoreFileWithInitConsentStaysDeniedAcrossLaunches() {
        let rig = AuditRig(granted)
        rig.store.broken = true
        let core = rig.core()
        core.track("X", props: nil, eventId: nil)
        core.flush(force: true)
        XCTAssertNil(core.anonymousId)
        XCTAssertEqual(rig.transport.attempts, 0)
        XCTAssertEqual(rig.queue.count, 0)
        // «Oxunmur» qeydi saxlanır: növbəti açılışda (fayl artıq oxunur) razılıq yenə rədd sayılır.
        XCTAssertEqual(rig.store.map[Core.Keys.consent], Core.consentUnreadable)
        rig.store.broken = false
        let again = rig.core()
        XCTAssertNil(again.anonymousId)
        again.setConsent(analytics: true, ads: false)
        XCTAssertNotNil(again.anonymousId)
        XCTAssertEqual(rig.store.map[Core.Keys.consent], "10")
    }

    // MARK: - C4. Kodsuz 4xx alan toplu növbəni əbədi bağlamır

    private func poisonRig() -> AuditRig {
        let rig = AuditRig(granted)
        rig.transport.respond = { batch in
            let text = Util.jsonString(batch) ?? ""
            return text.contains("POISON") ? 403 : 200
        }
        rig.transport.postError = "<html>blocked by WAF</html>"
        return rig
    }

    func testC4BatchRejectedWithUncoded4xxIsIsolatedAndOnlyThePoisonRowIsDropped() {
        let rig = poisonRig()
        let core = rig.core()
        core.track("Before", props: nil, eventId: nil)
        core.track("Search", props: ["q": "POISON"], eventId: nil)
        core.track("After", props: nil, eventId: nil)

        // İlk iki rədd: toplu olduğu kimi qalır.
        for _ in 0..<(Core.stuckBatchTries - 1) {
            core.flush(force: true)
            XCTAssertEqual(rig.transport.raw.count, 0)
        }
        let queued = rig.queue.count
        // Üçüncü rədd: sətirlər bir-bir göndərilir, sağlam sətirlər çatır, zəhərli sətir növbənin başında qalır.
        core.flush(force: true)
        XCTAssertTrue(rig.transport.names.contains("Before"))
        XCTAssertFalse(rig.transport.names.contains("After"))
        XCTAssertTrue(rig.queue.count < queued)
        XCTAssertTrue(rig.queue.rows.first?.payload.contains("POISON") ?? false)

        // Tək göndərilən sətir `stuckRowTries` dəfə rədd olunandan sonra atılır, qalanlar davam edir.
        for _ in 0..<(Core.stuckRowTries - 2) {
            core.flush(force: true)
            XCTAssertTrue(rig.queue.rows.first?.payload.contains("POISON") ?? false)
        }
        core.flush(force: true)
        XCTAssertEqual(rig.queue.count, 0)
        XCTAssertTrue(rig.transport.names.contains("After"))
        XCTAssertFalse(rig.transport.names.contains("Search"))
        XCTAssertTrue(rig.env.logs.contains { $0.contains("no known error code, dropped") })
        XCTAssertNil(rig.store.map[Core.Keys.stuck])

        // Növbə yenidən adi qaydada işləyir.
        core.track("Later", props: nil, eventId: nil)
        core.flush(force: true)
        XCTAssertTrue(rig.transport.names.contains("Later"))
    }

    func testC4PoisonRowDoesNotBlockTheQueueForThirtyDays() {
        let rig = poisonRig()
        let core = rig.core()
        core.track("Search", props: ["q": "POISON"], eventId: nil)
        core.flush(force: true)
        for day in 1...30 {
            rig.env.time += 86_400_000
            core.track("Daily", props: ["day": day], eventId: nil)
            core.flush(force: true)
        }
        core.flush(force: true)
        XCTAssertEqual(rig.queue.count, 0)
        XCTAssertEqual(rig.transport.names.filter { $0 == "Daily" }.count, 30)
        XCTAssertFalse(rig.transport.names.contains("Search"))
    }

    func testC4IsolatedRowIsDroppedAfterThreeDaysEvenWithFewAttempts() {
        let rig = AuditRig(granted)
        let core = rig.core()
        rig.transport.status = 403
        rig.transport.postError = "blocked"
        core.track("Only", props: nil, eventId: nil)
        // Növbədə SessionStart / AppInstall da var: toplu üç rəddən sonra təcrid olunur.
        for _ in 0..<Core.stuckBatchTries { core.flush(force: true) }
        XCTAssertTrue(rig.queue.count > 0)
        rig.env.time += Core.stuckRowMs + 1
        rig.transport.respond = { batch in
            let events = batch["events"] as? [[String: Any]] ?? []
            return (events.first?["name"] as? String) == "SessionStart" ? 403 : 200
        }
        core.flush(force: true)
        // Yalnız hələ də rədd olunan sətir atılır.
        XCTAssertEqual(rig.queue.count, 0)
        XCTAssertTrue(rig.transport.names.contains("Only"))
        XCTAssertFalse(rig.transport.names.contains("SessionStart"))
    }

    func testC4OutageThatEndsLosesNothing() {
        let rig = AuditRig(granted)
        let core = rig.core()
        rig.transport.status = 403
        rig.transport.postError = "blocked"
        core.track("A", props: nil, eventId: nil)
        core.track("B", props: nil, eventId: nil)
        // Üç toplu rəddi + təcrid olunmuş ilk sətirin dörd rəddi: hələ heç nə atılmır.
        for _ in 0..<(Core.stuckBatchTries + Core.stuckRowTries - 2) { core.flush(force: true) }
        let queued = rig.queue.count
        rig.transport.status = 200
        core.flush(force: true)
        XCTAssertEqual(rig.queue.count, 0)
        XCTAssertEqual(rig.transport.events.count, queued)
        XCTAssertTrue(rig.transport.names.contains("A"))
        XCTAssertTrue(rig.transport.names.contains("B"))
    }

    func testC4ServerErrorsAndThrottlingKeepTheOldBehaviour() {
        // 5xx: toplu hədsiz saxlanır, heç nə atılmır və təcrid olunmur.
        let rig = AuditRig(granted)
        let core = rig.core()
        rig.transport.status = 503
        core.track("A", props: nil, eventId: nil)
        let queued = rig.queue.count
        for _ in 0..<40 {
            rig.env.time += 86_400_000
            core.flush(force: true)
        }
        XCTAssertEqual(rig.queue.count, queued)
        XCTAssertNil(rig.store.map[Core.Keys.stuck])
        // 429 (serverin fasilə tələbi) də sayılmır.
        rig.transport.status = 429
        for _ in 0..<20 {
            rig.env.time += 86_400_000
            core.flush(force: true)
        }
        XCTAssertEqual(rig.queue.count, queued)
        XCTAssertNil(rig.store.map[Core.Keys.stuck])
        // 5xx ardıcıl 4xx sayğacını sıfırlayır.
        rig.transport.status = 403
        rig.transport.postError = "blocked"
        for _ in 0..<(Core.stuckBatchTries - 1) {
            rig.env.time += 86_400_000
            core.flush(force: true)
        }
        XCTAssertNotNil(rig.store.map[Core.Keys.stuck])
        rig.transport.status = 500
        rig.env.time += 86_400_000
        core.flush(force: true)
        XCTAssertNil(rig.store.map[Core.Keys.stuck])
        XCTAssertEqual(rig.queue.count, queued)
        rig.transport.status = 200
        rig.env.time += 86_400_000
        core.flush(force: true)
        XCTAssertTrue(rig.transport.names.contains("A"))
    }

    func testC4StuckStateSurvivesARestart() {
        let rig = AuditRig(granted)
        rig.transport.status = 403
        rig.transport.postError = "blocked"
        var core = rig.core()
        core.track("A", props: nil, eventId: nil)
        core.flush(force: true)
        core.flush(force: true)
        XCTAssertTrue((rig.store.map[Core.Keys.stuck] ?? "").contains("|2|"))
        // Yeni proses: sayğac yaddaşdan oxunur, üçüncü rədd toplunu təcrid edir.
        core = rig.core()
        rig.env.logs.removeAll()
        core.flush(force: true)
        XCTAssertTrue(rig.env.logs.contains { $0.contains("sent one by one") })
    }

    // MARK: - C6. Məşğul növbə: ən köhnə track / screen atılır

    func testC6BusyCallsDropTheOldestAndKeepTheOrder() {
        let calls = BusyCalls(limit: 3)
        var tickets: [BusyCalls.Ticket] = []
        for _ in 0..<5 { tickets.append(calls.add { _ in }) }
        XCTAssertEqual(calls.count, 3)
        // Ən köhnə iki çağırış atılıb, son üçü gözləyir.
        XCTAssertNil(calls.take(tickets[0]))
        XCTAssertNil(calls.take(tickets[1]))
        XCTAssertEqual(calls.takeDropped(), 2)
        XCTAssertEqual(calls.takeDropped(), 0)
        XCTAssertEqual(calls.count, 3)
        XCTAssertNotNil(calls.take(tickets[2]))
        XCTAssertEqual(calls.count, 2)
        // Götürülmüş çağırış ikinci dəfə icra olunmur.
        XCTAssertNil(calls.take(tickets[2]))
        // Yer boşaldıqca yeni çağırışlar heç nə atmadan əlavə olunur.
        tickets.append(calls.add { _ in })
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.takeDropped(), 0)
        XCTAssertNotNil(calls.take(tickets[3]))
        XCTAssertNotNil(calls.take(tickets[4]))
        XCTAssertNotNil(calls.take(tickets[5]))
        XCTAssertEqual(calls.count, 0)
    }

    func testC6DroppedBusyCallIsNeverExecuted() {
        let rig = AuditRig(granted)
        let core = rig.core()
        let calls = BusyCalls(limit: 2)
        var tickets: [BusyCalls.Ticket] = []
        for index in 0..<4 {
            tickets.append(calls.add { core in core.track("T\(index)", props: nil, eventId: nil) })
        }
        for ticket in tickets {
            if let run = calls.take(ticket) { run(core) }
        }
        core.flush(force: true)
        let tracked = rig.transport.names.filter { $0.hasPrefix("T") }
        XCTAssertEqual(tracked, ["T2", "T3"])
    }

    // MARK: - C7. Növbə kəsiləndə sazlama rejimində xəbər verilir

    func testC7QueueTrimIsLoggedInDebug() {
        let config = "{\"enabled\":true,\"flush\":{\"max_queue\":10,\"max_batch\":10}}"
        let rig = AuditRig(granted)
        rig.store.map[Core.Keys.config] = config
        rig.transport.status = 500
        let core = rig.core()
        for index in 0..<20 { core.track("E\(index)", props: nil, eventId: nil) }
        XCTAssertEqual(rig.queue.count, 10)
        XCTAssertTrue(rig.env.logs.contains { $0.contains("queue is full") && $0.contains("dropped") })

        // Sazlama rejimi olmadan loq yazılmır, davranış eynidir.
        let quiet = AuditRig(SmartBeeOptions(consent: SmartBeeConsent(analytics: true, ads: true)))
        quiet.store.map[Core.Keys.config] = config
        quiet.transport.status = 500
        let silent = quiet.core()
        for index in 0..<20 { silent.track("E\(index)", props: nil, eventId: nil) }
        XCTAssertEqual(quiet.queue.count, 10)
        XCTAssertTrue(quiet.env.logs.isEmpty)
    }

    // MARK: - C8. Gözləmə siyahısında reklam rəddi sonrakı razılıqla əvəz olunmur

    func testC8AdsWithdrawalIsNotCoalescedWithALaterGrant() {
        // setConsent(true, false) və ardınca setConsent(true, true): birincisi qalmalıdır (növbə təmizlənməlidir).
        XCTAssertTrue(PendingRule.keepsWithdrawal(lastDenies: false, lastDeniesAds: true, nextDenies: false, nextDeniesAds: false))
        // Analitikanın rəddi də əvvəlki kimi qalır.
        XCTAssertTrue(PendingRule.keepsWithdrawal(lastDenies: true, lastDeniesAds: true, nextDenies: false, nextDeniesAds: false))
        XCTAssertTrue(PendingRule.keepsWithdrawal(lastDenies: true, lastDeniesAds: false, nextDenies: false, nextDeniesAds: true))
        // Eyni və ya daha sərt çağırış əvvəlkini əvəz edə bilər.
        XCTAssertFalse(PendingRule.keepsWithdrawal(lastDenies: false, lastDeniesAds: true, nextDenies: false, nextDeniesAds: true))
        XCTAssertFalse(PendingRule.keepsWithdrawal(lastDenies: false, lastDeniesAds: true, nextDenies: true, nextDeniesAds: true))
        XCTAssertFalse(PendingRule.keepsWithdrawal(lastDenies: false, lastDeniesAds: false, nextDenies: false, nextDeniesAds: false))
        XCTAssertFalse(PendingRule.keepsWithdrawal(lastDenies: false, lastDeniesAds: false, nextDenies: true, nextDeniesAds: true))
    }

    func testC8WithdrawThenRegrantStillScrubsTheQueue() {
        // Nüvədə hər iki çağırış icra olunanda (birləşdirilməyəndə) növbədəki sətirlər reklam məlumatsız qalır.
        let rig = AuditRig(granted)
        rig.transport.status = 500
        let core = rig.core()
        core.onDeepLink("https://shop.az/p/1?utm_source=fb&gclid=G1SECRET")
        core.flush(force: true)
        XCTAssertTrue(rig.stored.contains("G1SECRET"))
        core.setConsent(analytics: true, ads: false)
        core.setConsent(analytics: true, ads: true)
        XCTAssertFalse(rig.stored.contains("G1SECRET"))
        rig.transport.status = 200
        rig.env.time += 2 * Core.backoffMaxMs
        core.flush(force: true)
        XCTAssertFalse(rig.transport.raw.joined().contains("G1SECRET"))
        for post in rig.transport.posts { XCTAssertEqual(adsFlag(post), false) }
    }
}
