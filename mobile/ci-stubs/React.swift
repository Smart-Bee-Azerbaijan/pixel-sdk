// React Native-in iOS modulunun minimal əvəzi. Yalnız CI-da körpü faylının tip yoxlaması üçündür:
// tam React Native tətbiqi yığmadan Swift sintaksisi və nativ SDK-ya çağırışlar yoxlanır.
// Real React modulu ilə uyğunluğu təmin etmir.

public typealias RCTPromiseResolveBlock = (Any?) -> Void
public typealias RCTPromiseRejectBlock = (String?, String?, Error?) -> Void
