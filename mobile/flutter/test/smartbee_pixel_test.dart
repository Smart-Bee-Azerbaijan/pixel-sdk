import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartbee_pixel/smartbee_pixel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('az.smartbee/pixel');
  const key = 'demo0key01';
  final calls = <MethodCall>[];
  Object? Function(MethodCall call)? handler;

  setUp(() {
    calls.clear();
    // By default the native side accepts `start` and answers null to everything else.
    handler = (call) => call.method == 'start' ? true : null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handler?.call(call);
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('init forwards the options and the wrapper version and completes with true', () async {
    expect(
      await SmartBee.init(key, debug: true, consent: const SmartBeeConsent(analytics: true, ads: false), endpoint: 'https://proxy.example.com'),
      isTrue,
    );
    expect(await SmartBee.init(key), isTrue);
    expect(calls.map((c) => c.method), ['start', 'start']);
    expect(calls[0].arguments, {
      'key': key,
      'debug': true,
      'autoEvents': true,
      'endpoint': 'https://proxy.example.com',
      'collectAdvertisingId': true,
      'consent': {'analytics': true, 'ads': false},
      'wrapperVersion': SmartBee.version,
    });
    expect(calls[1].arguments['consent'], isNull);
    expect(calls[1].arguments['endpoint'], isNull);
  });

  test('init completes with false for a malformed key, a native refusal and a native error', () async {
    for (final bad in ['', 'short', 'UPPERCASE1', 'has space1', 'kkkkkkkkkkkkkkkkk']) {
      expect(await SmartBee.init(bad), isFalse, reason: bad);
    }
    expect(calls, isEmpty);

    handler = (_) => false;
    expect(await SmartBee.init(key), isFalse);
    handler = (_) => null;
    expect(await SmartBee.init(key), isFalse);
    handler = (_) => throw PlatformException(code: 'boom');
    expect(await SmartBee.init(key), isFalse);
  });

  test('collectAdvertisingId defaults to true and can be sent as false', () async {
    await SmartBee.init(key);
    await SmartBee.init(key, collectAdvertisingId: false);
    await SmartBee.init(key, collectAdvertisingId: true);
    expect(calls.map((c) => c.arguments['collectAdvertisingId']), [true, false, true]);
  });

  test('SmartBeeConsent.fromMap fails closed', () {
    final cases = <Map<Object?, Object?>, List<bool>>{
      {'analytics': true, 'ads': true}: [true, true],
      {'analytics': true}: [true, false],
      {'ads': true}: [false, true],
      {'analytics': false}: [false, false],
      {'analytics': 'yes', 'ads': 1}: [false, false],
      {'analytics': null, 'ads': true}: [false, true],
      {}: [false, false],
    };
    cases.forEach((map, expected) {
      final consent = SmartBeeConsent.fromMap(map);
      expect([consent.analytics, consent.ads], expected, reason: '$map');
    });
  });

  test('track brings props into a form that can cross the channel', () async {
    await SmartBee.track(
      'Purchase',
      props: {
        'value': 250,
        'when': DateTime.utc(2026, 11, 25, 7),
        'nan': double.nan,
        'object': Object(),
        'nothing': null,
        'nested': {
          'list': [1, Object(), 'a'],
          1: 'non-string key',
        },
      },
      eventId: 'order:A-1',
    );
    await SmartBee.track('Lead');
    expect(calls[0].arguments, {
      'name': 'Purchase',
      'props': {
        'value': 250,
        'when': '2026-11-25T07:00:00.000Z',
        'nothing': null,
        'nested': {
          'list': [1, 'a'],
        },
      },
      'eventId': 'order:A-1',
    });
    expect(calls[1].arguments, {'name': 'Lead', 'props': null, 'eventId': null});
  });

  test('an empty name is ignored', () async {
    await SmartBee.track('');
    await SmartBee.track('', props: {'a': 1});
    await SmartBee.identify('');
    await SmartBee.screen('');
    await SmartBee.handleDeepLink('');
    expect(calls, isEmpty);
  });

  test('identify, screen, setConsent, setConsentValue, reset and flush', () async {
    await SmartBee.identify('user-42', traits: {'email': 'user@example.com'});
    await SmartBee.screen('Cart', props: {'items': 2});
    await SmartBee.setConsent(analytics: true, ads: false);
    await SmartBee.setConsentValue(SmartBeeConsent.fromMap({'ads': true}));
    await SmartBee.reset();
    await SmartBee.flush();
    expect(calls.map((c) => c.method), ['identify', 'screen', 'setConsent', 'setConsent', 'reset', 'flush']);
    expect(calls[0].arguments, {
      'userId': 'user-42',
      'traits': {'email': 'user@example.com'},
    });
    expect(calls[1].arguments, {
      'name': 'Cart',
      'props': {'items': 2},
    });
    expect(calls[2].arguments, {'analytics': true, 'ads': false});
    expect(calls[3].arguments, {'analytics': false, 'ads': true});
    expect(calls[4].arguments, isNull);
  });

  test('getAnonymousId returns the native value', () async {
    handler = (call) => call.method == 'getAnonymousId' ? 'anon-1' : null;
    expect(await SmartBee.getAnonymousId(), 'anon-1');
    handler = (_) => null;
    expect(await SmartBee.getAnonymousId(), isNull);
  });

  test('a native error and an unregistered plugin never throw', () async {
    handler = (_) => throw PlatformException(code: 'boom');
    expect(await SmartBee.init(key), isFalse);
    await SmartBee.track('Lead', props: {'a': 1});
    await SmartBee.identify('u');
    expect(await SmartBee.getAnonymousId(), isNull);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    expect(await SmartBee.init(key), isFalse);
    await SmartBee.track('Lead');
    await SmartBee.flush();
    expect(await SmartBee.getAnonymousId(), isNull);
  });

  packagingTests(channel, calls);

  test('very deep props are cut off and a circular reference does not loop forever', () async {
    final circular = <String, Object?>{};
    circular['self'] = circular;
    await SmartBee.track('Lead', props: circular);
    expect(calls.single.method, 'track');
    final props = calls.single.arguments['props'] as Map;
    expect(props.containsKey('self'), isTrue);
  });
}

void packagingTests(MethodChannel channel, List<MethodCall> calls) {
  test('handleDeepLink is forwarded to the native side on iOS and Android', () async {
    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      calls.clear();
      debugDefaultTargetPlatformOverride = platform;
      try {
        await SmartBee.handleDeepLink('myapp://product/1?utm_source=fb');
        await SmartBee.handleDeepLink('');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
      expect(calls.map((c) => c.method), ['handleDeepLink'], reason: '$platform');
      expect(calls.single.arguments, {'url': 'myapp://product/1?utm_source=fb'});
    }
  });

  test('version equals pubspec.yaml and sdkVersion equals version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec);
    expect(match, isNotNull);
    expect(SmartBee.version, match!.group(1));
    expect(SmartBee.sdkVersion, SmartBee.version);
  });

  test('the copies of the native core and the plugin files are in place', () {
    for (final path in [
      'android/src/main/kotlin/az/smartbee/pixel/Core.kt',
      'android/src/main/kotlin/az/smartbee/pixel/flutter/SmartBeePixelPlugin.kt',
      'ios/Classes/Core/Core.swift',
      'ios/Classes/SmartBeePixelPlugin.swift',
      'ios/Resources/PrivacyInfo.xcprivacy',
      'ios/smartbee_pixel.podspec',
    ]) {
      expect(File(path).existsSync(), isTrue, reason: path);
    }
    // Every method the Dart side sends must have a counterpart in both native plugins.
    final dart = File('lib/smartbee_pixel.dart').readAsStringSync();
    final methods = RegExp(r"_invoke<[^>]+>\('(\w+)'").allMatches(dart).map((m) => m.group(1)!).toSet();
    expect(methods, {'start', 'track', 'identify', 'screen', 'setConsent', 'reset', 'flush', 'handleDeepLink', 'getAnonymousId'});
    final kotlin = File('android/src/main/kotlin/az/smartbee/pixel/flutter/SmartBeePixelPlugin.kt').readAsStringSync();
    final swift = File('ios/Classes/SmartBeePixelPlugin.swift').readAsStringSync();
    for (final method in methods) {
      expect(kotlin.contains('"$method" ->'), isTrue, reason: 'Kotlin: $method');
      expect(swift.contains('case "$method":'), isTrue, reason: 'Swift: $method');
    }
    // The native plugins default a missing consent purpose to false (consent fails closed).
    expect(kotlin.contains('rawConsent["analytics"] as? Boolean ?: false'), isTrue);
    expect(kotlin.contains('rawConsent["ads"] as? Boolean ?: false'), isTrue);
    // A `consent` that is present but is not a map is denied as a whole.
    expect(kotlin.contains('else -> SmartBeeConsent(false, false)'), isTrue);
    expect(swift.contains('options.consent = SmartBeeConsent(analytics: false, ads: false)'), isTrue);
    // iOS: a real boolean only, the number 1 is not consent.
    expect(swift.contains('CFGetTypeID(number) == CFBooleanGetTypeID()'), isTrue);
    expect(swift.contains('strictBool(consent["analytics"]) ?? false'), isTrue);
    expect(swift.contains('strictBool(consent["ads"]) ?? false'), isTrue);
    expect(swift.contains('as? Bool ?? false'), isFalse);
  });

  test('infinite numbers and non-string keys are dropped and the depth is limited', () async {
    Object? deep = 1;
    for (var i = 0; i < 20; i++) {
      deep = {'d': deep};
    }
    await SmartBee.track('Lead', props: {'inf': double.infinity, 'neg': double.negativeInfinity, 'ok': 1.5, 'deep': deep});
    final props = calls.single.arguments['props'] as Map;
    expect(props.keys.toSet(), {'ok', 'deep'});
    var levels = 0;
    Object? cursor = props['deep'];
    while (cursor is Map && cursor.containsKey('d')) {
      cursor = cursor['d'];
      levels++;
    }
    expect(levels, lessThan(6));
  });
}
