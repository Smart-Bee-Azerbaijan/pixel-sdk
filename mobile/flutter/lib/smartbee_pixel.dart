import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Consent state for the two purposes the SDK distinguishes.
class SmartBeeConsent {
  /// Creates a consent value; both purposes must be stated.
  const SmartBeeConsent({required this.analytics, required this.ads});

  /// Reads consent from a loosely typed map (for example the answer of a consent management platform).
  ///
  /// Fails closed: a purpose that is missing or is not a `bool` is treated as `false`.
  factory SmartBeeConsent.fromMap(Map<Object?, Object?> map) {
    final analytics = map['analytics'];
    final ads = map['ads'];
    return SmartBeeConsent(analytics: analytics is bool && analytics, ads: ads is bool && ads);
  }

  /// When `false` nothing is collected, stored or sent, and the queue and all identifiers are erased.
  final bool analytics;

  /// When `false` events are still sent, but no advertising / device identifier or click id leaves the device.
  final bool ads;
}

/// The Flutter API of SmartBee Pixel. It holds no logic of its own: every call is forwarded to the native SDK.
///
/// The methods never throw; when the native side is unavailable a call is a no-op.
class SmartBee {
  SmartBee._();

  /// The version of this package; sent in batches as `sdk.wrapper_version`.
  /// Must equal the version in pubspec.yaml (checked by a test).
  static const String version = '1.0.0';

  /// The SDK version (the plugin and the native cores it contains are released together).
  static const String sdkVersion = version;

  static const MethodChannel _channel = MethodChannel('az.smartbee/pixel');

  /// The project key format (spec/PROTOCOL.md, section 2).
  static final RegExp _keyPattern = RegExp(r'^[a-z0-9]{8,16}$');

  static bool _missingWarned = false;
  static bool _initCalled = false;

  /// Integration mistakes and swallowed errors: reported in debug builds only.
  static void _debug(String message) {
    if (kDebugMode) debugPrint('[SmartBee] $message');
  }

  static Future<T?> _invoke<T>(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      if (!_missingWarned) {
        _missingWarned = true;
        debugPrint(
          '[SmartBee] the native plugin is not registered, so every call is a no-op. '
          'This is expected on unsupported platforms and in unit tests; in an app, do a full rebuild after adding the package.',
        );
      }
      return null;
    } catch (error) {
      // A PlatformException or an encoding error must not break the app.
      _debug('$method failed: $error');
      return null;
    }
  }

  /// Returns a value that can cross the method channel, or [_drop] for an unsupported value.
  static Object? _safe(Object? value, int depth) {
    if (value == null || value is bool || value is String) return value;
    if (value is num) return value.isFinite ? value : _drop;
    if (value is DateTime) return value.toUtc().toIso8601String();
    if (depth <= 0) return _drop;
    if (value is Map) {
      final out = <String, Object?>{};
      value.forEach((key, item) {
        if (key is! String) return;
        final cleaned = _safe(item, depth - 1);
        if (!identical(cleaned, _drop)) out[key] = cleaned;
      });
      return out;
    }
    if (value is Iterable) {
      final out = <Object?>[];
      for (final item in value) {
        final cleaned = _safe(item, depth - 1);
        if (!identical(cleaned, _drop)) out.add(cleaned);
      }
      return out;
    }
    return _drop;
  }

  static const Object _drop = Object();

  static Map<String, Object?>? _object(Map<String, Object?>? value) {
    if (value == null) return null;
    final cleaned = _safe(value, 5);
    return cleaned is Map<String, Object?> ? cleaned : null;
  }

  /// `true` for a usable name; an empty one is ignored with a debug warning.
  static bool _named(String value, String what) {
    if (value.isNotEmpty) return true;
    _debug('$what must not be empty; the call is ignored');
    return false;
  }

  /// Starts the SDK. Call it once, in one place, as early as possible.
  ///
  /// Completes with `true` when the plugin accepted the call and handed it to the native SDK (plugin registered, key
  /// well-formed) and with `false` otherwise; it never throws. `true` does not mean the SDK has finished starting
  /// (start-up is asynchronous, so [getAnonymousId] may still complete with `null` right afterwards), nor that it
  /// will: in a process of a multi-process Android app that is not the main process the SDK stays disabled.
  ///
  /// A repeated call does not restart the SDK or change the key; only the more restrictive parts of its options are
  /// applied (purposes set to `false` in [consent], and `collectAdvertisingId: false`), and a warning is logged.
  ///
  /// [consent]: consent stated by the app at start. When omitted, a choice stored by an earlier [setConsent] applies,
  /// and otherwise the default of the key's remote configuration.
  ///
  /// [collectAdvertisingId]: the advertising identifier (Android: GAID; iOS: IDFA, together with the vendor
  /// identifier and the tracking permission status). Read only while advertising consent is given and, on iOS, sent
  /// only when the user has authorized tracking (ATT); with `false` it is never read.
  static Future<bool> init(
    String key, {
    SmartBeeConsent? consent,
    bool debug = false,
    bool autoEvents = true,
    String? endpoint,
    bool collectAdvertisingId = true,
  }) async {
    if (!_keyPattern.hasMatch(key)) {
      debugPrint(r'[SmartBee] init: the key must match ^[a-z0-9]{8,16}$; the SDK is not started');
      return false;
    }
    if (_initCalled) {
      debugPrint(
        '[SmartBee] init was already called. Initialise in one place: the key and options of the first call stay in '
        'effect, only stricter consent and collectAdvertisingId=false from this call are applied.',
      );
    }
    final started = await _invoke<bool>('start', {
      'key': key,
      'debug': debug,
      'autoEvents': autoEvents,
      'endpoint': endpoint,
      'collectAdvertisingId': collectAdvertisingId,
      'consent': consent == null ? null : {'analytics': consent.analytics, 'ads': consent.ads},
      'wrapperVersion': version,
    });
    if (started == true) _initCalled = true;
    return started == true;
  }

  /// Records an event. [eventId] is your own id for de-duplication with server-side events (for example an order
  /// number). An empty [name] is ignored.
  static Future<void> track(String name, {Map<String, Object?>? props, String? eventId}) async {
    if (!_named(name, 'track: the event name')) return;
    await _invoke<void>('track', {'name': name, 'props': _object(props), 'eventId': eventId});
  }

  /// Identifies the user. `email` and `phone` traits are hashed with SHA-256 on the device.
  static Future<void> identify(String userId, {Map<String, Object?>? traits}) async {
    if (!_named(userId, 'identify: the user id')) return;
    await _invoke<void>('identify', {'userId': userId, 'traits': _object(traits)});
  }

  /// Records a screen view. In Flutter the native side cannot see screens, so call it yourself
  /// (typically from a `NavigatorObserver`).
  static Future<void> screen(String name, {Map<String, Object?>? props}) async {
    if (!_named(name, 'screen: the screen name')) return;
    await _invoke<void>('screen', {'name': name, 'props': _object(props)});
  }

  /// Changes and stores consent. With `analytics: false` nothing is sent or stored.
  ///
  /// For a loosely typed source use [SmartBeeConsent.fromMap] (which fails closed) and [setConsentValue].
  static Future<void> setConsent({required bool analytics, required bool ads}) {
    return _invoke<void>('setConsent', {'analytics': analytics, 'ads': ads});
  }

  /// Same as [setConsent], with a [SmartBeeConsent] value.
  static Future<void> setConsentValue(SmartBeeConsent consent) {
    return setConsent(analytics: consent.analytics, ads: consent.ads);
  }

  /// Sign-out: the user is cleared and a new anonymous id and session are created.
  static Future<void> reset() => _invoke<void>('reset');

  /// Sends the queue now instead of waiting for the next periodic flush.
  static Future<void> flush() => _invoke<void>('flush');

  /// Call it when the app is opened through a link (deep link / universal link / app link).
  ///
  /// It works the same on iOS and Android: in a Flutter app the native SDK does not observe links itself, and
  /// Flutter has no built-in link API. Usually the URL comes from a package such as `app_links` (both the launch
  /// link and links delivered to the running app); call this once per link.
  /// Only `http`, `https` and `scheme://...` URLs up to 4096 characters are counted.
  static Future<void> handleDeepLink(String url) {
    if (url.isEmpty) return Future<void>.value();
    return _invoke<void>('handleDeepLink', {'url': url});
  }

  /// The current anonymous id; `null` when the SDK has not finished starting, analytics consent is missing or not
  /// known yet, or the native plugin is not registered.
  static Future<String?> getAnonymousId() => _invoke<String>('getAnonymousId');
}
