# SmartBee Pixel — SDK API v1

Status: **1.0 — frozen with SDK 1.0.0**. The same methods, the same names and the same behaviour on every platform.

## Methods

| Method | Description |
|---|---|
| `init(key, options?)` | Starts the SDK. Not needed on the web (the key is in the script URL). There is one key per project: Android, iOS and web use the same key. In the mobile SDKs a repeated call does not restart the SDK and does not change the key: it is logged (always, not only in debug mode) and only its tightening options are applied (the `false` purposes of `consent`, `collectAdvertisingId: false`). A call with an invalid key is ignored and may be repeated later with a valid key. |
| `track(name, props?, options?)` | Sends an event. With `options.eventId` you can supply your own ID (for dedup with the server side); an invalid ID (one that does not match `^[A-Za-z0-9_.:-]{1,64}$`) is replaced by a generated UUID and a warning is logged in debug mode. In the mobile SDKs the event time is the moment of the call. |
| `identify(userId, traits?)` | Identifies the user. `user_id` is added to all later events. On all platforms a `userId` that looks like an e-mail address or a phone number is not sent or stored in clear text. E-mail: the SHA-256 of the value with surrounding whitespace removed and converted to lower case. Phone (7–15 digits starting with `+`, any 10–15 digits, or 9+ digits starting with `0`; space, hyphen, dot and parentheses count as separators): the SHA-256 of the digits only (the same value as `phone_sha256`). Short numeric IDs, IDs with letters and UUIDs are kept as they are. One leading `tel:`, `phone:`, `sms:`, `mailto:` or `email:` is ignored when the ID is examined, and an ID that contains an e-mail address (`John Doe <john@example.com>`) is hashed as that address. An ID shaped like a JWT is rejected; an ID shaped like a card number is sent as the SHA-256 of its digits ([PROTOCOL.md](PROTOCOL.md) 6.1). An empty ID or one longer than 128 characters is rejected. |
| `screen(name, props?)` | Mobile: a screen view. On the web `page(props?)`: a manual page view in an SPA. The screen name (and, on the web, the page title) is scanned like a text value of `props` ([PROTOCOL.md](PROTOCOL.md) 6.1): e-mail-like text, phone numbers, card numbers and secrets are replaced with `[redacted]`, and a name shaped like a URL, a path or a query string is cleaned by the URL rules; the screen name is cut to 128 characters. |
| `setConsent({ analytics, ads })` | Changes and stores consent. In the mobile SDKs a withdrawal takes effect immediately, in the calling thread (even if the SDK is busy or has not started yet, no request is sent for the withdrawn purpose from then on), it is written to disk in the calling thread so that it survives the death of the process ("Source of consent"), and it is never dropped when called before `init`. Android and iOS also have a variant that takes a consent object: `setConsent(SmartBeeConsent)`. |
| `reset()` | Sign-out: `user_id` is deleted, a new anonymous ID and session are created. In the mobile SDKs the stored campaign / click IDs, the screen name and the sequence number (`seq`) are deleted too. |
| `flush()` | Sends the queue immediately. |
| `getAnonymousId()` | Returns the current anonymous ID. In the mobile SDKs it returns the new ID right after `reset()` and `null` right after analytics consent is withdrawn; the ID created when consent is given again becomes available asynchronously. |
| `sdkVersion` | The version of the SDK (`SmartBee.sdkVersion`; in Java `SmartBee.getSdkVersion()`). In React Native and Flutter it is the version of the wrapper package, which is released together with the native cores it contains. Not available on the web. |

## `init` options

| Option | Default | Description |
|---|---|---|
| `consent` | from the configuration | The starting consent. On the web, a choice the visitor stored with `setConsent` takes precedence. On Android and iOS the more restrictive of the stored choice and this value wins for each purpose ("Source of consent"). The type name on Android and iOS is `SmartBeeConsent`. |
| `debug` | `false` | Verbose logging. |
| `autoEvents` | `true` | `false` turns every automatic event off (regardless of the configuration). |
| `endpoint` | `https://c.cdnsb.net` | Only for tests or a proxy. |
| `collectAdvertisingId` | `true` | Mobile SDKs only (Android, iOS, React Native, Flutter; not on the web): the device's advertising identifier. It is read and sent only while advertising consent is given; when consent is withdrawn it is also removed from events that have not been sent yet. With `false` it is never read. Android (`ctx.ids.gaid`): the app must include the `play-services-ads-identifier` library (the SDK does not bring it itself); it is not sent when the user has limited ad tracking; the value is refreshed on every transition to the foreground, and the first send of the process waits at most 2.5 seconds for the first read. iOS (`ctx.ids.idfa`, `ctx.ids.idfv`, `ctx.ids.att`): only with the user's ATT permission; the SDK does not show the permission prompt, the app requests it itself. On iOS 14+, when the ATT status is not `authorized` the batch is not eligible for advertising: `idfa` and `idfv` are not sent, click IDs are removed and `ctx.consent.ads` is sent as `false` even if advertising consent is given. On iOS the `false` option also turns off the IDFV and the reading of the ATT status (because the permission is unknown, on iOS 14+ batches are treated as not eligible for advertising). React Native and Flutter pass the option to the native SDK as it is. |

## Calls per platform

Web:

```js
smartbee('track', 'Purchase', { value: 250, currency: 'AZN', order_id: 'A-1001' });
smartbee('identify', 'user-42', { email: 'a@b.az' });
smartbee('setConsent', { analytics: true, ads: false });
```

Android (Kotlin):

```kotlin
SmartBee.init(context, "k7m2x9qa4t")
// With options: SmartBee.init(context, "k7m2x9qa4t", smartBeeOptions { consent(analytics = true, ads = false) })
// Java: new SmartBeeOptions.Builder().consent(true, false).build()
SmartBee.track("Purchase", mapOf("value" to 250, "currency" to "AZN", "order_id" to "A-1001"))
SmartBee.identify("user-42", mapOf("email" to "a@b.az"))
```

iOS (Swift):

```swift
SmartBee.initialize(key: "k7m2x9qa4t")
// With options: SmartBee.initialize(key: "k7m2x9qa4t", options: SmartBeeOptions(consent: SmartBeeConsent(analytics: true, ads: false)))
SmartBee.track("Purchase", props: ["value": 250, "currency": "AZN", "order_id": "A-1001"])
SmartBee.identify("user-42", traits: ["email": "a@b.az"])
```

React Native:

```ts
import SmartBee from '@smartbee/pixel';
await SmartBee.init('k7m2x9qa4t');
SmartBee.track('Purchase', { value: 250, currency: 'AZN', order_id: 'A-1001' });
```

Flutter:

```dart
await SmartBee.init('k7m2x9qa4t');
SmartBee.track('Purchase', props: {'value': 250, 'currency': 'AZN', 'order_id': 'A-1001'});
```

In Swift the method is called `initialize` because `init` is a keyword.

iOS has one additional method: `SmartBee.handleDeepLink(_ url: URL)`. On iOS the SDK cannot observe deep links and screen changes without replacing the app's system methods, so the app forwards them.

Android also has `SmartBee.handleDeepLink(url: String?)`. The SDK reads the deep link of a newly created Activity itself; this method is for two cases:

- a deep link delivered to a running Activity (`singleTop` / `singleTask`): it is called in `onNewIntent`;
- the launch link, when the SDK was started after the Activity had been created (for example after a consent dialog).

```kotlin
override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    SmartBee.handleDeepLink(intent.dataString)
}
```

Only `http` / `https` and hierarchical app schemes (`myapp://...`) count as deep links. Addresses such as `tel:`, `sms:`, `mailto:`, `geo:`, `content://`, `file://`, `data:`, `intent:` are sent neither automatically nor through this method. If the app calls both `setIntent` and `handleDeepLink` in `onNewIntent`, the deep link is counted once; on both platforms the same deep link forwarded again within 5 seconds is also counted once. On Android the old intent of an Activity opened from the "recent apps" list (`FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY`), and the same intent read again within 30 minutes when the process is restored, do not count as a deep link.

A URL longer than 8192 characters is not processed in any way and is ignored. The recorded URL (the `props.url` of `DeepLinkOpen`) is cleaned by the common URL rules of [PROTOCOL.md](PROTOCOL.md) 6.1, the same rules the web tracker applies to page URLs (shared vectors: [vectors/sanitize-url.json](vectors/sanitize-url.json)): query parameters with a sensitive name (English and Azerbaijani / Turkish names such as `telefon`, `parol`, `sifre`, `kart`) and those listed in `strip_params` are removed (both `&` and `;` are recognised as separators); a parameter value shaped like a JWT or like another secret (32 or more hex characters, a long token, a card number, 20 or more digits, a phone number starting with `+`) becomes `[redacted]`, and so does a parameter whose name itself looks like a secret; a parameter whose value is a URL or a query string is cleaned by the same rules (up to two levels); path segments that look like a secret and e-mail-like text become `[redacted]`, and after a hint segment (`reset`, `verify`, `activate`, `confirm`, `auth`, `callback`, `session`, `2fa`, …) the next two segments of the path and, when the hint ends the path, the query are examined more strictly (after an order confirmation such as `/order/confirm/` an order number written in capital letters, digits and hyphens is kept, anything else is masked); matrix parameters (`/reset;t=<token>`, also in a hash route) are cleaned like query parameters; in an app-scheme link (`myapp://reset/123456`) the host position is treated as the first path segment; a hash route (`#/…`, `#!…`) is kept and cleaned like a path, any other fragment and the user name / password part are removed; the result is cut to 2048 characters. The six UTM parameters (`utm_source`, `utm_medium`, `utm_campaign`, `utm_term`, `utm_content`, `utm_id`) and the 17 click-ID parameters (`fbclid`, `gclid`, `gbraid`, `wbraid`, `ttclid`, `msclkid`, `dclid`, `twclid`, `yclid`, `li_fat_id`, `sccid`, `rdt_cid`, `_gl`, `mc_eid`, `srsltid`, `epik`, `gad_source`; for the campaign `ScCid` is accepted as `sccid`) are kept and their values are not inspected for secrets, except that a phone number starting with `+` and a card number in a UTM value become `[redacted]`; click IDs are kept only when the batch is eligible for advertising. The campaign is stored for 90 days; click IDs are not written to disk without eligibility for advertising, and the click IDs of a deep link received while consent is still undecided are held in memory only until the decision is known.

### Android: calling from Java

All public methods are `@JvmStatic`. A `null` argument (`context`, key, options, name, `userId`, map, URL) does not throw: the call is simply ignored.

### Android: multi-process apps

The SDK works only in the app's main process. In another process (`android:process`) `init` and all other calls are ignored.

## Common behaviour

1. **It never breaks the app / site.** All errors inside the SDK are caught; public methods do not throw.
2. **Calls made before `init` are not lost.** They are queued and executed after `init`. In the mobile SDKs at most 100 ordinary calls (`track`, `identify`, `screen`, deep links, `flush`) are kept and further ones are dropped; consent, `reset` and lifecycle calls are never dropped. On Android and iOS, after `init`, calls made while the SDK is busy (for example in a slow request) are limited too: at most 100 `track` / `screen` calls wait, and when the list is full the oldest waiting one is dropped and counted in the debug log; `identify`, `flush`, `handleDeepLink`, `setConsent` and `reset` are never dropped.
3. **Events go through a queue.** In memory on the web (emptied with `sendBeacon` when the page is closed), on disk on mobile. On Android and iOS the on-disk queue is limited to `flush.max_queue` events and to 5 MB; beyond either limit the oldest events are dropped.
4. **Sending is batched.** According to the `flush` parameters of the configuration: when the interval elapses, when the batch is full, when the app goes to the background.
5. **Invalid input is dropped.** An invalid event name, `props` over the limit, forbidden keys; a warning is logged in debug mode. The keys of `props` / `traits` are checked by name, by the common rule of [PROTOCOL.md](PROTOCOL.md) 6.1, which is the same on the web and in the mobile SDKs (shared vectors: [vectors/sanitize-props.json](vectors/sanitize-props.json)): keys named as an e-mail, a phone or a secret are dropped at every depth; the value is taken into account, so that flags and counters stay (`email_verified: true`, `emails_sent: 5`, `has_password: true`), and so do settings named after a contact (`email_template: "welcome"`, `mobile: "ios"`); the recognised names include `session`, `session_id`, `auth`, `sid`, `api_key`, `cookie`, `pan`, `authorization`, `credit_card`, one-time codes such as `sms_code`, `totp`, `2fa_code`, names such as `signature`, `nonce`, `license_key`, `cardholder`, `account_number` and the Azerbaijani / Turkish names `telefon`, `mobil`, `nomre`, `parol`, `sifre` / `shifre`, `kart`, `eposta` / `poct`, `whatsapp` (the letters `ö ə ş ç ü ğ ı İ` are folded to ASCII first; Cyrillic names are not recognised), while `card_type`, `tokens_used`, `token_count`, `phone_model`, `gift_card`, `key` and `session_count` are kept; in `traits` the e-mail and phone values are hashed (also one level deep in a nested object); a key ending in `sha256` is kept verbatim only when its value is 64 hex characters. A text value that is a JWT or a card number becomes `[redacted]`; a text value, or a word in it, that is a URL, a path or a query string is cleaned by the URL rules; e-mail-like parts, phone numbers starting with `+`, card numbers, JWTs, known API-key prefixes, IBANs, `Bearer` tokens and hex strings or other long tokens of 32 or more characters inside other text become `[redacted]`, whatever punctuation surrounds them; `name=value` text with a sensitive name is cleaned like a query string.
6. **Personal data is hashed.** The `email` and `phone` in `identify` are converted to SHA-256 before they leave the device ([PROTOCOL.md](PROTOCOL.md), 6.1).
7. **Consent comes before everything.** With `analytics: false` nothing is sent or stored. In the mobile SDKs, when analytics has been explicitly denied (by the app or by the user) the configuration is not requested either and the advertising identifier / ATT status is not read.
8. **It does not block the main thread.** In the mobile SDKs disk and network work is done on a background thread.

### Source of consent (mobile)

Consent can be stated explicitly by the app (the `consent` option of `init`) or by the user (`setConsent`; the choice is stored). Separately for each purpose (`analytics`, `ads`):

- When both exist, the **more restrictive** one wins: an explicit `false` passed to `init` takes precedence over a stored `true`, and a stored `false` over a `true` in `init`.
- A `setConsent` call at run time is the most recent explicit choice: it is stored and, in that process, replaces the value from `init` (and the restrictions of a repeated `init`). At the next launch the more restrictive of the stored choice and the `init` value applies again.
- When neither exists, the `consent_default` value of the key's configuration applies. The configuration never touches an explicitly stated consent: it can neither raise nor change it.
- A repeated `init` call can only tighten consent.

Additional rules:

- If the app passed no `consent` and there is no stored choice, consent is recomputed from `consent_default` every time the configuration is received. If `analytics` is `false`, the queue and the identifiers (anonymous ID, user, session, sequence number, campaign) are deleted.
- On Android and iOS, at the first start (the configuration has never been received and the app passed no `consent`) nothing is written to disk and nothing is sent until the first configuration response. Events wait in memory (at most 100) and `getAnonymousId()` returns `null`. To avoid the wait, pass `consent` to `init`. If in this state the server does not recognise the key (`unknown_key`) or the configuration turns the SDK off (`enabled: false`), the identifiers are not written to disk.
- When consent is withdrawn and given again, a new anonymous ID is created; `AppInstall` is also evaluated (once) when consent is given after the SDK has started.
- The choice is written to disk first and then takes effect in memory; if the write fails, the withdrawal is still applied in memory and the write is retried.
- **A withdrawal survives the death of the process.** A `setConsent` call that denies a purpose, and a repeated `init` that tightens consent, is recorded in a small file in the calling thread before the call returns; the SDK's worker removes the record once it has executed the call and the consent is in the store. If the process dies in between, the record is applied at the next start before anything is sent: the stated consent is restored, and after a withdrawal of `analytics` the old queue and the identifiers are deleted (even if consent was granted again afterwards). Android does not `fsync` this file: it is meant to survive the death of the process.
- **Queued events lose their advertising data on disk.** When `ads` consent is withdrawn (on iOS also when the ATT status is no longer `authorized`), the events already in the on-disk queue are rewritten: `ctx.ids` and the click IDs of `ctx.campaign` are removed, `ctx.consent.ads` becomes `false`, click IDs are removed from the URL values in the `props` and `traits` of every queued event (not only from the `props.url` of `DeepLinkOpen`) and from a URL-shaped `screen.name`, also from the current screen name kept in memory for later events; the stored campaign loses its click IDs. These events stay ineligible for advertising after consent is granted again. On iOS the advertising state (consent and ATT status) is read again for every batch of a flush, so a withdrawal in the middle of a multi-batch flush applies to the remaining batches.
- **Click IDs received while consent is undecided are not persisted.** At the first start (see above) the campaign and the `DeepLinkOpen` event of a deep link are held in memory; when the decision arrives without eligibility for advertising, the click IDs are removed before anything is written to disk.
- **A corrupt local store means "denied until restated".** If the store cannot be parsed or the stored consent value is not a valid one, both purposes are treated as denied (the configuration's `consent_default` is not applied and no request is made) until `setConsent` is called. The `consent` option of `init` cannot loosen this state.
- **`consent_default` fails closed.** When the configuration contains `consent_default`, a purpose is granted only by a JSON `true`: a missing or non-boolean member (or a `consent_default` that is not an object) counts as `false`. When the member is absent altogether, both purposes default to `true`. The web tracker differs: there a purpose is denied only by an explicit `false` ([PROTOCOL.md](PROTOCOL.md) 7). The server always sends both members as booleans.

### Disabled key and rejection responses

In line with the tables in [PROTOCOL.md](PROTOCOL.md) 5.6. The first four points describe the mobile SDKs, the last one the web tracker:

- The SDK treats the key as disabled only on an explicit response of the server: when the configuration's `404` response or a batch's `403` / `404` response carries `error: unknown_key` in its JSON body. In this state nothing is sent and no new events are collected, but the queue and the cached configuration are not deleted; after one hour the configuration is requested again.
- A batch is deleted only on the documented final codes: a `400` with `empty_body`, `bad_gzip`, `bad_json`, `bad_batch` or `bad_chars`; a `403` with `origin_not_allowed`, `app_not_allowed`, `platform_not_enabled`, `unknown_platform` or `browser_not_allowed`; a `403` / `404` with `unknown_key` (which also disables the key); a `413` for a single-event batch with `body_too_large`, `context_too_large` or `too_many_events`. A `413` for a batch of several events splits the batch in half, whatever the body. Everything else is transient: a `4xx` without a recognised code for its status (a WAF's `400`, a `422` with or without a body, a body-less `413` for a single event), `3xx` (redirects are not followed), `408`, `429`, `5xx` and a network error. The batch is kept and resent with increasing backoff: 5 s, doubling up to 1 hour, ±20% jitter. For `5xx`, network errors, `408` and `429` there is no limit on the number of attempts. A batch that gets 3 consecutive `4xx` answers without a documented error code (not `408` / `429`) is sent row by row, and a single event that is still rejected that way is dropped after 5 attempts or 3 days, whichever comes first. A `Retry-After` given in whole seconds is clamped to 1–3600 s and applied with a positive jitter of 0–20%.
- The cached configuration, the ETag and the queue are bound to the key and to the `endpoint`: they are discarded when the app is started with a different key or URL (the identifiers and consent are kept).
- Configuration values are clamped to safe bounds: `ttl_s` 60 s – 7 days, `session_timeout_s` 60 s – 24 hours, `flush.interval_s` 10–3600, `flush.max_batch` 10–100, `flush.max_queue` 10–5000.
- Web tracker: a batch is deleted on the same `400` / `403` codes (it has no "disabled key" state: after `403 unknown_key` it only deletes the batch) and on every `413` (after one resend without the stored campaign when the context is too large). A `4xx` without a recognised code (including `404` and `422`), `408`, `429`, `5xx`, a network error and a redirect (not followed when the batch is sent with `fetch`) are transient, but the retries are in memory and limited: at most 5 retries per batch, after 5, 10, 20, 40 and 80 s (±20%), then the batch is deleted. `Retry-After` is honoured on `408` / `429`, up to 300 s.

## Automatic events

| Event | Platform | When |
|---|---|---|
| `PageView` | web | When the page loads and when the URL changes in an SPA |
| `FormSubmit` | web | When a form is submitted |
| `OutboundClick` | web | When a link to another domain is clicked |
| `ContactClick` | web | When a `tel:`, `mailto:` or WhatsApp link is clicked |
| `AppInstall` | mobile | At the first launch. On Android it is not sent for existing users when the SDK was added to an existing app with an update |
| `AppUpdate` | mobile | At the first launch after the version changes |
| `AppOpen` | mobile | When the app comes to the foreground (once per return from the background; screen rotation and moving between screens do not count) |
| `SessionStart` | all | When a new session starts |
| `ScreenView` | Android | When the Activity changes (the name is the name of the Activity class). After the app calls `screen()`, automatic names stop. On iOS, React Native and Flutter `screen()` is called manually |
| `DeepLinkOpen` | mobile | When the app is opened through a deep link. On Android automatically for a new Activity and with `SmartBee.handleDeepLink(url)` for `onNewIntent`; on iOS the app calls `SmartBee.handleDeepLink(url)`. Without advertising consent, click IDs (`fbclid`, `gclid` and so on) are removed from `props.url`; UTM parameters are kept |

All of them are sent with `origin: auto` and can be turned off remotely with the `auto` switches of the configuration. `SessionStart` is the exception: it has no `auto` switch of its own and is turned off only with `autoEvents: false`.

## Wrappers (React Native, Flutter)

- They hold no logic of their own: every call is forwarded to the native SDK.
- `sdk.wrapper` and `sdk.wrapper_version` are sent in the batch.
- `init` returns a promise / future of a boolean: `true` when the call was handed to the native SDK, `false` otherwise (native module missing, malformed key). It does not wait for the SDK to finish starting.
- Consent fails closed: a purpose that is missing or is not a boolean in the consent passed to `init` or `setConsent` is treated as `false`.
- `ScreenView` is not captured automatically (there is only one native screen); `screen()` is called manually.
- In a wrapper the native SDK does not read deep links itself; the wrapper forwards them. React Native: automatically through the `Linking` module (iOS and Android), unless `autoEvents` is `false`; `SmartBee.handleDeepLink(url)` is available for other cases. Flutter: the app passes the URL with `SmartBee.handleDeepLink(url)` (iOS and Android).
