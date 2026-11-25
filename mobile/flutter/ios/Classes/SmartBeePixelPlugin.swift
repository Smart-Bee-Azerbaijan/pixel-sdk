import Flutter
import Foundation

/// Forwards Dart calls to the native SDK. It holds no logic of its own.
public class SmartBeePixelPlugin: NSObject, FlutterPlugin {
    /// The `debug` option of the last `start` call. Method calls arrive on the main thread.
    private var debug = false

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "az.smartbee/pixel", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(SmartBeePixelPlugin(), channel: channel)
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

    /// A Dart `bool` only: a number (`1`) also arrives as an `NSNumber` and `as? Bool` would accept it.
    private static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        // Answers `true` when the native SDK was asked to start, `false` when the call could not be made.
        case "start":
            if let key = args["key"] as? String {
                var options = SmartBeeOptions()
                // Consent fails closed: a purpose that is missing or not a boolean (the number 1 included) is treated
                // as denied, and so is a `consent` value that is present but is not a map. Only an absent or null
                // `consent` means "not stated".
                if let raw = args["consent"], !(raw is NSNull) {
                    if let consent = raw as? [String: Any] {
                        let analytics = SmartBeePixelPlugin.strictBool(consent["analytics"]) ?? false
                        let ads = SmartBeePixelPlugin.strictBool(consent["ads"]) ?? false
                        options.consent = SmartBeeConsent(analytics: analytics, ads: ads)
                    } else {
                        options.consent = SmartBeeConsent(analytics: false, ads: false)
                    }
                }
                if let debug = args["debug"] as? Bool { options.debug = debug }
                if let autoEvents = args["autoEvents"] as? Bool { options.autoEvents = autoEvents }
                if let endpoint = args["endpoint"] as? String, !endpoint.isEmpty { options.endpoint = endpoint }
                if let collect = args["collectAdvertisingId"] as? Bool { options.collectAdvertisingId = collect }
                options.wrapper = "flutter"
                options.wrapperVersion = args["wrapperVersion"] as? String
                debug = options.debug
                SmartBee.initialize(key: key, options: options)
                result(true)
            } else {
                result(false)
            }
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
        // Consent fails closed here too: a missing purpose is treated as denied.
        case "setConsent":
            let analytics = SmartBeePixelPlugin.strictBool(args["analytics"]) ?? false
            let ads = SmartBeePixelPlugin.strictBool(args["ads"]) ?? false
            SmartBee.setConsent(SmartBeeConsent(analytics: analytics, ads: ads))
            result(nil)
        case "reset":
            SmartBee.reset()
            result(nil)
        case "flush":
            SmartBee.flush()
            result(nil)
        case "handleDeepLink":
            if let text = args["url"] as? String, !text.isEmpty {
                if let url = SmartBeePixelPlugin.parseLink(text) {
                    SmartBee.handleDeepLink(url)
                } else if debug {
                    NSLog("[SmartBee] Flutter plugin: the deep link is not a valid URL, ignored")
                }
            }
            result(nil)
        case "getAnonymousId":
            result(SmartBee.anonymousId)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
