#!/usr/bin/env bash
# Type-checks the iOS bridge files of the React Native and Flutter wrappers together with the native core.
# The React / Flutter modules are represented by minimal stand-ins (mobile/ci-stubs). Requires macOS.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
sdks="$(dirname "$here")"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

for module in React Flutter; do
  swiftc -emit-module -parse-as-library -module-name "$module" -emit-module-path "$out/$module.swiftmodule" "$here/$module.swift"
done

echo "React Native iOS bridge"
swiftc -typecheck -I "$out" -module-name smartbee_pixel_rn \
  "$sdks"/react-native/ios/Core/*.swift "$sdks"/react-native/ios/SmartBeePixelBridge.swift

echo "Flutter iOS plugin"
swiftc -typecheck -I "$out" -module-name smartbee_pixel_flutter \
  "$sdks"/flutter/ios/Classes/Core/*.swift "$sdks"/flutter/ios/Classes/SmartBeePixelPlugin.swift

echo "type check passed"
