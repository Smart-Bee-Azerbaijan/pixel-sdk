// Flutter-in iOS modulunun minimal əvəzi. Yalnız CI-da plagin faylının tip yoxlaması üçündür:
// tam Flutter tətbiqi yığmadan Swift sintaksisi və nativ SDK-ya çağırışlar yoxlanır.
// Real Flutter modulu ilə uyğunluğu təmin etmir.

import Foundation

public typealias FlutterResult = (Any?) -> Void

public let FlutterMethodNotImplemented: NSObject = NSObject()

open class FlutterMethodCall: NSObject {
    public var method: String = ""
    public var arguments: Any?
}

public protocol FlutterBinaryMessenger: NSObjectProtocol {}

open class FlutterMethodChannel: NSObject {
    public init(name: String, binaryMessenger: FlutterBinaryMessenger) {}
}

public protocol FlutterPlugin: NSObjectProtocol {
    static func register(with registrar: FlutterPluginRegistrar)
}

public protocol FlutterPluginRegistrar: NSObjectProtocol {
    func messenger() -> FlutterBinaryMessenger
    func addMethodCallDelegate(_ delegate: FlutterPlugin, channel: FlutterMethodChannel)
}
