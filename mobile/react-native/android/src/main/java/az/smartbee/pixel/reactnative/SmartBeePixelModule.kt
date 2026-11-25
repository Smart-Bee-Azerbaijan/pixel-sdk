package az.smartbee.pixel.reactnative

import az.smartbee.pixel.Consent
import az.smartbee.pixel.SmartBee
import az.smartbee.pixel.SmartBeeOptions
import com.facebook.react.ReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.uimanager.ViewManager

/** JS çağırışlarını nativ SDK-ya ötürür. Öz məntiqi yoxdur. */
class SmartBeePixelModule(private val context: ReactApplicationContext) : ReactContextBaseJavaModule(context) {
    override fun getName(): String = "SmartBeePixel"

    private fun ReadableMap.bool(key: String, fallback: Boolean): Boolean =
        if (hasKey(key) && !isNull(key)) getBoolean(key) else fallback

    private fun ReadableMap.text(key: String): String? =
        if (hasKey(key) && !isNull(key)) getString(key) else null

    @ReactMethod
    fun start(key: String, options: ReadableMap?) {
        try {
            val consentMap = options?.takeIf { it.hasKey("consent") && !it.isNull("consent") }?.getMap("consent")
            val consent = consentMap?.let { Consent(it.bool("analytics", true), it.bool("ads", true)) }
            val defaults = SmartBeeOptions()
            SmartBee.init(
                context.applicationContext,
                key,
                SmartBeeOptions(
                    consent = consent,
                    debug = options?.bool("debug", false) ?: false,
                    autoEvents = options?.bool("autoEvents", true) ?: true,
                    endpoint = options?.text("endpoint") ?: defaults.endpoint,
                    wrapper = "react-native",
                    wrapperVersion = options?.text("wrapperVersion"),
                ),
            )
        } catch (t: Throwable) {
            // Körpü xətası tətbiqi sındırmamalıdır.
        }
    }

    @ReactMethod
    fun track(name: String, props: ReadableMap?, eventId: String?) {
        try {
            SmartBee.track(name, props?.toHashMap(), eventId)
        } catch (t: Throwable) {
        }
    }

    @ReactMethod
    fun identify(userId: String, traits: ReadableMap?) {
        try {
            SmartBee.identify(userId, traits?.toHashMap())
        } catch (t: Throwable) {
        }
    }

    @ReactMethod
    fun screen(name: String, props: ReadableMap?) {
        try {
            SmartBee.screen(name, props?.toHashMap())
        } catch (t: Throwable) {
        }
    }

    @ReactMethod
    fun setConsent(analytics: Boolean, ads: Boolean) = SmartBee.setConsent(analytics, ads)

    @ReactMethod
    fun reset() = SmartBee.reset()

    @ReactMethod
    fun flush() = SmartBee.flush()

    @ReactMethod
    fun getAnonymousId(promise: Promise) {
        promise.resolve(SmartBee.getAnonymousId())
    }
}

class SmartBeePixelPackage : ReactPackage {
    override fun createNativeModules(context: ReactApplicationContext): List<NativeModule> = listOf(SmartBeePixelModule(context))

    override fun createViewManagers(context: ReactApplicationContext): List<ViewManager<*, *>> = emptyList()
}
