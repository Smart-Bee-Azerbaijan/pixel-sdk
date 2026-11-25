package az.smartbee.pixel

import android.app.Application
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File
import java.lang.reflect.Modifier
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

private const val AUDIT_KEY = "demo0andr1"

/** İşçi axından çağırılan saxta nəqliyyat: topluları bütöv saxlayır. */
private class AuditTransport : Transport {
    val batches: MutableList<JSONObject> = Collections.synchronizedList(ArrayList<JSONObject>())

    @Volatile
    var configCalls = 0

    /** Verilibsə toplu sorğusu bu açılana qədər gözləyir (yavaş şəbəkə). */
    @Volatile
    var postGate: CountDownLatch? = null
    val postStarted = CountDownLatch(1)

    override fun post(url: String, json: String): HttpResult {
        postStarted.countDown()
        postGate?.await(20, TimeUnit.SECONDS)
        batches.add(JSONObject(json))
        return HttpResult(200)
    }

    override fun get(url: String, etag: String?): HttpResult {
        configCalls++
        return HttpResult(200, "{\"enabled\":true}")
    }

    private fun snapshot(): List<JSONObject> = synchronized(batches) { batches.toList() }

    val names: List<String>
        get() = snapshot().flatMap { p -> p.getJSONArray("events").let { a -> (0 until a.length()).map { a.getJSONObject(it).optString("name") } } }

    fun ctxFor(name: String): JSONObject? = snapshot()
        .firstOrNull { p -> p.getJSONArray("events").let { a -> (0 until a.length()).any { a.getJSONObject(it).optString("name") == name } } }
        ?.getJSONObject("ctx")
}

/** Auditin Android qatına aid tapıntıları: açıq API, gözləmə siyahısı, həyat dövrü, baza. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AuditFixesAndroidTest {
    private val app: Application get() = ApplicationProvider.getApplicationContext()
    private val transport = AuditTransport()
    private val granted = opts(consent = SmartBeeConsent(analytics = true, ads = true), debug = true)

    @Before
    fun setUp() {
        SmartBee.testShutdown()
        SmartBee.testTransport = { transport }
        SmartBee.testAdIds = { null }
    }

    @After
    fun tearDown() {
        SmartBee.testShutdown()
    }

    private fun settle(millis: Long = 2_000) {
        shadowOf(Looper.getMainLooper()).idleFor(millis, TimeUnit.MILLISECONDS)
        SmartBee.testAwaitIdle()
    }

    private fun sent(): List<String> {
        settle()
        SmartBee.flush()
        SmartBee.testAwaitIdle()
        return transport.names
    }

    // ---- 4. Bazanın geri qaytarılması ------------------------------------------------------------

    @Test
    fun databaseFromANewerSdkIsRecreatedInsteadOfCrashing() {
        val file = File(app.noBackupFilesDir, "smartbee_pixel.db")
        val newer = SQLiteDatabase.openOrCreateDatabase(file, null)
        newer.execSQL("CREATE TABLE kv (k TEXT PRIMARY KEY NOT NULL, v TEXT NOT NULL, extra TEXT NOT NULL)")
        newer.execSQL("CREATE TABLE events (id INTEGER PRIMARY KEY, body BLOB)")
        newer.version = 7
        newer.close()

        val helper = PixelDatabase(app)
        val store = SqliteStore(helper)
        store.put("anon_id", "a-1")
        assertEquals("a-1", store.get("anon_id"))
        val queue = SqliteQueue(helper)
        queue.add("{}", "{\"n\":1}")
        assertEquals(1, queue.size())
        helper.close()

        // Başdan-başa: SDK belə baza ilə də başlayır və event göndərir.
        SmartBee.init(app, AUDIT_KEY, granted)
        SmartBee.track("Lead")
        assertTrue(sent().contains("Lead"))
    }

    @Test
    fun storeKeepsCacheAndDiskInSync() {
        val helper = PixelDatabase(app)
        val store = SqliteStore(helper)
        store.put("consent", "11")
        store.put("consent", "00")
        store.remove("missing")
        assertEquals("00", SqliteStore(PixelDatabase(app)).get("consent"))
        store.remove("consent")
        assertNull(SqliteStore(PixelDatabase(app)).get("consent"))

        helper.close()
    }

    // ---- 9. Gözləmə siyahısı razılığı və reset-i heç vaxt atmır ---------------------------------

    @Test
    fun consentWithdrawnBeforeInitIsNeverDropped() {
        repeat(150) { SmartBee.track("Early") }
        SmartBee.identify("user-1")
        SmartBee.setConsent(false, false)
        SmartBee.init(app, AUDIT_KEY, granted)
        assertNull(SmartBee.getAnonymousId())
        SmartBee.track("AfterDenial")
        assertTrue(sent().isEmpty())
        assertEquals("rədd ediləndə konfiq də soruşulmur", 0, transport.configCalls)
        assertNull(SmartBee.getAnonymousId())
        val store = SqliteStore(PixelDatabase(app))
        assertEquals("00", store.get(Core.K_CONSENT))
        assertNull(store.get(Core.K_ANON))
        assertNull(store.get(Core.K_USER))
    }

    @Test
    fun callsBeyondThePendingLimitAreDroppedButConsentAndResetSurvive() {
        repeat(300) { SmartBee.track("Early") }
        SmartBee.reset()
        SmartBee.setConsent(SmartBeeConsent(analytics = true, ads = false))
        SmartBee.setConsent(null)
        SmartBee.init(app, AUDIT_KEY, opts(debug = true))
        settle()
        SmartBee.track("Late")
        val names = sent()
        assertEquals(100, names.count { it == "Early" })
        assertTrue(names.contains("Late"))
        assertEquals(false, transport.ctxFor("Late")!!.getJSONObject("consent").getBoolean("ads"))
        assertEquals("10", SqliteStore(PixelDatabase(app)).get(Core.K_CONSENT))
    }

    @Test
    fun withdrawalStopsSendingWhileTheWorkerIsBusy() {
        SmartBee.init(app, AUDIT_KEY, granted)
        settle()
        SmartBee.flush()
        SmartBee.testAwaitIdle()
        val before = transport.batches.size
        // İşçi axın növbəti göndərişdə ilişir; razılıq başqa axında geri alınır.
        transport.postGate = CountDownLatch(1)
        repeat(120) { SmartBee.track("Lead") }
        SmartBee.flush()
        SmartBee.setConsent(false, false)
        assertNull("anonim ID dərhal görünməz olur", SmartBee.getAnonymousId())
        transport.postGate!!.countDown()
        settle()
        // Geri alınmadan sonra ən çox artıq yolda olan bir sorğu bitə bilər; növbənin qalanı göndərilmir.
        val after = transport.batches.size - before
        assertTrue("sent $after batches after withdrawal", after <= 1)
        assertEquals("00", SqliteStore(PixelDatabase(app)).get(Core.K_CONSENT))
        assertEquals(0, SqliteQueue(PixelDatabase(app)).size())
    }

    // ---- 12. Anonim ID açıq çağırışda dərhal yenilənir ----------------------------------------------

    @Test
    fun anonymousIdIsNewRightAfterResetAndNullRightAfterWithdrawal() {
        SmartBee.init(app, AUDIT_KEY, granted)
        settle()
        val first = SmartBee.getAnonymousId()
        assertNotNull(first)

        SmartBee.reset()
        val second = SmartBee.getAnonymousId()
        assertNotNull("yeni ID çağırışdan dərhal sonra əlçatandır", second)
        assertNotEquals(first, second)
        settle()
        assertEquals("nüvə də eyni ID-ni işlədir", second, SmartBee.getAnonymousId())
        SmartBee.track("Lead")
        sent()
        assertEquals(second, SqliteStore(PixelDatabase(app)).get(Core.K_ANON))

        SmartBee.setConsent(false, false)
        assertNull(SmartBee.getAnonymousId())
        settle()
        assertNull(SmartBee.getAnonymousId())
        SmartBee.setConsent(true, true)
        settle()
        val third = SmartBee.getAnonymousId()
        assertNotNull(third)
        assertNotEquals(second, third)
    }

    // ---- 19. Təkrar init ------------------------------------------------------------------------

    @Test
    fun repeatedInitAppliesOnlyStricterOptions() {
        SmartBee.init(app, AUDIT_KEY, granted)
        settle()
        // İkinci çağırış açarı və ünvanı dəyişmir, razılığı isə yalnız sərtləşdirir.
        SmartBee.init(app, "otherkey99", opts(consent = SmartBeeConsent(analytics = true, ads = false), endpoint = "https://evil.example.com"))
        SmartBee.track("Second")
        assertTrue(sent().contains("Second"))
        val ctx = transport.ctxFor("Second")!!
        assertFalse(ctx.getJSONObject("consent").getBoolean("ads"))
        assertTrue(transport.batches.all { it.getString("key") == AUDIT_KEY })

        // Yumşaldan seçim nəzərə alınmır.
        SmartBee.init(app, AUDIT_KEY, granted)
        SmartBee.track("Third")
        assertTrue(sent().contains("Third"))
        assertFalse(transport.ctxFor("Third")!!.getJSONObject("consent").getBoolean("ads"))

        SmartBee.init(app, AUDIT_KEY, opts(consent = SmartBeeConsent(analytics = false, ads = false)))
        assertNull(SmartBee.getAnonymousId())
        SmartBee.track("Fourth")
        assertFalse(sent().contains("Fourth"))
    }

    // ---- 18. Keçidlər ---------------------------------------------------------------------------

    @Test
    fun intentLaunchedFromHistoryIsNotADeepLink() {
        SmartBee.init(app, AUDIT_KEY, granted)
        settle()
        val recents = Intent(Intent.ACTION_VIEW, Uri.parse("https://shop.az/p/1?utm_source=fb"))
            .addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY)
        Robolectric.buildActivity(FirstActivity::class.java, recents).setup()
        assertEquals(0, sent().count { it == "DeepLinkOpen" })

        val fresh = Intent(Intent.ACTION_VIEW, Uri.parse("https://shop.az/p/2?utm_source=fb"))
        Robolectric.buildActivity(SecondActivity::class.java, fresh).setup()
        assertEquals(1, sent().count { it == "DeepLinkOpen" })
    }

    @Test
    fun overlongLinksAreIgnoredAtEveryEntryPoint() {
        SmartBee.init(app, AUDIT_KEY, granted)
        settle()
        val long = "https://shop.az/p?q=" + "a@".repeat(5000)
        SmartBee.handleDeepLink(long)
        Robolectric.buildActivity(FirstActivity::class.java, Intent(Intent.ACTION_VIEW, Uri.parse(long))).setup()
        assertEquals(0, sent().count { it == "DeepLinkOpen" })
    }

    // ---- 7. Həyat dövrü çağırışları tətbiqə istisna ötürmür -------------------------------------

    @Test
    fun lifecycleCallbacksNeverThrowIntoTheHost() {
        SmartBee.init(app, AUDIT_KEY, granted)
        settle()
        class Hostile : android.app.Activity() {
            override fun getIntent(): Intent = throw IllegalStateException("host bug")
            override fun isChangingConfigurations(): Boolean = throw IllegalStateException("host bug")
        }
        // Robolectric yerli sinfi yarada bilmir: çağırışlar birbaşa qeydiyyatdan keçmiş callback-lərə verilir.
        val field = Application::class.java.getDeclaredField("mActivityLifecycleCallbacks").apply { isAccessible = true }
        @Suppress("UNCHECKED_CAST")
        val callbacks = (field.get(app) as List<Application.ActivityLifecycleCallbacks>).toList()
        assertTrue(callbacks.isNotEmpty())
        val hostile = Hostile()
        for (callback in callbacks) {
            callback.onActivityCreated(hostile, null)
            callback.onActivityStarted(hostile)
            callback.onActivityResumed(hostile)
            callback.onActivityPaused(hostile)
            callback.onActivityStopped(hostile)
        }
        SmartBee.track("StillAlive")
        assertTrue(sent().contains("StillAlive"))
    }

    // ---- 22. Açıq səth --------------------------------------------------------------------------

    @Test
    fun testHooksAndWrapperFieldsAreNotPublic() {
        val publicMethods = SmartBee::class.java.declaredMethods.filter { Modifier.isPublic(it.modifiers) && !it.isSynthetic }.map { it.name }.toSet()
        assertEquals(
            setOf("init", "track", "identify", "screen", "setConsent", "reset", "flush", "handleDeepLink", "getAnonymousId", "getSdkVersion"),
            publicMethods,
        )
        assertTrue(SmartBee::class.java.declaredFields.filter { it.name != "INSTANCE" }.none { Modifier.isPublic(it.modifiers) })
        assertEquals(SDK_VERSION, SmartBee.sdkVersion)

        val options = SmartBeeOptions::class.java
        assertTrue("açıq konstruktor olmamalıdır", options.declaredConstructors.none { Modifier.isPublic(it.modifiers) && !it.isSynthetic })
        val getters = options.declaredMethods.filter { Modifier.isPublic(it.modifiers) && !it.isSynthetic }.map { it.name }.toSet()
        assertEquals(setOf("getConsent", "getDebug", "getAutoEvents", "getEndpoint", "getCollectAdvertisingId"), getters)
        val builder = SmartBeeOptions.Builder::class.java.declaredMethods.filter { Modifier.isPublic(it.modifiers) && !it.isSynthetic }.map { it.name }.toSet()
        assertEquals(setOf("consent", "debug", "autoEvents", "endpoint", "collectAdvertisingId", "build"), builder)

        // Kotlin DSL-i və Builder eyni nəticəni verir; örtüyün adı yalnız daxili yolla verilir və yoxlanır.
        val dsl = smartBeeOptions {
            consent(analytics = true, ads = false)
            debug(true)
            collectAdvertisingId(false)
        }
        assertEquals(SmartBeeConsent(true, false), dsl.consent)
        assertTrue(dsl.debug)
        assertFalse(dsl.collectAdvertisingId)
        assertEquals(DEFAULT_ENDPOINT, dsl.endpoint)
        assertNull(dsl.wrapper)
        assertEquals("flutter", SmartBeeOptions.Builder().wrapper("flutter", "1.0.0").build().wrapper)
        assertNull(SmartBeeOptions.Builder().wrapper("Not Valid", "1.0.0").build().wrapper)
    }

    @Test
    fun workerThreadIsADaemonNamedForDiagnostics() {
        SmartBee.init(app, AUDIT_KEY, granted)
        settle()
        val worker = Thread.getAllStackTraces().keys.firstOrNull { it.name == "smartbee-pixel" }
        assertNotNull(worker)
        assertTrue(worker!!.isDaemon)
    }
}
