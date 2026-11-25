Pod::Spec.new do |s|
  s.name             = 'smartbee_pixel'
  s.version          = '1.0.0'
  s.summary          = 'SmartBee Pixel SDK for Flutter.'
  s.homepage         = 'https://smartbee.az'
  s.license          = { :type => 'MIT' }
  s.author           = 'SmartBee'
  s.source           = { :path => '.' }
  # Classes/Core nativ nüvənin nüsxəsidir (mobile/sync-native.mjs).
  s.source_files     = 'Classes/**/*.swift'
  s.resource_bundles = { 'SmartBeePixelPrivacy' => ['Resources/PrivacyInfo.xcprivacy'] }
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.7'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
