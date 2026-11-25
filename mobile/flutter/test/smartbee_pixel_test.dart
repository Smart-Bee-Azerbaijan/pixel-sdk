import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartbee_pixel/smartbee_pixel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('az.smartbee/pixel');
  final calls = <MethodCall>[];
  Object? Function(MethodCall call)? handler;

  setUp(() {
    calls.clear();
    handler = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handler?.call(call);
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('init seçimləri və örtük versiyasını ötürür', () async {
    await SmartBee.init('demo0andr1', debug: true, consent: const SmartBeeConsent(analytics: true, ads: false), endpoint: 'https://proxy.example.com');
    await SmartBee.init('demo0andr1');
    expect(calls.map((c) => c.method), ['start', 'start']);
    expect(calls[0].arguments, {
      'key': 'demo0andr1',
      'debug': true,
      'autoEvents': true,
      'endpoint': 'https://proxy.example.com',
      'consent': {'analytics': true, 'ads': false},
      'wrapperVersion': SmartBee.version,
    });
    expect(calls[1].arguments['consent'], isNull);
    expect(calls[1].arguments['endpoint'], isNull);
  });

  test('track parametrləri kanaldan keçə bilən formaya gətirir', () async {
    await SmartBee.track(
      'Purchase',
      {
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
      'order:A-1',
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

  test('identify, screen, setConsent, reset və flush', () async {
    await SmartBee.identify('user-42', {'email': 'a@b.az'});
    await SmartBee.screen('Cart', {'items': 2});
    await SmartBee.setConsent(analytics: true, ads: false);
    await SmartBee.reset();
    await SmartBee.flush();
    expect(calls.map((c) => c.method), ['identify', 'screen', 'setConsent', 'reset', 'flush']);
    expect(calls[0].arguments, {
      'userId': 'user-42',
      'traits': {'email': 'a@b.az'},
    });
    expect(calls[1].arguments, {
      'name': 'Cart',
      'props': {'items': 2},
    });
    expect(calls[2].arguments, {'analytics': true, 'ads': false});
    expect(calls[3].arguments, isNull);
  });

  test('getAnonymousId nativ dəyəri qaytarır', () async {
    handler = (call) => call.method == 'getAnonymousId' ? 'anon-1' : null;
    expect(await SmartBee.getAnonymousId(), 'anon-1');
    handler = (_) => null;
    expect(await SmartBee.getAnonymousId(), isNull);
  });

  test('nativ xəta və qoşulmamış plagin istisna atmır', () async {
    handler = (_) => throw PlatformException(code: 'boom');
    await SmartBee.init('demo0andr1');
    await SmartBee.track('Lead', {'a': 1});
    await SmartBee.identify('u');
    expect(await SmartBee.getAnonymousId(), isNull);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    await SmartBee.track('Lead');
    await SmartBee.flush();
    expect(await SmartBee.getAnonymousId(), isNull);
  });

  auditTests(channel, calls);

  test('çox dərin parametrlər kəsilir, dövri istinad sonsuz dövrə salmır', () async {
    final circular = <String, Object?>{};
    circular['self'] = circular;
    await SmartBee.track('Lead', circular);
    expect(calls.single.method, 'track');
    final props = calls.single.arguments['props'] as Map;
    expect(props.containsKey('self'), isTrue);
  });
}

// ---- Audit (AUDIT.md, bölmə 8) ----------------------------------------------

void auditTests(MethodChannel channel, List<MethodCall> calls) {
  test('audit: handleDeepLink yalnız iOS-da nativ tərəfə ötürülür', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await SmartBee.handleDeepLink('myapp://product/1?utm_source=fb');
      await SmartBee.handleDeepLink('');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    expect(calls.map((c) => c.method), ['handleDeepLink']);
    expect(calls.single.arguments, {'url': 'myapp://product/1?utm_source=fb'});

    calls.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await SmartBee.handleDeepLink('myapp://product/1');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    expect(calls, isEmpty);
  });

  test('audit: version pubspec.yaml ilə eynidir', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec);
    expect(match, isNotNull);
    expect(SmartBee.version, match!.group(1));
  });

  test('audit: nativ nüvənin nüsxələri və plagin faylları yerindədir', () {
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
    // Dart tərəfinin göndərdiyi hər metodun hər iki nativ plagində qarşılığı olmalıdır.
    final dart = File('lib/smartbee_pixel.dart').readAsStringSync();
    final methods = RegExp(r"_invoke<[^>]+>\('(\w+)'").allMatches(dart).map((m) => m.group(1)!).toSet();
    expect(methods, {'start', 'track', 'identify', 'screen', 'setConsent', 'reset', 'flush', 'handleDeepLink', 'getAnonymousId'});
    final kotlin = File('android/src/main/kotlin/az/smartbee/pixel/flutter/SmartBeePixelPlugin.kt').readAsStringSync();
    final swift = File('ios/Classes/SmartBeePixelPlugin.swift').readAsStringSync();
    for (final method in methods) {
      expect(kotlin.contains('"$method" ->'), isTrue, reason: 'Kotlin: $method');
      expect(swift.contains('case "$method":'), isTrue, reason: 'Swift: $method');
    }
  });

  test('audit: sonsuz ədədlər və sətir olmayan açarlar atılır, dərinlik məhduddur', () async {
    Object? deep = 1;
    for (var i = 0; i < 20; i++) {
      deep = {'d': deep};
    }
    await SmartBee.track('Lead', {'inf': double.infinity, 'neg': double.negativeInfinity, 'ok': 1.5, 'deep': deep});
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
