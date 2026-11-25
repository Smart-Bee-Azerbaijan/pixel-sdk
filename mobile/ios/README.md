# SmartBee Pixel — iOS SDK

Swift Package, iOS 13+. Asılılığı yoxdur.

## İstifadə

```swift
import SmartBeePixel

// application(_:didFinishLaunchingWithOptions:)
SmartBee.initialize(key: "MƏNBƏ_AÇARI")

SmartBee.track("Purchase", props: ["value": 250, "currency": "AZN", "order_id": "A-1001"], eventId: "order:A-1001")
SmartBee.identify("user-42", traits: ["email": "a@b.az"])   // e-poçt cihazda hash olunur
SmartBee.screen("ProductDetail")
SmartBee.setConsent(analytics: true, ads: false)
SmartBee.reset()                                              // çıxış

// Tətbiq keçidlə açılanda (URL scheme və ya universal link)
SmartBee.handleDeepLink(url)
```

Tam API: [../../spec/SDK-API.md](../../spec/SDK-API.md).

## Quruluş

| Fayl | Məzmun |
|---|---|
| `SmartBee.swift` | Açıq API, tək ardıcıl növbə, tətbiqin həyat dövrü |
| `Core.swift` | Bütün məntiq; UIKit-dən asılı deyil, macOS-da `swift test` ilə yoxlanır |
| `Internals.swift` | Protokollar, uzaqdan konfiq, təmizləmə və hash köməkçiləri |
| `Platform.swift` | Fayl yaddaşı və növbəsi (ehtiyat nüsxədən çıxarılıb), URLSession nəqliyyatı, cihaz konteksti |
| `PrivacyInfo.xcprivacy` | Apple privacy manifest |

## Yığma və test

macOS lazımdır. CI: `.github/workflows/ci-ios.yaml`.

```sh
swift test
xcodebuild build -scheme SmartBeePixel -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

## Android SDK-dan fərqlər

- `ScreenView` avtomatik tutulmur: `SmartBee.screen()` əl ilə çağırılır (sistem metodlarını dəyişdirmək tətbiq üçün risklidir).
- Keçidlər `SmartBee.handleDeepLink(_:)` ilə ötürülür.
- Gövdə gzip ilə sıxılmır.
- Növbə fayla qısa fasilə ilə yazılır; qəfil çökmədə son bir neçə saniyənin eventləri itə bilər.

## Bu versiyada olmayanlar

- IDFA və App Tracking Transparency (yalnız IDFV, reklam razılığı ilə göndərilir).
- CocoaPods podspec.
- Cihazda / simulyatorda işləyən testlər.
