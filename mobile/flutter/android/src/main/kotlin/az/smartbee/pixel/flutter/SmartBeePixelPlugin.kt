package az.smartbee.pixel.flutter

import android.content.Context
import az.smartbee.pixel.Consent
import az.smartbee.pixel.SmartBee
import az.smartbee.pixel.SmartBeeOptions
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Dart çağırışlarını nativ SDK-ya ötürür. Öz məntiqi yoxdur. */
class SmartBeePixelPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "az.smartbee/pixel").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    @Suppress("UNCHECKED_CAST")
    private fun MethodCall.map(key: String): Map<String, Any?>? = argument<Any?>(key) as? Map<String, Any?>

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "start" -> {
                    val app = context
                    val key = call.argument<String>("key")
                    if (app != null && key != null) {
                        val consent = call.map("consent")?.let {
                            val analytics = it["analytics"] as? Boolean
                            val ads = it["ads"] as? Boolean
                            if (analytics != null && ads != null) Consent(analytics, ads) else null
                        }
                        val defaults = SmartBeeOptions()
                        SmartBee.init(
                            app,
                            key,
                            SmartBeeOptions(
                                consent = consent,
                                debug = call.argument<Boolean>("debug") ?: false,
                                autoEvents = call.argument<Boolean>("autoEvents") ?: true,
                                endpoint = call.argument<String>("endpoint") ?: defaults.endpoint,
                                wrapper = "flutter",
                                wrapperVersion = call.argument<String>("wrapperVersion"),
                            ),
                        )
                    }
                    result.success(null)
                }
                "track" -> {
                    call.argument<String>("name")?.let { SmartBee.track(it, call.map("props"), call.argument<String>("eventId")) }
                    result.success(null)
                }
                "identify" -> {
                    call.argument<String>("userId")?.let { SmartBee.identify(it, call.map("traits")) }
                    result.success(null)
                }
                "screen" -> {
                    call.argument<String>("name")?.let { SmartBee.screen(it, call.map("props")) }
                    result.success(null)
                }
                "setConsent" -> {
                    val analytics = call.argument<Boolean>("analytics")
                    val ads = call.argument<Boolean>("ads")
                    if (analytics != null && ads != null) SmartBee.setConsent(analytics, ads)
                    result.success(null)
                }
                "reset" -> {
                    SmartBee.reset()
                    result.success(null)
                }
                "flush" -> {
                    SmartBee.flush()
                    result.success(null)
                }
                // Android-də nativ SDK keçidi Activity-dən özü oxuyur; Dart tərəfi də bu çağırışı göndərmir.
                "handleDeepLink" -> result.success(null)
                "getAnonymousId" -> result.success(SmartBee.getAnonymousId())
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            // Körpü xətası tətbiqi sındırmamalıdır.
            result.success(null)
        }
    }
}
