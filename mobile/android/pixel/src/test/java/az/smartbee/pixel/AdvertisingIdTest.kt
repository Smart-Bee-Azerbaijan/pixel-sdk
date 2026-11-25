package az.smartbee.pixel

import com.networknt.schema.InputFormat
import com.networknt.schema.JsonSchemaFactory
import com.networknt.schema.SpecVersion
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

private const val GAID = "38400000-8cf0-11bd-b23e-10b96e40000d"
private const val OTHER_GAID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
private const val ZERO_GAID = "00000000-0000-0000-0000-000000000000"

/** Reklam ID-si (GAID): yalnız reklam razılığı ilə göndərilir, diskə yazılmır, oxunması nüvəni bloklamır. */
class AdvertisingIdTest {
    private val schema = JsonSchemaFactory.getInstance(SpecVersion.VersionFlag.V202012)
        .getSchema(File(System.getProperty("spec.dir") ?: error("spec.dir is not set"), "schema/batch.v1.schema.json").readText())

    private val granted = opts(consent = SmartBeeConsent(analytics = true, ads = true), debug = true)

    /** Oxuma cəhdlərini sayan saxta mənbə. */
    private class Lookup(var result: () -> AdInfo?) : AdIdLookup {
        var reads = 0
        override fun read(): AdInfo? {
            reads++
            return result()
        }
    }

    private fun newRig(options: SmartBeeOptions = granted, fresh: Boolean = false, result: () -> AdInfo? = { AdInfo(GAID, false) }): Pair<Rig, Lookup> {
        val rig = Rig(options, fresh)
        val lookup = Lookup(result)
        rig.env.adLookup = lookup
        return rig to lookup
    }

    private fun gaidOf(batch: JSONObject): String? = batch.getJSONObject("ctx").optJSONObject("ids")?.optString("gaid")

    /** `name` eventinin getdiyi toplunun GAID-i; event göndərilməyibsə xəta. */
    private fun gaidFor(rig: Rig, name: String): String? {
        val batch = rig.transport.posts.last { post ->
            post.getJSONArray("events").let { a -> (0 until a.length()).any { a.getJSONObject(it).optString("name") == name } }
        }
        return gaidOf(batch)
    }

    /** Göndərilən heç bir gövdədə, saxlanan heç bir dəyərdə və növbədə GAID yoxdur. */
    private fun assertNothingCarries(rig: Rig, id: String, from: Int = 0) {
        for (body in rig.transport.bodies.drop(from)) assertFalse(body, body.contains(id))
        assertNeverOnDisk(rig, id)
    }

    private fun assertNeverOnDisk(rig: Rig, id: String) {
        for ((key, value) in rig.store.map) assertFalse("$key=$value", value.contains(id))
        for (row in rig.queue.rows) {
            assertFalse(row.ctx, row.ctx.contains(id) || row.ctx.contains("gaid"))
            assertFalse(row.payload, row.payload.contains(id))
        }
    }

    private fun assertValid(batch: JSONObject) {
        val errors = schema.validate(batch.toString(), InputFormat.JSON)
        assertTrue("schema errors: $errors", errors.isEmpty())
    }

    // ---- Razılıq --------------------------------------------------------------------------------

    @Test
    fun gaidIsSentWhenAdsConsentIsGranted() {
        val (rig, lookup) = newRig()
        val core = rig.core()
        core.onForeground()
        core.track("Lead", null, null)
        assertNeverOnDisk(rig, GAID)
        core.flush(force = true)

        assertEquals(1, lookup.reads)
        assertEquals(GAID, gaidFor(rig, "Lead"))
        for (batch in rig.transport.posts) assertValid(batch)
        assertEquals(setOf("gaid"), rig.transport.posts.last().getJSONObject("ctx").getJSONObject("ids").keySet())
        assertNeverOnDisk(rig, GAID)
    }

    @Test
    fun gaidIsNeitherReadNorSentWithoutAdsConsent() {
        val (rig, lookup) = newRig(opts(consent = SmartBeeConsent(analytics = true, ads = false)))
        val core = rig.core()
        core.onForeground()
        core.track("Lead", null, null)
        core.flush(force = true)

        assertTrue(rig.transport.names.contains("Lead"))
        assertEquals(0, lookup.reads)
        assertNothingCarries(rig, GAID)
        for (batch in rig.transport.posts) assertFalse(batch.getJSONObject("ctx").has("ids"))
    }

    @Test
    fun gaidIsNeitherReadNorSentWithoutAnalyticsConsent() {
        val (rig, lookup) = newRig(opts(consent = SmartBeeConsent(analytics = false, ads = true)))
        val core = rig.core()
        core.onForeground()
        core.track("Lead", null, null)
        core.flush(force = true)
        assertEquals(0, lookup.reads)
        assertEquals(0, rig.transport.posts.size)
    }

    @Test
    fun gaidIsAbsentFromEveryBatchAfterAdsConsentIsWithdrawn() {
        val (rig, lookup) = newRig()
        val core = rig.core()
        core.onForeground()
        core.track("Before", null, null)
        core.flush(force = true)
        assertEquals(GAID, gaidFor(rig, "Before"))

        // Razılıq varkən növbəyə düşmüş, amma hələ göndərilməmiş event də GAID-siz getməlidir.
        core.track("Queued", null, null)
        val sentBefore = rig.transport.bodies.size
        core.setConsent(true, false)
        core.track("After", null, null)
        core.flush(force = true)
        core.onBackground()
        core.onForeground()
        core.track("Later", null, null)
        core.flush(force = true)

        assertTrue(rig.transport.names.containsAll(listOf("Queued", "After", "Later")))
        assertNothingCarries(rig, GAID, from = sentBefore)
        for (batch in rig.transport.posts.drop(sentBefore)) assertFalse(batch.getJSONObject("ctx").has("ids"))
        // Yaddaşdakı dəyər silinib: razılıq qayıdanda köhnə dəyər işlədilmir, yenidən oxunur.
        assertEquals(1, lookup.reads)
        lookup.result = { AdInfo(OTHER_GAID, false) }
        core.track("WhileOff", null, null)
        core.setConsent(true, true)
        assertEquals(2, lookup.reads)
        core.track("Again", null, null)
        core.flush(force = true)
        assertEquals(OTHER_GAID, gaidFor(rig, "Again"))
        // Reklam razılığı olmadan yaranmış eventə sonradan da əlavə olunmur.
        assertNull(gaidFor(rig, "WhileOff"))
        assertNothingCarries(rig, GAID, from = sentBefore)
    }

    @Test
    fun analyticsWithdrawalDropsTheCachedGaid() {
        val (rig, lookup) = newRig()
        val core = rig.core()
        core.onForeground()
        core.setConsent(false, true)
        val sentBefore = rig.transport.bodies.size
        core.track("Off", null, null)
        core.flush(force = true)
        assertEquals(sentBefore, rig.transport.bodies.size)

        lookup.result = { null }
        core.setConsent(true, true)
        core.track("Lead", null, null)
        core.flush(force = true)
        assertEquals(2, lookup.reads)
        assertNull(gaidFor(rig, "Lead"))
    }

    @Test
    fun serverConsentDefaultControlsTheGaid() {
        // Tətbiq razılıq bildirməyib: qərar konfiqin `consent_default` dəyərindədir.
        val (rig, lookup) = newRig(opts(debug = true))
        rig.store.map[Core.K_CONFIG] = """{"enabled":true,"consent_default":{"analytics":true,"ads":true}}"""
        val core = rig.core()
        core.onForeground()
        core.track("Before", null, null)
        core.flush(force = true)
        assertEquals(GAID, gaidFor(rig, "Before"))

        core.track("Queued", null, null)
        val sentBefore = rig.transport.bodies.size
        rig.transport.configBody = """{"enabled":true,"consent_default":{"analytics":true,"ads":false}}"""
        core.refreshConfig(force = true)
        core.track("After", null, null)
        core.flush(force = true)
        assertTrue(rig.transport.names.containsAll(listOf("Queued", "After")))
        assertNothingCarries(rig, GAID, from = sentBefore)
        assertEquals(1, lookup.reads)
    }

    @Test
    fun gaidIsNotReadOnFirstLaunchUntilConsentIsKnown() {
        val (rig, lookup) = newRig(opts(debug = true), fresh = true)
        rig.transport.configStatus = -1
        val core = rig.core()
        core.onForeground()
        core.track("Held", null, null)
        core.flush(force = true)
        assertEquals("razılıq məlum deyil", 0, lookup.reads)

        rig.transport.configStatus = 200
        rig.transport.configBody = """{"enabled":true,"consent_default":{"analytics":true,"ads":false}}"""
        rig.env.time += Core.BACKOFF_MAX_MS
        core.flush(force = true)
        assertTrue(rig.transport.names.contains("Held"))
        assertEquals(0, lookup.reads)
        assertNothingCarries(rig, GAID)

        // Server reklam razılığına icazə verəndə GAID oxunur.
        rig.transport.configBody = """{"enabled":true,"consent_default":{"analytics":true,"ads":true}}"""
        core.refreshConfig(force = true)
        assertEquals(1, lookup.reads)
        core.track("Lead", null, null)
        core.flush(force = true)
        assertEquals(GAID, gaidFor(rig, "Lead"))
    }

    // ---- Seçim və örtüklər ----------------------------------------------------------------------

    @Test
    fun optionTurnsCollectionOff() {
        val (rig, lookup) = newRig(opts(consent = SmartBeeConsent(true, true), collectAdvertisingId = false))
        val core = rig.core()
        core.onForeground()
        core.setConsent(true, true)
        core.track("Lead", null, null)
        core.flush(force = true)

        assertTrue(rig.transport.names.contains("Lead"))
        assertEquals(0, lookup.reads)
        assertNothingCarries(rig, GAID)
        assertTrue(opts().collectAdvertisingId)
    }

    @Test
    fun wrappersBehaveTheSame() {
        for (wrapper in listOf("react-native", "flutter")) {
            val (rig, lookup) = newRig(opts(consent = SmartBeeConsent(true, true), wrapper = wrapper, wrapperVersion = "1.0.0"))
            val core = rig.core()
            core.onForeground()
            core.track("Lead", null, null)
            core.flush(force = true)
            assertEquals(1, lookup.reads)
            assertEquals(GAID, gaidFor(rig, "Lead"))
            assertEquals(wrapper, rig.transport.posts.last().getJSONObject("sdk").getString("wrapper"))
            assertValid(rig.transport.posts.last())

            core.setConsent(true, false)
            val sentBefore = rig.transport.bodies.size
            core.track("After", null, null)
            core.flush(force = true)
            assertNothingCarries(rig, GAID, from = sentBefore)

            val (off, offLookup) = newRig(opts(consent = SmartBeeConsent(true, true), wrapper = wrapper, collectAdvertisingId = false))
            val offCore = off.core()
            offCore.onForeground()
            offCore.track("Lead", null, null)
            offCore.flush(force = true)
            assertEquals(0, offLookup.reads)
            assertNothingCarries(off, GAID)
        }
    }

    // ---- Mənbənin vəziyyətləri ------------------------------------------------------------------

    @Test
    fun noGaidWhenLibraryIsAbsentLimitedZeroOrFailing() {
        val cases: Map<String, (() -> AdInfo?)?> = linkedMapOf(
            "kitabxana yoxdur" to null,
            "nəticə yoxdur" to { null },
            "izləmə məhdudlaşdırılıb" to { AdInfo(GAID, true) },
            "sıfır ID" to { AdInfo(ZERO_GAID, false) },
            "sıfırlar" to { AdInfo("0000", false) },
            "boş ID" to { AdInfo("", false) },
            "null ID" to { AdInfo(null, false) },
            "yararsız ID" to { AdInfo("not an id: $GAID", false) },
            "istisna" to { throw IllegalStateException("Google Play services is missing") },
            "Error" to { throw NoClassDefFoundError("com/google/android/gms/common/GooglePlayServicesUtilLight") },
        )
        for ((name, result) in cases) {
            val rig = Rig(granted)
            val lookup = result?.let { Lookup(it) }
            rig.env.adLookup = lookup
            val core = rig.core()
            core.onForeground()
            core.track("Lead", null, null)
            core.flush(force = true)

            assertTrue(name, rig.transport.names.containsAll(listOf("SessionStart", "AppInstall", "AppOpen", "Lead")))
            assertEquals(name, 0, rig.queue.size())
            for (batch in rig.transport.posts) {
                assertFalse(name, batch.getJSONObject("ctx").has("ids"))
                assertValid(batch)
            }
            assertNothingCarries(rig, GAID)
            // GAID hər ön plana keçiddə yenidən oxunur (istifadəçi onu sıfırlaya bilər).
            core.onBackground()
            core.onForeground()
            if (lookup != null) assertEquals(name, 2, lookup.reads)
        }
    }

    @Test
    fun gaidIsTrimmedAndSentAsReturned() {
        assertEquals(GAID, Util.adId(AdInfo(" $GAID\n", false)))
        assertNull(Util.adId(AdInfo(GAID, true)))
        assertNull(Util.adId(AdInfo(ZERO_GAID, false)))
        assertNull(Util.adId(null))
    }

    // ---- Oxumanın vaxtı -------------------------------------------------------------------------

    @Test
    fun slowLookupDoesNotBlockTrackingOrFlushing() {
        val (rig, lookup) = newRig()
        rig.env.deferOffload = true
        val core = rig.core()
        core.onForeground()
        core.track("Early", null, null)
        core.flush(force = true)

        // Oxuma başqa axına verilib və hələ bitməyib: eventlər gözləmədən, GAID-siz gedir.
        assertEquals(1, rig.env.offloaded.size)
        assertEquals("oxuma çağıran axında işləməməlidir", 0, lookup.reads)
        assertEquals(listOf("SessionStart", "AppInstall", "AppOpen", "Early"), rig.transport.names)
        assertEquals(0, rig.queue.size())
        assertNothingCarries(rig, GAID)

        // Cavab gözlənilərkən ikinci oxuma başlamır.
        core.onBackground()
        core.onForeground()
        core.setConsent(true, true)
        assertEquals(1, rig.env.offloaded.size)

        // Cavabdan əvvəl növbəyə düşən event cavabdan sonra göndərilirsə GAID ilə gedir.
        core.track("Queued", null, null)
        rig.env.runOffloaded()
        assertEquals(1, lookup.reads)
        assertNeverOnDisk(rig, GAID)
        core.track("Late", null, null)
        core.flush(force = true)
        assertEquals(GAID, gaidFor(rig, "Queued"))
        assertEquals(GAID, gaidFor(rig, "Late"))
    }

    @Test
    fun lookupThatNeverReturnsChangesNothing() {
        val (rig, lookup) = newRig()
        rig.env.deferOffload = true
        val core = rig.core()
        core.onForeground()
        repeat(3) {
            rig.env.time += 86_400_001L
            core.onBackground()
            core.onForeground()
            core.track("Lead", null, null)
            core.flush(force = true)
        }
        assertEquals(3, rig.transport.names.count { it == "Lead" })
        assertEquals(1, rig.env.offloaded.size)
        assertEquals(0, lookup.reads)
        assertNothingCarries(rig, GAID)
    }

    @Test
    fun resultArrivingAfterWithdrawalIsDiscarded() {
        val (rig, lookup) = newRig()
        rig.env.deferOffload = true
        val core = rig.core()
        core.onForeground()
        core.setConsent(true, false)
        rig.env.runOffloaded()
        assertEquals(1, lookup.reads)
        core.track("Lead", null, null)
        core.flush(force = true)
        assertTrue(rig.transport.names.contains("Lead"))
        assertNothingCarries(rig, GAID)

        // Atılmış nəticə keş sayılmır: razılıq qayıdanda yenidən oxunur.
        core.setConsent(true, true)
        assertEquals(1, rig.env.offloaded.size)
        rig.env.runOffloaded()
        core.track("Again", null, null)
        core.flush(force = true)
        assertEquals(GAID, gaidFor(rig, "Again"))
    }

    @Test
    fun gaidIsRefreshedOnEveryForeground() {
        val (rig, lookup) = newRig()
        val core = rig.core()
        core.onForeground()
        assertEquals(1, lookup.reads)
        // Ön plana keçid olmadan (konfiq yeniləməsi, göndəriş) yenidən oxunmur.
        repeat(3) {
            rig.env.time += 3_600_000
            core.refreshConfig(force = true)
            core.track("Lead", null, null)
            core.flush(force = true)
        }
        assertEquals(1, lookup.reads)
        assertEquals(GAID, gaidFor(rig, "Lead"))

        // İstifadəçi ID-ni sıfırlayıb: növbəti ön plana keçiddə yeni dəyər oxunur (24 saatlıq keş yoxdur).
        lookup.result = { AdInfo(OTHER_GAID, false) }
        core.track("StillCached", null, null)
        core.flush(force = true)
        assertEquals(GAID, gaidFor(rig, "StillCached"))
        core.onBackground()
        core.onForeground()
        assertEquals(2, lookup.reads)
        core.track("Fresh", null, null)
        core.flush(force = true)
        assertEquals(OTHER_GAID, gaidFor(rig, "Fresh"))

        // İstifadəçi izləməni məhdudlaşdırıb: növbəti ön plana keçiddən sonra GAID göndərilmir.
        lookup.result = { AdInfo(OTHER_GAID, true) }
        core.onBackground()
        core.onForeground()
        val sentBefore = rig.transport.bodies.size
        core.track("Limited", null, null)
        core.flush(force = true)
        assertEquals(3, lookup.reads)
        assertNull(gaidFor(rig, "Limited"))
        assertNothingCarries(rig, OTHER_GAID, from = sentBefore)
    }

    @Test
    fun gaidIsNotKeptAcrossProcessRestarts() {
        val (rig, lookup) = newRig()
        val core = rig.core()
        core.onForeground()
        core.track("Lead", null, null)
        core.flush(force = true)
        assertEquals(GAID, gaidFor(rig, "Lead"))
        assertNeverOnDisk(rig, GAID)

        // Yeni proses: kitabxana artıq yoxdur, diskdən bərpa olunacaq dəyər də yoxdur.
        rig.env.adLookup = null
        val again = rig.core()
        val sentBefore = rig.transport.bodies.size
        again.onForeground()
        again.track("Lead", null, null)
        again.flush(force = true)
        assertTrue(rig.transport.bodies.size > sentBefore)
        assertNothingCarries(rig, GAID, from = sentBefore)
        assertEquals(1, lookup.reads)
    }

    @Test
    fun killSwitchStopsTheLookup() {
        val (rig, lookup) = newRig()
        rig.store.map[Core.K_CONFIG] = """{"enabled":false}"""
        val core = rig.core()
        core.onForeground()
        core.track("Lead", null, null)
        core.flush(force = true)
        assertEquals(0, lookup.reads)
        assertEquals(0, rig.transport.posts.size)
    }
}
