# SmartBee Pixel — Protocol v1

Status: **1.0 — frozen with SDK 1.0.0**. Everything in this document is frozen: only new, optional fields may be added.

Machine-checkable form: [schema/batch.v1.schema.json](schema/batch.v1.schema.json), [schema/config.v1.schema.json](schema/config.v1.schema.json). If the document and the schema contradict each other, the schema prevails.

## 1. Names

The brand name is used only in this table and on the public surface of the SDKs. The protocol itself (paths, field names) contains no brand.

| Place | Value |
|---|---|
| Host | `c.cdnsb.net` |
| Web global function | `smartbee` |
| Android | `az.smartbee:pixel`, class `SmartBee` |
| iOS | `SmartBeePixel`, class `SmartBee` |
| React Native | `@smartbee/pixel` |
| Flutter | `smartbee_pixel` |

## 2. Concepts

- **Project**: one customer's site and apps. A project has **one key**: the website, the Android app and the iOS app use the same key; forwarding to advertising platforms is also set up once per project.
- **Source**: the project's key and its three allow-lists: `domains` (the website's domains), `android_apps` (Android `applicationId`s), `ios_apps` (iOS bundle IDs). An empty list means that the platform is not enabled for this key; at least one list is non-empty. Technically a project may have several keys (for example, for production and test environments), but the usual case is one project = one key.
- **Key**: `^[a-z0-9]{8,16}$` (new keys are 16 digits). It is not secret (it is visible in the site's code and inside the app). The server verifies it together with the list that matches the batch's platform (see 5.7).

## 3. Endpoints

| Method and path | Purpose |
|---|---|
| `GET /v1/{key}.js` | Web script. The configuration is inside the script. |
| `GET /v1/{key}/config` | Configuration for the mobile SDKs (JSON). |
| `POST /v1/e` | Event batch. Same format for web and mobile. |

Unknown or disabled key:

- `/v1/{key}.js` — `200`, a script that does nothing (so that there is no console error on the customer's site). This is not the full tracker but a small stub: it replaces the `smartbee` function with a function that sends and stores nothing, empties the snippet's queue (`q`) and answers only `getAnonymousId` (with `null`).
- `/v1/{key}/config` — `404`, body `{"ok":false,"error":"unknown_key"}`. The SDK treats the key as "disabled" only with this recognised body; any other `404` (see 5.6) is transient.
- `/v1/e` — `403 unknown_key`.

The key is the same, the platforms differ:

- `/v1/{key}.js` serves a working script only for a key enabled for web (one that has at least one domain); for a key without a domain, a script that does nothing is returned, as for an unknown key.
- `/v1/{key}/config` works for every active key (regardless of which platforms are enabled): there is one configuration per key, with separate `auto` switches for web and mobile.
- `/v1/e` verifies the batch against the list that matches `ctx.platform` (5.7).

## 4. Web snippet

```html
<script>
!function(w,d,n,u,t,s){if(typeof w[n]=='function')return;t=w[n]=function(){t.d||t.q.length>499||t.q.push(arguments)};t.q=[];t.l=+new Date;t.v=1;
function x(){t.d=1;t.q.length=0}
try{s=d.createElement('script');s.async=1;s.src=u;s.onerror=x;(d.head||d.documentElement).appendChild(s)}catch(e){x()}
}(window,document,'smartbee','https://c.cdnsb.net/v1/KEY.js');
</script>
```

The snippet's contract with the tracker:

- `window.smartbee.q` — the list of calls made before the script loads (each one an `arguments` object). When the tracker loads, it executes them in order.
- `window.smartbee.l` — the time at which the snippet ran (ms).
- `window.smartbee.v` — the snippet version (`1`).
- `window.smartbee.d` — `1` if the script could not be loaded (`onerror`, a CSP / Trusted Types exception): the queue is emptied, subsequent calls do nothing and do not throw.
- The queue is limited to 500 calls (it does not grow even if the script never loads).
- If the snippet is included a second time, it does nothing; a second snippet / script with a different key is also ignored (one key per page).
- No `init` call is needed: the key is in the script's URL, the tracker starts by itself and sends the first `PageView` by itself.

The script is served with `Cache-Control: private, no-cache` and an `ETag`: the browser revalidates on every load, and intermediate caches (CDN) do not store it. The ETag is computed from the tracker version and the configuration's `rev` value.

The script is public and is served without cookies: the response carries `Access-Control-Allow-Origin: *`, `Cross-Origin-Resource-Policy: cross-origin` and `Timing-Allow-Origin: *`, so it can also be loaded with `<script crossorigin="anonymous">` (the page's error reports are then readable). This is separate from the credentialed CORS of `POST /v1/e` (5.8).

Script requests are not counted against the general read limit (per IP): visitors sharing one address (carrier NAT) must not push the script into `429` on the customer's site. The script has its own, considerably higher budget, and it is per (IP, key) pair (`200` and `304` are counted together). Separately, requests from one IP for non-working keys (unknown, disabled, not enabled for web) are counted; when the threshold is reached, such requests from that IP receive `429`, while the script of a working key continues to be served.

## 5. Event batch: `POST /v1/e`

### 5.1 Request

- Body: JSON, UTF-8.
- `Content-Type`: web sends `text/plain` (so that `sendBeacon` works without a preflight), mobile sends `application/json`. The server reads the body as JSON regardless of the header.
- Mobile may use `Content-Encoding: gzip`.
- Web requests are sent with cookies (`credentials: include`).

### 5.2 Limits

| Limit | Value |
|---|---|
| Number of events in a batch | 1–100 |
| Body size (uncompressed) | 500 KB; 60 KB for web `sendBeacon` |
| Size of a single event | 32 KB |
| Size of the context (`ctx`) | 8 KB |
| Depth of `props` / `traits` | 4 levels |
| Event name | `^[A-Za-z][A-Za-z0-9_]{0,63}$` |

A batch that exceeds a limit receives `413`. The SDK splits the batch itself before sending.

### 5.3 Batch structure

```json
{
  "v": 1,
  "key": "k7m2x9qa4t",
  "sent_at": "2026-11-25T07:00:05.120Z",
  "sdk": { "name": "android", "version": "1.0.0" },
  "ctx": { "platform": "android" },
  "events": [ { "id": "…", "type": "track", "name": "Purchase", "ts": "…", "anon_id": "…" } ]
}
```

| Field | Required | Description |
|---|---|---|
| `v` | yes | Protocol version, `1`. |
| `key` | yes | The project's key (the same on all platforms). |
| `sent_at` | yes | The moment of sending, by the client clock. The server compares it with the receive time and corrects the client clock error: the stored time of an event is `ts + (receive time − sent_at)`. `ts` and `sent_at` must be written with the same clock. |
| `sdk.name` | yes | `web`, `android`, `ios`. |
| `sdk.version` | yes | SDK version (semver). |
| `sdk.wrapper` | no | `react-native` or `flutter`. |
| `sdk.wrapper_version` | no | Version of the wrapper. |
| `ctx` | yes | Context, see 5.4. Applies to all events in the batch. |
| `events` | yes | Events, see 5.5. |

If the context changes (for example, the app was updated), the SDK sends the events with the old context in a separate batch.

### 5.4 Context (`ctx`)

Only `platform` is required. The rest are sent when available.

| Field | Platform | Description |
|---|---|---|
| `platform` | all | `web`, `android`, `ios`. |
| `locale` | all | For example `az-AZ`. |
| `tz` | all | IANA name, for example `Asia/Baku`. |
| `screen` | all | `{ "w": 1080, "h": 2400, "density": 2.75 }`. |
| `consent` | all | `{ "analytics": true, "ads": true }`, see section 7. |
| `campaign` | all | Last touch: `utm_source`, `utm_medium`, `utm_campaign`, `utm_term`, `utm_content` and the click IDs listed in section 6 (`fbclid`, `gclid`, `ttclid`, etc.). |
| `ids` | all | Platform identifiers: `fbp`, `fbc`, `ttp` (web); `gaid` (Android); `idfa`, `idfv`, `att` (iOS). `att` — the state of the ATT permission (string): `authorized`, `denied`, `restricted`, `not_determined`; `idfa` is sent only when it is `authorized`. |
| `ua` | web | `navigator.userAgent`. |
| `app` | mobile | `{ "id": "az.shop.app", "version": "1.2.3", "build": "45" }`. `id` is the package name (Android `applicationId`) / bundle ID (iOS) and is verified against the key's matching list (5.7). |
| `os` | mobile | `{ "name": "Android", "version": "14" }`. `name`: the Android SDK sends `Android`; the iOS SDK sends the platform it was compiled for: `iOS` (also for a Mac Catalyst build), `tvOS`, `watchOS`, `macOS` or `visionOS`. |
| `device` | mobile | `{ "manufacturer": "Google", "model": "Pixel 8", "type": "phone" }`. `type`: the Android SDK sends `phone` or `tablet` (a large or extra-large screen layout); the iOS SDK sends `phone`, `tablet` (iPad), `desktop` (Mac Catalyst, macOS), `tv` (tvOS), `watch` (watchOS) or `headset` (visionOS). |

The IP address and the receive time are determined by the server itself; the client does not send them.

### 5.5 Event

| Field | Required | Description |
|---|---|---|
| `id` | yes | `^[A-Za-z0-9_.:-]{1,64}$`. UUID v4 by default. It is the dedup key and is forwarded to platforms as `event_id`. |
| `type` | yes | `track` or `identify`. The server does not reject a type it does not recognise; it stores it. |
| `ts` | yes | The moment of the event, by the client clock, UTC, in the format `2026-11-25T07:00:00.000Z`. The plausible range (from the year 2000 up to 48 hours after the receive time) is checked after the `sent_at` correction: events from a device whose clock is wrong are not rejected. An event that is still out of range after the correction is rejected individually. |
| `anon_id` | yes | Anonymous identifier, see section 6. |
| `name` | for `track` | Event name. Standard names: [EVENTS.md](EVENTS.md). |
| `user_id` | for `identify` | The customer's own user ID. It is also sent in all events after `identify`. |
| `session_id` | no | Session identifier. |
| `seq` | no | A counter that increases per installation. It is for ordering and loss detection. |
| `origin` | no | `code` (default), `auto` (an automatic event of the SDK) or `rule` (remote rule). |
| `rule_id` | no | The rule's ID when `origin: rule`. |
| `props` | no | Event parameters. Everything supplied by the user lives only here. |
| `traits` | no | `identify` only: user traits. |
| `page` | web | `{ "url": "…", "referrer": "…", "title": "…" }`. |
| `screen` | mobile | `{ "name": "ProductDetail" }`. |

User parameters are never mixed into the top level of the event, so they cannot override system fields.

### 5.6 Response

| Code | Meaning | SDK action |
|---|---|---|
| `2xx` | Accepted | Removes the batch from the queue. |
| `400`, `403` with an `error` code listed for that status under "Error codes" | The batch is invalid, or the key is not valid for this site / app | Deletes the batch and does not resend it. On `403 unknown_key` (and on a batch `404` whose body carries `unknown_key`) the mobile SDK also treats the key as disabled; the web tracker only deletes the batch. |
| `413` | The batch is too large | Mobile: a batch of more than one event is split in half and resent, whatever the body says; a single-event batch is deleted only when the body carries one of the documented `413` codes (`body_too_large`, `context_too_large`, `too_many_events`), otherwise it is kept and retried. Web: the batch is not split and is not kept. If the response body contains `context_too_large` (or the body is empty) and a campaign is stored, the tracker drops the stored campaign (`ctx.campaign`) and sends the batch once more without it; in every other case the batch is deleted. Consent is checked again before that resend: if `ads` consent was withdrawn in the meantime, the batch goes out without click IDs and with `ads: false`; if `analytics` consent was withdrawn, it is not resent. |
| Any other `4xx`: `404`, `422`, and a `400` / `403` without a code listed for that status | Something between the SDK and the server answered (WAF, ingress, proxy), or the body is missing | Transient: keeps the batch and retries. Mobile: after 3 consecutive answers of this kind for the same batch its events are sent one by one, and a single event still rejected this way is dropped after 5 attempts or 3 days (below). |
| `3xx` | Unexpected redirect | The redirect is not followed and the batch is kept and retried: in the mobile SDKs always, in the web tracker when the batch is sent with `fetch` (`redirect: 'manual'`). In the web tracker's `XMLHttpRequest` fallback (no `fetch`, or `fetch` rejected) the browser follows the redirect itself and the tracker sees only the final response. |
| `408`, `429` | Transient | Keeps it, honours `Retry-After`. |
| `5xx`, network error | Transient | Keeps it, retries with increasing backoff. |

Retries differ between the platforms because the queues differ:

- **Mobile SDKs** (the queue is on disk). After a transient response the SDK stops the current flush and waits: 5 s after the first consecutive failure, doubling each time up to 1 hour, with ±20% random jitter. For `5xx`, network errors, `408` and `429` (and `3xx`) there is no limit on the number of attempts: a batch leaves the queue only when it is accepted, when it is rejected with a final code, when the queue limits drop its events (`flush.max_queue`, and 5 MB on disk) or when consent, the kill-switch or a change of key / endpoint clears the queue. A `4xx` without a documented error code (not `408` / `429`) is bounded, so that one bad event cannot block the queue for good: when the same batch gets 3 consecutive answers of this kind, its events are sent one by one (row by row), and a single event that is still rejected this way is dropped after 5 attempts or 3 days, whichever comes first (debug log); the remaining events go on. Any other transient response or an accepted batch in between restarts the count of 3. A `Retry-After` header given in whole seconds is applied to any transient response: the value is clamped to 1–3600 s and a positive jitter of 0–20% is added. A forced flush (the app goes to the background, a manual `flush()`) ignores the backoff delay but not the `Retry-After` delay. The failure counter is reset by an accepted or finally rejected batch.
- **Web tracker** (the queue is in memory). A batch is sent at most 6 times: the first attempt and 5 retries, after 5, 10, 20, 40 and 80 s with ±20% random jitter; after the last failed attempt it is deleted (if that attempt ended with a network error, the batch is offered once to `sendBeacon` first). `Retry-After` (seconds or an HTTP date) is read only on `408` / `429`, is clamped to 1–300 s, has no jitter and pauses all batches, which are then resumed one second apart. Batches waiting for a retry live only as long as the page: when the page is hidden or closed they are handed to `sendBeacon` together with the queue (the newest events, up to 60 KB; the rest goes out as an ordinary request). The number of events waiting for a retry is limited to `flush.max_queue`: when it is exceeded, the oldest waiting batch is dropped. Withdrawing analytics consent deletes the waiting batches too.
- The server drops individual invalid events, accepts the rest and returns `200`. It returns `400` only if the batch envelope (`v`, `key`, JSON) is invalid.
- The body of a successful response has the form `{"ok":true,"accepted":n,"rejected":n,"duplicates":n}` and is for debugging only: the SDK does not rely on these counts. The `error` code of a rejection response, however, is part of the contract (below).
- The server deduplicates by `id`, so resending the same batch is safe.
- The dedup space is per key and is shared across all platforms: if the same custom `id` (for example `order:A-1001`) is sent from both the site and the app within the dedup window, only the first one is stored.

#### Error codes

Every rejection response of the server is JSON: `{"ok":false,"error":"<code>"}`. The codes are stable (their names do not change within `v: 1`).

| Status | `error` | For the SDK |
|---|---|---|
| `400` | `empty_body`, `bad_gzip`, `bad_json`, `bad_batch`, `bad_chars` | Final: the batch is deleted. |
| `403` | `unknown_key` | Final: the batch is deleted; the mobile SDK also treats the key as disabled (like the configuration's `404 unknown_key` response). |
| `403` | `origin_not_allowed`, `app_not_allowed`, `platform_not_enabled`, `unknown_platform`, `browser_not_allowed` | Final: the batch is deleted (5.7). |
| `404` (`GET /v1/{key}/config`) | `unknown_key` | Final: the key does not exist or is disabled. |
| `413` | `body_too_large`, `context_too_large`, `too_many_events` | The `413` rule above (mobile: split and resend; web: on `context_too_large`, drop the campaign and resend once). |
| `429` | `rate_limited` | Transient: `Retry-After`. |
| `503`, `500` | `unavailable`, `internal` | Transient. |
| `404` | `not_found` | Transient: the route was not found (for example, an old replica during a deploy); it says nothing about the state of the key. |

**A `4xx` without a recognised JSON body must be treated as transient.** Such a response is produced not by the server but by a layer in between (ingress, CDN, WAF, corporate proxy): the SDK keeps the batch and retries as described above, does not treat the key as disabled and does not delete the queue. The same rule applies to a response whose `error` code is not listed for its status in the table above: a WAF's `400 {"error":"blocked"}`, a `422` with or without a body, a `403` with an unknown code. The web tracker and the mobile SDKs apply this rule alike; the only exception is `413` on the web (the table at the top of this section). In the mobile SDKs the retries of such a response are bounded as described above (3 consecutive answers for the same batch, then row by row; a single event is dropped after 5 attempts or 3 days). A code is read only from a JSON object body; the mobile SDKs ignore a rejection body larger than 4096 bytes.

### 5.7 Source verification

One key can serve all three platforms. Verification is performed according to the batch's `ctx.platform` value, against the key's list for that platform:

| `ctx.platform` | What is verified | List |
|---|---|---|
| `web` | The host of the `Origin` header (if absent, `Referer`; if that is absent too, the `page.url` of every event). A `shop.az` entry also covers subdomains. | `domains` |
| `android` | `ctx.app.id` must match one of the `applicationId`s in the list character for character. | `android_apps` |
| `ios` | `ctx.app.id` must match one of the bundle IDs in the list character for character. | `ios_apps` |

A batch that does not match is not written and receives `403`:

| Error | Cause |
|---|---|
| `unknown_platform` | `ctx.platform` is not one of the recognised values (`web`, `android`, `ios`). Independent of the key. |
| `browser_not_allowed` | `ctx.platform` is not web, but the request comes from a browser (an `Origin` or `Sec-Fetch-Site` / `Sec-Fetch-Mode` header is present). Independent of the key. |
| `unknown_key` | The key does not exist or is disabled. |
| `platform_not_enabled` | The key's list for this platform is empty (the platform has not been enabled for this key). |
| `origin_not_allowed` | Web: the host is not in the `domains` list. |
| `app_not_allowed` | Mobile: `ctx.app.id` is missing or is not in the platform's list. |

- The lists are not mixed: an Android package name is not looked up in `ios_apps` (and vice versa). If the same identifier is used on both platforms, it must be in both lists.
- A mobile batch (`android`, `ios`) is accepted only from an app: the mobile SDKs do not send the `Origin` and `Sec-Fetch-*` headers, whereas a browser sets them itself and the page's script cannot remove them. A non-web batch carrying one of these headers receives `403 browser_not_allowed`, is not written and is not counted against the key's limit; the response carries no CORS headers. The wrappers (React Native, Flutter) use the native SDK's network layer and are subject to the same rule. A web tracker inside a WebView sends `platform: web` and is verified against `domains`.
- All platforms have a rate limit per key and per IP. The key's budget is separate per platform (each platform gets the full budget): the traffic of one platform does not push the others into `429`. The share of a single IP, however, is per key and is shared across platforms. Rejected batches (`403`) are not counted against the key's budget.

### 5.8 CORS and cookies

- CORS headers are given only to web batches (`ctx.platform: web`) and to responses whose body was not read (preflight, envelope errors, IP limit). The response for a mobile platform and for an unrecognised platform (successful or rejected) carries no CORS header: no page can read it.
- The preflight (`OPTIONS /v1/e`) has no body and the platform is not yet known, so it always allows; the rejection of a non-web batch happens on the `POST` itself.
- `Access-Control-Allow-Origin`: the request's `Origin` value (not an asterisk).
- `Access-Control-Allow-Credentials: true`.
- `cdnsb.net` cookies must be `SameSite=None; Secure`. They do not arrive in browsers that block third-party cookies, so the primary identifier is `anon_id`.
- The cross-site cookie (`sb_uid`, `.cdnsb.net`) is set only for a web batch, only when `ctx.consent.ads === true` and when at least one event is accepted. It is deleted when advertising consent is withdrawn: if the `ctx.consent.ads` value of a web batch from an allowed origin is not `true` and the request carries this cookie, the server returns it with the same name, domain, path and flags, with `Max-Age=0` (even if analytics consent is also absent and nothing is written). In responses for mobile platforms and for rejected requests (`403`) the cookie is neither set nor deleted.

## 6. Identifiers

| | Web | Mobile |
|---|---|---|
| `anon_id` | A first-party cookie on the customer's own domain (shared across subdomains). The cookie is authoritative: a deleted cookie is not restored from `localStorage` (a new ID is created); `localStorage` is used only when the cookie cannot be written | A UUID stored in the app's storage (installation ID) |
| `session_id` | Renewed after 30 minutes of inactivity | Renewed when the app stays in the background for more than 30 minutes |
| `user_id` | Supplied with `identify`; stored per origin (`localStorage`, bound to the anonymous ID), so every subdomain must call `identify` itself | Supplied with `identify` |

- `reset()` (logout): `user_id` is deleted, a new `anon_id` and `session_id` are created; the stored campaign is also deleted.
- The campaign (UTM and click IDs) is stored for 90 days, on the web and in the mobile SDKs.
- There are 17 click IDs: `fbclid`, `gclid`, `gbraid`, `wbraid`, `ttclid`, `msclkid`, `dclid`, `twclid`, `yclid`, `li_fat_id`, `sccid`, `rdt_cid`, `_gl`, `mc_eid`, `srsltid`, `epik`, `gad_source`. For the campaign the names are matched exactly, in lower case; the only other accepted spelling is `ScCid`, which is stored as `sccid`. In a URL a click-ID parameter is recognised regardless of case. Click IDs are stored and sent only with `ads` consent (on iOS: only while the batch is eligible for advertising, 7.1).
- The session duration can be changed from the configuration (`session_timeout_s`).

### 6.1 Personal data

- E-mail and phone are not sent in the clear in `traits`. The SDK normalises them, hashes them with SHA-256 and sends them as `email_sha256`, `phone_sha256`.
- The rules below are the same in every SDK (web, Android, iOS and the wrappers) and are checked against shared vectors ([vectors/sanitize-url.json](vectors/sanitize-url.json), [vectors/sanitize-props.json](vectors/sanitize-props.json), [vectors/identity.json](vectors/identity.json), [vectors/campaign.json](vectors/campaign.json)).
- E-mail: surrounding whitespace is removed, converted to lower case.
- Phone: digits only, with the country code (E.164, without the `+` sign).
- **How a name is read.** Parameter names, path segments and `props` / `traits` keys are compared by their words. Only the first 128 characters of a name are looked at; a percent-encoded name is decoded first; the Azerbaijani / Turkish letters `ö ə ş ç ü ğ ı İ` (and their upper-case forms) are folded to `o e s c u g i I`; the name is then split into lower-case words of the letters `a`–`z`: every other character (digits, `_`, `-`, `[`, `.`, …) is a separator, and so is a camelCase boundary (`user[passWord]` → `user pass word`, `SMSCode` → `sms code`, `Şifrə` → `sifre`). Cyrillic and other non-Latin names are not recognised.
- **E-mail and phone names.** An e-mail name has a word that contains `mail`, `eposta` or `poct`. A phone name has a word that starts with `phone`, `telephone`, `cellphone` or `telefon`, a word that contains `homephone` or `mobilephone`, or one of the whole words `tel`, `msisdn`, `mobile`, `gsm`, `mobil`, `nomre`, `whatsapp`.
- `traits` keys are recognised by these names (also in an object nested one level deep; arrays are not searched): a key with an e-mail name is hashed as an e-mail, otherwise a key with a phone name is hashed as a phone; the clear value is not sent. An exact `email` / `phone` key takes precedence. When several keys match, they are visited in alphabetical order (by UTF-16 code unit, so an upper-case key sorts before a lower-case one) and the first valid value is hashed: for an e-mail a value shaped like an e-mail address, for a phone a value with at least 7 digits. A value longer than 320 characters is not a candidate. Keys whose name ends with `sha256` are not hashed again; they are kept only with a 64-character hex value (the key rules below).
- `user_id` is at most 128 characters (UTF-16 code units); an empty or longer ID is rejected. If it looks like an e-mail address, the SHA-256 of it (surrounding whitespace removed, in lower case) is sent; if it looks like a phone number, the SHA-256 of its digits is sent (the same normalisation as `phone_sha256`). One leading `tel:`, `phone:`, `sms:`, `mailto:` or `email:` (ASCII letters in any case) is ignored when the ID is examined. An ID shaped like a JWT is rejected (a JWT is a credential, not an identifier). An ID shaped like a card number (15–19 digits that pass the Luhn check, optionally with single spaces or hyphens between the digits) is replaced with the SHA-256 of its digits. An ID that is not an e-mail address as a whole but contains one (`John Doe <john@example.com>`, `john@example.com (admin)`) is hashed as that address: the text is split at whitespace and at `< > ( ) [ ] " ' , ; :`, and the first part shaped like an e-mail address is taken; if there is none, the first address formed by two neighbouring pieces of a part with several `@` (`user@shop.az@tenant`, `tenant@user@shop.az` → `user@shop.az`). The fullwidth `＠` (U+FF20) is read as `@`. The checks run in the order e-mail, phone, card. Looks like a phone: in a string consisting only of digits and separators (space, hyphen, dot, parentheses), 7–15 digits starting with `+`, 9–15 digits starting with `0`, or any 10–15 digits. That is, a numeric customer ID of 10–15 digits is hashed too; to prevent this, the ID is given a letter prefix. Any other ID is sent as given (only NUL characters are removed), including an unrecognised `tel:abc`.
- `props` and `traits` keys are filtered by name at every depth; a warning is issued in debug mode. The name is read by its words (above). Two terms are used below: a **flag** is a value that is a boolean or `null`; a **small** value is a flag or a number whose absolute value is below 100 000 (a counter, not a secret). A **detail word** is one of `number`, `num`, `no`, `nomre`, `nomresi`, `code`, `kod`, `kodu`, `value`, `word`, `phrase`. A key is dropped when any of these rules matches:
  1. Its lower-cased name is exactly `email`, `phone`, `password`, `pass`, `token`, `card`, `card_number`, `cvv`, `pin`, `fin` or `kart`: dropped whatever its value.
  2. A key whose name ends with `sha256` is kept verbatim only when its value is a string of exactly 64 hex characters. With any other value the key is judged by the rules below as if the name had no such suffix (a non-hex `email_sha256` is dropped as an e-mail key), and a value that stays is scanned like any other value.
  3. Always dropped: the whole word `authorization` / `authorisation`; the word `key` preceded by `api`, `access`, `private` or `auth`; the word `id` preceded by `session`.
  4. A secret part, that is a word that contains `passw`, `pasword`, `passphrase`, `passport`, `pasport`, `passcode`, `pwd`, `psw`, `secret`, `cvv`, `cvc`, `iban`, `cardnumber`, `apikey`, `accesskey`, `privatekey`, `sessionid`, `sessid`, `csrf`, `xsrf`, `bearer`, `credential`, `parol`, `sifre` or `shifre`: dropped, unless the value is a flag, when it is the last word, when it is followed by exactly one detail word that ends the name (`secret_code`), or when the value is not small (`has_password: true`, `password_changed: true` and `secret_count: 3` are kept). The stems `sifrel…` (`şifrələmə`, encryption) and `secretar…` (`secretary`) are not secret parts, here and in URL names and path hints.
  5. A word that ends with `token`: dropped only as the last word (`access_token`, `csrftoken`; `token_count`, `tokens_used` are kept).
  6. `card` / `kart`: followed by `number`, `num`, `no`, `holder`, `exp`, `expiry`, `cvv`, `cvc`, `pan`, `nomre` or `nomresi`, always dropped; as the last word (`credit_card`, `user_card`), dropped unless the value is a flag or the word before it is `video`, `memory`, `gift`, `graphics`, `sd`, `sim`, `sound`, `flash`, `greeting`, `business` or `post` (`gift_card` is kept).
  7. One of the whole words `pass`, `pin`, `fin`, `otp`, `totp`, `jwt`, `ssn`, `pan`, `cookie`, `pw`, `auth`, `session`, `sid`: dropped as the last word, or when followed by exactly one detail word that ends the name (`otp_code`, `cookie_value`), unless the value is a flag (`otp_sent`, `pin_color`, `session_count` are kept).
  8. `code` / `kod` / `kodu` as the last word, preceded by `sms`, `verification`, `verify`, `otp`, `auth`, `security`, `confirm`, `confirmation`, `activation`, `reset`, `login`, `access`, `pin`, `pass`, `secret`, `recovery`, `backup`, `mfa`, `tfa`, `twofa`, `fa` (`2fa_code`), `tesdiq` or `dogrulama`: dropped unless the value is a flag (`sms_code`; `promo_code`, `country_code` are kept).
  9. Dropped unless the value is a flag: a word that contains `signature`, `cardholder`, `creditcard` or `pinkod`; the whole word `sig` or `nonce`; the word `key` preceded by `license` / `licence`; `cc`, `account` or `hesab` followed by `number`, `num`, `no`, `nomre` or `nomresi` (`cc_number`, `account_number`, `hesab_nomresi`; `license: "MIT"` and `account: "pro"` are kept).
  10. A word of an e-mail name: dropped unless the value is small (`email_verified: true`, `emails_sent: 5` are kept) or a contact label (below).
  11. A word of a phone name: dropped, unless the value is small or a contact label, when it is the last word, when the next word is `number`, `num`, `no`, `nomre` or `nomresi`, or when the value is phone-shaped: an integer of 7–15 digits, or a string of at most 40 characters made only of digits, whitespace and `+ - ( ) .` with 7–15 digits (`phone_model` with a model name and `is_mobile: true` are kept).
  
  A **contact label** (rules 10 and 11) is a string value of at most 32 characters without `@` (or the fullwidth `＠`) and without 7 or more digits in a row, when the word after the e-mail / phone word is `template`, `campaign`, `provider`, `list`, `type`, `status`, `verified`, `enabled`, `optin` or `consent` (`email_template: "welcome"`, `mailing_list: "news"`), or when the value itself is `ios`, `android`, `web`, `yes`, `no`, `true` or `false` in any case (`mobile: "ios"`). In `traits` such a value is kept as it is and is not hashed.
  
  Everything else is kept, for example `card_type`, `card_brand`, `key`, `api_version`, `author`, `authorized`, `cookies_enabled`.
- A string value of `props` / `traits` (at every depth, also inside arrays) is scanned in three steps. The page title and the screen name go through the same scan (below).
  1. The whole value, with surrounding whitespace removed. A value shaped like a JWT or like a card number (15–19 digits that pass the Luhn check, optionally with single spaces or hyphens between the digits) becomes `[redacted]`. A value that is itself a URL (it starts with `//` or with `scheme://`) is cleaned by the URL rules below, with the configuration's `strip_params` and the current `ads` consent; the cleaned URL is then scanned by runs as in step 3; such a value longer than 8192 characters becomes `[redacted]` as a whole.
  2. Otherwise, inside the text: e-mail-like parts (the fullwidth `＠` counts as `@`); phone numbers that start with `+` (`+`, a digit, then digits and the separators space, `(`, `)`, `.`, `-`, at most 24 characters after the `+`, 7–15 digits in total); and digit runs of 15–19 digits that pass the Luhn check are replaced with `[redacted]`. Between two digits of such a run there may be up to three separator characters: space, hyphen, `/`, no-break space (U+00A0), thin space (U+2009) or narrow no-break space (U+202F) (`4111 - 1111 - 1111 - 1111`, `4111/1111/1111/1111`). A Luhn-valid digit run that lies wholly inside a run of `A-Z a-z 0-9 _ -` that step 3 masks (a hex token, an IBAN, a known key prefix) is left to that rule, so the token is masked as a whole.
  3. Then every whitespace-separated token. A token is cleaned by the URL rules when it starts with `scheme://`, `//`, `/` or `?`, when it contains a `?` followed later by `=` (`shop.az/cb?token=…`), or when it is a hash route (`#/…`, `#!…`); a token that starts with `#` and contains `=` is cleaned as a query string (`#access_token=…&view=grid` → `#view=grid`). A token cleaned this way is then also scanned by runs (next item), so a secret followed by punctuation or a quote is masked (`(https://shop.az/a?v=<key>)`, `{"url":"https://shop.az/x?k=<hex>"}`); in this scan a `%XX` escape separates runs, and the value of a parameter exempt from the shape check (click IDs, the six UTM names, `_openstat`, `after`, `before`, `…cursor`) is skipped up to the next `&`, `;` or `#`. Any other token:
     - is first cleaned as a query string when it starts with `name=` (a name of the characters `A-Z a-z 0-9 _ - . % [ ]`) and either an `&` follows (`a=1&token=…` → `a=1`), or it is a single pair whose name is one the parameter rules remove and whose value has 6 or more characters, starts with one of `A-Z a-z 0-9 _ - % + .` and contains a digit or an upper-case letter (`session_id=Xk29LmQa` is removed; `code=200`, `key=value`, `auth=ok` are kept);
     - is then scanned by runs of the characters `A-Z a-z 0-9 _ -`; every other character (punctuation, quotes, brackets, invisible characters) separates runs. A run that starts with `eyJ` and begins a JWT is replaced with `[redacted]` together with the rest of the JWT. A run of 14 or more characters is replaced when it is a known key prefix (below). The remaining rules apply to a run that is not part of a file or domain name (no `.` with a run character beyond it on either side: `app.9f8a….js` is kept): an IBAN (two letters, two digits, 11–30 letters and digits, 15–34 characters in all, valid by the mod-97 check), and, for a run of 32 or more characters, the hex, base64url and long-run rules of a path segment (below; a UUID written without hyphens excepted). A run of digits only and an ordinary name are exempt from those three rules unless the run is hex only: a name made of words (a letter followed by two or more lower-case letters), numbers of one to four digits and `-` / `_` (`Step3ShippingAddressViewController`, `order_2026_summer_collection_items_list`);
     - after a token that ends with the word `Bearer` (in any case, not preceded by a letter) the beginning of the next token is replaced with `[redacted]` when it has 8 or more characters of `A-Z a-z 0-9 . _ ~ + / = -` with a digit, or an upper-case letter after the first character (`Bearer abcDEF123456` → `Bearer [redacted]`; `Bearer of bad news` is kept).
  
  So a path or a query string passed as a value (`/reset/<token>`, `?token=…&page=2`) is cleaned like a URL, while `#ff0000`, `#sale` and `1/2` are not changed. Other personal data in values (names, a phone number without `+`, a postal address) is not looked for.
- Known key prefixes. A string is treated as an API key when it starts with `sk_live_`, `sk_test_`, `rk_live_`, `rk_test_`, `whsec_`, `ghp_`, `gho_`, `github_pat_`, `glpat-`, `xoxb-`, `xoxp-`, `AKIA` or `AIza` and continues with at least 10 characters of `A-Z a-z 0-9 _ -` to its end. The rule applies to runs of text values, to path segments and to query parameter values.
- Sensitive query parameters (plus the `strip_params` from the configuration) are removed from URLs (on the web `page.url`, `page.referrer`, form and link addresses; in the mobile SDKs the `props.url` of `DeepLinkOpen`; on every platform URL-shaped values and tokens of `props` / `traits`, of the page title and of the screen name, as described above); the query part of a hash route goes through the same rule. A parameter is recognised by the words of its name (case-insensitively; also spellings such as `auth-token`, `user[passWord]`, `SMSCode`). A name in which nothing was recognised (and no safe pair, below, was found) is read once more without the camelCase split, so that mixed case does not hide a word (`tOkEn`, `PaSsWoRd`). The lists:
  - a word that contains one of: `token`, `passw`, `pasword`, `passphrase`, `passport`, `pasport`, `passcode`, `pwd`, `psw`, `secret`, `session`, `sessid`, `jwt`, `msisdn`, `iban`, `signature`, `mail`, `apikey`, `credential`, `csrf`, `xsrf`, `oauth`, `authoris`, `authoriz`, `authent`, `bearer`, `cvv`, `cvc`, `saml` (`SAMLResponse`), `checkword`, `cardnumber`, `authcode`, `smscode`, `otpcode`, `resetcode`, `accesskey`, `privatekey`, `homephone`, `mobilephone`, `parol`, `sifre`, `shifre`, `eposta`, `poct`;
  - a word that starts with `phone`, `telephone`, `cellphone` or `telefon`;
  - one of the whole words: `pass`, `sig`, `sign`, `auth`, `sid`, `otp`, `code`, `kod`, `kodu`, `key`, `tel`, `mobile`, `card`, `pan`, `fin`, `pin`, `ssn`, `hash`, `nonce`, `reset`, `activation`, `confirm`, `verify`, `invite`, `unsubscribe`, `ticket`, `magic`, `pw`, `cc`, `mobil`, `nomre`, `whatsapp`, `kart`. Whole words do not match inside longer words: `confirmed`, `verified`, `tickets`, `magical`, `pwa`, `ccy`, `mobilya`, `karton` are kept.
- Word pairs that are not secrets are taken out of the name before it is compared with the lists, so they do not make a parameter sensitive (the rest of the name still can):
  - `code` / `kod` / `kodu` preceded by `promo`, `coupon`, `discount`, `country`, `lang`, `language`, `currency`, `postal`, `post`, `zip`, `region`, `area`, `product`, `item`, `color`, `colour`, `error`, `status`, `sku`, `bar`, `qr`, `referral`, `invite`, `ref`, `store`, `model`, `partner`, `category`, `endirim`, `mehsul` or `olke` (`promo_code`, `invite_code`, `olke_kodu`);
  - `card`, `kart`, `ticket`, `phone`, `mobile`, `pin`, `pan`, `pass` or `fin` followed by `type`, `model`, `brand`, `os`, `size`, `color`, `colour` or `count` (`card_type`, `phone_model`, `ticket_count`).
  
  The words `mobile`, `mobil` and `cc` are ignored when the parameter's value has at most 2 characters: there they are flags (`mobile=1`, `cc=az`).
- Campaign parameters. Only the six names `utm_source`, `utm_medium`, `utm_campaign`, `utm_term`, `utm_content` and `utm_id` are kept as UTM parameters; any other name that starts with `utm_` is an ordinary parameter (`utm_token` is removed, the value of `utm_foo` is checked). The 17 click IDs (section 6) are kept with `ads` consent and removed without it. Order of the checks: `strip_params` first, then click IDs, then the six UTM names, then the name lists. In the value of one of the six UTM names a phone number starting with `+` and a card number (Luhn, as in a text value; `+` is read as a space) are replaced with `[redacted]`, in the URL and in `ctx.campaign` (`utm_term=%2B994501234567` → `utm_term=[redacted]`); the value of a click ID is not checked for these shapes (a numeric click ID can look like a card number).
- Parameter values. A value shorter than 8 characters (6 when the query is hinted, below) is never inspected. A JWT-shaped value becomes `[redacted]`. A value that is itself a URL or a query string is cleaned inside by the same rules (up to two levels; deeper than that, a nested value that still contains `=` is removed together with its parameter). A value that is not a URL becomes `[redacted]` when, after percent-decoding, it looks like a secret by the rules for a path segment below (the hinted rules when the query is hinted): a run of 32 or more hex characters anywhere in the value (a static file name excepted, as in a segment), a long token, a known key prefix, a card number, 20 or more digits, a phone number starting with `+`. Three details differ from a path segment: a number of 15–19 digits that passes the Luhn check is masked whatever its first digit; a value is also examined with `+` read as a space, as in form encoding (`n=4111+1111+1111+1111`); and a value that starts with `tel:` or `sms:` is examined without that prefix as a directly hinted segment, so 6 or more digits are masked. The values of the click IDs, of the six UTM names, of `_openstat`, `after`, `before` and of parameters whose name ends with `cursor` (pagination cursors) are exempt from this shape check; a JWT is masked there too (for the UTM names see also above). A parameter whose name (6 or more characters) itself looks like a secret by the rules for an unhinted path segment becomes `[redacted]` as a whole (`?<JWT>=1` → `?[redacted]`).
- A query part without `=` (`/verify?<token>`) is removed if it is a sensitive name; otherwise, from 6 characters on, it is examined like a parameter value and becomes `[redacted]` when it looks like a secret. For a part whose value is empty or consists only of `=` signs, the name is examined as a part without `=`, so a padded base64 token is not read as a name and a value (`/reset?<base64>==`, `/reset?<base64>=` → `/reset?[redacted]`; `?q=`, `?debug=`, `/login?returnUrl=`, `a==` are kept). Under a hint a part without a value is also examined piece by piece, split at `/` and `=` (standard base64 containing `+` and `/`).
- A segment of the path (and of the hash route) that looks like a secret is replaced with `[redacted]`. A segment is examined after percent-decoding; a segment shorter than 6 characters is never masked by these rules. Without a hint, a segment is masked when it is:
  - a JWT: `eyJ` followed by at least 8 base64url characters, a dot, at least 8 more base64url characters and an optional third dot-separated part;
  - a known key prefix (above);
  - a phone number starting with `+`: `+`, a digit, then digits and the separators space, `(`, `)`, `.`, `-`; 9–20 characters with 9–15 digits;
  - digits only: 20 or more digits, or 15–19 digits that pass the Luhn check and start with `3`, `4`, `5` or `6` (a card number; a Luhn-valid order number such as `20261125…` is kept). A bare number of 10–14 digits (an order number, a barcode, a timestamp, a phone number without `+`) is **not** masked;
  - a card number written with single spaces or hyphens between the digits (15–19 digits, Luhn);
  - a segment that contains a run of 32 or more hex characters (`<hex>`, `v1:<hex>`, `reset-<hex>`, `<hex>.json`), unless the segment is a static file name (`<md5>.jpg`, `app.<hash>.js`; the extensions are listed below); a run of exactly 32 hex characters with a UUID version and variant digit in place (a UUID written without hyphens) is excepted;
  - a base64url token of 32 or more characters (optionally ending in up to two `=`) that has a lower-case letter, an upper-case letter and a digit, and in which `-` and `_` make up less than one eighth of the length;
  - anything containing a run of 24 or more letters and digits that includes both a digit and a letter outside `a`–`f` (a 24-character hex ObjectId is kept). Two common identifier formats are kept as well: a cuid (`c` followed by 24 lower-case letters and digits) and a ULID (26 characters of Crockford base32, the first one `0`–`7`).
- Path hints. A segment (percent-decoded, matrix parameters excluded, Azerbaijani / Turkish letters folded as in a name) is read like this: it is split at every character that is not a letter or a digit, parts that contain a digit are ignored (except `2fa`, which counts as a word), and the remaining parts are split into words as a name is. The segment is a **hint** when it has one to three words and
  - its first or its last word starts with one of `reset`, `forgot`, `passw`, `pasword`, `sifre`, `shifre`, `parol`, `unuttum`, `tesdiq`, `dogrula`, `aktivle`, `aktivas`, `signin`, `login`, `verify`, `verific`, `confirm`, `activat`, `magic`, `invit`, `unsubscribe`, `token`, `secret`, `recover`, `restore`, `signature`;
  - or its first or its last word is one of `otp`, `pwd`, `psw`, `sso`, `msisdn`, `iban`, `auth`, `oauth`, `callback`, `session`, `join`, `mfa`, `2fa` (whole words: `author`, `oauth2`, `sessions`, `joined` are not hints);
  - or its first two or its last two words join to `signin` or `login` (`sign-in`, `log_in`).
  
  A slug of more than three words is not a hint (`how-to-reset-your-password`), and neither are `mail`, `email`, `tel`, `phone`, `fin` or `sig`.
- Order confirmation. A segment whose hint comes only from a word that starts with `confirm` or `tesdiq` stays a hint. It is in *order context* when the segment itself has one of the order words `order`, `orders`, `checkout`, `payment`, `payments`, `booking`, `purchase`, `sifaris`, `odenis` (`order-confirmation`), when it is a single word and the previous or the next segment is exactly such a word (`/order/confirm/…`), or when it is the single word `confirmation`. In order context, a segment (one of the next two) made only of `A-Z 0-9 -` with at least one digit is examined without the hint (`/order/confirm/2026112500123`, `/confirmation/AZ-778899`, `/confirm/order/778899` are kept); anything else is examined as hinted (`/order/confirm/Zq7Lm2Xp9Rt4`, `/order/confirm/az-778899` are masked). When the order word is `payment`, `payments` or `odenis` (in the segment itself or as the neighbouring segment; for the single word `confirmation` only as the previous segment), a number of 6–8 digits stays hinted (`/payment/confirmation/879609` is masked, `/payment/confirmation/2026112500123` is kept). A confirm word combined with other words is an ordinary hint (`/checkout/confirm-email/<token>` is masked). When such a segment ends the path, a parameter is examined without the hint only if its value has that order-number shape and its name consists only of the words `order`, `booking`, `ref`, `reference`, `number`, `id`; outside order context the name must also contain `order` or `booking` (`/confirm?order_id=778899` is kept; `/confirm?id=778899`, `/confirm?id=<token>`, `/orders/confirm?t=<token>` are masked; `/orders/confirm?id=778899` is kept). The 6–8-digit payment exception applies to path segments only, not to parameters. Any other hint next to an order word stays a hint (`/order/verify/<token>`), and the unhinted rules still apply (a JWT after `/order/confirm/` is masked).
- What a hint covers. **The next two segments of that path** are examined as hinted (`/account/reset/<id>/<token>`). When the hint is the last segment of the path, the query is hinted as well (`/reset?t=<token>`, `/verify?<token>`): parameter values from 6 characters on, and parts without `=`. The path and the hash route are separate in this respect; a hint at the end of a hash route covers the route's own query, including parameters written without `?` (`#/reset&t=<token>`). A hash-route segment with matrix parameters (`#/reset;t=<token>`) is cleaned like a path segment, with the segment's own hint.
- A hinted segment of 6 or more characters is masked, in addition to the rules above (the exceptions for a UUID without hyphens, a cuid and a ULID do not apply, and a Luhn-valid number of 15–19 digits is masked whatever its first digit), when it consists only of the characters `A-Z a-z 0-9 _ . ~ + = : -`, is not a static file name (its last extension is one of `js`, `mjs`, `css`, `map`, `png`, `jpg`, `jpeg`, `gif`, `svg`, `webp`, `avif`, `ico`, `woff`, `woff2`, `ttf`, `otf`, `eot`) and one of the following holds:
  - one of its parts separated by `-`, `_`, `.`, `~`, `:` mixes letters and digits, except a word of three or more letters followed by one or two digits (`step2`, `oauth2`, `iphone15`), `v` followed by one to three digits (`v2`) and `2fa`;
  - one of its parts has 6 or more digits and nothing else, and the segment directly follows the hint (in the second segment after the hint such a part is kept);
  - one of its parts consists of letters with an upper-case letter after the first character (`GBwfxTRf`), except a part that is all upper-case and a camelCase word whose pieces have three or more letters each (`forgotPassword`, `ThankYou`);
  - the segment is 16 or more characters long and none of its parts is an ordinary word (4–15 letters, all lower-case, all upper-case, or capitalised).
  
  The hint's own segment is examined too, but only by the first two of these four rules (`/confirm-482913`, `/reset_a1b2c3d4`).

  So `/reset-password/success`, `/verify/email/sent`, `/reset/step2`, `/login/2026-11-25`, `/reset/summer-sale-2026`, `/confirm/order/123456` and `/login/app.3f9a2b1c.js` are kept, while `/reset/123456`, `/reset/GBwfxTRf`, `/reset/9f8a7b6c5d4e`, `/reset/xKmPvQwLnRsTyZaBcDe7` and, as a rule, a UUID after a hint are masked. When a hinted segment is masked, the hinted segment immediately before it is masked as well if it is a short identifier that was not masked on its own: 1–16 characters of `A-Z a-z 0-9 _ -` with at least one upper-case letter or digit (`/reset/MQ/<token>` → `/reset/[redacted]/[redacted]`).
- Phone words. After a segment of one to three words (read as for a hint) whose first or last word is `phone`, `telephone`, `tel`, `telefon`, `mobile`, `mobil`, `nomre`, `gsm` or `whatsapp`, the next segment is masked when it consists of 7–15 digits (`/tel/0501234567`). A phone word gives no other hint: `/phone/iphone15` and `/phone/SM-A546B` are kept.
- Matrix parameters of a path segment (`/reset;t=<JWT>`, `;jsessionid=…`): each `;name=value` part is cleaned like a query parameter (name rule, value rules, a nested URL, a part without a name), with the hint of its segment: after a hint segment as a query after that hint (`/reset;t=Xk29LmQa` → `/reset;t=[redacted]`), otherwise with the hint the segment itself is examined under. A percent-decoded segment that contains `/` (from `%2F`) or `=` is also split at these characters, and when one of the pieces looks like a secret the whole segment is masked (`/x/t=4111111111111111` → `/x/[redacted]`; `/filter/color=red` is kept). Ordinary paths (slug, UUID, product number) are not changed. A fragment that is not a route (`#…`) and the user name / password part of the URL are not sent.
- Scheme and host. For `http` / `https` the scheme, host and port are never changed. For any other `scheme://` URL (an app deep link such as `myapp://reset/123456`) what stands in the host position is treated as the first path segment: it can be masked and it can be a hint.
- In the part of the URL after the host e-mail-like text is replaced with `[redacted]`: a part (between `/`, `?`, `&`, `=`, `#` and whitespace) with an `@`, a fullwidth `＠` (U+FF20) or `%40` after its first character, followed by text that contains a dot and at least two Latin letters after it. The name of an image with a density suffix is not an e-mail (`logo@2x.png`, `a@1.5x.webp`: digits, `x.` and one of the static file extensions above).
- The cleaned URL is cut to 2048 characters.
- A URL longer than 8192 characters is shortened before it is cleaned, by the same function in every SDK: its query and fragment are dropped, and if what remains is still longer than 8192 characters it is cut to 8192 characters and then back to the last `/` (the last whole segment). On the web this applies to `page.url`, `page.referrer`, form and link addresses; a URL-valued string in `props` / `traits` longer than 8192 characters becomes `[redacted]` (above). The campaign is read from the URL as given, whatever its length.
- In the mobile SDKs a deep link longer than 8192 characters is not processed in any way and is ignored (no `DeepLinkOpen`, no campaign), so a recorded deep link is never a shortened one.
- Page title (web, `page.title`) and screen name (mobile, `screen.name`) are scanned like a string value of `props` (the three steps above): e-mail-like text, phone numbers starting with `+`, card numbers, JWTs, known key prefixes, IBANs, `Bearer` tokens and long hex strings or tokens become `[redacted]`, and a title or name shaped like a URL, a path or a query string is cleaned by the URL rules (with `strip_params` and the current `ads` consent). In addition, 9 or more digits in a row without separators are replaced with `[redacted]`. Names are not recognised. The title is then cut to 512 characters, the screen name to 128.

#### Limits of the heuristics

The rules above recognise shapes and names; they do not understand the data.

**May still get through** (known misses):

- Names, postal addresses and free text are never recognised. Field names in Cyrillic or another non-Latin script are not recognised, neither as `props` / `traits` keys nor as URL parameters.
- After a hint, a token made only of lower-case letters and shorter than 16 characters is kept (`/reset/abcdefgh`); so is a token glued to a hint word written with non-ASCII letters (`/şifrə-<token>`), a 6-digit code two segments after the hint (`/acc/verify/327/965040`) or after an encoded slash (`/mfa%2F959174`).
- Order confirmations: a 6–8-digit code after an order (not payment) confirmation is kept as an order number (`/order/confirm/482913`), and so is an upper-case base32 secret after `/confirmation/`.
- `sessions`, `oauth2`, `authorize`, `authenticate`, `tfa`, `two-factor` are not hint words. In a path segment `name=value` is masked only when the name is a path hint word or the value is a secret by itself (`/x/sid=<token>`, `/x/code=<token>` are kept).
- Under a hint, a named parameter value in standard base64 with `/` is not masked unless the long-token rules catch it; only a part without a value is split at `/`.
- An e-mail address whose domain ending is not written in Latin letters (an IDN top-level domain), and an address that is percent-encoded twice (`%2540`), are not recognised.
- Card numbers: one written with dots (`4111.1111.1111.1111`) is not recognised (in a path segment, a parameter value and a user ID only single spaces or hyphens between the digits are); one immediately next to other digits is merged with them into one run and not recognised (`4111 1111 1111 1111 12/27`, `<card> 123`, `?n=<card>+123`).
- Text values are checked by weaker rules than URLs. Kept in text: a random token shorter than 32 characters that is not a JWT, a known key prefix or a `Bearer` token (payment-system and Firebase identifiers have this shape); a 40-character secret containing `/` or `+`; `Basic <base64>` credentials; `Bearer: <token>` (with a colon); an IBAN written in groups separated by spaces (`AZ21 NABZ 0000 …`).
- Tokens joined by dots, other than JWTs, are not recognised in text unless they carry a known key prefix (a run next to a dot is exempt from the IBAN and 32-character rules): three-part keys of the `XX.<part>.<part>` kind, `ya29.<token>`, `<base64>.txt`. A hex run of 32 or more characters in a static file name (`<hash>.jpg`, `app.<hash>.js`) is kept in URLs and in text; with any other extension it is masked in a URL (`<hash>.json`).
- Short passwords inside free text are kept: `{"password":"…"}` passed as a string value, `pwd: …`, `password=<value>` when the value is shorter than 6 characters or has only lower-case letters.
- Numeric values under secret-named keys with extra words are kept (`user_password_plain: 4821`, `secret_answer: 1234`, `otp_entered: 482913`, `pin_entered: 4821`); the keys `licensekey`, `activation_key`, `product_key` are not on the list. `cardholder`, `creditcard`, `pinkod` and `totp` are recognised as `props` / `traits` keys but not as URL parameter names.
- User IDs are sent as given although address- or secret-shaped: `@user@shop.az`, `user%40shop.az`, `user@@shop.az`, the small-form `﹫` (U+FE6B), a bare 9-digit phone number, an API key, an IBAN or a hex token used as the user ID.
- Campaign (UTM) values are not checked for keys, IBANs, hex tokens or phone numbers without `+`.
- A bare number of 10–14 digits is not masked in a URL, and a phone number without `+` is not looked for in the text of `props` / `traits` values (a title or screen name masks 9 or more digits in a row).
- `props` / `traits` strings have no length cap before they are scanned (the cost is linear: up to about 0.1 s for 64 KB).
- iOS only: two canonically-equal spellings of a `strip_params` entry (`é` and `e` + U+0301) are merged into one when the configuration is parsed, so only one spelling is stripped; Android strips both.

**May be masked although harmless** (accepted on purpose, because the opposite mistake costs more):

- Dropped keys: `loyalty_card`, `boarding_pass`, `confirmation_code`, `page_token`, `design_signature`, `signature_style`, `cardholder_verified`, `account_number_masked`.
- After a hint: `/session/iPhone15`, `/session/Workshop2026`, `/auth/SignIn`, `/event/join/123456`, `/meeting/join/9876543210`, `/session/1700000000`; an empty-valued parameter whose name looks like a token (`/login?Xk29LmQa=`).
- After an order confirmation only upper-case / digit references are recognised as order numbers: a lower-case or mixed-case reference is masked (`/order/confirm/az-778899`), and so is a 6–8-digit number after a payment confirmation (`/payment/confirmation/879609`).
- A Luhn-valid number of 15–19 digits in a parameter value is masked even when it is a barcode, an order number or an IMEI (`orderId=…`, `?imei=<15 digits>`); a long playlist-style identifier in a parameter value (YouTube `list=…`) is masked.
- In text: a git SHA-1, an upper-case 32-hex identifier, `cs_test_…`, the word after `Bearer` (`Bearer Bluetooth5.0 speaker`); `x=1&code=SAVE20` → `x=1`, `id=5&key=color` → `id=5`.

Use other key names, or keep such values out of the URL.

So the rules are a safety net, not a filter to rely on: do not put personal data or secrets into URLs, event parameters, titles and screen names, and use `strip_params` for parameters the rules do not know.

## 7. Consent

There are two purposes:

| `analytics` | `ads` | Behaviour |
|---|---|---|
| `false` | — | Nothing is sent or stored. The queue is deleted. |
| `true` | `false` | Events are sent but are not forwarded to advertising platforms; advertising identifiers (`gaid`, `idfa`, `fbp`, etc.) are not sent. |
| `true` | `true` | Full mode. On iOS, forwarding to advertising platforms additionally requires the ATT permission (7.1). |

- The initial value comes from `consent_default` in the configuration; the `init` option or `setConsent` overrides it.
- On the first start of the mobile SDK, if there is no stored configuration and no `init` consent, the SDK waits for the configuration response (200 or 404): until then events are kept in memory (at most 100), nothing is written to disk and nothing is sent. Then `consent_default` is applied. A failed request is retried with increasing backoff.
- On web the visitor's choice stored with `setConsent` takes precedence over the value in `init`. `init` is only the initial value (it is not stored, and only the first `init` is taken into account); `setConsent` is the visitor's own choice and is stored.
- On web the Global Privacy Control signal (`navigator.globalPrivacyControl === true`), if the visitor has no stored choice, sets `ads` consent to `false` (it does not touch `analytics`). It is overridden only by `setConsent`, not by `consent_default` or `init`.
- On web, when `analytics: false`, no identifier is stored and no cookie is written; the opt-out in the shared cookie also deletes identifiers left on other subdomains.
- The choice is stored and remains in force on subsequent pages / launches.
- How the SDKs read `consent_default`. The server always sends both members as booleans (section 8). If the configuration reaches an SDK in another form, the platforms differ: in the mobile SDKs, when the `consent_default` member is present, a purpose is granted only by a JSON `true` (a missing or non-boolean member, or a `consent_default` that is not an object, counts as `false`), and when `consent_default` is absent altogether both purposes default to `true`; in the web tracker a purpose is denied only by an explicit `false` (a missing or non-boolean member counts as `true`).
- Mobile: a withdrawal is durable. A `setConsent` call that denies a purpose (and a repeated `init` that tightens consent) is written to a small file on the calling thread, before the call returns, and is applied at the next start before anything is sent: if the process dies before the SDK's worker has executed the call, the old queue is still not sent. A withdrawal of `analytics` deletes the queue and the identifiers even if consent is granted again before the worker gets to it.
- Mobile: when `ads` consent is withdrawn (on iOS also when the ATT permission is no longer `authorized`), the events already in the on-disk queue are rewritten in place: `ctx.ids` and the click IDs of `ctx.campaign` are removed, `ctx.consent.ads` becomes `false`, and click IDs are removed from the URL values in the `props` and `traits` of every queued event (not only from the `props.url` of `DeepLinkOpen`) and from a URL-shaped `screen.name`; the click IDs of the stored campaign are deleted too, and the current screen name held in memory (it is written to later events) is cleaned the same way. There is no way back: these events are sent with `ads: false` even if consent is granted again before they leave the device.
- Mobile: while consent is still undecided (the first start, before the first configuration response), the campaign and the `DeepLinkOpen` event of a deep link exist only in memory. If the decision turns out to be without `ads` consent, the click IDs are removed before anything is written to disk.
- Mobile: if the local store is corrupt or the stored consent value is unreadable, the earlier choice may have been a refusal, so both purposes are treated as denied (not as "never stated") until `setConsent` is called. The `consent` option of `init` cannot loosen this state.
- Web: when `analytics` consent is withdrawn, the queue and the batches waiting for a retry are deleted together with the identifiers; when `ads` consent is withdrawn, the stored click IDs are deleted and the URLs of events that are still in the queue or waiting for a retry (page URL, referrer, URL values of `props` / `traits`, and URLs inside the page title) are cleaned again without click IDs. Web keeps the queue in memory only, so nothing has to be rewritten on disk.

### 7.1 Forwarding to advertising platforms and ATT on iOS

The server forwards an event to advertising platforms (destinations) only under the following condition; the same condition also applies to the hashed e-mail / phone stored for matching (`email_sha256`, `phone_sha256` of `identify`):

| `ctx.platform` | Condition |
|---|---|
| `web`, `android` | `ctx.consent.ads === true` |
| `ios` | `ctx.consent.ads === true` **and** `ctx.ids.att === "authorized"` |

- On iOS advertising consent alone is not enough: the App Tracking Transparency permission is also required. When the `att` value is `denied`, `restricted`, `not_determined`, when it is an unrecognised value, or when the field is not sent at all, the event is not forwarded and no identity is written.
- On iOS 13, which has no ATT, the SDK does not send `att` (none of the four values in 5.4 fits). The protocol has no separate value meaning "ATT is absent, tracking is allowed", so the events of such devices are not forwarded either.
- The condition applies only to forwarding: the event itself (analytics) is stored regardless of `att`, and the context is written as is.
- The decision is made according to the context in each event's own batch: if the permission is later revoked, new events are not forwarded.

## 8. Configuration

The `GET /v1/{key}/config` response and the configuration inside the web script have the same form. Schema: [schema/config.v1.schema.json](schema/config.v1.schema.json).

```json
{
  "v": 1,
  "key": "k7m2x9qa4t",
  "rev": 12,
  "enabled": true,
  "sample": 1,
  "ttl_s": 3600,
  "session_timeout_s": 1800,
  "consent_default": { "analytics": true, "ads": true },
  "auto": { "page_view": true, "lifecycle": true },
  "blocked_events": [],
  "strip_params": [],
  "flush": { "interval_s": 30, "max_batch": 50, "max_queue": 1000 },
  "rules": []
}
```

| Field | Description |
|---|---|
| `rev` | Version of the configuration; it increases on every change. |
| `enabled` | If `false`, the SDK sends nothing and deletes the queue (kill-switch). |
| `sample` | 0–1. Sampling is done per `anon_id`, so that a user is either fully included or fully left out. |
| `ttl_s` | The mobile SDK does not refresh the configuration more often than this interval. |
| `sdk_latest` | The latest released version of the mobile SDK; when the server knows it, it adds it to the configuration of every key (the key is one for all platforms). It is not present in the configuration inside the web script. If the SDK's own version is older than this, it writes a warning once in debug mode; it does not affect behaviour. The field may be absent. |
| `auto` | Switches for the automatic events. Web: `page_view` (if `false`, SPA navigations are not counted either), `spa`, `forms`, `outbound`, `contact_links`. Mobile: `lifecycle`, `screens`, `deeplinks`. The SDK ignores a switch it does not recognise. |
| `blocked_events` | Events with these names are dropped in the SDK. |
| `flush` | Parameters of the queue. When `max_queue` is exceeded, the oldest events are dropped. `interval_s` applies only to the mobile SDKs: the web tracker sends the queue every half second and when the page is closed. In the mobile SDKs the on-disk queue is additionally limited to 5 MB (the UTF-8 size of the stored contexts and events); beyond that the oldest events are dropped as well. |
| `rules` | No-code event rules. Their format will be described in phase 6. The SDK skips a rule type it does not recognise. |

The server validates the configuration before distributing it:

- The envelope fields (`v`, `key`, `rev`, `enabled`, the `endpoint` in the web script, `sdk_latest`) are always written by the server itself; the key's stored settings cannot change them.
- Recognised fields are checked by type: a field whose type is invalid is dropped and the default value is given. An out-of-range number is clamped to the bound: `sample` 0–1, `ttl_s` 60–604800, `session_timeout_s` 60–86400, `flush.interval_s` 1–3600, `flush.max_batch` 1–100, `flush.max_queue` 1–5000.
- A non-boolean value in `consent_default` is given as `false` (a corrupt entry is not treated as consent). How each SDK reads a `consent_default` that reaches it in any other form is described in section 7.
- `strip_params` is at most 100 short (1–64 characters) strings, `blocked_events` is at most 500 event names (the pattern in 5.2); invalid elements are removed.
- `consent_default`, `auto` and `flush` are always given in full (members that are not supplied take the default value).

The mobile SDK requests the configuration with `If-None-Match` and stores it on disk. If the configuration has not been received, the SDK works with the default values and keeps events in the queue.

## 9. Compatibility rules

1. The server does not reject fields it does not recognise. The SDK skips configuration fields it does not recognise.
2. Within `v: 1` no field is removed, no type or meaning changes, and no required field is added.
3. An incompatible change comes only with `/v2`; `/v1` keeps running in parallel.
4. The server accepts at least all released SDK versions of `v: 1`.
