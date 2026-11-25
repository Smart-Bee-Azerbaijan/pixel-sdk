package az.smartbee.pixel

import android.app.Application
import android.database.sqlite.SQLiteDatabase
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
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit

private const val VERIFY_KEY = "demo0andr1"
private const val VERIFY_LINK = "https://shop.az/p/1?utm_source=fb&fbclid=FB1"

/** İşçi axından çağırılan saxta nəqliyyat; `gate` verilibsə toplu sorğusu o açılana qədər ilişir (yavaş şəbəkə). */
private class BlockingTransport : Transport {
    val batches: MutableList<JSONObject> = Collections.synchronizedList(ArrayList<JSONObject>())

    @Volatile
    var gate: CountDownLatch? = null

    /** Hər toplu sorğusu başlayanda bir icazə buraxılır. */
    val entered = Semaphore(0)

    @Volatile
    var configBody = "{\"enabled\":true}"

    override fun post(url: String, json: String): HttpResult {
        entered.release()
        gate?.await(20, TimeUnit.SECONDS)
        batches.add(JSONObject(json))
        return HttpResult(200)
    }

    override fun get(url: String, etag: String?): HttpResult = HttpResult(200, configBody)

    val names: List<String>
        get() = synchronized(batches) { batches.toList() }
            .flatMap { p -> p.getJSONArray("events").let { a -> (0 until a.length()).map { a.getJSONObject(it).optString("name") } } }
}

/** Yoxlama auditinin Android qatına aid tapıntıları (B2, B3, B7, B8): nişan faylı, baza, işçi axının növbəsi. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class VerificationFixesAndroidTest {
    private val app: Application get() = ApplicationProvider.getApplicationContext()
    private val transport = BlockingTransport()
    private val unstated = opts(debug = true)
    private val tombFile: File get() = File(app.noBackupFilesDir, "smartbee_pixel.consent")
    private val dbFile: File get() = File(app.noBackupFilesDir, "smartbee_pixel.db")

    @Before
    fun setUp() {
        SmartBee.testShutdown()
        SmartBee.testTransport = { transport }
        SmartBee.testAdIds = { null }
    }

    @After
    fun tearDown() {
        transport.gate?.countDown()
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

    /** İşçi axını toplu sorğusunda ilişdirir və o, həqiqətən ilişənə qədər gözləyir. */
    private fun blockWorker(): CountDownLatch {
        settle()
        SmartBee.flush()
        SmartBee.testAwaitIdle()
        transport.entered.drainPermits()
        val gate = CountDownLatch(1)
        transport.gate = gate
        SmartBee.track("Blocker")
        SmartBee.flush()
        assertTrue(transport.entered.tryAcquire(10, TimeUnit.SECONDS))
        return gate
    }

    private fun stored(key: String): String? {
        val helper = PixelDatabase(app)
        try {
            return SqliteStore(helper).get(key)
        } finally {
            helper.close()
        }
    }

    // ---- B2: imtina çağıran axında diskə yazılır -------------------------------------------------

    @Test
    fun withdrawalIsWrittenToDiskInTheCallingThreadWhileTheWorkerIsBlocked() {
        SmartBee.init(app, VERIFY_KEY, unstated)
        SmartBee.setConsent(true, true)
        settle()
        assertEquals("11", stored(Core.K_CONSENT))
        assertFalse("razılıq vermək nişan yaratmır", tombFile.exists())

        val gate = blockWorker()
        SmartBee.setConsent(false, false)
        // İşçi axın hələ sorğudadır: baza köhnə razılığı saxlayır, nişan isə artıq diskdədir.
        assertEquals("1 00 1 1\n", tombFile.readText())
        // Proses indi ölsə razılığın yenidən verilməsi də itmir, aradakı silinmə də.
        SmartBee.setConsent(true, false)
        assertEquals("1 10 1 1\n", tombFile.readText())

        gate.countDown()
        settle()
        // İşçi axın hər iki çağırışı icra edib razılığı bazaya yazdı: nişan silinir.
        assertFalse(tombFile.exists())
        assertEquals("10", stored(Core.K_CONSENT))
    }

    @Test
    fun withdrawalLostByADeadProcessIsHonouredOnTheNextLaunchBeforeAnythingIsSent() {
        // Əvvəlki proses: razılıq `11`, növbədə göndərilməmiş event; `setConsent(false, false)` nişanı yazıb və
        // işçi axın onu icra etməmiş proses ölüb.
        val helper = PixelDatabase(app)
        val store = SqliteStore(helper)
        store.put(Core.K_BINDING, Core.binding(VERIFY_KEY, DEFAULT_ENDPOINT))
        store.put(Core.K_CONFIG, "{\"enabled\":true}")
        store.put(Core.K_CONSENT, "11")
        store.put(Core.K_ANON, "old-anon")
        store.put(Core.K_USER, "user-1")
        SqliteQueue(helper).add("""{"platform":"android","consent":{"analytics":true,"ads":true}}""", """{"id":"e1","type":"track","name":"Old"}""")
        helper.close()
        tombFile.writeText("1 00 1 1\n")

        SmartBee.init(app, VERIFY_KEY, unstated)
        SmartBee.track("New")
        assertTrue(sent().isEmpty())
        assertNull(SmartBee.getAnonymousId())
        assertEquals("00", stored(Core.K_CONSENT))
        assertNull(stored(Core.K_ANON))
        assertNull(stored(Core.K_USER))
        assertFalse(tombFile.exists())
        val reopened = PixelDatabase(app)
        assertEquals(0, SqliteQueue(reopened).size())
        reopened.close()
    }

    @Test
    fun withdrawalBeforeInitIsWrittenToDiskAsSoonAsInitIsCalled() {
        SmartBee.setConsent(true, false)
        assertFalse("init-dən əvvəl faylın yeri məlum deyil", tombFile.exists())
        // İşçi axın başlanğıcda ilişir (nüvə hələ qurulmayıb, gözləyən çağırışlar icra olunmayıb).
        val boot = CountDownLatch(1)
        SmartBee.testAdIds = {
            boot.await(20, TimeUnit.SECONDS)
            null
        }
        try {
            SmartBee.init(app, VERIFY_KEY, unstated)
            // `init` qayıdanda nişan artıq diskdədir, işçi axın nə ilə məşğul olursa olsun.
            assertTrue(tombFile.exists())
            assertEquals("1 10 0 1\n", tombFile.readText())
        } finally {
            boot.countDown()
        }
        settle()
        assertFalse(tombFile.exists())
        assertEquals("10", stored(Core.K_CONSENT))
    }

    // ---- B3: reklam sahələri bazadakı sətirlərdən silinir ----------------------------------------

    @Test
    fun adsWithdrawalRewritesRowsInTheDatabase() {
        val helper = PixelDatabase(app)
        val queue = SqliteQueue(helper)
        val store = SqliteStore(helper)
        val env = AndroidEnv(app)
        val posts = ArrayList<JSONObject>()
        val recording = object : Transport {
            override fun post(url: String, json: String): HttpResult {
                posts.add(JSONObject(json))
                return HttpResult(200)
            }
            override fun get(url: String, etag: String?): HttpResult = HttpResult(200, "{\"enabled\":true}")
        }
        val core = Core(VERIFY_KEY, opts(consent = SmartBeeConsent(analytics = true, ads = true), debug = true), store, queue, recording, env)
        core.start()
        core.onDeepLink(VERIFY_LINK)
        core.track("Queued", null, null)
        val before = queue.peek(100)
        assertTrue(before.any { it.ctx.contains("FB1") })
        assertTrue(before.any { it.payload.contains("FB1") })

        core.setConsent(true, false)
        // Yeni bağlantı ilə oxunur: dəyişiklik diskdədir, sətirlərin sayı, sırası və ID-ləri qalıb.
        val reopened = PixelDatabase(app)
        val after = SqliteQueue(reopened).peek(100)
        reopened.close()
        assertEquals(before.map { it.id }, after.map { it.id })
        for (row in after) {
            assertFalse(row.ctx, row.ctx.contains("FB1"))
            assertFalse(row.payload, row.payload.contains("FB1"))
            assertFalse(row.ctx, JSONObject(row.ctx).getJSONObject("consent").getBoolean("ads"))
        }
        assertTrue(after.any { it.ctx.contains("utm_source") })

        // Razılıq yenidən verilsə də köhnə sətirlər reklam razılığı ilə getmir.
        core.setConsent(true, true)
        core.flush(force = true)
        assertTrue(posts.isNotEmpty())
        for (batch in posts) {
            assertFalse(batch.toString().contains("FB1"))
            assertFalse(batch.getJSONObject("ctx").getJSONObject("consent").getBoolean("ads"))
        }
        helper.close()
    }

    // ---- B7 (a): işçi axının növbəsi məhduddur ---------------------------------------------------

    @Test
    fun callsQueuedBehindABusyWorkerAreCappedButConsentAndResetSurvive() {
        SmartBee.init(app, VERIFY_KEY, opts(consent = SmartBeeConsent(analytics = true, ads = true), debug = true))
        settle()
        val before = SmartBee.getAnonymousId()
        assertNotNull(before)

        val gate = blockWorker()
        repeat(400) { SmartBee.track("Busy") }
        SmartBee.reset()
        SmartBee.setConsent(true, false)
        gate.countDown()

        val names = sent()
        assertEquals("ilk 100 çağırış qalır, sonrakılar atılır", 100, names.count { it == "Busy" })
        assertNotEquals("reset atılmayıb", before, SmartBee.getAnonymousId())
        assertNotNull(SmartBee.getAnonymousId())
        assertEquals("razılıq çağırışı atılmayıb", "10", stored(Core.K_CONSENT))
        // Növbə boşalandan sonra yeni çağırışlar yenə qəbul olunur.
        SmartBee.track("AfterBusy")
        assertTrue(sent().contains("AfterBusy"))
    }

    // ---- B7 (b): növbənin diskdəki ölçüsü məhduddur ----------------------------------------------

    @Test
    fun diskQueueIsCappedInBytesAndDropsTheOldestRowsFirst() {
        assertEquals(5L * 1024 * 1024, SqliteQueue.MAX_QUEUE_BYTES)
        val helper = PixelDatabase(app)
        val queue = SqliteQueue(helper, maxBytes = 10_000)
        // Hər sətir 1000 simvol, amma 2000 baytdır: hədd simvolla yox, baytla sayılır.
        val text = "ə".repeat(1000)
        for (i in 0 until 30) {
            queue.add("{}", """{"n":$i,"t":"$text"}""")
            queue.trim(1000)
        }
        val rows = queue.peek(100)
        assertTrue(rows.isNotEmpty())
        assertTrue(rows.sumOf { Util.utf8Size(it.ctx) + Util.utf8Size(it.payload) } <= 10_000)
        assertEquals("ən yeni sətirlər qalır", 29, JSONObject(rows.last().payload).getInt("n"))
        assertEquals((30 - rows.size until 30).toList(), rows.map { JSONObject(it.payload).getInt("n") })
        assertEquals(4, rows.size)

        // Əvvəlki prosesdən qalmış böyük növbə də ilk yazıda həddə salınır; sətir həddi əvvəlki kimi işləyir.
        val wide = SqliteQueue(helper, maxBytes = 1_000_000)
        for (i in 30 until 60) wide.add("{}", """{"n":$i,"t":"$text"}""")
        val narrow = SqliteQueue(helper, maxBytes = 10_000)
        narrow.trim(1000)
        assertEquals(4, narrow.size())
        narrow.trim(2)
        assertEquals(listOf(58, 59), narrow.peek(10).map { JSONObject(it.payload).getInt("n") })
        helper.close()
    }

    // ---- B8: pozulmuş baza saxlanmış imtinanı unutmur --------------------------------------------

    @Test
    fun corruptDatabaseDoesNotSilentlyForgetAStoredRefusal() {
        val helper = PixelDatabase(app)
        SqliteStore(helper).put(Core.K_CONSENT, "00")
        helper.close()
        // Baza faylı pozulur (oxunmur). Susmaya görə Android onu silib boş baza yaradardı: imtina itərdi.
        for (suffix in listOf("-wal", "-shm", "-journal")) File(dbFile.path + suffix).delete()
        dbFile.writeBytes(ByteArray(8192) { 0x5A })
        transport.configBody = """{"enabled":true,"consent_default":{"analytics":true,"ads":true}}"""

        SmartBee.init(app, VERIFY_KEY, unstated)
        SmartBee.track("AfterCorruption")
        assertTrue("razılıq «bildirilməyib» sayılmır: heç nə göndərilmir", sent().isEmpty())
        assertNull(SmartBee.getAnonymousId())
        assertEquals(ConsentTombstone.CORRUPT, stored(Core.K_CONSENT))
        assertFalse(tombFile.exists())

        // Növbəti açılışda da (yeni baza artıq sağlamdır) rədd qüvvədədir.
        SmartBee.testShutdown()
        SmartBee.testTransport = { transport }
        SmartBee.testAdIds = { null }
        SmartBee.init(app, VERIFY_KEY, unstated)
        SmartBee.track("NextLaunch")
        assertTrue(sent().isEmpty())

        // Yalnız yenidən bildirilən razılıq onu əvəz edir.
        SmartBee.setConsent(true, true)
        SmartBee.track("AfterRestating")
        assertTrue(sent().contains("AfterRestating"))
        assertEquals("11", stored(Core.K_CONSENT))
    }

    @Test
    fun databaseDowngradeKeepsTheStoredConsent() {
        // Oxuna bilən daha yeni sxem: razılıq yeni cədvələ köçürülür.
        var newer = SQLiteDatabase.openOrCreateDatabase(dbFile, null)
        newer.execSQL("CREATE TABLE kv (k TEXT PRIMARY KEY NOT NULL, v TEXT NOT NULL, extra TEXT)")
        newer.execSQL("INSERT INTO kv (k, v) VALUES ('consent', '00')")
        newer.execSQL("INSERT INTO kv (k, v) VALUES ('anon_id', 'from-the-future')")
        newer.execSQL("CREATE TABLE events (id INTEGER PRIMARY KEY, body BLOB)")
        newer.version = 7
        newer.close()
        assertEquals("00", stored(Core.K_CONSENT))
        assertNull(stored(Core.K_ANON))

        // Oxunmayan sxem: razılıq «oxunmur» (rədd) kimi qeyd olunur, «bildirilməyib» kimi yox.
        SQLiteDatabase.deleteDatabase(dbFile)
        newer = SQLiteDatabase.openOrCreateDatabase(dbFile, null)
        newer.execSQL("CREATE TABLE kv (name TEXT PRIMARY KEY NOT NULL, data BLOB)")
        newer.version = 7
        newer.close()
        assertEquals(ConsentTombstone.CORRUPT, stored(Core.K_CONSENT))

        // Cədvəl oxunur, amma razılıq heç vaxt bildirilməyib: belə də qalır.
        SQLiteDatabase.deleteDatabase(dbFile)
        newer = SQLiteDatabase.openOrCreateDatabase(dbFile, null)
        newer.execSQL("CREATE TABLE kv (k TEXT PRIMARY KEY NOT NULL, v TEXT NOT NULL)")
        newer.version = 7
        newer.close()
        assertNull(stored(Core.K_CONSENT))
    }
}
