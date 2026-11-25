import Foundation
import XCTest
@testable import SmartBeePixel

private let audit3Key = "demo0ios01"

private final class Audit3Store: Store {
    var map: [String: String] = [:]
    func get(_ key: String) -> String? { return map[key] }
    func put(_ key: String, _ value: String) { map[key] = value }
    func remove(_ key: String) { map[key] = nil }
    var corrupt: Bool { return false }
}

private final class Audit3Queue: EventQueue {
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

private final class Audit3Transport: Transport {
    /// Yalnız qəbul olunmuş toplular.
    var raw: [String] = []
    var status = 200

    func post(url: String, json: String) -> HttpResult {
        let accepted = status >= 200 && status <= 299
        if accepted { raw.append(json) }
        return HttpResult(status: status, body: nil)
    }

    func get(url: String, etag: String?) -> HttpResult {
        return HttpResult(status: 200, body: nil, etag: "W/\"1\"")
    }

    var posts: [[String: Any]] { return raw.compactMap { Util.parseObject($0) } }
    var events: [[String: Any]] { return posts.flatMap { $0["events"] as? [[String: Any]] ?? [] } }
}

private final class Audit3Env: Env {
    var time: Int64 = 1_795_590_000_000
    private var counter = 0
    var logs: [String] = []

    func advertising(includeId: Bool) -> AdvertisingInfo {
        return AdvertisingInfo(status: nil, idfa: nil)
    }

    func attRequired() -> Bool { return false }
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
            "app": ["id": "az.smartbee.demo", "version": "1.2.3", "build": "45"],
            "os": ["name": "iOS", "version": "18.1"],
        ]
    }
}

/// Konfiqi artıq bir dəfə alıb keşləmiş tətbiqi təqlid edir.
private final class Audit3Rig {
    let store = Audit3Store()
    let queue = Audit3Queue()
    let transport = Audit3Transport()
    let env = Audit3Env()
    let gate = ConsentGate()
    let options: SmartBeeOptions

    init(_ options: SmartBeeOptions) {
        self.options = options
        store.map[Core.Keys.binding] = Core.binding(key: audit3Key, endpoint: options.endpoint)
        store.map[Core.Keys.config] = "{\"enabled\":true}"
    }

    func core() -> Core {
        let core = Core(key: audit3Key, options: options, store: store, queue: queue, transport: transport, env: env, gate: gate)
        core.start()
        return core
    }

    /// Növbədəki bütün sətirlərin mətni (kontekst və yük).
    var stored: String {
        return queue.rows.map { $0.ctx + $0.payload }.joined(separator: "\n")
    }

    /// Göndərilmiş eventlərdən adı verilən birincisi.
    func event(_ name: String) -> [String: Any] {
        for event in transport.events where (event["name"] as? String) == name { return event }
        return [:]
    }
}

/// Təsdiq turu 3: təmizləmə qaydalarının vektorlardan kənar yoxlamaları — uzun ünvanın qısaldılması (D1; eyni girişlər və
/// gözlənilən dəyərlər veb tracker-in `audit3-scrub.test.js` və Android-in `Audit3ScrubTest.kt` testlərindədir), reklam
/// razılığı geri alınanda ekran adının yenidən təmizlənməsi, `strip_params` müqayisəsi və lüğət / çoxluq dəyərləri (D2).
final class Audit3ScrubTests: XCTestCase {
    private let granted = SmartBeeOptions(consent: SmartBeeConsent(analytics: true, ads: true), debug: true)
    private let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTYifQ.c2lnbmF0dXJlMTIz"

    private func dict(_ value: Any?) -> [String: Any] { return value as? [String: Any] ?? [:] }

    private func head(_ text: String, _ count: Int) -> String {
        return String(decoding: Array(text.utf16.prefix(count)), as: UTF16.self)
    }

    private func screenName(_ event: [String: Any]) -> String? {
        return dict(event["screen"])["name"] as? String
    }

    // MARK: - D1. Uzun ünvanlar veb tracker-dəki kimi qısaldılır

    func testD1LongUrlsAreCleanedAndShortenedExactlyLikeTheWebTracker() {
        let z5000 = String(repeating: "z", count: 5000)
        let z9000 = String(repeating: "z", count: 9000)
        XCTAssertEqual(Util.cleanUrl("https://shop.az/p?token=x&keep=1&pad=" + z5000), head("https://shop.az/p?keep=1&pad=" + z5000, 2048))
        XCTAssertEqual(Util.cleanUrl("https://shop.az/reset/Xk29LmQa/x/y/" + z5000 + "?token=x"), head("https://shop.az/reset/[redacted]/x/y/" + z5000, 2048))
        XCTAssertEqual(Util.cleanUrl("https://shop.az/a/b?x=" + z9000 + "#/r"), "https://shop.az/a/b")
        XCTAssertEqual(Util.cleanUrl("https://shop.az/a/b#/r/" + z9000), "https://shop.az/a/b")
        XCTAssertEqual(Util.cleanUrl("https://shop.az/" + String(repeating: "seg/", count: 3000)), "https://shop.az/" + String(repeating: "seg/", count: 508))
        XCTAssertEqual(Util.cleanUrl("https://shop.az/x/" + z9000), "https://shop.az/x/")
        XCTAssertEqual(Util.cleanUrl("myapp://" + z9000), head("myapp://" + z9000, 2048))
        // Tam 8192 simvol: qısaldılmır, query təmizlənir.
        let tail = String(repeating: "z", count: 8192 - 31)
        let exact = "https://shop.az/p?token=x&keep=" + tail
        XCTAssertEqual(exact.utf16.count, 8192)
        XCTAssertEqual(Util.cleanUrl(exact), head("https://shop.az/p?keep=" + tail, 2048))
        // Kampaniya uzun ünvandan da oxunur.
        let campaign = Util.campaignOf("https://shop.az/?utm_source=fb&pad=" + z5000 + "&utm_medium=cpc") ?? [:]
        XCTAssertEqual(campaign.count, 2)
        XCTAssertEqual(campaign["utm_source"] as? String, "fb")
        XCTAssertEqual(campaign["utm_medium"] as? String, "cpc")
        XCTAssertEqual(Util.stripClickIds("https://shop.az/p?gclid=x&q=" + z9000), "https://shop.az/p")
    }

    func testD1DeepLinkBetween4097And8192CharactersIsTracked() {
        let rig = Audit3Rig(granted)
        let core = rig.core()
        let pad = String(repeating: "z", count: 6000)
        let url = "https://shop.az/p?utm_source=fb&token=x&pad=" + pad
        XCTAssertTrue(url.utf16.count > 4096 && url.utf16.count <= Util.maxUrlLength)
        XCTAssertTrue(Util.isLink(url))
        core.onDeepLink(url)
        core.flush(force: true)
        let props = dict(rig.event("DeepLinkOpen")["props"])
        XCTAssertEqual(props["url"] as? String, head("https://shop.az/p?utm_source=fb&pad=" + pad, 2048))
        let ctx = dict(rig.transport.posts.last?["ctx"])
        XCTAssertEqual(dict(ctx["campaign"])["utm_source"] as? String, "fb")
    }

    // MARK: - Razılıq: ekran adı da yenidən təmizlənir

    func testConsentScreenNameIsReCleanedWhenAdsConsentIsWithdrawn() {
        let rig = Audit3Rig(granted)
        rig.transport.status = 500
        let core = rig.core()
        core.screen("/kampaniya?fbclid=FB1SECRET&x=1", props: nil)
        core.track("ViewItem", props: ["value": 1], eventId: nil)
        core.flush(force: true)
        XCTAssertTrue(rig.stored.contains("FB1SECRET"))

        core.setConsent(analytics: true, ads: false)
        // Diskdəki sətirlər dərhal təmizlənir.
        XCTAssertFalse(rig.stored.contains("FB1SECRET"))

        // Cari ekran adı sonrakı eventlərə də klik ID-siz yazılır.
        core.track("AddToCart", props: ["value": 2], eventId: nil)
        rig.transport.status = 200
        rig.env.time += 2 * Core.backoffMaxMs
        core.flush(force: true)
        XCTAssertFalse(rig.transport.raw.joined(separator: "\n").contains("FB1SECRET"))
        XCTAssertFalse(rig.transport.events.isEmpty)
        for name in ["ScreenView", "ViewItem", "AddToCart"] {
            XCTAssertEqual(screenName(rig.event(name)), "/kampaniya?x=1", name)
        }
    }

    func testConsentScreenNameThatIsOnlyAClickIdIsRemoved() {
        let rig = Audit3Rig(granted)
        rig.transport.status = 500
        let core = rig.core()
        core.screen("#gclid=G1SECRET", props: nil)
        core.flush(force: true)
        XCTAssertTrue(rig.stored.contains("G1SECRET"))
        core.setConsent(analytics: true, ads: false)
        XCTAssertFalse(rig.stored.contains("G1SECRET"))
        core.track("Later", props: nil, eventId: nil)
        rig.transport.status = 200
        rig.env.time += 2 * Core.backoffMaxMs
        core.flush(force: true)
        XCTAssertFalse(rig.transport.events.isEmpty)
        for event in rig.transport.events { XCTAssertNil(event["screen"]) }
    }

    func testConsentScreenNameWithoutClickIdsIsNotTouched() {
        let rig = Audit3Rig(granted)
        rig.transport.status = 500
        let core = rig.core()
        core.screen("Kataloq / Çay dəstləri", props: ["page": 2])
        core.flush(force: true)
        let before = rig.queue.rows.map { $0.payload }
        core.setConsent(analytics: true, ads: false)
        XCTAssertEqual(rig.queue.rows.map { $0.payload }, before)
    }

    func testConsentScreenNameKeepsClickIdsWhileAdsConsentIsGranted() {
        let rig = Audit3Rig(granted)
        let core = rig.core()
        core.screen("/kampaniya?fbclid=FB1SECRET&x=1", props: nil)
        core.flush(force: true)
        XCTAssertEqual(screenName(rig.event("ScreenView")), "/kampaniya?fbclid=FB1SECRET&x=1")
    }

    func testCampaignValuesOfStoredCampaignAreCleanedByName() {
        // Saxlanmış kampaniya göndərilməzdən əvvəl yenə təmizlənir: utm dəyərində telefon və kart gizlədilir, klik ID-sində yox.
        let rig = Audit3Rig(granted)
        let saved: [String: Any] = ["utm_term": "+994501234567", "utm_content": "4111 1111 1111 1111", "yclid": "4111111111111111"]
        rig.store.map[Core.Keys.campaign] = Util.jsonString(saved)
        rig.store.map[Core.Keys.campaignAt] = String(rig.env.time)
        let core = rig.core()
        core.track("ViewItem", props: nil, eventId: nil)
        core.flush(force: true)
        let campaign = dict(dict(rig.transport.posts.last?["ctx"])["campaign"])
        XCTAssertEqual(campaign["utm_term"] as? String, "[redacted]")
        XCTAssertEqual(campaign["utm_content"] as? String, "[redacted]")
        XCTAssertEqual(campaign["yclid"] as? String, "4111111111111111")
    }

    // MARK: - Yeni qaydalar: təkrar təmizləmə və vaxt

    func testNewRulesAreIdempotent() {
        let urls = [
            "https://shop.az/reset;t=" + jwt + ";n=1/x;k=Xk29LmQa", "https://shop.az/reset?dGhpcyBpcyBhIHNlY3JldCB0b2tlbg==", "https://shop.az/p?" + jwt + "=1&keep=1",
            "https://shop.az/p?utm_term=call%20%2B994501234567%20now&utm_content=4111+1111+1111+1111", "https://shop.az/x/t=4111111111111111/y",
            "https://shop.az/confirmation/AZ-778899/Xk29LmQa", "https://shop.az/confirm?order=778899&t=Xk29LmQa", "https://shop.az/2fa/123456",
        ]
        for url in urls {
            let once = Util.cleanUrl(url)
            XCTAssertNotEqual(once, url)
            XCTAssertEqual(Util.cleanUrl(once), once, url)
        }
        let texts = [
            "k=" + jwt + "&z=1", "access_token=Xk29LmQa&z=1", "Authorization: Bearer abcDEF123456", "IBAN AZ21NABZ00000000137010001944.",
            "4111\u{00a0}1111  1111/1111", "\u{201c}" + jwt + "\u{201d}", "mail user\u{ff20}shop.az",
        ]
        for text in texts {
            let once = Util.label(text)
            XCTAssertNotEqual(once, text)
            XCTAssertEqual(Util.label(once), once, text)
        }
    }

    func testNewRulesAreLinearOnHostileInput() {
        func fill(_ unit: String, _ size: Int) -> String {
            return head(String(repeating: unit, count: size / unit.utf16.count + 1), size)
        }
        let texts = [
            "eyJhbGciOiJIUzI1NiJ9.", "9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c.", "aB3", "aB3dEf9hIj2kLm5nOp8qRs1tUv4wXy7z|", "Bearer ", "Bearer abcDEF123456 ",
            "AZ21NABZ00000000137010001944 ", "AZ21", "a=1&token=x&", "=", "access_token=Xk29LmQa ", "4111 \u{00a0}/", "1 - ", "a\u{ff20}", "Step3ShippingAddress", "a-b_", "a.b",
        ]
        let urls: [(String, String)] = [
            ("https://shop.az/reset", ";t=Xk29LmQa"), ("https://shop.az/p", ";"), ("https://shop.az/p", ";n=https%3A%2F%2Fa.az%2Freset%2FXk29LmQa7"),
            ("https://shop.az", "/confirm"), ("https://shop.az/confirm", "/"), ("https://shop.az", "/order/confirm/778899"), ("https://shop.az/x/", "t=Xk29LmQa="),
            ("https://shop.az/reset?", "dGhpcyBpcyBhIHNlY3JldCB0b2tlbg==&"), ("https://shop.az/p?", jwt + "=1&"),
            ("https://shop.az/p?", "utm_term=%2B994501234567&utm_content=4111+1111+1111+1111&"), ("https://shop.az/p?utm_term=", "+1 "), ("https://shop.az", "/2fa/123456"),
        ]
        let started = Date()
        for unit in texts {
            _ = Util.label(fill(unit, 200_000))
            _ = Util.cleanObject(["v": fill(unit, 200_000)])
        }
        for item in urls {
            _ = Util.cleanUrl(item.0 + fill(item.1, 8000))
            _ = Util.label(item.0 + fill(item.1, 8000))
            _ = Util.campaignOf(item.0 + fill(item.1, 200_000))
        }
        // Xətti alqoritm bütün girişləri saniyələrdən tez bitirir; kvadratik olsaydı dəqiqələr çəkərdi.
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }

    // MARK: - D2. `strip_params`, lüğət və çoxluq dəyərləri, keçid olmayan sxemlər (Android ilə eyni)

    func testD2StripParamsAreMatchedByUtf16UnitsAfterTheSdkLowercasing() {
        // Kanonik ekvivalent, amma UTF-16 vahidləri fərqli yazılış (`é` və `e` + U+0301) Android-dəki kimi uyğun gəlmir.
        let composed = RemoteConfig.parse("{\"strip_params\":[\"caf\u{00e9}\"]}")?.stripParams ?? []
        XCTAssertEqual(Util.cleanUrl("https://shop.az/p?caf%C3%A9=1&keep=1", extraStrip: composed), "https://shop.az/p?keep=1")
        XCTAssertEqual(Util.cleanUrl("https://shop.az/p?cafe%CC%81=1&keep=1", extraStrip: composed), "https://shop.az/p?cafe%CC%81=1&keep=1")
        // Böyük hərflər iki tərəfdə də eyni qayda ilə kiçildilir (yunan sözsonu siqması daxil).
        let sigma = RemoteConfig.parse("{\"strip_params\":[\"\u{039f}\u{0394}\u{039f}\u{03a3}\",\"Custom\"]}")?.stripParams ?? []
        XCTAssertEqual(Util.cleanUrl("https://shop.az/p?%CE%9F%CE%94%CE%9F%CE%A3=1&CUSTOM=2&keep=1", extraStrip: sigma), "https://shop.az/p?keep=1")
        XCTAssertEqual(Util.cleanUrl("https://shop.az/p?%CE%BF%CE%B4%CE%BF%CF%82=1&custom=2&keep=1", extraStrip: sigma), "https://shop.az/p?keep=1")
    }

    func testD2DictionaryWithNonStringKeysKeepsItsStringKeys() {
        let mixed: [AnyHashable: Any] = ["plan": "pro", 7: "seven", "page": 2]
        let cleaned = Util.cleanObject(["nested": mixed, "keep": 1]) ?? [:]
        XCTAssertEqual(cleaned["keep"] as? Int, 1)
        let nested = dict(cleaned["nested"])
        XCTAssertEqual(nested.count, 2)
        XCTAssertEqual(nested["plan"] as? String, "pro")
        XCTAssertEqual(nested["page"] as? Int, 2)
        // NSDictionary də eyni qayda ilə.
        let objc = NSDictionary(objects: ["pro", "seven"], forKeys: ["plan" as NSString, NSNumber(value: 7)])
        let fromObjc = dict((Util.cleanObject(["nested": objc]) ?? [:])["nested"])
        XCTAssertEqual(fromObjc.count, 1)
        XCTAssertEqual(fromObjc["plan"] as? String, "pro")
    }

    func testD2SetValueIsSentAsAnArray() {
        let tags: Set<String> = ["a", "b"]
        let cleaned = Util.cleanObject(["tags": tags, "ids": NSSet(array: [1, 2, 3])]) ?? [:]
        let sent = (cleaned["tags"] as? [Any] ?? []).compactMap { $0 as? String }.sorted()
        XCTAssertEqual(sent, ["a", "b"])
        let ids = (cleaned["ids"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }.sorted()
        XCTAssertEqual(ids, [1, 2, 3])
    }

    func testD2AndroidOnlySchemesAreNotLinks() {
        XCTAssertFalse(Util.isLink("android.resource://az.smartbee.demo/raw/x"))
        XCTAssertFalse(Util.isLink("android-app://az.smartbee.demo/https/shop.az/p"))
        XCTAssertTrue(Util.isLink("myapp://open/p"))
    }
}
