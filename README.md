# SmartBee Pixel SDK

Open-source client SDKs for SmartBee Pixel: Android (Kotlin), iOS (Swift), React Native and Flutter.
All SDKs speak the same `/v1` protocol (see [spec/](spec/)) and share one public API.

Full integration guide: **https://c.cdnsb.net/docs**

## Install

| Platform | How |
|---|---|
| iOS (Swift Package) | `.package(url: "https://github.com/Smart-Bee-Azerbaijan/pixel-sdk.git", from: "1.0.0")`, product `SmartBeePixel` |
| Android | JitPack: `implementation("com.github.Smart-Bee-Azerbaijan:pixel-sdk:1.+")` |
| Flutter | git dependency, see below |
| React Native | `@smartbee/pixel` (npm release pending) |

```yaml
# pubspec.yaml
dependencies:
  smartbee_pixel:
    git:
      url: https://github.com/Smart-Bee-Azerbaijan/pixel-sdk.git
      path: mobile/flutter
      ref: v1.0.0
```

## Layout

- `mobile/android`: Kotlin SDK (no runtime dependencies)
- `mobile/ios`: Swift SDK (`Package.swift` lives at the repository root)
- `mobile/react-native`, `mobile/flutter`: thin wrappers that vendor the native cores (`mobile/sync-native.mjs`)
- `spec`: protocol, JSON schemas and shared test vectors

## Status

Unit-tested on CI on every push. The SDKs have not yet been validated on physical devices; treat 1.0.x as an early release.

## License

MIT
