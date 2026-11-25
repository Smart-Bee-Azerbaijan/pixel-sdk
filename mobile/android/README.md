# SmartBee Pixel — Android SDK

Kotlin (also callable from Java), `minSdk 21`. The only dependency is the Kotlin standard library; it is compatible with projects on Kotlin 1.9 and newer.

## Usage

```kotlin
// Application.onCreate
SmartBee.init(this, "YOUR_KEY")

SmartBee.track("Purchase", mapOf("value" to 250, "currency" to "AZN", "order_id" to "A-1001"), eventId = "order:A-1001")
SmartBee.identify("user-42", mapOf("email" to "a@b.az"))   // the email is hashed on the device
SmartBee.setConsent(analytics = true, ads = false)
SmartBee.reset()                                             // log out
val version = SmartBee.sdkVersion                            // "1.0.0"
```

Options are built with `SmartBeeOptions.Builder` (Java and Kotlin) or with the `smartBeeOptions { }` function (Kotlin); there is no public constructor:

```kotlin
SmartBee.init(this, "YOUR_KEY", smartBeeOptions {
    consent(analytics = true, ads = false)   // or consent(SmartBeeConsent(true, false))
    debug(BuildConfig.DEBUG)
    collectAdvertisingId(false)
})
```

```java
SmartBeeOptions options = new SmartBeeOptions.Builder()
        .consent(true, false)
        .debug(BuildConfig.DEBUG)
        .build();
SmartBee.init(this, "YOUR_KEY", options);
SmartBee.setConsent(new SmartBeeConsent(true, true));
String version = SmartBee.getSdkVersion();
```

| `Builder` method | By default | Description |
|---|---|---|
| `consent(SmartBeeConsent?)` / `consent(analytics, ads)` | `null` | The consent the app declares at startup |
| `debug(Boolean)` | `false` | Verbose logging (Logcat, tag `SmartBee`) |
| `autoEvents(Boolean)` | `true` | `false`: all automatic events are turned off |
| `endpoint(String?)` | `https://c.cdnsb.net` | For testing or a proxy only |
| `collectAdvertisingId(Boolean)` | `true` | `false`: the GAID is never read |

Full API: [../../spec/SDK-API.md](../../spec/SDK-API.md).

## What you need to know

- **No call throws an exception**, even with a `null` argument (including calls from Java).
- **Consent.** For each purpose the most restrictive explicit value wins: if either the `consent` option of `init` or the choice the user previously saved with `setConsent` says `false`, the result is `false`. If neither exists, the `consent_default` from the key's configuration applies. A runtime `setConsent` call is the most recent choice and replaces the value from `init`.
- **Withdrawing consent is immediate.** `setConsent(false, …)` takes effect on the calling thread: even if the SDK is busy or has not started yet, no request is sent from then on, and `getAnonymousId()` returns `null` immediately. When analytics is explicitly declined, the configuration is not requested either and the GAID is not read.
- **Withdrawing consent is durable.** A `setConsent` call that denies a purpose (and a repeated `init` that tightens consent) is also written to a small file in `noBackupFilesDir` on the calling thread, before the call returns. If the process dies before the worker thread has executed the call, the withdrawal is applied at the next start before anything is sent: after a withdrawal of analytics the old queue and the identifiers are deleted, even if consent was granted again afterwards. The file is not `fsync`ed: it is meant to survive the death of the process. The worker removes it once the consent is in the database.
- **Queued events are cleaned on disk when ads consent is withdrawn.** The rows already in the queue are rewritten without `ctx.ids` and without click IDs (in `ctx.campaign`, in the URL values of the `props` and `traits` of every queued event, not only in the `DeepLinkOpen` address, and in a URL-shaped `screen.name`; the current screen name in memory is cleaned too), with `ctx.consent.ads: false`; the stored campaign loses its click IDs. These events stay non-ads even if ads consent is granted again before they are sent.
- **A corrupt database means "denied until restated".** If the SDK's database is corrupt (Android recreates it) or the stored consent value is unreadable, both purposes are treated as denied, not as "never stated": the `consent_default` of the configuration is not applied and nothing is requested until `setConsent` is called. The `consent` option of `init` cannot loosen this state: only a new `setConsent` call states consent again.
- **`consent_default` fails closed.** When the configuration contains `consent_default`, a purpose is granted only by a JSON `true`; a missing or non-boolean member counts as `false`. (The server always sends both members as booleans.)
- **`init` is called once.** A repeated call does not restart the SDK and does not change the key: it is logged to Logcat and only its tightening options (the `false` purposes of `consent`, `collectAdvertisingId(false)`) are applied.
- **Calls made before `init`** are kept in memory: at most 100 ordinary calls (`track`, `identify`, `screen`, `flush`, `handleDeepLink`), further ones are dropped and their number is written to the debug log; `setConsent` and `reset` are never dropped.
- **Calls made while the SDK is busy are capped.** All work runs on one worker thread. While it is busy (for example in a slow request), at most 100 `track` / `screen` calls wait for it; when the list is full the oldest waiting one is dropped and the number of dropped calls is written to the debug log. `identify`, `flush`, `handleDeepLink`, `setConsent`, `reset` and lifecycle calls are never dropped, and the order of the calls does not change.
- **The on-disk queue is capped** at `flush.max_queue` events (1000 by default) and at 5 MB (the UTF-8 size of the stored contexts and events); beyond either limit the oldest events are dropped.
- **Delivery.** A batch is deleted only when the server accepts it or rejects it with a documented final code ([spec/PROTOCOL.md](../../spec/PROTOCOL.md), 5.6). A `4xx` without such a code (a WAF's `400`, a `422`, a body-less `413` for a single event), a `3xx` (redirects are not followed), `408`, `429`, `5xx` and a network error keep the batch; it is retried after 5 s, doubling up to 1 hour (±20%), or after the server's `Retry-After`. `5xx`, network errors, `408` and `429` are retried without a limit on the number of attempts. A batch that gets 3 consecutive `4xx` answers without a documented error code (other than `408` / `429`) is sent one event at a time; a single event that is still rejected that way is dropped after 5 attempts or 3 days, whichever comes first (debug log), and the rest of the queue goes on.
- **`reset()`** clears the user, the stored campaign / click IDs, the screen name and the event counter; the new anonymous ID can be read from `getAnonymousId()` immediately.
- **The event time** is the moment of the call (not the moment the worker thread processes it).
- **Personal data.** A `userId` that looks like an email or a phone number is not sent in the clear (its SHA-256 is sent). The same applies to an ID that contains an email address (`John Doe <john@example.com>`, also with two `@` as in `user@shop.az@tenant`; the fullwidth `＠` counts as `@`); one leading `tel:`, `phone:`, `sms:`, `mailto:` or `email:` is ignored. A `userId` shaped like a JWT is rejected, and one shaped like a card number is sent as the SHA-256 of its digits. In `props` / `traits`, keys are judged by the words of their name and by their value (regardless of case and of `_` / `-` spelling, at all depths; Azerbaijani / Turkish names such as `telefon`, `mobil`, `nomre`, `parol`, `sifre`, `kart`, `eposta`, `poct`, `whatsapp` are recognised too, with `ö ə ş ç ü ğ ı İ` folded to ASCII, while Cyrillic names are not): keys that indicate an email, a phone, a password, a token, a card, a session, an API key, a cookie or a one-time code are dropped (`session`, `auth`, `sid`, `sms_code`, `otp_code`, `totp` and `2fa_code` included; with a value that is not a flag also `signature`, `sig`, `nonce`, `license_key`, `cardholder`, `creditcard`, `cc_number`, `account_number`, `pinkod`), while counters, flags and descriptive names are kept (`token_count`, `email_verified`, `has_password: true`, `card_type`, `phone_model`, `gift_card`, `email_template: "welcome"`, `mobile: "ios"`). A `*_sha256` key is kept only with a 64-character hex value. Text values are scanned: a value that is a JWT or a card number becomes `[redacted]`; a value, or a word in it, that is a URL, a path (`/…`) or a query string (`?…`) is cleaned by the URL rules; emails, phone numbers starting with `+`, card numbers (also written with `/`, no-break or thin spaces), JWTs, known API-key prefixes (`sk_live_…`, `ghp_…`), IBANs (mod-97 checked, written without spaces), the token after `Bearer` and hex strings or other long tokens of 32+ characters inside a text become `[redacted]`, whatever punctuation surrounds them; `name=value` text is cleaned like a query string (`a=1&token=…` → `a=1`; a single pair only when the name is sensitive and the value has 6+ characters with a digit or a capital, so `code=200` stays). An email / phone in `traits` is sent only as `email_sha256` / `phone_sha256`. A screen name is scanned the same way (a URL-shaped name is cleaned as a URL), and 9 or more digits in a row become `[redacted]`. The rules are heuristics with known limits (listed at the end of 6.1): do not rely on them to remove personal data. These rules are the same as in the web tracker and the iOS SDK ([spec/PROTOCOL.md](../../spec/PROTOCOL.md), 6.1) and are checked against the shared vectors in `spec/vectors`. `props` / `traits` are copied at the moment of the call; a structure larger than 2000 elements or 100 000 characters is dropped (the event is sent without parameters).
- **If the key is disabled** (the server responds with `unknown_key`) the SDK stops, but does not clear the queue and checks again after one hour. A `4xx` response without a recognised `error` code (from a proxy / CDN / WAF) is treated as a temporary error: events are kept and sent later.
- **It runs only in the main process.** In multi-process apps, calls in the other processes do nothing.
- **First launch.** If consent is not given in `init` and there is no stored configuration, the SDK waits for the server's response: until then events are kept in memory (at most 100), nothing is written to disk and nothing is sent. `getAnonymousId()` returns `null` during this period.
- **Deep links.** When the app is opened by a deep link, it is captured automatically. For a deep link that arrives while the app is open, call `setIntent(intent)` and `SmartBee.handleDeepLink(intent.dataString)` in `onNewIntent`. Only `scheme://…` addresses count; `tel:`, `sms:`, `mailto:`, `geo:`, `content:`, etc. are not sent. An address longer than 8192 characters is ignored. The stale intent of an Activity opened from the "Recent apps" list (`FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY`) and the same intent re-read within 30 minutes when the process is restored are not counted as a new deep link. The recorded address is cleaned by the common URL rules ([spec/PROTOCOL.md](../../spec/PROTOCOL.md), 6.1), the same as page URLs on the web: parameters with sensitive names (`token`, `auth_code`, `jwt`, `sig`, `sessionId`, `activation`, `ticket`, `telefon`, `parol` …) are removed, a parameter value shaped like a JWT or like another secret (32+ hex characters, a long token, a Luhn-valid card number, 20+ digits, a phone number starting with `+`) becomes `[redacted]` (the values of the six UTM parameters, of click IDs and of pagination cursors are exempt, except that a phone number starting with `+` and a card number in a UTM value are masked; any other `utm_…` name is an ordinary parameter; a parameter whose name itself looks like a secret is masked as a whole), path segments that look like a secret (a JWT, a segment containing 32+ hex characters in a row unless it is a static file name such as `<md5>.jpg`, a long base64 token, a Luhn-valid card number of 15–19 digits, 20+ digits, a phone number starting with `+`) and emails become `[redacted]`, a hash route (`#/…`) is kept and cleaned, any other fragment and the user name / password part are removed. After a path segment that is a hint (one to three words, the first or last of them starting with `reset`, `forgot`, `verify`, `confirm`, `activat`, `invit`, `login`, `token` … or being one of `otp`, `sso`, `auth`, `oauth`, `callback`, `session`, `join`, `mfa`, `2fa`) the next two segments and, when the hint ends the path, the query are examined more strictly: 6 or more digits directly after the hint and token-like segments (letters and digits mixed, irregular upper case, 16+ characters without an ordinary word) are masked, while ordinary words, dates, versions and static file names (`success`, `step2`, `2026-11-25`, `app.3f9a2b1c.js`) are kept. An order confirmation keeps its order number: after `confirm…` / `tesdiq…` with an order word (`order`, `checkout`, `payment`, `booking`, `purchase`, `sifaris`, `odenis`) in the same, the previous or the next segment, or after the single word `confirmation`, a reference made of capital letters, digits and hyphens is kept (`/order/confirm/2026112500123`, `/confirmation/AZ-778899`), while anything else is masked as after any hint (`/order/confirm/Zq7Lm2Xp9Rt4`, `/order/confirm/az-778899`), and so is a code of 6–8 digits after a payment confirmation (`/payment/confirmation/879609`); under a `confirm` hint an order-named parameter (`orderId`, `booking_ref`) with such a value is examined without the hint. Matrix parameters (`/reset;t=<token>`, also in a hash route: `#/reset;t=<token>`) are cleaned like query parameters with the hint of their segment, and a segment with `=` or `%2F` is masked when one of its pieces is a secret. A bare number of 10–14 digits is not masked without a hint; the one exception is 7–15 digits right after a phone word (`/tel/0501234567`). In a link with an app scheme (`myapp://reset/123456`) the host position is treated as the first path segment. The campaign (UTM and the 17 click IDs listed in [spec/PROTOCOL.md](../../spec/PROTOCOL.md), 6) is stored for 90 days; click IDs are not written to disk without ads consent, and the click IDs of a deep link received while consent is still undecided (first launch) stay in memory until the decision is known.
- **When the SDK is added to an existing app**, `AppInstall` is not sent for existing users.
- **New version notice.** When `debug = true` and a newer version of the SDK has been released, one line per process is written to Logcat (tag `SmartBee`); behavior does not change.

## Advertising ID (GAID)

The SDK can send the Google advertising ID as `ctx.ids.gaid`, but **only when there is ads consent (`ads`)**. When consent is withdrawn, the value is cleared from memory and is not sent in any later batch (including older events waiting in the queue, which stay non-ads even after a later re-grant). The value is not written to disk.

- **Library.** The SDK does not bring in the Google library itself. For the GAID to be collected, the app must add it:

  ```kotlin
  implementation("com.google.android.gms:play-services-ads-identifier:18.2.0")
  ```

  If the library is missing (or the device has no Google Play services) nothing is collected and nothing breaks.
- **Permission.** The SDK's manifest declares the `com.google.android.gms.permission.AD_ID` permission (in apps targeting Android 13+ the ID comes back as all zeros without it). An app that does not want it can remove it in its own manifest:

  ```xml
  <manifest xmlns:android="http://schemas.android.com/apk/res/android" xmlns:tools="http://schemas.android.com/tools">
      <uses-permission android:name="com.google.android.gms.permission.AD_ID" tools:node="remove" />
  </manifest>
  ```
- **Turning it off.** `SmartBeeOptions.Builder().collectAdvertisingId(false)`: the GAID is never read.
- **Google Play.** If the GAID is collected, the advertising ID ("Device or other IDs") must be declared in the "Data safety" form in Play Console and the "Advertising ID" declaration must be filled in.
- If the user has limited ad tracking on the device or has deleted the advertising ID, the GAID is not sent. The value is read on a background thread and is refreshed every time the app comes to the foreground (the user can reset it). The first send of the process waits at most 2.5 seconds for the first read, so that `AppInstall` / `AppOpen` do not go out without the GAID; event collection is not blocked during this time.

## Structure

| File | Contents |
|---|---|
| `SmartBee.kt` | Public API (`SmartBee`, `SmartBeeOptions`, `SmartBeeConsent`, `smartBeeOptions`), a single background thread, the Activity lifecycle |
| `Core.kt` | All the logic; does not depend on Android, verified with JVM tests |
| `Internals.kt` | Interfaces, remote configuration, sanitization and hash helpers |
| `AndroidImpl.kt` | SQLite database (queue and storage, excluded from backup), HTTPS transport, device context, reading the advertising ID |

## Build and test

```sh
./gradlew :pixel:testDebugUnitTest :pixel:assembleRelease
```

JDK 17+ and the Android SDK (compileSdk 35) are required. The tests verify batches against the `spec` schema and vectors. The module is built in Kotlin's "explicit API" mode: the public surface is only the four names above, everything else is `internal`.

## Screen names

The automatic `ScreenView` takes the Activity class name as the screen name. In release builds where the code is minified (R8) this name becomes meaningless; in such apps and in single-Activity (Compose) apps, call `SmartBee.screen("name")`.

## Not in this version

- Play Install Referrer: it requires a dependency on a Google library.
- Publishing to Maven Central (the package is currently served from the `https://c.cdnsb.net/maven` repo: `az.smartbee:pixel`).
- Tests that run on a device / emulator (instrumented).
