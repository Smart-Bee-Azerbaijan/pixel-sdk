// A minimal stand-in for React Native's iOS module. It exists only to type-check the bridge file in CI:
// the Swift syntax and the calls into the native SDK are checked without building a full React Native app.
// It does not guarantee compatibility with the real React module.

public typealias RCTPromiseResolveBlock = (Any?) -> Void
public typealias RCTPromiseRejectBlock = (String?, String?, Error?) -> Void
