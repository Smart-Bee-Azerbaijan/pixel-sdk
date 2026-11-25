import Flutter
import Foundation

/// Dart çağırışlarını nativ SDK-ya ötürür. Öz məntiqi yoxdur.
public class SmartBeePixelPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "az.smartbee/pixel", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(SmartBeePixelPlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "start":
            if let key = args["key"] as? String {
                var options = SmartBeeOptions()
                if let consent = args["consent"] as? [String: Any],
                   let analytics = consent["analytics"] as? Bool, let ads = consent["ads"] as? Bool {
                    options.consent = Consent(analytics: analytics, ads: ads)
                }
                if let debug = args["debug"] as? Bool { options.debug = debug }
                if let autoEvents = args["autoEvents"] as? Bool { options.autoEvents = autoEvents }
                if let endpoint = args["endpoint"] as? String, !endpoint.isEmpty { options.endpoint = endpoint }
                options.wrapper = "flutter"
                options.wrapperVersion = args["wrapperVersion"] as? String
                SmartBee.initialize(key: key, options: options)
            }
            result(nil)
        case "track":
            if let name = args["name"] as? String {
                SmartBee.track(name, props: args["props"] as? [String: Any], eventId: args["eventId"] as? String)
            }
            result(nil)
        case "identify":
            if let userId = args["userId"] as? String {
                SmartBee.identify(userId, traits: args["traits"] as? [String: Any])
            }
            result(nil)
        case "screen":
            if let name = args["name"] as? String {
                SmartBee.screen(name, props: args["props"] as? [String: Any])
            }
            result(nil)
        case "setConsent":
            if let analytics = args["analytics"] as? Bool, let ads = args["ads"] as? Bool {
                SmartBee.setConsent(analytics: analytics, ads: ads)
            }
            result(nil)
        case "reset":
            SmartBee.reset()
            result(nil)
        case "flush":
            SmartBee.flush()
            result(nil)
        case "handleDeepLink":
            if let text = args["url"] as? String, let url = URL(string: text) {
                SmartBee.handleDeepLink(url)
            }
            result(nil)
        case "getAnonymousId":
            result(SmartBee.anonymousId)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
