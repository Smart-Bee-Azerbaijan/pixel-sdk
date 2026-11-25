# Security policy

## Reporting a vulnerability

Please do **not** open a public issue for a security problem.

Use GitHub's private vulnerability reporting for this repository: open the **Security** tab and choose **Report a vulnerability** (https://github.com/Smart-Bee-Azerbaijan/pixel-sdk/security/advisories/new). The report is visible only to the maintainers.

Please include:

- the affected SDK (Android, iOS, Flutter, React Native, web snippet) and its version;
- what an attacker can do and under which conditions;
- steps to reproduce, or a proof of concept, if you have one.

We will acknowledge the report, tell you whether we consider it a vulnerability and how we plan to fix it. Please give us a reasonable time to release a fix before disclosing the issue publicly; we will credit you in the release notes unless you prefer otherwise.

## Scope

In scope:

- the code in this repository (the mobile SDKs, the wrapper packages, the specification);
- the artifacts built from it: `az.smartbee:pixel` as served from the SmartBee Maven repository, the `SmartBeePixel` Swift package, and the `smartbee_pixel` (Flutter) and `@smartbee/pixel` (React Native) packages as they exist in this repository;
- the handling of personal data and consent by the SDKs: anything that makes an SDK send or store data that the documentation says it does not.

Out of scope for this repository (but still welcome through the same channel): the SmartBee collection service at `c.cdnsb.net` and the web tracker script it serves, whose source is not published here.

Please do not test against other organisations' keys or data, and do not run load tests against the production service.

## Supported versions

Security fixes are released for the latest 1.x version of each SDK. Before the `v1.0.0` tag there is no released version: fixes land on the `main` branch.

## Verifying what you install

- None of the packages has been published to a public registry (Maven Central, CocoaPods trunk, pub.dev, npm). Until the README says otherwise, the only legitimate sources are this repository and the SmartBee Maven repository at `https://c.cdnsb.net/maven`. A package with one of these names on a registry is not ours unless the README says so; please report it through the channel above.
- Android: depend on an exact version and use Gradle dependency verification; the SHA-256 of every file is served next to it in the Maven repository (see the README). Until the `v1.0.0` tag exists, the `1.0.0` artifact there is a pre-release build that may be rebuilt in place, so do not pin its checksum yet; from the tag onward a version is immutable and a changed checksum is a reason to stop and report.
- iOS, Flutter, React Native: pin a commit of this repository (or, once it exists, a tag); the lock files of your package manager record what was resolved.
