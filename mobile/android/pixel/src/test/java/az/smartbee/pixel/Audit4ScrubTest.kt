package az.smartbee.pixel

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Təsdiq turu 4: təmizləmə qaydalarının vektorlardan kənar yoxlamaları — mətndəki ünvanın ardınca durğu işarəsi (N1), boş
 * dəyərli base64 sonluğu (N2), hash marşrutunda matris parametri (N3), sifariş təsdiqi istisnasının daralması (N4), hissənin
 * içindəki hex ardıcıllığı (N8), yeni qaydaların vaxtı və təkrar tətbiqi. Eyni girişlər və gözlənilən dəyərlər veb
 * tracker-in `audit4-scrub.test.js` və iOS-un `Audit4ScrubTests.swift` testlərindədir.
 */
class Audit4ScrubTest {
    private val s = "https://shop.az"
    private val hex = "9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c"
    private val hex40 = "a3f1c9d27b6e4f0891ab54cd32ef7a10c4d5e6f7"
    private val hex64 = hex40 + hex.take(24)
    private val tok = "Zq7Lm2Xp9Rt4"

    // Açar önü hissələrdən yığılır ki, mənbə kodunda real açara bənzər sətir olmasın.
    private val key = "sk_" + "live_" + "51HabcDEF12345xyz"
    private val gclid = "EAIaIQobChMIabcdefghijklmnopqrstuvwxyz0123456789ABCD_BwE"
    private val luhn = "b170aaddf797447674180765e18cd758"
    private val r = "[redacted]"

    /** Giriş → gözlənilən nəticə. */
    private val urls = listOf(
        "$s/reset?c2VjcmV0LXJlc2V0LTE=" to "$s/reset?$r",
        "$s/#/verify/c2VjcmV0LXJlc2V0LTE=" to "$s/#/verify/$r",
        "$s/reset?YWJjZGVmZ2hpams+bG1ub3A/cXJz==" to "$s/reset?$r",
        "$s/#/reset;t=$tok" to "$s/#/reset;t=$r",
        "$s/order/confirm/$tok" to "$s/order/confirm/$r",
        "$s/checkout/confirm-email/$tok" to "$s/checkout/confirm-email/$r",
        "$s/payment/confirmation/879609" to "$s/payment/confirmation/$r",
        "$s/orders/confirm?t=$tok" to "$s/orders/confirm?t=$r",
        "$s/confirm?id=$tok" to "$s/confirm?id=$r",
        "$s/confirm?ref=$tok" to "$s/confirm?ref=$r",
        "$s/a?k=$hex40." to "$s/a?k=$r",
        "$s/a?k=v1:$hex40" to "$s/a?k=$r",
        "$s/a/$hex40.json" to "$s/a/$r",
        "$s/reset-$hex64" to "$s/$r",
    )
    private val texts = listOf(
        "Reset link: $s/a?k=$hex40." to "Reset link: $s/a?k=$r",
        "{\"url\":\"$s/x?k=$hex\"}" to "{\"url\":\"$s/x?k=$r",
        "($s/a?v=$key)" to "($s/a?v=$r)",
        "see /dl/$hex, ok" to "see /dl/$r ok",
        "$s/a/$hex." to "$s/a/$r",
        luhn to r,
        "id $luhn, card 4111 1111 1111 1111." to "id $r, card $r.",
        "#v=$key)" to "#v=$r)",
        "$s/a?v=x:$key&keep=1" to "$s/a?v=x:$r&keep=1",
    )

    @Test
    fun foundLeaksAreMasked() {
        for ((url, expected) in urls) assertEquals(url, expected, Util.cleanUrl(url))
        for ((text, expected) in texts) {
            assertEquals(text, expected, Util.clean(text, 4))
            assertEquals(text, expected, Util.label(text))
        }
    }

    @Test
    fun ordinaryUrlsAndTextsAreKept() {
        val paths = listOf(
            "/auth/login", "/session/schedule", "/join/team-name", "/product/iphone-15-pro-max-256gb", "/p/SKU-12345-BLK",
            "/products/550e8400-e29b-41d4-a716-446655440000", "/p/550e8400e29b41d4a716446655440000", "/order/2026112500123", "/orders/AZ-778899/track",
            "/order/confirm/2026112500123", "/orders/confirmation/AZ-778899", "/checkout/confirmation/100045678", "/search?q=red+shoes+size+42&price=10-200",
            "/p?q=", "/p?q=&debug=", "/price/1299.99", "/commit/3f9a2b1", "/commit/3f9a2b1c4d5e6f708192a3b4c5d6e7f", "/img/$hex.jpg", "/#/p;color=red;size=42",
            "/confirm?order_id=778899", "/order/confirm/thank-you", "/login?returnUrl=&next=", "/booking/confirm/AZ-778899/details",
            "/payment/confirmation/2026112500123", "/payment/success/778899",
        )
        for (path in paths) assertEquals(s + path, Util.cleanUrl(s + path))
        val kept = listOf(
            "Order 2026112500123 confirmed", "SKU ABC-12345-XYZ", "$s/p/iphone-15?color=black", "https://cdn.shop.az/img/$hex.jpg",
            "see $s/p?gclid=$gclid&x=1, ok", "$s/p?fbclid=$gclid", "commit 3f9a2b1", "price=1299.99&currency=AZN", "550e8400e29b41d4a716446655440000",
            "$s/p?next=%2Fproducts%2F550e8400e29b41d4a716446655440000", "$s/p?cursor=eyJpZCI6MTIzNDU2Nzg5MCwidHMiOjE3MDAwMDAwMDB9&q=1",
        )
        for (text in kept) assertEquals(text, Util.clean(text, 4))
    }

    @Test
    fun n1_clickIdInATextUrlIsKeptWithAdsConsentAndRemovedWithoutIt() {
        assertEquals("see $s/p?x=1, ok", Util.label("see $s/p?gclid=$gclid&x=1, ok", ads = false))
        assertEquals("$s/p", Util.label("$s/p?fbclid=$gclid", ads = false))
        // Klik ID-sindən sonrakı parametr yenə yoxlanır.
        assertEquals("($s/p?gclid=$gclid&v=x:$r)", Util.clean("($s/p?gclid=$gclid&v=x:$key)", 4))
    }

    @Test
    fun newRulesAreIdempotent() {
        for ((url, _) in urls) {
            val once = Util.cleanUrl(url)
            assertEquals(url, once, Util.cleanUrl(once))
        }
        for ((text, _) in texts) {
            val once = Util.label(text)
            assertEquals(text, once, Util.label(once))
        }
    }

    @Test
    fun newRulesAreLinearOnHostileInput() {
        fun fill(unit: String, size: Int): String = unit.repeat(size / unit.length + 1).take(size)
        val units = listOf(
            "$s/a?k=$hex40. ", "%2F", "gclid=x&", "gclid=", "$luhn ", "4111111111111111a", "4111111111111111-", "$hex40.", hex.take(31) + "g", "#a=1 ",
            "/dl/$hex, ", "x?a=1. ",
        )
        val longUrls = listOf(
            "$s/#/" to "a;x=1/", "$s/#/reset" to ";t=Xk29LmQa", "$s/#/a" to ";", s to "/payment/confirm/879609", "$s/reset-" to "z", "$s/" to "reset-",
            "$s/reset?" to "abc=&", "$s/reset?" to "ab/cd+ef=&", "$s/reset?" to "ab/", "$s/a/" to "$hex:", "$s/order/confirm?" to "id=778899&ref=Zq7&",
            "$s/p?x=" to "%2F", "$s/p?" to "gclid=x&",
        )
        // JIT-in isinməsi ölçməyə düşməsin.
        for (unit in units) Util.label(fill(unit, 2000))
        for ((head, unit) in longUrls) Util.cleanUrl(head + fill(unit, 2000))
        val started = System.nanoTime()
        for (unit in units) {
            Util.label(fill(unit, 200_000))
            Util.clean(mapOf("v" to fill(unit, 200_000)), 4)
        }
        for ((head, unit) in longUrls) {
            Util.cleanUrl(head + fill(unit, 8000))
            Util.label(head + fill(unit, 8000))
            Util.clean(head + fill(unit, 8000), 4)
        }
        val millis = (System.nanoTime() - started) / 1_000_000
        assertTrue("took ${millis}ms", millis < 3000)
    }
}
