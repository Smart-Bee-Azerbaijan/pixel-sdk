# SmartBee Pixel SDK

[![CI](https://github.com/Smart-Bee-Azerbaijan/pixel-sdk/actions/workflows/ci.yaml/badge.svg)](https://github.com/Smart-Bee-Azerbaijan/pixel-sdk/actions/workflows/ci.yaml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Open-source client SDKs for **SmartBee Pixel**, an event collection service for websites and mobile apps.

| Platform | Language | Minimum version | Package |
|---|---|---|---|
| Web | JavaScript snippet | any modern browser | served from `c.cdnsb.net` (source not in this repository) |
| Android | Kotlin, Java | Android 5.0 (API 21) | `az.smartbee:pixel` |
| iOS | Swift | iOS 13 | Swift Package `SmartBeePixel` |
| Flutter | Dart | Flutter 3.50 (Dart 3.14) | `smartbee_pixel` |
| React Native | TypeScript / JavaScript | React Native 0.76 | `@smartbee/pixel` |

The minimum versions of the two wrappers are the versions built in CI; older releases may work but are not claimed (see the package READMEs).

All SDKs share one public API and speak the same `/v1` protocol, documented in [`spec/`](spec/).
A step-by-step integration guide (in Azerbaijani) with a platform switcher lives at **https://c.cdnsb.net/docs**, and a live playground at **https://c.cdnsb.net/demo**.

> **Availability (before the `v1.0.0` tag).** Not every install path below works yet:
>
> | Platform | Works today | Waiting for |
> |---|---|---|
> | Web | yes — the snippet | — |
> | Android | a pre-release build of `1.0.0` in the Maven repository at `https://c.cdnsb.net/maven`; it may still be rebuilt under the same version number | the `v1.0.0` tag, from which `1.0.0` is immutable |
> | iOS | by branch or commit only (see [iOS](#ios-swift-package-manager)) | the `v1.0.0` tag, for `from: "1.0.0"` |
> | Flutter | git dependency pinned to a commit (see [Flutter](#flutter)) | the `v1.0.0` tag and publication on pub.dev |
> | React Native | a tarball built from a clone with `npm pack` (see [React Native](#react-native)) | publication on npm |
>
> Until the tag exists, treat the public API as final but the artifacts as pre-release: the `1.0.0` files in the Maven repository can be replaced by a newer build, so do not pin their checksum yet.
>
> None of the packages is on a public registry (Maven Central, CocoaPods trunk, pub.dev, npm) yet. Until this README says otherwise, the only legitimate sources are this repository and the Maven repository named above; a package called `smartbee_pixel`, `@smartbee/pixel`, `smartbee-pixel` or `az.smartbee:pixel` on a registry is not ours.

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
- [Advertising ID](#advertising-id)
- [Remote configuration](#remote-configuration)
- [Delivery, limits and retries](#delivery-limits-and-retries)
- [Versioning and updates](#versioning-and-updates)
- [Debugging](#debugging)
- [Repository layout](#repository-layout)
- [Development](#development)
- [Status](#status)
- [Security](#security)
- [License](#license)

## How it works

1. **Your site or app** records events through the snippet or an SDK. Email and phone are hashed on the device.
2. Events are queued and sent in batches to **`https://c.cdnsb.net/v1/e`**, where the key, format and limits are checked.
3. Accepted events are stored once (duplicates are dropped).

Every project has **one key** (8 to 16 lowercase letters and digits; newly issued keys are 16 digits). The website, the Android app and the iOS app all use the same key.
The key is not a secret. The server accepts it only together with a website domain (web), an Android `applicationId` or an iOS bundle ID registered for that key, so a key copied into another app or site is rejected.

A key works only on the platforms registered for it: a key with no registered domain does not serve the web script, and a batch from a platform that is not enabled is rejected with `403 platform_not_enabled`. A cross-platform app uses one key on both Android and iOS.

## Install

### Web

Add the snippet inside `<head>` on every page and replace `KEY` with your key. Nothing else is required: the key is part of the script URL and the tracker starts by itself.

```html
<script>
!function(w,d,n,u,t,s){if(typeof w[n]=='function')return;t=w[n]=function(){t.d||t.q.length>499||t.q.push(arguments)};t.q=[];t.l=+new Date;t.v=1;
function x(){t.d=1;t.q.length=0}
try{s=d.createElement('script');s.async=1;s.src=u;s.onerror=x;(d.head||d.documentElement).appendChild(s)}catch(e){x()}
}(window,document,'smartbee','https://c.cdnsb.net/v1/KEY.js');
</script>
```

If the site uses a Content-Security-Policy, allow `https://c.cdnsb.net` in `script-src` and `connect-src`, and give the inline snippet your page nonce.

**The source of the web tracker is not in this repository.** The script is generated and served by the SmartBee server for each key; this repository contains the snippet above, the protocol the tracker speaks ([`spec/PROTOCOL.md`](spec/PROTOCOL.md)) and the mobile SDKs.

### Android (Kotlin and Java)

The package is served from the SmartBee Maven repository (it is not on Maven Central). Depend on an exact version:

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri("https://c.cdnsb.net/maven")
            content { includeGroup("az.smartbee") }
        }
    }
}

// app/build.gradle.kts
dependencies {
    implementation("az.smartbee:pixel:1.0.0")
}
```

> **Before the `v1.0.0` tag:** the `1.0.0` artifact in the Maven repository is a pre-release build and has been, and may again be, rebuilt in place. Do not record its checksum yet (a later build would fail your verification); set up the verification below once the tag exists.

The repository is served by SmartBee and the artifacts are not PGP-signed, so, from the `v1.0.0` tag onward, pin what you have reviewed with [Gradle dependency verification](https://docs.gradle.org/current/userguide/dependency_verification.html):

```sh
./gradlew --write-verification-metadata sha256 help
```

This records the SHA-256 of every dependency in `gradle/verification-metadata.xml`; commit the file, and Gradle refuses a build in which an artifact has changed. Compare the recorded checksum of the AAR with the one served next to it:

```
https://c.cdnsb.net/maven/az/smartbee/pixel/1.0.0/pixel-1.0.0.aar.sha256
```

From the `v1.0.0` tag onward a released version is never rebuilt in place, and a changed checksum for the same version is a reason to stop and ask. (Before the tag, a changed checksum of `1.0.0` only means that the pre-release build was replaced.)

As an alternative, `implementation("az.smartbee:pixel:1.+")` picks up the latest 1.x release on every build. The trade-off: you get fixes without touching the build file, but an update reaches your release build without review, and dependency verification has to be refreshed for every new version.

The only dependency is the Kotlin standard library (the SDK is compatible with Kotlin 1.9 and newer projects, and callable from Java). Its manifest declares two permissions: `INTERNET` and `com.google.android.gms.permission.AD_ID` (see [Advertising ID](#advertising-id) for how to remove the latter). In multi-process apps the SDK runs in the main process only.

### iOS (Swift Package Manager)

Until the `v1.0.0` tag is published, add the package by branch or, better, by an exact commit. In Xcode choose **File → Add Package Dependencies…**, enter the repository URL and select **Branch · main** or **Commit**. Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Smart-Bee-Azerbaijan/pixel-sdk.git", branch: "main"),
    // or pinned: .package(url: "https://github.com/Smart-Bee-Azerbaijan/pixel-sdk.git", revision: "<full commit SHA>"),
],
targets: [
    .target(name: "App", dependencies: [.product(name: "SmartBeePixel", package: "pixel-sdk")]),
]
```

Once the tag exists, use **Up to Next Major Version · 1.0.0** (`from: "1.0.0"`).

The package has no dependencies and ships a privacy manifest (`PrivacyInfo.xcprivacy`).

### Flutter

Not on pub.dev. Use a git dependency pinned to a commit (after the tag: `ref: v1.0.0`):

```yaml
dependencies:
  smartbee_pixel:
    git:
      url: https://github.com/Smart-Bee-Azerbaijan/pixel-sdk.git
      path: mobile/flutter
      ref: <full commit SHA>
```

### React Native

Not on npm. Build the tarball from a clone and install it:

```sh
git clone https://github.com/Smart-Bee-Azerbaijan/pixel-sdk.git
cd pixel-sdk/mobile/react-native && npm pack        # creates smartbee-pixel-1.0.0.tgz
cd /path/to/your/app && npm install /path/to/pixel-sdk/mobile/react-native/smartbee-pixel-1.0.0.tgz
cd ios && pod install
```

The package has not been published to npm, and `npm install @smartbee/pixel` is **not** a supported install path: do not install a package of that name from a registry unless this README says it has been published.

The Flutter and React Native packages already contain the native SDKs; do not add `az.smartbee:pixel` or the Swift package to the same app.

## Quick start

Initialize once, in one place, as early as possible. Calls made before `init` are remembered and run afterwards.

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
  await SmartBee.init('KEY');
  runApp(const MyApp());
}
```

**React Native**

```ts
import SmartBee from '@smartbee/pixel';

await SmartBee.init('KEY');
```

The same key is used on Android and iOS (and on the website). The app's `applicationId` (Android) or bundle identifier (iOS) must be one of those registered for the key.

Options are passed like this (all are optional; see [`spec/SDK-API.md`](spec/SDK-API.md) for the full list):

```kotlin
// Kotlin
SmartBee.init(this, "KEY", smartBeeOptions { consent(analytics = true, ads = false); debug(BuildConfig.DEBUG) })
```

```java
// Java
SmartBee.init(this, "KEY", new SmartBeeOptions.Builder().consent(true, false).debug(BuildConfig.DEBUG).build());
```

```swift
// Swift
SmartBee.initialize(key: "KEY", options: SmartBeeOptions(consent: SmartBeeConsent(analytics: true, ads: false), debug: true))
```

```dart
// Flutter
await SmartBee.init('KEY', consent: const SmartBeeConsent(analytics: true, ads: false), debug: true);
```

```ts
// React Native
await SmartBee.init('KEY', { consent: { analytics: true, ads: false }, debug: true });
```

Notes on `init`:

- A **second `init`** does not restart the SDK or change the key. It is logged, and only its more restrictive options are applied (purposes set to `false` in `consent`, and `collectAdvertisingId = false`).
- In Flutter and React Native `init` returns a future / promise of a **boolean**: `true` when the call was handed to the native SDK, `false` when it could not be (native module missing, malformed key). It never throws. It does **not** wait for the SDK to finish starting: `getAnonymousId()` can still return `null` right afterwards.
- `SmartBee.sdkVersion` returns the SDK version on every mobile platform.

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
SmartBee.track('AddToCart', props: {'content_ids': ['p1'], 'value': 450, 'currency': 'AZN'});
SmartBee.track('Purchase', props: {'value': 450, 'currency': 'AZN', 'order_id': 'A-1001'}, eventId: 'order:A-1001');
```

```ts
// React Native
SmartBee.track('AddToCart', { content_ids: ['p1'], value: 450, currency: 'AZN' });
SmartBee.track('Purchase', { value: 450, currency: 'AZN', order_id: 'A-1001' }, { eventId: 'order:A-1001' });
```

- Calls return immediately and never throw.
- `value` is a number and `currency` a three-letter ISO 4217 code (`AZN`, `USD`).
- Pass an `eventId` for events that must not be counted twice (orders, payments). The server stores a given event ID once per key.
- `flush()` sends the queue immediately.

## Identifying users

Call `identify` when a user signs in; the user ID is attached to all later events. Call `reset` on sign-out: the user is cleared and a new anonymous ID is generated.

```js
smartbee('identify', 'user-42', { email: 'user@example.com', phone: '+994501234567', plan: 'pro' });   // Web
smartbee('reset');
```

```kotlin
SmartBee.identify("user-42", mapOf("email" to "user@example.com", "phone" to "+994501234567", "plan" to "pro"))   // Kotlin
SmartBee.reset()
```

```swift
SmartBee.identify("user-42", traits: ["email": "user@example.com", "phone": "+994501234567", "plan": "pro"])   // Swift
SmartBee.reset()
```

```dart
SmartBee.identify('user-42', traits: {'email': 'user@example.com', 'plan': 'pro'});   // Flutter
```

```ts
SmartBee.identify('user-42', { email: 'user@example.com', plan: 'pro' });   // React Native
```

**Email and phone never leave the device in clear text.** The SDK normalizes them, hashes them with SHA-256 and sends only the hash (`email_sha256`, `phone_sha256`). Pass phone numbers with the country code. A user ID that itself looks like an e-mail address or a phone number is hashed the same way instead of being sent as it is.

## Screens and deep links

| | Screen views | Deep links |
|---|---|---|
| Web | automatic page views, including single-page apps | UTM parameters and click IDs are read from the URL |
| Android | automatic per Activity until the app calls `SmartBee.screen(name)` itself; do that in single-Activity (Compose) apps and in R8-minified builds | automatic when the app is opened by a link; forward `onNewIntent` links with `SmartBee.handleDeepLink(url)` |
| iOS | manual: `SmartBee.screen(name)` | manual: `SmartBee.handleDeepLink(url)` |
| Flutter | manual: `SmartBee.screen(name)`, typically from a `NavigatorObserver` | manual on both platforms: `SmartBee.handleDeepLink(uri.toString())` |
| React Native | manual: `SmartBee.screen(name)`, typically from the navigation state listener | automatic on both platforms through `Linking` (not when `autoEvents` is `false`); `SmartBee.handleDeepLink(url)` for links that arrive another way |

The wrappers do not ship an integration for any navigation library: screen views are reported by calling `screen()`.

Only `http`, `https` and `scheme://…` links count as deep links; `tel:`, `sms:`, `mailto:`, `geo:`, `content:` and similar URIs are never sent. A URL longer than 8192 characters is ignored. The same link reported twice within 5 seconds is counted once.

On Android, a link that arrives while the app is already running (`singleTop` / `singleTask` activities) is delivered to `onNewIntent`:

```kotlin
override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    setIntent(intent)
    SmartBee.handleDeepLink(intent.dataString)
}
```

iOS does not swizzle system methods, so screens and links are forwarded by the app:

```swift
SmartBee.screen("ProductDetail", props: ["product_id": "p1"])

func application(_ app: UIApplication, open url: URL,
                 options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    SmartBee.handleDeepLink(url)
    return true
}
```

In scene-based apps (the default Xcode template) and SwiftUI apps the `AppDelegate` methods above are not called; forward links from here instead:

```swift
// SceneDelegate
func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    connectionOptions.urlContexts.forEach { SmartBee.handleDeepLink($0.url) }
    connectionOptions.userActivities.compactMap { $0.webpageURL }.forEach { SmartBee.handleDeepLink($0) }
}
func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    URLContexts.forEach { SmartBee.handleDeepLink($0.url) }
}
func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    if let url = userActivity.webpageURL { SmartBee.handleDeepLink(url) }
}

// SwiftUI
ContentView().onOpenURL { SmartBee.handleDeepLink($0) }
```

## Consent

Two independent purposes. The choice is stored on the device.

| `analytics` | `ads` | Behaviour |
|---|---|---|
| off | — | Nothing is sent or stored; the queue and identifiers are deleted. The mobile SDKs make no network request at all: not even the remote configuration is fetched. |
| on | off | Events are sent without advertising / device identifiers and click IDs. |
| on | on | Full mode. On iOS, identifiers and click IDs additionally require the user's tracking permission (ATT); see [Advertising ID](#advertising-id). |

```js
// Web: default until the visitor chooses (never overrides a stored choice); call right after the snippet
smartbee('init', { consent: { analytics: false, ads: false } });
// Web: only from the cookie banner's buttons
smartbee('setConsent', { analytics: true, ads: true });
```

```kotlin
SmartBee.init(this, "KEY", smartBeeOptions { consent(analytics = false, ads = false) })   // start without consent
SmartBee.setConsent(SmartBeeConsent(analytics = true, ads = true))                         // after the user agrees
```

```java
SmartBee.init(this, "KEY", new SmartBeeOptions.Builder().consent(false, false).build());
SmartBee.setConsent(new SmartBeeConsent(true, true));
```

```swift
SmartBee.initialize(key: "KEY", options: SmartBeeOptions(consent: SmartBeeConsent(analytics: false, ads: false)))
SmartBee.setConsent(SmartBeeConsent(analytics: true, ads: true))
```

```dart
await SmartBee.init('KEY', consent: const SmartBeeConsent(analytics: false, ads: false));   // Flutter
SmartBee.setConsent(analytics: true, ads: true);
```

```ts
await SmartBee.init('KEY', { consent: { analytics: false, ads: false } });   // React Native
SmartBee.setConsent({ analytics: true, ads: true });
```

On Android and iOS `setConsent(analytics, ads)` with two booleans is available as well.

**Which value applies (mobile).** Consent can be stated by the app (the `consent` option of `init`) and by the user (`setConsent`, which is stored). For each purpose separately:

- When both exist, the **more restrictive** one wins: an explicit `false` passed to `init` beats a stored `true`, and a stored `false` beats a `true` in `init`.
- A `setConsent` call at run time is the most recent explicit choice: it is stored and, for the rest of that process, replaces the value from `init`.
- When neither exists, the default comes from the key's [remote configuration](#remote-configuration) (`consent_default`). The configuration never overrides an explicitly stated consent.
- A repeated `init` can only tighten consent.
- A withdrawal takes effect immediately, in the calling thread, even if the SDK is busy or has not finished starting. It is also written to disk in the calling thread, so it survives the death of the process: at the next start it is applied before anything is sent.
- When ads consent is withdrawn (on iOS also when the tracking permission is), events already in the on-disk queue are rewritten without advertising identifiers and click IDs (also in the URL values of their `props` and `traits` and in a URL-shaped screen name; the current screen name is cleaned too), and they stay that way if consent is granted again before they are sent.
- If the SDK's local store is corrupt, consent counts as denied until `setConsent` is called; the `consent` option of `init` cannot loosen it.

If the app does not state a consent at start, on the very first launch a mobile SDK waits for the server's answer: until then events are held in memory (at most 100) and nothing is sent or written to disk. Passing a consent to `init` skips that wait.

**The wrappers fail closed.** In React Native a consent object with a missing or non-boolean purpose is completed with `false` (`{ analytics: true }` means `{ analytics: true, ads: false }`) and a warning is logged. In Flutter both purposes are required by the type; `SmartBeeConsent.fromMap` applies the same rule to loosely typed input.

On the web, a choice the visitor made earlier always wins over the `init` default; to withdraw consent call `setConsent`. A Global Privacy Control signal sets `ads` to `false` for visitors without a stored choice.

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
| `DeepLinkOpen` | app opened through a link | — | yes | manual | yes (through `Linking`) | manual on both platforms |

"manual" means the event is recorded when the app calls `screen()` / `handleDeepLink()`.

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
- **One set of rules on every platform.** The web tracker and the mobile SDKs apply the same rules to property keys, property values and URLs; they are specified in [`spec/PROTOCOL.md`](spec/PROTOCOL.md), section 6.1, and checked in every SDK against the shared vectors in [`spec/vectors`](spec/vectors).
- **Forbidden keys.** Properties named `email`, `phone`, `password`, `pass`, `token`, `card`, `card_number`, `cvv`, `pin`, `fin`, `kart` are dropped. Beyond these exact names, key names are checked at every depth, regardless of case and of `_` / `-` spelling: keys that look like an e-mail, a phone number, a password, a card detail, an IBAN, a token, a session, an API key, a cookie, a one-time code or another secret are dropped (`session`, `auth`, `sid`, `sms_code`, `totp`, `2fa_code` included; with a value that is not a flag also `signature`, `sig`, `nonce`, `license_key`, `cardholder`, `creditcard`, `cc_number`, `account_number`, `pinkod`). The value is taken into account, so flags, counters, settings and descriptive names are kept: `email_verified: true`, `emails_sent: 5`, `has_password: true`, `email_template: "welcome"`, `mobile: "ios"`, `token_count`, `card_type`, `phone_model`, `gift_card`. A `*_sha256` key is kept only when its value is 64 hex characters. Azerbaijani / Turkish names (`telefon`, `mobil`, `nomre`, `parol`, `sifre`, `kart`, `eposta`, `poct`, `whatsapp`) are recognised as well, with the letters `ö ə ş ç ü ğ ı İ` folded to ASCII; Cyrillic names are not recognised.
- **Property values.** A string value that is a JWT or a card number becomes `[redacted]`. A value, or a word inside it, that is a URL, a path (`/…`) or a query string (`?…`) is scrubbed by the URL rules below. Inside other text, e-mail addresses, phone numbers starting with `+`, card numbers (also written with `/`, no-break or thin spaces), JWTs, known API-key prefixes (`sk_live_…`, `ghp_…`), IBANs (mod-97 checked, written without spaces), the token after `Bearer` and hex strings or other long tokens of 32 or more characters are replaced with `[redacted]`, whatever punctuation surrounds them, also in a URL inside the text that is followed by punctuation or a quote (`(https://shop.example/a?v=<key>)`). Text of the form `name=value` is scrubbed like a query string (`a=1&token=…` becomes `a=1`; a single pair only when the name is sensitive and the value has 6 or more characters with a digit or a capital, so `code=200` stays). Names, addresses and phone numbers without `+` are not recognised: do not send personal data under another name.
- **User ID.** An ID that looks like an e-mail address or a phone number is sent as its SHA-256; an ID that contains an e-mail address (`John Doe <john@example.com>`, or two `@` as in `user@shop.az@tenant`) is hashed as that address (the fullwidth `＠` counts as `@`), and one leading `tel:`, `phone:`, `sms:`, `mailto:` or `email:` is ignored. An ID shaped like a JWT is rejected; an ID shaped like a card number is sent as the SHA-256 of its digits.
- **Page title and screen name** are scanned like a property value (a URL-shaped screen name is scrubbed as a URL); in addition, 9 or more digits in a row are replaced with `[redacted]`.
- **These rules are heuristics.** They recognise shapes and names and have known limits, listed at the end of section 6.1 of [`spec/PROTOCOL.md`](spec/PROTOCOL.md) (for example a short lower-case token, a card number written with dots, an IBAN written in spaced groups, a random token shorter than 32 characters inside a text, a Cyrillic field name; a token joined by dots that is not a JWT, such as `ya29.<token>`; a card number written directly next to other digits, such as `<card> 12/27`; `Basic <base64>` credentials; a short password inside free text; a user ID that is itself an API key or an IBAN). A little over-masking is accepted on purpose: the keys `loyalty_card`, `boarding_pass`, `confirmation_code` and `page_token` are dropped, a Luhn-valid 16-digit barcode or order number in a parameter value is masked, and after an order confirmation a lower-case or mixed-case order reference is masked (`/order/confirm/az-778899`). Treat them as a safety net, not as a filter: do not put such values into `props`, `traits` or the user ID at all.
- **URLs are scrubbed** before they are recorded: page, referrer, form and link URLs on the web, deep-link URLs (`DeepLinkOpen`) in the mobile SDKs, and URL-shaped property values everywhere. Query parameters whose name suggests a secret or personal data (`token`, `password`, `code`, `secret`, `session`, `auth`, `phone`, `mail`, `card`, `key`, `sig`, `otp`, `activation`, `ticket`, `telefon`, `parol`, … — also inside percent-encoded, bracketed or mixed-case names) are removed, while harmless pairs and flags stay (`promo_code`, `invite_code`, `card_type`, `phone_model`, `mobile=1`, `cc=az`). A parameter value shaped like a JWT or like another secret (32 or more hex characters, a long token, a known API-key prefix, a Luhn-valid card number, 20 or more digits, a phone number starting with `+`) becomes `[redacted]`; the values of the six UTM parameters, of click IDs and of pagination cursors are exempt, except that a phone number starting with `+` and a card number in a UTM value are masked. A parameter whose name itself looks like a secret is masked as a whole, and a padded base64 token in the query (`/reset?<base64>==`, `/reset?<base64>=`) is examined as one token. Path segments that look like a secret (a JWT, a segment containing 32 or more hex characters in a row, as in `reset-<hex>` or `<hex>.json`, unless it is a static file name such as `<md5>.jpg`; a long base64 string, a Luhn-valid card number of 15–19 digits, 20 or more digits, a phone number starting with `+`) and e-mail-like text become `[redacted]`; a bare number of 10–14 digits is left alone. After a path segment that is a hint (one to three words, the first or last of them starting with `reset`, `forgot`, `verify`, `confirm`, `activat`, `invit`, `login`, `token`, … or being one of `otp`, `sso`, `auth`, `oauth`, `callback`, `session`, `join`, `mfa`, `2fa`) the next two segments and, when the hint ends the path, the query are examined more strictly: 6 or more digits directly after the hint and token-like segments are masked (`/reset/GBwfxTRf`), while ordinary words, dates, versions and static file names are kept (`/reset/step2`, `/login/app.3f9a2b1c.js`). An order confirmation keeps its order number: after `confirm…` / `tesdiq…` with an order word (`order`, `checkout`, `payment`, `booking`, `purchase`, `sifaris`, `odenis`) in the same, the previous or the next segment, or after the single word `confirmation`, a reference made of capital letters, digits and hyphens is kept (`/order/confirm/2026112500123`, `/confirmation/AZ-778899`), while anything else is masked as after any hint (`/order/confirm/Zq7Lm2Xp9Rt4`, `/order/confirm/az-778899`), and so is a code of 6–8 digits after a payment confirmation (`/payment/confirmation/879609`); in `/confirm?orderId=…&t=<token>` the order number stays while `t` is masked. Matrix parameters (`/reset;t=<token>`, also in a hash route: `#/reset;t=<token>`) are scrubbed like query parameters with the hint of their segment, and a segment that contains `=` or `%2F` is masked when one of its pieces is a secret (`/x/t=<card number>`). After a phone word (`/tel/…`, `/phone/…`) a segment of 7–15 digits is masked. In an app-scheme link (`myapp://reset/123456`) the host position is treated as the first path segment. A hash route (`#/…`) is kept and cleaned the same way, any other fragment and the user name / password part are removed. The six UTM parameters (`utm_source`, `utm_medium`, `utm_campaign`, `utm_term`, `utm_content`, `utm_id`) are kept, any other `utm_…` name is an ordinary parameter (`utm_token` is removed); the 17 click IDs (`fbclid`, `gclid`, `gbraid`, `wbraid`, `ttclid`, `msclkid`, `dclid`, `twclid`, `yclid`, `li_fat_id`, `sccid`, `rdt_cid`, `_gl`, `mc_eid`, `srsltid`, `epik`, `gad_source`) are kept only while advertising is allowed. In the mobile SDKs a deep link longer than 8192 characters is not processed at all; on the web a URL longer than 8192 characters loses its query and fragment and has its path cut at the last whole segment before it is scrubbed.
- **Advertising and device identifiers (GAID / IDFA / IDFV) are read only with ads consent**, and on iOS sent only once the user has allowed tracking; see [Advertising ID](#advertising-id).
- **Without analytics consent the mobile SDKs are silent**: nothing is stored, nothing is sent and no request is made to the server.
- **On-device data** lives in the app's private storage and is excluded from device backups.

## Advertising ID

The mobile SDKs send the device advertising ID only while **ads consent** is given. When consent is withdrawn the ID is dropped, including from events still waiting in the queue.

**Android (GAID)**

- The SDK does not bring Google's library with it. For the ID to be collected, the app adds it; without it (or without Google Play services on the device) nothing is collected and nothing breaks:

  ```kotlin
  implementation("com.google.android.gms:play-services-ads-identifier:18.2.0")
  ```
- The SDK's manifest declares `com.google.android.gms.permission.AD_ID`, so the permission is merged into your app (apps targeting Android 13+ get an all-zero ID without it).
- If the ID is collected, declare it in the Play Console: the **Data safety** form (*Device or other IDs*) and the **Advertising ID** declaration.
- Nothing is sent when the user has deleted the advertising ID or opted out of ad personalization.

**iOS (IDFA, IDFV and App Tracking Transparency)**

- The IDFA **and the vendor identifier (IDFV)** are sent only when the user has granted App Tracking Transparency permission to your app. **The SDK never shows the prompt**; the app does:

  ```swift
  // Info.plist must contain NSUserTrackingUsageDescription
  import AppTrackingTransparency

  if #available(iOS 14, *) {
      ATTrackingManager.requestTrackingAuthorization { _ in }
  }
  ```
- On iOS 14 and later, while the tracking status is anything other than *authorized* (not asked, denied, restricted), a batch is treated as not eligible for advertising even if ads consent is given: no IDFA or IDFV is sent, click IDs are removed, and the batch is marked `consent.ads = false`, so the server does not forward it to advertising platforms. Analytics is not affected.
- If your app obtains ATT permission, declaring tracking in the app's own privacy manifest and in the App Privacy answers in App Store Connect is the app's responsibility.

**Turning it off.** Pass `collectAdvertisingId = false` and the identifier is never read. On iOS this also turns off the IDFV and the reading of the tracking status (batches are then never eligible for advertising on iOS 14+):

```kotlin
SmartBee.init(this, "KEY", smartBeeOptions { collectAdvertisingId(false) })            // Android · Kotlin
```

```java
SmartBee.init(this, "KEY", new SmartBeeOptions.Builder().collectAdvertisingId(false).build());   // Android · Java
```

```swift
SmartBee.initialize(key: "KEY", options: SmartBeeOptions(collectAdvertisingId: false)) // iOS
```

Flutter: `SmartBee.init(key, collectAdvertisingId: false)`; React Native: `SmartBee.init(key, { collectAdvertisingId: false })`.

On Android you can also remove the permission in your own manifest:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android" xmlns:tools="http://schemas.android.com/tools">
    <uses-permission android:name="com.google.android.gms.permission.AD_ID" tools:node="remove" />
</manifest>
```

## Remote configuration

The SDKs are deliberately thin: what is collected and how it is sent is controlled per key on the server, without shipping a new app build.
Mobile SDKs fetch the configuration from `/v1/KEY/config`, cache it on disk and refresh it when the app comes to the foreground (at most once per `ttl_s`). The web tracker receives it inside the script on every page load.

| Setting | Effect | Default |
|---|---|---|
| `enabled` | Kill switch: when `false` the SDK sends nothing and clears its queue. | `true` |
| `sample` | Share of users that are tracked (0 to 1). A user is either fully in or fully out. | `1` |
| `blocked_events` | Event names dropped on the device. | empty |
| `auto` | Switches for each group of automatic events. | all on |
| `consent_default` | Starting consent when neither the app nor the user has stated one. | both on |
| `session_timeout_s` | Session inactivity timeout. | `1800` |
| `strip_params` | Extra URL parameters to remove. | empty |
| `flush` | Send interval, batch size and queue size. | 30 s · 50 · 1000 |
| `ttl_s` | How often mobile SDKs refresh the configuration. | `3600` |

The mobile SDKs clamp these values to safe bounds (for example `ttl_s` between 60 seconds and 7 days), so a faulty configuration cannot stall an app.

**A key is treated as disabled only on the server's explicit word.** The mobile SDKs stop sending when the configuration says `enabled: false`, or when the server answers with a JSON body that carries `error: unknown_key`. A bare `404` / `403` from something in between (a CDN, an ingress, a corporate proxy) is treated as a temporary failure: nothing is deleted and the request is retried. After `unknown_key` the SDK keeps its queue, sends nothing and asks for the configuration again after an hour.

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
| `2xx` | accepted | removes the batch from the queue |
| `400` `403` with a documented JSON `error` code | invalid batch, or the key is not valid for this site / app | drops the batch, no retry |
| `413` | batch too large | mobile: splits a batch of several events in half and resends each half; a single event is dropped only when the body carries a documented `413` code, otherwise it is kept and retried. Web: drops the batch (after one retry without the stored campaign when the context is too large) |
| any other `4xx` (a `400` / `403` without a documented code, `404`, `422`), `3xx` | something between the SDK and the server answered | keeps the batch and retries, on the web as well as on mobile; redirects are not followed (on the web when the batch is sent with `fetch`). Mobile: a batch that gets 3 consecutive `4xx` answers without a documented code is sent one event at a time, and a single event still rejected that way is dropped after 5 attempts or 3 days |
| `408` `429` `5xx`, network error | temporary problem | keeps it and retries (honouring `Retry-After`): mobile SDKs after 5 seconds, doubling up to 1 hour, with no limit on attempts (the queue is on disk); the web tracker at most 5 more times (after 5, 10, 20, 40 and 80 seconds) while the page stays open, then it drops the batch |

Sending the same event twice is safe: the server stores it once. The normative table is in [`spec/PROTOCOL.md`](spec/PROTOCOL.md), section 5.6.

## Versioning and updates

- The SDKs follow semantic versioning. **Within 1.x the public API is stable**: methods are not removed and do not change meaning.
- The protocol and API documents in [`spec/`](spec/) are frozen with SDK 1.0.0: only new, optional fields may be added.
- The server accepts every released SDK version of the `/v1` protocol, so apps that are never updated keep working.
- From its tag onward a released version is immutable: the same version number never gets different bytes. `1.0.0` is not tagged yet (see the availability note at the top), so until the `v1.0.0` tag exists its pre-release artifacts may be rebuilt.
- App stores do not allow downloading code at run time, so SDK code itself changes only with a new app build. Everything listed under [Remote configuration](#remote-configuration) changes without one, and a faulty event or the whole collection can be switched off remotely at once.

The web tracker is served from the server, so websites receive updates without any change on their side. Only the snippet is frozen.

### Staying up to date

- **Exact version (recommended).** Pin `1.0.0` (once the `v1.0.0` tag exists; before that, pin a commit), commit the lock / verification files (`gradle/verification-metadata.xml`, `Package.resolved`, `pubspec.lock`, `package-lock.json`) and let Dependabot or Renovate open a pull request when a new SDK version is released.
- **Version range.** `1.+` in Gradle, `from: "1.0.0"` in Swift Package Manager, and, once the packages are on those registries, `^1.0.0` in npm and pub pick up new 1.x releases without a change to the build file. Gradle caches a resolved dynamic version for 24 hours (`--refresh-dependencies` checks right away); Swift Package Manager stays on the version in `Package.resolved` until **File → Packages → Update to Latest Package Versions** or `swift package update`.
- **The SDK tells you.** In debug mode the mobile SDKs log a one-time notice when a newer version has been released (see [Debugging](#debugging) for where the logs appear). Behaviour does not change.

## Debugging

| Platform | Enable | Where to look |
|---|---|---|
| Web | `smartbee('debug')` | browser console; Network panel, request to `c.cdnsb.net/v1/e` |
| Android | `smartBeeOptions { debug(true) }` / `new SmartBeeOptions.Builder().debug(true)` | Logcat, tag `SmartBee` |
| iOS | `SmartBeeOptions(debug: true)` | Xcode console, lines starting with `[SmartBee]` |
| Flutter | `SmartBee.init(key, debug: true)` | native logs (Logcat / Xcode); wrapper warnings in the Flutter console |
| React Native | `SmartBee.init(key, { debug: true })` | native logs (Logcat / Xcode); wrapper warnings in the Metro console |

| Symptom | Cause |
|---|---|
| `403 origin_not_allowed` | The website domain is not in the key's allowed list. |
| `403 app_not_allowed` | The package name / bundle ID is not among those registered for the key. |
| `403 platform_not_enabled` | The key is not enabled for this platform: no Android package name or iOS bundle ID (or, for web, no domain) is registered for it. |
| `403 unknown_key` | Wrong key, or the key is disabled. |
| Nothing is sent | Consent is off, the key format is wrong, or the key is switched off remotely. |
| `init` returns `false` (Flutter / React Native) | The native module is not linked (rebuild the app; Expo Go and Jest have no native module), or the key is malformed. |

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

The web tracker is not part of this repository (see [Web](#web)).

The Flutter and React Native packages contain a **vendored copy** of the native Android and iOS cores, because npm and pub packages cannot reference files outside their own directory. The copies are generated by `mobile/sync-native.mjs` and must not be edited by hand; CI fails if they drift from the source.

Not everything is in English yet. Still partly or wholly in Azerbaijani: the comments inside the native core sources (and therefore their vendored copies in the two wrappers), the native unit tests (comments and some test names), the comments and case descriptions of the shared test vectors and schema tooling under `spec/`, and the comments in a few build files (Gradle scripts, ProGuard rules, the Android manifest). In English: the public API documentation (KDoc / Swift doc comments), the specification documents, the wrapper code and all READMEs.

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
npm ci && npm test -w spec

# After changing a native core
node mobile/sync-native.mjs          # refresh the vendored copies
node mobile/sync-native.mjs --check  # what CI runs
```

The native SDKs are tested against the same JSON schema and vectors in `spec/`, which keeps the implementations in step.

This repository is published from an internal source repository. Issues are welcome here; pull requests are reviewed and applied upstream, then exported. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Status

| Platform | Version | Verification |
|---|---|---|
| Web | 1.0.0 | unit tests in the source repository; verified live in Chrome. Safari and Firefox not yet verified. The source is not published here. |
| Android | 1.0.0 | unit tests on CI (JVM + Robolectric); the Maven publication builds on CI. Not yet verified on a physical device. |
| iOS | 1.0.0 | unit tests on CI (macOS); builds for iOS. Not yet verified on a physical device. |
| Flutter | 1.0.0 | Dart unit tests; an Android app using the plugin builds on CI; the iOS plugin is type-checked against stubs only. |
| React Native | 1.0.0 | JS unit tests; the Android bridge builds on CI; the iOS bridge is type-checked against stubs only. Classic native module: no TurboModule spec yet. |

The `v1.0.0` tag has not been published yet (see the availability note at the top). Test the integration in your own app before shipping.

## Security

Please report vulnerabilities privately; see [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
