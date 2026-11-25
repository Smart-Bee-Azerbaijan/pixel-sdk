import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart';

/// Razılıq vəziyyəti.
class SmartBeeConsent {
  const SmartBeeConsent({required this.analytics, required this.ads});

  final bool analytics;
  final bool ads;
}

/// SmartBee Pixel-in Flutter API-si. Öz məntiqi yoxdur: hər çağırış nativ SDK-ya ötürülür.
///
/// Metodlar heç vaxt istisna atmır; nativ tərəf əlçatmazdırsa çağırış nəzərə alınmır.
class SmartBee {
  SmartBee._();

  /// Örtüyün versiyası; toplularda `sdk.wrapper_version` kimi göndərilir.
  /// pubspec.yaml-dakı versiya ilə eyni olmalıdır (testlə yoxlanır).
  static const String version = '1.0.0';

  static const MethodChannel _channel = MethodChannel('az.smartbee/pixel');

  static Future<T?> _invoke<T>(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } catch (_) {
      // MissingPluginException, PlatformException və kodlaşdırma xətaları tətbiqi sındırmamalıdır.
      return null;
    }
  }

  /// Kanaldan keçə bilən dəyər qaytarır. Dəstəklənməyən dəyər üçün [_drop].
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

  /// SDK-nı başladır. Təkrar çağırış nəzərə alınmır.
  static Future<void> init(
    String key, {
    SmartBeeConsent? consent,
    bool debug = false,
    bool autoEvents = true,
    String? endpoint,
  }) {
    return _invoke<void>('start', {
      'key': key,
      'debug': debug,
      'autoEvents': autoEvents,
      'endpoint': endpoint,
      'consent': consent == null ? null : {'analytics': consent.analytics, 'ads': consent.ads},
      'wrapperVersion': version,
    });
  }

  /// Event göndərir. [eventId] server tərəfi ilə dedup üçündür (məsələn sifariş nömrəsi).
  static Future<void> track(String name, [Map<String, Object?>? props, String? eventId]) {
    return _invoke<void>('track', {'name': name, 'props': _object(props), 'eventId': eventId});
  }

  /// İstifadəçini tanıdır. `email` və `phone` cihazda SHA-256 ilə hash olunur.
  static Future<void> identify(String userId, [Map<String, Object?>? traits]) {
    return _invoke<void>('identify', {'userId': userId, 'traits': _object(traits)});
  }

  /// Ekran baxışı. Flutter-də ekranlar nativ tərəfdə görünmür, ona görə əl ilə çağırılır.
  static Future<void> screen(String name, [Map<String, Object?>? props]) {
    return _invoke<void>('screen', {'name': name, 'props': _object(props)});
  }

  /// Razılığı dəyişir və saxlayır. `analytics: false` olduqda heç nə göndərilmir və saxlanmır.
  static Future<void> setConsent({required bool analytics, required bool ads}) {
    return _invoke<void>('setConsent', {'analytics': analytics, 'ads': ads});
  }

  /// Çıxış: istifadəçi silinir, yeni anonim ID və sessiya yaradılır.
  static Future<void> reset() => _invoke<void>('reset');

  /// Növbəni dərhal göndərir.
  static Future<void> flush() => _invoke<void>('flush');

  /// Tətbiq keçidlə (deep link / universal link) açılanda çağırılır.
  ///
  /// Yalnız iOS-da lazımdır: orada nativ SDK keçidləri özü tuta bilmir, Flutter-in də daxili
  /// keçid API-si yoxdur (adətən `app_links` kimi paketdən alınan ünvan bura ötürülür).
  /// Android-də nativ SDK keçidi Activity-dən özü oxuyur, ona görə çağırış nəzərə alınmır
  /// (ikiqat sayılmasın).
  static Future<void> handleDeepLink(String url) {
    if (url.isEmpty || defaultTargetPlatform != TargetPlatform.iOS) return Future<void>.value();
    return _invoke<void>('handleDeepLink', {'url': url});
  }

  /// Cari anonim ID; SDK başlamayıbsa və ya razılıq yoxdursa null.
  static Future<String?> getAnonymousId() => _invoke<String>('getAnonymousId');
}
