# Changelog

All notable changes to the SmartBee Pixel SDKs are recorded here. The SDKs (Android, iOS, Flutter, React Native) share one version number and follow [semantic versioning](https://semver.org/).

## 1.0.0 — unreleased

The first public release. The `v1.0.0` tag has not been published yet; until it is, the items below describe the state of the `main` branch.

Until the tag exists, the `az.smartbee:pixel:1.0.0` artifact in the Maven repository is a pre-release build: it has been rebuilt in place and may be again, so its checksum should not be pinned yet. From the tag onward a version is immutable. Nothing has been published to npm or pub.dev.

### Public API (frozen with this release)

- `init` / `initialize`, `track`, `identify`, `screen`, `setConsent`, `reset`, `flush`, `handleDeepLink`, `getAnonymousId`, `sdkVersion` on every mobile platform.
- Android: `SmartBeeConsent`, `SmartBeeOptions.Builder` and the Kotlin `smartBeeOptions { }` function; every method is callable from Java.
- iOS: `SmartBeeConsent`, `SmartBeeOptions`.
- React Native: `init` resolves to a boolean; `handleDeepLink(url)`; CommonJS package with TypeScript declarations and a Jest mock (`@smartbee/pixel/jest/mock`).
- Flutter: `init` completes with a boolean; `track`, `identify` and `screen` take their optional arguments by name; `SmartBeeConsent.fromMap`, `setConsentValue`.

### Behaviour

- Consent: for each purpose the more restrictive of the app's value and the stored choice applies; a repeated `init` can only tighten it; the wrappers treat a missing purpose as denied.
- Without analytics consent the mobile SDKs store nothing and make no network request.
- iOS: the advertising identifier, the vendor identifier and click IDs are sent only with advertising consent and the user's tracking permission (ATT).
- A key is treated as disabled only on an explicit `unknown_key` answer of the server; other `4xx` answers are retried.
- A batch that is too large (`413`) is split in half and resent by the mobile SDKs.
- Retries: `5xx`, network errors, `408` and `429` are retried without limit; a batch that gets 3 consecutive `4xx` answers without a documented error code is sent one event at a time, and a single event still rejected that way is dropped after 5 attempts or 3 days.
- If the stored consent cannot be read, both purposes stay denied until `setConsent` is called; the `consent` option of `init` cannot loosen it.
- When ads consent is withdrawn, click IDs are removed from the URL values in the `props` and `traits` of every queued event and from a URL-shaped screen name (also the current one), not only from the deep-link address.
- While the SDK is busy at most 100 `track` / `screen` calls wait and the oldest is dropped when the list is full; `identify`, `flush`, `handleDeepLink`, `setConsent` and `reset` are never dropped.
- Deep-link URLs are scrubbed of secrets and personal data; URLs longer than 8192 characters are ignored.

### Sanitising (what an integrator will notice)

The rules are specified in `spec/PROTOCOL.md`, section 6.1, together with their known limits.

- Property keys are judged by the words of their name and by their value. Now dropped: `session`, `auth`, `sid`, one-time codes such as `sms_code` / `otp_code`, and a `*_sha256` key whose value is not 64 hex characters. Now kept: `token_count`, `phone_model`, `gift_card` and similar counters, flags and descriptive names.
- A key named as a secret is kept when its value is a flag (`has_password: true`); `secretary` and `sifreleme` are no longer read as secrets. Dropped unless the value is a flag: `signature`, `sig`, `nonce`, `license_key`, `cardholder`, `creditcard`, `cc_number`, `account_number`, `pinkod`; also `totp` and `2fa_code`. Settings named after a contact stay (`email_template: "welcome"`, `mailing_list`, `mobile: "ios"`).
- Text values of `props` / `traits` are scanned: hex strings of 32 or more characters, phone numbers starting with `+`, card numbers, JWTs and known API-key prefixes inside a text become `[redacted]`.
- Secrets in a text are found whatever punctuation surrounds them (quotes, brackets, `|`, `&`, a trailing dot). Also masked: IBANs (mod-97 checked, written without spaces), the token after `Bearer`, base64 and other long tokens of 32 or more characters, card numbers written with `/`, no-break or thin spaces. `name=value` text is scrubbed like a query string (`a=1&token=…` becomes `a=1`; `code=200` stays).
- A property value (or a word in it) that starts with `/` or `?`, or is a URL, is scrubbed by the URL rules: `/reset/<token>` becomes `/reset/[redacted]`, sensitive query parameters are removed.
- URLs: `mobile=1`, `cc=az` and `invite_code=…` stay; `utm_token=…` is removed (only the six real UTM names are exempt); mixed-case names such as `tOkEn` are caught.
- Matrix parameters (`/reset;t=<token>`) are scrubbed like query parameters, values included; a path segment with `=` or `%2F` is masked when one of its pieces is a secret; a padded base64 token (`/reset?dGhpcy…==`) and a parameter whose name is itself a secret are masked; a phone number starting with `+` and a card number inside a UTM value are masked.
- Path hints: a short token after `reset`, `verify`, `login` and similar segments is masked (`/reset/GBwfxTRf`); the hint covers the next two segments and the query, no longer the whole rest of the path; `/phone/iphone15`, cuid and ULID identifiers and `logo@2x.png` are no longer masked.
- New path hints: `auth`, `oauth`, `callback`, `session`, `join`, `mfa`, `2fa` (`/auth/callback/<token>`, `/2fa/123456`). An order confirmation keeps an order number written in capital letters, digits and hyphens (`/order/confirm/2026112500123`, `/confirm/order/778899`, `/confirmation/AZ-778899`), and in `/confirm?orderId=…&t=<token>` only `t` is masked; anything else after it is masked as after any hint (`/order/confirm/Zq7Lm2Xp9Rt4`, `/order/confirm/az-778899`, `/checkout/confirm-email/<token>`), and so is a code of 6–8 digits after a payment confirmation (`/payment/confirmation/879609`). Under a bare `/confirm` only a parameter named after an order keeps its number (`/confirm?order_id=778899` stays, `/confirm?id=778899` is masked).
- A run of 32 or more hex characters is masked anywhere in a path segment or a parameter value (`v1:<hex>`, `reset-<hex>`, `<hex>.json`), not only when it is the whole segment; static file names stay (`<md5>.jpg`, `app.<hash>.js`). A path hint is recognised in a segment of any length.
- A base64 token in the query padded with a single `=` (`/reset?<base64>=`) is masked like one with `==`; `?q=` and `/login?returnUrl=` stay. Matrix parameters are scrubbed in a hash route too (`#/reset;t=<token>`).
- A secret in a URL inside a text is masked also when punctuation or a quote follows the URL (`(https://shop.example/a?v=<key>)`); a hex token or an IBAN whose digits happen to look like a card number is masked as a whole.
- Still not caught, so keep such values out of `props`, `traits` and the user ID: tokens joined by dots that are not JWTs (`ya29.<token>`), a card number directly next to other digits (`<card> 12/27`), `Basic <base64>` credentials and an IBAN in spaced groups inside a text, short passwords in free text, a user ID that is itself an API key or an IBAN.
- A screen name shaped like a URL is scrubbed as a URL.
- `identify`: a user ID shaped like a JWT is rejected, one shaped like a card number is hashed; a leading `phone:`, `sms:` or `email:` is ignored like `tel:` and `mailto:`; an ID with two `@` (`user@shop.az@tenant`) or with the fullwidth `＠` is hashed as the e-mail address in it.

### Specification

- `spec/PROTOCOL.md`, `spec/SDK-API.md` and `spec/EVENTS.md` are version 1.0, frozen with SDK 1.0.0.
