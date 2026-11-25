import Foundation
import React

/// JS çağırışlarını nativ SDK-ya ötürür. Öz məntiqi yoxdur.
@objc(SmartBeePixel)
final class SmartBeePixelBridge: NSObject {
    @objc static func requiresMainQueueSetup() -> Bool {
        return false
    }

    @objc(start:options:)
    func start(_ key: String, options: NSDictionary?) {
        var config = SmartBeeOptions()
        if let consent = options?["consent"] as? [String: Any],
           let analytics = consent["analytics"] as? Bool, let ads = consent["ads"] as? Bool {
            config.consent = Consent(analytics: analytics, ads: ads)
        }
        if let debug = options?["debug"] as? Bool { config.debug = debug }
        if let autoEvents = options?["autoEvents"] as? Bool { config.autoEvents = autoEvents }
        if let endpoint = options?["endpoint"] as? String, !endpoint.isEmpty { config.endpoint = endpoint }
        config.wrapper = "react-native"
        config.wrapperVersion = options?["wrapperVersion"] as? String
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
        SmartBee.setConsent(analytics: analytics, ads: ads)
    }

    @objc func reset() {
        SmartBee.reset()
    }

    @objc func flush() {
        SmartBee.flush()
    }

    /// JS tərəfi React Native-in Linking modulundan aldığı keçidi ötürür.
    @objc(handleDeepLink:)
    func handleDeepLink(_ url: String) {
        if let parsed = URL(string: url) { SmartBee.handleDeepLink(parsed) }
    }

    @objc(getAnonymousId:rejecter:)
    func getAnonymousId(_ resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
        resolve(SmartBee.anonymousId)
    }
}
