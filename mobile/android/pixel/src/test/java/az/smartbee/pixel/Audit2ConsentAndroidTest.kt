package az.smartbee.pixel

import android.app.Application
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

private const val AUDIT2_KEY = "demo0andr1"

/** Toplu sorğusunu `gate` açılana qədər saxlaya bilən saxta nəqliyyat (yavaş şəbəkə). */
private class SlowTransport : Transport {
    private val posts = Collections.synchronizedList(ArrayList<JSONObject>())

    @Volatile
    var gate: CountDownLatch? = null

    @Volatile
    var started: CountDownLatch? = null

    override fun post(url: String, json: String): HttpResult {
        started?.countDown()
        gate?.await(20, TimeUnit.SECONDS)
        posts.add(JSONObject(json))
        return HttpResult(200)
    }

    override fun get(url: String, etag: String?): HttpResult = HttpResult(200, "{\"enabled\":true}")

    val events: List<JSONObject>
        get() = synchronized(posts) { posts.toList() }.flatMap { p -> p.getJSONArray("events").let { a -> (0 until a.length()).map { a.getJSONObject(it) } } }
    val names: List<String> get() = events.map { if (it.getString("type") == "track") it.getString("name") else it.getString("type") }
}

/** İkinci auditin Android qatına aid tapıntıları: atomik nişan faylı (C3) və məşğul növbənin həddi (C6). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class Audit2ConsentAndroidTest {
    private val app: Application get() = ApplicationProvider.getApplicationContext()
    private val transport = SlowTransport()
    private val granted = opts(consent = SmartBeeConsent(analytics = true, ads = true), debug = true)
    private val markFile: File get() = File(app.noBackupFilesDir, "smartbee_pixel.consent")

    @Before
    fun setUp() {
        SmartBee.testShutdown()
        SmartBee.testTransport = { transport }
        markFile.delete()
    }

    @After
    fun tearDown() {
        transport.gate?.countDown()
        SmartBee.testShutdown()
        markFile.delete()
    }

    private fun settle(millis: Long = 2_000) {
        shadowOf(Looper.getMainLooper()).idleFor(millis, TimeUnit.MILLISECONDS)
        SmartBee.testAwaitIdle()
    }

    // ---- C3 ------------------------------------------------------------------------------------

    @Test
    fun c3_consentFileIsReplacedAtomicallyAndLeavesNoTempFile() {
        val file = ConsentFile(app)
        assertNull(file.read())
        file.write("1 00 1 1\n")
        assertEquals("1 00 1 1\n", file.read())
        // İkinci yazı mövcud faylı bütöv əvəz edir.
        file.write("1 10 1 1\n")
        assertEquals("1 10 1 1\n", file.read())
        assertEquals("1 10 1 1\n", markFile.readText())
        assertFalse(File(markFile.path + ".tmp").exists())
        file.delete()
        assertNull(file.read())
    }

    @Test
    fun c3_interruptedWriteLeavesThePreviousMarkIntact() {
        val file = ConsentFile(app)
        file.write("1 00 1 1\n")
        // Proses müvəqqəti faylı yazarkən ölüb: yarımçıq mətn yalnız `.tmp`-dədir, nişanın özü köhnə halındadır.
        File(markFile.path + ".tmp").writeText("1 1")
        assertEquals("1 00 1 1\n", file.read())
        assertEquals("00", ConsentTombstone.parse(file.read()!!).consent)
        // Növbəti yazı qalıq müvəqqəti faylın üstündən keçir.
        file.write("1 11 0 0\n")
        assertEquals("1 11 0 0\n", file.read())
        assertFalse(File(markFile.path + ".tmp").exists())
    }

    @Test
    fun c3_emptyMarkFileOnDiskKeepsAStoredRefusalAgainstInitConsent() {
        // Əvvəlki açılış: istifadəçi hər iki məqsədi rədd edib.
        SmartBee.init(app, AUDIT2_KEY, granted)
        settle()
        SmartBee.setConsent(false, false)
        settle()
        SmartBee.testShutdown()
        SmartBee.testTransport = { transport }
        // Nişan faylı boş qalıb (köhnə versiyanın yarımçıq yazısı); tətbiq `init`-də razılıq verir.
        markFile.writeText("")
        SmartBee.init(app, AUDIT2_KEY, granted)
        settle()
        SmartBee.track("AfterTorn")
        SmartBee.flush()
        settle()
        assertNull(SmartBee.getAnonymousId())
        assertTrue(transport.names.none { it == "AfterTorn" })
        assertFalse(markFile.exists())
    }

    // ---- C6 ------------------------------------------------------------------------------------

    @Test
    fun c6_busyQueueDropsTheOldestTrackCallsAndNeverIdentifyOrConsent() {
        SmartBee.init(app, AUDIT2_KEY, granted)
        settle()
        SmartBee.flush()
        settle()
        // İşçi axın yavaş sorğuda ilişir.
        val gate = CountDownLatch(1)
        val started = CountDownLatch(1)
        transport.gate = gate
        transport.started = started
        SmartBee.track("Blocker")
        SmartBee.flush()
        assertTrue(started.await(10, TimeUnit.SECONDS))

        SmartBee.identify("user-early")
        for (i in 0 until 150) SmartBee.track("T$i")
        SmartBee.identify("user-late")
        SmartBee.screen("Checkout")
        SmartBee.handleDeepLink("https://shop.az/p/1?utm_source=fb")
        SmartBee.flush()

        transport.gate = null
        gate.countDown()
        settle()
        SmartBee.flush()
        settle()

        val names = transport.names
        val tracked = names.filter { it.startsWith("T") && it.drop(1).all(Char::isDigit) }
        // `track` / `screen`-dən ən çoxu 100-ü gözləyir: `Checkout` da sayılır, ona görə ən köhnə 51 `track` atılıb.
        assertEquals((51 until 150).map { "T$it" }, tracked)
        assertTrue(names.contains("ScreenView"))
        assertTrue(names.contains("DeepLinkOpen"))
        assertEquals(2, names.count { it == "identify" })
        // Sıra dəyişmir: birinci identify bütün qalan `track`-lərdən əvvəl, ikincisi sonra icra olunub.
        assertTrue(names.indexOf("identify") < names.indexOf("T51"))
        assertTrue(names.lastIndexOf("identify") > names.indexOf("T149"))
        val users = transport.events.filter { it.getString("type") == "identify" }.map { it.getString("user_id") }
        assertEquals(listOf("user-early", "user-late"), users)
    }

    @Test
    fun c6_consentWithdrawalBehindAFullBusyQueueIsExecuted() {
        SmartBee.init(app, AUDIT2_KEY, granted)
        settle()
        SmartBee.flush()
        settle()
        val gate = CountDownLatch(1)
        val started = CountDownLatch(1)
        transport.gate = gate
        transport.started = started
        SmartBee.track("Blocker")
        SmartBee.flush()
        assertTrue(started.await(10, TimeUnit.SECONDS))
        for (i in 0 until 300) SmartBee.track("T$i")
        SmartBee.setConsent(false, false)
        assertNull(SmartBee.getAnonymousId())
        transport.gate = null
        gate.countDown()
        settle()
        SmartBee.flush()
        settle()
        // İmtinadan əvvəl gözləyən çağırışların heç biri göndərilmir və SDK razılıqsız vəziyyətdə qalır.
        assertTrue(transport.names.none { it.startsWith("T") && it.drop(1).all(Char::isDigit) })
        assertNull(SmartBee.getAnonymousId())
    }
}
