package az.smartbee.pixel

import com.networknt.schema.InputFormat
import com.networknt.schema.JsonSchemaFactory
import com.networknt.schema.SpecVersion
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

private val IDENTITY_KEYS = listOf(Core.K_ANON, Core.K_USER, Core.K_SESSION, Core.K_SEQ, Core.K_CAMPAIGN)

/** Razılıq, ekran, keçid, kampaniya, göndərmə və sessiya qaydaları (iOS nüvəsi ilə eyni davranış). */
class CoreRulesTest {
    private val schema = JsonSchemaFactory.getInstance(SpecVersion.VersionFlag.V202012)
        .getSchema(File(System.getProperty("spec.dir") ?: error("spec.dir is not set"), "schema/batch.v1.schema.json").readText())

    private fun assertValid(batch: JSONObject) {
        val errors = schema.validate(batch.toString(), InputFormat.JSON)
        assertTrue("schema errors: $errors", errors.isEmpty())
    }

    // ---- Razılıq: serverin consent_default dəyəri ----------------------------------------------

    @Test
    fun firstLaunchStoresAndSendsNothingUntilConfigArrives() {
        val rig = Rig(fresh = true)
        rig.transport.configStatus = -1
        val core = rig.core()
        core.onForeground()
        core.identify("user-1", null)
        core.onDeepLink("https://shop.az/?utm_source=fb")
        core.track("Lead", null, null)
        core.flush(force = true)
        core.onBackground()

        assertEquals(0, rig.transport.posts.size)
        assertEquals(0, rig.queue.size())
        assertNull(core.anonymousId)
        assertTrue("diskə heç nə yazılmamalıdır: ${rig.store.map}", rig.store.map.isEmpty())

        // Server analitikaya susmaya görə icazə vermir: gözləyən hər şey atılır.
        rig.transport.configStatus = 200
        rig.transport.configBody = """{"enabled":true,"consent_default":{"analytics":false,"ads":false}}"""
        rig.env.time += Core.BACKOFF_MAX_MS
        core.flush()
        core.track("Lead", null, null)
        core.flush(force = true)
        assertEquals(0, rig.transport.posts.size)
        assertEquals(0, rig.queue.size())
        assertNull(core.anonymousId)
        for (k in IDENTITY_KEYS + Core.K_APP_VERSION) assertNull(k, rig.store.get(k))
        assertNull("server seçimi istifadəçi seçimi kimi saxlanmır", rig.store.get(Core.K_CONSENT))

        // Növbəti işə düşmədə keşdəki konfiq dərhal tətbiq olunur.
        val again = rig.core()
        again.track("Lead", null, null)
        again.flush(force = true)
        assertEquals(0, rig.transport.posts.size)
        assertNull(rig.store.get(Core.K_ANON))
    }

    @Test
    fun firstLaunchReleasesHeldEventsWhenConfigAllowsAnalytics() {
        val rig = Rig(fresh = true)
        rig.transport.configStatus = -1
        val core = rig.core()
        core.track("Lead", null, null)
        core.flush(force = true)
        assertEquals(0, rig.transport.posts.size)
        // Uğursuz cəhddən sonra konfiq hər flush-da yenidən istənmir.
        val calls = rig.transport.configCalls
        core.flush(force = true)
        assertEquals(calls, rig.transport.configCalls)

        rig.transport.configStatus = 200
        rig.transport.configBody = """{"enabled":true,"consent_default":{"analytics":true,"ads":false}}"""
        rig.env.time += 60_000
        core.flush()
        assertEquals(listOf("SessionStart", "AppInstall", "Lead"), rig.transport.names)
        assertEquals(1, rig.transport.posts.size)
        val consent = rig.transport.posts[0].getJSONObject("ctx").getJSONObject("consent")
        assertTrue(consent.getBoolean("analytics"))
        assertFalse(consent.getBoolean("ads"))
        assertValid(rig.transport.posts[0])
        assertNotNull(core.anonymousId)
        assertEquals(core.anonymousId, rig.store.get(Core.K_ANON))
        assertEquals(core.anonymousId, rig.transport.events[0].getString("anon_id"))
    }

    @Test
    fun heldEventsAreBoundedAndExplicitConsentSettlesThem() {
        val granted = Rig(fresh = true)
        granted.transport.configStatus = -1
        val a = granted.core()
        for (i in 0 until Core.MAX_HELD + 50) a.track("Lead", mapOf("i" to i), null)
        a.setConsent(true, true)
        assertEquals(Core.MAX_HELD, granted.queue.size())
        assertEquals("11", granted.store.get(Core.K_CONSENT))
        assertEquals(a.anonymousId, granted.store.get(Core.K_ANON))
        a.flush(force = true)
        assertEquals(Core.MAX_HELD + 49, granted.transport.events.last().getJSONObject("props").getInt("i"))

        val denied = Rig(fresh = true)
        denied.transport.configStatus = -1
        val b = denied.core()
        b.track("Lead", null, null)
        b.setConsent(false, false)
        b.flush(force = true)
        assertEquals(0, denied.queue.size())
        assertEquals(0, denied.transport.posts.size)
        assertEquals(mapOf(Core.K_CONSENT to "00"), denied.store.map)
    }

    @Test
    fun initConsentOptionSkipsTheWaitOnFirstLaunch() {
        val rig = Rig(opts(consent = SmartBeeConsent(analytics = true, ads = true)), fresh = true)
        rig.transport.configStatus = -1
        val core = rig.core()
        core.track("Lead", null, null)
        core.flush(force = true)
        assertEquals(listOf("SessionStart", "AppInstall", "Lead"), rig.transport.names)
        assertEquals(core.anonymousId, rig.store.get(Core.K_ANON))
    }

    @Test
    fun changedConsentDefaultAppliesAsSoonAsConfigIsFetched() {
        val rig = Rig()
        val core = rig.core()
        core.identify("user-1", null)
        core.onDeepLink("https://shop.az/?utm_source=fb")
        core.track("Lead", null, null)
        assertTrue(rig.queue.size() > 0)
        val before = core.anonymousId

        rig.transport.configBody = """{"enabled":true,"consent_default":{"analytics":false,"ads":false}}"""
        core.refreshConfig()
        assertEquals(0, rig.queue.size())
        assertNull(core.anonymousId)
        for (k in IDENTITY_KEYS) assertNull(k, rig.store.get(k))
        core.track("Lead", null, null)
        core.flush(force = true)
        assertEquals(0, rig.transport.posts.size)

        // Server yenidən icazə verəndə köhnə identifikator qayıtmır.
        rig.env.time += 3_600_001
        rig.transport.configBody = """{"enabled":true,"consent_default":{"analytics":true,"ads":true}}"""
        core.refreshConfig()
        core.track("Lead", null, null)
        core.flush(force = true)
        val lead = rig.transport.events.last()
        assertNotEquals(before, lead.getString("anon_id"))
        assertFalse(lead.has("user_id"))
        assertEquals(lead.getString("anon_id"), rig.store.get(Core.K_ANON))
    }

    @Test
    fun appAndUserConsentChoicesAreNotOverriddenByConfig() {
        val denying = """{"enabled":true,"consent_default":{"analytics":false,"ads":false}}"""

        val byOption = Rig(opts(consent = SmartBeeConsent(analytics = true, ads = true)))
        byOption.transport.configBody = denying
        val a = byOption.core()
        a.refreshConfig()
        a.track("Lead", null, null)
        a.flush(force = true)
        assertTrue(byOption.transport.names.contains("Lead"))

        val byUser = Rig()
        byUser.store.put(Core.K_CONSENT, "10")
        byUser.transport.configBody = denying
        val b = byUser.core()
        b.refreshConfig()
        b.track("Lead", null, null)
        b.flush(force = true)
        assertTrue(byUser.transport.names.contains("Lead"))
        assertNotNull(byUser.store.get(Core.K_ANON))
    }

    @Test
    fun startWipesLeftoverIdentityWhenAnalyticsResolvesToFalse() {
        val rig = Rig()
        rig.store.put(Core.K_CONFIG, """{"enabled":true,"consent_default":{"analytics":false,"ads":false}}""")
        rig.store.put(Core.K_ANON, "old-anon")
        rig.store.put(Core.K_USER, "user-1")
        rig.store.put(Core.K_SESSION, "s1|1")
        rig.store.put(Core.K_SEQ, "7")
        rig.store.put(Core.K_CAMPAIGN, """{"utm_source":"fb"}""")
        rig.queue.add("{}", """{"id":"x"}""")
        val core = rig.core()
        assertNull(core.anonymousId)
        assertEquals(0, rig.queue.size())
        for (k in IDENTITY_KEYS) assertNull(k, rig.store.get(k))
    }

    @Test
    fun regrantingConsentCreatesNewAnonymousId() {
        val rig = Rig()
        val core = rig.core()
        val before = core.anonymousId
        core.setConsent(false, false)
        assertNull(core.anonymousId)
        core.setConsent(true, true)
        assertNotNull(core.anonymousId)
        assertNotEquals(before, core.anonymousId)
        assertEquals(core.anonymousId, rig.store.get(Core.K_ANON))
        // Razılıq dəyişmədən təkrar çağırış identifikatoru dəyişmir.
        val current = core.anonymousId
        core.setConsent(true, false)
        assertEquals(current, core.anonymousId)
    }

    // ---- Ekran ---------------------------------------------------------------------------------

    @Test
    fun automaticScreenNameNeverReplacesManualOne() {
        val rig = Rig()
        val core = rig.core()
        core.screen("ProductDetail", null)
        core.screen("MainActivity", null, Core.ORIGIN_AUTO)
        core.track("AddToCart", null, null)
        core.flush(force = true)
        assertEquals(1, rig.transport.names.count { it == "ScreenView" })
        assertEquals("ProductDetail", rig.transport.events.last().getJSONObject("screen").getString("name"))
    }

    @Test
    fun automaticScreensAreOffWhenAutoEventsAreDisabledOrInWrappers() {
        val off = Rig(opts(autoEvents = false))
        val a = off.core()
        a.screen("MainActivity", null, Core.ORIGIN_AUTO)
        a.track("Lead", null, null)
        a.flush(force = true)
        assertEquals(listOf("Lead"), off.transport.names)
        assertFalse(off.transport.events.last().has("screen"))

        val wrapped = Rig(opts(wrapper = "react-native", wrapperVersion = "1.0.0"))
        val b = wrapped.core()
        b.screen("MainActivity", null, Core.ORIGIN_AUTO)
        b.track("Lead", null, null)
        b.screen("Cart", null)
        b.flush(force = true)
        assertEquals(listOf("SessionStart", "AppInstall", "Lead", "ScreenView"), wrapped.transport.names)
        assertFalse(wrapped.transport.events[2].has("screen"))
        assertEquals("Cart", wrapped.transport.events[3].getJSONObject("screen").getString("name"))
    }

    // ---- AppInstall ----------------------------------------------------------------------------

    @Test
    fun existingUsersDoNotGetAppInstallWhenSdkIsAddedInAnUpdate() {
        val rig = Rig()
        rig.env.firstInstall = false
        rig.core().flush(force = true)
        assertFalse(rig.transport.names.contains("AppInstall"))
        assertEquals("1.2.3|45", rig.store.get(Core.K_APP_VERSION))

        rig.env.version = "1.3.0"
        rig.core().flush(force = true)
        assertEquals(1, rig.transport.names.count { it == "AppUpdate" })
    }

    // ---- Keçidlər və kampaniya -----------------------------------------------------------------

    @Test
    fun onlyRealLinksAreTrackedAsDeepLinks() {
        val rig = Rig()
        val core = rig.core()
        val rejected = listOf(
            "tel:+994501234567", "tel://+994501234567?utm_source=x", "sms:+994501234567?body=hi", "smsto:+994501234567",
            "mailto:user@example.com?subject=x&utm_source=x", "geo:40.4093,49.8671?q=home", "content://contacts/people/1?utm_source=x",
            "file:///sdcard/secret.pdf", "data:text/plain;base64,QQ==", "intent://scan/#Intent;scheme=zxing;end",
            "CONTENT://media/external/images/1", "myapp:product/1", "product/1?utm_source=x", "",
        )
        for (url in rejected) core.onDeepLink(url)
        core.flush(force = true)
        assertFalse(rig.transport.names.contains("DeepLinkOpen"))
        assertNull(rig.store.get(Core.K_CAMPAIGN))
        assertFalse(rig.transport.bodies.joinToString().contains("994501234567"))

        core.onDeepLink("https://shop.az/p/1?utm_source=fb")
        core.onDeepLink("HTTP://shop.az/p/2")
        core.onDeepLink("myapp://product/3")
        core.onDeepLink("my.app+x-1:///product/4")
        core.flush(force = true)
        val urls = rig.transport.events.filter { it.optString("name") == "DeepLinkOpen" }.map { it.getJSONObject("props").getString("url") }
        assertEquals(listOf("https://shop.az/p/1?utm_source=fb", "HTTP://shop.az/p/2", "myapp://product/3", "my.app+x-1:///product/4"), urls)
        assertEquals("""{"utm_source":"fb"}""", rig.store.get(Core.K_CAMPAIGN))
    }

    @Test
    fun repeatedDeepLinkWithinFiveSecondsCountsOnce() {
        val rig = Rig()
        val core = rig.core()
        core.onDeepLink("myapp://product/1?utm_source=fb")
        rig.env.time += 4_999
        core.onDeepLink("myapp://product/1?utm_source=fb")
        core.onDeepLink("myapp://product/2")
        rig.env.time += Core.LINK_REPEAT_MS
        core.onDeepLink("myapp://product/2")
        // Saat geri çəkilibsə keçid itmir.
        rig.env.time -= 60_000
        core.onDeepLink("myapp://product/2")
        // Araya başqa keçid düşübsə əvvəlki yenidən sayılır.
        core.onDeepLink("myapp://product/3")
        core.onDeepLink("myapp://product/2")
        core.flush(force = true)
        val urls = rig.transport.events.filter { it.optString("name") == "DeepLinkOpen" }.map { it.getJSONObject("props").getString("url") }
        assertEquals(
            listOf(
                "myapp://product/1?utm_source=fb", "myapp://product/2", "myapp://product/2", "myapp://product/2",
                "myapp://product/3", "myapp://product/2",
            ),
            urls,
        )
        rig.transport.posts.forEach { assertValid(it) }
    }

    @Test
    fun repeatedDeepLinkIsDroppedEvenWhenTheEventIsSwitchedOff() {
        // Təkrar qaydası eventdən asılı deyil: söndürülmüş `deeplinks` ilə də kampaniya bir dəfə yazılır.
        val rig = Rig()
        rig.store.put(Core.K_CONFIG, """{"enabled":true,"auto":{"deeplinks":false}}""")
        val core = rig.core()
        core.onDeepLink("myapp://product/1?utm_source=fb")
        rig.store.remove(Core.K_CAMPAIGN)
        core.onDeepLink("myapp://product/1?utm_source=fb")
        assertNull(rig.store.get(Core.K_CAMPAIGN))
        rig.env.time += Core.LINK_REPEAT_MS
        core.onDeepLink("myapp://product/1?utm_source=fb")
        assertEquals("""{"utm_source":"fb"}""", rig.store.get(Core.K_CAMPAIGN))
    }

    @Test
    fun clickIdsAreStrippedFromUrlWithoutTouchingTheRest() {
        assertEquals("https://a.az/", Util.stripClickIds("https://a.az/?fbclid=1"))
        // Hash marşrutunun query-sindən də çıxır; marşrut olmayan fraqment ünvanda qalmır (veb tracker ilə eyni qayda).
        assertEquals("https://a.az/p?x=1#/f?y=1", Util.stripClickIds("https://a.az/p?x=1&fbclid=1#/f?gclid=2&y=1"))
        assertEquals("https://a.az/p?x=1", Util.stripClickIds("https://a.az/p?x=1&fbclid=1#f?gclid=2"))
        assertEquals("myapp://p?utm_source=fb", Util.stripClickIds("myapp://p?FbClId=1&utm_source=fb"))
        assertEquals("https://a.az/p", Util.stripClickIds("https://a.az/p?%66bclid=1&gclid=2&gbraid=3&wbraid=4&ttclid=5&msclkid=6"))
        assertEquals("https://a.az/p?a=1&b=2", Util.stripClickIds("https://a.az/p?a=1&gclid&b=2"))
        for (same in listOf(
            "https://a.az/p?x=%41&y=a+b&utm_source=fb&z=%D9%85", "https://a.az/p?fbclidx=1&xfbclid=2", "https://a.az/p",
            "https://a.az/p?a==1", "myapp://p#/x", "",
        )) {
            assertEquals(same, Util.stripClickIds(same))
        }
    }

    @Test
    fun campaignValuesAreCappedWithoutSplittingSurrogatesAndNulIsStripped() {
        val smile = "😀"
        val campaign = Util.campaignOf(
            "https://a.az/?utm_source=" + "x".repeat(600) + "&utm_medium=a%00b&utm_term=%00&utm_campaign=" + smile.repeat(300) +
                "&utm_content=" + "y".repeat(511) + smile,
        )!!
        // Hədd veb tracker-dəki kimi 512 UTF-16 vahididir; surroqat cütü ortadan bölünmür.
        assertEquals(512, campaign.getString("utm_source").length)
        assertEquals("y".repeat(511), campaign.getString("utm_content"))
        assertEquals("ab", campaign.getString("utm_medium"))
        assertFalse(campaign.has("utm_term"))
        val emoji = campaign.getString("utm_campaign")
        assertEquals(256, emoji.codePointCount(0, emoji.length))
        assertEquals(512, emoji.length)
    }

    @Test
    fun oversizedCampaignIsDroppedInsteadOfPoisoningEveryBatch() {
        // 8192 simvoldan uzun keçid heç emal olunmur, ona görə konteksti aşan kampaniya yalnız saxlanmış dəyərdən gələ
        // bilər (köhnə versiyadan qalan və ya pozulmuş yaddaş). 15 açar x 256 dörd baytlıq simvol: təmizləmədən sonra
        // da (hər dəyər 512 UTF-16 vahidi) kontekst serverin 8 KB həddini aşır.
        val names = listOf("utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content") + Util.CLICK_IDS
        val stored = JSONObject()
        for (name in names) stored.put(name, "😀".repeat(256))
        assertTrue(Util.utf8Size(stored.toString()) > Core.MAX_CTX_BYTES)
        val rig = Rig()
        rig.store.put(Core.K_CAMPAIGN, stored.toString())
        rig.store.put(Core.K_CAMPAIGN_AT, rig.env.time.toString())
        val core = rig.core()
        core.track("Lead", null, null)
        // Kampaniya həqiqətən oxunub və atılıb (test boş keçmir): yaddaşdan silinib və sazlama loquna yazılıb.
        assertTrue(rig.env.logs.toString(), rig.env.logs.any { it.contains("campaign too large") })
        assertNull(rig.store.get(Core.K_CAMPAIGN))
        assertNull(rig.store.get(Core.K_CAMPAIGN_AT))
        assertTrue(rig.queue.rows.isNotEmpty())
        for (row in rig.queue.rows) assertTrue(Util.utf8Size(row.ctx) <= Core.MAX_CTX_BYTES)
        core.flush(force = true)
        assertTrue(rig.transport.posts.isNotEmpty())
        for (post in rig.transport.posts) {
            assertFalse(post.getJSONObject("ctx").has("campaign"))
            assertTrue(Util.utf8Size(post.getJSONObject("ctx").toString()) <= Core.MAX_CTX_BYTES)
            assertValid(post)
        }
        assertTrue(rig.transport.names.contains("Lead"))

        // Hədd daxilindəki kampaniya saxlanır və göndərilir (dəyərlər 512 simvola kəsilir).
        core.onDeepLink("https://shop.az/?utm_source=" + "x".repeat(600) + "&gclid=" + "g".repeat(600))
        core.track("Lead", null, null)
        core.flush(force = true)
        val campaign = rig.transport.posts.last().getJSONObject("ctx").getJSONObject("campaign")
        assertEquals(512, campaign.getString("utm_source").length)
        assertEquals(512, campaign.getString("gclid").length)
        assertValid(rig.transport.posts.last())
    }

    // ---- Giriş təmizliyi -----------------------------------------------------------------------

    @Test
    fun nulCharactersAreStrippedFromStrings() {
        val rig = Rig()
        val core = rig.core()
        core.screen("Ca\u0000rt", null)
        core.identify("user\u0000-1", mapOf("plan" to "p\u0000ro"))
        core.track("Lead", mapOf("title" to "a\u0000b", "list" to listOf("x\u0000"), "k\u0000ey" to 1, "em\u0000ail" to "a@b.az"), null)
        core.flush(force = true)
        assertFalse(rig.transport.bodies.joinToString().contains("\\u0000"))
        val lead = rig.transport.events.last()
        assertEquals("Cart", lead.getJSONObject("screen").getString("name"))
        assertEquals("user-1", lead.getString("user_id"))
        assertEquals("user-1", rig.store.get(Core.K_USER))
        val props = lead.getJSONObject("props")
        assertEquals(setOf("title", "list", "key"), props.keySet())
        assertEquals("ab", props.getString("title"))
        assertEquals("x", props.getJSONArray("list").getString(0))
        rig.transport.posts.forEach { assertValid(it) }

        val smile = "😀"
        assertEquals(smile.repeat(2), Util.text("\u0000" + smile.repeat(5), 2))
        assertEquals("abc", Util.text("abc", 3))
        // İstifadəçi ID-sinin həddi veb tracker-dəki kimi 128 UTF-16 vahididir.
        core.identify(smile.repeat(64), null)
        assertEquals(smile.repeat(64), rig.store.get(Core.K_USER))
        core.identify(smile.repeat(65), null)
        assertEquals(smile.repeat(64), rig.store.get(Core.K_USER))
        core.identify("u".repeat(129), null)
        assertEquals(smile.repeat(64), rig.store.get(Core.K_USER))
    }

    @Test
    fun droppedValuesAreLoggedInDebugMode() {
        val rig = Rig()
        val core = rig.core()
        core.track("Lead", mapOf("obj" to Any(), "nan" to Double.NaN, "list" to listOf(Any()), "ok" to 1), null)
        assertTrue(rig.env.logs.toString(), rig.env.logs.contains("dropped unsupported value: obj"))
        assertTrue(rig.env.logs.contains("dropped unsupported value: nan"))
        assertTrue(rig.env.logs.contains("dropped unsupported list item"))
        assertFalse(rig.env.logs.any { it.contains(": ok") })
    }

    @Test
    fun emailAndPhoneAreHashedWhateverTheKeyCaseOrNumberType() {
        val expectedPhone = Util.sha256("994501234567")
        val expectedEmail = Util.sha256("user@example.com")
        val cases: List<Map<String, Any?>> = listOf(
            mapOf("Email" to " User@Example.com ", "PHONE" to "+994 50 123 45 67"),
            mapOf("email" to "user@example.com", "phone" to 994501234567.0),
            mapOf("EMAIL" to "user@example.com", "Phone" to 994501234567L),
            mapOf("email" to "user@example.com", "phone" to java.math.BigDecimal("9.94501234567E+11")),
        )
        for (traits in cases) {
            val rig = Rig()
            val core = rig.core()
            core.identify("user-1", traits)
            core.flush(force = true)
            val out = rig.transport.events.first { it.getString("type") == "identify" }.getJSONObject("traits")
            assertEquals("$traits", setOf("email_sha256", "phone_sha256"), out.keySet())
            assertEquals("$traits", expectedEmail, out.getString("email_sha256"))
            assertEquals("$traits", expectedPhone, out.getString("phone_sha256"))
            assertValid(rig.transport.posts[0])
        }
        assertNull(Util.phoneText(Double.NaN))
        assertNull(Util.phoneText(true))
    }

    @Test
    fun snapshotIsIndependentOfTheCallersMap() {
        val nested = HashMap<String, Any?>(mapOf("id" to "p1"))
        val items = ArrayList<Any?>(listOf(nested))
        val props = HashMap<String, Any?>(mapOf("value" to 1, "items" to items))
        val copy = Util.snapshot(props)!!
        props["value"] = 2
        props["added"] = true
        nested["id"] = "p2"
        items.add("x")
        val cleaned = Util.cleanObject(copy)!!
        assertEquals(setOf("value", "items"), cleaned.keySet())
        assertEquals(1L, cleaned.getLong("value"))
        assertEquals("""[{"id":"p1"}]""", cleaned.getJSONArray("items").toString())
        assertNull(Util.snapshot(null))
        // Dərinlik həddi kopyada da eynidir.
        val deep = mapOf("a" to mapOf("b" to mapOf("c" to mapOf("d" to mapOf("e" to 1)))))
        assertEquals(Util.cleanObject(deep).toString(), Util.cleanObject(Util.snapshot(deep)).toString())
    }

    // ---- Göndərmə ------------------------------------------------------------------------------

    @Test
    fun batchSizeIsMeasuredInUtf8Bytes() {
        val rig = Rig()
        rig.store.put(Core.K_CONFIG, """{"enabled":true,"flush":{"max_batch":100,"max_queue":1000}}""")
        rig.transport.status = 500
        val core = rig.core()
        // Hər event ~10 000 simvol, amma ~30 KB-dır (üç baytlıq hərflər).
        for (i in 0 until 40) core.track("Lead", mapOf("blob" to "ə".repeat(4_000) + "ა".repeat(6_000)), null)
        rig.transport.status = 200
        rig.transport.bodies.clear()
        rig.transport.posts.clear()
        rig.env.time += 2 * Core.BACKOFF_MAX_MS
        core.flush(force = true)
        assertTrue(rig.transport.bodies.size >= 3)
        for (body in rig.transport.bodies) assertTrue("${Util.utf8Size(body)}", Util.utf8Size(body) <= 500 * 1024)
        assertEquals(40, rig.transport.events.count { it.optString("name") == "Lead" })
    }

    @Test
    fun payloadTooLargeSplitsTheBatchInsteadOfDroppingIt() {
        val rig = Rig()
        rig.store.put(Core.K_CONFIG, """{"enabled":true,"flush":{"max_batch":100,"max_queue":1000}}""")
        rig.transport.status = 500
        val core = rig.core()
        for (i in 0 until 16) core.track("Lead", mapOf("i" to i), null)
        val queued = rig.queue.size()
        rig.transport.posts.clear()
        rig.env.time += 2 * Core.BACKOFF_MAX_MS
        rig.transport.respond = { batch -> if (batch.getJSONArray("events").length() > 3) 413 else 200 }
        core.flush(force = true)
        core.flush(force = true)
        assertEquals(0, rig.queue.size())
        assertEquals(queued, rig.transport.events.size)
        assertEquals((0 until 16).toList(), rig.transport.events.filter { it.optString("name") == "Lead" }.map { it.getJSONObject("props").getInt("i") })

        // Tək event də sığmırsa yalnız o atılır.
        rig.transport.postError = """{"ok":false,"error":"body_too_large"}"""
        rig.transport.respond = { 413 }
        core.track("Lead", null, null)
        core.flush(force = true)
        assertEquals(0, rig.queue.size())
    }

    @Test
    fun redirectResponseKeepsTheBatch() {
        for (status in listOf(301, 302, 307, 308)) {
            val rig = Rig()
            val core = rig.core()
            core.track("Lead", null, null)
            val queued = rig.queue.size()
            rig.transport.status = status
            core.flush(force = true)
            assertEquals("status $status", queued, rig.queue.size())
            rig.transport.status = 200
            core.flush(force = true)
            assertEquals(0, rig.queue.size())
        }
    }

    @Test
    fun forcedFlushHonoursRetryAfter() {
        val rig = Rig()
        val core = rig.core()
        core.track("Lead", null, null)
        rig.transport.status = 429
        rig.transport.retryAfter = 120
        core.flush(force = true)
        val attempts = rig.transport.bodies.size
        rig.transport.status = 200
        rig.env.time += 60_000
        core.flush(force = true)
        core.onBackground()
        assertEquals(attempts, rig.transport.bodies.size)
        assertTrue(rig.queue.size() > 0)
        rig.env.time += 61_000
        core.flush(force = true)
        assertEquals(0, rig.queue.size())

        // Retry-After olmayan uğursuzluqdan sonra məcburi flush dərhal yenidən cəhd edir.
        rig.transport.retryAfter = null
        rig.transport.status = 500
        core.track("Lead", null, null)
        core.flush(force = true)
        rig.transport.status = 200
        core.flush(force = true)
        assertEquals(0, rig.queue.size())
    }

    @Test
    fun corruptedQueueRowsAreDroppedNotRetriedForever() {
        val rig = Rig()
        val core = rig.core()
        core.flush(force = true)
        rig.queue.add("{}", "not json")
        core.track("Lead", null, null)
        core.flush(force = true)
        assertEquals(0, rig.queue.size())
        assertTrue(rig.transport.names.contains("Lead"))
    }

    // ---- Sessiya -------------------------------------------------------------------------------

    @Test
    fun sessionSurvivesLongForegroundAndRenewsAfterLongBackground() {
        val rig = Rig()
        val core = rig.core()
        core.onForeground()
        core.track("Lead", null, null)
        // Ön planda 45 dəqiqə fəaliyyətsizlik sessiyanı bitirmir.
        rig.env.time += 45 * 60_000
        core.track("Lead", null, null)
        core.onBackground()
        // Arxa fonda 10 dəqiqə: sessiya eynidir (son eventdən 55 dəqiqə keçsə də).
        rig.env.time += 10 * 60_000
        core.onForeground()
        core.track("Lead", null, null)
        core.onBackground()
        // Arxa fonda 31 dəqiqə: yeni sessiya.
        rig.env.time += 31 * 60_000
        core.onForeground()
        core.track("Lead", null, null)
        core.flush(force = true)

        val sessions = rig.transport.events.filter { it.optString("name") == "Lead" }.map { it.getString("session_id") }
        assertEquals(4, sessions.size)
        assertEquals(sessions[0], sessions[1])
        assertEquals(sessions[0], sessions[2])
        assertNotEquals(sessions[0], sessions[3])
        assertEquals(2, rig.transport.names.count { it == "SessionStart" })
        assertEquals(3, rig.transport.names.count { it == "AppOpen" })
    }

    @Test
    fun sessionFallsBackToInactivityWhenLifecycleIsNotTracked() {
        val rig = Rig()
        val core = rig.core()
        core.onForeground(tracked = false)
        core.track("Lead", null, null)
        rig.env.time += 31 * 60_000
        core.track("Lead", null, null)
        core.flush(force = true)
        val sessions = rig.transport.events.filter { it.optString("name") == "Lead" }.map { it.getString("session_id") }
        assertNotEquals(sessions[0], sessions[1])
        assertEquals(1, rig.transport.names.count { it == "AppOpen" })
    }
}
