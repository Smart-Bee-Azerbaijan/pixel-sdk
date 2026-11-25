package az.smartbee.pixel

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private const val CLICK_LINK = "https://shop.az/p/1?utm_source=fb&utm_campaign=spring&fbclid=FB1&gclid=G1"

/** Diskə yazılan hər dəyəri yadda saxlayan yaddaş: «diskə heç vaxt düşməyib» iddiasını yoxlamaq üçün. */
private class RecordingStore : Store {
    val map = HashMap<String, String>()
    val written = ArrayList<String>()
    override fun get(key: String): String? = map[key]
    override fun put(key: String, value: String) {
        map[key] = value
        written.add(value)
    }
    override fun remove(key: String) { map.remove(key) }
}

/**
 * Yoxlama auditinin tapıntıları (B2, B3, B5, B7, B8): imtinanın prosesin ölümünə davam gətirməsi, reklam sahələrinin
 * diskdən silinməsi, rədd cavablarının protokol cədvəli, pozulmuş yaddaş və konfiq. Test adları iOS-da (XCTest)
 * təkrarlanır.
 */
class VerificationFixesTest {
    private val granted = opts(consent = SmartBeeConsent(analytics = true, ads = true), debug = true)

    /** Növbəsində göndərilməmiş eventlər və saxlanmış `11` razılığı olan tətbiq (əvvəlki proses). */
    private fun rigWithQueue(): Rig {
        val rig = Rig(opts(debug = true))
        rig.store.map[Core.K_CONSENT] = "11"
        rig.transport.status = 500
        val core = rig.core()
        core.onDeepLink(CLICK_LINK)
        core.identify("user-1", null)
        core.track("Old", null, null)
        core.flush(force = true)
        assertTrue(rig.queue.size() > 0)
        assertNotNull(rig.store.map[Core.K_ANON])
        rig.transport.status = 200
        rig.transport.bodies.clear()
        rig.transport.posts.clear()
        rig.env.time += 2 * Core.BACKOFF_MAX_MS
        return rig
    }

    /** Çağıran axının yazdığı nişan; proses ölür, yəni yaddaşdakı vəziyyət itir və yalnız fayl qalır. */
    private fun tombstoneLeftBy(file: FakeTombFile, calls: (ConsentTombstone) -> Unit): ConsentTombstone {
        val dying = ConsentTombstone()
        dying.attach(file)
        calls(dying)
        return ConsentTombstone().also { it.attach(file) }
    }

    private fun assertNoClickIds(text: String) {
        for (id in Util.CLICK_IDS) assertFalse("$id: $text", text.contains(id))
        assertFalse(text, text.contains("FB1"))
        assertFalse(text, text.contains("G1\""))
    }

    private fun assertRowsHaveNoAdsData(rig: Rig) {
        assertTrue(rig.queue.rows.isNotEmpty())
        for (row in rig.queue.rows) {
            val ctx = JSONObject(row.ctx)
            assertFalse(row.ctx, ctx.has("ids"))
            assertFalse(row.ctx, ctx.getJSONObject("consent").getBoolean("ads"))
            assertNoClickIds(row.ctx)
            if (row.payload.contains("DeepLinkOpen")) assertNoClickIds(row.payload)
        }
    }

    // ---- B2: imtina prosesin ölümünə davam gətirir ------------------------------------------------

    @Test
    fun withdrawalTombstoneFromADeadProcessErasesQueueAndIdentifiersBeforeAnythingIsSent() {
        val rig = rigWithQueue()
        val oldAnon = rig.store.map[Core.K_ANON]
        val file = FakeTombFile()
        // `setConsent(false, false)` çağıran axında nişanı yazıb; işçi axın onu bazaya yazmamış proses ölüb.
        rig.tombstone = tombstoneLeftBy(file) { assertTrue(it.record("00", erase = true, scrub = true)) }
        assertEquals("1 00 1 1\n", file.text)
        assertEquals("11", rig.store.map[Core.K_CONSENT])

        val core = rig.core()
        core.onForeground()
        core.track("New", null, null)
        core.flush(force = true)

        assertEquals(0, rig.transport.bodies.size)
        assertEquals("rədd ediləndə konfiq də soruşulmur", 0, rig.transport.configCalls)
        assertEquals(0, rig.queue.size())
        assertEquals("00", rig.store.map[Core.K_CONSENT])
        for (k in listOf(Core.K_ANON, Core.K_USER, Core.K_SESSION, Core.K_SEQ, Core.K_CAMPAIGN)) assertNull(k, rig.store.map[k])
        assertNull(core.anonymousId)
        assertNotEquals(oldAnon, rig.store.map[Core.K_ANON])
        assertNull("nişan icra olunandan sonra silinir", file.text)
    }

    @Test
    fun adsWithdrawalTombstoneFromADeadProcessForcesAdsOffAndScrubsTheQueue() {
        val rig = rigWithQueue()
        assertTrue(rig.queue.rows.any { it.ctx.contains("FB1") })
        val file = FakeTombFile()
        rig.tombstone = tombstoneLeftBy(file) { assertTrue(it.record("10", erase = false, scrub = true)) }

        val core = rig.core()
        assertEquals("10", rig.store.map[Core.K_CONSENT])
        assertRowsHaveNoAdsData(rig)
        assertNoClickIds(rig.store.map[Core.K_CAMPAIGN].orEmpty())
        assertNull(file.text)

        core.flush(force = true)
        assertTrue(rig.transport.names.contains("Old"))
        for (body in rig.transport.bodies) {
            assertNoClickIds(body)
            assertFalse(JSONObject(body).getJSONObject("ctx").getJSONObject("consent").getBoolean("ads"))
        }
    }

    @Test
    fun regrantAfterWithdrawalIsNotUndoneByAStaleTombstone() {
        // 1) İşçi axın imtinanı bazaya yazıb: nişan silinir, sonrakı razılıq nişansız saxlanır.
        val file = FakeTombFile()
        val tombstone = ConsentTombstone()
        tombstone.attach(file)
        assertTrue(tombstone.record("00", erase = true, scrub = true))
        assertNotNull(file.text)
        tombstone.done(persisted = true)
        assertNull(file.text)
        assertFalse("sırf razılıq nişan tələb etmir", tombstone.record("11", erase = false, scrub = false))
        assertNull(file.text)

        // 2) Hər iki çağırış işçi axını gözləyərkən proses ölüb: silinmə itmir, saxlanan razılıq isə sonuncudur.
        val rig = rigWithQueue()
        val oldAnon = rig.store.map[Core.K_ANON]
        val left = FakeTombFile()
        rig.tombstone = tombstoneLeftBy(left) {
            assertTrue(it.record("00", erase = true, scrub = true))
            assertTrue(it.record("11", erase = false, scrub = false))
        }
        assertEquals("1 11 1 1\n", left.text)
        val core = rig.core()
        assertEquals("11", rig.store.map[Core.K_CONSENT])
        assertEquals("köhnə növbə silinib", 0, rig.queue.rows.count { it.payload.contains("\"Old\"") })
        assertNotNull(core.anonymousId)
        assertNotEquals(oldAnon, core.anonymousId)
        assertNull(left.text)
        core.track("AfterRegrant", null, null)
        core.flush(force = true)
        assertTrue(rig.transport.names.contains("AfterRegrant"))
        assertFalse(rig.transport.names.contains("Old"))

        // 3) Növbəti açılışda nişan yoxdur: razılıq qüvvədə qalır.
        val next = Rig(opts(debug = true))
        next.store.map[Core.K_CONSENT] = "11"
        next.tombstone = ConsentTombstone().also { it.attach(left) }
        assertNotNull(next.core().anonymousId)
    }

    @Test
    fun tombstoneIsKeptUntilTheWorkerHasPersistedTheConsent() {
        val file = FakeTombFile()
        val tombstone = ConsentTombstone()
        // `init`-dən əvvəl faylın yeri məlum deyil: imtina yaddaşda qalır və `init` çağırılan kimi yazılır.
        assertTrue(tombstone.record("10", erase = false, scrub = true))
        assertNull(file.text)
        tombstone.attach(file)
        assertEquals("1 10 0 1\n", file.text)

        // Çağırış atılıb və ya uğursuz olub (razılıq bazada deyil): nişan qalır.
        tombstone.done(persisted = false)
        assertEquals("1 10 0 1\n", file.text)
        // Nişan qaldığı üçün sonrakı razılıq onun üstünə yazılır (köhnə imtina geri qayıtmasın), silinmə isə itmir.
        assertTrue(tombstone.record("11", erase = false, scrub = false))
        assertEquals("1 11 0 1\n", file.text)
        // Fayl silinə bilmirsə vəziyyət itmir, növbəti uğurlu çağırış onu silir.
        file.failDelete = true
        tombstone.done(persisted = true)
        assertEquals("1 11 0 1\n", file.text)
        file.failDelete = false
        assertTrue(tombstone.record("11", erase = false, scrub = false))
        tombstone.done(persisted = true)
        assertNull(file.text)
    }

    @Test
    fun restrictTombstoneErasesTheQueueWithoutChangingTheStoredConsent() {
        val rig = rigWithQueue()
        val file = FakeTombFile()
        // Təkrar `init(consent: analytics=false)`: məhdudiyyət saxlanmır, amma tələb etdiyi silinmə itmir.
        rig.tombstone = tombstoneLeftBy(file) { assertTrue(it.record(null, erase = true, scrub = false)) }
        assertEquals("1 -- 1 0\n", file.text)
        val core = rig.core()
        assertEquals("11", rig.store.map[Core.K_CONSENT])
        assertEquals(0, rig.queue.rows.count { it.payload.contains("\"Old\"") })
        assertNull(rig.store.map[Core.K_USER])
        assertNotNull(core.anonymousId)
        assertNull(file.text)
    }

    @Test
    fun tornTombstoneIsTreatedAsDeniedForBothPurposes() {
        for (text in listOf("", "1 0", "garbage", "2 11 0 0\n", "1 1x 0 0\n")) {
            val rig = rigWithQueue()
            val file = FakeTombFile(text)
            rig.tombstone = ConsentTombstone().also { it.attach(file) }
            val core = rig.core()
            core.track("New", null, null)
            core.flush(force = true)
            assertEquals(text, 0, rig.transport.bodies.size)
            assertEquals(text, 0, rig.queue.size())
            assertNull(text, core.anonymousId)
            // Yarımçıq nişan istifadəçinin imtinası (`00`) kimi saxlanır (iOS ilə eyni qayda).
            assertEquals(text, ConsentTombstone.DENIED, rig.store.map[Core.K_CONSENT])
            assertNull(text, file.text)
        }
    }

    // ---- B3: reklam sahələri diskdən silinir -------------------------------------------------------

    @Test
    fun adsWithdrawalRewritesQueuedRowsAtRestAndRegrantDoesNotRestoreThem() {
        val rig = Rig(granted)
        val core = rig.core()
        core.onDeepLink(CLICK_LINK)
        core.track("Queued", null, null)
        assertTrue(rig.queue.rows.any { it.ctx.contains("FB1") })
        assertTrue(rig.queue.rows.any { it.payload.contains("DeepLinkOpen") && it.payload.contains("FB1") })
        val ids = rig.queue.rows.map { it.id }

        core.setConsent(true, false)
        assertEquals("sətirlərin sırası və ID-ləri qalır", ids, rig.queue.rows.map { it.id })
        assertRowsHaveNoAdsData(rig)
        assertNoClickIds(rig.store.map[Core.K_CAMPAIGN].orEmpty())
        assertTrue("UTM qalır", rig.queue.rows.any { it.ctx.contains("utm_campaign") })
        assertNull(rig.store.map[Core.K_ADS_ROWS])

        // Göndərişdən əvvəl razılıq yenidən verilir: köhnə sətirlər reklam üçün yararlı olmur.
        core.setConsent(true, true)
        core.flush(force = true)
        assertEquals(0, rig.queue.size())
        val old = rig.transport.posts.filter { batch -> batch.getJSONArray("events").toString().contains("\"Queued\"") }
        assertEquals(1, old.size)
        assertFalse(old[0].getJSONObject("ctx").getJSONObject("consent").getBoolean("ads"))
        for (body in rig.transport.bodies) assertNoClickIds(body)
    }

    @Test
    fun secondInitRestrictingAdsRewritesQueuedRowsAtRest() {
        val rig = Rig(granted)
        val core = rig.core()
        core.onDeepLink(CLICK_LINK)
        core.track("Queued", null, null)
        core.restrict(SmartBeeConsent(analytics = true, ads = false), collectAdvertisingId = true)
        assertRowsHaveNoAdsData(rig)
        assertNoClickIds(rig.store.map[Core.K_CAMPAIGN].orEmpty())
    }

    @Test
    fun remoteConsentDefaultTurningAdsOffRewritesQueuedRowsAtRest() {
        val rig = Rig(opts(debug = true))
        val core = rig.core()
        core.onDeepLink(CLICK_LINK)
        core.track("Queued", null, null)
        assertTrue(rig.queue.rows.any { it.ctx.contains("FB1") })
        rig.transport.configBody = """{"enabled":true,"consent_default":{"analytics":true,"ads":false}}"""
        core.refreshConfig(force = true)
        assertRowsHaveNoAdsData(rig)
        assertNoClickIds(rig.store.map[Core.K_CAMPAIGN].orEmpty())
    }

    @Test
    fun rowsQueuedWithoutAdsConsentAreNotReadOrRewritten() {
        val rig = Rig(opts(consent = SmartBeeConsent(analytics = true, ads = false), debug = true))
        val core = rig.core()
        core.track("Queued", null, null)
        core.setConsent(true, false)
        core.restrict(SmartBeeConsent(analytics = true, ads = false), collectAdvertisingId = true)
        assertEquals(0, rig.queue.rewritten)
        assertNull(rig.store.map[Core.K_ADS_ROWS])
    }

    @Test
    fun deepLinkWhileConsentIsUndecidedWritesNoClickIdsToDiskWhenAdsIsDenied() {
        val store = RecordingStore()
        val queue = FakeQueue()
        val transport = FakeTransport()
        val core = Core(KEY, opts(debug = true), store, queue, transport, FakeEnv()).also { it.start() }
        // İlk işə düşmə: konfiq hələ gəlməyib, razılıq məlum deyil. Keçid yalnız yaddaşda gözləyir.
        core.onDeepLink(CLICK_LINK)
        assertEquals(0, queue.size())
        assertTrue(store.written.none { it.contains("FB1") || it.contains("fbclid") })
        assertNull(store.map[Core.K_CAMPAIGN])

        transport.configBody = """{"enabled":true,"consent_default":{"analytics":true,"ads":false}}"""
        core.refreshConfig(force = true)
        assertTrue(queue.rows.any { it.payload.contains("DeepLinkOpen") })
        for (row in queue.rows) {
            assertNoClickIds(row.ctx)
            assertNoClickIds(row.payload)
            assertFalse(JSONObject(row.ctx).getJSONObject("consent").getBoolean("ads"))
        }
        // Diskə heç bir an, keçici də olsa, klik ID-si yazılmayıb; UTM isə saxlanıb.
        assertTrue(store.written.none { it.contains("FB1") || it.contains("fbclid") || it.contains("gclid") })
        assertEquals(setOf("utm_source", "utm_campaign"), JSONObject(store.map[Core.K_CAMPAIGN]!!).keySet())
    }

    @Test
    fun deepLinkWhileConsentIsUndecidedKeepsClickIdsWhenAdsIsGranted() {
        val rig = Rig(opts(debug = true), fresh = true)
        val core = rig.core()
        core.onDeepLink(CLICK_LINK)
        assertNull(rig.store.map[Core.K_CAMPAIGN])
        rig.transport.configBody = """{"enabled":true,"consent_default":{"analytics":true,"ads":true}}"""
        core.refreshConfig(force = true)
        assertEquals(setOf("utm_source", "utm_campaign", "fbclid", "gclid"), JSONObject(rig.store.map[Core.K_CAMPAIGN]!!).keySet())
        assertTrue(rig.queue.rows.any { it.payload.contains("DeepLinkOpen") && it.payload.contains("FB1") })
    }

    // ---- B5: rədd cavabları PROTOCOL.md 5.6 cədvəli ilə --------------------------------------------

    @Test
    fun rejectionVerdictMatchesTheProtocolErrorTableExactly() {
        fun verdict(status: Int, error: String? = null, events: Int = 1): Int =
            HttpResult(status, error?.let { """{"ok":false,"error":"$it"}""" }).verdict(events)
        for (status in listOf(200, 201, 204)) assertEquals(HttpResult.ACCEPTED, verdict(status))

        // 413: birdən çox event həmişə bölünür; tək event yalnız cədvəldəki kodla atılır.
        for (error in listOf(null, "body_too_large", "blocked")) assertEquals(HttpResult.SPLIT, verdict(413, error, events = 2))
        for (error in listOf("body_too_large", "context_too_large", "too_many_events")) assertEquals(error, HttpResult.DROP, verdict(413, error))
        for (error in listOf(null, "blocked", "bad_json", "unknown_key")) assertEquals("$error", HttpResult.RETRY, verdict(413, error))
        assertEquals(HttpResult.RETRY, HttpResult(413, "<html>Request Entity Too Large</html>").verdict(1))

        // 400: yalnız cədvəldəki kodlar; WAF-ın `{"error":"blocked"}` cavabı müvəqqətidir.
        for (error in listOf("empty_body", "bad_gzip", "bad_json", "bad_batch", "bad_chars")) assertEquals(error, HttpResult.DROP, verdict(400, error))
        for (error in listOf(null, "blocked", "body_too_large", "unknown_key", "origin_not_allowed")) assertEquals("$error", HttpResult.RETRY, verdict(400, error))
        assertEquals(HttpResult.RETRY, HttpResult(400, """{"error":"blocked"}""").verdict(3))

        // 403: `unknown_key` açarı söndürür; cədvəldəki kodlar toplunu atır; qalanı müvəqqətidir.
        assertEquals(HttpResult.KEY_OFF, verdict(403, "unknown_key"))
        for (error in listOf("origin_not_allowed", "app_not_allowed", "platform_not_enabled", "unknown_platform", "browser_not_allowed")) {
            assertEquals(error, HttpResult.DROP, verdict(403, error))
        }
        for (error in listOf(null, "blocked", "forbidden", "bad_json")) assertEquals("$error", HttpResult.RETRY, verdict(403, error))

        // 404: yalnız `unknown_key`.
        assertEquals(HttpResult.KEY_OFF, verdict(404, "unknown_key"))
        for (error in listOf(null, "not_found", "app_not_allowed", "bad_batch")) assertEquals("$error", HttpResult.RETRY, verdict(404, error))

        // 422 cədvəldə yoxdur: gövdə ilə və ya gövdəsiz müvəqqətidir. Qalan hər status da.
        for (error in listOf(null, "bad_batch", "unknown_key", "body_too_large")) assertEquals("$error", HttpResult.RETRY, verdict(422, error))
        for (status in listOf(-1, 0, 100, 301, 302, 304, 307, 401, 402, 405, 408, 409, 410, 418, 429, 451, 500, 502, 503, 504)) {
            for (error in listOf(null, "unknown_key", "bad_batch", "body_too_large", "app_not_allowed")) {
                assertEquals("$status $error", HttpResult.RETRY, verdict(status, error))
                assertEquals("$status $error", HttpResult.RETRY, verdict(status, error, events = 5))
            }
        }
    }

    @Test
    fun unrecognisedRejectionsKeepTheBatchAndTableRejectionsDropIt() {
        fun queuedAfter(status: Int, body: String?): Pair<Int, Int> {
            val rig = Rig(granted)
            rig.store.map[Core.K_APP_VERSION] = "1.2.3|45"
            val core = rig.core()
            core.track("Lead", null, null)
            // Sessiya eventi ilə birlikdə növbədə iki sətir var; tək eventlik hal üçün biri qalır.
            rig.queue.rows.removeAll { !it.payload.contains("\"Lead\"") }
            assertEquals(1, rig.queue.size())
            rig.transport.status = status
            rig.transport.postError = body
            core.flush(force = true)
            assertFalse("$status $body", core.paused)
            return rig.queue.size() to rig.transport.bodies.size
        }
        // Saxlanır: WAF-ın 400-ü, 422, gövdəsiz və ya tanınmayan kodlu tək eventlik 413.
        assertEquals(1 to 1, queuedAfter(400, """{"error":"blocked"}"""))
        assertEquals(1 to 1, queuedAfter(422, null))
        assertEquals(1 to 1, queuedAfter(422, """{"ok":false,"error":"bad_batch"}"""))
        assertEquals(1 to 1, queuedAfter(413, null))
        assertEquals(1 to 1, queuedAfter(413, """{"error":"blocked"}"""))
        assertEquals(1 to 1, queuedAfter(404, """{"ok":false,"error":"not_found"}"""))
        // Atılır: cədvəldəki kodlar.
        assertEquals(0 to 1, queuedAfter(400, """{"ok":false,"error":"bad_batch"}"""))
        assertEquals(0 to 1, queuedAfter(413, """{"ok":false,"error":"body_too_large"}"""))
        assertEquals(0 to 1, queuedAfter(403, """{"ok":false,"error":"app_not_allowed"}"""))
    }

    // ---- B7 (d): Java-dan null blok -----------------------------------------------------------------

    @Test
    fun smartBeeOptionsWithANullBlockFromJavaReturnsTheDefaults() {
        // Java: `SmartBeeOptionsKt.smartBeeOptions(null)`.
        val method = Class.forName("az.smartbee.pixel.SmartBeeOptionsKt").getMethod("smartBeeOptions", Function1::class.java)
        val options = method.invoke(null, null) as SmartBeeOptions
        assertNull(options.consent)
        assertFalse(options.debug)
        assertTrue(options.autoEvents)
        assertTrue(options.collectAdvertisingId)
        assertEquals(DEFAULT_ENDPOINT, options.endpoint)
        assertEquals(DEFAULT_ENDPOINT, smartBeeOptions(null).endpoint)
    }

    // ---- B8: pozulmuş yaddaş və konfiq razılıq sayılmır ---------------------------------------------

    @Test
    fun remoteConsentDefaultIsTrueOnlyForAJsonBooleanTrue() {
        fun consent(json: String): Pair<Boolean, Boolean> = RemoteConfig.parse(json)!!.let { it.consentAnalytics to it.consentAds }
        // Sahə yoxdursa susmaya görə dəyərlər qalır.
        assertEquals(true to true, consent("""{"enabled":true}"""))
        // Var, amma obyekt deyil: hər iki məqsəd false.
        for (value in listOf("null", "true", "1", "\"yes\"", "[]", "[true,true]")) {
            assertEquals(value, false to false, consent("""{"consent_default":$value}"""))
        }
        // Çatışmayan və ya boolean olmayan üzv false-dur.
        assertEquals(false to false, consent("""{"consent_default":{}}"""))
        assertEquals(true to false, consent("""{"consent_default":{"analytics":true}}"""))
        assertEquals(false to true, consent("""{"consent_default":{"ads":true}}"""))
        assertEquals(false to false, consent("""{"consent_default":{"analytics":"true","ads":1}}"""))
        assertEquals(false to false, consent("""{"consent_default":{"analytics":null,"ads":"1"}}"""))
        assertEquals(true to false, consent("""{"consent_default":{"analytics":true,"ads":{"value":true}}}"""))
        assertEquals(true to true, consent("""{"consent_default":{"analytics":true,"ads":true}}"""))
        assertEquals(false to false, consent("""{"consent_default":{"analytics":false,"ads":false}}"""))
    }

    @Test
    fun malformedStoredConsentIsTreatedAsDeniedNotAsNeverStated() {
        for (stored in listOf("??", "1", "111", "yes", "1x", "")) {
            val rig = Rig(opts(debug = true))
            rig.store.map[Core.K_CONFIG] = """{"enabled":true,"consent_default":{"analytics":true,"ads":true}}"""
            rig.store.map[Core.K_CONSENT] = stored
            val core = rig.core()
            core.onForeground()
            core.track("Lead", null, null)
            core.flush(force = true)
            assertNull(stored, core.anonymousId)
            assertEquals(stored, 0, rig.transport.bodies.size)
            assertEquals(stored, 0, rig.transport.configCalls)
            assertEquals(stored, 0, rig.queue.size())

            // `setConsent` razılığı yenidən bildirir.
            core.setConsent(true, true)
            assertEquals("11", rig.store.map[Core.K_CONSENT])
            core.track("AfterRestating", null, null)
            core.flush(force = true)
            assertTrue(stored, rig.transport.names.contains("AfterRestating"))
        }
    }

    @Test
    fun initConsentDoesNotRestateAMalformedStoredConsent() {
        // Oxunmayan saxlanmış razılıq itmiş imtina ola bilər: `init`-in `consent` seçimi onu yumşalda bilmir.
        val rig = Rig(opts(consent = SmartBeeConsent(analytics = true, ads = true), debug = true))
        rig.store.map[Core.K_CONSENT] = "??"
        val core = rig.core()
        core.track("Lead", null, null)
        core.flush(force = true)
        assertNull(core.anonymousId)
        assertEquals(0, rig.transport.bodies.size)
        assertEquals(0, rig.transport.configCalls)

        // Yalnız yeni `setConsent` onu əvəz edir.
        core.setConsent(true, false)
        core.track("AfterSetConsent", null, null)
        core.flush(force = true)
        assertTrue(rig.transport.names.contains("AfterSetConsent"))
        assertFalse(rig.transport.posts.last().getJSONObject("ctx").getJSONObject("consent").getBoolean("ads"))
        assertEquals("10", rig.store.map[Core.K_CONSENT])
    }
}
