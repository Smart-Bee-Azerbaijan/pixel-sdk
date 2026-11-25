#!/usr/bin/env bash
# React Native və Flutter örtüklərinin iOS körpü fayllarını nativ nüvə ilə birlikdə tip yoxlamasından keçirir.
# React / Flutter modulları minimal əvəzlərlə (mobile/ci-stubs) təmsil olunur. macOS tələb edir.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
sdks="$(dirname "$here")"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

for module in React Flutter; do
  swiftc -emit-module -parse-as-library -module-name "$module" -emit-module-path "$out/$module.swiftmodule" "$here/$module.swift"
done

echo "React Native iOS körpüsü"
swiftc -typecheck -I "$out" -module-name smartbee_pixel_rn \
  "$sdks"/react-native/ios/Core/*.swift "$sdks"/react-native/ios/SmartBeePixelBridge.swift

echo "Flutter iOS plagini"
swiftc -typecheck -I "$out" -module-name smartbee_pixel_flutter \
  "$sdks"/flutter/ios/Classes/Core/*.swift "$sdks"/flutter/ios/Classes/SmartBeePixelPlugin.swift

echo "tip yoxlaması uğurludur"
