package az.smartbee.pixel

import android.app.Application
import android.content.pm.PackageManager
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import com.google.android.gms.ads.identifier.AdvertisingIdClient
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.lang.reflect.InvocationTargetException
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

private const val SOURCE_KEY = "demo0andr1"
private const val DEVICE_GAID = "38400000-8cf0-11bd-b23e-10b96e40000d"

/**
 * Reklam ID-sinin Android qatı: Google sinfinin refleksiya ilə çağırılması və oxumanın getdiyi axın.
 * `com.google.android.gms.ads.identifier.AdvertisingIdClient` burada test mənbəyindəki əvəzdir.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AdvertisingIdAndroidTest {
    private class Posts : Transport {
        val bodies: MutableList<String> = Collections.synchronizedList(ArrayList<String>())

        override fun post(url: String, json: String): HttpResult {
            bodies.add(json)
            return HttpResult(200)
        }

        override fun get(url: String, etag: String?): HttpResult = HttpResult(200, "{\"enabled\":true}")

        fun snapshot(): List<JSONObject> = synchronized(bodies) { bodies.toList() }.map { JSONObject(it) }

        fun names(): List<String> = snapshot().flatMap { p ->
            p.getJSONArray("events").let { a -> (0 until a.length()).map { a.getJSONObject(it).optString("name") } }
        }
    }

    private val app: Application get() = ApplicationProvider.getApplicationContext()
    private val transport = Posts()
    private val granted = opts(consent = SmartBeeConsent(analytics = true, ads = true), debug = true)

    @Before
    fun setUp() {
        SmartBee.testShutdown()
        SmartBee.testTransport = { transport }
        AdvertisingIdClient.next = null
        AdvertisingIdClient.lastThread = null
    }

    @After
    fun tearDown() {
        SmartBee.testShutdown()
        AdvertisingIdClient.next = null
        AdvertisingIdClient.lastThread = null
    }

    /** Event göndərib işçi axının boşalmasını gözləyir; göndərilən son toplunu qaytarır. */
    private fun send(name: String): JSONObject {
        SmartBee.track(name)
        SmartBee.flush()
        SmartBee.testAwaitIdle()
        return transport.snapshot().last { it.toString().contains("\"$name\"") }
    }

    private fun gaidOf(batch: JSONObject): String? = batch.getJSONObject("ctx").optJSONObject("ids")?.optString("gaid")

    /** Oxuma başqa axında gedir: GAID-li ilk toplu görünənə qədər (ən çox 10 s) event göndərir. */
    private fun awaitGaid(): String? {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        while (System.nanoTime() < deadline) {
            gaidOf(send("Probe"))?.let { return it }
            Thread.sleep(20)
        }
        return null
    }

    // ---- Refleksiya -----------------------------------------------------------------------------

    @Test
    fun playAdIdReadsTheGoogleClientByReflection() {
        AdvertisingIdClient.next = AdvertisingIdClient.Info(DEVICE_GAID, false)
        val info = PlayAdId(app).read()!!
        assertEquals(DEVICE_GAID, info.id)
        assertFalse(info.limitAdTracking)
        assertEquals(DEVICE_GAID, Util.adId(info))

        AdvertisingIdClient.next = AdvertisingIdClient.Info(DEVICE_GAID, true)
        val limited = PlayAdId(app).read()!!
        assertTrue(limited.limitAdTracking)
        assertNull(Util.adId(limited))

        AdvertisingIdClient.next = AdvertisingIdClient.Info(null, false)
        assertNull(Util.adId(PlayAdId(app).read()))
    }

    @Test
    fun playAdIdFailureSurfacesAsAnExceptionThatTheCoreSwallows() {
        // Play xidmətləri yoxdur: Google sinfi istisna atır.
        try {
            PlayAdId(app).read()
            throw AssertionError("istisna gözlənilirdi")
        } catch (e: InvocationTargetException) {
            assertTrue(e.cause is java.io.IOException)
        }

        AdvertisingIdClient.lastThread = null
        SmartBee.init(app, SOURCE_KEY, granted)
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        while (AdvertisingIdClient.lastThread == null && System.nanoTime() < deadline) Thread.sleep(10)
        assertNotNull("oxuma cəhdi olmalıdır", AdvertisingIdClient.lastThread)
        send("Warmup")
        val batch = send("Lead")
        assertFalse(batch.getJSONObject("ctx").has("ids"))
        assertNotNull(SmartBee.getAnonymousId())
    }

    @Test
    fun libraryManifestRequestsTheAdIdPermission() {
        val info = app.packageManager.getPackageInfo(app.packageName, PackageManager.GET_PERMISSIONS)
        val permissions = info.requestedPermissions?.toList().orEmpty()
        assertTrue("$permissions", permissions.contains("com.google.android.gms.permission.AD_ID"))
    }

    // ---- Axın -----------------------------------------------------------------------------------

    @Test
    fun lookupNeverRunsOnTheCallingOrMainThread() {
        AdvertisingIdClient.next = AdvertisingIdClient.Info(DEVICE_GAID, false)
        SmartBee.init(app, SOURCE_KEY, granted)
        assertEquals(DEVICE_GAID, awaitGaid())

        val thread = AdvertisingIdClient.lastThread!!
        assertNotSame(Thread.currentThread(), thread)
        assertNotSame(Looper.getMainLooper().thread, thread)
        assertEquals("smartbee-pixel-io", thread.name)
        assertTrue(thread.isDaemon)
    }

    @Test
    fun slowLookupDoesNotBlockInitTrackingOrFlushing() {
        val started = CountDownLatch(1)
        val gate = CountDownLatch(1)
        val threads = Collections.synchronizedList(ArrayList<Thread>())
        SmartBee.testAdIds = {
            AdIdLookup {
                threads.add(Thread.currentThread())
                started.countDown()
                gate.await(30, TimeUnit.SECONDS)
                AdInfo(DEVICE_GAID, false)
            }
        }
        try {
            SmartBee.init(app, SOURCE_KEY, granted)
            assertTrue("oxuma başlamalıdır", started.await(10, TimeUnit.SECONDS))

            // Oxuma hələ gözləyir: çağırışlar dərhal qayıdır, eventlər GAID-siz göndərilir.
            val batch = send("Lead")
            assertEquals(1L, gate.count)
            assertNull(gaidOf(batch))
            assertNotNull(SmartBee.getAnonymousId())
            SmartBee.setConsent(true, true)
            assertNull(gaidOf(send("Again")))
            assertEquals(1, threads.size)
        } finally {
            gate.countDown()
        }
        assertEquals(DEVICE_GAID, awaitGaid())
        assertEquals(1, threads.size)
        assertNotSame(Thread.currentThread(), threads[0])
    }

    // ---- Razılıq və seçim (başdan-başa) ---------------------------------------------------------

    @Test
    fun gaidStopsAfterConsentWithdrawal() {
        AdvertisingIdClient.next = AdvertisingIdClient.Info(DEVICE_GAID, false)
        SmartBee.init(app, SOURCE_KEY, granted)
        assertEquals(DEVICE_GAID, awaitGaid())

        SmartBee.track("Queued")
        SmartBee.setConsent(true, false)
        SmartBee.testAwaitIdle()
        val before = transport.bodies.size
        send("After")
        val later = synchronized(transport.bodies) { transport.bodies.drop(before) }
        assertTrue(later.any { it.contains("\"Queued\"") })
        for (body in later) assertFalse(body, body.contains(DEVICE_GAID) || body.contains("gaid"))
    }

    @Test
    fun optionTurnsCollectionOffForAppsAndWrappers() {
        AdvertisingIdClient.next = AdvertisingIdClient.Info(DEVICE_GAID, false)
        val variants = listOf(
            opts(consent = SmartBeeConsent(true, true), collectAdvertisingId = false),
            opts(consent = SmartBeeConsent(true, true), wrapper = "react-native", wrapperVersion = "1.0.0", collectAdvertisingId = false),
            // Reklam razılığı yoxdur: seçim açıq olsa da oxunmur.
            opts(consent = SmartBeeConsent(true, false)),
        )
        for (options in variants) {
            SmartBee.testShutdown()
            SmartBee.testTransport = { transport }
            SmartBee.init(app, SOURCE_KEY, options)
            send("Lead")
            send("Lead")
            assertNull("Google sinfi çağırılmamalıdır", AdvertisingIdClient.lastThread)
        }
        assertTrue(transport.names().contains("Lead"))
        for (body in transport.bodies) assertFalse(body, body.contains("gaid"))
    }

    @Test
    fun wrappersCollectTheGaidLikeNativeApps() {
        AdvertisingIdClient.next = AdvertisingIdClient.Info(DEVICE_GAID, false)
        SmartBee.init(app, SOURCE_KEY, opts(consent = SmartBeeConsent(true, true), wrapper = "flutter", wrapperVersion = "1.0.0"))
        assertEquals(DEVICE_GAID, awaitGaid())
        assertEquals("flutter", transport.snapshot().last().getJSONObject("sdk").getString("wrapper"))
        assertEquals("smartbee-pixel-io", AdvertisingIdClient.lastThread!!.name)
    }
}
