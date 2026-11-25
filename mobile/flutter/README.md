# SmartBee Pixel — Flutter SDK

Nativ Android və iOS SDK-larının üstündə nazik örtük. Öz məntiqi yoxdur.

```dart
import 'package:smartbee_pixel/smartbee_pixel.dart';

await SmartBee.init('MƏNBƏ_AÇARI');
SmartBee.track('Purchase', {'value': 250, 'currency': 'AZN', 'order_id': 'A-1001'}, 'order:A-1001');
SmartBee.identify('user-42', {'email': 'a@b.az'});   // e-poçt cihazda hash olunur
SmartBee.screen('Cart');
SmartBee.setConsent(analytics: true, ads: false);
SmartBee.reset();
```

- `ScreenView` avtomatik tutulmur: `NavigatorObserver`-də `SmartBee.screen()` çağırın.
- Keçidlər (deep link): Android-də avtomatik izlənir. iOS-da ünvanı (məsələn `app_links` paketindən) `SmartBee.handleDeepLink(url)` ilə ötürün; bu çağırış Android-də heç nə etmir.
- `android/src/main/kotlin/az/smartbee/pixel/*.kt` və `ios/Classes/Core/*.swift` nativ nüvənin nüsxəsidir; onları dəyişməyin, `node mobile/sync-native.mjs` işlədin.

Test: `flutter analyze && flutter test`.
