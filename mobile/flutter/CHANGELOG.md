## 1.0.0

- First public release.
- `SmartBee.init` completes with a `bool` (whether the native SDK accepted the call).
- `track`, `identify` and `screen` take their optional arguments by name: `track(name, props: …, eventId: …)`.
- `SmartBeeConsent.fromMap` and `SmartBee.setConsentValue`; consent fails closed.
