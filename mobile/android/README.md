# SmartBee Pixel — Android SDK

Kotlin, `minSdk 21`. İş vaxtı asılılığı yoxdur (yalnız Android platforması və Kotlin stdlib).

## İstifadə

```kotlin
// Application.onCreate
SmartBee.init(this, "MƏNBƏ_AÇARI")

SmartBee.track("Purchase", mapOf("value" to 250, "currency" to "AZN", "order_id" to "A-1001"), eventId = "order:A-1001")
SmartBee.identify("user-42", mapOf("email" to "a@b.az"))   // e-poçt cihazda hash olunur
SmartBee.setConsent(analytics = true, ads = false)
SmartBee.reset()                                             // çıxış
```

Tam API: [../../spec/SDK-API.md](../../spec/SDK-API.md).

## Quruluş

| Fayl | Məzmun |
|---|---|
| `SmartBee.kt` | Açıq API, tək arxa axın, Activity həyat dövrü |
| `Core.kt` | Bütün məntiq; Android-dən asılı deyil, JVM testləri ilə yoxlanır |
| `Internals.kt` | İnterfeyslər, uzaqdan konfiq, təmizləmə və hash köməkçiləri |
| `AndroidImpl.kt` | SQLite bazası (növbə və yaddaş, ehtiyat nüsxəyə düşmür), HTTPS nəqliyyatı, cihaz konteksti |

## Yığma və test

```sh
./gradlew :pixel:testDebugUnitTest :pixel:assembleRelease
```

JDK 17+ və Android SDK (compileSdk 35) lazımdır. Testlər topluları `spec` sxemi və vektorları ilə yoxlayır.

## Ekran adları

Avtomatik `ScreenView` ekran adı kimi Activity sinfinin adını götürür. Kod kiçildilən (R8) buraxılış yığmalarında bu ad mənasız olur; belə tətbiqlərdə və tək Activity-li (Compose) tətbiqlərdə `SmartBee.screen("ad")` çağırın.

## Bu versiyada olmayanlar

- Reklam ID-si (GAID) və Play Install Referrer: Google kitabxanası asılılığı tələb edir.
- Maven Central-a dərc konfiqurasiyası.
- Cihazda / emulyatorda işləyən (instrumented) testlər.
