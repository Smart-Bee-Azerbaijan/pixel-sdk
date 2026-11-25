# SmartBee Pixel — React Native SDK

Nativ Android və iOS SDK-larının üstündə nazik örtük. Öz məntiqi yoxdur.

```ts
import SmartBee from '@smartbee/pixel';

await SmartBee.init('MƏNBƏ_AÇARI');
SmartBee.track('Purchase', { value: 250, currency: 'AZN', order_id: 'A-1001' }, { eventId: 'order:A-1001' });
SmartBee.identify('user-42', { email: 'a@b.az' });   // e-poçt cihazda hash olunur
SmartBee.screen('Cart');
SmartBee.setConsent({ analytics: true, ads: false });
SmartBee.reset();
```

- `ScreenView` avtomatik tutulmur: naviqasiya kitabxananızın ekran dəyişmə hadisəsində `SmartBee.screen()` çağırın.
- Keçidlər (deep link) avtomatik izlənir: Android-də nativ SDK, iOS-da React Native-in `Linking` modulu vasitəsilə. iOS-da `Linking`-in işləməsi üçün `AppDelegate`-də standart React Native `RCTLinkingManager` quraşdırması olmalıdır.
- `android/src/main/java/az/smartbee/pixel/*.kt` və `ios/Core/*.swift` nativ nüvənin nüsxəsidir; onları dəyişməyin, `node mobile/sync-native.mjs` işlədin.

Test: `node --test`. Android körpüsünün yığılması: `mobile/android`-da `./gradlew :rn-bridge:assembleRelease`.
