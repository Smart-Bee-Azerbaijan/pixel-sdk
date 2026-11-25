# SmartBee Pixel — React Native SDK

A thin wrapper over the native Android and iOS SDKs. It holds no logic of its own: every call is forwarded to the native core, a copy of which ships inside this package.

## Install

The package is **not on npm**. The only legitimate source is this repository: an `@smartbee/pixel` (or similarly named) package on a registry is not ours unless the README of this repository says it has been published. Build the tarball from a clone and install that:

```sh
git clone https://github.com/Smart-Bee-Azerbaijan/pixel-sdk.git
cd pixel-sdk/mobile/react-native && npm pack        # creates smartbee-pixel-1.0.0.tgz
cd /path/to/your/app && npm install /path/to/pixel-sdk/mobile/react-native/smartbee-pixel-1.0.0.tgz
cd ios && pod install
```

The native code is linked by React Native autolinking (the podspec in the package root, `android/build.gradle` and the `SmartBeePixelPackage` class are found by the React Native CLI); no `react-native.config.js` or manual linking is needed. Do not add the native SDK (`az.smartbee:pixel` or the `SmartBeePixel` Swift package) to the same app: this package already contains it.

## Usage

```ts
import SmartBee from '@smartbee/pixel';

const started = await SmartBee.init('YOUR_KEY');
SmartBee.track('Purchase', { value: 250, currency: 'AZN', order_id: 'A-1001' }, { eventId: 'order:A-1001' });
SmartBee.identify('user-42', { email: 'user@example.com' });   // the e-mail is hashed on the device
SmartBee.screen('Cart');
SmartBee.setConsent({ analytics: true, ads: false });
SmartBee.reset();
```

## API

| Method | Notes |
|---|---|
| `init(key, options?): Promise<boolean>` | Options: `consent`, `debug`, `autoEvents`, `endpoint`, `collectAdvertisingId`. |
| `track(name, props?, { eventId }?)` | `eventId`: a string; a finite number is sent as its decimal string. |
| `identify(userId, traits?)` | `userId`: a non-empty string; a finite number is sent as its decimal string. |
| `screen(name, props?)` | |
| `setConsent({ analytics, ads })` | |
| `reset()` · `flush()` | |
| `handleDeepLink(url)` | |
| `getAnonymousId(): Promise<string \| null>` | |
| `sdkVersion` · `VERSION` (named export) | The package version; the native cores inside it are released together with it. |

- **Initialise in one place**, once, as early as possible. `init` resolves to `true` when the wrapper accepted the call and handed it to the native SDK (native module present, key well-formed) and to `false` otherwise; it never rejects. `true` is not a statement about the native SDK itself: for example, in a process of a multi-process Android app that is not the main process the call is accepted but the SDK stays disabled there. A repeated `init` does not restart the SDK or change the key: it is passed on to the native SDK, which applies only its more restrictive options (purposes set to `false` in `consent`, `collectAdvertisingId: false`), and a warning is logged.
- **`await init()` does not mean "ready".** The native SDK starts asynchronously (and on a first launch without a stated consent it waits for the remote configuration), so `getAnonymousId()` may still resolve to `null` right after `init`. Calls made in the meantime are queued by the native SDK and are not lost.
- **Consent fails closed.** In `init({ consent })` and in `setConsent`, a purpose that is missing or is not a boolean is treated as `false`, with a warning: `{ analytics: true }` means `{ analytics: true, ads: false }`. `setConsent` without an object is ignored.
- **Nothing throws.** Every method swallows errors; in development builds (`__DEV__`) swallowed errors and argument mistakes (a name that is not a non-empty string, props that are not a plain object) are reported with `console.warn`. A call with an invalid name is ignored.
- **No native module** (Expo Go, web, Jest): one warning is logged and every call is a no-op; `init` resolves to `false`.
- `ScreenView` is not captured automatically: call `SmartBee.screen()` from your navigation library's state-change listener.
- **Deep links** are forwarded automatically on both platforms from React Native's `Linking` module (on iOS this needs the standard `RCTLinkingManager` set-up in `AppDelegate`). The launch link is reported once: a JavaScript reload does not report it again, and on Android neither does an Activity that the system recreates with its old intent (after a rotation, or when it is restored after the process was killed; for the latter a SHA-256 of the last reported launch link is kept on the device while analytics consent is given). With `autoEvents: false` links are not forwarded automatically; `SmartBee.handleDeepLink(url)` works in both modes, for links that reach the app another way. Only `http`, `https` and `scheme://…` URLs up to 4096 characters are counted.

## Testing your app with Jest

The package is plain CommonJS, so Jest loads it without extra `transformIgnorePatterns`. Without the native module it only logs one warning; to assert calls, use the bundled mock:

```js
jest.mock('@smartbee/pixel', () => require('@smartbee/pixel/jest/mock'));

import SmartBee from '@smartbee/pixel';
expect(SmartBee.track).toHaveBeenCalledWith('Purchase', expect.any(Object), { eventId: 'order:A-1001' });
```

## Advertising identifier (GAID / IDFA)

Collected and sent only while advertising consent (`consent.ads`) is given; when consent is withdrawn it is also removed from events that have not been sent yet.

- **Android (GAID):** the SDK does not bring Google's library itself. Add it to the app's `android/app/build.gradle`: `implementation 'com.google.android.gms:play-services-ads-identifier:18.2.0'` (without the library the GAID is simply not collected). The package adds the `com.google.android.gms.permission.AD_ID` permission to the manifest; the collection of the advertising ID must be declared in Google Play's "Data safety" form.
- **iOS (IDFA):** `Info.plist` must contain `NSUserTrackingUsageDescription` and the app must request the ATT permission itself (`ATTrackingManager.requestTrackingAuthorization`); the SDK never shows the permission prompt and sends the IDFA (and the vendor identifier) only when permission was granted.
- **Turning it off:** `SmartBee.init(key, { collectAdvertisingId: false })` — the identifier is never read. To remove the Android permission as well, add this to the app's `AndroidManifest.xml` (`<manifest>` must declare `xmlns:tools="http://schemas.android.com/tools"`):

```xml
<uses-permission android:name="com.google.android.gms.permission.AD_ID" tools:node="remove" />
```

## Supported versions

| | Supported | How it is verified in CI |
|---|---|---|
| React Native | 0.76 and newer (`peerDependencies`) | the Android bridge is compiled against React Native 0.76.9 |
| Android | `minSdk` 21 as a fallback; the app's `rootProject.ext` values (`minSdkVersion`, `compileSdkVersion`) win, and React Native itself requires a higher `minSdk` | as above |
| iOS | 13.0 in the podspec (React Native itself requires a newer iOS) | the Swift bridge is type-checked against a minimal stub of the React module |
| JavaScript | CommonJS, no build step | Node unit tests |

## Status

- The bridge is a classic native module (`RCTBridgeModule` / `ReactContextBaseJavaModule`). There is **no TurboModule spec or codegen configuration yet**. On the New Architecture the module is expected to load through React Native's interop layer for legacy modules; this has not been verified in CI.
- The iOS bridge is only type-checked against stubs; no example app is built for iOS in CI, and `pod lib lint` is not run.
- Not yet verified on physical devices.

## Development

- `android/src/main/java/az/smartbee/pixel/*.kt` and `ios/Core/*.swift` are copies of the native core; do not edit them, run `node mobile/sync-native.mjs` instead.
- Tests: `node --test`. Building the Android bridge: `./gradlew :rn-bridge:assembleDebug` in `mobile/android`.
