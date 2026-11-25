// A minimal stand-in for Flutter's iOS module. It exists only to type-check the plugin file in CI:
// the Swift syntax and the calls into the native SDK are checked without building a full Flutter app.
// It does not guarantee compatibility with the real Flutter module.

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
