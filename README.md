# SmartBee Pixel SDK

[![CI](https://github.com/Smart-Bee-Azerbaijan/pixel-sdk/actions/workflows/ci.yaml/badge.svg)](https://github.com/Smart-Bee-Azerbaijan/pixel-sdk/actions/workflows/ci.yaml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Open-source client SDKs for **SmartBee Pixel**, an event collection service for websites and mobile apps.

| Platform | Language | Minimum version | Package |
|---|---|---|---|
| Web | JavaScript snippet | any modern browser | served from `c.cdnsb.net` |
| Android | Kotlin, Java | Android 5.0 (API 21) | `az.smartbee:pixel` |
| iOS | Swift | iOS 13 | Swift Package `SmartBeePixel` |
| Flutter | Dart | Flutter 3.19 | `smartbee_pixel` |
| React Native | TypeScript / JavaScript | React Native 0.72 | `@smartbee/pixel` |

All SDKs share one public API and speak the same `/v1` protocol, documented in [`spec/`](spec/).
A step-by-step integration guide (in Azerbaijani) with a platform switcher lives at **https://c.cdnsb.net/docs**, and a live playground at **https://c.cdnsb.net/demo**.

## Contents

- [How it works](#how-it-works)
- [Install](#install)
- [Quick start](#quick-start)
- [Tracking events](#tracking-events)
- [Identifying users](#identifying-users)
- [Screens and deep links](#screens-and-deep-links)
- [Consent](#consent)
- [Automatic events](#automatic-events)
- [Standard events](#standard-events)
- [Privacy](#privacy)
- [Remote configuration](#remote-configuration)
- [Delivery, limits and retries](#delivery-limits-and-retries)
- [Versioning and updates](#versioning-and-updates)
- [Debugging](#debugging)
- [Repository layout](#repository-layout)
- [Development](#development)
- [Status](#status)
- [License](#license)

## How it works

1. **Your site or app** records events through the snippet or an SDK. Email and phone are hashed on the device.
2. Events are queued and sent in batches to **`https://c.cdnsb.net/v1/e`**, where the source, format and limits are checked.
3. Accepted events are stored once (duplicates are dropped).

Every website and every app is a separate **source** with its own **key** (8 to 16 lowercase letters and digits).
The key is not a secret. The server accepts it only together with the registered website domain (web) or the registered package name / bundle ID (mobile), so a key copied into another app or site is rejected.

Android and iOS are separate sources: a cross-platform app uses two keys.

## Install

### Web

Add the snippet inside `<head>` on every page and replace `KEY` with your source key. Nothing else is required: the key is part of the script URL and the tracker starts by itself.

```html
<script>
!function(w,d,n,u,t,s){if(w[n])return;t=w[n]=function(){t.q.push(arguments)};t.q=[];t.l=+new Date;t.v=1;
s=d.createElement('script');s.async=1;s.src=u;(d.head||d.documentElement).appendChild(s)
}(window,document,'smartbee','https://c.cdnsb.net/v1/KEY.js');
</script>
```

If the site uses a Content-Security-Policy, allow `https://c.cdnsb.net` in `script-src` and `connect-src`, and give the inline snippet your page nonce.

### Android (Kotlin and Java)

The package is published to the SmartBee Maven repository.

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://c.cdnsb.net/maven") }
    }
}

// app/build.gradle.kts
dependencies {
    implementation("az.smartbee:pixel:1.+")
}
```

`1.+` picks up the latest 1.x release on every build; write `1.0.0` to pin a version.
The SDK has no runtime dependencies and needs only the `INTERNET` permission, which it declares itself.

### iOS (Swift Package Manager)

In Xcode choose **File → Add Package Dependencies…**, enter the repository URL and select **Up to Next Major Version · 1.0.0**. Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Smart-Bee-Azerbaijan/pixel-sdk.git", from: "1.0.0"),
],
targets: [
    .target(name: "App", dependencies: [.product(name: "SmartBeePixel", package: "pixel-sdk")]),
]
```

The package has no dependencies and ships a privacy manifest (`PrivacyInfo.xcprivacy`).

### Flutter

Not yet on pub.dev. Until then, use a git dependency:

```yaml
dependencies:
  smartbee_pixel:
    git:
      url: https://github.com/Smart-Bee-Azerbaijan/pixel-sdk.git
      path: mobile/flutter
      ref: v1.0.0
```

### React Native

Not yet on npm. Once published:

```sh
npm install @smartbee/pixel
cd ios && pod install
```

## Quick start

Initialize once, as early as possible. Calls made before `init` are remembered and run afterwards.

**Web** needs no code: the snippet starts the tracker and sends page views automatically.

**Android · Kotlin**

```kotlin
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        SmartBee.init(this, "KEY")
    }
}
```

**Android · Java**

```java
public class App extends Application {
    @Override
    public void onCreate() {
        super.onCreate();
        SmartBee.init(this, "KEY");
    }
}
```

**iOS**

```swift
import SmartBeePixel

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    SmartBee.initialize(key: "KEY")
    return true
}
```

**Flutter**

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SmartBee.init(Platform.isIOS ? 'IOS_KEY' : 'ANDROID_KEY');
  runApp(const MyApp());
}
```

**React Native**

```ts
import { Platform } from 'react-native';
import SmartBee from '@smartbee/pixel';

await SmartBee.init(Platform.OS === 'ios' ? 'IOS_KEY' : 'ANDROID_KEY');
```

The app's `applicationId` (Android) or bundle identifier (iOS) must match the one registered for the key.

## Tracking events

One method on every platform: an event name and optional properties.
Use the [standard names](#standard-events) where they fit; any other name is a custom event (starts with a letter; letters, digits and `_`; up to 64 characters).

```js
// Web
smartbee('track', 'AddToCart', { content_ids: ['p1'], value: 450, currency: 'AZN' });
smartbee('track', 'Purchase', { value: 450, currency: 'AZN', order_id: 'A-1001' }, { eventId: 'order:A-1001' });
```

```kotlin
// Android · Kotlin
SmartBee.track("AddToCart", mapOf("content_ids" to listOf("p1"), "value" to 450, "currency" to "AZN"))
SmartBee.track("Purchase", mapOf("value" to 450, "currency" to "AZN", "order_id" to "A-1001"), eventId = "order:A-1001")
```

```java
// Android · Java
Map<String, Object> order = new HashMap<>();
order.put("value", 450);
order.put("currency", "AZN");
order.put("order_id", "A-1001");
SmartBee.track("Purchase", order, "order:A-1001");
```

```swift
// iOS
SmartBee.track("AddToCart", props: ["content_ids": ["p1"], "value": 450, "currency": "AZN"])
SmartBee.track("Purchase", props: ["value": 450, "currency": "AZN", "order_id": "A-1001"], eventId: "order:A-1001")
```

```dart
// Flutter
SmartBee.track('AddToCart', {'content_ids': ['p1'], 'value': 450, 'currency': 'AZN'});
SmartBee.track('Purchase', {'value': 450, 'currency': 'AZN', 'order_id': 'A-1001'}, 'order:A-1001');
```

```ts
// React Native
SmartBee.track('AddToCart', { content_ids: ['p1'], value: 450, currency: 'AZN' });
SmartBee.track('Purchase', { value: 450, currency: 'AZN', order_id: 'A-1001' }, { eventId: 'order:A-1001' });
```

- Calls return immediately and never throw.
- `value` is a number and `currency` a three-letter ISO 4217 code (`AZN`, `USD`).
- Pass an `eventId` for events that must not be counted twice (orders, payments). The server stores a given event ID once per source.
- `flush()` sends the queue immediately.

## Identifying users

Call `identify` when a user signs in; the user ID is attached to all later events. Call `reset` on sign-out: the user is cleared and a new anonymous ID is generated.

```js
smartbee('identify', 'user-42', { email: 'a@b.az', phone: '+994501234567', plan: 'pro' });   // Web
smartbee('reset');
```

```kotlin
SmartBee.identify("user-42", mapOf("email" to "a@b.az", "phone" to "+994501234567", "plan" to "pro"))   // Kotlin
SmartBee.reset()
```

```swift
SmartBee.identify("user-42", traits: ["email": "a@b.az", "phone": "+994501234567", "plan": "pro"])   // Swift
SmartBee.reset()
```

**Email and phone never leave the device in clear text.** The SDK normalizes them, hashes them with SHA-256 and sends only the hash (`email_sha256`, `phone_sha256`). Pass phone numbers with the country code.

## Screens and deep links

| | Screen views | Deep links |
|---|---|---|
| Web | automatic page views, including single-page apps | UTM parameters and click IDs are read from the URL |
| Android | automatic per Activity; call `SmartBee.screen(name)` in single-Activity (Compose) apps and in R8-minified builds | automatic (`ACTION_VIEW` intents) |
| iOS | manual: `SmartBee.screen(name)` | manual: `SmartBee.handleDeepLink(url)` |
| Flutter | manual, typically from a `NavigatorObserver` | automatic on Android; call `SmartBee.handleDeepLink(uri)` on iOS |
| React Native | manual, typically from the navigation state listener | automatic (native on Android, `Linking` on iOS) |

iOS does not swizzle system methods, so screens and links are forwarded by the app:

```swift
SmartBee.screen("ProductDetail", props: ["product_id": "p1"])

func application(_ app: UIApplication, open url: URL,
                 options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    SmartBee.handleDeepLink(url)
    return true
}
```

## Consent

Two independent purposes. The choice is stored on the device.

| `analytics` | `ads` | Behaviour |
|---|---|---|
| off | — | Nothing is sent or stored; the queue and identifiers are deleted. |
| on | off | Events are sent without advertising identifiers and click IDs. |
| on | on | Full mode. |

```js
smartbee('setConsent', { analytics: true, ads: false });                         // Web
```

```kotlin
SmartBee.init(this, "KEY", SmartBeeOptions(consent = Consent(analytics = false, ads = false)))   // start without consent
SmartBee.setConsent(analytics = true, ads = true)                                                // after the user agrees
```

```java
SmartBee.init(this, "KEY", new SmartBeeOptions(new Consent(false, false)));
SmartBee.setConsent(true, true);
```

```swift
SmartBee.initialize(key: "KEY", options: SmartBeeOptions(consent: Consent(analytics: false, ads: false)))
SmartBee.setConsent(analytics: true, ads: true)
```

If the app does not state a consent at start, the default comes from the source's [remote configuration](#remote-configuration).

## Automatic events

Sent without any code. Each group can be switched off remotely. Do not send them manually or they will be counted twice.

| Event | When | Web | Android | iOS | RN | Flutter |
|---|---|---|---|---|---|---|
| `PageView` | page load, SPA route change | yes | — | — | — | — |
| `FormSubmit` | a form is submitted (field values are not read) | yes | — | — | — | — |
| `ContactClick` | phone, email or WhatsApp link (the number or address is not sent) | yes | — | — | — | — |
| `OutboundClick` | link to another domain | yes | — | — | — | — |
| `SessionStart` | new session (after 30 minutes of inactivity) | yes | yes | yes | yes | yes |
| `AppInstall` | first launch | — | yes | yes | yes | yes |
| `AppUpdate` | first launch after a version change | — | yes | yes | yes | yes |
| `AppOpen` | app comes to the foreground | — | yes | yes | yes | yes |
| `ScreenView` | screen change | — | yes | manual | manual | manual |
| `DeepLinkOpen` | app opened through a link | — | yes | manual | yes | manual on iOS |

## Standard events

Names are case-sensitive.

| Event | When | Recommended properties |
|---|---|---|
| `ViewContent` | product, listing or article view | `content_ids` `content_type` `content_name` `value` `currency` |
| `Search` | search | `search_string` |
| `AddToCart` | add to cart | `content_ids` `contents` `value` `currency` |
| `AddToWishlist` | add to wishlist | `content_ids` `value` `currency` |
| `InitiateCheckout` | checkout started | `contents` `num_items` `value` `currency` |
| `AddPaymentInfo` | payment details entered | `value` `currency` |
| `Purchase` | order completed | `value`* `currency`* `order_id` `contents` `num_items` |
| `Lead` | enquiry, form | `value` `currency` |
| `CompleteRegistration` | registration completed | `method` |
| `Login` | sign-in | `method` |
| `Contact` | contact attempt | `method` |
| `Subscribe` | paid subscription | `value` `currency` |
| `StartTrial` | trial started | `value` `currency` |
| `Schedule` | appointment booked | — |
| `SubmitApplication` | application submitted | — |
| `FindLocation` | branch or address lookup | — |
| `CustomizeProduct` | product customized | `content_ids` |
| `Donate` | donation | `value` `currency` |

\* required for `Purchase`.

Any other property key is allowed and stored as sent. See [`spec/EVENTS.md`](spec/EVENTS.md).

## Privacy

- **Email and phone** are accepted only through `identify` and are SHA-256 hashed on the device.
- **Forbidden keys**: properties named `email`, `phone`, `password`, `pass`, `token`, `card`, `card_number`, `cvv`, `pin`, `fin` are dropped by the SDK.
- **Property values are not inspected.** Do not send personal data under another name.
- **URLs are cleaned**: parameters such as `token`, `password`, `access_token`, `code`, `secret`, `api_key` are removed and email-like parts are replaced with `[redacted]`.
- **Advertising identifiers (GAID / IDFA) are not read.** On iOS only the vendor identifier (IDFV) is used, and only with ads consent.
- **On-device data** lives in the app's private storage and is excluded from device backups.

## Remote configuration

The SDKs are deliberately thin: what is collected and how it is sent is controlled per source on the server, without shipping a new app build.
Mobile SDKs fetch the configuration from `/v1/KEY/config`, cache it on disk and refresh it when the app comes to the foreground (at most once per `ttl_s`). The web tracker receives it inside the script on every page load.

| Setting | Effect | Default |
|---|---|---|
| `enabled` | Kill switch: when `false` the SDK sends nothing and clears its queue. | `true` |
| `sample` | Share of users that are tracked (0 to 1). A user is either fully in or fully out. | `1` |
| `blocked_events` | Event names dropped on the device. | empty |
| `auto` | Switches for each group of automatic events. | all on |
| `consent_default` | Starting consent when the app does not state one. | both on |
| `session_timeout_s` | Session inactivity timeout. | `1800` |
| `strip_params` | Extra URL parameters to remove. | empty |
| `flush` | Send interval, batch size and queue size. | 30 s · 50 · 1000 |
| `ttl_s` | How often mobile SDKs refresh the configuration. | `3600` |

Schema: [`spec/schema/config.v1.schema.json`](spec/schema/config.v1.schema.json).

## Delivery, limits and retries

- **Web** sends the queue every half second and when the page is closed.
- **Mobile** keeps the queue on disk, so events survive offline periods and app restarts. It is sent every 30 seconds, when 50 events have accumulated and when the app goes to the background.

| Limit | Value |
|---|---|
| Events per batch | 1 to 100 |
| Batch size | 500 KB |
| Event size | 32 KB |
| Property nesting | 4 levels |
| Event name | 64 characters |

| Response | Meaning | SDK behaviour |
|---|---|---|
| `200` | accepted | removes the batch from the queue |
| `400` `403` `413` | invalid batch or source mismatch | drops it, no retry |
| `408` `429` `5xx` | temporary problem | keeps it and retries with backoff (5 seconds up to 1 hour) |

Sending the same event twice is safe: the server stores it once.

## Versioning and updates

- The SDKs follow semantic versioning. **Within 1.x the public API is stable**: methods are not removed and do not change meaning.
- The server accepts every released SDK version of the `/v1` protocol, so apps that are never updated keep working.
- Depend on a **version range** (`1.+` in Gradle, `from: "1.0.0"` in Swift Package Manager, `^1.0.0` in npm and pub) and every app build picks up the latest fixes automatically.
- App stores do not allow downloading code at run time, so SDK code itself changes only with a new app build. Everything listed under [Remote configuration](#remote-configuration) changes without one, and a faulty event or the whole collection can be switched off remotely at once.

The web tracker is served from the server, so websites receive updates without any change on their side. Only the snippet is frozen.

## Debugging

| Platform | Enable | Where to look |
|---|---|---|
| Web | `smartbee('debug')` | browser console; Network panel, request to `c.cdnsb.net/v1/e` |
| Android | `SmartBeeOptions(debug = true)` | Logcat, tag `SmartBee` |
| iOS | `SmartBeeOptions(debug: true)` | Xcode console, lines starting with `[SmartBee]` |
| Flutter | `SmartBee.init(key, debug: true)` | native logs (Logcat / Xcode) |
| React Native | `SmartBee.init(key, { debug: true })` | native logs (Logcat / Xcode) |

| Symptom | Cause |
|---|---|
| `403 origin_not_allowed` | The website domain is not in the source's allowed list. |
| `403 app_not_allowed` | The package name / bundle ID differs from the registered one. |
| `403 platform_mismatch` | An Android key is used on iOS, or the other way round. |
| `403 unknown_key` | Wrong key, or the source is disabled. |
| Nothing is sent | Consent is off, the key format is wrong, or the source is switched off remotely. |

## Repository layout

```
Package.swift            Swift package manifest (iOS SDK, sources in mobile/ios)
mobile/android           Android SDK: Gradle project, module :pixel
mobile/ios               iOS SDK: sources and tests
mobile/flutter           Flutter plugin (Dart API + native bridges)
mobile/react-native      React Native module (JS API + native bridges)
mobile/sync-native.mjs   copies the native cores into the two wrappers
mobile/ci-stubs          minimal React / Flutter stubs for type-checking the iOS bridges
spec                     protocol, SDK API, event catalogue, JSON schemas, shared test vectors
```

The Flutter and React Native packages contain a **vendored copy** of the native Android and iOS cores, because npm and pub packages cannot reference files outside their own directory. The copies are generated by `mobile/sync-native.mjs` and must not be edited by hand; CI fails if they drift from the source.

## Development

```sh
# Android: unit tests (JVM + Robolectric)
cd mobile/android && ./gradlew :pixel:testDebugUnitTest

# iOS: unit tests (macOS, no simulator needed)
swift test

# React Native: JS tests
cd mobile/react-native && node --test

# Flutter
cd mobile/flutter && flutter pub get && flutter analyze && flutter test

# Protocol schemas and vectors
npm install && npm test -w spec

# After changing a native core
node mobile/sync-native.mjs          # refresh the vendored copies
node mobile/sync-native.mjs --check  # what CI runs
```

Every SDK is tested against the same JSON schema and vectors in `spec/`, which keeps the four implementations in step.

This repository is published from an internal source repository. Issues are welcome here; pull requests are reviewed and applied upstream, then exported.

## Status

| Platform | Version | Verification |
|---|---|---|
| Web | 1.0.0 | unit tests; verified live in Chrome. Safari and Firefox not yet verified. |
| Android | 1.0.0 | unit tests on CI; a consumer project builds against the published Maven package (Kotlin and Java). Not yet verified on a physical device. |
| iOS | 1.0.0 | unit tests on CI (macOS); builds for iOS. Not yet verified on a physical device. |
| Flutter | 1.0.0 | unit tests; an Android app using the plugin builds on CI; the iOS plugin is type-checked only. |
| React Native | 1.0.0 | JS unit tests; the Android bridge builds; the iOS bridge is type-checked only. |

Treat 1.0.x as an early release and test the integration in your own app before shipping.

## License

[MIT](LICENSE)
