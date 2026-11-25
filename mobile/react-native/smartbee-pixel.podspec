require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name         = 'smartbee-pixel'
  s.version      = package['version']
  s.summary      = package['description']
  s.homepage     = 'https://smartbee.az'
  s.license      = { :type => 'MIT', :file => 'LICENSE' }
  s.author       = 'SmartBee'
  s.platform     = :ios, '13.0'
  s.swift_version = '5.7'
  s.source       = { :git => 'https://github.com/Smart-Bee-Azerbaijan/pixel-sdk.git', :tag => "v#{s.version}" }
  # ios/Core is a copy of the native core (mobile/sync-native.mjs).
  s.source_files = 'ios/**/*.{swift,m}'
  s.resource_bundles = { 'SmartBeePixelPrivacy' => ['ios/Resources/PrivacyInfo.xcprivacy'] }
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  # For the advertising identifier (IDFA). AppTrackingTransparency exists only since iOS 14: it is weak-linked so
  # that an app does not crash at launch on iOS 13 because of the missing framework (the code calls it under `#available`).
  s.frameworks = 'AdSupport'
  s.weak_frameworks = 'AppTrackingTransparency'
  s.dependency 'React-Core'
end
