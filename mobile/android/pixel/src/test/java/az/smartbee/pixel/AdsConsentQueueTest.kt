package az.smartbee.pixel

import com.networknt.schema.InputFormat
import com.networknt.schema.JsonSchemaFactory
import com.networknt.schema.SpecVersion
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

private const val QUEUE_GAID = "38400000-8cf0-11bd-b23e-10b96e40000d"
private const val LINK = "https://shop.az/p/1?utm_source=fb&utm_campaign=spring&fbclid=FB1&gclid=G1"

/**
 * Reklam razılığının geri alınması artıq növbədə olan eventlərə də aiddir: toplu qurulanda razılıq yoxdursa
 * hər sətir `ctx.ids`-siz, klik ID-lərsiz və `consent.ads = false` ilə gedir (iOS ilə eyni qayda).
 */
class AdsConsentQueueTest {
    private val schema = JsonSchemaFactory.getInstance(SpecVersion.VersionFlag.V202012)
        .getSchema(File(System.getProperty("spec.dir") ?: error("spec.dir is not set"), "schema/batch.v1.schema.json").readText())

    private val granted = opts(consent = SmartBeeConsent(analytics = true, ads = true), debug = true)

    private fun newRig(options: SmartBeeOptions = granted): Rig {
        val rig = Rig(options)
        rig.env.adLookup = AdIdLookup { AdInfo(QUEUE_GAID, false) }
        return rig
    }

    private fun namesOf(batch: JSONObject): List<String> =
        batch.getJSONArray("events").let { a -> (0 until a.length()).map { a.getJSONObject(it).optString("name") } }

    /** `name` eventinin getdiyi (qəbul olunmuş) toplunun konteksti. */
    private fun ctxFor(rig: Rig, name: String): JSONObject =
        rig.transport.posts.last { namesOf(it).contains(name) }.getJSONObject("ctx")

    /** JSON dəyərini müqayisə oluna bilən adi Kotlin dəyərinə çevirir (açarların sırası nəzərə alınmır). */
    private fun plain(value: Any?): Any? = when (value) {
        is JSONObject -> value.keySet().associateWith { plain(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { plain(value.get(it)) }
        is Number -> value.toDouble()
        else -> value
    }

    private fun assertValid(batch: JSONObject) {
        val errors = schema.validate(batch.toString(), InputFormat.JSON)
        assertTrue("schema errors: $errors", errors.isEmpty())
    }

    private fun assertStripped(ctx: JSONObject) {
        assertFalse(ctx.toString(), ctx.has("ids"))
        assertFalse(ctx.toString(), ctx.getJSONObject("consent").getBoolean("ads"))
        assertTrue(ctx.getJSONObject("consent").getBoolean("analytics"))
        val campaign = ctx.optJSONObject("campaign") ?: return
        for (id in Util.CLICK_IDS) assertFalse(id, campaign.has(id))
    }

    @Test
    fun rowsQueuedBeforeWithdrawalAreSentStrippedAndMarkedAdsFalse() {
        val rig = newRig()
        val core = rig.core()
        core.onForeground()
        core.onDeepLink(LINK)
        core.track("Queued", null, null)
        val stored = rig.queue.rows.map { it.ctx }
        assertTrue(stored.isNotEmpty())
        val last = JSONObject(stored.last())
        assertTrue(last.getJSONObject("consent").getBoolean("ads"))
        assertEquals(setOf("utm_source", "utm_campaign", "fbclid", "gclid"), last.getJSONObject("campaign").keySet())

        core.setConsent(true, false)
        // Razılıq geri alınan kimi növbədəki sətirlər diskdə də təmizlənir; uğursuz göndəriş onları dəyişmir.
        val scrubbed = rig.queue.rows.map { it.ctx }
        assertEquals(stored.size, scrubbed.size)
        for (ctx in scrubbed) assertStripped(JSONObject(ctx))
        rig.transport.status = 500
        val from = rig.transport.bodies.size
        core.flush(force = true)
        assertEquals(scrubbed, rig.queue.rows.map { it.ctx })
        assertTrue(rig.transport.bodies.size > from)

        rig.transport.status = 200
        rig.env.time += 2 * Core.BACKOFF_MAX_MS
        core.flush(force = true)
        assertEquals(0, rig.queue.size())

        val sent = rig.transport.bodies.drop(from).map { JSONObject(it) }
        assertTrue(sent.any { namesOf(it).contains("Queued") })
        for (batch in sent) {
            assertValid(batch)
            assertStripped(batch.getJSONObject("ctx"))
            assertFalse(batch.toString().contains(QUEUE_GAID))
        }
        // UTM parametrləri qalır.
        assertEquals(setOf("utm_source", "utm_campaign"), ctxFor(rig, "Queued").getJSONObject("campaign").keySet())
        assertEquals("spring", ctxFor(rig, "Queued").getJSONObject("campaign").getString("utm_campaign"))
    }

    @Test
    fun campaignWithOnlyClickIdsDisappearsFromQueuedRows() {
        val rig = newRig()
        val core = rig.core()
        core.onDeepLink("https://shop.az/p/1?fbclid=FB1")
        core.track("Queued", null, null)
        assertTrue(rig.queue.rows.last().ctx.contains("FB1"))
        core.setConsent(true, false)
        core.flush(force = true)
        val ctx = ctxFor(rig, "Queued")
        assertFalse(ctx.has("campaign"))
        assertStripped(ctx)
        for (batch in rig.transport.posts) assertValid(batch)
    }

    @Test
    fun rowsQueuedWithoutAdsConsentStayAdsFalseAfterRegrant() {
        val rig = newRig(opts(consent = SmartBeeConsent(analytics = true, ads = false), debug = true))
        val core = rig.core()
        core.onDeepLink(LINK)
        core.track("WhileOff", null, null)
        core.setConsent(true, true)
        core.track("AfterGrant", null, null)
        core.flush(force = true)

        val off = ctxFor(rig, "WhileOff")
        assertStripped(off)
        assertEquals(setOf("utm_source", "utm_campaign"), off.getJSONObject("campaign").keySet())

        val on = ctxFor(rig, "AfterGrant")
        assertTrue(on.getJSONObject("consent").getBoolean("ads"))
        assertEquals(QUEUE_GAID, on.getJSONObject("ids").getString("gaid"))
        // Reklam razılığı olmadan gələn klik ID-ləri diskə yazılmır: razılıq sonradan veriləndə üzə çıxmır.
        assertEquals(setOf("utm_source", "utm_campaign"), on.getJSONObject("campaign").keySet())
        assertFalse(namesOf(rig.transport.posts.last { namesOf(it).contains("AfterGrant") }).contains("WhileOff"))
        for (batch in rig.transport.posts) assertValid(batch)
    }

    /** Növbə: razılıqla, razılıqsız və yenidən razılıqla yaranmış sətirlər (hamısı eyni kampaniya ilə). */
    private fun mixedQueue(): Pair<Rig, Core> {
        val rig = newRig()
        val core = rig.core()
        core.onDeepLink(LINK)
        core.track("A", null, null)
        core.setConsent(true, false)
        core.track("B", null, null)
        core.setConsent(true, true)
        core.track("C", null, null)
        assertEquals(0, rig.transport.posts.size)
        return rig to core
    }

    @Test
    fun mixedQueueKeepsRowConsentWhileAdsConsentIsGranted() {
        val (rig, core) = mixedQueue()
        core.flush(force = true)
        // Razılıq geri alınanda növbədə olan sətirlər (A daxil) diskdə təmizlənib: razılıq yenidən veriləndə də
        // reklam üçün yararlı olmur. Yalnız yeni razılıqdan sonra yaranan C reklam razılığı ilə gedir.
        assertEquals(listOf("SessionStart", "AppInstall", "DeepLinkOpen", "A", "B", "C"), rig.transport.posts.flatMap { namesOf(it) })
        for (name in listOf("SessionStart", "AppInstall", "DeepLinkOpen", "A", "B")) assertStripped(ctxFor(rig, name))
        assertEquals(listOf("C"), namesOf(rig.transport.posts.last()))
        assertTrue(ctxFor(rig, "C").getJSONObject("consent").getBoolean("ads"))
        assertEquals(listOf("https://shop.az/p/1?utm_source=fb&utm_campaign=spring"), linkUrls(rig.transport.posts))
        // Razılıq geri alınanda saxlanmış klik ID-ləri diskdən də silinir və yenidən veriləndə qayıtmır.
        assertFalse(ctxFor(rig, "C").getJSONObject("campaign").has("fbclid"))
        for (batch in rig.transport.posts) assertValid(batch)
    }

    @Test
    fun mixedQueueCollapsesIntoOneContextAfterWithdrawal() {
        val (rig, core) = mixedQueue()
        core.setConsent(true, false)
        core.flush(force = true)
        // Kampaniyasız başlanğıc eventləri ayrıca topludadır; qalanları indi yalnız reklam sahələri ilə fərqlənirdi.
        assertEquals(
            listOf(listOf("SessionStart", "AppInstall"), listOf("DeepLinkOpen", "A", "B", "C")),
            rig.transport.posts.map { namesOf(it) },
        )
        for (batch in rig.transport.posts) {
            assertValid(batch)
            assertStripped(batch.getJSONObject("ctx"))
            assertFalse(batch.toString().contains(QUEUE_GAID))
        }
        assertEquals(setOf("utm_source", "utm_campaign"), ctxFor(rig, "C").getJSONObject("campaign").keySet())
        val seqs = rig.transport.events.map { it.getLong("seq") }
        assertEquals(seqs.sorted(), seqs)
    }

    // ---- DeepLinkOpen eventinin ünvanı ----------------------------------------------------------

    private fun linkUrls(batches: List<JSONObject>): List<String> = batches.flatMap { batch ->
        batch.getJSONArray("events").let { a -> (0 until a.length()).map { a.getJSONObject(it) } }
            .filter { it.optString("name") == "DeepLinkOpen" }
            .map { it.getJSONObject("props").getString("url") }
    }

    private fun assertNoClickIds(text: String) {
        for (id in Util.CLICK_IDS) assertFalse("$id: $text", text.contains(id))
    }

    @Test
    fun deepLinkUrlHasNoClickIdsWhenQueuedWithoutAdsConsent() {
        val rig = newRig(opts(consent = SmartBeeConsent(analytics = true, ads = false), debug = true))
        val core = rig.core()
        core.onDeepLink("https://shop.az/p/1?a=1&fbclid=FB1&utm_source=fb&GCLID=G1&gbraid=GB&wbraid=WB&ttclid=TT&msclkid=MS&q=a%20b+c#frag")
        // Klik ID-ləri növbəyə (diskə) də düşmür.
        assertNoClickIds(rig.queue.rows.last().payload)
        assertNoClickIds(rig.queue.rows.last().ctx)

        // Razılıq sonradan verilsə də razılıqsız yaranmış sətir dəyişmir.
        core.setConsent(true, true)
        core.flush(force = true)
        assertEquals(listOf("https://shop.az/p/1?a=1&utm_source=fb&q=a%20b+c"), linkUrls(rig.transport.posts))
        for (body in rig.transport.bodies) assertNoClickIds(body)
        for (batch in rig.transport.posts) assertValid(batch)
    }

    @Test
    fun queuedDeepLinkUrlLosesClickIdsWhenAdsConsentIsWithdrawn() {
        val rig = newRig()
        val core = rig.core()
        core.onDeepLink(LINK)
        core.track("Lead", mapOf("url" to LINK), null)
        val stored = rig.queue.rows.map { it.payload }
        assertTrue(stored.any { it.contains("fbclid") })

        core.setConsent(true, false)
        // Razılıq geri alınan kimi DeepLinkOpen sətirinin ünvanı diskdə də təmizlənir; uğursuz göndəriş onu dəyişmir.
        val scrubbed = rig.queue.rows.map { it.payload }
        assertEquals(stored.size, scrubbed.size)
        assertTrue(scrubbed.none { it.contains("DeepLinkOpen") && it.contains("fbclid") })
        rig.transport.status = 500
        core.flush(force = true)
        assertEquals(scrubbed, rig.queue.rows.map { it.payload })
        assertTrue(rig.transport.bodies.isNotEmpty())

        rig.transport.status = 200
        rig.env.time += 2 * Core.BACKOFF_MAX_MS
        core.flush(force = true)
        assertEquals(0, rig.queue.size())
        assertEquals(listOf("https://shop.az/p/1?utm_source=fb&utm_campaign=spring"), linkUrls(rig.transport.posts))
        for (body in rig.transport.bodies) assertNoClickIds(JSONObject(body).getJSONObject("ctx").toString())
        // Tətbiqin öz eventinin ünvan dəyərindən də klik ID-ləri silinir (veb tracker-in scrubEvents funksiyası kimi).
        val lead = rig.transport.events.first { it.optString("name") == "Lead" }
        assertEquals("https://shop.az/p/1?utm_source=fb&utm_campaign=spring", lead.getJSONObject("props").getString("url"))
        for (batch in rig.transport.posts) assertValid(batch)
    }

    @Test
    fun deepLinkUrlKeepsClickIdsWhileAdsConsentIsGranted() {
        val rig = newRig()
        val core = rig.core()
        core.onDeepLink(LINK)
        core.flush(force = true)
        assertEquals(listOf(LINK), linkUrls(rig.transport.posts))
    }

    @Test
    fun heldDeepLinkLosesClickIdsWhenServerDefaultDeniesAds() {
        // İlk işə düşmə: razılıq hələ məlum deyil, keçid yaddaşda gözləyir; konfiq reklam razılığını rədd edir.
        val rig = Rig(opts(debug = true), fresh = true)
        rig.transport.configBody = """{"enabled":true,"consent_default":{"analytics":true,"ads":false}}"""
        val core = rig.core()
        core.onDeepLink(LINK)
        assertEquals(0, rig.queue.size())
        core.flush(force = true)
        assertEquals(listOf("https://shop.az/p/1?utm_source=fb&utm_campaign=spring"), linkUrls(rig.transport.posts))
        for (body in rig.transport.bodies) assertNoClickIds(body)

        // Sonradan verilən razılıq köhnə sətirə klik ID-lərini qaytarmır (təkrar göndəriş halı).
        rig.transport.posts.clear()
        rig.env.time += Core.LINK_REPEAT_MS
        core.onDeepLink(LINK)
        core.setConsent(true, true)
        core.flush(force = true)
        assertEquals(listOf("https://shop.az/p/1?utm_source=fb&utm_campaign=spring"), linkUrls(rig.transport.posts))
    }

    @Test
    fun contextIsSentUnchangedWhileAdsConsentStaysGranted() {
        val rig = Rig(granted)
        val core = rig.core()
        core.onDeepLink(LINK)
        core.track("Lead", null, null)
        val stored = rig.queue.rows.map { it.ctx }.distinct()
        assertEquals(2, stored.size)
        core.flush(force = true)

        assertEquals(2, rig.transport.posts.size)
        for ((index, batch) in rig.transport.posts.withIndex()) {
            assertValid(batch)
            assertEquals(plain(JSONObject(stored[index])), plain(batch.getJSONObject("ctx")))
        }
        val ctx = ctxFor(rig, "Lead")
        assertTrue(ctx.getJSONObject("consent").getBoolean("ads"))
        assertEquals(setOf("utm_source", "utm_campaign", "fbclid", "gclid"), ctx.getJSONObject("campaign").keySet())
    }
}
