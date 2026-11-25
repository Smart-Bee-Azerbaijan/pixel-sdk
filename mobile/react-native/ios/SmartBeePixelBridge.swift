import Foundation
import React

/// Forwards JavaScript calls to the native SDK. It holds no logic of its own.
@objc(SmartBeePixel)
final class SmartBeePixelBridge: NSObject {
    // Process-wide on purpose: a JavaScript reload creates a new bridge instance, but must not report the launch link again.
    private static let stateLock = NSLock()
    private static var debugEnabled = false
    private static var lastInitialLink: String?

    @objc static func requiresMainQueueSetup() -> Bool {
        return false
    }

    private static func isDebug() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return debugEnabled
    }

    /// `URL(string:)` rejects text with spaces or non-ASCII characters; such a link is percent-encoded and tried again.
    private static func parseLink(_ text: String) -> URL? {
        if let url = URL(string: text) { return url }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: "#%")
        if let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed), let url = URL(string: encoded) {
            return url
        }
        return nil
    }

    /// A JavaScript boolean only: a number (`1`) also arrives as an `NSNumber` and `as? Bool` would accept it.
    private static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func forward(_ text: String) {
        if text.isEmpty { return }
        if let url = parseLink(text) {
            SmartBee.handleDeepLink(url)
        } else if isDebug() {
            NSLog("[SmartBee] React Native bridge: the deep link is not a valid URL, ignored")
        }
    }

    @objc(start:options:)
    func start(_ key: String, options: NSDictionary?) {
        var config = SmartBeeOptions()
        // Consent fails closed: a purpose that is missing or not a boolean (the number 1 included) is treated as
        // denied, and so is a `consent` value that is present but is not an object. Only an absent or null `consent`
        // means "not stated".
        if let raw = options?["consent"], !(raw is NSNull) {
            if let consent = raw as? [String: Any] {
                let analytics = SmartBeePixelBridge.strictBool(consent["analytics"]) ?? false
                let ads = SmartBeePixelBridge.strictBool(consent["ads"]) ?? false
                config.consent = SmartBeeConsent(analytics: analytics, ads: ads)
            } else {
                config.consent = SmartBeeConsent(analytics: false, ads: false)
            }
        }
        if let debug = options?["debug"] as? Bool { config.debug = debug }
        if let autoEvents = options?["autoEvents"] as? Bool { config.autoEvents = autoEvents }
        if let endpoint = options?["endpoint"] as? String, !endpoint.isEmpty { config.endpoint = endpoint }
        if let collect = options?["collectAdvertisingId"] as? Bool { config.collectAdvertisingId = collect }
        config.wrapper = "react-native"
        config.wrapperVersion = options?["wrapperVersion"] as? String
        SmartBeePixelBridge.stateLock.lock()
        SmartBeePixelBridge.debugEnabled = config.debug
        SmartBeePixelBridge.stateLock.unlock()
        SmartBee.initialize(key: key, options: config)
    }

    @objc(track:props:eventId:)
    func track(_ name: String, props: NSDictionary?, eventId: String?) {
        SmartBee.track(name, props: props as? [String: Any], eventId: eventId)
    }

    @objc(identify:traits:)
    func identify(_ userId: String, traits: NSDictionary?) {
        SmartBee.identify(userId, traits: traits as? [String: Any])
    }

    @objc(screen:props:)
    func screen(_ name: String, props: NSDictionary?) {
        SmartBee.screen(name, props: props as? [String: Any])
    }

    @objc(setConsent:ads:)
    func setConsent(_ analytics: Bool, ads: Bool) {
        SmartBee.setConsent(SmartBeeConsent(analytics: analytics, ads: ads))
    }

    @objc func reset() {
        SmartBee.reset()
    }

    @objc func flush() {
        SmartBee.flush()
    }

    /// A link delivered to the running app (the `url` event of Linking) or reported by the app itself.
    @objc(handleDeepLink:)
    func handleDeepLink(_ url: String) {
        SmartBeePixelBridge.forward(url)
    }

    /// The launch link (`Linking.getInitialURL()`). JavaScript asks for it again after every reload and the answer
    /// stays the same for as long as the process lives: the same launch link is reported once per process.
    @objc(handleInitialLink:)
    func handleInitialLink(_ url: String) {
        SmartBeePixelBridge.stateLock.lock()
        let repeated = SmartBeePixelBridge.lastInitialLink == url
        if !repeated { SmartBeePixelBridge.lastInitialLink = url }
        SmartBeePixelBridge.stateLock.unlock()
        if !repeated { SmartBeePixelBridge.forward(url) }
    }

    @objc(getAnonymousId:rejecter:)
    func getAnonymousId(_ resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
        resolve(SmartBee.anonymousId)
    }
}
