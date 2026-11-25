import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Razılıq vəziyyəti (PROTOCOL.md, bölmə 7).
public struct Consent {
    public let analytics: Bool
    public let ads: Bool

    public init(analytics: Bool, ads: Bool) {
        self.analytics = analytics
        self.ads = ads
    }
}

/// `SmartBee.initialize` seçimləri.
public struct SmartBeeOptions {
    /// Başlanğıc razılıq; verilməyibsə mənbənin konfiqindən götürülür.
    public var consent: Consent?
    /// Ətraflı log (konsol, prefiks `[SmartBee]`).
    public var debug: Bool
    /// `false` olarsa bütün avtomatik eventlər sönür.
    public var autoEvents: Bool
    /// Yalnız test və ya proksi üçün.
    public var endpoint: String
    /// Örtük SDK-nın adı (`react-native`, `flutter`); tətbiq kodu tərəfindən verilmir.
    public var wrapper: String?
    public var wrapperVersion: String?

    public init(
        consent: Consent? = nil,
        debug: Bool = false,
        autoEvents: Bool = true,
        endpoint: String = "https://c.cdnsb.net",
        wrapper: String? = nil,
        wrapperVersion: String? = nil
    ) {
        self.consent = consent
        self.debug = debug
        self.autoEvents = autoEvents
        self.endpoint = endpoint
        self.wrapper = wrapper
        self.wrapperVersion = wrapperVersion
    }
}

/// SmartBee Pixel-in açıq API-si (SDK-API.md).
///
/// Bütün metodlar istənilən axından çağırıla bilər, dərhal qayıdır və heç vaxt xəta atmır.
/// `initialize`-dən əvvəlki çağırışlar yadda saxlanır və ondan sonra icra olunur.
public enum SmartBee {
    private static let maxPending = 100
    private static let queue = DispatchQueue(label: "az.smartbee.pixel", qos: .utility)
    private static let lock = NSLock()
    private static var initialized = false
    private static var core: Core?
    private static var fileQueue: FileQueue?
    private static var pending: [(Core) -> Void] = []
    private static var cachedAnonymousId: String?
    private static var observers: [NSObjectProtocol] = []

    /// SDK-nı başladır. Təkrar çağırış nəzərə alınmır. (Swift-də `init` açar söz olduğu üçün ad `initialize`-dır.)
    public static func initialize(key: String, options: SmartBeeOptions = SmartBeeOptions()) {
        lock.lock()
        if initialized {
            lock.unlock()
            return
        }
        initialized = true
        lock.unlock()

        guard Util.isValidKey(key) else {
            NSLog("[SmartBee] invalid source key, SDK is disabled")
            return
        }
        // Ekran və cihaz məlumatı (UIKit) yalnız əsas axında oxuna bilər. Əsas axın gözlədilmir
        // (kilidlənmə riski): başqa axından başladılanda bu sahələr bir az sonra əlavə olunur.
        let env = AppleEnv(snapshot: AppleEnv.captureBase())
        if Thread.isMainThread {
            env.merge(AppleEnv.captureUI())
        } else {
            DispatchQueue.main.async { env.merge(AppleEnv.captureUI()) }
        }
        queue.async {
            let events = FileQueue()
            let created = Core(
                key: key,
                options: options,
                store: FileStore(),
                queue: events,
                transport: URLSessionTransport(debug: options.debug),
                env: env
            )
            created.start()
            created.refreshConfig()
            lock.lock()
            core = created
            fileQueue = events
            let queued = pending
            pending.removeAll()
            lock.unlock()
            for call in queued { call(created) }
            setAnonymousId(created.anonymousId)
            events.persist()
            schedule(created, events)
        }
        observeLifecycle()
    }

    /// Event göndərir. `eventId` server tərəfi ilə dedup üçündür (məsələn sifariş nömrəsi).
    public static func track(_ name: String, props: [String: Any]? = nil, eventId: String? = nil) {
        post { $0.track(name, props: props, eventId: eventId) }
    }

    /// İstifadəçini tanıdır. `email` və `phone` cihazda SHA-256 ilə hash olunur.
    public static func identify(_ userId: String, traits: [String: Any]? = nil) {
        post { $0.identify(userId, traits: traits) }
    }

    /// Ekran baxışı. Sonrakı eventlərə də bu ekran adı əlavə olunur.
    public static func screen(_ name: String, props: [String: Any]? = nil) {
        post { $0.screen(name, props: props) }
    }

    /// Razılığı dəyişir və saxlayır. `analytics = false` olduqda heç nə göndərilmir və saxlanmır.
    public static func setConsent(analytics: Bool, ads: Bool) {
        // Razılıq geri alınanda növbə diskdən də dərhal silinməlidir.
        post(persistNow: true) { $0.setConsent(analytics: analytics, ads: ads) }
    }

    /// Çıxış: istifadəçi silinir, yeni anonim ID və sessiya yaradılır.
    public static func reset() {
        post(persistNow: true) { $0.reset() }
    }

    /// Növbəni dərhal göndərir.
    public static func flush() {
        post { $0.flush(force: true) }
    }

    /// Tətbiq keçidlə açılanda çağırılır (`application(_:open:options:)`, `scene(_:openURLContexts:)`
    /// və ya universal link). iOS-da keçidləri SDK özü tuta bilmir.
    public static func handleDeepLink(_ url: URL) {
        let text = url.absoluteString
        post { $0.onDeepLink(text) }
    }

    /// Cari anonim ID. SDK başlamayıbsa və ya razılıq yoxdursa nil.
    public static var anonymousId: String? {
        lock.lock()
        defer { lock.unlock() }
        return cachedAnonymousId
    }

    // MARK: - Daxili

    private static func setAnonymousId(_ value: String?) {
        lock.lock()
        cachedAnonymousId = value
        lock.unlock()
    }

    private static func post(persistNow: Bool = false, _ call: @escaping (Core) -> Void) {
        lock.lock()
        guard let current = core else {
            // initialize hələ bitməyib: çağırış yadda saxlanır (məhdud sayda).
            if pending.count < maxPending { pending.append(call) }
            lock.unlock()
            return
        }
        let events = fileQueue
        lock.unlock()
        queue.async {
            call(current)
            setAnonymousId(current.anonymousId)
            if persistNow { events?.persist() } else { events?.persistSoon() }
        }
    }

    private static func schedule(_ core: Core, _ events: FileQueue) {
        // Konfiq dəyişə bilər, ona görə növbəti fasilə hər dəfə yenidən oxunur.
        let interval = DispatchTimeInterval.milliseconds(Int(core.flushIntervalMs))
        queue.asyncAfter(deadline: .now() + interval) {
            core.flush()
            events.persist()
            schedule(core, events)
        }
    }

    private static func observeLifecycle() {
        #if canImport(UIKit) && !os(watchOS)
        let center = NotificationCenter.default
        let active = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            post { $0.onForeground() }
        }
        let background = center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            // Növbənin göndərilməsi və diskə yazılması üçün sistemdən qısa əlavə vaxt istənilir.
            var task = UIBackgroundTaskIdentifier.invalid
            let finish = {
                if task != .invalid {
                    UIApplication.shared.endBackgroundTask(task)
                    task = .invalid
                }
            }
            task = UIApplication.shared.beginBackgroundTask(withName: "az.smartbee.pixel.flush") {
                DispatchQueue.main.async { finish() }
            }
            lock.lock()
            let current = core
            let events = fileQueue
            lock.unlock()
            queue.async {
                current?.onBackground()
                events?.persist()
                DispatchQueue.main.async { finish() }
            }
        }
        lock.lock()
        observers = [active, background]
        lock.unlock()
        // SDK gec başladıla bilər (məsələn React Native / Flutter-dən): tətbiq artıq aktivdirsə
        // didBecomeActive bir daha gəlməyəcək, ona görə vəziyyət indi oxunur (yalnız əsas axında).
        DispatchQueue.main.async {
            if UIApplication.shared.applicationState == .active {
                post { $0.onForeground() }
            }
        }
        #endif
    }
}
