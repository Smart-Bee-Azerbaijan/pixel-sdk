package az.smartbee.pixel

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Təsdiq turu 3: təmizləmə qaydalarının vektorlardan kənar yoxlamaları — uzun ünvanın qısaldılması (D1; eyni girişlər və
 * gözlənilən dəyərlər veb tracker-in `audit3-scrub.test.js` və iOS-un `Audit3ScrubTests.swift` testlərindədir), reklam
 * razılığı geri alınanda ekran adının yenidən təmizlənməsi və yeni qaydaların vaxtı.
 */
class Audit3ScrubTest {
    private val granted = opts(consent = SmartBeeConsent(analytics = true, ads = true), debug = true)
    private val jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTYifQ.c2lnbmF0dXJlMTIz"

    private fun disk(rig: Rig): String = rig.queue.rows.joinToString("\n") { it.ctx + it.payload }

    // ---- D1: uzun ünvanlar veb tracker-dəki kimi qısaldılır ---------------------------------------

    @Test
    fun d1_longUrlsAreCleanedAndShortenedExactlyLikeTheWebTracker() {
        val z5000 = "z".repeat(5000)
        assertEquals(("https://shop.az/p?keep=1&pad=$z5000").take(2048), Util.cleanUrl("https://shop.az/p?token=x&keep=1&pad=$z5000"))
        assertEquals(("https://shop.az/reset/[redacted]/x/y/$z5000").take(2048), Util.cleanUrl("https://shop.az/reset/Xk29LmQa/x/y/$z5000?token=x"))
        assertEquals("https://shop.az/a/b", Util.cleanUrl("https://shop.az/a/b?x=" + "z".repeat(9000) + "#/r"))
        assertEquals("https://shop.az/a/b", Util.cleanUrl("https://shop.az/a/b#/r/" + "z".repeat(9000)))
        assertEquals("https://shop.az/" + "seg/".repeat(508), Util.cleanUrl("https://shop.az/" + "seg/".repeat(3000)))
        assertEquals("https://shop.az/x/", Util.cleanUrl("https://shop.az/x/" + "z".repeat(9000)))
        assertEquals(("myapp://" + "z".repeat(9000)).take(2048), Util.cleanUrl("myapp://" + "z".repeat(9000)))
        // Tam 8192 simvol: qısaldılmır, query təmizlənir.
        val exact = "https://shop.az/p?token=x&keep=" + "z".repeat(8192 - 31)
        assertEquals(8192, exact.length)
        assertEquals(("https://shop.az/p?keep=" + "z".repeat(8192 - 31)).take(2048), Util.cleanUrl(exact))
        // Kampaniya uzun ünvandan da oxunur.
        val campaign = Util.campaignOf("https://shop.az/?utm_source=fb&pad=$z5000&utm_medium=cpc")
        assertEquals(2, campaign?.length())
        assertEquals("fb", campaign?.optString("utm_source"))
        assertEquals("cpc", campaign?.optString("utm_medium"))
        assertEquals("https://shop.az/p", Util.stripClickIds("https://shop.az/p?gclid=x&q=" + "z".repeat(9000)))
    }

    @Test
    fun d1_deepLinkBetween4097And8192CharactersIsTracked() {
        val rig = Rig(granted)
        val core = rig.core()
        val url = "https://shop.az/p?utm_source=fb&token=x&pad=" + "z".repeat(6000)
        assertTrue(url.length in 4097..Util.MAX_URL_LENGTH)
        assertTrue(Util.isLink(url))
        core.onDeepLink(url)
        core.flush(force = true)
        val event = rig.transport.events.first { it.optString("name") == "DeepLinkOpen" }
        assertEquals(("https://shop.az/p?utm_source=fb&pad=" + "z".repeat(6000)).take(2048), event.getJSONObject("props").getString("url"))
        assertEquals("fb", rig.transport.posts.last().getJSONObject("ctx").getJSONObject("campaign").getString("utm_source"))
    }

    // ---- Razılıq: ekran adı da yenidən təmizlənir -------------------------------------------------

    @Test
    fun consent_screenNameIsReCleanedWhenAdsConsentIsWithdrawn() {
        val rig = Rig(granted)
        rig.transport.status = 500
        val core = rig.core()
        core.screen("/kampaniya?fbclid=FB1SECRET&x=1", null)
        core.track("ViewItem", mapOf("value" to 1), null)
        core.flush(force = true)
        assertTrue(disk(rig).contains("FB1SECRET"))

        core.setConsent(true, false)
        // Diskdəki sətirlər dərhal təmizlənir.
        assertFalse(disk(rig).contains("FB1SECRET"))

        // Cari ekran adı sonrakı eventlərə də klik ID-siz yazılır.
        core.track("AddToCart", mapOf("value" to 2), null)
        rig.transport.status = 200
        rig.transport.bodies.clear()
        rig.transport.posts.clear()
        rig.env.time += 2 * Core.BACKOFF_MAX_MS
        core.flush(force = true)
        assertFalse(rig.transport.bodies.joinToString("\n").contains("FB1SECRET"))
        for (name in listOf("ScreenView", "ViewItem", "AddToCart")) {
            val event = rig.transport.events.first { it.optString("name") == name }
            assertEquals(name, "/kampaniya?x=1", event.getJSONObject("screen").getString("name"))
        }
    }

    @Test
    fun consent_screenNameThatIsOnlyAClickIdIsRemoved() {
        val rig = Rig(granted)
        rig.transport.status = 500
        val core = rig.core()
        core.screen("#gclid=G1SECRET", null)
        core.flush(force = true)
        assertTrue(disk(rig).contains("G1SECRET"))
        core.setConsent(true, false)
        assertFalse(disk(rig).contains("G1SECRET"))
        core.track("Later", null, null)
        rig.transport.bodies.clear()
        rig.transport.posts.clear()
        rig.transport.status = 200
        rig.env.time += 2 * Core.BACKOFF_MAX_MS
        core.flush(force = true)
        for (event in rig.transport.events) assertNull(event.optString("name"), event.optJSONObject("screen"))
    }

    @Test
    fun consent_screenNameWithoutClickIdsIsNotTouched() {
        val rig = Rig(granted)
        rig.transport.status = 500
        val core = rig.core()
        core.screen("Kataloq / Çay dəstləri", mapOf("page" to 2))
        core.flush(force = true)
        val before = rig.queue.rows.map { it.payload }
        core.setConsent(true, false)
        assertEquals(before, rig.queue.rows.map { it.payload })
    }

    @Test
    fun consent_screenNameKeepsClickIdsWhileAdsConsentIsGranted() {
        val rig = Rig(granted)
        val core = rig.core()
        core.screen("/kampaniya?fbclid=FB1SECRET&x=1", null)
        core.flush(force = true)
        val event = rig.transport.events.first { it.optString("name") == "ScreenView" }
        assertEquals("/kampaniya?fbclid=FB1SECRET&x=1", event.getJSONObject("screen").getString("name"))
    }

    // ---- Yeni qaydalar: təkrar təmizləmə və vaxt --------------------------------------------------

    @Test
    fun newRulesAreIdempotent() {
        val urls = listOf(
            "https://shop.az/reset;t=$jwt;n=1/x;k=Xk29LmQa", "https://shop.az/reset?dGhpcyBpcyBhIHNlY3JldCB0b2tlbg==", "https://shop.az/p?$jwt=1&keep=1",
            "https://shop.az/p?utm_term=call%20%2B994501234567%20now&utm_content=4111+1111+1111+1111", "https://shop.az/x/t=4111111111111111/y",
            "https://shop.az/confirmation/AZ-778899/Xk29LmQa", "https://shop.az/confirm?order=778899&t=Xk29LmQa", "https://shop.az/2fa/123456",
        )
        for (url in urls) {
            val once = Util.cleanUrl(url)
            assertFalse(url, once == url)
            assertEquals(url, once, Util.cleanUrl(once))
        }
        val texts = listOf(
            "k=$jwt&z=1", "access_token=Xk29LmQa&z=1", "Authorization: Bearer abcDEF123456", "IBAN AZ21NABZ00000000137010001944.",
            "4111 1111  1111/1111", "“$jwt”", "mail user＠shop.az",
        )
        for (text in texts) {
            val once = Util.label(text)
            assertFalse(text, once == text)
            assertEquals(text, once, Util.label(once))
        }
    }

    @Test
    fun newRulesAreLinearOnHostileInput() {
        fun fill(unit: String, size: Int): String = unit.repeat(size / unit.length + 1).take(size)
        val texts = listOf(
            "eyJhbGciOiJIUzI1NiJ9.", "9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c.", "aB3", "aB3dEf9hIj2kLm5nOp8qRs1tUv4wXy7z|", "Bearer ", "Bearer abcDEF123456 ",
            "AZ21NABZ00000000137010001944 ", "AZ21", "a=1&token=x&", "=", "access_token=Xk29LmQa ", "4111  /", "1 - ", "a＠", "Step3ShippingAddress", "a-b_", "a.b",
        )
        val urls = listOf(
            "https://shop.az/reset" to ";t=Xk29LmQa", "https://shop.az/p" to ";", "https://shop.az/p" to ";n=https%3A%2F%2Fa.az%2Freset%2FXk29LmQa7",
            "https://shop.az" to "/confirm", "https://shop.az/confirm" to "/", "https://shop.az" to "/order/confirm/778899", "https://shop.az/x/" to "t=Xk29LmQa=",
            "https://shop.az/reset?" to "dGhpcyBpcyBhIHNlY3JldCB0b2tlbg==&", "https://shop.az/p?" to "$jwt=1&",
            "https://shop.az/p?" to "utm_term=%2B994501234567&utm_content=4111+1111+1111+1111&", "https://shop.az/p?utm_term=" to "+1 ", "https://shop.az" to "/2fa/123456",
        )
        // JIT-in isinməsi ölçməyə düşməsin.
        for (unit in texts) Util.label(fill(unit, 2000))
        for ((head, unit) in urls) Util.cleanUrl(head + fill(unit, 2000))
        val started = System.nanoTime()
        for (unit in texts) {
            Util.label(fill(unit, 200_000))
            Util.clean(mapOf("v" to fill(unit, 200_000)), 4)
        }
        for ((head, unit) in urls) {
            Util.cleanUrl(head + fill(unit, 8000))
            Util.label(head + fill(unit, 8000))
            Util.campaignOf(head + fill(unit, 200_000))
        }
        val millis = (System.nanoTime() - started) / 1_000_000
        assertTrue("took ${millis}ms", millis < 3000)
    }

    @Test
    fun campaignValuesOfStoredCampaignAreCleanedByName() {
        // Saxlanmış kampaniya göndərilməzdən əvvəl yenə təmizlənir: utm dəyərində telefon və kart gizlədilir, klik ID-sində yox.
        val rig = Rig(granted)
        rig.store.map[Core.K_CAMPAIGN] = JSONObject().put("utm_term", "+994501234567").put("utm_content", "4111 1111 1111 1111").put("yclid", "4111111111111111").toString()
        rig.store.map[Core.K_CAMPAIGN_AT] = rig.env.time.toString()
        val core = rig.core()
        core.track("ViewItem", null, null)
        core.flush(force = true)
        val campaign = rig.transport.posts.last().getJSONObject("ctx").getJSONObject("campaign")
        assertEquals("[redacted]", campaign.getString("utm_term"))
        assertEquals("[redacted]", campaign.getString("utm_content"))
        assertEquals("4111111111111111", campaign.getString("yclid"))
    }
}
