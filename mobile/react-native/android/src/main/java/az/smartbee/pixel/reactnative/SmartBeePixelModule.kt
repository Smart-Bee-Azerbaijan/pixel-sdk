package az.smartbee.pixel.reactnative

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log
import az.smartbee.pixel.SmartBee
import az.smartbee.pixel.SmartBeeConsent
import az.smartbee.pixel.SmartBeeOptions
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.ReadableType
import java.lang.ref.WeakReference
import java.security.MessageDigest
import java.util.WeakHashMap

/** Forwards JavaScript calls to the native SDK. It holds no logic of its own. */
class SmartBeePixelModule(private val context: ReactApplicationContext) : ReactContextBaseJavaModule(context) {
    init {
        // A constructor must not throw either: without the observer only the restore check of the launch link is lost.
        try {
            watchActivities(context.applicationContext)
        } catch (ignored: Throwable) {
            // Best effort.
        }
    }

    override fun getName(): String = NAME

    /** A bridge failure must never crash the app: it is swallowed and, in debug mode, logged. */
    private inline fun guarded(method: String, block: () -> Unit) {
        try {
            block()
        } catch (t: Throwable) {
            report(method, t)
        }
    }

    private fun report(method: String, t: Throwable) {
        if (!debug) return
        try {
            Log.w(TAG, "React Native bridge: $method failed", t)
        } catch (ignored: Throwable) {
            // Logging is best effort.
        }
    }

    private fun ReadableMap.bool(key: String, fallback: Boolean): Boolean =
        if (hasKey(key) && getType(key) == ReadableType.Boolean) getBoolean(key) else fallback

    private fun ReadableMap.text(key: String): String? =
        if (hasKey(key) && getType(key) == ReadableType.String) getString(key) else null

    @ReactMethod
    fun start(key: String?, options: ReadableMap?) = guarded("start") {
        debug = options?.bool("debug", false) ?: false
        // Consent fails closed: a purpose that is missing or not a boolean is treated as denied, and so is a `consent`
        // value that is present but is not an object (a string, a number, a boolean, an array). Only an absent or
        // null `consent` means "not stated".
        val consent: SmartBeeConsent? = when {
            options == null || !options.hasKey("consent") -> null
            options.getType("consent") == ReadableType.Null -> null
            options.getType("consent") == ReadableType.Map -> {
                val map = options.getMap("consent")
                if (map == null) SmartBeeConsent(false, false) else SmartBeeConsent(map.bool("analytics", false), map.bool("ads", false))
            }
            else -> SmartBeeConsent(false, false)
        }
        val collectAdvertisingId = options?.bool("collectAdvertisingId", true) ?: true
        SmartBee.init(
            context.applicationContext,
            key,
            SmartBeeOptions.Builder()
                .consent(consent)
                .debug(debug)
                .autoEvents(options?.bool("autoEvents", true) ?: true)
                .endpoint(options?.text("endpoint"))
                .wrapper("react-native", options?.text("wrapperVersion"))
                .collectAdvertisingId(collectAdvertisingId)
                .build(),
        )
    }

    @ReactMethod
    fun track(name: String?, props: ReadableMap?, eventId: String?) = guarded("track") {
        SmartBee.track(name, props?.toHashMap(), eventId)
    }

    @ReactMethod
    fun identify(userId: String?, traits: ReadableMap?) = guarded("identify") {
        SmartBee.identify(userId, traits?.toHashMap())
    }

    @ReactMethod
    fun screen(name: String?, props: ReadableMap?) = guarded("screen") {
        SmartBee.screen(name, props?.toHashMap())
    }

    @ReactMethod
    fun setConsent(analytics: Boolean, ads: Boolean) = guarded("setConsent") {
        SmartBee.setConsent(SmartBeeConsent(analytics, ads))
        // Without analytics consent nothing is kept on the device, the launch-link marker included.
        if (!analytics) forgetStoredLink(context.applicationContext)
    }

    @ReactMethod
    fun reset() = guarded("reset") {
        SmartBee.reset()
    }

    @ReactMethod
    fun flush() = guarded("flush") {
        SmartBee.flush()
    }

    /** A link delivered to the running app (the `url` event of Linking) or reported by the app itself. */
    @ReactMethod
    fun handleDeepLink(url: String?) = guarded("handleDeepLink") {
        SmartBee.handleDeepLink(url)
    }

    /**
     * The launch link (`Linking.getInitialURL()`). JavaScript asks for it again after every reload, and the answer
     * stays the same for as long as the Activity lives: the same link of the same Activity is reported once.
     * An Activity reopened from the recent-apps list carries its old intent, which is not a new link either, and
     * neither is the intent of an Activity that the system recreated (a rotation, or a restore after the process was
     * killed): see [firstReport].
     */
    @ReactMethod
    fun handleInitialLink(url: String?) = guarded("handleInitialLink") {
        if (!url.isNullOrEmpty()) {
            val activity: Activity? = context.currentActivity
            val flags = activity?.intent?.flags ?: 0
            val fromHistory = flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0
            if (!fromHistory && firstReport(context.applicationContext, url, activity)) SmartBee.handleDeepLink(url)
        }
    }

    @ReactMethod
    fun getAnonymousId(promise: Promise) {
        try {
            promise.resolve(SmartBee.getAnonymousId())
        } catch (t: Throwable) {
            report("getAnonymousId", t)
            try {
                promise.resolve(null)
            } catch (ignored: Throwable) {
                // The promise was already settled.
            }
        }
    }

    companion object {
        const val NAME = "SmartBeePixel"
        private const val TAG = "SmartBee"

        /** The `debug` option of the last `start` call. */
        @Volatile
        private var debug = false

        // Process-wide on purpose: a JavaScript reload creates a new module instance, but must not report the launch link again.
        private val lock = Any()
        private var lastInitialLink: String? = null
        private var lastInitialActivity: WeakReference<Activity>? = null

        // The module is created after the first Activity, so the `savedInstanceState` of that Activity (the way the
        // native SDK recognises a restored Activity) cannot be seen from here. Two things replace it:
        //  - Activities created while the observer below is registered are remembered as new or restored;
        //  - for the Activity that existed before, the last reported launch link is kept on the device as a SHA-256
        //    of the URL together with the id of the Android task. A task id survives the death of the process and a
        //    new launch in a new task gets a new one, so "same link, same task" means the old intent of a restored
        //    Activity. The marker is written only while the SDK has analytics consent and is removed when the
        //    Activity that reported the link is finished, or JavaScript withdraws analytics consent.
        private const val PREFS = "az.smartbee.pixel.reactnative"
        private const val PREF_LINK = "initial_link_sha256"
        private const val PREF_TASK = "initial_link_task"
        private const val NO_TASK = -1

        /** Activities created while the observer was registered: `true` when created from a saved state. */
        private val seen = WeakHashMap<Activity, Boolean>()
        private var watching = false

        /** The marker of the last reported launch link that still has to be written (waiting for consent to be known). */
        private var unsavedHash: String? = null
        private var unsavedTask = NO_TASK

        private fun sha256(text: String): String? = try {
            MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
        } catch (t: Throwable) {
            null
        }

        private fun taskOf(activity: Activity?): Int = try {
            activity?.taskId ?: NO_TASK
        } catch (t: Throwable) {
            NO_TASK
        }

        /** Registers the Activity observer once per process. */
        private fun watchActivities(app: Context?) {
            val application = app as? Application ?: return
            synchronized(lock) {
                if (watching) return
                watching = true
            }
            application.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
                override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {
                    try {
                        synchronized(lock) { seen[activity] = savedInstanceState != null }
                    } catch (ignored: Throwable) {
                        // Best effort.
                    }
                }

                // Called before a background process can be killed: the last moment to write the marker.
                override fun onActivityStopped(activity: Activity) {
                    try {
                        saveMarker(activity.applicationContext)
                    } catch (ignored: Throwable) {
                        // Best effort.
                    }
                }

                override fun onActivityDestroyed(activity: Activity) {
                    try {
                        // The user left this launch for good (not a rotation): the same link later is a new launch.
                        if (!activity.isFinishing) return
                        val reporter = synchronized(lock) {
                            val mine = lastInitialActivity?.get() === activity
                            if (mine) {
                                lastInitialLink = null
                                lastInitialActivity = null
                                unsavedHash = null
                                unsavedTask = NO_TASK
                            }
                            mine
                        }
                        if (reporter) forgetStoredLink(activity.applicationContext)
                    } catch (ignored: Throwable) {
                        // Best effort.
                    }
                }

                override fun onActivityStarted(activity: Activity) {}
                override fun onActivityResumed(activity: Activity) {}
                override fun onActivityPaused(activity: Activity) {}
                override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
            })
        }

        /**
         * Writes the pending marker once the SDK is known to have analytics consent (it has an anonymous id). Until
         * then nothing is written: the SDK may still be starting, or consent may be missing. A marker written earlier
         * is removed when JavaScript withdraws analytics consent (`setConsent`).
         */
        private fun saveMarker(app: Context?) {
            if (app == null) return
            try {
                val pending = synchronized(lock) { Pair(unsavedHash, unsavedTask) }
                val hash = pending.first ?: return
                val task = pending.second
                if (SmartBee.getAnonymousId() == null) return
                val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                prefs.edit().putString(PREF_LINK, hash).putInt(PREF_TASK, task).apply()
                synchronized(lock) {
                    if (unsavedHash == hash && unsavedTask == task) {
                        unsavedHash = null
                        unsavedTask = NO_TASK
                    }
                }
            } catch (ignored: Throwable) {
                // Without the marker a restored Activity may report its launch link once more; nothing else is lost.
            }
        }

        private fun forgetStoredLink(app: Context?) {
            try {
                synchronized(lock) {
                    unsavedHash = null
                    unsavedTask = NO_TASK
                }
                val prefs = app?.getSharedPreferences(PREFS, Context.MODE_PRIVATE) ?: return
                if (prefs.contains(PREF_LINK)) prefs.edit().clear().apply()
            } catch (ignored: Throwable) {
                // Best effort.
            }
        }

        private fun storedMatches(app: Context?, hash: String, task: Int): Boolean = try {
            val prefs = app?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            prefs != null && prefs.getString(PREF_LINK, null) == hash && prefs.getInt(PREF_TASK, NO_TASK) == task
        } catch (t: Throwable) {
            false
        }

        /**
         * `true` when this launch link has not been reported yet: not for this Activity (a JavaScript reload), not
         * for an Activity the system recreated from a saved state, and not before the process was killed.
         */
        private fun firstReport(app: Context?, url: String, activity: Activity?): Boolean {
            val restored: Boolean? = synchronized(lock) {
                if (url == lastInitialLink && lastInitialActivity?.get() === activity) return false
                if (activity == null) null else seen[activity]
            }
            // Recreated in this process (a rotation, "don't keep activities"): the intent is the old one.
            if (restored == true) return false
            val hash = sha256(url)
            val task = taskOf(activity)
            // The Activity existed before the observer: it may have been restored after the process was killed.
            if (restored == null && hash != null && task != NO_TASK && storedMatches(app, hash, task)) {
                synchronized(lock) {
                    lastInitialLink = url
                    lastInitialActivity = activity?.let { WeakReference(it) }
                }
                return false
            }
            synchronized(lock) {
                lastInitialLink = url
                lastInitialActivity = activity?.let { WeakReference(it) }
                unsavedHash = hash
                unsavedTask = task
            }
            saveMarker(app)
            return true
        }
    }
}
