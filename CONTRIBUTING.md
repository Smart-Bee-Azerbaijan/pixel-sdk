# Contributing

Thank you for looking at the code. Bug reports, questions and pull requests are welcome.

## How changes land

This repository is **published from an internal source repository** by an export script; it is never edited directly, and every export replaces its whole content. For that reason a pull request cannot be merged here with the merge button. Instead:

1. Open an issue or a pull request here.
2. A maintainer reviews it and applies the change in the source repository, keeping you as the author of the commit where that is possible.
3. The next export brings the change to this repository, and the pull request is closed with a link to the exported commit.

Security problems are reported privately: see [SECURITY.md](SECURITY.md).

## What lives where

| Path | What it is |
|---|---|
| `mobile/android` | Android SDK (Gradle module `:pixel`) |
| `mobile/ios` | iOS SDK (the Swift package manifest is `Package.swift` in the repository root) |
| `mobile/react-native`, `mobile/flutter` | wrapper packages: a JS / Dart API, native bridges and a generated copy of the native cores |
| `spec` | the protocol, the SDK API, JSON schemas and shared test vectors |

The files under `mobile/react-native/android/src/main/java/az/smartbee/pixel/*.kt`, `mobile/react-native/ios/Core`, `mobile/flutter/android/src/main/kotlin/az/smartbee/pixel/*.kt` and `mobile/flutter/ios/Classes/Core` are **generated copies** of the native cores (their first line says so). Change the original under `mobile/android/pixel` or `mobile/ios/Sources` and run `node mobile/sync-native.mjs`; CI fails when the copies differ.

The documents in `spec/` are normative and frozen with SDK 1.0.0: a change there may only add new, optional fields.

## Running the tests

```sh
# Android: unit tests (JVM + Robolectric) and the React Native Android bridge. Needs JDK 17 and the Android SDK.
cd mobile/android && ./gradlew :pixel:testDebugUnitTest :rn-bridge:assembleDebug

# iOS: unit tests (macOS, no simulator needed), from the repository root
swift test
bash mobile/ci-stubs/typecheck-ios-bridges.sh   # type-checks the wrappers' Swift bridges

# React Native: JS tests (Node 20 or newer; no dependencies to install)
cd mobile/react-native && node --test

# Flutter
cd mobile/flutter && flutter pub get && flutter analyze && flutter test

# Specification: schemas and vectors
npm ci && npm test -w spec

# The generated copies of the native cores are up to date
node mobile/sync-native.mjs --check
```

The same commands run in CI (`.github/workflows/ci.yaml`).

## Guidelines

- Public methods of the SDKs never throw and never block the calling thread; keep it that way.
- Behaviour that the specification describes must stay the same on every platform. If you change it on one, say so in the pull request.
- Anything that touches consent, identifiers or personal data needs a test.
- Use obviously fake data in tests and examples (`user@example.com`, `example0key00000`); no real names, keys or customer identifiers.
- Write code comments, documentation and log messages in English.

## License

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
