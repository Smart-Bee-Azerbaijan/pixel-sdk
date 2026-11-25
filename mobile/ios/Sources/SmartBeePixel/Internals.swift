import CryptoKit
import Foundation

let pixelSdkVersion = "1.0.0"
let defaultEndpoint = "https://c.cdnsb.net"

/// Nə tətbiq (`initialize`-in `consent` seçimi), nə istifadəçi (`setConsent`) razılıq bildirməyibsə qüvvədə olan dəyər.
/// `true`: açarın konfiqindəki `consent_default` tətbiq olunur. `false`: heç kim razılıq bildirməyənə qədər hər iki
/// məqsəd rədd edilmiş sayılır (uzaq konfiq razılığı yalnız aşağı sala bilir, qaldıra bilmir).
/// Susmaya görə davranışı dəyişmək üçün yalnız bu sətir dəyişdirilir (Android-də `CONSENT_WHEN_UNSTATED`).
let consentWhenUnstated = true

// MARK: - Asılılıqlar (Apple tətbiqi Platform.swift-dədir; testlərdə saxta tətbiqlər işlədilir)

/// Kiçik açar-dəyər yaddaşı (identifikatorlar, razılıq, konfiq).
protocol Store: AnyObject {
    func get(_ key: String) -> String?
    func put(_ key: String, _ value: String)
    func remove(_ key: String)
    /// Son yazı diskə çatmayıbsa true (dəyər yaddaşda qüvvədədir, yazı sonra təkrarlanır).
    var unsaved: Bool { get }
    /// Diskə çatmamış yazını təkrarlayır.
    func retrySave()
    /// Yaddaş faylı var və oxunur, amma təhlil olunmur (pozulub): saxlanmış razılıq itmiş ola bilər.
    var corrupt: Bool { get }
}

extension Store {
    var unsaved: Bool { return false }
    func retrySave() {}
    var corrupt: Bool { return false }
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
    /// Növbədəki sətirləri yerində dəyişir (sıra və ID qalır). `change` hər sətir üçün çağırılır: yeni kontekst və
    /// yük qaytarırsa sətir onlarla əvəz olunur, nil qaytarırsa sətirə toxunulmur.
    func update(_ change: (QueuedEvent) -> (ctx: String, payload: String)?)
}

/// Toplu sorğusunun nəticəsi (PROTOCOL.md 5.6).
enum Verdict {
    case accepted
    case retry
    case split
    case drop
    /// Toplu silinir və açar söndürülmüş sayılır (`403 unknown_key`).
    case keyOff
}

/// HTTP cavabı. `body` uğurlu konfiq cavabının gövdəsi və ya rədd cavabının (məhdud ölçüdə oxunmuş) gövdəsidir.
struct HttpResult {
    static let maxErrorChars = 4096
    static let errorUnknownKey = "unknown_key"
    /// `403` cavabının qəti kodları (PROTOCOL.md 5.6, 5.7).
    static let terminalErrors: Set<String> = ["origin_not_allowed", "app_not_allowed", "platform_not_enabled", "unknown_platform", "browser_not_allowed"]
    /// `400` cavabının qəti kodları: toplunun zərfi yararsızdır (PROTOCOL.md 5.6).
    static let badBatchErrors: Set<String> = ["empty_body", "bad_gzip", "bad_json", "bad_batch", "bad_chars"]
    /// `413` cavabının serverin özündən gələn kodları (PROTOCOL.md 5.6).
    static let tooLargeErrors: Set<String> = ["body_too_large", "context_too_large", "too_many_events"]

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

    /// Rədd cavabının JSON gövdəsindəki `error` kodu (PROTOCOL.md 5.6); gövdə JSON deyilsə və ya kod yoxdursa nil.
    var error: String? {
        guard let text = body, text.utf16.count <= HttpResult.maxErrorChars else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let object = Util.parseObject(trimmed) else { return nil }
        return object["error"] as? String
    }

    /// Toplu yalnız serverin öz tanınan `error` kodu ilə silinir (PROTOCOL.md 5.6; Android ilə eyni qayda):
    /// - `413`: birdən çox event varsa toplu bölünür (gövdədən asılı olmayaraq); tək eventlik toplu yalnız
    ///   `tooLargeErrors` kodu ilə silinir.
    /// - `400`: yalnız `badBatchErrors` kodu ilə silinir (WAF-ın `{"error":"blocked"}` cavabı müvəqqətidir).
    /// - `403`: `unknown_key` açarı söndürür, `terminalErrors` kodu toplunu silir.
    /// - `404`: yalnız `unknown_key` açarı söndürür.
    /// Qalan hər şey (`422`, tanınan kodu olmayan hər `4xx`, `3xx`, `408`, `429`, `5xx`, şəbəkə xətası) müvəqqətidir:
    /// toplu saxlanır.
    func verdict(events: Int) -> Verdict {
        if ok { return .accepted }
        let code = error ?? ""
        if status == 413 {
            if events > 1 { return .split }
            return HttpResult.tooLargeErrors.contains(code) ? .drop : .retry
        }
        if status == 400 { return HttpResult.badBatchErrors.contains(code) ? .drop : .retry }
        if status == 403 {
            if code == HttpResult.errorUnknownKey { return .keyOff }
            return HttpResult.terminalErrors.contains(code) ? .drop : .retry
        }
        if status == 404 { return code == HttpResult.errorUnknownKey ? .keyOff : .retry }
        return .retry
    }
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
    /// Reklam identifikatoru və izləmə icazəsinin indiki vəziyyəti. Hər çağırışda sistemdən yenidən oxunur
    /// (istifadəçi icazə pəncərəsinə SDK başlayandan sonra cavab verə bilər) və heç vaxt icazə pəncərəsi göstərmir.
    /// `includeId = false`: yalnız vəziyyət oxunur, identifikatorun özünə toxunulmur.
    func advertising(includeId: Bool) -> AdvertisingInfo
    /// Bu sistemdə izləmə üçün App Tracking Transparency icazəsi tələb olunursa (iOS / tvOS 14+) true.
    /// Sistemə müraciət etmir (ATT vəziyyətini oxumur).
    func attRequired() -> Bool
    /// [0, 1) aralığında təsadüfi ədəd (fasilələrin kənarlaşması üçün).
    func random() -> Double
    func log(_ message: String)
}

extension Env {
    func attRequired() -> Bool { return false }
    func random() -> Double { return Double.random(in: 0..<1) }
}

/// Reklam identifikatoru (IDFA) və App Tracking Transparency vəziyyəti.
struct AdvertisingInfo {
    /// ATT vəziyyəti: `authorized`, `denied`, `restricted` və ya `not_determined`.
    /// ATT olmayan sistemdə (iOS 13 və başqa platformalar) nil.
    var status: String?
    /// IDFA. Yalnız sistem izləməyə icazə verəndə doludur.
    var idfa: String?

    init(status: String? = nil, idfa: String? = nil) {
        self.status = status
        self.idfa = idfa
    }
}

/// Açıq çağırışın (`setConsent`, təkrar `initialize`) çağıran axında dərhal qoyduğu qadağalar. Nüvə onları hər şəbəkə
/// sorğusundan və reklam məlumatının əlavə edilməsindən əvvəl yoxlayır: razılığın geri alınması SDK növbəsini gözləmir.
/// Hər qadağa onu qoyan çağırış nüvədə icra olunandan sonra götürülür (o vaxt nüvənin öz vəziyyəti artıq yenidir).
final class ConsentGate {
    private let lock = NSLock()
    private var analytics = 0
    private var ads = 0

    var analyticsDenied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return analytics > 0
    }

    var adsDenied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ads > 0
    }

    func hold(denyAnalytics: Bool, denyAds: Bool) {
        lock.lock()
        if denyAnalytics { analytics += 1 }
        if denyAds { ads += 1 }
        lock.unlock()
    }

    func release(denyAnalytics: Bool, denyAds: Bool) {
        lock.lock()
        if denyAnalytics, analytics > 0 { analytics -= 1 }
        if denyAds, ads > 0 { ads -= 1 }
        lock.unlock()
    }
}

/// Çağıran axında diskə yazılmış, amma nüvədə hələ icra olunmamış razılıq rəddinin nişanı (bax `ConsentTombstone`).
/// SDK növbəsi şəbəkə sorğusu ilə məşğul ikən proses ölsə belə rədd itmir: növbəti başlanğıcda nişan heç nə
/// göndərilməzdən əvvəl tətbiq olunur.
struct ConsentMark: Equatable {
    /// Analitika rədd edilib: növbə və identifikatorlar silinməlidir (razılıq sonra yenidən verilsə belə).
    var wipe: Bool
    /// Reklam razılığı rədd edilib: növbədəki sətirlərdən və saxlanmış kampaniyadan reklam məlumatı silinməlidir.
    var scrub: Bool
    /// `setConsent`-in son dəyəri (`10` kimi iki simvol); nişanı yalnız təkrar `initialize` qoyubsa nil.
    var consent: String?

    /// Saxlanmış razılığın yararlı dəyərləri: birinci simvol analitika, ikinci reklam.
    static let consentValues: Set<String> = ["00", "01", "10", "11"]
    /// Oxunan, amma təhlil olunmayan nişan: hər iki məqsəd rədd edilmiş sayılır.
    static let strictest = ConsentMark(wipe: true, scrub: true, consent: "00")

    /// Fayldakı yazılış: `wipe`, `scrub` (hərəsi `0` / `1`) və razılıq dəyəri (yoxdursa `--`).
    var text: String {
        return (wipe ? "1" : "0") + (scrub ? "1" : "0") + (consent ?? "--")
    }

    static func parse(_ text: String) -> ConsentMark {
        let chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard chars.count == 4 else { return strictest }
        let flags: Set<Character> = ["0", "1"]
        guard flags.contains(chars[0]), flags.contains(chars[1]) else { return strictest }
        let value = String(chars[2]) + String(chars[3])
        if value == "--" { return ConsentMark(wipe: chars[0] == "1", scrub: chars[1] == "1", consent: nil) }
        guard consentValues.contains(value) else { return strictest }
        return ConsentMark(wipe: chars[0] == "1", scrub: chars[1] == "1", consent: value)
    }

    /// Yeni çağırışla birləşdirir: rədd bayraqları yalnız artır, razılıq dəyəri ən son çağırışınkıdır.
    func adding(denyAnalytics: Bool, denyAds: Bool, consent value: String?) -> ConsentMark {
        return ConsentMark(wipe: wipe || denyAnalytics, scrub: scrub || denyAds, consent: value ?? consent)
    }
}

/// Yaddaşdakı müvəqqəti qat: yazılar `commit` çağırılana qədər diskə getmir.
/// Razılıq hələ məlum deyilkən (ilk konfiq cavabına qədər) və ya açar söndürülübsə identifikatorlar yalnız burada yaşayır.
final class PendingStore: Store {
    private let parent: Store
    private var values: [String: String] = [:]
    private var removed: Set<String> = []

    init(_ parent: Store) {
        self.parent = parent
    }

    func get(_ key: String) -> String? {
        if removed.contains(key) { return nil }
        if let value = values[key] { return value }
        return parent.get(key)
    }

    func put(_ key: String, _ value: String) {
        removed.remove(key)
        values[key] = value
    }

    func remove(_ key: String) {
        values[key] = nil
        removed.insert(key)
    }

    func commit() {
        for key in removed { parent.remove(key) }
        for (key, value) in values { parent.put(key, value) }
        removed.removeAll()
        values.removeAll()
    }
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
    /// SDK-nın ən son buraxılmış versiyası (`sdk_latest`); yoxdursa və ya yararsızdırsa nil.
    var sdkLatest: String?

    // Serverdən gələn dəyərlərin təhlükəsiz hədləri (Android ilə eynidir): səhv və ya zərərli konfiq cihazı
    // saniyədə bir sorğuya, tək eventlik toplulara və ya hədsiz növbəyə məcbur edə bilməz.
    static let minTtlS: Int64 = 60
    static let maxTtlS: Int64 = 7 * 86_400
    static let minSessionS: Int64 = 60
    static let maxSessionS: Int64 = 86_400
    static let minIntervalS: Int64 = 10
    static let maxIntervalS: Int64 = 3600
    static let minBatch: Int64 = 10
    static let maxBatchLimit: Int64 = 100
    static let minQueue: Int64 = 10
    /// Növbə bütöv yaddaşda saxlanır, ona görə serverin icazə verdiyi həddən asılı olmayaraq məhdudlaşdırılır.
    static let maxQueueLimit: Int64 = 5000

    static let standard = RemoteConfig()

    /// Konfiqdə açıq şəkildə `false` verilməyibsə avtomatik event açıqdır.
    func auto(_ name: String) -> Bool {
        return auto[name] != false
    }

    private static func clamp(_ value: Int64, _ low: Int64, _ high: Int64) -> Int64 {
        return min(max(value, low), high)
    }

    /// Tanınmayan sahələr ötürülür; yararsız JSON üçün nil.
    static func parse(_ json: String?) -> RemoteConfig? {
        guard let json = json, !json.isEmpty, let o = Util.parseObject(json) else { return nil }
        var config = RemoteConfig()
        if let v = Util.bool(o["enabled"]) { config.enabled = v }
        if let v = Util.double(o["sample"]), !v.isNaN { config.sample = min(max(v, 0), 1) }
        if let v = Util.int(o["ttl_s"]) { config.ttlMs = clamp(v, minTtlS, maxTtlS) * 1000 }
        if let v = Util.int(o["session_timeout_s"]) { config.sessionTimeoutMs = clamp(v, minSessionS, maxSessionS) * 1000 }
        // `consent_default` yoxdursa susmaya görə dəyərlər qalır. Varsa hər məqsəd yalnız əsl JSON `true` ilə açılır:
        // obyekt olmayan dəyər, çatışmayan və ya boolean olmayan üzv razılıq sayılmır (PROTOCOL.md 8).
        if let raw = o["consent_default"] {
            let consent = raw as? [String: Any] ?? [:]
            config.consentAnalytics = Util.bool(consent["analytics"]) == true
            config.consentAds = Util.bool(consent["ads"]) == true
        }
        if let latest = o["sdk_latest"] as? String, Util.semver(latest) != nil { config.sdkLatest = latest }
        if let auto = o["auto"] as? [String: Any] {
            for (name, value) in auto {
                if let flag = Util.bool(value) { config.auto[name] = flag }
            }
        }
        if let list = o["blocked_events"] as? [Any] { config.blockedEvents = Set(list.compactMap { $0 as? String }) }
        // Android-dəki `lowercase(Locale.ROOT)` ilə eyni çevirmə (bax `Util.jsLower`).
        if let list = o["strip_params"] as? [Any] { config.stripParams = Set(list.compactMap { ($0 as? String).map { Util.jsLower($0) } }) }
        if let flush = o["flush"] as? [String: Any] {
            if let v = Util.int(flush["interval_s"]) { config.flushIntervalMs = clamp(v, minIntervalS, maxIntervalS) * 1000 }
            if let v = Util.int(flush["max_batch"]) { config.maxBatch = Int(clamp(v, minBatch, maxBatchLimit)) }
            if let v = Util.int(flush["max_queue"]) { config.maxQueue = Int(clamp(v, minQueue, maxQueueLimit)) }
        }
        return config
    }
}

/// `Util.snapshot`-un nəticəsi: `oversized` olduqda `value` nil-dir və event parametrsiz gedir.
struct Snapshot {
    var value: [String: Any?]?
    var oversized: Bool
}

// MARK: - Köməkçilər

enum Util {
    /// Keçidin ən böyük uzunluğu (UTF-16 vahidi ilə; tracker: URL_IN_MAX, Android: MAX_URL_LENGTH). Bundan uzun dərin keçid
    /// nəzərə alınmır; `cleanUrl` bundan uzun ünvanı təmizləməzdən əvvəl qısaldır (bax `shorten`).
    static let maxUrlLength = 8192
    static let redacted = "[redacted]"
    private static let redactedUnits: [UInt16] = Array("[redacted]".utf16)

    // Həssas adlar (query parametrləri, yol hissələri, `props` / `traits` açarları).
    //
    // Qaydalar və siyahılar veb tracker-dəki (tracker/src/tracker.js) və Android-dəki (Internals.kt) qaydalarla
    // hərf-hərf eynidir və üç SDK-da ortaq vektorlarla yoxlanır (spec/vectors/sanitize-url.json, sanitize-props.json,
    // identity.json, campaign.json). Ad əvvəlcə sözlərə ayrılır (bax `nameWords`). «Hissə» siyahıları sözün istənilən
    // yerində axtarılır; qısa və çoxmənalı sözlər («söz» siyahıları) yalnız bütöv söz kimi tutulur, yoxsa `inside`,
    // `hotel`, `company`, `keyword`, `author` kimi adlar da tutulardı.

    /// Query parametri (tracker: PARAM_RE): sözün içində axtarılan hissələr.
    private static let paramParts = [
        "token", "passw", "pasword", "passphrase", "passport", "pasport", "passcode", "pwd", "psw", "secret", "session", "sessid", "jwt",
        "msisdn", "iban", "signature", "mail", "apikey", "credential", "csrf", "xsrf", "oauth", "authoris", "authoriz", "authent",
        "bearer", "cvv", "cvc", "saml", "checkword", "cardnumber", "authcode", "smscode", "otpcode", "resetcode", "accesskey",
        "privatekey", "homephone", "mobilephone", "parol", "sifre", "shifre", "eposta", "poct",
    ]
    /// Telefon adları: söz bu hissələrdən biri ilə başlayır (`phone`, `phoneNumber`, `telephone`, `telefon`; `iphone` yox).
    private static let phonePrefixes = ["phone", "telephone", "cellphone", "telefon"]
    /// Telefon adları: sözün istənilən yerində axtarılan bitişik yazılışlar (yalnız `props` / `traits` açarları üçün).
    private static let phoneKeyParts = ["homephone", "mobilephone"]
    /// Query parametri (tracker: PARAM_RE): bütöv söz kimi axtarılanlar.
    private static let paramWords: Set<String> = [
        "pass", "sig", "sign", "auth", "sid", "otp", "code", "kod", "kodu", "key", "tel", "mobile", "card", "pan", "fin", "pin", "ssn",
        "hash", "nonce", "reset", "activation", "confirm", "verify", "invite", "unsubscribe", "ticket", "magic", "pw", "cc", "mobil",
        "nomre", "whatsapp", "kart",
    ]
    /// Sirr olmayan «… code / kod / kodu» adları (tracker: SAFE_NAME_RE): bu sözlərdən birinin ardınca gələn kod sözü saxlanır.
    private static let safeCodeWords: Set<String> = [
        "promo", "coupon", "discount", "country", "lang", "language", "currency", "postal", "post", "zip", "region", "area",
        "product", "item", "color", "colour", "error", "status", "sku", "bar", "qr", "referral", "invite", "ref", "store", "model",
        "partner", "category", "endirim", "mehsul", "olke",
    ]
    private static let codeWords: Set<String> = ["code", "kod", "kodu"]
    /// Çoxmənalı söz və ardınca gələn təsvir sözü (tracker: SAFE_NAME_RE; `card_type`, `phone_model`): cüt sirr deyil.
    private static let describedWords: Set<String> = ["card", "kart", "ticket", "phone", "mobile", "pin", "pan", "pass", "fin"]
    private static let describingWords: Set<String> = ["type", "model", "brand", "os", "size", "color", "colour", "count"]
    /// Dəyəri ən çoxu 2 simvol olan parametrdə bayraq sayılan sözlər (tracker: FLAG_NAME_RE; `mobile=1`, `cc=az`).
    private static let flagNameWords: Set<String> = ["mobile", "mobil", "cc"]
    /// Dəyərinə sirr qaydaları tətbiq olunmayan utm parametrləri (tracker: UTM); `utm_token` kimi adlar adi parametrdir.
    private static let utmNames: Set<String> = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id"]
    /// `props` / `traits` açarı (tracker: FORBIDDEN): kiçik hərflə yazılmış ad dəqiq budursa dəyər heç vaxt göndərilmir.
    private static let forbiddenKeys: Set<String> = ["email", "phone", "password", "pass", "token", "card", "card_number", "cvv", "pin", "fin", "kart"]
    /// `props` / `traits` açarı (tracker: SECRET_PARTS): sözün içində axtarılan sirr hissələri.
    private static let secretKeyParts = [
        "passw", "pasword", "passphrase", "passport", "pasport", "passcode", "pwd", "psw", "secret", "cvv", "cvc", "iban", "cardnumber",
        "apikey", "accesskey", "privatekey", "sessionid", "sessid", "csrf", "xsrf", "bearer", "credential", "parol", "sifre", "shifre",
    ]
    /// Adın istənilən yerində açarı həmişə atan bütöv sözlər (tracker: SECRET_WORDS).
    private static let secretKeyWordList: Set<String> = ["authorization", "authorisation"]
    /// Qısa, çoxmənalı sözlər (tracker: LAST_WORDS): yalnız adın son sözü olanda (və ya ardınca təsvir sözü gələndə) sirdir.
    private static let lastKeyWords: Set<String> = ["pass", "pin", "fin", "otp", "totp", "jwt", "ssn", "pan", "cookie", "pw", "auth", "session", "sid"]
    /// Dəyər bayraq (`true` / `false` / null) olmayanda açarı atan adlar (tracker: FLAG_PARTS, FLAG_WORDS, LICENSE_WORDS,
    /// NUMBER_OWNER_WORDS): sözün içində axtarılan hissələr, bütöv sözlər, `license key` cütü və ardınca nömrə sözü
    /// (`phoneDetailWords`) gələn sahib sözləri (`cc_number`, `account_number`, `hesab_nomresi`).
    private static let flagKeyParts = ["signature", "cardholder", "creditcard", "pinkod"]
    private static let flagKeyWords: Set<String> = ["sig", "nonce"]
    private static let licenseWords: Set<String> = ["license", "licence"]
    private static let numberOwnerWords: Set<String> = ["cc", "account", "hesab"]
    /// Sirr sözündən sonra gələndə açarı yenə sirr edən təsvir sözləri (tracker: SECRET_DETAIL_WORDS; `otp_code`, `cookie_value`).
    private static let secretDetailWords: Set<String> = ["number", "num", "no", "nomre", "nomresi", "code", "kod", "kodu", "value", "word", "phrase"]
    private static let cardWords: Set<String> = ["card", "kart"]
    private static let cardDetailWords: Set<String> = ["number", "num", "no", "holder", "exp", "expiry", "cvv", "cvc", "pan", "nomre", "nomresi"]
    /// `card` sözündən əvvəl gələndə onu ödəniş kartı olmayan əşya edən sözlər (tracker: SAFE_CARD_WORDS; `gift_card`).
    private static let safeCardWords: Set<String> = ["video", "memory", "gift", "graphics", "sd", "sim", "sound", "flash", "greeting", "business", "post"]
    /// `key` sözündən əvvəl gələndə açarı sirr edən sözlər (`api_key`, `accessKey`, `private_key`, `auth_key`).
    private static let keyOwnerWords: Set<String> = ["api", "access", "private", "auth"]
    /// `code` / `kod` sözündən əvvəl gələndə onu birdəfəlik kod edən sözlər (tracker: CODE_OWNER_WORDS; `sms_code`).
    private static let codeOwnerWords: Set<String> = [
        "sms", "verification", "verify", "otp", "auth", "security", "confirm", "confirmation", "activation", "reset", "login", "access",
        "pin", "pass", "secret", "recovery", "backup", "mfa", "tfa", "twofa", "fa", "tesdiq", "dogrulama",
    ]
    /// E-poçt adları (tracker: MAIL_PARTS): sözün istənilən yerində axtarılan hissələr.
    private static let mailKeyParts = ["mail", "eposta", "poct"]
    /// `props` / `traits` açarı (tracker: PHONE_WORDS): telefon adı sayılan bütöv sözlər (`phonePrefixes`-dən əlavə).
    private static let phoneKeyWordList: Set<String> = ["tel", "msisdn", "mobile", "gsm", "mobil", "nomre", "whatsapp"]
    private static let phoneDetailWords: Set<String> = ["number", "num", "no", "nomre", "nomresi"]
    /// E-poçt / telefon sözündən sonra gələndə açarı əlaqə məlumatı olmayan ayar edən sözlər (tracker: CONTACT_DETAIL_WORDS;
    /// `email_template`, `mailing_list`) və belə açarın əlaqə məlumatı olmayan dəyərləri (tracker: CONTACT_VALUES;
    /// `mobile: "ios"`); bax `contactLabel`.
    private static let contactDetailWords: Set<String> = ["template", "campaign", "provider", "list", "type", "status", "verified", "enabled", "optin", "consent"]
    private static let contactValues: Set<String> = ["ios", "android", "web", "yes", "no", "true", "false"]
    /// Bundan kiçik (mütləq qiymətcə) ədəd sayğacdır, sirr deyil (tracker: SMALL_NUMBER; `emails_sent: 5`).
    private static let smallNumber: Double = 100000
    /// Bundan uzun mətn (UTF-16 vahidi ilə) e-poçt / telefon namizədi deyil (tracker: CONTACT_MAX).
    static let contactMax = 320
    /// Yol ipucu (tracker: HINT_STEMS, HINT_WORDS, HINT_PAIRS): hissənin birinci və ya sonuncu sözü bu köklərdən biri ilə
    /// başlayırsa və ya bu sözlərdən biridirsə, sonrakı iki hissə sirr kimi yoxlanır (bax `pathHint`).
    private static let hintStems = [
        "reset", "forgot", "passw", "pasword", "sifre", "shifre", "parol", "unuttum", "tesdiq", "dogrula", "aktivle", "aktivas",
        "signin", "login", "verify", "verific", "confirm", "activat", "magic", "invit", "unsubscribe", "token", "secret", "recover",
        "restore", "signature",
    ]
    private static let hintWords: Set<String> = ["otp", "pwd", "psw", "sso", "msisdn", "iban", "auth", "oauth", "callback", "session", "join", "mfa", "2fa"]
    private static let hintPairs: Set<String> = ["signin", "login"]
    /// Sifariş təsdiqi səhifələri (tracker: SOFT_STEMS, ORDER_WORDS, PAY_WORDS). Hissənin ipucu yalnız təsdiq kökündən
    /// (`confirm…`, `tesdiq…`) gəlirsə ipucu qalır, amma sifariş kontekstində — hissənin özündə `orderWords` sözü var
    /// (`order-confirmation`), hissə təkcə təsdiq sözüdür və qonşu (əvvəlki / sonrakı) hissə `orderWords` sözüdür
    /// (`/order/confirm/…`), ya da hissə təkcə `confirmation` sözüdür — sonrakı iki hissədə sifariş nömrəsinə bənzəyən hissə
    /// (bax `refShaped`: `2026112500123`, `AZ-778899`) ipucusuz yoxlanır. Qarışıq hərfli token (`/order/confirm/Zq7Lm2Xp9Rt4`)
    /// gizlədilir. Ödəniş sözünün (`payWords`) kontekstində 6–8 rəqəmlik kod (bax `payCode`: təsdiq kodu uzunluğu) sifariş
    /// nömrəsi sayılmır (`/payment/confirmation/879609`).
    private static let softStems: Set<String> = ["confirm", "tesdiq"]
    private static let orderWords: Set<String> = ["order", "orders", "checkout", "payment", "payments", "booking", "purchase", "sifaris", "odenis"]
    private static let payWords: Set<String> = ["payment", "payments", "odenis"]
    /// Təsdiq kökünün ipucu altında dəyəri ipucusuz yoxlanan query parametrləri: adın bütün sözləri bu siyahıdadır (`order_id`,
    /// `ref`) və dəyər sifariş nömrəsinə bənzəyir (bax `refShaped`). Yol sifariş kontekstində deyilsə adda `orderNameWords`
    /// sözü də olmalıdır.
    private static let orderParamWords: Set<String> = ["order", "booking", "ref", "reference", "number", "id"]
    private static let orderNameWords: Set<String> = ["order", "booking"]
    /// Sirr sözünə bənzəyən, amma sirr olmayan köklər (tracker: PLAIN_STEM_RE): «şifrələ…» (şifrələmə) və `secretar…` (secretary).
    private static let plainStemSifrel: [UInt16] = Array("sifrel".utf16)
    private static let plainStemSecretar: [UInt16] = Array("secretar".utf16)
    private static let bearerUnits: [UInt16] = Array("bearer".utf16)
    private static let jwtStart: [UInt16] = Array("eyJ".utf16)
    private static let confirmationWord = "confirmation"
    /// Telefon sözü olan hissədən (`/phone/`, `/tel/`) birbaşa sonrakı hissə yalnız 7–15 rəqəmdirsə gizlədilir (tracker: PHONE_HINT_WORDS).
    private static let phoneHintWords: Set<String> = ["phone", "telephone", "tel", "telefon", "mobile", "mobil", "nomre", "gsm", "whatsapp"]
    /// Statik fayl uzantıları (tracker: STATIC_EXT): belə adlı yol hissəsi ipucu qaydası ilə gizlədilmir; `@2x.png` sonluqlu şəkil adı e-poçt sayılmır.
    private static let staticExt: Set<String> = [
        "js", "mjs", "css", "map", "png", "jpg", "jpeg", "gif", "svg", "webp", "avif", "ico", "woff", "woff2", "ttf", "otf", "eot",
    ]
    /// Tanınan API açarı önləri (tracker: KEY_PREFIX_RE): ardınca ən azı 10 base64url simvolu gəlirsə sirdir.
    private static let keyPrefixes: [[UInt16]] = [
        Array("sk_live_".utf16), Array("sk_test_".utf16), Array("rk_live_".utf16), Array("rk_test_".utf16), Array("whsec_".utf16),
        Array("ghp_".utf16), Array("gho_".utf16), Array("github_pat_".utf16), Array("glpat-".utf16), Array("xoxb-".utf16),
        Array("xoxp-".utf16), Array("AKIA".utf16), Array("AIza".utf16),
    ]
    /// `@` kimi oxunan tam enli işarə (U+FF20; tracker: WIDE_AT): e-poçt axtarışında `@` sayılır.
    private static let cWideAt: UInt16 = 0xff20
    /// İstifadəçi ID-sinin əvvəlindən atılan önlər (tracker: ID_PREFIXES).
    private static let idPrefixes: [[UInt16]] = [
        Array("tel:".utf16), Array("phone:".utf16), Array("sms:".utf16), Array("mailto:".utf16), Array("email:".utf16),
    ]
    private static let smsPrefix: [UInt16] = Array("sms:".utf16)
    private static let cursorSuffix: [UInt16] = Array("cursor".utf16)

    /// URL kimi təmizlənən `props` / `traits` mətn dəyərinin ən böyük uzunluğu; bundan uzun URL dəyəri tam gizlədilir.
    static let maxTextUrl = 8192

    private static let telPrefix: [UInt16] = Array("tel:".utf16)
    private static let httpPrefix: [UInt16] = Array("http:".utf16)
    private static let httpsPrefix: [UInt16] = Array("https:".utf16)
    private static let snapClickId: [UInt16] = Array("ScCid".utf16)
    private static let snapClickIdLower: [UInt16] = Array("sccid".utf16)

    /// İstifadəçi ID-sinin ən böyük uzunluğu (UTF-16 vahidi ilə, veb tracker-dəki kimi).
    static let maxUserId = 128

    private static let campaignKeys = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content"]
    static let clickIds = [
        "fbclid", "gclid", "gbraid", "wbraid", "ttclid", "msclkid", "dclid", "twclid", "yclid", "li_fat_id",
        "sccid", "rdt_cid", "_gl", "mc_eid", "srsltid", "epik", "gad_source",
    ]

    /// `scheme://` şəklində yazılsa belə keçid sayılmayan sxemlər: telefon, ünvan, fayl və məzmun istinadları.
    private static let notLinks: Set<String> = [
        "tel", "sms", "smsto", "mms", "mmsto", "mailto", "geo", "content", "file", "data", "intent",
        "android.resource", "android-app", "blob", "javascript", "about",
    ]

    // UTF-16 vahidləri (mətnlər Android-dəki `Char` ardıcıllığı ilə eyni qaydada emal olunsun deyə).
    private static let cTab: UInt16 = 9
    private static let cSpace: UInt16 = 32
    private static let cExclamation: UInt16 = 33
    private static let cHash: UInt16 = 35
    private static let cPercent: UInt16 = 37
    private static let cAmp: UInt16 = 38
    private static let cApostrophe: UInt16 = 39
    private static let cOpen: UInt16 = 40
    private static let cClose: UInt16 = 41
    private static let cAsterisk: UInt16 = 42
    private static let cPlus: UInt16 = 43
    private static let cDash: UInt16 = 45
    private static let cDot: UInt16 = 46
    private static let cSlash: UInt16 = 47
    private static let cColon: UInt16 = 58
    private static let cSemicolon: UInt16 = 59
    private static let cEquals: UInt16 = 61
    private static let cQuestion: UInt16 = 63
    private static let cAt: UInt16 = 64
    private static let cUnderscore: UInt16 = 95
    private static let cTilde: UInt16 = 126
    private static let cNbsp: UInt16 = 0x00a0

    private static func isLetter(_ c: UInt8) -> Bool { return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    private static func isDigit(_ c: UInt8) -> Bool { return c >= 48 && c <= 57 }

    private static func isLower(_ c: UInt16) -> Bool { return c >= 97 && c <= 122 }
    private static func isUpper(_ c: UInt16) -> Bool { return c >= 65 && c <= 90 }
    private static func isNumber(_ c: UInt16) -> Bool { return c >= 48 && c <= 57 }
    private static func isAlnum(_ c: UInt16) -> Bool { return isLower(c) || isUpper(c) || isNumber(c) }
    private static func isAlpha(_ c: UInt16) -> Bool { return isLower(c) || isUpper(c) }
    private static func lower(_ c: UInt16) -> UInt16 { return isUpper(c) ? c + 32 : c }

    private static func string(_ units: [UInt16]) -> String {
        return String(decoding: units, as: UTF16.self)
    }

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

    /// Örtüyün adı sxemdəki şablona (`^[a-z][a-z0-9-]{0,31}$`) uyğundursa özü, yoxsa nil (yararsız ad göndərilmir).
    static func wrapperName(_ name: String?) -> String? {
        guard let name = name else { return nil }
        let bytes = Array(name.utf8)
        guard let first = bytes.first, bytes.count <= 32, first >= 97, first <= 122 else { return nil }
        return bytes.allSatisfy { ($0 >= 97 && $0 <= 122) || isDigit($0) || $0 == 45 } ? name : nil
    }

    /// Örtüyün versiyası: 1–32 simvol; boşdursa nil.
    static func wrapperVersion(_ version: String?) -> String? {
        guard let version = version else { return nil }
        let cleaned = text(version.trimmingCharacters(in: .whitespacesAndNewlines), limit: 32)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// `MAJOR.MINOR.PATCH` (yalnız rəqəmlər) yazılışını üç ədədə ayırır; başqa hər şey üçün nil.
    static func semver(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var out: [Int] = []
        for part in parts {
            let bytes = Array(part.utf8)
            // 9 rəqəm həddi ədədin daşmasının qarşısını alır.
            guard !bytes.isEmpty, bytes.count <= 9, bytes.allSatisfy({ isDigit($0) }), let number = Int(String(part)) else { return nil }
            out.append(number)
        }
        return out
    }

    /// `latest` versiyası `current`-dən yenidirsə true. Hissələr ədəd kimi müqayisə olunur (1.10.0 > 1.9.0);
    /// versiyalardan biri yararsızdırsa false.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let a = semver(latest), let b = semver(current) else { return false }
        for index in 0..<3 where a[index] != b[index] {
            return a[index] > b[index]
        }
        return false
    }

    /// Reklam identifikatorunu yoxlayır: UUID olmalıdır və yalnız sıfırlardan ibarət olmamalıdır
    /// (izləmə məhdudlaşdırılanda sistem sıfır UUID qaytarır). Yararsızdırsa nil.
    static func advertisingId(_ raw: String?) -> String? {
        guard let raw = raw, let parsed = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let text = parsed.uuidString
        return text == "00000000-0000-0000-0000-000000000000" ? nil : text
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

    /// Başdakı və sondakı boşluqları silir; boşluq JavaScript-in `\s` sinfidir (bax `isSpace`),
    /// `whitespacesAndNewlines` yox.
    static func jsTrim(_ text: String) -> String {
        let u = Array(text.utf16)
        var start = 0
        var end = u.count
        while start < end && isSpace(u[start]) { start += 1 }
        while end > start && isSpace(u[end - 1]) { end -= 1 }
        if start == 0 && end == u.count { return text }
        return string(Array(u[start..<end]))
    }

    /// PROTOCOL.md 6.1: başdakı və sondakı boşluqlar silinir, kiçik hərfə çevrilir.
    static func normalizeEmail(_ email: String) -> String {
        return jsLower(jsTrim(email))
    }

    /// Kiçik hərfə çevirmə — JS-in `toLowerCase()` və Java-nın `lowercase()` ilə eyni nəticə.
    /// Swift-in `lowercased()` funksiyası yunan sözsonu siqmasını (Σ → ς) nəzərə almır: `ΧΡΗΣΤΟΣ@x.gr`
    /// başqa hash verərdi. Qayda (Unicode Final_Sigma): Σ-dan əvvəl hərf varsa və sonra hərf gəlmirsə ς olur
    /// (aradakı «case-ignorable» simvollar ötürülür).
    static func jsLower(_ text: String) -> String {
        let capitalSigma: Unicode.Scalar = "\u{03A3}"
        let smallSigma: Unicode.Scalar = "\u{03C3}"
        let finalSigma: Unicode.Scalar = "\u{03C2}"
        let scalars = Array(text.unicodeScalars)
        if !scalars.contains(capitalSigma) { return text.lowercased() }
        var out = String.UnicodeScalarView()
        for index in 0..<scalars.count {
            let scalar = scalars[index]
            if scalar != capitalSigma {
                out.append(scalar)
                continue
            }
            var before = false
            var back = index - 1
            while back >= 0 {
                let properties = scalars[back].properties
                if properties.isCaseIgnorable {
                    back -= 1
                    continue
                }
                before = properties.isCased
                break
            }
            var after = false
            var forward = index + 1
            while forward < scalars.count {
                let properties = scalars[forward].properties
                if properties.isCaseIgnorable {
                    forward += 1
                    continue
                }
                after = properties.isCased
                break
            }
            out.append(before && !after ? finalSigma : smallSigma)
        }
        return String(out).lowercased()
    }

    /// PROTOCOL.md 6.1: yalnız rəqəmlər.
    static func normalizePhone(_ phone: String) -> String {
        return String(String.UnicodeScalarView(phone.unicodeScalars.filter { $0.value >= 48 && $0.value <= 57 }))
    }

    /// `^[^@\s]+@[^@\s]+\.[^@\s]+$` (veb tracker ilə eyni qayda), regex-siz.
    static func isEmailShaped(_ text: String) -> Bool {
        let u = Array(text.utf16)
        guard let at = u.firstIndex(of: cAt), at > 0 else { return false }
        var index = 0
        while index < u.count {
            if isSpace(u[index]) { return false }
            if u[index] == cAt, index != at { return false }
            index += 1
        }
        // Domen: `@`-dən sonra ən azı bir simvol, nöqtə və yenə ən azı bir simvol.
        var dot = at + 2
        while dot < u.count - 1 {
            if u[dot] == cDot { return true }
            dot += 1
        }
        return false
    }

    /// İstifadəçi ID-si telefon nömrəsinə oxşayırsa onun rəqəmləri (`phone_sha256` ilə eyni normallaşdırma: yalnız
    /// rəqəmlər, başdakı `+` atılır), yoxsa nil. Qayda veb tracker-in `phoneDigits` funksiyası və Android ilə eynidir
    /// ki, eyni istifadəçi bütün platformalarda eyni `user_id` alsın: mətn `^\+?[0-9(][0-9\s().-]{5,24}$`
    /// şəklindədir və 7–15 rəqəmi var; telefon sayılır: `+` ilə başlayan, 10 və daha çox rəqəmli və ya `0` ilə
    /// başlayan 9+ rəqəmli (qısa ədədi ID-lər, məsələn bazanın sıra nömrəsi, telefon sayılmır).
    static func userIdPhone(_ text: String) -> String? {
        let u = Array(text.utf16)
        let start = (!u.isEmpty && u[0] == cPlus) ? 1 : 0
        let body = u.count - start
        if body < 6 || body > 25 { return nil }
        let first = u[start]
        if !isNumber(first) && first != cOpen { return nil }
        var digits: [UInt16] = []
        var index = start
        while index < u.count {
            let c = u[index]
            if isNumber(c) {
                digits.append(c)
            } else if !(c == cOpen || c == cClose || c == cDot || c == cDash || isSpace(c)) {
                return nil
            }
            index += 1
        }
        let n = digits.count
        if n < 7 || n > 15 { return nil }
        return (start == 1 || n >= 10 || (digits[0] == 48 && n >= 9)) ? string(digits) : nil
    }

    /// `identify`-ın göndərilən `user_id`-si (veb tracker-in `identify` funksiyası və Android ilə eyni qayda); ID
    /// yararsızdırsa nil. Boş və ya `maxUserId`-dən uzun (UTF-16 vahidi ilə, NUL silinməzdən əvvəl) ID rədd olunur.
    /// E-poçt ünvanına (boşluqlar silinib kiçik hərfə çevriləndən sonra) və ya telefon nömrəsinə (bax `userIdPhone`)
    /// oxşayan ID açıq göndərilmir və saxlanmır: yerinə normallaşdırılmış dəyərin SHA-256-sı işlədilir. Qalan ID
    /// olduğu kimi (yalnız NUL silinir, kənar boşluqlar qalır) göndərilir.
    static func userId(_ id: String?) -> String? {
        guard let id = id, !id.isEmpty, id.utf16.count <= maxUserId else { return nil }
        let raw = text(id)
        var plain = jsTrim(raw)
        // Başdakı `tel:` / `phone:` / `sms:` / `mailto:` / `email:` atılır (tracker: ID_PREFIXES; yalnız ASCII hərfləri).
        let given = Array(plain.utf16)
        for prefix in idPrefixes {
            if matchesAt(given, 0, prefix) {
                plain = jsTrim(string(Array(given[prefix.count...])))
                break
            }
        }
        // JWT giriş sirridir, identifikator deyil: rədd olunur.
        if isJwt(Array(plain.utf16)) { return nil }
        // Tam enli `＠` (U+FF20) `@` sayılır.
        var mail = string(Array(jsLower(plain).utf16).map { $0 == cWideAt ? cAt : $0 })
        if !isEmailShaped(mail) {
            let u = Array(mail.utf16)
            if let at = u.firstIndex(of: cAt), at > 0 { mail = emailIn(u) }
        }
        if isEmailShaped(mail) { return sha256(mail) }
        if let phone = userIdPhone(plain) { return sha256(phone) }
        // Kart nömrəsinə bənzəyən ID (15–19 rəqəm, Luhn): rəqəmlərinin hash-i göndərilir.
        if cardNumber(Array(plain.utf16)) { return sha256(normalizePhone(plain)) }
        return raw.isEmpty ? nil : raw
    }

    /// İstifadəçi ID-sinin (kiçik hərflə, UTF-16 vahidləri) içindəki e-poçt ünvanı; yoxdursa mətnin özü (tracker: `emailIn`).
    /// Mətn boşluq və `< > ( ) [ ] " ' , ; :` simvollarına görə bölünür: ilk e-poçta bənzəyən hissə götürülür; yoxdursa bir
    /// neçə `@` olan hissədə (`user@shop.az@tenant`) `@` ilə ayrılmış qonşu iki parçadan alınan ilk ünvan.
    private static func emailIn(_ u: [UInt16]) -> String {
        var tokens: [[UInt16]] = []
        var start = 0
        var i = 0
        while i <= u.count {
            if i < u.count && !isIdSeparator(u[i]) {
                i += 1
                continue
            }
            if i > start { tokens.append(Array(u[start..<i])) }
            start = i + 1
            i += 1
        }
        for token in tokens {
            let text = string(token)
            if isEmailShaped(text) { return text }
        }
        for token in tokens {
            var from = 0
            var at = indexOf(token, cAt, from: 0)
            while at >= 0 {
                let next = indexOf(token, cAt, from: at + 1)
                let pair = string(Array(token[from..<(next < 0 ? token.count : next)]))
                if isEmailShaped(pair) { return pair }
                from = at + 1
                at = next
            }
        }
        return string(u)
    }

    private static func isIdSeparator(_ c: UInt16) -> Bool {
        // `< > ( ) [ ] " ' , ; :`
        return isSpace(c) || c == 60 || c == 62 || c == cOpen || c == cClose || c == 91 || c == 93 || c == 34 || c == cApostrophe
            || c == 44 || c == cSemicolon || c == cColon
    }

    /// Yalnız http / https və iyerarxik (`scheme://...`) tətbiq keçidləri izlənir (`^[a-zA-Z][a-zA-Z0-9+.-]*://`).
    /// `tel:`, `sms:`, `mailto:`, `geo:`, `content://`, `file://` kimi ünvanlar şəxsi məlumat daşıyır və keçid deyil.
    /// `maxUrlLength`-dən uzun ünvan keçid sayılmır.
    static func isLink(_ url: String) -> Bool {
        let u = Array(url.utf16)
        if u.count > maxUrlLength { return false }
        let length = schemeLength(u)
        if length == 0 { return false }
        let scheme = string(Array(u[0..<(length - 3)])).lowercased()
        return !notLinks.contains(scheme)
    }

    /// Telefon ədəd kimi verilə bilər (React Native / Flutter-də `Double`): eksponentsiz onluq yazılış götürülür.
    static func phoneText(_ value: Any?) -> String? {
        guard let value = value else { return nil }
        if let string = value as? String { return string }
        guard let number = value as? NSNumber, !isBool(number) else { return nil }
        let kind = String(cString: number.objCType)
        if kind != "d", kind != "f" { return number.stringValue }
        let double = number.doubleValue
        guard double.isFinite else { return nil }
        // Ədədin tam onluq yazılışı; sondakı artıq sıfırlar atılır.
        var text = String(format: "%.1074f", double)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
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

    /// Yalnız əsl JSON `true` / `false`; 0 və 1 ədədləri qəbul edilmir (Android ilə eyni qayda).
    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isBool(number) else { return nil }
        return number.boolValue
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// NUL simvolunu (U+0000) silir və `limit` verilibsə mətni o qədər Unicode kod nöqtəsinə kəsir.
    /// Sxemdəki uzunluq hədləri kod nöqtəsi ilə sayılır, `Character` isə bir neçə kod nöqtəsindən ibarət ola bilər.
    static func text(_ value: String, limit: Int? = nil) -> String {
        var out = String.UnicodeScalarView()
        var kept = 0
        for scalar in value.unicodeScalars {
            if scalar.value == 0 { continue }
            if let limit = limit, kept >= limit { break }
            out.append(scalar)
            kept += 1
        }
        return String(out)
    }

    // MARK: Adların təhlili

    /// Adın sözləri (tracker: `normName`): `user[passWord]`, `auth-token`, `SMSCode` -> `user pass word`, `auth token`,
    /// `sms code`. Adın yalnız ilk 128 simvoluna (UTF-16 vahidi) baxılır; `%` varsa ad əvvəlcə açılır (açılmırsa olduğu
    /// kimi qalır). Söz yalnız `a-z` hərflərindən ibarətdir: rəqəm və başqa hər simvol ayırıcıdır; kiçik hərf və ya
    /// rəqəmdən sonrakı böyük hərf (camelCase) və böyük hərflər sırasının kiçik hərfdən əvvəlki sonuncu hərfi
    /// (`SMSCode`) yeni söz başlayır. JavaScript-in `toLowerCase()`-i ilə eyni nəticə üçün Kelvin işarəsi (U+212A) `k`,
    /// nöqtəli böyük İ (U+0130) `i` və ardınca ayırıcı sayılır.
    static func nameWords(_ name: String) -> [String] {
        return nameWords(units: Array(name.utf16), camel: true)
    }

    /// `camel` false olduqda böyük-kiçik hərf keçidi söz sərhədi sayılmır (tracker: `normName(name, true)`; `tOkEn` -> `token`).
    private static func nameWords(units name: [UInt16], camel: Bool) -> [String] {
        var u = name
        if u.count > 128 { u = Array(u[0..<128]) }
        if u.contains(cPercent), let decoded = decodeUnits(u) { u = decoded }
        u = u.map { fold($0) }
        var out: [String] = []
        var word: [UInt16] = []
        let n = u.count
        var i = 0
        while i < n {
            let c = u[i]
            var letter: UInt16 = 0
            var boundary = false
            if isUpper(c) {
                let previous: UInt16 = i > 0 ? u[i - 1] : cSpace
                boundary = camel && (isLower(previous) || isNumber(previous) || (isUpper(previous) && i + 1 < n && isLower(u[i + 1])))
                letter = lower(c)
            } else if isLower(c) {
                letter = c
            } else if c == 0x212a {
                letter = 107
            } else if c == 0x0130 {
                letter = 105
            } else {
                boundary = true
            }
            if boundary && !word.isEmpty {
                out.append(plainStems(word))
                word.removeAll()
            }
            if letter != 0 { word.append(letter) }
            // U+0130 kiçik hərfdə `i` + birləşən nöqtədir (U+0307): nöqtə ayırıcıdır.
            if c == 0x0130 {
                out.append(plainStems(word))
                word.removeAll()
            }
            i += 1
        }
        if !word.isEmpty { out.append(plainStems(word)) }
        return out
    }

    /// Sirr sözünə bənzəyən, amma sirr olmayan kökləri `x` ilə əvəz edir (tracker: PLAIN_STEM_RE, `sifrel|secretar`):
    /// «şifrələ…» (şifrələmə) və `secretar…` (secretary). Beləliklə `sifre` / `secret` hissələri bu sözlərdə tapılmır.
    /// `word`: yalnız `a-z` hərflərindən ibarət söz.
    private static func plainStems(_ word: [UInt16]) -> String {
        var out: [UInt16] = []
        out.reserveCapacity(word.count)
        var i = 0
        while i < word.count {
            if matchesAt(word, i, plainStemSifrel) {
                out.append(120)
                i += plainStemSifrel.count
            } else if matchesAt(word, i, plainStemSecretar) {
                out.append(120)
                i += plainStemSecretar.count
            } else {
                out.append(word[i])
                i += 1
            }
        }
        return string(out)
    }

    /// Azərbaycan / türk hərfini ASCII qarşılığına gətirir (tracker: FOLD) ki, `şifrə`, `nömrə`, `poçt` kimi adlar
    /// tanınsın: `ö ə ş ç ü ğ ı` və böyük qarşılıqları, `İ` -> `I`.
    private static func fold(_ c: UInt16) -> UInt16 {
        switch c {
        case 0x00f6: return 111
        case 0x00d6: return 79
        case 0x0259: return 101
        case 0x018f: return 69
        case 0x015f: return 115
        case 0x015e: return 83
        case 0x00e7: return 99
        case 0x00c7: return 67
        case 0x00fc: return 117
        case 0x00dc: return 85
        case 0x011f: return 103
        case 0x011e: return 71
        case 0x0131: return 105
        case 0x0130: return 73
        default: return c
        }
    }

    private static func containsAny(_ word: String, _ parts: [String]) -> Bool {
        for part in parts where word.contains(part) { return true }
        return false
    }

    private static func startsWithAny(_ word: String, _ prefixes: [String]) -> Bool {
        for prefix in prefixes where word.hasPrefix(prefix) { return true }
        return false
    }

    /// Ardıcıl iki söz sirr olmayan cütdürsə true (tracker: SAFE_NAME_RE): `promo code`, `endirim kodu`, `card type`.
    private static func safePair(_ first: String, _ second: String) -> Bool {
        if codeWords.contains(second) && safeCodeWords.contains(first) { return true }
        return describingWords.contains(second) && describedWords.contains(first)
    }

    /// Sözlərdən sirr olmayan cütləri çıxarır (tracker: `replace(SAFE_NAME_RE, ' ')`, bax `safePair`). Tracker-dəki ifadə
    /// ardıcıl uyğunluqlarda ortaq boşluğu bir dəfə işlədir, ona görə atılan cütdən dərhal sonrakı söz yeni cütün birinci
    /// sözü ola bilmir (`promo_code_country_code`-da `country code` qalır).
    private static func withoutSafePairs(_ words: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(words.count)
        var i = 0
        while i < words.count {
            if i + 1 < words.count && safePair(words[i], words[i + 1]) {
                i += 2
                if i < words.count {
                    out.append(words[i])
                    i += 1
                }
            } else {
                out.append(words[i])
                i += 1
            }
        }
        return out
    }

    /// Sözlərdən biri həssas query parametri adına uyğundursa true (tracker: `sensitiveName`). `safe`: `withoutSafePairs`
    /// nəticəsi; `short` (dəyər ən çoxu 2 simvol) olduqda `flagNameWords` sözləri nəzərə alınmır.
    private static func sensitiveWords(_ safe: [String], _ short: Bool) -> Bool {
        for word in safe {
            if short && flagNameWords.contains(word) { continue }
            if containsAny(word, paramParts) || startsWithAny(word, phonePrefixes) || paramWords.contains(word) { return true }
        }
        return false
    }

    /// Açarın sözləri e-poçt adına uyğundursa true (tracker: `mailWords`).
    private static func mailKeyWords(_ words: [String]) -> Bool {
        for word in words where containsAny(word, mailKeyParts) { return true }
        return false
    }

    /// Söz telefon adıdırsa true (tracker: `phoneWord`).
    private static func phoneKeyWord(_ word: String) -> Bool {
        return startsWithAny(word, phonePrefixes) || containsAny(word, phoneKeyParts) || phoneKeyWordList.contains(word)
    }

    /// Açarın sözləri telefon adına uyğundursa true (tracker: `phoneWords`).
    private static func phoneKeyWords(_ words: [String]) -> Bool {
        for word in words where phoneKeyWord(word) { return true }
        return false
    }

    /// Ad (böyük-kiçik hərfə baxılmadan) `sha256` ilə bitirsə true (tracker: `/sha256$/` kiçik hərfli ada tətbiq olunur).
    private static func endsWithSha256(_ name: String) -> Bool {
        let u = Array(name.utf16)
        let suffix: [UInt16] = [115, 104, 97, 50, 53, 54]
        if u.count < suffix.count { return false }
        var i = 0
        while i < suffix.count {
            if lower(u[u.count - suffix.count + i]) != suffix[i] { return false }
            i += 1
        }
        return true
    }

    /// 64 simvolluq hex mətn (tracker: HEX64_RE): `*_sha256` açarının yararlı dəyəri.
    private static func isHex64(_ text: String) -> Bool {
        let u = Array(text.utf16)
        if u.count != 64 { return false }
        for c in u where hexValue(c) < 0 { return false }
        return true
    }

    /// Dəyər telefon nömrəsi şəklindədirsə true (tracker: `phoneShaped`): 7–15 rəqəmli tam ədəd və ya yalnız rəqəm, boşluq və
    /// `+ - ( ) .` simvollarından ibarət, 7–15 rəqəmli mətn (`contactMax`-dan uzun mətn yox).
    private static func phoneShaped(_ value: Any?) -> Bool {
        guard let value = value else { return false }
        if let given = value as? String {
            if given.utf16.count > contactMax { return false }
            let v = Array(jsTrim(given).utf16)
            if v.count < 7 || v.count > 40 { return false }
            var digits = 0
            for c in v {
                if isNumber(c) {
                    digits += 1
                } else if c != cPlus && c != cDash && c != cOpen && c != cClose && c != cDot && !isSpace(c) {
                    return false
                }
            }
            return digits >= 7 && digits <= 15
        }
        if let number = value as? NSNumber {
            if isBool(number) { return false }
            let d = number.doubleValue
            return d == floor(d) && abs(d) >= 1000000 && abs(d) < 1e15
        }
        return false
    }

    /// `props` / `traits` açarı şəxsi məlumata və ya sirrə işarə edirsə true (tracker: `forbiddenKey`). Ad sözlərə ayrılır
    /// (bax `nameWords`); flag: dəyər `true` / `false` / null; small: flag və ya mütləq qiyməti `smallNumber`-dən kiçik ədəd:
    ///  - kiçik hərflə yazılmış ad dəqiq `forbiddenKeys` siyahısındadırsa həmişə atılır;
    ///  - `sha256` ilə bitən ad sonluqsuz yoxlanır (64 hex dəyərli `*_sha256` açarı bura çatmır, `clean`-də saxlanır);
    ///  - `authorization` / `authorisation` sözü: həmişə atılır;
    ///  - sirr hissəsi (`secretKeyParts`) olan söz, dəyər flag olmayanda: son sözdürsə və ya ardınca yalnız bir təsvir sözü
    ///    (`secretDetailWords`) gəlirsə həmişə, qalan halda dəyər small olmayanda atılır (`has_password: true`,
    ///    `is_secret: true`, `password_changed: true` qalır); «şifrələ…» və `secretar…` kökləri sirr hissəsi sayılmır (bax
    ///    `plainStems`);
    ///  - dəyər flag olmayanda: `signature` / `cardholder` / `creditcard` / `pinkod` hissəsi olan söz, `sig` / `nonce` sözü,
    ///    `license` + `key`, `cc` / `account` / `hesab` + nömrə sözü (`cc_number`, `account_number`, `hesab_nomresi`) atılır;
    ///  - `token` ilə bitən söz adın son sözüdürsə həmişə atılır (`token_count`, `tokens` qalır);
    ///  - `card` / `kart`: ardınca kart məlumatı sözü gəlirsə həmişə; son sözdürsə, dəyər flag deyilsə və əvvəlki söz
    ///    `safeCardWords`-də deyilsə atılır (`gift_card` qalır);
    ///  - `api` / `access` / `private` / `auth` + `key`, `session` + `id`: həmişə atılır;
    ///  - qısa çoxmənalı sözlər (`lastKeyWords`): son sözdürsə və ya ardınca yalnız bir təsvir sözü gəlirsə, dəyər flag
    ///    olmayanda atılır (`pin`, `user_otp`, `cookie_value`; `pin_color`, `otp_sent` qalır);
    ///  - `code` / `kod` / `kodu` son sözdürsə və əvvəlki söz `codeOwnerWords`-dədirsə, dəyər flag olmayanda atılır;
    ///  - e-poçt hissəsi olan söz: dəyər small olmayanda atılır (`email_verified: true`, `emails_sent: 5` qalır); dəyər əlaqə
    ///    məlumatı deyilsə (bax `contactLabel`: `email_template: "welcome"`, `mobile: "ios"`) e-poçt və telefon sözü açarı atmır;
    ///  - telefon sözü: dəyər small deyilsə və söz sonuncudursa, ardınca nömrə sözü gəlirsə və ya dəyər telefon
    ///    şəklindədirsə (bax `phoneShaped`) atılır (`phone_model: "iPhone15"` qalır).
    static func forbiddenKey(_ name: String, _ value: Any?) -> Bool {
        if forbiddenKeys.contains(name.lowercased()) { return true }
        var w = nameWords(name)
        var flag = true
        var small = true
        if let value = value, !(value is NSNull) {
            if let number = value as? NSNumber {
                if !isBool(number) {
                    flag = false
                    let d = number.doubleValue
                    small = d > -smallNumber && d < smallNumber
                }
            } else {
                flag = false
                small = false
            }
        }
        if endsWithSha256(name) && !w.isEmpty && w[w.count - 1] == "sha" { w.removeLast() }
        let n = w.count
        var i = 0
        while i < n {
            let word = w[i]
            let last = i == n - 1
            let detail = i == n - 2 && secretDetailWords.contains(w[i + 1])
            if secretKeyWordList.contains(word) { return true }
            if !flag && containsAny(word, secretKeyParts) && (last || detail || !small) { return true }
            if last && word.hasSuffix("token") { return true }
            if cardWords.contains(word) {
                if !last && cardDetailWords.contains(w[i + 1]) { return true }
                if last && !flag && !(i > 0 && safeCardWords.contains(w[i - 1])) { return true }
            }
            if i > 0 && word == "key" && keyOwnerWords.contains(w[i - 1]) { return true }
            if i > 0 && word == "id" && w[i - 1] == "session" { return true }
            if !flag && lastKeyWords.contains(word) && (last || detail) { return true }
            if last && !flag && i > 0 && codeWords.contains(word) && codeOwnerWords.contains(w[i - 1]) { return true }
            if !flag {
                if containsAny(word, flagKeyParts) || flagKeyWords.contains(word) { return true }
                if i > 0 && word == "key" && licenseWords.contains(w[i - 1]) { return true }
                if !last && numberOwnerWords.contains(word) && phoneDetailWords.contains(w[i + 1]) { return true }
            }
            let next = last ? "" : w[i + 1]
            if small || contactLabel(value, next) {
                i += 1
                continue
            }
            if containsAny(word, mailKeyParts) { return true }
            if phoneKeyWord(word) {
                if last { return true }
                if phoneDetailWords.contains(next) { return true }
                if phoneShaped(value) { return true }
            }
            i += 1
        }
        return false
    }

    /// E-poçt / telefon sözü olan açarın dəyəri əlaqə məlumatı deyilsə true (tracker: `contactLabel`): ən çoxu 32 simvolluq
    /// (UTF-16 vahidi) mətn, içində `@` (və ya tam enli `＠`) və 7+ rəqəmlik ardıcıllıq yoxdur, və ya açarda sözdən sonra
    /// ayar sözü gəlir (`next`: `contactDetailWords`; `email_template`, `mailing_list`), ya da dəyər `contactValues`
    /// siyahısındadır (`mobile: "ios"`, `is_mobile: "yes"`).
    private static func contactLabel(_ value: Any?, _ next: String) -> Bool {
        guard let value = value, let given = value as? String else { return false }
        let u = Array(given.utf16)
        if u.count > 32 { return false }
        var run = 0
        for c in u {
            if c == cAt || c == cWideAt { return false }
            if !isNumber(c) {
                run = 0
            } else {
                run += 1
                if run >= 7 { return false }
            }
        }
        if contactDetailWords.contains(next) { return true }
        let trimmed = trimUnits(u)
        return contactValues.contains(lowerAscii(trimmed, 0, trimmed.count))
    }

    /// Query (və ya matris) parametri silinməlidirsə true (tracker: `stripParam`). Sıra: konfiqin `strip_params`
    /// siyahısı (`extra`, kiçik hərflə); klik ID-ləri (yalnız reklam razılığı yoxdursa silinir); tanınan utm adları
    /// (`utmNames`, saxlanır); sonra adın sözləri həssas ad siyahıları ilə tutuşdurulur. Uyğunluq yoxdursa və istisna cütü
    /// də tapılmayıbsa ad böyük-kiçik hərf bölgüsü olmadan bir də yoxlanır (`PaSsWoRd`, `tOkEn`). Bu variantda parametrin
    /// dəyəri uzun sayılır (bayraq istisnası tətbiq olunmur).
    static func sensitiveParam(_ rawName: String, extra: Set<String> = [], ads: Bool = true) -> Bool {
        return sensitiveParam(units: Array(rawName.utf16), extra, ads, false)
    }

    /// `short`: parametrin xam dəyəri ən çoxu 2 simvoldur (tracker: `value.length <= 2`).
    private static func sensitiveParam(units rawName: [UInt16], _ extra: Set<String>, _ ads: Bool, _ short: Bool) -> Bool {
        let decoded = decodeUnits(rawName) ?? rawName
        let lowered = jsLower(string(decoded))
        // Android-dəki kimi UTF-16 vahidləri müqayisə olunur: `Set<String>.contains` kanonik ekvivalent yazılışları
        // (`é` və `e` + U+0301) eyni sayardı.
        if containsUnits(extra, lowered) { return true }
        if clickIds.contains(lowered) { return !ads }
        if utmNames.contains(lowered) { return false }
        let words = nameWords(units: decoded, camel: true)
        let safe = withoutSafePairs(words)
        if sensitiveWords(safe, short) { return true }
        if safe.count != words.count { return false }
        return sensitiveWords(withoutSafePairs(nameWords(units: decoded, camel: false)), short)
    }

    /// `set`-də UTF-16 vahidləri `text` ilə eyni olan element varsa true (kanonik ekvivalentlik nəzərə alınmır).
    private static func containsUnits(_ set: Set<String>, _ text: String) -> Bool {
        if set.isEmpty { return false }
        for item in set where item.utf16.elementsEqual(text.utf16) { return true }
        return false
    }

    // MARK: İstifadəçi məlumatının təmizlənməsi

    /// Atılan dəyər üçün işarə.
    private struct Drop {}

    /// Lüğət dəyəri mətn açarlı lüğət kimi; açarı mətn olmayan elementlər atılır, qalanı saxlanır (Android: `k as? String ?: continue`).
    /// Dəyər lüğət deyilsə nil.
    private static func stringKeyed(_ value: Any) -> [String: Any?]? {
        if let dict = value as? [String: Any?] { return dict }
        guard let mixed = value as? [AnyHashable: Any] else { return nil }
        var out: [String: Any?] = [:]
        for (key, item) in mixed {
            if let name = key.base as? String { out.updateValue(item, forKey: name) }
        }
        return out
    }

    /// Siyahı dəyəri massiv kimi; `Set` (və `NSSet`) elementlərinin massivinə çevrilir (Android: `Iterable`). Siyahı deyilsə nil.
    private static func listed(_ value: Any) -> [Any?]? {
        if let array = value as? [Any?] { return array }
        guard let set = value as? Set<AnyHashable> else { return nil }
        var out: [Any?] = []
        out.reserveCapacity(set.count)
        for item in set { out.append(item.base) }
        return out
    }

    /// İstifadəçi məlumatını JSON-a çevrilə bilən dəyərə gətirir. Qadağan olunmuş açarlar, dərinliyi aşan və
    /// JSON-a çevrilməyən dəyərlər atılır; mətn dəyərlərində e-poçta bənzər hissələr gizlədilir.
    private static func clean(_ value: Any?, depth: Int, log: (String) -> Void, extra: Set<String>, ads: Bool) -> Any {
        guard let value = value else { return NSNull() }
        if value is NSNull { return NSNull() }
        if let string = value as? String { return scrubText(text(string), extra, ads) }
        if let number = value as? NSNumber {
            if isBool(number) { return number.boolValue }
            return number.doubleValue.isFinite ? number : Drop()
        }
        if let date = value as? Date {
            // Sonsuz və ya həddən uzaq tarix Int64-ə çevrilə bilmir.
            let millis = date.timeIntervalSince1970 * 1000
            if millis.isFinite, abs(millis) < 8.64e15 { return iso(Int64(millis)) }
            return Drop()
        }
        if let dict = stringKeyed(value) {
            if depth <= 0 { return Drop() }
            var out: [String: Any] = [:]
            for (key, item) in dict {
                // Əvvəlcə NUL silinir, sonra açar yoxlanır (Android ilə eyni sıra).
                let name = text(key)
                // `__proto__` açarı JavaScript tərəfində prototipi dəyişərdi: veb tracker kimi atılır.
                if name == "__proto__" { continue }
                // `*_sha256` açarının 64 simvolluq hex dəyəri artıq hash-dir: olduğu kimi saxlanır.
                if endsWithSha256(name), let found = item, let hash = found as? String, isHex64(hash) {
                    out[name] = hash
                    continue
                }
                if forbiddenKey(name, item) {
                    log("dropped forbidden key: \(name)")
                    continue
                }
                let cleaned = clean(item, depth: depth - 1, log: log, extra: extra, ads: ads)
                if cleaned is Drop {
                    log("dropped unsupported value: \(name)")
                } else {
                    out[name] = cleaned
                }
            }
            return out
        }
        if let array = listed(value) {
            if depth <= 0 { return Drop() }
            var out: [Any] = []
            for item in array {
                let cleaned = clean(item, depth: depth - 1, log: log, extra: extra, ads: ads)
                if !(cleaned is Drop) { out.append(cleaned) }
            }
            return out
        }
        return Drop()
    }

    /// Lüğəti təmiz JSON obyektinə çevirir; boşdursa nil.
    static func cleanObject(_ dict: [String: Any?]?, log: (String) -> Void = { _ in }, extra: Set<String> = [], ads: Bool = true) -> [String: Any]? {
        guard let dict = dict else { return nil }
        guard let out = clean(dict, depth: 4, log: log, extra: extra, ads: ads) as? [String: Any], !out.isEmpty else { return nil }
        return out
    }

    /// `identify`-ın göndərilən `traits`-i (veb tracker və Android ilə eyni qayda): təmizlənmiş obyekt və
    /// `email_sha256` / `phone_sha256`; boşdursa nil. E-poçt və telefon cihazı yalnız hash şəklində tərk edir:
    /// - dəqiq `email` (mətn) və `phone` (mətn və ya ədəd) açarları üstündür: e-poçt boşluqları silinib kiçik hərfə
    ///   çevrilir, telefonun yalnız rəqəmləri götürülür; boş qalmayan dəyər hash olunur;
    /// - sonra oxşar adlı açarlar (`Email`, `user_email`, `phoneNumber`, `msisdn` …) yoxlanır, bax `hashTraits`.
    static func cleanTraits(_ traits: [String: Any?]?, log: (String) -> Void = { _ in }, extra: Set<String> = [], ads: Bool = true) -> [String: Any]? {
        guard let traits = traits else { return nil }
        var out = (clean(traits, depth: 4, log: log, extra: extra, ads: ads) as? [String: Any]) ?? [:]
        // `contactMax`-dan uzun mətn e-poçt / telefon namizədi deyil.
        if let found = traits["email"], let value = found, let given = value as? String, given.utf16.count <= contactMax {
            let email = normalizeEmail(text(given))
            if !email.isEmpty { out["email_sha256"] = sha256(email) }
        }
        if let found = traits["phone"], let value = found, let given = phoneText(value) {
            var candidate = true
            if let written = value as? String, written.utf16.count > contactMax { candidate = false }
            let phone = normalizePhone(given)
            if candidate && !phone.isEmpty { out["phone_sha256"] = sha256(phone) }
        }
        hashTraits(traits, &out, depth: 1)
        return out.isEmpty ? nil : out
    }

    /// `traits`-dəki e-poçt və telefon dəyərlərini hash edir (tracker: `hashTraits`). Açar adı sözə görə tanınır
    /// (bax `mailKeyWords`, `phoneKeyWords`); `sha256` ilə bitən açarlara baxılmır. Açarlar əlifba sırası ilə
    /// (UTF-16 vahidlərinə görə) gəzilir və ilk yararlı dəyər götürülür: e-poçt üçün e-poçta bənzəyən mətn, telefon
    /// üçün ən azı 7 rəqəm. `out`-da artıq olan hash dəyişdirilmir. `depth` səviyyə iç-içə obyektlər də yoxlanır.
    private static func hashTraits(_ traits: [String: Any?], _ out: inout [String: Any], depth: Int) {
        // UTF-16 vahidlərinə görə sıra: JavaScript-in `sort()`-u və Kotlin-in `String.compareTo`-su ilə eyni.
        let keys = traits.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
        for key in keys {
            guard let found = traits[key], let value = found else { continue }
            if endsWithSha256(key) { continue }
            if let given = phoneText(value) {
                let raw = text(given)
                if raw.utf16.count > contactMax { continue }
                let trimmed = jsTrim(raw)
                let words = nameWords(key)
                if mailKeyWords(words) {
                    if out["email_sha256"] == nil && isEmailShaped(trimmed) { out["email_sha256"] = sha256(jsLower(trimmed)) }
                } else if phoneKeyWords(words) {
                    let digits = normalizePhone(trimmed)
                    if out["phone_sha256"] == nil && digits.utf16.count >= 7 { out["phone_sha256"] = sha256(digits) }
                }
            } else if depth > 0, let nested = stringKeyed(value) {
                hashTraits(nested, &out, depth: depth - 1)
            }
        }
    }

    /// Çağırış anındakı surətin hədləri: bundan böyük quruluş kopyalanmır.
    static let maxSnapshotNodes = 2_000
    static let maxSnapshotChars = 100_000

    private final class Budget {
        var nodes: Int
        var chars: Int
        var exceeded = false

        init(nodes: Int, chars: Int) {
            self.nodes = nodes
            self.chars = chars
        }

        func take(_ length: Int) {
            nodes -= 1
            chars -= length
            if nodes < 0 || chars < 0 { exceeded = true }
        }
    }

    /// Çağırış anındakı dəyərlərin surəti. Çağıranın axınında qurulur: tətbiq eyni (dəyişən, məsələn
    /// `NSMutableDictionary` / `NSMutableArray`) quruluşu sonra dəyişsə də event çağırış anındakı dəyərlərlə gedir və
    /// SDK növbəsi başqa axında dəyişdirilən obyekti oxumur. Dərinlik həddi `cleanObject` ilə eynidir; element sayı
    /// və mətnlərin ümumi uzunluğu məhduddur: hədd aşılarsa `oversized` qaytarılır və event parametrsiz gedir.
    static func snapshot(_ dict: [String: Any]?) -> Snapshot {
        guard let dict = dict else { return Snapshot(value: nil, oversized: false) }
        let budget = Budget(nodes: maxSnapshotNodes, chars: maxSnapshotChars)
        let copied = copy(dict, depth: 4, budget: budget)
        if budget.exceeded { return Snapshot(value: nil, oversized: true) }
        return Snapshot(value: copied as? [String: Any?], oversized: false)
    }

    private static func copy(_ value: Any?, depth: Int, budget: Budget) -> Any? {
        if budget.exceeded { return nil }
        guard let value = value else {
            budget.take(0)
            return nil
        }
        if let string = value as? String {
            budget.take(string.utf16.count)
            // Yeni `String` dəyəri: `NSMutableString`-in sonrakı dəyişiklikləri surətə təsir etmir.
            return String(string)
        }
        budget.take(0)
        if budget.exceeded { return nil }
        if value is NSNull || value is NSNumber || value is Date { return value }
        if let dict = stringKeyed(value) {
            if depth <= 0 { return Drop() }
            var out: [String: Any?] = [:]
            for (key, item) in dict {
                budget.take(key.utf16.count)
                if budget.exceeded { break }
                let copied: Any? = copy(item, depth: depth - 1, budget: budget)
                out.updateValue(copied, forKey: String(key))
            }
            return out
        }
        if let array = listed(value) {
            if depth <= 0 { return Drop() }
            var out: [Any?] = []
            for item in array {
                if budget.exceeded { break }
                out.append(copy(item, depth: depth - 1, budget: budget))
            }
            return out
        }
        // JSON-a çevrilməyən obyekt: `clean` onu atacaq.
        return Drop()
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

    // MARK: Kontekst

    /// Sistem dil identifikatorunu sxemin həddinə gətirir: `_` -> `-`, `@…` və Unicode genişlənməsi (`-u-…`) atılır,
    /// ən çox 35 simvol.
    static func localeTag(_ identifier: String) -> String {
        let base = identifier.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? identifier
        var units = Array(base.replacingOccurrences(of: "_", with: "-").utf16)
        var index = 0
        while index + 2 < units.count {
            // `-u-` və ya `-U-`: Unicode genişlənməsinin başlanğıcı.
            if units[index] == cDash && (units[index + 1] == 117 || units[index + 1] == 85) && units[index + 2] == cDash {
                units = Array(units[0..<index])
                break
            }
            index += 1
        }
        var cut = text(string(units), limit: 35)
        while cut.hasSuffix("-") { cut.removeLast() }
        return cut
    }

    private static func clampText(_ object: inout [String: Any], _ name: String, _ limit: Int, locale: Bool = false) {
        guard let raw = object[name] else { return }
        var value = ""
        if let string = raw as? String { value = text(locale ? localeTag(string) : string, limit: limit) }
        if value.isEmpty {
            object[name] = nil
        } else {
            object[name] = value
        }
    }

    private static func clampObject(_ ctx: inout [String: Any], _ name: String, _ fields: [(String, Int)]) {
        guard let raw = ctx[name] else { return }
        guard var object = raw as? [String: Any] else {
            ctx[name] = nil
            return
        }
        for (field, limit) in fields { clampText(&object, field, limit) }
        ctx[name] = object
    }

    /// Cihaz kontekstini sxemin (spec/schema/batch.v1.schema.json) hədlərinə gətirir: uzun mətnlər kəsilir, yanlış
    /// tipli və boş sahələr atılır. Hədd aşan bir sahə bütün toplunun rədd olunmasına (və silinməsinə) səbəb olardı.
    static func clampContext(_ input: [String: Any]) -> [String: Any] {
        var ctx = input
        clampText(&ctx, "locale", 35, locale: true)
        clampText(&ctx, "tz", 64)
        clampText(&ctx, "ua", 1024)
        clampObject(&ctx, "app", [("id", 255), ("version", 64), ("build", 64)])
        if let app = ctx["app"] as? [String: Any], app["id"] == nil { ctx["app"] = nil }
        clampObject(&ctx, "os", [("name", 32), ("version", 32)])
        clampObject(&ctx, "device", [("manufacturer", 64), ("model", 64), ("type", 16)])
        if let raw = ctx["screen"] {
            if var screen = raw as? [String: Any] {
                for name in ["w", "h"] {
                    if let number = screen[name] as? NSNumber, !isBool(number), number.doubleValue.isFinite,
                       number.doubleValue >= 0, number.doubleValue <= 2_147_483_647 {
                        screen[name] = Int(number.doubleValue)
                    } else {
                        screen[name] = nil
                    }
                }
                if let number = screen["density"] as? NSNumber, !isBool(number), number.doubleValue.isFinite, number.doubleValue >= 0 {
                    screen["density"] = number
                } else {
                    screen["density"] = nil
                }
                ctx["screen"] = screen
            } else {
                ctx["screen"] = nil
            }
        }
        if let raw = ctx["ids"] {
            var ids = raw as? [String: Any] ?? [:]
            for name in Array(ids.keys) { clampText(&ids, name, 256) }
            if ids.isEmpty {
                ctx["ids"] = nil
            } else {
                ctx["ids"] = ids
            }
        }
        return ctx
    }

    // MARK: Ünvanlar

    private static func hexValue(_ c: UInt16) -> Int {
        if c >= 48 && c <= 57 { return Int(c) - 48 }
        if c >= 97 && c <= 102 { return Int(c) - 97 + 10 }
        if c >= 65 && c <= 70 { return Int(c) - 65 + 10 }
        return -1
    }

    /// `u[at]`-dəki `%XX` ardıcıllığının baytı; ardıcıllıq yararsızdırsa -1.
    private static func percentByte(_ u: [UInt16], _ at: Int) -> Int {
        if at + 2 >= u.count || u[at] != cPercent { return -1 }
        let hi = hexValue(u[at + 1])
        let lo = hexValue(u[at + 2])
        return (hi < 0 || lo < 0) ? -1 : hi * 16 + lo
    }

    /// JavaScript-in `decodeURIComponent` funksiyası ilə eyni nəticə (UTF-16 vahidləri üzərində): faiz kodlamasını
    /// açır (`+` olduğu kimi qalır). Yararsız `%` ardıcıllığı və ya yararsız UTF-8 (yarımçıq, artıq uzun yazılış,
    /// surroqat, U+10FFFF-dən böyük) olduqda nil qaytarır (JavaScript-də istisna): çağıran mətni olduğu kimi
    /// saxlayır və ya parametri ötürür.
    private static func decodeUnits(_ u: [UInt16]) -> [UInt16]? {
        if !u.contains(cPercent) { return u }
        var out: [UInt16] = []
        out.reserveCapacity(u.count)
        let n = u.count
        var i = 0
        while i < n {
            let c = u[i]
            if c != cPercent {
                out.append(c)
                i += 1
                continue
            }
            let first = percentByte(u, i)
            if first < 0 { return nil }
            i += 3
            if first < 0x80 {
                out.append(UInt16(first))
                continue
            }
            // Çoxbaytlı UTF-8: davam baytlarının sayı və ən kiçik yararlı kod nöqtəsi.
            var extra = 0
            var min = 0
            if first >= 0xc2 && first <= 0xdf {
                extra = 1
                min = 0x80
            } else if first >= 0xe0 && first <= 0xef {
                extra = 2
                min = 0x800
            } else if first >= 0xf0 && first <= 0xf4 {
                extra = 3
                min = 0x10000
            } else {
                return nil
            }
            var point = first & (0x3f >> extra)
            var k = 0
            while k < extra {
                let next = percentByte(u, i)
                if next < 0 || (next & 0xc0) != 0x80 { return nil }
                point = (point << 6) | (next & 0x3f)
                i += 3
                k += 1
            }
            if point < min || point > 0x10ffff || (point >= 0xd800 && point <= 0xdfff) { return nil }
            if point >= 0x10000 {
                let offset = point - 0x10000
                out.append(UInt16(0xd800 + (offset >> 10)))
                out.append(UInt16(0xdc00 + (offset & 0x3ff)))
            } else {
                out.append(UInt16(point))
            }
        }
        return out
    }

    /// `decodeUnits`-in mətn variantı (Android-dəki `decodeURIComponent`).
    static func decodeURIComponent(_ text: String) -> String? {
        guard let decoded = decodeUnits(Array(text.utf16)) else { return nil }
        return string(decoded)
    }

    /// JavaScript-in `encodeURIComponent` funksiyası ilə eyni nəticə: `A-Z a-z 0-9 - _ . ! ~ * ' ( )` simvollarından
    /// başqa hər UTF-8 baytı faizlə kodlanır (Android ilə eyni nəticə).
    static func encode(_ text: String) -> String {
        let digits: [UInt8] = Array("0123456789ABCDEF".utf8)
        var out: [UInt8] = []
        for byte in text.utf8 {
            let c = UInt16(byte)
            if isAlnum(c) || c == cDash || c == cUnderscore || c == cDot || c == cExclamation || c == cTilde || c == cAsterisk
                || c == cApostrophe || c == cOpen || c == cClose {
                out.append(byte)
            } else {
                out.append(37)
                out.append(digits[Int(byte >> 4)])
                out.append(digits[Int(byte & 15)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// JavaScript-in `\s` sinfi (veb tracker ilə eyni ayırıcılar).
    private static func isSpace(_ c: UInt16) -> Bool {
        switch c {
        case 9, 10, 11, 12, 13, 32, 0x00a0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff:
            return true
        default:
            return c >= 0x2000 && c <= 0x200a
        }
    }

    private static func isSegmentEnd(_ c: UInt16) -> Bool {
        return c == cSlash || c == cQuestion || c == cAmp || c == cEquals || c == cHash || isSpace(c)
    }

    /// `u[from..<to]` hissəsinin yalnız ASCII böyük hərfləri kiçildilmiş mətni (tracker: `lowerAscii`).
    private static func lowerAscii(_ u: [UInt16], _ from: Int, _ to: Int) -> String {
        var out: [UInt16] = []
        var i = from
        while i < to {
            out.append(lower(u[i]))
            i += 1
        }
        return string(out)
    }

    /// `u[from..<end]` şəkil adının sonluğudursa true (tracker: ASSET_TAIL_RE, `^[0-9]+(\.[0-9]+)?x\.([A-Za-z0-9]+)$` və
    /// uzantı `staticExt` siyahısındadır): `@2x.png`, `@1.5x.jpg` sonluqlu şəkil adları.
    private static func assetTail(_ u: [UInt16], _ from: Int, _ end: Int) -> Bool {
        var i = from
        while i < end && isNumber(u[i]) { i += 1 }
        if i == from { return false }
        if i + 1 < end && u[i] == cDot && isNumber(u[i + 1]) {
            i += 1
            while i < end && isNumber(u[i]) { i += 1 }
        }
        // `x.`
        if i + 1 >= end || u[i] != 120 || u[i + 1] != cDot { return false }
        i += 2
        if i >= end { return false }
        var k = i
        while k < end {
            if !isAlnum(u[k]) { return false }
            k += 1
        }
        return staticExt.contains(lowerAscii(u, i, end))
    }

    /// `@`-dən sonrakı hissə (`u[from..<end]`) e-poçt domeninə oxşayırsa true (tracker: `emailTail`): `.\.[A-Za-z]{2}`
    /// uyğun gəlir və hissə şəkil adının sonluğu deyil (bax `assetTail`).
    private static func emailTail(_ u: [UInt16], _ from: Int, _ end: Int) -> Bool {
        var i = from + 1
        var found = false
        while i + 2 < end {
            if u[i] == cDot, isLower(u[i + 1]) || isUpper(u[i + 1]), isLower(u[i + 2]) || isUpper(u[i + 2]) {
                found = true
                break
            }
            i += 1
        }
        return found && !assetTail(u, from, end)
    }

    /// E-poçta bənzər hissələri `[redacted]` ilə əvəz edir (veb tracker ilə eyni qayda). Mətn ayırıcılara
    /// (`/ ? & = #` və boşluqlar) görə hissələrə bölünür və hər simvola sabit sayda baxılır: istənilən girişdə
    /// xətti vaxtda işləyir (regex işlədilmir).
    static func redactEmails(_ text: String) -> String {
        let u = Array(text.utf16)
        let out = redactEmailUnits(u)
        return out == u ? text : string(out)
    }

    private static func redactEmailUnits(_ u: [UInt16]) -> [UInt16] {
        let n = u.count
        var found = false
        var k = 0
        while k < n {
            if u[k] == cAt || u[k] == cWideAt || (u[k] == cPercent && k + 2 < n && u[k + 1] == 52 && u[k + 2] == 48) {
                found = true
                break
            }
            k += 1
        }
        if !found { return u }
        var out: [UInt16] = []
        out.reserveCapacity(n)
        var i = 0
        while i < n {
            if isSegmentEnd(u[i]) {
                out.append(u[i])
                i += 1
                continue
            }
            var end = i
            // `@` (və ya tam enli `＠`) və ya `%40` hissənin birinci simvolundan sonra axtarılır.
            var mark = -1
            var skip = 0
            while end < n && !isSegmentEnd(u[end]) {
                if mark < 0 && end > i {
                    if u[end] == cAt || u[end] == cWideAt {
                        mark = end
                        skip = 1
                    } else if u[end] == cPercent && end + 2 < n && u[end + 1] == 52 && u[end + 2] == 48 {
                        mark = end
                        skip = 3
                    }
                }
                end += 1
            }
            if mark >= 0 && emailTail(u, mark + skip, end) {
                out.append(contentsOf: redactedUnits)
            } else {
                out.append(contentsOf: u[i..<end])
            }
            i = end
        }
        return out
    }

    private static func isBase64Url(_ c: UInt16) -> Bool {
        return isAlnum(c) || c == cDash || c == cUnderscore
    }

    /// JWT (tracker: JWT_RE, `^eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(\.[A-Za-z0-9_-]*)?$`): `eyJ` ilə başlayan, hər biri
    /// ən azı 8 simvolluq iki base64url hissə və istəyə görə üçüncü hissə.
    private static func isJwt(_ u: [UInt16]) -> Bool {
        let n = u.count
        if n < 20 || u[0] != 101 || u[1] != 121 || u[2] != 74 { return false }
        var i = 3
        var run = 0
        while i < n && isBase64Url(u[i]) {
            i += 1
            run += 1
        }
        if run < 8 || i >= n || u[i] != cDot { return false }
        i += 1
        run = 0
        while i < n && isBase64Url(u[i]) {
            i += 1
            run += 1
        }
        if run < 8 { return false }
        if i == n { return true }
        if u[i] != cDot { return false }
        i += 1
        while i < n && isBase64Url(u[i]) { i += 1 }
        return i == n
    }

    /// `u` mətni `prefix` ilə (böyük-kiçik hərf dəqiq) başlayırsa true.
    private static func startsExactly(_ u: [UInt16], _ prefix: [UInt16]) -> Bool {
        if u.count < prefix.count { return false }
        var j = 0
        while j < prefix.count {
            if u[j] != prefix[j] { return false }
            j += 1
        }
        return true
    }

    /// Tanınan API açarı önü və ardınca ən azı 10 base64url simvolu (tracker: KEY_PREFIX_RE; `sk_live_…`).
    private static func keyPrefix(_ u: [UInt16]) -> Bool {
        for prefix in keyPrefixes {
            if !startsExactly(u, prefix) || u.count - prefix.count < 10 { continue }
            var ok = true
            var i = prefix.count
            while i < u.count {
                if !isBase64Url(u[i]) { ok = false }
                i += 1
            }
            if ok { return true }
        }
        return false
    }

    /// Luhn yoxlaması (kart nömrəsi); mətn yalnız rəqəmlərdən ibarət olmalıdır.
    private static func luhn(_ digits: [UInt16]) -> Bool {
        var sum = 0
        var alt = false
        var i = digits.count - 1
        while i >= 0 {
            var d = Int(digits[i]) - 48
            if alt {
                d *= 2
                if d > 9 { d -= 9 }
            }
            sum += d
            alt = !alt
            i -= 1
        }
        return sum % 10 == 0
    }

    /// Kart nömrəsi (tracker: `cardNumber`, `^[0-9]([ -]?[0-9]){14,18}$`): 15–19 rəqəm, rəqəmlər arasında tək boşluq və ya
    /// tire ola bilər, Luhn yoxlamasından keçir.
    private static func cardNumber(_ s: [UInt16]) -> Bool {
        let n = s.count
        if n < 15 || n > 40 || !isNumber(s[0]) || !isNumber(s[n - 1]) { return false }
        var digits: [UInt16] = []
        var separator = false
        var i = 0
        while i < n {
            let c = s[i]
            if isNumber(c) {
                digits.append(c)
                separator = false
            } else if (c == cSpace || c == cDash) && !separator {
                separator = true
            } else {
                return false
            }
            i += 1
        }
        return digits.count >= 15 && digits.count <= 19 && luhn(digits)
    }

    /// Adi identifikator (tracker: `plainId`): cuid (`c` + 24 kiçik hərf / rəqəm) və ULID (26 simvol, birincisi `0-7`,
    /// qalanı Crockford base32: `0-9 A-H J K M N P-T V-Z`).
    private static func plainId(_ s: [UInt16], _ from: Int, _ to: Int) -> Bool {
        let length = to - from
        if length == 25 && s[from] == 99 {
            var i = from
            while i < to {
                if !(isLower(s[i]) || isNumber(s[i])) { return false }
                i += 1
            }
            return true
        }
        if length == 26 && s[from] >= 48 && s[from] <= 55 {
            var i = from
            while i < to {
                let c = s[i]
                // `I` `L` `O` `U` Crockford əlifbasında yoxdur.
                if !(isNumber(c) || (isUpper(c) && c != 73 && c != 76 && c != 79 && c != 85)) { return false }
                i += 1
            }
            return true
        }
        return false
    }

    /// 24 və daha çox simvolluq hərf-rəqəm ardıcıllığı, içində rəqəm və hex olmayan hərf (tracker: `longRun`). Təmiz hex
    /// ID-lər (məsələn 24 simvolluq ObjectId) adi identifikatordur; 32+ hex ayrıca qayda ilə tutulur. `hinted` deyilsə
    /// cuid və ULID də adi identifikator sayılır (bax `plainId`).
    private static func longRun(_ s: [UInt16], _ hinted: Bool) -> Bool {
        var run = 0
        var digit = false
        var other = false
        var i = 0
        while i <= s.count {
            let c: UInt16 = i < s.count ? s[i] : cSlash
            if isAlnum(c) {
                run += 1
                if isNumber(c) {
                    digit = true
                } else if hexValue(c) < 0 {
                    other = true
                }
            } else {
                if run >= 24 && digit && other && (hinted || !plainId(s, i - run, i)) { return true }
                run = 0
                digit = false
                other = false
            }
            i += 1
        }
        return false
    }

    /// `s[from..<to]` adi sözdürsə true (tracker: WORD_RE, `^([a-z]{4,15}|[A-Z]{4,15}|[A-Z][a-z]{3,14})$`): 4–15 hərf, hamısı
    /// kiçik, hamısı böyük və ya yalnız birincisi böyük.
    private static func ordinaryWord(_ s: [UInt16], _ from: Int, _ to: Int) -> Bool {
        let length = to - from
        if length < 4 || length > 15 { return false }
        var lowers = 0
        var uppers = 0
        var i = from
        while i < to {
            let c = s[i]
            if isLower(c) {
                lowers += 1
            } else if isUpper(c) {
                uppers += 1
            } else {
                return false
            }
            i += 1
        }
        return uppers == 0 || lowers == 0 || (uppers == 1 && isUpper(s[from]))
    }

    /// Qısa identifikator (tracker: SHORT_ID_RE və `[A-Z0-9]`): 1–16 simvol `A-Z a-z 0-9 _ -`, böyük hərf və ya rəqəm var.
    private static func shortId(_ s: [UInt16]) -> Bool {
        if s.isEmpty || s.count > 16 { return false }
        var marked = false
        for c in s {
            if !isBase64Url(c) { return false }
            if isUpper(c) || isNumber(c) { marked = true }
        }
        return marked
    }

    /// Statik fayl adı (tracker: `staticFile`): son nöqtədən sonrakı uzantı `staticExt` siyahısındadır.
    private static func staticFile(_ s: [UInt16]) -> Bool {
        guard let dot = s.lastIndex(of: cDot), dot > 0 else { return false }
        return staticExt.contains(lowerAscii(s, dot + 1, s.count))
    }

    /// `^[A-Za-z][a-z]{2,}([A-Z][a-z]{2,})*$`: hər parçası 3+ hərfli camelCase söz (`forgotPassword`).
    private static func camelWord(_ s: [UInt16], _ from: Int, _ to: Int) -> Bool {
        var i = from
        if i >= to || !(isLower(s[i]) || isUpper(s[i])) { return false }
        while true {
            i += 1
            var lowers = 0
            while i < to && isLower(s[i]) {
                i += 1
                lowers += 1
            }
            if lowers < 2 { return false }
            if i == to { return true }
            if !isUpper(s[i]) { return false }
        }
    }

    /// `^([A-Za-z][a-z]{2,}[0-9]{1,2}|v[0-9]{1,3}|2[fF][aA])$`: 3+ hərfli söz və ardınca 1–2 rəqəm (`step2`, `oauth2`,
    /// `iphone15`), versiya (`v2`, `v10`) və ya `2fa`.
    private static func wordWithNumber(_ s: [UInt16], _ from: Int, _ to: Int) -> Bool {
        var i = from
        if i >= to { return false }
        // `2fa` (böyük-kiçik hərfə baxılmadan) ipucu sözüdür, token deyil.
        if isTwoFa(s, from, to) { return true }
        // `v`
        if s[i] == 118 {
            let count = to - i - 1
            var version = count >= 1 && count <= 3
            var k = i + 1
            while k < to {
                if !isNumber(s[k]) { version = false }
                k += 1
            }
            if version { return true }
        }
        if !(isLower(s[i]) || isUpper(s[i])) { return false }
        i += 1
        var lowers = 0
        while i < to && isLower(s[i]) {
            i += 1
            lowers += 1
        }
        let digits = to - i
        if lowers < 2 || digits < 1 || digits > 2 { return false }
        while i < to {
            if !isNumber(s[i]) { return false }
            i += 1
        }
        return true
    }

    /// İpucu altındakı hissənin `- _ . ~ :` ilə ayrılmış parçası (`s[from..<to]`) tokenə bənzəyirsə true (tracker: `tokenPart`):
    ///  - rəqəmi olmayan parça: böyük hərfi birincidən sonra gəlirsə (`aKdmQz`), amma tam BÖYÜK söz və hər parçası 3+ hərfli
    ///    camelCase söz (`forgotPassword`) istisnadır; `hint` 3-də (ipucu sözünün öz hissəsi) belə parça sayılmır;
    ///  - yalnız rəqəm: 6+ rəqəm və `hint` 1 (ipucu birbaşa əvvəlki hissədədir) və ya 3-dür;
    ///  - hərf və rəqəm qarışıq: 3+ hərfli söz + 1–2 rəqəm (`step2`, `oauth2`) və versiya (`v2`) istisna olmaqla həmişə.
    private static func tokenPart(_ s: [UInt16], _ from: Int, _ to: Int, _ hint: Int) -> Bool {
        let length = to - from
        var digits = 0
        var innerUpper = false
        var allUpper = length > 0
        var i = from
        while i < to {
            let c = s[i]
            if isNumber(c) { digits += 1 }
            if isUpper(c) {
                if i > from { innerUpper = true }
            } else {
                allUpper = false
            }
            i += 1
        }
        if digits == 0 {
            if hint == 3 || !innerUpper || allUpper { return false }
            return !camelWord(s, from, to)
        }
        if digits == length { return length >= 6 && hint != 2 }
        return !wordWithNumber(s, from, to)
    }

    /// Yol hissəsi (və ya query parametrinin dəyəri) sirrə bənzəyirsə true (tracker: `secretSegment`). `hint`: 0 — ipucu
    /// yoxdur; 1 — sirr sözü birbaşa əvvəlki hissədədir (və ya query yolun sirr sözü ilə bitən hissəsindən sonra gəlir);
    /// 2 — sirr sözü iki hissə əvvəldədir; 3 — hissənin özü sirr sözüdür (`confirm-<token>`). `path`: yol hissəsidir
    /// (query / `props` dəyəri yox). Qaydalar ehtiyatlıdır ki, adi ünvanlar (slug, UUID, məhsul nömrəsi) pozulmasın;
    /// 6 simvoldan qısa hissə heç vaxt tutulmur:
    ///  1) JWT (bax `isJwt`) və tanınan API açarı önü (bax `keyPrefix`);
    ///  2) `+` ilə başlayan telefon nömrəsi (`^\+[0-9][0-9 ().-]{7,18}$`, 9–15 rəqəm);
    ///  3) yalnız rəqəm: 20 və daha çox rəqəm; Luhn yoxlamasından keçən 15–19 rəqəm (kart nömrəsi) — yolda yalnız ipucu
    ///     olduqda və ya ilk rəqəm 3–6 olduqda (kart şəbəkələrinin önləri; `2026…` ilə başlayan sifariş nömrəsi qalır),
    ///     query dəyərində həmişə; `hint` 1 olduqda 6+ rəqəm. 10–14 rəqəmlik çılpaq ədəd (sifariş nömrəsi, barkod, vaxt
    ///     möhürü, `+` işarəsiz telefon) ipucu olmadan tutulmur;
    ///  4) rəqəmləri boşluq və ya tire ilə ayrılmış kart nömrəsi (bax `cardNumber`);
    ///  5) hissənin içində 32 və daha çox simvolluq hex ardıcıllığı (MD5 / SHA / təsadüfi token; bax `hexRun`: `v1:<hex>`,
    ///     `reset-<hex>`, `<hex>.json`), hissə statik fayl adı (bax `staticFile`: `<md5>.jpg`) deyilsə; tiresiz yazılmış UUID
    ///     (düz 32 hex, versiya və variant yerində) ipucu olmayanda istisnadır, çünki tireli UUID kimi adi identifikatordur;
    ///  6) 32 və daha çox simvolluq base64url (sonda ən çoxu iki `=`): kiçik hərf, böyük hərf və rəqəm birlikdə, ayırıcı
    ///     (`-` `_`) uzunluğun 1/8-dən az;
    ///  7) 24+ simvolluq hərf-rəqəm ardıcıllığı, içində rəqəm və hex olmayan hərf (bax `longRun`; cuid və ULID ipucu
    ///     olmayanda istisnadır);
    ///  8) ipucu varsa: hissə yalnız `A-Z a-z 0-9 _ . ~ + = : -` simvollarındandır, statik fayl adı deyil (bax
    ///     `staticFile`) və `- _ . ~ :` ilə ayrılmış parçalarından biri tokenə bənzəyir (bax `tokenPart`), ya da (`hint`
    ///     1, 2) uzunluq 16+ simvoldur və parçalardan heç biri adi söz deyil (bax `ordinaryWord`).
    static func secretSegment(_ text: String, hint: Int, path: Bool) -> Bool {
        return secretSegment(units: Array(text.utf16), hint, path)
    }

    private static func secretSegment(units s: [UInt16], _ hint: Int, _ path: Bool) -> Bool {
        let n = s.count
        if n < 6 { return false }
        if isJwt(s) || keyPrefix(s) { return true }
        var digits = 0
        var separators = 0
        var allDigits = true
        var upper = false
        var lowerCase = false
        var phone = n >= 9 && n <= 20 && s[0] == cPlus && isNumber(s[1])
        var hintable = true
        var i = 0
        while i < n {
            let c = s[i]
            if isNumber(c) { digits += 1 } else { allDigits = false }
            if isUpper(c) { upper = true }
            if isLower(c) { lowerCase = true }
            if c == cDash || c == cUnderscore { separators += 1 }
            if i > 1 && !(isNumber(c) || c == cSpace || c == cOpen || c == cClose || c == cDot || c == cDash) { phone = false }
            if !(isAlnum(c) || c == cUnderscore || c == cDot || c == cTilde || c == cPlus || c == cEquals || c == cColon || c == cDash) {
                hintable = false
            }
            i += 1
        }
        if phone && digits >= 9 && digits <= 15 { return true }
        if allDigits {
            // İlk rəqəm 3–6: kart şəbəkələrinin önləri.
            let cardLike = hint > 0 || !path || (s[0] >= 51 && s[0] <= 54)
            return n >= 20 || (n >= 15 && cardLike && luhn(s)) || hint == 1
        }
        if cardNumber(s) { return true }
        if n >= 32 && hexRun(s, hint) && !staticFile(s) { return true }
        if n >= 32 && digits > 0 && lowerCase && upper && separators * 8 < n {
            // `^[A-Za-z0-9_-]+={0,2}$`
            var end = n
            if s[end - 1] == cEquals { end -= 1 }
            if s[end - 1] == cEquals { end -= 1 }
            var base64 = true
            var j = 0
            while j < end {
                if !isBase64Url(s[j]) { base64 = false }
                j += 1
            }
            if base64 { return true }
        }
        if longRun(s, hint > 0) { return true }
        if hint == 0 || !hintable || staticFile(s) { return false }
        var word = false
        var start = 0
        i = 0
        while i <= n {
            let c: UInt16 = i < n ? s[i] : cDash
            if c == cDash || c == cUnderscore || c == cDot || c == cTilde || c == cColon {
                if tokenPart(s, start, i, hint) { return true }
                if ordinaryWord(s, start, i) { word = true }
                start = i + 1
            }
            i += 1
        }
        return hint != 3 && n >= 16 && !word
    }

    /// `s`-də 32 və daha çox simvolluq hex ardıcıllığı (`0-9 a-f A-F`) varsa true (tracker: `hexRun`). Düz 32 simvolluq
    /// ardıcıllıq tiresiz UUID şəklindədirsə (13-cü simvol 1–8 — versiya, 17-ci simvol 8 / 9 / a / b — variant) ipucu
    /// olmayanda sayılmır.
    private static func hexRun(_ s: [UInt16], _ hint: Int) -> Bool {
        let n = s.count
        var i = 0
        while i < n {
            let k = i
            while i < n && hexValue(s[i]) >= 0 { i += 1 }
            if i - k >= 32 {
                let version = s[k + 12]
                let variant = lower(s[k + 16])
                let shaped = version >= 49 && version <= 56 && (variant == 56 || variant == 57 || variant == 97 || variant == 98)
                let uuid = i - k == 32 && shaped
                if hint > 0 || !uuid { return true }
            }
            i += 1
        }
        return false
    }

    /// Yol hissəsinin ipucu növü (tracker: `pathHint`): 2 — sirr sözü (təsdiq kökü başqa sözlə birlikdə də:
    /// `confirm-email`); 1 — telefon sözü (birinci və ya sonuncu söz `phoneHintWords`-dədir); 0 — ipucu yoxdur. Hissə
    /// (açılmış; Azərbaycan hərfləri ASCII-yə gətirilir) hərf-rəqəm olmayan simvollara görə parçalanır; rəqəmi olan parça
    /// nəzərə alınmır, qalanları camelCase sözlərinə ayrılır. Söz sayı 1–3 olmalıdır (uzun slug ipucu deyil:
    /// `how-to-reset-your-password`). Sirr sözü: birinci və ya sonuncu söz `hintStems` kökü ilə başlayır və ya
    /// `hintWords`-dədir, ya da ilk / son iki söz birlikdə `signin` / `login`-dir. `2fa` parçası rəqəminə baxmayaraq söz
    /// sayılır. İpucu yalnız təsdiq kökündəndirsə (`softStems`): 3 — hissə təkcə təsdiq sözüdür (`confirm`; sifariş
    /// kontekstini qonşu hissələrə görə `cleanPath` təyin edir); 4 — hissə təkcə `confirmation` sözüdür və ya içində
    /// `orderWords` sözü var (`order-confirmation`); 5 — içində `payWords` sözü var (`payment-confirmation`).
    private static func pathHint(_ segment: [UInt16]) -> Int {
        let u = segment.map { fold($0) }
        var words: [String] = []
        var start = 0
        var i = 0
        while i <= u.count {
            if i < u.count && isAlnum(u[i]) {
                i += 1
                continue
            }
            if i > start {
                var digit = false
                var k = start
                while k < i {
                    if isNumber(u[k]) { digit = true }
                    k += 1
                }
                if !digit {
                    words.append(contentsOf: nameWords(units: Array(u[start..<i]), camel: true))
                } else if isTwoFa(u, start, i) {
                    words.append("2fa")
                }
            }
            start = i + 1
            i += 1
        }
        let n = words.count
        if n < 1 || n > 3 { return 0 }
        let a = hintWord(words[0])
        let b = hintWord(words[n - 1])
        if a == 2 || b == 2 { return 2 }
        if n > 1 && (hintPairs.contains(words[0] + words[1]) || hintPairs.contains(words[n - 2] + words[n - 1])) { return 2 }
        if a == 1 || b == 1 {
            for word in words where orderWords.contains(word) { return payWords.contains(word) ? 5 : 4 }
            if n > 1 { return 2 }
            return words[0] == confirmationWord ? 4 : 3
        }
        return (phoneHintWords.contains(words[0]) || phoneHintWords.contains(words[n - 1])) ? 1 : 0
    }

    /// 2 — söz sirr sözüdür (`hintWords` və ya `hintStems` kökü); 1 — yalnız təsdiq kökü (`softStems`) ilə başlayır; 0 — ipucu deyil.
    private static func hintWord(_ word: String) -> Int {
        if hintWords.contains(word) { return 2 }
        for stem in hintStems where word.hasPrefix(stem) { return softStems.contains(stem) ? 1 : 2 }
        return 0
    }

    /// `s[from, to)` `2fa` sözüdürsə (böyük-kiçik hərfə baxılmadan) true.
    private static func isTwoFa(_ s: [UInt16], _ from: Int, _ to: Int) -> Bool {
        return to - from == 3 && s[from] == 50 && lower(s[from + 1]) == 102 && lower(s[from + 2]) == 97
    }

    /// Yol hissəsi (açılmış) bütövlükdə sifariş sözüdürsə (`orderWords`; böyük-kiçik hərfə baxılmadan) 1, ödəniş sözüdürsə
    /// (`payWords`) 2, qalan halda 0 (tracker: `orderSegment`).
    private static func orderSegment(_ plain: [UInt16]) -> Int {
        if plain.isEmpty || plain.count > 16 { return 0 }
        let folded = plain.map { fold($0) }
        let word = lowerAscii(folded, 0, folded.count)
        if payWords.contains(word) { return 2 }
        return orderWords.contains(word) ? 1 : 0
    }

    /// `^[0-9]{6,8}$`: ödəniş kontekstində təsdiq kodu uzunluğunda ədəd (tracker: PAY_CODE_RE).
    private static func payCode(_ s: [UInt16]) -> Bool {
        if s.count < 6 || s.count > 8 { return false }
        for c in s where !isNumber(c) { return false }
        return true
    }

    /// Yol hissəsinin `/` (`%2F`) və `=` ilə ayrılmış parçalarından biri sirrə bənzəyirsə true (tracker: `secretPiece`;
    /// `/x/t=<kart>`, `/reset%2F<açar>`).
    private static func secretPiece(_ plain: [UInt16], _ hint: Int) -> Bool {
        if !plain.contains(cEquals) && !plain.contains(cSlash) { return false }
        var start = 0
        var i = 0
        while i <= plain.count {
            if i < plain.count && plain[i] != cSlash && plain[i] != cEquals {
                i += 1
                continue
            }
            if secretSegment(units: Array(plain[start..<i]), hint, true) { return true }
            start = i + 1
            i += 1
        }
        return false
    }

    /// Sifariş / bron nömrəsinə bənzəyən yol hissəsi (tracker: `refShaped`): yalnız `A-Z 0-9 -` simvolları, ən azı bir rəqəm.
    private static func refShaped(_ s: [UInt16]) -> Bool {
        var digit = false
        for c in s {
            if isNumber(c) {
                digit = true
            } else if !isUpper(c) && c != cDash {
                return false
            }
        }
        return digit
    }

    /// `=` işarələrindən ibarət mətn (boş mətn də).
    private static func onlyEquals(_ s: [UInt16]) -> Bool {
        for c in s where c != cEquals { return false }
        return true
    }

    /// Adın bütün sözləri `orderParamWords` siyahısındadırsa true (tracker: `orderParam`; `order`, `order_id`, `orderId`,
    /// `id`). `strict`: sözlərdən biri `orderNameWords` siyahısında da olmalıdır (`order_id`; təkcə `id` və ya `ref` yox).
    private static func orderParam(_ rawName: [UInt16], _ strict: Bool) -> Bool {
        let words = nameWords(units: rawName, camel: true)
        var named = !strict
        for word in words {
            if !orderParamWords.contains(word) { return false }
            if orderNameWords.contains(word) { named = true }
        }
        return named && !words.isEmpty
    }

    /// utm parametrinin dəyəri (tracker: `utmValue`; `cleaned`: iç-içə ünvan təmizlənmiş, `value`: açılmış, `rawValue`: xam).
    /// Forma kodlaşdırmasındakı kimi `+` boşluq sayılır; `+` ilə başlayan telefon nömrəsi (`%2B994…`) və kart nömrəsi
    /// gizlədilir. Nəticə: parametrin yeni (kodlanmış) dəyəri, dəyişmirsə nil.
    private static func utmValue(_ cleaned: [UInt16], _ value: [UInt16], _ rawValue: [UInt16]) -> [UInt16]? {
        var form = cleaned
        if rawValue.contains(cPlus) {
            let spaced = rawValue.map { $0 == cPlus ? cSpace : $0 }
            form = decodeUnits(spaced) ?? spaced
        }
        let masked = redactDigits(redactPhones(form), 0)
        if masked == form { return nil }
        if cleaned != value || trimUnits(masked) == redactedUnits { return redactedUnits }
        return Array(encode(string(masked)).utf16)
    }

    /// `^[a-zA-Z][a-zA-Z0-9+.-]*:` başlanğıcının uzunluğu (`:` daxil); yoxdursa 0.
    private static func schemeColon(_ u: [UInt16]) -> Int {
        guard let first = u.first, isLower(first) || isUpper(first) else { return 0 }
        var i = 1
        while i < u.count && (isAlnum(u[i]) || u[i] == cPlus || u[i] == cDot || u[i] == cDash) { i += 1 }
        return (i < u.count && u[i] == cColon) ? i + 1 : 0
    }

    /// `^[a-zA-Z][a-zA-Z0-9+.-]*://` başlanğıcının uzunluğu (`://` daxil); yoxdursa 0.
    private static func schemeLength(_ u: [UInt16]) -> Int {
        let colon = schemeColon(u)
        if colon == 0 { return 0 }
        return (colon + 1 < u.count && u[colon] == cSlash && u[colon + 1] == cSlash) ? colon + 2 : 0
    }

    /// Dəyər ünvandırsa true (tracker: URL_VALUE_RE, `^([a-z][a-z0-9+.-]*:)?//`).
    private static func isUrlValue(_ u: [UInt16]) -> Bool {
        let colon = schemeColon(u)
        return colon + 1 < u.count && u[colon] == cSlash && u[colon + 1] == cSlash
    }

    /// `scheme://host…` başlanğıcının uzunluğu (ilk `/ ? #`-ə qədər; tracker: ORIGIN_RE); yoxdursa 0.
    private static func originLength(_ u: [UInt16]) -> Int {
        var i = schemeLength(u)
        if i == 0 { return 0 }
        while i < u.count && u[i] != cSlash && u[i] != cQuestion && u[i] != cHash { i += 1 }
        return i
    }

    /// `u`-nun `at` yerində ASCII `pattern` (kiçik hərflə verilir) böyük-kiçik hərfə baxılmadan durursa true.
    private static func matchesAt(_ u: [UInt16], _ at: Int, _ pattern: [UInt16]) -> Bool {
        if at + pattern.count > u.count { return false }
        var j = 0
        while j < pattern.count {
            if lower(u[at + j]) != pattern[j] { return false }
            j += 1
        }
        return true
    }

    private static func containsPattern(_ u: [UInt16], _ pattern: [UInt16]) -> Bool {
        var i = 0
        while i + pattern.count <= u.count {
            if matchesAt(u, i, pattern) { return true }
            i += 1
        }
        return false
    }

    /// `u`-da `from` yerindən başlayaraq `c` simvolunun ilk yeri; yoxdursa -1.
    private static func indexOf(_ u: [UInt16], _ c: UInt16, from: Int) -> Int {
        var i = from < 0 ? 0 : from
        while i < u.count {
            if u[i] == c { return i }
            i += 1
        }
        return -1
    }

    private static let nestedEquals: [UInt16] = Array("%3d".utf16)
    private static let nestedScheme: [UInt16] = Array("://".utf16)
    private static let nestedEncodedScheme: [UInt16] = Array("%3a%2f".utf16)
    private static let nestedEncodedSlash: [UInt16] = Array("%2f".utf16)

    /// Parametr dəyərinin içində ünvan və ya query sətri ola bilərsə true (tracker: NESTED_RE,
    /// `=|%3d|://|%3a%2f|^%2f|^/`, böyük-kiçik hərfə baxılmadan).
    private static func maybeNested(_ value: [UInt16]) -> Bool {
        return value.contains(cEquals) || containsPattern(value, nestedEquals) || containsPattern(value, nestedScheme)
            || containsPattern(value, nestedEncodedScheme) || matchesAt(value, 0, nestedEncodedSlash) || value.first == cSlash
    }

    /// Dəyərinə sirr qaydaları tətbiq olunmayan parametr (tracker: `keptParam`): klik ID-ləri, tanınan utm adları
    /// (`utmNames`), `_openstat`, `after` / `before` və adı `cursor` ilə bitən səhifələmə parametrləri (JWT yenə gizlədilir).
    private static func keptParam(_ rawName: [UInt16]) -> Bool {
        let lowered = string(decodeUnits(rawName) ?? rawName).lowercased()
        if clickIds.contains(lowered) || utmNames.contains(lowered) { return true }
        if lowered == "_openstat" || lowered == "after" || lowered == "before" { return true }
        let u = Array(lowered.utf16)
        if u.count < cursorSuffix.count { return false }
        return Array(u[(u.count - cursorSuffix.count)...]) == cursorSuffix
    }

    /// Kənar boşluqları (JavaScript-in `\s` sinfi) atılmış vahidlər.
    private static func trimUnits(_ u: [UInt16]) -> [UInt16] {
        var start = 0
        var end = u.count
        while start < end && isSpace(u[start]) { start += 1 }
        while end > start && isSpace(u[end - 1]) { end -= 1 }
        if start == 0 && end == u.count { return u }
        return Array(u[start..<end])
    }

    /// Parametr dəyəri sirrə bənzəyirsə true (tracker: `secretValue`). `tel:` / `sms:` önlü dəyər telefon nömrəsi kimi
    /// (6+ rəqəm) yoxlanır; forma kodlaşdırmasında `+` boşluqdur (`n=4111+1111+1111+1111`), ona görə dəyər `+` boşluqla
    /// əvəz olunmuş halda da yoxlanır.
    private static func secretValue(_ value: [UInt16], _ rawValue: [UInt16], _ hint: Int) -> Bool {
        if matchesAt(value, 0, telPrefix) || matchesAt(value, 0, smsPrefix) {
            return secretSegment(units: Array(value[4...]), 1, false)
        }
        if secretSegment(units: value, hint, false) { return true }
        if !rawValue.contains(cPlus) { return false }
        let form = rawValue.map { $0 == cPlus ? cSpace : $0 }
        return secretSegment(units: trimUnits(decodeUnits(form) ?? form), hint, false)
    }

    /// Tək `ad=dəyər` hissəsi (tracker: `cleanParam`); nil: parametr silinir. Dəyər JWT-yə bənzəyirsə gizlədilir; dəyərin
    /// özü ünvan və ya query sətridirsə o da təmizlənir (iki səviyyəyədək; daha dərində belə dəyər tam atılır). Qalan
    /// dəyər (açılmış halda) sirrə bənzəyirsə (bax `secretValue`) `ad=[redacted]` olur; `keptParam` parametrlərinin dəyərinə
    /// bu qayda tətbiq olunmur. `hint`: yolun son hissəsi sirr sözüdürsə 1 (`/reset?t=<token>`): dəyər ipucu qaydası ilə
    /// də yoxlanır. Adsız hissə (`/verify?<token>`) və dəyəri yalnız `=` işarələrindən ibarət və ya boş olan hissə (base64
    /// sonluğu: `/reset?<token>=`) özü yoxlanır — ipucu altında `/` ilə ayrılmış parçaları da (standart base64); adı sirrə
    /// bənzəyən hissə (`?<JWT>=1`) bütöv gizlədilir. Dəyişməyən hissə olduğu kimi qaytarılır (yenidən kodlanmır).
    private static func cleanParam(_ part: [UInt16], _ extra: Set<String>, _ ads: Bool, _ depth: Int, _ pathHinted: Int) -> [UInt16]? {
        guard let eq = part.firstIndex(of: cEquals) else {
            // Adsız hissənin dəyəri boşdur (qısa dəyər).
            if sensitiveParam(units: part, extra, ads, true) { return nil }
            // Təsdiq sözünün ipucu (4, 5) adsız hissə üçün həmişə qalır: dəyər yoxdur, sifariş nömrəsinə bənzəmir.
            let hint = pathHinted >= 4 ? 1 : pathHinted
            let bare = decodeSegment(part)
            if secretSegment(units: bare, hint, false) || (hint > 0 && secretPiece(bare, hint)) { return redactedUnits }
            return part
        }
        let rawName = Array(part[0..<eq])
        let rawValue = Array(part[(eq + 1)...])
        if sensitiveParam(units: rawName, extra, ads, rawValue.count <= 2) { return nil }
        // `pathHinted` 4, 5: yol təsdiq sözü ilə bitir (4 — sifariş kontekstində); sifariş nömrəsi parametri (`order_id`; sifariş
        // kontekstində `ref`, `id` də) dəyəri sifariş nömrəsinə bənzəyəndə ipucusuz yoxlanır.
        var hint = pathHinted
        if pathHinted >= 4 {
            let reference = orderParam(rawName, pathHinted == 5) && refShaped(decodeUnits(rawValue) ?? rawValue)
            hint = reference ? 0 : 1
        }
        // Dəyər boşdursa və ya yalnız `=` işarələrindəndirsə (base64 tokeninin sonluğu) ad bütöv token kimi yoxlanır.
        if onlyEquals(rawValue) {
            let bare = decodeSegment(rawName)
            if secretSegment(units: bare, hint, false) || (hint > 0 && secretPiece(bare, hint)) { return redactedUnits }
        }
        // Adın özü sirrə bənzəyirsə (`?<JWT>=1`) hissə bütöv gizlədilir.
        if rawName.count >= 6 && secretSegment(units: decodeSegment(rawName), 0, false) { return redactedUnits }
        let shortest = hint > 0 ? 6 : 8
        if rawValue.count < shortest { return part }
        if isJwt(rawValue) { return rawName + [cEquals] + redactedUnits }
        let value = decodeUnits(rawValue) ?? rawValue
        var plain = !maybeNested(rawValue)
        let isUrl = !plain && (isUrlValue(value) || value.first == cSlash)
        let valueEq = value.firstIndex(of: cEquals) ?? -1
        if !plain && !isUrl && valueEq < 1 { plain = true }
        if !plain && depth >= 2 { return valueEq < 0 ? part : nil }
        var cleaned = value
        if !plain {
            cleaned = isUrl ? scrubUrl(value, extra, ads, depth + 1) : cleanQuery(value, extra, ads, depth + 1, 0)
        }
        // utm dəyərində telefon (`+` ilə) və kart nömrəsi də gizlədilir (qalan sirr qaydaları tətbiq olunmur, bax `keptParam`).
        if utmNames.contains(string(decodeUnits(rawName) ?? rawName).lowercased()), let utm = utmValue(cleaned, value, rawValue) {
            return rawName + [cEquals] + utm
        }
        if cleaned != value {
            if cleaned == redactedUnits { return rawName + [cEquals] + redactedUnits }
            return rawName + [cEquals] + Array(encode(string(cleaned)).utf16)
        }
        if !isUrl && !keptParam(rawName) && secretValue(value, rawValue, hint) { return rawName + [cEquals] + redactedUnits }
        return part
    }

    /// Query sətirindən həssas parametrləri, reklam razılığı yoxdursa klik ID-lərini də silir (tracker: `cleanQuery`;
    /// başdakı `?` olmadan alır və qaytarır). Ayırıcı həm `&`, həm `;` ola bilər; qalan hissələrin ayırıcısı saxlanır.
    private static func cleanQuery(_ query: [UInt16], _ extra: Set<String>, _ ads: Bool, _ depth: Int, _ hint: Int) -> [UInt16] {
        var out: [UInt16] = []
        out.reserveCapacity(query.count)
        let n = query.count
        var start = 0
        var i = 0
        while i <= n {
            if i < n && query[i] != cAmp && query[i] != cSemicolon {
                i += 1
                continue
            }
            if i > start, let part = cleanParam(Array(query[start..<i]), extra, ads, depth, hint) {
                // Hissədən əvvəlki ayırıcı; ilk saxlanan hissədən əvvəl ayırıcı yazılmır.
                if !out.isEmpty { out.append(query[start - 1]) }
                out.append(contentsOf: part)
            }
            start = i + 1
            i += 1
        }
        return out
    }

    /// Yol hissəsi sirr kimi yoxlanmazdan əvvəl açılır (512 simvoldan uzun və ya açılmayan hissə olduğu kimi qalır).
    private static func decodeSegment(_ segment: [UInt16]) -> [UInt16] {
        if segment.count <= 512 && segment.contains(cPercent) { return decodeUnits(segment) ?? segment }
        return segment
    }

    /// `^[0-9]{7,15}$`: telefon sözündən sonrakı yol hissəsi (tracker: PHONE_DIGITS_RE).
    private static func phoneDigits(_ s: [UInt16]) -> Bool {
        if s.count < 7 || s.count > 15 { return false }
        for c in s where !isNumber(c) { return false }
        return true
    }

    /// `cleanPath`-in nəticəsi: təmizlənmiş yol və query üçün ipucu (tracker: `pathHinted`) — yolun son (boş olmayan) hissəsi
    /// sirr sözü idisə 1; ipucu yalnız təsdiq kökündən idisə sifariş kontekstində 4, onsuz 5 (bax `cleanParam`); qalan halda 0.
    private struct CleanedPath {
        let units: [UInt16]
        let hinted: Int
    }

    /// Yolun (və hash marşrutunun) hissələrini yoxlayır (tracker: `cleanPath`): sirrə bənzəyən hissə `[redacted]` olur,
    /// matris parametrləri (`;jsessionid=…`, `;t=<token>`) query parametri kimi təmizlənir (bax `cleanParam`), hissənin `/`
    /// (`%2F`) və `=` ilə ayrılmış parçaları da yoxlanır (bax `secretPiece`). Sirr sözü olan hissədən (bax `pathHint`) sonrakı
    /// İKİ hissə ipucu ilə yoxlanır (`/account/reset/<id>/<token>`); sirr sözünün öz hissəsində yalnız rəqəmli parça
    /// yoxlanır (`confirm-<token>`). Telefon sözü olan hissədən (`/phone/`, `/tel/`) birbaşa sonrakı hissə yalnız 7–15
    /// rəqəmdirsə gizlədilir. İpucu ilə yoxlanan hissə gizlədilirsə ondan dərhal əvvəlki, ipucu altındakı qısa
    /// identifikator da (bax `shortId`: `/reset/MQ/<token>`) gizlədilir. Toxunulmayan hissələr olduğu kimi qalır.
    private static func cleanPath(_ path: [UInt16], _ extra: Set<String>, _ ads: Bool, _ depth: Int) -> CleanedPath {
        if path.isEmpty { return CleanedPath(units: path, hinted: 0) }
        var segments: [[UInt16]] = []
        var from = 0
        var i = 0
        while i <= path.count {
            if i < path.count && path[i] != cSlash {
                i += 1
                continue
            }
            segments.append(Array(path[from..<i]))
            from = i + 1
            i += 1
        }
        var left = 0
        var hinted = 0
        var phone = false
        var previous = -1
        var previousTail: [UInt16] = []
        var before: [UInt16] = []
        var ref = 0
        var refPay = false
        var index = 0
        while index < segments.count {
            let segment = segments[index]
            if segment.isEmpty {
                index += 1
                continue
            }
            var first = segment
            var semi = -1
            if let found = segment.firstIndex(of: cSemicolon) {
                semi = found
                first = Array(segment[0..<found])
            }
            let plain = decodeSegment(first)
            var kind = pathHint(plain)
            let soft = kind >= 3
            var pay = kind == 5
            var order = pay || kind == 4
            if soft {
                // İpucu yalnız təsdiq kökündəndir: əvvəlki və ya sonrakı (boş olmayan) hissə sifariş sözüdürsə sifariş kontekstidir.
                if kind == 3 {
                    var next = index + 1
                    while next < segments.count && segments[next].isEmpty { next += 1 }
                    let near = orderSegment(before)
                    var after = 0
                    if next < segments.count {
                        var name = segments[next]
                        if let found = name.firstIndex(of: cSemicolon) { name = Array(name[0..<found]) }
                        after = orderSegment(decodeSegment(name))
                    }
                    order = near > 0 || after > 0
                    pay = near == 2 || after == 2
                } else if orderSegment(before) == 2 {
                    pay = true
                }
                kind = 2
            }
            let own = kind == 2
            var shown = 0
            if own {
                if order {
                    shown = 4
                } else {
                    shown = soft ? 5 : 1
                }
            }
            var hint = 0
            if left == 2 {
                hint = 1
            } else if left == 1 {
                hint = 2
            } else if own {
                hint = 3
            }
            // Sifariş kontekstindəki təsdiq sözündən sonrakı iki hissədə sifariş nömrəsinə bənzəyən hissə (bax `refShaped`)
            // ipucusuz yoxlanır; ödəniş kontekstində 6–8 rəqəmlik kod istisnadır.
            let reference = ref > 0 && refShaped(plain) && !(refPay && payCode(plain))
            let tested = reference ? 0 : hint
            var tail: [UInt16] = []
            if semi >= 0 {
                // Matris parametrləri query parametri kimi yoxlanır (ad və dəyər); ipucu hissənin öz ipucudur.
                var j = semi + 1
                while j <= segment.count {
                    var stop = j
                    while stop < segment.count && segment[stop] != cSemicolon { stop += 1 }
                    if let bit = cleanParam(Array(segment[j..<stop]), extra, ads, depth, own ? shown : hint) {
                        tail.append(cSemicolon)
                        tail.append(contentsOf: bit)
                    }
                    j = stop + 1
                }
            }
            let masked = secretSegment(units: plain, tested, true) || (phone && phoneDigits(plain)) || secretPiece(plain, tested)
            phone = kind == 1
            if masked && previous >= 0 { segments[previous] = redactedUnits + previousTail }
            segments[index] = (masked ? redactedUnits : first) + tail
            previous = (!masked && (hint == 1 || hint == 2) && shortId(plain)) ? index : -1
            previousTail = tail
            if own {
                left = 2
            } else if left > 0 {
                left -= 1
            }
            before = plain
            if own {
                ref = order ? 2 : 0
                refPay = pay
            } else if ref > 0 {
                ref -= 1
            }
            hinted = shown
            index += 1
        }
        var out: [UInt16] = []
        out.reserveCapacity(path.count)
        index = 0
        while index < segments.count {
            if index > 0 { out.append(cSlash) }
            out.append(contentsOf: segments[index])
            index += 1
        }
        return CleanedPath(units: out, hinted: hinted)
    }

    /// Ünvandan həssas query parametrlərini, sirrə bənzəyən yol hissələrini, marşrut olmayan fraqmenti və e-poçta bənzər
    /// hissələri silir (tracker: `scrubUrl`). `depth`: parametr dəyərinin içindəki ünvan üçün iç-içəlik səviyyəsi.
    private static func scrubUrl(_ url: [UInt16], _ extra: Set<String>, _ ads: Bool, _ depth: Int) -> [UInt16] {
        var href = url
        var hash: [UInt16] = []
        var query: [UInt16] = []
        var hasQuery = false
        if let index = href.firstIndex(of: cHash) {
            hash = Array(href[index...])
            href = Array(href[0..<index])
        }
        if let index = href.firstIndex(of: cQuestion) {
            query = Array(href[(index + 1)...])
            hasQuery = true
            href = Array(href[0..<index])
        }
        // http / https: sxem və host toxunulmaz qalır (istifadəçi adı / parol hissəsi sonuncu `@` işarəsinədək silinir).
        // Başqa sxemlərdə (tətbiq keçidi: `myapp://reset/123456`) «host» yolun ilk hissəsidir: o da sirr sözü ola bilər
        // və özü gizlədilə bilər.
        let originEnd = originLength(href)
        var head = Array(href[0..<originEnd])
        if let at = head.lastIndex(of: cAt) {
            head = Array(head[0..<schemeLength(head)]) + Array(head[(at + 1)...])
        }
        var path = Array(href[originEnd...])
        if originEnd > 0 && !matchesAt(head, 0, httpPrefix) && !matchesAt(head, 0, httpsPrefix) {
            let cutAt = schemeLength(head)
            path = Array(head[cutAt...]) + path
            head = Array(head[0..<cutAt])
        }
        var cleaned = cleanPath(path, extra, ads, depth)
        var rest = cleaned.units
        // Yol sirr sözü ilə bitirsə (`/reset?t=<token>`) query dəyərləri də ipucu ilə yoxlanır.
        if hasQuery {
            query = cleanQuery(query, extra, ads, depth, cleaned.hinted)
            if !query.isEmpty {
                rest.append(cQuestion)
                rest.append(contentsOf: query)
            }
        }
        // Hash marşrutu (`#/…`, `#!…`) saxlanır və yol kimi təmizlənir; onun da öz query hissəsi ola bilər
        // (`#/callback?access_token=…`). Başqa fraqment atılır.
        if hash.count > 1 && (hash[1] == cExclamation || hash[1] == cSlash) {
            var route = Array(hash[1...])
            query = []
            hasQuery = false
            if let index = hash.firstIndex(of: cQuestion) {
                query = Array(hash[(index + 1)...])
                hasQuery = true
                route = Array(hash[1..<index])
            }
            var extraQuery: [UInt16] = []
            var join = false
            // `?` olmadan yazılmış parametrlər (`#/home&state=…&code=…`, `#/access_token=…`): birinci `&`-dən sonrakı hissə
            // və `=` olan son yol hissəsi query kimi təmizlənir. `=` işarəsi matris parametrindədirsə (`#/reset;t=<token>`:
            // hissədə ondan əvvəl `;` var) hissə yolda qalır və `cleanPath` onu öz ipucu ilə təmizləyir; növbəti hissələrə baxılır.
            if route.contains(cEquals) {
                if let amp = route.firstIndex(of: cAmp) {
                    extraQuery = Array(route[(amp + 1)...])
                    route = Array(route[0..<amp])
                    join = true
                }
                var eq = indexOf(route, cEquals, from: 0)
                while eq >= 0 {
                    // Hissənin başlanğıcı və "="-dən əvvəlki ilk ";".
                    var semi = eq
                    while semi > 0 && route[semi - 1] != cSlash { semi -= 1 }
                    while semi < eq && route[semi] != cSemicolon { semi += 1 }
                    if semi >= eq { break }
                    var next = eq
                    while next < route.count && route[next] != cSlash { next += 1 }
                    while next < route.count && route[next] != cEquals { next += 1 }
                    eq = next < route.count ? next : -1
                }
                if eq >= 0 {
                    var cutAt = 0
                    var k = eq
                    while k >= 0 {
                        if route[k] == cSlash {
                            cutAt = k + 1
                            break
                        }
                        k -= 1
                    }
                    if cutAt == 0 && route[0] == cExclamation { cutAt = 1 }
                    var moved = Array(route[cutAt...])
                    if join {
                        moved.append(cAmp)
                        moved.append(contentsOf: extraQuery)
                    }
                    extraQuery = moved
                    route = Array(route[0..<cutAt])
                    join = false
                }
            }
            cleaned = cleanPath(route, extra, ads, depth)
            let hint = cleaned.hinted
            if !extraQuery.isEmpty { extraQuery = cleanQuery(extraQuery, extra, ads, depth, hint) }
            rest.append(cHash)
            rest.append(contentsOf: cleaned.units)
            if !extraQuery.isEmpty {
                if join { rest.append(cAmp) }
                rest.append(contentsOf: extraQuery)
            }
            if hasQuery {
                query = cleanQuery(query, extra, ads, depth, hint)
                if !query.isEmpty {
                    rest.append(cQuestion)
                    rest.append(contentsOf: query)
                }
            }
        }
        return head + redactEmailUnits(rest)
    }

    /// `+` ilə başlayan telefon nömrələrini gizlədir (tracker: `redactPhones`): `+` və ardınca rəqəm, sonra rəqəm və
    /// ayırıcılar (boşluq, mötərizə, nöqtə, tire; `+`-dan sonra ən çoxu 24 simvol), cəmi 7–15 rəqəm.
    private static func redactPhones(_ s: [UInt16]) -> [UInt16] {
        if !s.contains(cPlus) { return s }
        let n = s.count
        var out: [UInt16] = []
        out.reserveCapacity(n)
        var i = 0
        while i < n {
            let c = s[i]
            if c == cPlus && i + 1 < n && isNumber(s[i + 1]) {
                var digits = 0
                var last = i
                var j = i + 1
                while j < n && j - i <= 24 {
                    let d = s[j]
                    if isNumber(d) {
                        digits += 1
                        last = j
                    } else if d != cSpace && d != cOpen && d != cClose && d != cDot && d != cDash {
                        break
                    }
                    j += 1
                }
                if digits >= 7 && digits <= 15 {
                    out.append(contentsOf: redactedUnits)
                    i = last + 1
                } else {
                    out.append(cPlus)
                    i += 1
                }
            } else {
                out.append(c)
                i += 1
            }
        }
        return out
    }

    /// Kart nömrəsinin rəqəmləri arasında ola bilən ayırıcı (tracker: `cardGap`): boşluq, tire, `/`, qırılmayan (U+00A0),
    /// nazik (U+2009) və dar qırılmayan (U+202F) boşluq.
    private static func cardGap(_ c: UInt16) -> Bool {
        return c == cSpace || c == cDash || c == cSlash || c == cNbsp || c == 0x2009 || c == 0x202f
    }

    /// Rəqəm ardıcıllıqlarını gəzir (tracker: `redactDigits`). Ardıcıllıq: rəqəmlər, aralarında ən çoxu üç ayırıcı (bax
    /// `cardGap`) ola bilər. `min` 0: Luhn yoxlamasından keçən 15–19 rəqəmlik ardıcıllıq (kart nömrəsi) gizlədilir;
    /// `min` > 0: ayırıcısız `min` və daha çox rəqəm gizlədilir (ekran adında telefon). Kart nömrəsinə bənzəyən rəqəmlər
    /// bütövlükdə sirr ardıcıllığının (bax `secretRun`: hex token, IBAN) içindədirsə toxunulmur: ardıcıllığı sonra `redactRuns`
    /// bütöv gizlədir. `[a, b)` — sonuncu yoxlanmış token simvolları ardıcıllığıdır (hər ardıcıllıq bir dəfə yoxlanır, vaxt
    /// xətti qalır).
    private static func redactDigits(_ s: [UInt16], _ min: Int) -> [UInt16] {
        let n = s.count
        var out: [UInt16] = []
        out.reserveCapacity(n)
        var i = 0
        var a = 0
        var b = 0
        var inside = false
        while i < n {
            if !isNumber(s[i]) {
                out.append(s[i])
                i += 1
                continue
            }
            var digits: [UInt16] = []
            var last = i
            var j = i
            while j < n {
                let c = s[j]
                if isNumber(c) {
                    digits.append(c)
                    last = j
                    j += 1
                    continue
                }
                if min > 0 { break }
                // Rəqəmlər arasında ən çoxu üç ayırıcı (bax `cardGap`) ola bilər.
                var k = j
                while k < n && k - j < 3 && cardGap(s[k]) { k += 1 }
                if k == j || k >= n || !isNumber(s[k]) { break }
                j = k
            }
            var masked = false
            if min > 0 {
                masked = digits.count >= min
            } else {
                masked = digits.count >= 15 && digits.count <= 19 && luhn(digits)
                if masked {
                    if i >= b {
                        a = i
                        while a > b && isBase64Url(s[a - 1]) { a -= 1 }
                        b = i
                        while b < n && isBase64Url(s[b]) { b += 1 }
                        inside = b - a >= 14 && secretRun(s, a, b)
                    }
                    if inside && last < b { masked = false }
                }
            }
            if masked {
                out.append(contentsOf: redactedUnits)
            } else {
                out.append(contentsOf: s[i...last])
            }
            i = last + 1
        }
        return out
    }

    /// IBAN (tracker: `iban`): 2 hərf + 2 rəqəm + 11–30 hərf / rəqəm (cəmi 15–34 simvol) və mod 97 yoxlaması (ISO 13616).
    private static func iban(_ s: [UInt16]) -> Bool {
        let n = s.count
        if n < 15 || n > 34 || !isAlpha(s[0]) || !isAlpha(s[1]) || !isNumber(s[2]) || !isNumber(s[3]) { return false }
        var r = 0
        var i = 0
        while i < n {
            let c = s[(i + 4) % n]
            if isNumber(c) {
                r = (r * 10 + Int(c) - 48) % 97
            } else if isAlpha(c) {
                r = (r * 100 + Int(lower(c)) - 87) % 97
            } else {
                return false
            }
            i += 1
        }
        return r == 1
    }

    /// Token simvollarından (`A-Z a-z 0-9 _ -`) ibarət ardıcıllıq adi addırsa true (tracker: `wordy`): yalnız sözlərdən
    /// (bir hərf və ardınca 2+ kiçik hərf: `step`, `Shipping`), 1–4 rəqəmlik ədədlərdən və `-` `_` ayırıcılarından ibarətdir
    /// (`Step3ShippingAddressViewController`).
    private static func wordy(_ s: [UInt16]) -> Bool {
        let n = s.count
        var i = 0
        while i < n {
            let c = s[i]
            if c == cDash || c == cUnderscore {
                i += 1
                continue
            }
            let k = i
            if isNumber(c) {
                while i < n && isNumber(s[i]) { i += 1 }
                if i - k > 4 { return false }
                continue
            }
            i += 1
            while i < n && isLower(s[i]) { i += 1 }
            if i - k < 3 { return false }
        }
        return true
    }

    /// `w[i, j)` token simvollarından ibarət ardıcıllıqdır; ondan başlayan JWT-nin (bax `isJwt`) sonu, JWT deyilsə -1 (tracker: `jwtEnd`).
    private static func jwtEnd(_ w: [UInt16], _ i: Int, _ j: Int) -> Int {
        let n = w.count
        if j - i < 11 || j >= n || w[j] != cDot { return -1 }
        // `eyJ` (böyük-kiçik hərf dəqiq).
        if w[i] != jwtStart[0] || w[i + 1] != jwtStart[1] || w[i + 2] != jwtStart[2] { return -1 }
        var k = j + 1
        while k < n && isBase64Url(w[k]) { k += 1 }
        if k - j < 9 { return -1 }
        if k >= n || w[k] != cDot { return k }
        k += 1
        while k < n && isBase64Url(w[k]) { k += 1 }
        return k
    }

    /// `w[i, j)` token simvollarından ibarət ardıcıllıqdır (ən azı 14 simvol); sirdirsə true (tracker: `secretRun`):
    ///  - tanınan API açarı önü (bax `keyPrefix`);
    ///  - qalan qaydalar ardıcıllıq fayl və ya domen adının hissəsi olmayanda (yanında `.` və ondan o yana token simvolu
    ///    yoxdur) tətbiq olunur: IBAN (bax `iban`); 32+ simvolluq ardıcıllıq üçün yolun hex, base64 və uzun hərf-rəqəm
    ///    qaydaları (`secretSegment` 5–7; tiresiz UUID istisnadır) — yalnız rəqəmdən ibarət və adi ad (bax `wordy`) olan
    ///    ardıcıllıq istisnadır. 32 simvoldan qısa ardıcıllıq (ödəniş sisteminin ID-si `pi_…`, Firebase UID) adi
    ///    identifikator sayılır.
    private static func secretRun(_ w: [UInt16], _ i: Int, _ j: Int) -> Bool {
        let s = Array(w[i..<j])
        if keyPrefix(s) { return true }
        if i > 1 && w[i - 1] == cDot && isBase64Url(w[i - 2]) { return false }
        if j + 1 < w.count && w[j] == cDot && isBase64Url(w[j + 1]) { return false }
        if iban(s) { return true }
        if j - i < 32 { return false }
        var allDigits = true
        var allHex = true
        for c in s {
            if !isNumber(c) { allDigits = false }
            if hexValue(c) < 0 { allHex = false }
        }
        if allDigits || (!allHex && wordy(s)) { return false }
        return secretSegment(units: s, 0, false)
    }

    /// Ünvanda parametr adından əvvəl gələ bilən işarə: `? & ; # / !` (tracker: `paramStart`).
    private static func paramStart(_ c: UInt16) -> Bool {
        return c == cQuestion || c == cAmp || c == cSemicolon || c == cHash || c == cSlash || c == cExclamation
    }

    /// Mətn hissəsində sirr ardıcıllıqlarını gizlədir (tracker: `redactRuns`). Hissə token simvollarının (`A-Z a-z 0-9 _ -`)
    /// ardıcıllıqlarına bölünür; qalan hər simvol (durğu işarələri, dırnaqlar, görünməyən simvollar) ayırıcıdır. Ardıcıllıq
    /// JWT-nin başlanğıcıdırsa (bax `jwtEnd`) bütün JWT, sirdirsə (bax `secretRun`) özü `[redacted]` olur. `url`: mətn
    /// təmizlənmiş ünvandır (bax `scrubToken`) — `%XX` kodu ayırıcıdır, dəyərinə sirr qaydaları tətbiq olunmayan parametrin
    /// (bax `keptParam`: klik ID-si, utm) dəyəri növbəti `&`, `;` və ya `#` işarəsinədək ötürülür.
    private static func redactRuns(_ w: [UInt16], _ url: Bool) -> [UInt16] {
        let n = w.count
        var out: [UInt16] = []
        var keep = 0
        var i = 0
        while i < n {
            if url && w[i] == cPercent && i + 2 < n && hexValue(w[i + 1]) >= 0 && hexValue(w[i + 2]) >= 0 {
                i += 3
                continue
            }
            if !isBase64Url(w[i]) {
                i += 1
                continue
            }
            var j = i
            while j < n && isBase64Url(w[j]) { j += 1 }
            if url && j < n && w[j] == cEquals && (i == 0 || paramStart(w[i - 1])) && keptParam(Array(w[i..<j])) {
                i = j + 1
                while i < n && w[i] != cAmp && w[i] != cSemicolon && w[i] != cHash { i += 1 }
                continue
            }
            var e = jwtEnd(w, i, j)
            if e < 0 && j - i >= 14 && secretRun(w, i, j) { e = j }
            if e < 0 {
                i = j
                continue
            }
            out.append(contentsOf: w[keep..<i])
            out.append(contentsOf: redactedUnits)
            keep = e
            i = e
        }
        if keep == 0 { return w }
        out.append(contentsOf: w[keep..<n])
        return out
    }

    /// Mətn hissəsi query sətri kimi təmizlənməlidirsə true (tracker: `pairText`): `ad=` ilə başlayır (ad: `A-Z a-z 0-9 _ - .
    /// % [ ]`) və ya ardınca `&` gəlir (`a=1&token=…`), ya da tək cütdür, adı həssasdır (bax `sensitiveParam`) və dəyəri 6+
    /// simvolluqdur, token simvolu, `%`, `+` və ya `.` ilə başlayır, içində rəqəm və ya böyük hərf var
    /// (`session_id=Xk29LmQa`; `code=200`, `key=value` və `auth="…"` qalır).
    private static func pairText(_ w: [UInt16], _ extra: Set<String>, _ ads: Bool) -> Bool {
        let n = w.count
        let eq = indexOf(w, cEquals, from: 0)
        if eq < 1 { return false }
        var i = 0
        while i < eq {
            let c = w[i]
            // `. % [ ]`
            if !isBase64Url(c) && c != cDot && c != cPercent && c != 91 && c != 93 { return false }
            i += 1
        }
        if indexOf(w, cAmp, from: eq) > 0 { return true }
        if n - eq < 7 { return false }
        let first = w[eq + 1]
        if !isBase64Url(first) && first != cPercent && first != cPlus && first != cDot { return false }
        i = eq + 1
        while i < n {
            if isNumber(w[i]) || isUpper(w[i]) {
                return sensitiveParam(units: Array(w[0..<eq]), extra, ads, n - eq - 1 <= 2)
            }
            i += 1
        }
        return false
    }

    /// Hissə `Bearer` sözü ilə bitirsə (böyük-kiçik hərfə baxılmadan; əvvəlində hərf yoxdur) true (tracker: `bearerWord`).
    private static func bearerWord(_ w: [UInt16]) -> Bool {
        let n = w.count
        if n < 6 || (n > 6 && isAlpha(w[n - 7])) { return false }
        return matchesAt(w, n - 6, bearerUnits)
    }

    /// `Bearer` sözündən sonrakı hissənin əvvəlindəki tokenin uzunluğu (tracker: `bearerEnd`): `A-Z a-z 0-9 . _ ~ + / = -`
    /// simvollarından 8+ simvol, içində rəqəm və ya (birincidən sonra) böyük hərf var; token deyilsə 0.
    private static func bearerEnd(_ w: [UInt16]) -> Int {
        let n = w.count
        var mixed = false
        var i = 0
        while i < n {
            let c = w[i]
            if isNumber(c) || (i > 0 && isUpper(c)) {
                mixed = true
            } else if !isAlpha(c) && c != cDot && c != cUnderscore && c != cTilde && c != cPlus && c != cSlash && c != cEquals && c != cDash {
                break
            }
            i += 1
        }
        return (i >= 8 && mixed) ? i : 0
    }

    /// Mətnin boşluqlarla ayrılmış bir hissəsi (tracker: `scrubToken`). Ünvan şəklindədirsə (`sxem://`, `//`, `/` və ya
    /// `?` ilə başlayır, içində `?` və ondan sonra `=` var, ya da hash marşrutudur) ünvan kimi təmizlənir; `#` ilə başlayıb
    /// `=` daşıyırsa query kimi; `ad=dəyər` cütüdürsə (bax `pairText`) əvvəlcə query kimi təmizlənir; sonra hər halda sirr
    /// ardıcıllıqları gizlədilir (bax `redactRuns`: ünvanın ardınca durğu işarəsi və ya dırnaq gələndə hissə bütöv dəyər olmur).
    private static func scrubToken(_ w: [UInt16], _ extra: Set<String>, _ ads: Bool) -> [UInt16] {
        let n = w.count
        let c = w[0]
        let q = indexOf(w, cQuestion, from: 0)
        let route = n > 1 && c == cHash && (w[1] == cExclamation || w[1] == cSlash)
        let queried = q > 0 && indexOf(w, cEquals, from: q) > 0
        if isUrlValue(w) || c == cSlash || (c == cQuestion && n > 1) || queried || route {
            return n > maxTextUrl ? redactedUnits : redactRuns(scrubUrl(w, extra, ads, 0), true)
        }
        if c == cHash && indexOf(w, cEquals, from: 0) > 0 {
            let cleaned = cleanQuery(Array(w[1...]), extra, ads, 0, 0)
            if cleaned.isEmpty { return cleaned }
            return redactRuns([cHash] + cleaned, true)
        }
        if pairText(w, extra, ads) { return redactRuns(cleanQuery(w, extra, ads, 0, 0), false) }
        return redactRuns(w, false)
    }

    /// `props` / `traits` mətn dəyəri (tracker: `scrubText`; ekran adı da buradan keçir). Kənar boşluqlar atıldıqdan sonra
    /// dəyər bütöv JWT və ya kart nömrəsidirsə `[redacted]` olur; ünvandırsa ünvan kimi təmizlənir, sonra sirr ardıcıllıqları
    /// gizlədilir (bax `redactRuns`; `maxTextUrl`-dən uzun ünvan tam gizlədilir). Qalan halda: e-poçta bənzər hissələr, `+` ilə başlayan telefon nömrələri və kart nömrələri
    /// (Luhn) gizlədilir, sonra boşluqlarla ayrılmış hər hissə `scrubToken` ilə yoxlanır.
    private static func scrubText(_ value: String, _ extra: Set<String>, _ ads: Bool) -> String {
        let u = Array(value.utf16)
        return string(scrubTextUnits(u, extra, ads))
    }

    private static func scrubTextUnits(_ u: [UInt16], _ extra: Set<String>, _ ads: Bool) -> [UInt16] {
        let t = trimUnits(u)
        if isJwt(t) || cardNumber(t) { return redactedUnits }
        if isUrlValue(t) { return t.count > maxTextUrl ? redactedUnits : redactRuns(scrubUrl(t, extra, ads, 0), true) }
        let s = redactDigits(redactPhones(redactEmailUnits(u)), 0)
        let n = s.count
        var out: [UInt16] = []
        out.reserveCapacity(n)
        var i = 0
        var bearer = false
        while i < n {
            var j = i
            while j < n && isSpace(s[j]) { j += 1 }
            out.append(contentsOf: s[i..<j])
            i = j
            while j < n && !isSpace(s[j]) { j += 1 }
            if j > i {
                let w = Array(s[i..<j])
                // `Bearer` sözündən sonrakı hissənin tokeni (bax `bearerEnd`) gizlədilir.
                let e = bearer ? bearerEnd(w) : 0
                if e > 0 {
                    out.append(contentsOf: redactedUnits)
                    if e < w.count { out.append(contentsOf: scrubToken(Array(w[e...]), extra, ads)) }
                } else {
                    out.append(contentsOf: scrubToken(w, extra, ads))
                }
                bearer = bearerWord(w)
            }
            i = j
        }
        return out
    }

    /// Ekran adı (vebdə səhifə başlığı; tracker: `scrubLabel`): `props` mətn dəyəri kimi təmizlənir (bax `scrubText`;
    /// ünvan şəklindədirsə ünvan kimi: `/reset-password/<token>`), sonra ayırıcısız 9 və daha çox rəqəm (telefon)
    /// `[redacted]` olur. Ad və soyad tanınmır.
    static func label(_ value: String, extra: Set<String> = [], ads: Bool = true) -> String {
        return string(redactDigits(scrubTextUnits(Array(value.utf16), extra, ads), 9))
    }

    /// NUL simvolunu silir və mətni ən çox `limit` UTF-16 vahidinə kəsir; surroqat cütü ortadan bölünmür
    /// (tracker: `cut`).
    static func cut(_ value: String, _ limit: Int) -> String {
        let cleaned = text(value)
        let u = Array(cleaned.utf16)
        if u.count <= limit { return cleaned }
        let last = u[limit - 1]
        return string(Array(u[0..<((last >= 0xd800 && last <= 0xdbff) ? limit - 1 : limit)]))
    }

    /// Keçidi göndərilə bilən formaya gətirir. Qaydalar veb tracker-in `cleanUrl` funksiyası və Android ilə eynidir və
    /// ortaq vektorlarla yoxlanır (spec/vectors/sanitize-url.json):
    /// - adı həssas olan (bax `sensitiveParam`) və ya konfiqin `strip_params` siyahısında olan query parametrləri silinir;
    ///   ayırıcı kimi həm `&`, həm `;` tanınır; `utm_*` qalır; klik ID-ləri yalnız `ads` (reklam razılığı) olduqda qalır;
    /// - JWT-yə bənzəyən dəyər `ad=[redacted]` olur; dəyəri ünvan və ya query sətri olan parametr (`redirect=https%3A…`)
    ///   eyni qaydalarla, iki səviyyəyədək təmizlənir;
    /// - yolun sirrə oxşayan hissələri (bax `secretSegment`) və e-poçta bənzər mətn `[redacted]` olur;
    /// - hash marşrutu (`#/…`, `#!…`) yol kimi təmizlənir, başqa fraqment və istifadəçi adı / parol hissəsi silinir;
    /// - nəticə 2048 simvola kəsilir.
    /// `maxUrlLength`-dən uzun ünvan təmizlənməzdən əvvəl qısaldılır (bax `shorten`).
    static func cleanUrl(_ url: String, extraStrip: Set<String> = [], ads: Bool = true) -> String {
        let all = Array(url.utf16)
        let given = all.count > maxUrlLength ? shorten(all) : all
        return cut(string(scrubUrl(given, extraStrip, ads, 0)), 2048)
    }

    /// `maxUrlLength`-dən uzun ünvanı qısaldır (tracker: `shorten`): query və fraqment atılır, yol `maxUrlLength` simvola
    /// (UTF-16 vahidi), son bütöv hissəyə qədər kəsilir.
    private static func shorten(_ url: [UInt16]) -> [UInt16] {
        var end = maxUrlLength
        let q = indexOf(url, cQuestion, from: 0)
        let h = indexOf(url, cHash, from: 0)
        if q >= 0 && q < end { end = q }
        if h >= 0 && h < end { end = h }
        let head = Array(url[0..<end])
        // Son `/` və ilk `//`-nin yeri (yoxdursa -1).
        var slash = -1
        var k = head.count - 1
        while k >= 0 {
            if head[k] == cSlash {
                slash = k
                break
            }
            k -= 1
        }
        var pair = -1
        k = 0
        while k + 1 < head.count {
            if head[k] == cSlash && head[k + 1] == cSlash {
                pair = k
                break
            }
            k += 1
        }
        if end == maxUrlLength && slash > pair + 1 { return Array(head[0...slash]) }
        return head
    }

    /// Reklam razılığı olmadan göndərilən ünvan: `cleanUrl` `ads: false` ilə. Veb tracker-dəki kimi ünvan yenidən
    /// təmizlənir, ona görə klik ID-ləri (`clickIds`) iç-içə ünvanlardan (iki səviyyə), hash marşrutunun query-sindən
    /// və matris parametrlərindən də çıxır. Artıq təmizlənmiş ünvanın qalan hissələri dəyişmir.
    static func stripClickIds(_ url: String, extraStrip: Set<String> = []) -> String {
        return cleanUrl(url, extraStrip: extraStrip, ads: false)
    }

    /// Kampaniya dəyərinin ən böyük uzunluğu, UTF-16 vahidi ilə (veb tracker və sxemdəki hədd: 512).
    static let maxCampaignValue = 512

    /// Kampaniya dəyəri (tracker: `scrubValue` + `cut`): JWT `[redacted]` olur, dəyər ünvandırsa o da təmizlənir,
    /// qalan halda e-poçta bənzər hissələr gizlədilir; nəticə `maxCampaignValue` simvola kəsilir. `utm` (ad `campaignKeys`
    /// siyahısındadır, bax `isUtmName`) olduqda `+` ilə başlayan telefon və kart nömrəsi də gizlədilir; klik ID-lərində yox
    /// (yalnız rəqəmdən ibarət klik ID-si kart nömrəsinə bənzəyə bilər).
    static func campaignValue(_ value: String, extraStrip: Set<String> = [], ads: Bool = true, utm: Bool = false) -> String {
        let u = Array(value.utf16)
        var scrubbed: [UInt16]
        if isJwt(u) {
            scrubbed = redactedUnits
        } else if isUrlValue(u) {
            scrubbed = scrubUrl(u, extraStrip, ads, 1)
        } else {
            scrubbed = redactEmailUnits(u)
            if utm { scrubbed = redactDigits(redactPhones(scrubbed), 0) }
        }
        return cut(string(scrubbed), maxCampaignValue)
    }

    /// Ad utm kampaniya adıdırsa (`utm_source`, `utm_medium`, `utm_campaign`, `utm_term`, `utm_content`) true.
    static func isUtmName(_ name: String) -> Bool {
        return campaignKeys.contains(name)
    }

    /// Keçiddəki UTM və (`withClickIds` olduqda) klik ID parametrləri (PROTOCOL.md 5.4 `campaign`). Qaydalar veb tracker
    /// və Android ilə eynidir (spec/vectors/campaign.json): query yalnız `&` ilə bölünür, ad və dəyər açılır (dəyərdə
    /// `+` boşluqdur; açılmayan cüt ötürülür), adlar dəqiq (kiçik hərflə) tutuşdurulur, təkrarlanan adın sonuncusu
    /// götürülür, boş dəyər və təmizləmədən sonra boş qalan dəyər atılır. Dəyərlər `campaignValue` ilə təmizlənir. Veb
    /// tracker-dəki kimi ünvanın uzunluğuna hədd yoxdur (dərin keçidin uzunluğunu çağıran yoxlayır, bax `maxUrlLength`).
    static func campaignOf(_ url: String, withClickIds: Bool = true, extraStrip: Set<String> = []) -> [String: Any]? {
        let all = Array(url.utf16)
        var base = all
        if let hash = all.firstIndex(of: cHash) { base = Array(all[0..<hash]) }
        guard let question = base.firstIndex(of: cQuestion) else { return nil }
        let q = Array(base[(question + 1)...])
        // Açar UTF-16 vahidləridir: `String` açarları kanonik ekvivalentliyə görə birləşdirərdi.
        var found: [[UInt16]: [UInt16]] = [:]
        var i = 0
        while i <= q.count {
            var end = i
            while end < q.count && q[end] != cAmp { end += 1 }
            let part = Array(q[i..<end])
            i = end + 1
            if part.isEmpty { continue }
            var rawName = part
            var rawValue: [UInt16] = []
            if let eq = part.firstIndex(of: cEquals) {
                rawName = Array(part[0..<eq])
                rawValue = Array(part[(eq + 1)...])
            }
            guard let name = decodeUnits(rawName) else { continue }
            guard let value = decodeUnits(rawValue.map { $0 == cPlus ? cSpace : $0 }) else { continue }
            // Snapchat klik ID-sini `ScCid` şəklində yazır; qalan adlar dəqiq (kiçik hərflə) tutuşdurulur.
            found[name == snapClickId ? snapClickIdLower : name] = value
        }
        var out: [String: Any] = [:]
        let names = withClickIds ? campaignKeys + clickIds : campaignKeys
        for name in names {
            guard let value = found[Array(name.utf16)], !value.isEmpty else { continue }
            let cleaned = campaignValue(string(value), extraStrip: extraStrip, ads: withClickIds, utm: isUtmName(name))
            if !cleaned.isEmpty { out[name] = cleaned }
        }
        return out.isEmpty ? nil : out
    }
}
