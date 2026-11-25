# SmartBee Pixel — Flutter SDK

A thin wrapper over the native Android and iOS SDKs. It holds no logic of its own: every call is forwarded to the native core, a copy of which ships inside this plugin.

## Install

The package is **not on pub.dev**. The only legitimate source is this repository: a `smartbee_pixel` package on a registry is not ours unless the README of this repository says it has been published. Use a git dependency pinned to a commit:

```yaml
dependencies:
  smartbee_pixel:
    git:
      url: https://github.com/Smart-Bee-Azerbaijan/pixel-sdk.git
      path: mobile/flutter
      ref: <full commit SHA>
```

Do not add the native SDK (`az.smartbee:pixel` or the `SmartBeePixel` Swift package) to the same app: this plugin already contains it.

## Usage

```dart
import 'package:smartbee_pixel/smartbee_pixel.dart';

final started = await SmartBee.init('YOUR_KEY');
SmartBee.track('Purchase', props: {'value': 250, 'currency': 'AZN', 'order_id': 'A-1001'}, eventId: 'order:A-1001');
SmartBee.identify('user-42', traits: {'email': 'user@example.com'});   // the e-mail is hashed on the device
SmartBee.screen('Cart');
SmartBee.setConsent(analytics: true, ads: false);
SmartBee.reset();
```

## API

| Method | Notes |
|---|---|
| `SmartBee.init(String key, {SmartBeeConsent? consent, bool debug, bool autoEvents, String? endpoint, bool collectAdvertisingId})` | `Future<bool>` |
| `SmartBee.track(String name, {Map<String, Object?>? props, String? eventId})` | |
| `SmartBee.identify(String userId, {Map<String, Object?>? traits})` | |
| `SmartBee.screen(String name, {Map<String, Object?>? props})` | |
| `SmartBee.setConsent({required bool analytics, required bool ads})` · `SmartBee.setConsentValue(SmartBeeConsent)` | |
| `SmartBee.reset()` · `SmartBee.flush()` | |
| `SmartBee.handleDeepLink(String url)` | |
| `SmartBee.getAnonymousId()` | `Future<String?>` |
| `SmartBee.sdkVersion` · `SmartBee.version` | The package version; the native cores inside it are released together with it. |

- **Initialise in one place**, once, as early as possible. `init` completes with `true` when the plugin accepted the call and handed it to the native SDK (plugin registered, key well-formed) and with `false` otherwise; it never throws. `true` is not a statement about the native SDK itself: for example, in a process of a multi-process Android app that is not the main process the call is accepted but the SDK stays disabled there. A repeated `init` does not restart the SDK or change the key: it is passed on to the native SDK, which applies only its more restrictive options (purposes set to `false` in `consent`, `collectAdvertisingId: false`), and a warning is logged.
- **`await init()` does not mean "ready".** The native SDK starts asynchronously (and on a first launch without a stated consent it waits for the remote configuration), so `getAnonymousId()` may still complete with `null` right after `init`. Calls made in the meantime are queued by the native SDK and are not lost.
- **Consent fails closed.** `SmartBeeConsent` requires both purposes. For a loosely typed source (for example the answer of a consent platform) use `SmartBeeConsent.fromMap(map)`: a purpose that is missing or is not a `bool` becomes `false`. The native plugins apply the same rule.
- **Nothing throws.** Errors are swallowed; in debug builds they are printed with `debugPrint`. A call with an empty name is ignored. When the native plugin is not registered, one warning is printed and every call is a no-op.
- `ScreenView` is not captured automatically: call `SmartBee.screen()` from a `NavigatorObserver`.
- **Deep links** are not captured automatically on either platform: pass the URL (for example from the `app_links` package, both the launch link and links delivered to the running app) to `SmartBee.handleDeepLink(url)`, once per link. The plugin does not de-duplicate: if your link source hands out the launch link again (after a hot restart, or when Android recreates the Activity after the process was killed), skip the repeat in your app. Only `http`, `https` and `scheme://…` URLs up to 4096 characters are counted.

## Advertising identifier (GAID / IDFA)

Collected and sent only while advertising consent (`consent.ads`) is given; when consent is withdrawn it is also removed from events that have not been sent yet.

- **Android (GAID):** the SDK does not bring Google's library itself. Add it to the app's `android/app/build.gradle`: `implementation 'com.google.android.gms:play-services-ads-identifier:18.2.0'` (without the library the GAID is simply not collected). The plugin adds the `com.google.android.gms.permission.AD_ID` permission to the manifest; the collection of the advertising ID must be declared in Google Play's "Data safety" form.
- **iOS (IDFA):** `Info.plist` must contain `NSUserTrackingUsageDescription` and the app must request the ATT permission itself (`ATTrackingManager.requestTrackingAuthorization`, for example with the `app_tracking_transparency` package); the SDK never shows the permission prompt and sends the IDFA (and the vendor identifier) only when permission was granted.
- **Turning it off:** `SmartBee.init(key, collectAdvertisingId: false)` — the identifier is never read. To remove the Android permission as well, add this to the app's `AndroidManifest.xml` (`<manifest>` must declare `xmlns:tools="http://schemas.android.com/tools"`):

```xml
<uses-permission android:name="com.google.android.gms.permission.AD_ID" tools:node="remove" />
```

## Supported versions

| | Supported | How it is verified in CI |
|---|---|---|
| Flutter / Dart | Flutter 3.50 and newer, Dart 3.14 and newer (`environment` in `pubspec.yaml`) | `flutter analyze`, `flutter test` and a debug APK of an app that uses the plugin, on Flutter 3.50.1 |
| Android | `minSdk` 21 (the app's own `minSdkVersion` applies when it is higher) | the APK build above |
| iOS | 13.0 | the Swift plugin is type-checked against a minimal stub of the Flutter module; no iOS app is built |

Older Flutter releases may well work, but they are not built in CI, so they are not claimed.

## Status

- The iOS plugin is only type-checked against stubs; no example app is built for iOS in CI.
- There is no `example/` app in the package yet.
- Not yet verified on physical devices.

## Development

- `android/src/main/kotlin/az/smartbee/pixel/*.kt` and `ios/Classes/Core/*.swift` are copies of the native core; do not edit them, run `node mobile/sync-native.mjs` instead.
- Tests: `flutter analyze && flutter test`.
