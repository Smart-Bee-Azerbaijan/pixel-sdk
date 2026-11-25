import Foundation
import XCTest
@testable import SmartBeePixel

/// Təsdiq turu 4: təmizləmə qaydalarının vektorlardan kənar yoxlamaları — mətndəki ünvanın ardınca durğu işarəsi (N1), boş
/// dəyərli base64 sonluğu (N2), hash marşrutunda matris parametri (N3), sifariş təsdiqi istisnasının daralması (N4), hissənin
/// içindəki hex ardıcıllığı (N8), yeni qaydaların vaxtı və təkrar tətbiqi. Eyni girişlər və gözlənilən dəyərlər veb
/// tracker-in `audit4-scrub.test.js` və Android-in `Audit4ScrubTest.kt` testlərindədir.
final class Audit4ScrubTests: XCTestCase {
    private let s = "https://shop.az"
    private let hex = "9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c"
    private let hex40 = "a3f1c9d27b6e4f0891ab54cd32ef7a10c4d5e6f7"
    private let hex24 = "9f8a7b6c5d4e3f2a1b0c9d8e"
    private let tok = "Zq7Lm2Xp9Rt4"
    // Açar önü hissələrdən yığılır ki, mənbə kodunda real açara bənzər sətir olmasın.
    private let key = "sk_" + "live_" + "51HabcDEF12345xyz"
    private let gclid = "EAIaIQobChMIabcdefghijklmnopqrstuvwxyz0123456789ABCD_BwE"
    private let luhn = "b170aaddf797447674180765e18cd758"
    private let r = "[redacted]"

    private func head(_ text: String, _ count: Int) -> String {
        return String(decoding: Array(text.utf16.prefix(count)), as: UTF16.self)
    }

    /// `props` mətn dəyərinin təmizlənmiş halı.
    private func text(_ value: String) -> String? {
        return (Util.cleanObject(["v": value]) ?? [:])["v"] as? String
    }

    /// Giriş və gözlənilən nəticə.
    private var urls: [(String, String)] {
        return [
            (s + "/reset?c2VjcmV0LXJlc2V0LTE=", s + "/reset?" + r),
            (s + "/#/verify/c2VjcmV0LXJlc2V0LTE=", s + "/#/verify/" + r),
            (s + "/reset?YWJjZGVmZ2hpams+bG1ub3A/cXJz==", s + "/reset?" + r),
            (s + "/#/reset;t=" + tok, s + "/#/reset;t=" + r),
            (s + "/order/confirm/" + tok, s + "/order/confirm/" + r),
            (s + "/checkout/confirm-email/" + tok, s + "/checkout/confirm-email/" + r),
            (s + "/payment/confirmation/879609", s + "/payment/confirmation/" + r),
            (s + "/orders/confirm?t=" + tok, s + "/orders/confirm?t=" + r),
            (s + "/confirm?id=" + tok, s + "/confirm?id=" + r),
            (s + "/confirm?ref=" + tok, s + "/confirm?ref=" + r),
            (s + "/a?k=" + hex40 + ".", s + "/a?k=" + r),
            (s + "/a?k=v1:" + hex40, s + "/a?k=" + r),
            (s + "/a/" + hex40 + ".json", s + "/a/" + r),
            (s + "/reset-" + hex40 + hex24, s + "/" + r),
        ]
    }

    private var texts: [(String, String)] {
        return [
            ("Reset link: " + s + "/a?k=" + hex40 + ".", "Reset link: " + s + "/a?k=" + r),
            ("{\"url\":\"" + s + "/x?k=" + hex + "\"}", "{\"url\":\"" + s + "/x?k=" + r),
            ("(" + s + "/a?v=" + key + ")", "(" + s + "/a?v=" + r + ")"),
            ("see /dl/" + hex + ", ok", "see /dl/" + r + " ok"),
            (s + "/a/" + hex + ".", s + "/a/" + r),
            (luhn, r),
            ("id " + luhn + ", card 4111 1111 1111 1111.", "id " + r + ", card " + r + "."),
            ("#v=" + key + ")", "#v=" + r + ")"),
            (s + "/a?v=x:" + key + "&keep=1", s + "/a?v=x:" + r + "&keep=1"),
        ]
    }

    func testFoundLeaksAreMasked() {
        for item in urls { XCTAssertEqual(Util.cleanUrl(item.0), item.1, item.0) }
        for item in texts {
            XCTAssertEqual(text(item.0), item.1, item.0)
            XCTAssertEqual(Util.label(item.0), item.1, item.0)
        }
    }

    func testOrdinaryUrlsAndTextsAreKept() {
        let paths = [
            "/auth/login", "/session/schedule", "/join/team-name", "/product/iphone-15-pro-max-256gb", "/p/SKU-12345-BLK",
            "/products/550e8400-e29b-41d4-a716-446655440000", "/p/550e8400e29b41d4a716446655440000", "/order/2026112500123", "/orders/AZ-778899/track",
            "/order/confirm/2026112500123", "/orders/confirmation/AZ-778899", "/checkout/confirmation/100045678", "/search?q=red+shoes+size+42&price=10-200",
            "/p?q=", "/p?q=&debug=", "/price/1299.99", "/commit/3f9a2b1", "/commit/3f9a2b1c4d5e6f708192a3b4c5d6e7f", "/img/" + hex + ".jpg", "/#/p;color=red;size=42",
            "/confirm?order_id=778899", "/order/confirm/thank-you", "/login?returnUrl=&next=", "/booking/confirm/AZ-778899/details",
            "/payment/confirmation/2026112500123", "/payment/success/778899",
        ]
        for path in paths { XCTAssertEqual(Util.cleanUrl(s + path), s + path) }
        let kept = [
            "Order 2026112500123 confirmed", "SKU ABC-12345-XYZ", s + "/p/iphone-15?color=black", "https://cdn.shop.az/img/" + hex + ".jpg",
            "see " + s + "/p?gclid=" + gclid + "&x=1, ok", s + "/p?fbclid=" + gclid, "commit 3f9a2b1", "price=1299.99&currency=AZN", "550e8400e29b41d4a716446655440000",
            s + "/p?next=%2Fproducts%2F550e8400e29b41d4a716446655440000", s + "/p?cursor=eyJpZCI6MTIzNDU2Nzg5MCwidHMiOjE3MDAwMDAwMDB9&q=1",
        ]
        for value in kept { XCTAssertEqual(text(value), value) }
    }

    func testN1ClickIdInATextUrlIsKeptWithAdsConsentAndRemovedWithoutIt() {
        XCTAssertEqual(Util.label("see " + s + "/p?gclid=" + gclid + "&x=1, ok", ads: false), "see " + s + "/p?x=1, ok")
        XCTAssertEqual(Util.label(s + "/p?fbclid=" + gclid, ads: false), s + "/p")
        // Klik ID-sindən sonrakı parametr yenə yoxlanır.
        XCTAssertEqual(text("(" + s + "/p?gclid=" + gclid + "&v=x:" + key + ")"), "(" + s + "/p?gclid=" + gclid + "&v=x:" + r + ")")
    }

    func testNewRulesAreIdempotent() {
        for item in urls {
            let once = Util.cleanUrl(item.0)
            XCTAssertEqual(Util.cleanUrl(once), once, item.0)
        }
        for item in texts {
            let once = Util.label(item.0)
            XCTAssertEqual(Util.label(once), once, item.0)
        }
    }

    func testNewRulesAreLinearOnHostileInput() {
        func fill(_ unit: String, _ size: Int) -> String {
            return head(String(repeating: unit, count: size / unit.utf16.count + 1), size)
        }
        let units = [
            s + "/a?k=" + hex40 + ". ", "%2F", "gclid=x&", "gclid=", luhn + " ", "4111111111111111a", "4111111111111111-", hex40 + ".", head(hex, 31) + "g", "#a=1 ",
            "/dl/" + hex + ", ", "x?a=1. ",
        ]
        let longUrls: [(String, String)] = [
            (s + "/#/", "a;x=1/"), (s + "/#/reset", ";t=Xk29LmQa"), (s + "/#/a", ";"), (s, "/payment/confirm/879609"), (s + "/reset-", "z"), (s + "/", "reset-"),
            (s + "/reset?", "abc=&"), (s + "/reset?", "ab/cd+ef=&"), (s + "/reset?", "ab/"), (s + "/a/", hex + ":"), (s + "/order/confirm?", "id=778899&ref=Zq7&"),
            (s + "/p?x=", "%2F"), (s + "/p?", "gclid=x&"),
        ]
        let started = Date()
        for unit in units {
            _ = Util.label(fill(unit, 200_000))
            _ = Util.cleanObject(["v": fill(unit, 200_000)])
        }
        for item in longUrls {
            _ = Util.cleanUrl(item.0 + fill(item.1, 8000))
            _ = Util.label(item.0 + fill(item.1, 8000))
            _ = Util.cleanObject(["v": item.0 + fill(item.1, 8000)])
        }
        // Xətti alqoritm bütün girişləri saniyələrdən tez bitirir; kvadratik olsaydı dəqiqələr çəkərdi.
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }
}
