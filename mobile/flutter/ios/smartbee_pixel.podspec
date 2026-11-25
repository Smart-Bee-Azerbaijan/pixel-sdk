Pod::Spec.new do |s|
  s.name             = 'smartbee_pixel'
  s.version          = '1.0.0'
  s.summary          = 'SmartBee Pixel SDK for Flutter.'
  s.homepage         = 'https://smartbee.az'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = 'SmartBee'
  s.source           = { :path => '.' }
  # Classes/Core is a copy of the native core (mobile/sync-native.mjs).
  s.source_files     = 'Classes/**/*.swift'
  s.resource_bundles = { 'SmartBeePixelPrivacy' => ['Resources/PrivacyInfo.xcprivacy'] }
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.7'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  # For the advertising identifier (IDFA). AppTrackingTransparency exists only since iOS 14: it is weak-linked so
  # that an app does not crash at launch on iOS 13 because of the missing framework (the code calls it under `#available`).
  s.frameworks = 'AdSupport'
  s.weak_frameworks = 'AppTrackingTransparency'
end
