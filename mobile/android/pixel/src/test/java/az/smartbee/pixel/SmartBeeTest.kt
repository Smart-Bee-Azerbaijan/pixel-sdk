package az.smartbee.pixel

import android.app.Activity
import android.app.ActivityManager
import android.app.Application
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ActivityController
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowApplication
import java.io.File
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

private const val SOURCE = "demo0andr1"

/** İşçi axından çağırılan saxta nəqliyyat. */
private class RecordingTransport : Transport {
    private val posts = Collections.synchronizedList(ArrayList<JSONObject>())

    @Volatile
    var configBody = "{\"enabled\":true}"

    @Volatile
    var configCalls = 0

    /** Verilibsə konfiq sorğusu bu açılana qədər gözləyir (yavaş şəbəkə). */
    @Volatile
    var gate: CountDownLatch? = null
    val configStarted = CountDownLatch(1)

    override fun post(url: String, json: String): HttpResult {
        posts.add(JSONObject(json))
        return HttpResult(200)
    }

    override fun get(url: String, etag: String?): HttpResult {
        configCalls++
        configStarted.countDown()
        gate?.await(20, TimeUnit.SECONDS)
        return HttpResult(200, configBody)
    }

    val events: List<JSONObject>
        get() = synchronized(posts) { posts.toList() }.flatMap { p -> p.getJSONArray("events").let { a -> (0 until a.length()).map { a.getJSONObject(it) } } }
    val names: List<String> get() = events.map { if (it.getString("type") == "track") it.getString("name") else it.getString("type") }
}

class FirstActivity : Activity()

class SecondActivity : Activity()

/** Açıq API, həyat dövrü və keçidlərin Robolectric ilə başdan-başa yoxlanması. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SmartBeeTest {
    private val app: Application get() = ApplicationProvider.getApplicationContext()
    private val transport = RecordingTransport()
    private val granted = opts(consent = SmartBeeConsent(analytics = true, ads = true), debug = true)

    @Before
    fun setUp() {
        SmartBee.testShutdown()
        SmartBee.testTransport = { transport }
    }

    @After
    fun tearDown() {
        SmartBee.testShutdown()
    }

    /** Əsas axındakı gecikdirilmiş işləri və işçi axını bitirir. */
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

    private fun count(name: String): Int = sent().count { it == name }

    private fun view(url: String): Intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))

    private fun <T : Activity> ActivityController<T>.leave(): ActivityController<T> = pause().stop()

    private fun <T : Activity> ActivityController<T>.comeBack(): ActivityController<T> = restart().start().resume()

    private fun setProcessForeground() {
        val info = ActivityManager.RunningAppProcessInfo(app.packageName, android.os.Process.myPid(), arrayOf(app.packageName))
        info.importance = ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
        shadowOf(app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).setProcesses(listOf(info))
    }

    // ---- Null arqumentlər ----------------------------------------------------------------------

    @Test
    fun javaCallsWithNullArgumentsNeverThrow() {
        // init-dən əvvəl, context olmadan.
        JavaNullCalls.callEverything(null)
        JavaNullCalls.callEverything(app)
        settle()
        assertNull("null açarla SDK başlamır", SmartBee.getAnonymousId())
        assertEquals(0, transport.configCalls)

        // Null seçimlərlə başlayır; sonrakı null çağırışlar işləyən SDK-nı da sındırmır.
        JavaNullCalls.initWithNullOptions(app, SOURCE)
        JavaNullCalls.callEverything(app)
        SmartBee.track("Purchase")
        assertTrue(sent().contains("Purchase"))
        assertNotNull(SmartBee.getAnonymousId())
    }

    // ---- Başlanğıc -----------------------------------------------------------------------------

    @Test
    fun failedStartCanBeRetriedAndKeepsEarlierCalls() {
        val broken = object : ContextWrapper(app) {
            override fun getApplicationContext(): Context = this
            override fun getNoBackupFilesDir(): File = throw IllegalStateException("storage is locked")
        }
        SmartBee.track("Early")
        SmartBee.init(broken, SOURCE, granted)
        SmartBee.testAwaitIdle()
        SmartBee.track("Lead")
        settle()
        assertEquals(0, transport.configCalls)
        assertNull(SmartBee.getAnonymousId())

        SmartBee.init(app, SOURCE, granted)
        val names = sent()
        assertTrue("$names", names.containsAll(listOf("Early", "Lead")))
        assertNotNull(SmartBee.getAnonymousId())
    }

    @Test
    fun contextWithoutApplicationContextStillWorks() {
        val detached = object : ContextWrapper(app) {
            override fun getApplicationContext(): Context? = null
        }
        SmartBee.init(detached, SOURCE, granted)
        SmartBee.track("Lead")
        assertTrue(sent().contains("Lead"))
    }

    @Test
    fun sdkRunsOnlyInTheMainProcess() {
        assertTrue(Processes.isMain(app))
        val main = Application.getProcessName()
        ShadowApplication.setProcessName(app.packageName + ":push")
        try {
            assertFalse(Processes.isMain(app))
            SmartBee.init(app, SOURCE, granted)
            SmartBee.track("Lead")
            SmartBee.identify("user-1")
            settle()
            SmartBee.flush()
            settle()
            assertEquals(0, transport.configCalls)
            assertTrue(transport.names.isEmpty())
            assertNull(SmartBee.getAnonymousId())
            assertFalse(File(app.noBackupFilesDir, "smartbee_pixel.db").exists())
        } finally {
            ShadowApplication.setProcessName(main)
        }
    }

    @Test
    fun slowConfigRequestDoesNotBlockIdentityOrLoseCalls() {
        val gate = CountDownLatch(1)
        transport.gate = gate
        try {
            SmartBee.track("Early")
            SmartBee.init(app, SOURCE, granted)
            assertTrue(transport.configStarted.await(10, TimeUnit.SECONDS))
            // Konfiq sorğusu hələ cavabsızdır, amma identifikator və əvvəlki çağırışlar artıq hazırdır.
            assertNotNull(SmartBee.getAnonymousId())
            // İşçi axın məşğul olanda gözləyən adi çağırışların həddi 100-dür (bax VerificationFixesAndroidTest).
            for (i in 0 until 90) SmartBee.track("Lead", mapOf("i" to i))
        } finally {
            gate.countDown()
        }
        val names = sent()
        assertEquals(1, names.count { it == "Early" })
        assertEquals(90, names.count { it == "Lead" })
    }

    @Test
    fun propsAreCopiedAtCallTime() {
        val props = HashMap<String, Any?>()
        props["step"] = "cart"
        SmartBee.track("Step", props)
        props["step"] = "payment"
        SmartBee.track("Step", props)
        props["step"] = "done"
        props["late"] = true
        val traits = HashMap<String, Any?>(mapOf("plan" to "free"))
        SmartBee.identify("user-1", traits)
        traits["plan"] = "pro"

        SmartBee.init(app, SOURCE, granted)
        sent()
        val steps = transport.events.filter { it.optString("name") == "Step" }.map { it.getJSONObject("props") }
        assertEquals(listOf("cart", "payment"), steps.map { it.getString("step") })
        assertFalse(steps.any { it.has("late") })
        assertEquals("free", transport.events.first { it.getString("type") == "identify" }.getJSONObject("traits").getString("plan"))
    }

    // ---- Ön plan / arxa fon --------------------------------------------------------------------

    @Test
    fun rotationAndScreenChangesDoNotRepeatAppOpen() {
        SmartBee.init(app, SOURCE, granted)
        val first = Robolectric.buildActivity(FirstActivity::class.java).setup()
        assertEquals(1, count("AppOpen"))

        first.recreate()
        first.recreate()
        assertEquals(1, count("AppOpen"))

        // Növbəti ekran gec açılır (əvvəlki artıq dayanıb): qısa boşluq arxa fon sayılmır.
        first.leave()
        shadowOf(Looper.getMainLooper()).idleFor(300, TimeUnit.MILLISECONDS)
        val second = Robolectric.buildActivity(SecondActivity::class.java).setup()
        assertEquals(1, count("AppOpen"))

        // Əsl arxa fon və qayıdış.
        second.leave()
        settle()
        second.comeBack()
        assertEquals(2, count("AppOpen"))
    }

    @Test
    fun lateInitInForegroundCountsTheVisibleActivity() {
        val first = Robolectric.buildActivity(FirstActivity::class.java).setup()
        setProcessForeground()
        SmartBee.init(app, SOURCE, granted)
        assertEquals(1, count("AppOpen"))

        // Ekrandan ekrana keçid: yeni Activity başlayır, sonra əvvəlki dayanır.
        first.pause()
        val second = Robolectric.buildActivity(SecondActivity::class.java).setup()
        first.stop()
        assertEquals(1, count("AppOpen"))
        second.pause()
        first.comeBack()
        second.stop()
        assertEquals(1, count("AppOpen"))
    }

    @Test
    fun lateInitKeepsForegroundWhileTheUnseenActivityIsOnlyPaused() {
        val first = Robolectric.buildActivity(FirstActivity::class.java).setup()
        setProcessForeground()
        SmartBee.init(app, SOURCE, granted)

        // Üstündə açılıb bağlanan pəncərə (məsələn icazə dialoqu): əvvəlki Activity yalnız fasilədədir.
        first.pause()
        val dialog = Robolectric.buildActivity(SecondActivity::class.java).setup()
        dialog.pause()
        first.resume()
        dialog.stop()
        settle()

        first.pause()
        Robolectric.buildActivity(SecondActivity::class.java).setup()
        first.stop()
        assertEquals(1, count("AppOpen"))
    }

    @Test
    fun backgroundIsDetectedAfterLateInit() {
        val first = Robolectric.buildActivity(FirstActivity::class.java).setup()
        setProcessForeground()
        SmartBee.init(app, SOURCE, granted)
        assertEquals(1, count("AppOpen"))

        first.leave()
        settle()
        first.comeBack()
        assertEquals(2, count("AppOpen"))
    }

    @Test
    fun activityNameIsAutomaticScreenUntilAppNamesScreensItself() {
        SmartBee.init(app, SOURCE, granted)
        val first = Robolectric.buildActivity(FirstActivity::class.java).setup()
        SmartBee.track("Lead")
        sent()
        assertEquals("FirstActivity", transport.events.last { it.optString("name") == "Lead" }.getJSONObject("screen").getString("name"))

        SmartBee.screen("Checkout")
        first.pause().resume()
        SmartBee.track("Purchase")
        sent()
        assertEquals("Checkout", transport.events.last { it.optString("name") == "Purchase" }.getJSONObject("screen").getString("name"))
        assertEquals(2, transport.names.count { it == "ScreenView" })
    }

    // ---- Keçidlər ------------------------------------------------------------------------------

    @Test
    fun deepLinkIsCountedOncePerNewIntent() {
        SmartBee.init(app, SOURCE, granted)
        val first = Robolectric.buildActivity(FirstActivity::class.java, view("https://shop.az/p/1?utm_source=fb")).setup()
        assertEquals(1, count("DeepLinkOpen"))

        // Fırlanma və arxa fondan qayıdış eyni intent-i yenidən saymır.
        first.recreate()
        first.leave()
        settle()
        first.comeBack()
        assertEquals(1, count("DeepLinkOpen"))

        // İşləyən Activity-yə gələn keçid (onNewIntent): tətbiq ötürür, setIntent etsə də ikiqat sayılmır.
        first.leave()
        first.get().intent = view("myapp://product/2")
        SmartBee.handleDeepLink("myapp://product/2")
        first.comeBack()
        assertEquals(2, count("DeepLinkOpen"))

        // Tətbiq yalnız setIntent edibsə keçid növbəti onStart-da oxunur.
        first.leave()
        first.get().intent = view("myapp://product/3")
        first.comeBack()
        assertEquals(3, count("DeepLinkOpen"))

        val urls = transport.events.filter { it.optString("name") == "DeepLinkOpen" }.map { it.getJSONObject("props").getString("url") }
        assertEquals(listOf("https://shop.az/p/1?utm_source=fb", "myapp://product/2", "myapp://product/3"), urls)
    }

    @Test
    fun sameLinkHandedOverTwiceInARowCountsOnce() {
        SmartBee.init(app, SOURCE, granted)
        SmartBee.handleDeepLink("myapp://product/7?utm_source=fb")
        SmartBee.handleDeepLink("myapp://product/7?utm_source=fb")
        assertEquals(1, count("DeepLinkOpen"))

        // Activity-dən oxunan eyni ünvan da təkrar sayılmır, başqa ünvan isə sayılır.
        val first = Robolectric.buildActivity(FirstActivity::class.java, view("myapp://product/7?utm_source=fb")).setup()
        assertEquals(1, count("DeepLinkOpen"))
        first.leave()
        first.get().intent = view("myapp://product/8")
        first.comeBack()
        assertEquals(2, count("DeepLinkOpen"))
    }

    @Test
    fun nonLinkIntentsAreNeverReported() {
        SmartBee.init(app, SOURCE, granted)
        for (url in listOf("tel:+994501234567", "sms:+994501234567", "mailto:user@example.com", "geo:40.4,49.8", "content://contacts/people/1", "file:///sdcard/a.pdf")) {
            Robolectric.buildActivity(FirstActivity::class.java, view(url)).setup()
            SmartBee.handleDeepLink(url)
        }
        // VIEW olmayan intent-in ünvanı da keçid deyil.
        Robolectric.buildActivity(SecondActivity::class.java, Intent(Intent.ACTION_SEND, Uri.parse("https://shop.az/p/1"))).setup()
        assertEquals(0, count("DeepLinkOpen"))
        assertFalse(transport.events.joinToString().contains("994501234567"))
    }

    @Test
    fun intentOfActivityCreatedBeforeInitIsNotReportedLater() {
        val first = Robolectric.buildActivity(FirstActivity::class.java, view("https://shop.az/p/1?utm_source=fb")).setup()
        SmartBee.init(app, SOURCE, granted)
        first.leave()
        settle()
        first.comeBack()
        assertEquals(0, count("DeepLinkOpen"))

        // Gec başlayan tətbiq açılış keçidini özü ötürür.
        SmartBee.handleDeepLink(first.get().intent.dataString)
        assertEquals(1, count("DeepLinkOpen"))
    }

    @Test
    fun wrappersForwardDeepLinksThemselvesAndHaveNoActivityScreens() {
        SmartBee.init(app, SOURCE, opts(consent = SmartBeeConsent(true, true), wrapper = "flutter", wrapperVersion = "1.0.0"))
        val first = Robolectric.buildActivity(FirstActivity::class.java, view("https://shop.az/p/1")).setup()
        first.leave()
        first.get().intent = view("https://shop.az/p/2")
        first.comeBack()
        SmartBee.track("Lead")
        val names = sent()
        assertFalse("$names", names.contains("DeepLinkOpen"))
        assertFalse("$names", names.contains("ScreenView"))
        assertFalse(transport.events.last { it.optString("name") == "Lead" }.has("screen"))

        SmartBee.handleDeepLink("https://shop.az/p/2?utm_source=fb")
        assertEquals(1, count("DeepLinkOpen"))
    }
}
