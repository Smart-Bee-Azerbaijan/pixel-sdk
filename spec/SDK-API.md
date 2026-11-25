# SmartBee Pixel — SDK API v1

Vəziyyət: **qaralama**. Bütün platformalarda eyni metodlar, eyni adlar və eyni davranış.

## Metodlar

| Metod | Təsvir |
|---|---|
| `init(key, options?)` | SDK-nı başladır. Vebdə lazım deyil (açar skriptin URL-indədir). Təkrar çağırış nəzərə alınmır. |
| `track(name, props?, options?)` | Event göndərir. `options.eventId` ilə öz ID-nizi verə bilərsiniz (server tərəfi ilə dedup üçün). |
| `identify(userId, traits?)` | İstifadəçini tanıdır. Sonrakı bütün eventlərə `user_id` əlavə olunur. |
| `screen(name, props?)` | Mobil: ekran baxışı. Vebdə `page(props?)`: SPA-da əl ilə səhifə baxışı. |
| `setConsent({ analytics, ads })` | Razılığı dəyişir və saxlayır. |
| `reset()` | Çıxış: `user_id` silinir, yeni anonim ID və sessiya yaradılır. |
| `flush()` | Növbəni dərhal göndərir. |
| `getAnonymousId()` | Cari anonim ID-ni qaytarır. |

## `init` seçimləri

| Seçim | Susmaya görə | Təsvir |
|---|---|---|
| `consent` | konfiqdən | Başlanğıc razılıq. |
| `debug` | `false` | Ətraflı log. |
| `autoEvents` | `true` | `false` olarsa bütün avtomatik eventlər sönür (konfiqdən asılı olmayaraq). |
| `endpoint` | `https://c.cdnsb.net` | Yalnız test və ya proksi üçün. |

## Platformalar üzrə çağırış

Veb:

```js
smartbee('track', 'Purchase', { value: 250, currency: 'AZN', order_id: 'A-1001' });
smartbee('identify', 'user-42', { email: 'a@b.az' });
smartbee('setConsent', { analytics: true, ads: false });
```

Android (Kotlin):

```kotlin
SmartBee.init(context, "k7m2x9qa4t")
SmartBee.track("Purchase", mapOf("value" to 250, "currency" to "AZN", "order_id" to "A-1001"))
SmartBee.identify("user-42", mapOf("email" to "a@b.az"))
```

iOS (Swift):

```swift
SmartBee.initialize(key: "k7m2x9qa4t")
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
SmartBee.track('Purchase', {'value': 250, 'currency': 'AZN', 'order_id': 'A-1001'});
```

Swift-də `init` açar sözü olduğu üçün metod `initialize` adlanır.

iOS-da əlavə bir metod var: `SmartBee.handleDeepLink(_ url: URL)`. iOS-da SDK keçidləri və ekran dəyişmələrini tətbiqin sistem metodlarını dəyişdirmədən tuta bilmir, ona görə bunlar tətbiq tərəfindən ötürülür.

## Ortaq davranış

1. **Heç vaxt tətbiqi / saytı sındırmır.** SDK-nın daxilindəki bütün xətalar tutulur; açıq metodlar istisna atmır.
2. **`init`-dən əvvəlki çağırışlar itmir.** Növbəyə yığılır və `init`-dən sonra icra olunur.
3. **Eventlər növbədən keçir.** Vebdə yaddaşda (səhifə bağlananda `sendBeacon` ilə boşaldılır), mobildə diskdə.
4. **Göndərmə toplu ilədir.** Konfiqdəki `flush` parametrləri ilə: müddət dolanda, toplu dolanda, tətbiq arxa fona keçəndə.
5. **Yararsız giriş atılır.** Yararsız event adı, limiti aşan `props`, qadağan olunmuş açarlar; sazlama rejimində xəbərdarlıq verilir.
6. **Şəxsi məlumat hash olunur.** `identify`-dakı `email` və `phone` cihazı tərk etməzdən əvvəl SHA-256-ya çevrilir ([PROTOCOL.md](PROTOCOL.md), 6.1).
7. **Razılıq hər şeydən üstündür.** `analytics: false` olduqda heç nə göndərilmir və saxlanmır.
8. **Əsas axını bloklamır.** Mobil SDK-da disk və şəbəkə işi arxa axındadır.

## Avtomatik eventlər

| Event | Platforma | Nə vaxt |
|---|---|---|
| `PageView` | veb | Səhifə yüklənəndə və SPA-da URL dəyişəndə |
| `FormSubmit` | veb | Form göndəriləndə |
| `OutboundClick` | veb | Başqa domenə keçid kliklənəndə |
| `ContactClick` | veb | `tel:`, `mailto:`, WhatsApp keçidi kliklənəndə |
| `AppInstall` | mobil | İlk açılışda |
| `AppUpdate` | mobil | Versiya dəyişəndən sonrakı ilk açılışda |
| `AppOpen` | mobil | Tətbiq ön plana keçəndə |
| `SessionStart` | hamısı | Yeni sessiya başlayanda |
| `ScreenView` | Android | Activity dəyişəndə. iOS, React Native və Flutter-də `screen()` əl ilə çağırılır |
| `DeepLinkOpen` | mobil | Tətbiq keçidlə açılanda. Android-də avtomatik; iOS-da tətbiq `SmartBee.handleDeepLink(url)` çağırır |

Hamısı `origin: auto` ilə göndərilir və konfiqdəki `auto` açarları ilə uzaqdan söndürülə bilər.

## Örtüklər (React Native, Flutter)

- Öz məntiqləri yoxdur: hər çağırış nativ SDK-ya ötürülür.
- Topluda `sdk.wrapper` və `sdk.wrapper_version` göndərilir.
- `ScreenView` avtomatik tutulmur (nativ ekran yalnız birdir); naviqasiya kitabxanası üçün hazır inteqrasiya verilir və ya `screen()` əl ilə çağırılır.
