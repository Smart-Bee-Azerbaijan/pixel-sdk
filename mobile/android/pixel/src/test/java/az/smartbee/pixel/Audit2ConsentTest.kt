package az.smartbee.pixel

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * İkinci müstəqil auditin razılıq / çatdırılma tapıntıları (C1, C3, C4, C7). iOS-da eyni ssenarilər
 * `Audit2ConsentTests.swift`-dədir; Android qatına aid olanlar (atomik nişan faylı, məşğul növbə) `Audit2ConsentAndroidTest.kt`-də.
 */
class Audit2ConsentTest {
    private val granted = opts(consent = SmartBeeConsent(analytics = true, ads = true), debug = true)

    private fun disk(rig: Rig): String = rig.queue.rows.joinToString("\n") { it.ctx + it.payload }

    private fun event(rig: Rig, name: String): JSONObject = rig.transport.events.first { it.optString("name") == name || it.optString("type") == name }

    // ---- C1: props / traits içindəki klik ID-ləri reklam razılığı geri alınanda silinir ----------

    @Test
    fun c1_clickIdsInQueuedPropsAndTraitsAreRemovedWhenAdsConsentIsWithdrawn() {
        val rig = Rig(granted)
        rig.transport.status = 500
        val core = rig.core()
        core.track("ViewItem", mapOf("link" to "https://shop.az/p?gclid=G1SECRET&utm_source=fb&x=1", "value" to 250, "name" to "Çay dəsti"), null)
        core.identify("u1", mapOf("landing" to "https://shop.az/?fbclid=FB1SECRET&utm_medium=cpc", "plan" to "pro", "email" to "a@b.az"))
        core.flush(force = true)
        assertTrue(disk(rig).contains("G1SECRET"))
        assertTrue(disk(rig).contains("FB1SECRET"))

        core.setConsent(true, false)
        // Diskdəki sətirlər dərhal təmizlənir.
        assertFalse(disk(rig).contains("G1SECRET"))
        assertFalse(disk(rig).contains("FB1SECRET"))

        rig.transport.status = 200
        rig.transport.bodies.clear()
        rig.transport.posts.clear()
        rig.env.time += 2 * Core.BACKOFF_MAX_MS
        core.flush(force = true)
        val sent = rig.transport.bodies.joinToString("\n")
        assertFalse(sent.contains("G1SECRET"))
        assertFalse(sent.contains("FB1SECRET"))
        for (post in rig.transport.posts) assertFalse(post.getJSONObject("ctx").getJSONObject("consent").getBoolean("ads"))
        // Adi analitika zədələnmir: UTM, qalan parametrlər və hash-lər yerindədir.
        val props = event(rig, "ViewItem").getJSONObject("props")
        assertEquals("https://shop.az/p?utm_source=fb&x=1", props.getString("link"))
        assertEquals(250, props.getInt("value"))
        assertEquals("Çay dəsti", props.getString("name"))
        val traits = event(rig, "identify").getJSONObject("traits")
        assertEquals("https://shop.az/?utm_medium=cpc", traits.getString("landing"))
        assertEquals("pro", traits.getString("plan"))
        assertEquals(Util.sha256("a@b.az"), traits.getString("email_sha256"))
        assertFalse(traits.has("email"))
    }

    @Test
    fun c1_reCleaningDoesNotTouchRowsWithoutClickIds() {
        val rig = Rig(granted)
        rig.transport.status = 500
        val core = rig.core()
        core.track("Purchase", mapOf("value" to 12.5, "currency" to "AZN", "items" to listOf(mapOf("id" to "p1", "qty" to 2)), "page" to "https://shop.az/cart?step=2"), null)
        core.identify("u1", mapOf("email" to "a@b.az", "phone" to "+994501234567", "plan" to "pro"))
        core.flush(force = true)
        val before = rig.queue.rows.map { it.payload }
        core.setConsent(true, false)
        assertEquals(before, rig.queue.rows.map { it.payload })
    }

    @Test
    fun c1_undecidedEventsAreCleanedBeforeTheyReachTheDiskWhenConfigDeniesAds() {
        val rig = Rig(opts(debug = true), fresh = true)
        rig.transport.configStatus = 500
        val core = rig.core()
        core.track("ViewItem", mapOf("link" to "https://shop.az/p?gclid=G1SECRET&x=1"), null)
        core.identify("u1", mapOf("landing" to "https://shop.az/?fbclid=FB1SECRET"))
        assertEquals(0, rig.queue.size())

        rig.transport.configStatus = 200
        rig.transport.configBody = "{\"enabled\":true,\"consent_default\":{\"analytics\":true,\"ads\":false}}"
        rig.env.time += 2 * Core.BACKOFF_MAX_MS
        core.refreshConfig(force = true)
        assertTrue(rig.queue.size() > 0)
        assertFalse(disk(rig).contains("G1SECRET"))
        assertFalse(disk(rig).contains("FB1SECRET"))
        core.flush(force = true)
        val sent = rig.transport.bodies.joinToString("\n")
        assertFalse(sent.contains("G1SECRET"))
        assertFalse(sent.contains("FB1SECRET"))
        assertEquals("https://shop.az/p?x=1", event(rig, "ViewItem").getJSONObject("props").getString("link"))
    }

    // ---- C3: yarımçıq nişan və pozulmuş razılıq ---------------------------------------------------

    @Test
    fun c3_tornTombstoneIsAUserRefusalThatInitConsentCannotLoosen() {
        for (text in listOf("", " ", "1 1", "garbage")) {
            assertEquals(text, "00", ConsentTombstone.parse(text).consent)
            assertTrue(text, ConsentTombstone.parse(text).erase)
            assertTrue(text, ConsentTombstone.parse(text).scrub)

            val rig = Rig(granted)
            rig.store.map[Core.K_CONSENT] = "00"
            rig.tombstone = ConsentTombstone().also { it.attach(FakeTombFile(text)) }
            val core = rig.core()
            core.track("AfterTorn", null, null)
            core.flush(force = true)
            assertEquals(text, "00", rig.store.map[Core.K_CONSENT])
            assertNull(text, core.anonymousId)
            assertEquals(text, 0, rig.transport.bodies.size)
            assertEquals(text, 0, rig.transport.configCalls)

            // Növbəti açılışda da (nişan artıq silinib) `init`-in razılığı imtinanı yumşaltmır.
            val next = Rig(granted)
            next.store.map[Core.K_CONSENT] = rig.store.map[Core.K_CONSENT]!!
            assertNull(text, next.core().anonymousId)
        }
    }

    @Test
    fun c3_unreadableMarkNeverOverwritesAValidStoredConsent() {
        for (stored in listOf("00", "10", "11")) {
            val rig = Rig(opts(debug = true))
            rig.store.map[Core.K_CONSENT] = stored
            rig.tombstone = ConsentTombstone().also { it.attach(FakeTombFile("1 ?? 1 1\n")) }
            rig.core()
            assertEquals(stored, rig.store.map[Core.K_CONSENT])
        }
        // Bazada yararlı dəyər yoxdursa «oxunmur» dəyəri yazılır və rədd sayılır.
        val rig = Rig(granted)
        rig.tombstone = ConsentTombstone().also { it.attach(FakeTombFile("1 ?? 1 1\n")) }
        val core = rig.core()
        assertEquals(ConsentTombstone.CORRUPT, rig.store.map[Core.K_CONSENT])
        assertNull(core.anonymousId)
    }

    @Test
    fun c3_corruptStoredConsentWithInitConsentStaysDeniedUntilSetConsent() {
        for (stored in listOf("??", "", "1", "yes")) {
            val rig = Rig(granted)
            rig.store.map[Core.K_CONSENT] = stored
            val core = rig.core()
            core.onForeground()
            core.track("X", null, null)
            core.flush(force = true)
            assertNull(stored, core.anonymousId)
            assertEquals(stored, 0, rig.transport.bodies.size)
            assertEquals(stored, 0, rig.transport.configCalls)
            assertEquals(stored, 0, rig.queue.size())

            core.setConsent(true, true)
            core.track("AfterSetConsent", null, null)
            core.flush(force = true)
            assertTrue(stored, rig.transport.names.contains("AfterSetConsent"))
            assertEquals("11", rig.store.map[Core.K_CONSENT])
        }
    }

    // ---- C4: kodsuz 4xx alan toplu növbəni əbədi bağlamır -----------------------------------------

    @Test
    fun c4_batchRejectedWithUncoded4xxIsIsolatedAndOnlyThePoisonRowIsDropped() {
        val rig = Rig(granted)
        val core = rig.core()
        rig.transport.respond = { batch -> if (batch.toString().contains("POISON")) 403 else 200 }
        rig.transport.postError = "<html>blocked by WAF</html>"
        core.track("Before", null, null)
        core.track("Search", mapOf("q" to "POISON"), null)
        core.track("After", null, null)

        // İlk iki rədd: toplu olduğu kimi qalır.
        repeat(Core.STUCK_BATCH_TRIES - 1) {
            core.flush(force = true)
            assertEquals(0, rig.transport.posts.size)
        }
        val queued = rig.queue.size()
        // Üçüncü rədd: sətirlər bir-bir göndərilir, sağlam sətirlər çatır, zəhərli sətir növbənin başında qalır.
        core.flush(force = true)
        assertTrue(rig.transport.names.contains("Before"))
        assertFalse(rig.transport.names.contains("After"))
        assertTrue(rig.queue.size() < queued)
        assertTrue(rig.queue.rows[0].payload.contains("POISON"))

        // Tək göndərilən sətir STUCK_ROW_TRIES dəfə rədd olunandan sonra atılır, qalanlar davam edir.
        repeat(Core.STUCK_ROW_TRIES - 2) {
            core.flush(force = true)
            assertTrue(rig.queue.rows[0].payload.contains("POISON"))
        }
        core.flush(force = true)
        assertEquals(0, rig.queue.size())
        assertTrue(rig.transport.names.contains("After"))
        assertFalse(rig.transport.names.contains("Search"))
        assertTrue(rig.env.logs.any { it.contains("no known error code, dropped") })
        assertNull(rig.store.map[Core.K_STUCK])

        // Növbə yenidən adi qaydada işləyir.
        core.track("Later", null, null)
        core.flush(force = true)
        assertTrue(rig.transport.names.contains("Later"))
    }

    @Test
    fun c4_poisonRowDoesNotBlockTheQueueForThirtyDays() {
        val rig = Rig(granted)
        val core = rig.core()
        rig.transport.respond = { batch -> if (batch.toString().contains("POISON")) 403 else 200 }
        rig.transport.postError = "<html>blocked by WAF</html>"
        core.track("Search", mapOf("q" to "POISON"), null)
        core.flush(force = true)
        for (day in 1..30) {
            rig.env.time += 86_400_000L
            core.track("Daily", mapOf("day" to day), null)
            core.flush(force = true)
        }
        core.flush(force = true)
        assertEquals(0, rig.queue.size())
        assertEquals(30, rig.transport.names.count { it == "Daily" })
        assertFalse(rig.transport.names.contains("Search"))
    }

    @Test
    fun c4_isolatedRowIsDroppedAfterThreeDaysEvenWithFewAttempts() {
        val rig = Rig(granted)
        val core = rig.core()
        rig.transport.status = 403
        rig.transport.postError = "blocked"
        core.track("Only", null, null)
        // Növbədə SessionStart / AppInstall da var: toplu üç rəddən sonra təcrid olunur.
        repeat(Core.STUCK_BATCH_TRIES) { core.flush(force = true) }
        val queued = rig.queue.size()
        assertTrue(queued > 0)
        rig.env.time += Core.STUCK_ROW_MS + 1
        rig.transport.status = 200
        rig.transport.posts.clear()
        rig.transport.respond = { batch -> if (batch.getJSONArray("events").getJSONObject(0).optString("name") == "SessionStart") 403 else 200 }
        core.flush(force = true)
        // Yalnız hələ də rədd olunan sətir atılır.
        assertEquals(0, rig.queue.size())
        assertTrue(rig.transport.names.contains("Only"))
        assertFalse(rig.transport.names.contains("SessionStart"))
    }

    @Test
    fun c4_outageThatEndsLosesNothing() {
        val rig = Rig(granted)
        val core = rig.core()
        rig.transport.status = 403
        rig.transport.postError = "blocked"
        core.track("A", null, null)
        core.track("B", null, null)
        // Üç toplu rəddi + təcrid olunmuş ilk sətirin dörd rəddi: hələ heç nə atılmır.
        repeat(Core.STUCK_BATCH_TRIES + Core.STUCK_ROW_TRIES - 2) { core.flush(force = true) }
        val queued = rig.queue.size()
        rig.transport.status = 200
        rig.transport.posts.clear()
        core.flush(force = true)
        assertEquals(0, rig.queue.size())
        assertEquals(queued, rig.transport.events.size)
        assertTrue(rig.transport.names.containsAll(listOf("A", "B")))
    }

    @Test
    fun c4_serverErrorsAndCoded4xxKeepTheOldBehaviour() {
        // 5xx: toplu hədsiz saxlanır, heç nə atılmır və təcrid olunmur.
        val rig = Rig(granted)
        val core = rig.core()
        rig.transport.status = 503
        core.track("A", null, null)
        val queued = rig.queue.size()
        repeat(40) {
            rig.env.time += 86_400_000L
            core.flush(force = true)
        }
        assertEquals(queued, rig.queue.size())
        assertNull(rig.store.map[Core.K_STUCK])
        // 429 (serverin fasilə tələbi) də sayılmır.
        rig.transport.status = 429
        repeat(20) {
            rig.env.time += 86_400_000L
            core.flush(force = true)
        }
        assertEquals(queued, rig.queue.size())
        assertNull(rig.store.map[Core.K_STUCK])
        // 5xx ardıcıl 4xx sayğacını sıfırlayır.
        rig.transport.status = 403
        rig.transport.postError = "blocked"
        repeat(Core.STUCK_BATCH_TRIES - 1) {
            rig.env.time += 86_400_000L
            core.flush(force = true)
        }
        rig.transport.status = 500
        rig.env.time += 86_400_000L
        core.flush(force = true)
        assertNull(rig.store.map[Core.K_STUCK])
        assertEquals(queued, rig.queue.size())
        rig.transport.status = 200
        rig.env.time += 86_400_000L
        core.flush(force = true)
        assertTrue(rig.transport.names.contains("A"))
    }

    @Test
    fun c4_stuckStateSurvivesARestart() {
        val rig = Rig(granted)
        rig.transport.status = 403
        rig.transport.postError = "blocked"
        var core = rig.core()
        core.track("A", null, null)
        core.flush(force = true)
        core.flush(force = true)
        assertTrue(rig.store.map[Core.K_STUCK]!!.contains("|2|"))
        // Yeni proses: sayğac bazadan oxunur, üçüncü rədd toplunu təcrid edir.
        core = rig.core()
        rig.env.logs.clear()
        core.flush(force = true)
        assertTrue(rig.env.logs.any { it.contains("sent one by one") })
    }

    // ---- C7: növbə kəsiləndə sazlama rejimində xəbər verilir ---------------------------------------

    @Test
    fun c7_queueTrimIsLoggedInDebug() {
        val rig = Rig(granted)
        rig.store.map[Core.K_CONFIG] = "{\"enabled\":true,\"flush\":{\"max_queue\":10,\"max_batch\":10}}"
        rig.transport.status = 500
        val core = rig.core()
        for (i in 0 until 20) core.track("E$i", null, null)
        assertEquals(10, rig.queue.size())
        assertTrue(rig.env.logs.any { it.contains("queue is full") && it.contains("dropped") })

        // Sazlama rejimi olmadan loq yazılmır, davranış eynidir.
        val quiet = Rig(opts(consent = SmartBeeConsent(analytics = true, ads = true)))
        quiet.store.map[Core.K_CONFIG] = "{\"enabled\":true,\"flush\":{\"max_queue\":10,\"max_batch\":10}}"
        quiet.transport.status = 500
        val silent = quiet.core()
        for (i in 0 until 20) silent.track("E$i", null, null)
        assertEquals(10, quiet.queue.size())
        assertTrue(quiet.env.logs.isEmpty())
    }
}
