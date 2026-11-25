package az.smartbee.pixel.flutter

import android.content.Context
import android.util.Log
import az.smartbee.pixel.SmartBee
import az.smartbee.pixel.SmartBeeConsent
import az.smartbee.pixel.SmartBeeOptions
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Forwards Dart calls to the native SDK. It holds no logic of its own. */
class SmartBeePixelPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null

    /** The `debug` option of the last `start` call. */
    @Volatile
    private var debug = false

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

    private fun MethodCall.text(key: String): String? = argument<Any?>(key) as? String

    private fun MethodCall.bool(key: String, fallback: Boolean): Boolean = argument<Any?>(key) as? Boolean ?: fallback

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                // Answers `true` when the native SDK was asked to start, `false` when the call could not be made.
                "start" -> {
                    val app = context
                    val key = call.text("key")
                    if (app != null && key != null) {
                        debug = call.bool("debug", false)
                        // Consent fails closed: a purpose that is missing or not a boolean is treated as denied, and so
                        // is a `consent` value that is present but is not a map (a string, a number, a boolean, a list).
                        // Only an absent or null `consent` means "not stated".
                        val rawConsent = call.argument<Any?>("consent")
                        val consent: SmartBeeConsent? = when (rawConsent) {
                            null -> null
                            is Map<*, *> -> SmartBeeConsent(rawConsent["analytics"] as? Boolean ?: false, rawConsent["ads"] as? Boolean ?: false)
                            else -> SmartBeeConsent(false, false)
                        }
                        SmartBee.init(
                            app,
                            key,
                            SmartBeeOptions.Builder()
                                .consent(consent)
                                .debug(debug)
                                .autoEvents(call.bool("autoEvents", true))
                                .endpoint(call.text("endpoint"))
                                .wrapper("flutter", call.text("wrapperVersion"))
                                .collectAdvertisingId(call.bool("collectAdvertisingId", true))
                                .build(),
                        )
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "track" -> {
                    call.text("name")?.let { SmartBee.track(it, call.map("props"), call.text("eventId")) }
                    result.success(null)
                }
                "identify" -> {
                    call.text("userId")?.let { SmartBee.identify(it, call.map("traits")) }
                    result.success(null)
                }
                "screen" -> {
                    call.text("name")?.let { SmartBee.screen(it, call.map("props")) }
                    result.success(null)
                }
                // Consent fails closed here too: a missing purpose is treated as denied.
                "setConsent" -> {
                    SmartBee.setConsent(SmartBeeConsent(call.bool("analytics", false), call.bool("ads", false)))
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
                // In a wrapper the native SDK does not read the Activity intent: the Dart side forwards the link.
                "handleDeepLink" -> {
                    SmartBee.handleDeepLink(call.text("url"))
                    result.success(null)
                }
                "getAnonymousId" -> result.success(SmartBee.getAnonymousId())
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            // A bridge failure must never crash the app: it is swallowed and, in debug mode, logged.
            if (debug) {
                try {
                    Log.w("SmartBee", "Flutter plugin: ${call.method} failed", t)
                } catch (ignored: Throwable) {
                    // Logging is best effort.
                }
            }
            try {
                result.success(if (call.method == "start") false else null)
            } catch (ignored: Throwable) {
                // The result was already sent.
            }
        }
    }
}
