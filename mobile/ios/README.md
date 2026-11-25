# SmartBee Pixel — iOS SDK

Swift Package, iOS 13+. It has no dependencies.

## Usage

```swift
import SmartBeePixel

// application(_:didFinishLaunchingWithOptions:)
SmartBee.initialize(key: "YOUR_KEY")

SmartBee.track("Purchase", props: ["value": 250, "currency": "AZN", "order_id": "A-1001"], eventId: "order:A-1001")
SmartBee.identify("user-42", traits: ["email": "a@b.az"])   // the email is hashed on the device
SmartBee.screen("ProductDetail")
SmartBee.setConsent(analytics: true, ads: false)
SmartBee.reset()                                              // log out
let version = SmartBee.sdkVersion                             // "1.0.0"

// When the app is opened by a deep link (URL scheme or universal link)
SmartBee.handleDeepLink(url)
```

Full API: [../../spec/SDK-API.md](../../spec/SDK-API.md).

Options:

```swift
var options = SmartBeeOptions()
options.consent = SmartBeeConsent(analytics: true, ads: false)   // the type name is `SmartBeeConsent`
options.debug = true
options.collectAdvertisingId = false
SmartBee.initialize(key: "YOUR_KEY", options: options)
```

## What you need to know

- **No call throws an error**, and any call can be made from any thread.
- **Consent.** For each purpose the most restrictive explicit value wins: if either the `consent` option of `initialize` or the choice the user previously saved with `setConsent` says `false`, the result is `false`. If neither exists, the `consent_default` from the key's configuration applies. A runtime `setConsent` call is the most recent choice and replaces the value from `initialize`.
- **Withdrawing consent is immediate.** `setConsent(analytics: false, …)` takes effect on the calling thread: even if the SDK is busy or has not started yet, no request is sent from then on, and `SmartBee.anonymousId` returns `nil` immediately. When analytics is explicitly declined, the configuration is not requested either (nothing goes out to the network).
- **Withdrawing consent is durable.** A `setConsent` call that denies a purpose (and a repeated `initialize` that tightens consent) is also written to a small file (`consent.mark`) on the calling thread, before the call returns. If the process dies before the SDK's queue has executed the call, the withdrawal is applied at the next start before anything is sent: after a withdrawal of analytics the old queue and the identifiers are deleted, even if consent was granted again afterwards. The file is removed once the SDK has executed the call and written the result to disk.
- **Queued events are cleaned on disk** when ads consent or the ATT permission is withdrawn: the rows already in the queue are rewritten without device identifiers and click IDs (in `ctx.campaign`, in the URL values of the `props` and `traits` of every queued event, not only in the `DeepLinkOpen` address, and in a URL-shaped `screen.name`; the current screen name in memory is cleaned too), with `ctx.consent.ads: false`; the stored campaign loses its click IDs. These events stay ineligible for advertising after a later re-grant. During a flush the advertising state (ads consent and ATT status) is read again for every batch, so a withdrawal in the middle of a multi-batch flush applies to the remaining batches.
- **A corrupt local store means "denied until restated".** If the store file cannot be parsed or the stored consent value is not a valid one, both purposes are treated as denied, not as "never stated": the `consent_default` of the configuration is not applied and nothing is requested until `setConsent` is called. The `consent` option of `initialize` cannot loosen this state: only a new `setConsent` call states consent again.
- **`consent_default` fails closed.** When the configuration contains `consent_default`, a purpose is granted only by a JSON `true`; a missing or non-boolean member counts as `false`. (The server always sends both members as booleans.)
- **The on-disk queue is capped** at `flush.max_queue` events (1000 by default) and at 5 MB; beyond either limit the oldest events are dropped.
- **Delivery.** A batch is deleted only when the server accepts it or rejects it with a documented final code ([spec/PROTOCOL.md](../../spec/PROTOCOL.md), 5.6). A `4xx` without such a code (a WAF's `400`, a `422`, a body-less `413` for a single event), a `3xx` (redirects are not followed), `408`, `429`, `5xx` and a network error keep the batch; it is retried after 5 s, doubling up to 1 hour (±20%), or after the server's `Retry-After`. `5xx`, network errors, `408` and `429` are retried without a limit on the number of attempts. A batch that gets 3 consecutive `4xx` answers without a documented error code (other than `408` / `429`) is sent one event at a time; a single event that is still rejected that way is dropped after 5 attempts or 3 days, whichever comes first (debug log), and the rest of the queue goes on.
- **`initialize` is called once.** A repeated call does not restart the SDK and does not change the key: it is logged to the console and only its tightening options (the `false` purposes of `consent`, `collectAdvertisingId: false`) are applied. A call with an invalid key is ignored, and it can be called again later with a correct key.
- **Calls made before `initialize`** are kept in memory: at most 100 ordinary calls (`track`, `identify`, `screen`, `flush`, `handleDeepLink`), further ones are dropped and their number is written to the debug log; `setConsent` and `reset` are never dropped.
- **Calls made while the SDK is busy are capped.** While the SDK's queue is busy (for example in a slow request), at most 100 `track` / `screen` calls wait for it; when the list is full the oldest waiting one is dropped and the number of dropped calls is written to the debug log. `identify`, `flush`, `handleDeepLink`, `setConsent` and `reset` are never dropped, and the order of the calls does not change.
- **`reset()`** clears the user, the stored campaign / click IDs, the screen name and the event counter; the new anonymous ID can be read from `SmartBee.anonymousId` immediately.
- **Personal data.** A `userId` that looks like an email or a phone number is not sent in the clear (its SHA-256 is sent). The same applies to an ID that contains an email address (`John Doe <john@example.com>`, also with two `@` as in `user@shop.az@tenant`; the fullwidth `＠` counts as `@`); one leading `tel:`, `phone:`, `sms:`, `mailto:` or `email:` is ignored. A `userId` shaped like a JWT is rejected, and one shaped like a card number is sent as the SHA-256 of its digits. In `props` / `traits`, keys are judged by the words of their name and by their value (regardless of case and of `_` / `-` spelling, at all depths; Azerbaijani / Turkish names such as `telefon`, `mobil`, `nomre`, `parol`, `sifre`, `kart`, `eposta`, `poct`, `whatsapp` are recognised too, with `ö ə ş ç ü ğ ı İ` folded to ASCII, while Cyrillic names are not): keys that indicate an email, a phone, a password, a token, a card, a session, an API key, a cookie or a one-time code are dropped (`session`, `auth`, `sid`, `sms_code`, `otp_code`, `totp` and `2fa_code` included; with a value that is not a flag also `signature`, `sig`, `nonce`, `license_key`, `cardholder`, `creditcard`, `cc_number`, `account_number`, `pinkod`), while counters, flags and descriptive names are kept (`token_count`, `email_verified`, `has_password: true`, `card_type`, `phone_model`, `gift_card`, `email_template: "welcome"`, `mobile: "ios"`). A `*_sha256` key is kept only with a 64-character hex value. Text values are scanned: a value that is a JWT or a card number becomes `[redacted]`; a value, or a word in it, that is a URL, a path (`/…`) or a query string (`?…`) is cleaned by the URL rules; emails, phone numbers starting with `+`, card numbers (also written with `/`, no-break or thin spaces), JWTs, known API-key prefixes (`sk_live_…`, `ghp_…`), IBANs (mod-97 checked, written without spaces), the token after `Bearer` and hex strings or other long tokens of 32+ characters inside a text become `[redacted]`, whatever punctuation surrounds them; `name=value` text is cleaned like a query string (`a=1&token=…` → `a=1`; a single pair only when the name is sensitive and the value has 6+ characters with a digit or a capital, so `code=200` stays). An email / phone in `traits` is sent only as `email_sha256` / `phone_sha256`. A screen name is scanned the same way (a URL-shaped name is cleaned as a URL), and 9 or more digits in a row become `[redacted]`. The rules are heuristics with known limits (listed at the end of 6.1): do not rely on them to remove personal data. These rules are the same as in the web tracker and the Android SDK ([spec/PROTOCOL.md](../../spec/PROTOCOL.md), 6.1) and are checked against the shared vectors in `spec/vectors`.
- **Deep links.** An address longer than 8192 characters is ignored. The recorded address is cleaned by the common URL rules ([spec/PROTOCOL.md](../../spec/PROTOCOL.md), 6.1), the same as page URLs on the web: parameters with sensitive names (`token`, `auth_code`, `jwt`, `sig`, `sessionId`, `activation`, `ticket`, `telefon`, `parol` …) are removed, a parameter value shaped like a JWT or like another secret (32+ hex characters, a long token, a Luhn-valid card number, 20+ digits, a phone number starting with `+`) becomes `[redacted]` (the values of the six UTM parameters, of click IDs and of pagination cursors are exempt, except that a phone number starting with `+` and a card number in a UTM value are masked; any other `utm_…` name is an ordinary parameter; a parameter whose name itself looks like a secret is masked as a whole), path segments that look like a secret (a JWT, a segment containing 32+ hex characters in a row unless it is a static file name such as `<md5>.jpg`, a long base64 token, a Luhn-valid card number of 15–19 digits, 20+ digits, a phone number starting with `+`) and emails become `[redacted]`, a hash route (`#/…`) is kept and cleaned, any other fragment and the user name / password part are removed. After a path segment that is a hint (one to three words, the first or last of them starting with `reset`, `forgot`, `verify`, `confirm`, `activat`, `invit`, `login`, `token` … or being one of `otp`, `sso`, `auth`, `oauth`, `callback`, `session`, `join`, `mfa`, `2fa`) the next two segments and, when the hint ends the path, the query are examined more strictly: 6 or more digits directly after the hint and token-like segments (letters and digits mixed, irregular upper case, 16+ characters without an ordinary word) are masked, while ordinary words, dates, versions and static file names (`success`, `step2`, `2026-11-25`, `app.3f9a2b1c.js`) are kept. An order confirmation keeps its order number: after `confirm…` / `tesdiq…` with an order word (`order`, `checkout`, `payment`, `booking`, `purchase`, `sifaris`, `odenis`) in the same, the previous or the next segment, or after the single word `confirmation`, a reference made of capital letters, digits and hyphens is kept (`/order/confirm/2026112500123`, `/confirmation/AZ-778899`), while anything else is masked as after any hint (`/order/confirm/Zq7Lm2Xp9Rt4`, `/order/confirm/az-778899`), and so is a code of 6–8 digits after a payment confirmation (`/payment/confirmation/879609`); under a `confirm` hint an order-named parameter (`orderId`, `booking_ref`) with such a value is examined without the hint. Matrix parameters (`/reset;t=<token>`, also in a hash route: `#/reset;t=<token>`) are cleaned like query parameters with the hint of their segment, and a segment with `=` or `%2F` is masked when one of its pieces is a secret. A bare number of 10–14 digits is not masked without a hint; the one exception is 7–15 digits right after a phone word (`/tel/0501234567`). In a link with an app scheme (`myapp://reset/123456`) the host position is treated as the first path segment. The campaign (UTM and the 17 click IDs listed in [spec/PROTOCOL.md](../../spec/PROTOCOL.md), 6) is stored for 90 days; click IDs are not written to disk without eligibility for advertising, and the click IDs of a deep link received while consent is still undecided (first launch) stay in memory until the decision is known.
- **If the key is disabled** (the server responds with `unknown_key`) the SDK stops, but does not clear the queue and checks again after one hour. A `4xx` response without a recognised `error` code (from a proxy / CDN / WAF) is treated as a temporary error: events are kept and sent later.
- **In an app extension** the SDK does nothing (one line is written to the console).

## Advertising identifier (IDFA) and App Tracking Transparency

**On iOS 14+, if the user has not allowed tracking (the ATT status is not `authorized`), no batch the SDK sends is eligible for advertising**, even if ads consent (`ads: true`) has been given:

- `ctx.ids` contains no device identifier: neither `idfa` nor `idfv` (only the status itself, `ctx.ids.att`, is reported);
- click IDs (`gclid`, `fbclid`, etc.) are sent neither in the campaign, nor in the `DeepLinkOpen` address, nor in any URL value of `props` / `traits` or URL-shaped screen name, and are not written to disk either (UTM stays);
- `ctx.consent.ads` goes out as `false` in the batch, meaning the server does not forward the events to advertising platforms.

Device identifiers and click IDs are sent only when all of the following hold:

- there is ads consent (`ads: true`);
- the `collectAdvertisingId` option is on (it is on by default);
- iOS 14+: `ATTrackingManager.trackingAuthorizationStatus == .authorized`; iOS 13 (no ATT): ads consent is enough, while the IDFA is provided only when the "Limit Ad Tracking" setting is off;
- additionally for the IDFA: the identifier is not the zero UUID.

The status is re-read on every event and for every batch that is sent. When the permission or ads consent is withdrawn, events waiting in the queue are rewritten on disk and go out without identifiers, without click IDs (they are removed from the campaign, from the URL values in the `props` and `traits` of every queued event, not only from the `DeepLinkOpen` address, and from a URL-shaped screen name) and with `consent.ads: false`; there is no reverse direction (an event created without permission remains ineligible for advertising even after permission is granted). If there is no ads consent, `ctx.ids` is not sent at all and the ATT status is not read.

**The SDK never shows the permission prompt itself.** If you want the IDFA to be collected, the app must do this:

1. Add the `NSUserTrackingUsageDescription` key (with the explanation text to be shown to the user) to `Info.plist`.
2. Request the permission yourself at a suitable moment:

```swift
import AppTrackingTransparency

if #available(iOS 14, *) {
    ATTrackingManager.requestTrackingAuthorization { _ in }
}
```

If these are not done, nothing breaks: analytics events go out as before, they are just not forwarded to advertising platforms. An app that never wants device identifiers can turn them off once and for all. In that case neither the IDFA, nor the IDFV, nor the ATT status is read from the system; since the permission is unknown, on iOS 14+ batches are treated as ineligible for advertising (`consent.ads: false`):

```swift
SmartBee.initialize(key: "YOUR_KEY", options: SmartBeeOptions(collectAdvertisingId: false))
```

**Privacy manifest and App Store answers.** In the SDK's `PrivacyInfo.xcprivacy` file, the "Device ID" data type is declared for the analytics and third-party advertising purposes, as used for tracking; the top-level `NSPrivacyTracking` is `false` and `NSPrivacyTrackingDomains` is empty. The SDK's current behavior is as follows: device identifiers and click IDs leave the device only when the ATT permission is `authorized`, meaning data that counts as "tracking" is sent only with permission. If the app obtains the ATT permission and events are forwarded to advertising platforms, declaring tracking in **the app's own** privacy manifest (`NSPrivacyTracking`, and `NSPrivacyTrackingDomains` if needed) and in the "App Privacy" answers in App Store Connect is the app's responsibility.

## Structure

| File | Contents |
|---|---|
| `SmartBee.swift` | Public API, a single serial queue, the app lifecycle |
| `Core.swift` | All the logic; does not depend on UIKit, verified with `swift test` on macOS |
| `Internals.swift` | Protocols, remote configuration, sanitization and hash helpers |
| `Platform.swift` | File storage and queue (excluded from backup), URLSession transport, device context |
| `PrivacyInfo.xcprivacy` | Apple privacy manifest |

## Build and test

macOS is required. The commands are run from the package root (the folder containing `Package.swift`); CI runs the same commands on every push.

```sh
swift test
xcodebuild build -scheme SmartBeePixel -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

## Differences from the Android SDK

- `ScreenView` is not captured automatically: `SmartBee.screen()` is called manually (changing system methods is risky for the app).
- Deep links are passed in with `SmartBee.handleDeepLink(_:)`.
- The body is not compressed with gzip.
- The queue is written to the file with a short delay: an event is on disk within at most ~2 seconds even if there is no other SDK call, and it is written immediately when the app goes to the background and when it terminates (`willTerminate`). In a sudden crash, the events of the last second or two can be lost.
- Eligibility for advertising depends on the ATT permission (the section above); on Android, only on ads consent.
- `ctx.os.name` is the platform the SDK was compiled for: `iOS` (also for a Mac Catalyst build), `tvOS`, `watchOS`, `macOS` or `visionOS`. `ctx.device.type` is `phone`, `tablet` (iPad), `desktop` (Mac Catalyst, macOS), `tv` (tvOS), `watch` (watchOS) or `headset` (visionOS). The package declares iOS 13+ (and macOS, for `swift test` only); the other values are what the code sends when it is compiled for those platforms, which CI does not do.
- visionOS: the screen size is not sent and the ATT status is not read, so batches are never treated as eligible for advertising. CI builds the package for iOS and runs the tests on macOS; there is no visionOS build in CI.

## Not in this version

- Showing the ATT permission prompt (it is the app's job, see the section above).
- CocoaPods podspec.
- Tests that run on a device / simulator.
