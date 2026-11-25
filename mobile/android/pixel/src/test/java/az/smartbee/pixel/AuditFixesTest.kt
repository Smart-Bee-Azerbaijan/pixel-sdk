package az.smartbee.pixel

import com.networknt.schema.InputFormat
import com.networknt.schema.JsonSchema
import com.networknt.schema.JsonSchemaFactory
import com.networknt.schema.SpecVersion
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

private const val UNKNOWN_KEY = """{"ok":false,"error":"unknown_key"}"""
private const val AD_ID = "38400000-8cf0-11bd-b23e-10b96e40000d"
private const val JWT = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abcDEF123_-x"

/** İlk buraxılışdan əvvəlki auditin (AUDIT.md, H / I / J bölmələri) tapıntılarının sınaqları. iOS-da eyni vektorlar var. */
class AuditFixesTest {
    private val specDir = File(System.getProperty("spec.dir") ?: error("spec.dir is not set"))
    private val schema: JsonSchema = JsonSchemaFactory.getInstance(SpecVersion.VersionFlag.V202012)
        .getSchema(File(specDir, "schema/batch.v1.schema.json").readText())

    private val granted = opts(consent = SmartBeeConsent(analytics = true, ads = true), debug = true)

    private fun assertValid(batch: JSONObject) {
        val errors = schema.validate(batch.toString(), InputFormat.JSON)
        assertTrue("schema errors: $errors", errors.isEmpty())
    }

    private fun ctxFor(rig: Rig, name: String): JSONObject =
        rig.transport.posts.first { p -> p.getJSONArray("events").let { a -> (0 until a.length()).any { a.getJSONObject(it).optString("name") == name } } }.getJSONObject("ctx")

    private fun event(rig: Rig, name: String): JSONObject = rig.transport.events.first { it.optString("name") == name }

    private fun queued(rig: Rig): List<String> = rig.queue.rows.map { JSONObject(it.payload).optString("name") }

    // ---- 1. Kontekst sxemin hədlərinə gətirilir --------------------------------------------------

    @Test
    fun contextIsClampedToSchemaLimits() {
        val long = "x".repeat(5000)
        val rig = Rig(opts(consent = SmartBeeConsent(true, true), wrapper = "React Native!", wrapperVersion = long))
        rig.env.context = {
            JSONObject()
                .put("locale", "az-Latn-AZ-u-ca-gregory-nu-latn$long")
                .put("tz", long)
                .put("ua", long)
                .put("screen", JSONObject().put("w", -5).put("h", "tall").put("density", -1.5))
                .put("app", JSONObject().put("id", long).put("version", long).put("build", long))
                .put("os", JSONObject().put("name", long).put("version", 14))
                .put("device", JSONObject().put("manufacturer", long).put("model", long + "\u0000").put("type", long))
                .put("ids", JSONObject().put("x", long).put("n", 5))
        }
        val core = rig.core()
        core.track("Lead", null, null)
        core.flush(force = true)

        assertEquals(1, rig.transport.posts.size)
        val batch = rig.transport.posts[0]
        assertValid(batch)
        val ctx = batch.getJSONObject("ctx")
        // spec/schema/batch.v1.schema.json: hər sahənin həddi.
        assertEquals("az-Latn-AZ", ctx.getString("locale"))
        assertEquals(64, ctx.getString("tz").length)
        assertEquals(1024, ctx.getString("ua").length)
        val app = ctx.getJSONObject("app")
        assertEquals(255, app.getString("id").length)
        assertEquals(64, app.getString("version").length)
        assertEquals(64, app.getString("build").length)
        val os = ctx.getJSONObject("os")
        assertEquals(32, os.getString("name").length)
        assertFalse("yanlış tipli sahə atılır", os.has("version"))
        val device = ctx.getJSONObject("device")
        assertEquals(64, device.getString("manufacturer").length)
        assertEquals(64, device.getString("model").length)
        assertEquals(16, device.getString("type").length)
        assertEquals(0, ctx.getJSONObject("screen").length())
        assertEquals(256, ctx.getJSONObject("ids").getString("x").length)
        assertFalse(ctx.getJSONObject("ids").has("n"))
        // Yararsız örtük adı göndərilmir (versiyası ilə birlikdə).
        assertFalse(batch.getJSONObject("sdk").has("wrapper"))
        assertFalse(batch.getJSONObject("sdk").has("wrapper_version"))
        assertTrue(batch.getJSONObject("sdk").getString("version").length <= 32)
    }

    @Test
    fun wrapperFieldsFollowTheSchemaPattern() {
        val rig = Rig(opts(consent = SmartBeeConsent(true, true), wrapper = "react-native", wrapperVersion = "v".repeat(100)))
        val core = rig.core()
        core.track("Lead", null, null)
        core.flush(force = true)
        val sdk = rig.transport.posts[0].getJSONObject("sdk")
        assertEquals("react-native", sdk.getString("wrapper"))
        assertEquals(32, sdk.getString("wrapper_version").length)
        assertValid(rig.transport.posts[0])
    }

    @Test
    fun localeTagDropsUnicodeExtensions() {
        assertEquals("az-AZ", Util.localeTag("az_AZ@calendar=gregorian"))
        assertEquals("en-US", Util.localeTag("en-US-u-hc-h12"))
        assertEquals("az-Latn-AZ", Util.localeTag("az-Latn-AZ-U-nu-latn"))
        assertTrue(Util.localeTag("x".repeat(100)).length == 35)
    }

    // ---- 2. Söndürmə yalnız serverin açıq cavabı ilə ---------------------------------------------

    @Test
    fun configFailuresWithoutRecognisedBodyAreTransient() {
        for (status in listOf(404, 403, 401, 400, 410, 500, 503, 302)) {
            for (body in listOf(null, "<html>Not Found</html>", """{"ok":false,"error":"not_found"}""", """{"error":5}""")) {
                val rig = Rig()
                val core = rig.core()
                core.track("Lead", null, null)
                val before = rig.queue.size()
                rig.transport.configStatus = status
                rig.transport.configError = body
                core.refreshConfig(force = true)
                assertFalse("$status $body", core.paused)
                assertTrue(core.config.enabled)
                assertEquals(before, rig.queue.size())
                assertEquals("""{"enabled":true}""", rig.store.map[Core.K_CONFIG])
            }
        }
    }

    @Test
    fun unknownKeyPausesWithoutClearingQueueAndIsRecheckedAfterOneHour() {
        val rig = Rig()
        val core = rig.core()
        core.track("Lead", null, null)
        val before = rig.queue.size()
        rig.transport.configStatus = 404
        rig.transport.configError = UNKNOWN_KEY
        core.refreshConfig(force = true)

        assertTrue(core.paused)
        assertEquals("növbə silinmir", before, rig.queue.size())
        assertEquals("keşlənmiş konfiq qalır", """{"enabled":true}""", rig.store.map[Core.K_CONFIG])
        core.track("WhilePaused", null, null)
        core.flush(force = true)
        assertEquals(before, rig.queue.size())
        assertEquals(0, rig.transport.bodies.size)

        // Vəziyyət prosesin yenidən başlamasından sonra da qalır.
        assertTrue(rig.core().paused)

        // Bir saat ərzində yenidən soruşulmur.
        val calls = rig.transport.configCalls
        rig.env.time += 59 * 60_000L
        core.flush()
        core.onForeground()
        assertEquals(calls, rig.transport.configCalls)

        // Bir saatdan sonra yoxlanır: açar yenidən aktivdirsə növbə göndərilir.
        rig.transport.configStatus = 200
        rig.transport.configBody = """{"enabled":true}"""
        rig.env.time += 2 * 60_000L
        core.flush()
        assertFalse(core.paused)
        assertNull(rig.store.map[Core.K_KEY_OFF_AT])
        assertTrue(rig.transport.names.contains("Lead"))
        assertFalse(rig.transport.names.contains("WhilePaused"))
        assertEquals(0, rig.queue.size())
    }

    @Test
    fun postVerdictFollowsTheProtocolTable() {
        fun verdict(status: Int, error: String? = null, events: Int = 3): Int =
            HttpResult(status, error?.let { """{"ok":false,"error":"$it"}""" }).verdict(events)
        assertEquals(HttpResult.ACCEPTED, verdict(200))
        assertEquals(HttpResult.ACCEPTED, verdict(204))
        for (code in listOf("empty_body", "bad_gzip", "bad_json", "bad_batch", "bad_chars")) assertEquals(code, HttpResult.DROP, verdict(400, code))
        assertEquals(HttpResult.KEY_OFF, verdict(403, "unknown_key"))
        for (code in listOf("origin_not_allowed", "app_not_allowed", "platform_not_enabled", "unknown_platform", "browser_not_allowed")) {
            assertEquals(code, HttpResult.DROP, verdict(403, code))
        }
        assertEquals(HttpResult.SPLIT, verdict(413, "body_too_large", events = 2))
        assertEquals(HttpResult.DROP, verdict(413, "body_too_large", events = 1))
        assertEquals(HttpResult.RETRY, verdict(413, null, events = 1))
        assertEquals(HttpResult.RETRY, verdict(422))
        assertEquals(HttpResult.RETRY, verdict(429, "rate_limited"))
        assertEquals(HttpResult.RETRY, verdict(404, "not_found"))
        assertEquals(HttpResult.RETRY, verdict(403, "some_future_code"))
        // Tanınan gövdəsi olmayan hər 4xx (WAF, ingress, proksi), 3xx, 5xx və şəbəkə xətası müvəqqətidir.
        for (status in listOf(-1, 301, 302, 400, 401, 403, 404, 405, 407, 408, 409, 410, 418, 429, 451, 500, 502, 503, 504)) {
            assertEquals("$status", HttpResult.RETRY, verdict(status))
            assertEquals("$status html", HttpResult.RETRY, HttpResult(status, "<html>blocked</html>").verdict(3))
        }
        assertNull(HttpResult(403, "x".repeat(5000)).error)
        assertNull(HttpResult(403, """["unknown_key"]""").error)
    }

    @Test
    fun proxyErrorsHoldTheBatchAndServerRejectionsDropIt() {
        for (status in listOf(401, 403, 404, 407, 400)) {
            val rig = Rig()
            val core = rig.core()
            core.track("Lead", null, null)
            val before = rig.queue.size()
            rig.transport.status = status
            core.flush(force = true)
            assertEquals("$status", before, rig.queue.size())
            assertEquals(1, rig.transport.bodies.size)
            // Fasilədən sonra yenidən cəhd olunur və eventlər çatır.
            rig.transport.status = 200
            rig.env.time += 10_000
            core.flush()
            assertEquals(0, rig.queue.size())
            assertFalse(core.paused)
        }

        val rig = Rig()
        val core = rig.core()
        core.track("Lead", null, null)
        rig.transport.status = 403
        rig.transport.postError = UNKNOWN_KEY
        core.flush(force = true)
        assertEquals("rədd edilmiş toplu silinir", 0, rig.queue.size())
        assertTrue("403 unknown_key açarı söndürür", core.paused)
        core.track("Later", null, null)
        assertEquals(0, rig.queue.size())
    }

    // ---- 3. Keş açara və ünvana bağlıdır ----------------------------------------------------------

    @Test
    fun cachedConfigAndQueueOfAnotherKeyOrEndpointAreDiscarded() {
        val cases = listOf(
            Core.binding("otherkey01", DEFAULT_ENDPOINT) to opts(debug = true),
            Core.binding(KEY, DEFAULT_ENDPOINT) to opts(debug = true, endpoint = "https://proxy.example.com/"),
        )
        for ((oldBinding, options) in cases) {
            val rig = Rig(options)
            rig.store.map[Core.K_BINDING] = oldBinding
            rig.store.map[Core.K_CONFIG] = """{"enabled":true,"blocked_events":["Lead"]}"""
            rig.store.map[Core.K_CONFIG_ETAG] = "W/\"old\""
            rig.store.map[Core.K_CONFIG_AT] = rig.env.time.toString()
            rig.store.map[Core.K_KEY_OFF_AT] = rig.env.time.toString()
            rig.store.map[Core.K_ANON] = "anon-kept"
            rig.queue.add("{\"platform\":\"android\"}", "{\"name\":\"Old\"}")

            val core = rig.core()
            assertTrue("başqa açarın sətirləri atılır", rig.queue.rows.isEmpty())
            assertFalse(core.paused)
            assertTrue(core.config.blockedEvents.isEmpty())
            assertNull(rig.store.map[Core.K_CONFIG])
            assertNull(rig.store.map[Core.K_CONFIG_ETAG])
            assertEquals("identifikatorlar qalır", "anon-kept", rig.store.map[Core.K_ANON])

            rig.transport.configBody = """{"enabled":true}"""
            core.refreshConfig()
            assertNull("köhnə ETag göndərilmir", rig.transport.lastEtag)
            assertEquals(Core.binding(KEY, options.endpoint), rig.store.map[Core.K_BINDING])
            core.track("Lead", null, null)
            core.flush(force = true)
            assertTrue(rig.transport.names.contains("Lead"))
        }
        // Eyni açar və ünvan: keş və növbə qalır.
        val same = Rig()
        same.queue.add("{\"platform\":\"android\"}", "{\"name\":\"Kept\"}")
        same.core()
        assertEquals(1, same.queue.rows.count { it.payload.contains("Kept") })
    }

    // ---- 5. Pozuq sətir yalnız özü atılır ----------------------------------------------------------

    @Test
    fun corruptQueueRowIsSkippedAndTheRestOfTheBatchIsSent() {
        val rig = Rig()
        val core = rig.core()
        core.track("A", null, null)
        val ctx = rig.queue.rows.last().ctx
        rig.queue.add(ctx, "{not json")
        rig.queue.add("{broken ctx", "{\"name\":\"Lost\"}")
        core.track("B", null, null)
        core.flush(force = true)
        assertEquals(0, rig.queue.size())
        assertTrue(rig.transport.names.containsAll(listOf("A", "B")))
        assertTrue(rig.env.logs.any { it.contains("corrupt queue rows") })
        for (batch in rig.transport.posts) assertValid(batch)
    }

    // ---- 6. Keçidlər: uzunluq həddi və xətti e-poçt axtarışı -------------------------------------

    @Test
    fun overlongDeepLinkIsRejectedBeforeAnyProcessing() {
        val rig = Rig(granted)
        val core = rig.core()
        val url = "https://shop.az/p?utm_source=fb&q=" + "a@".repeat(5000)
        assertTrue(url.length > Util.MAX_URL_LENGTH)
        core.onDeepLink(url)
        core.onDeepLink(url, auto = true)
        assertFalse(queued(rig).contains("DeepLinkOpen"))
        assertNull(rig.store.map[Core.K_CAMPAIGN])
        assertNull(rig.store.map[Core.K_LAST_LINK])
        assertTrue(rig.env.logs.any { it.contains("longer than 8192") })
        assertFalse(Util.isLink(url))
        // Təmizləmə funksiyaları veb tracker-dəki kimi uzun ünvanı qısaldır (query atılır); kampaniya oxunur.
        assertEquals("https://shop.az/p", Util.cleanUrl(url))
        assertEquals("https://shop.az/p", Util.stripClickIds(url))
        assertEquals("fb", Util.campaignOf(url)?.optString("utm_source"))

        // Həddə qədər olan keçid qəbul olunur.
        val ok = "https://shop.az/p?q=" + "a".repeat(Util.MAX_URL_LENGTH - 20)
        assertEquals(Util.MAX_URL_LENGTH, ok.length)
        core.onDeepLink(ok)
        assertTrue(queued(rig).contains("DeepLinkOpen"))
    }

    @Test
    fun emailRedactionIsLinearOnPathologicalInput() {
        val inputs = listOf(
            "a@".repeat(4000),
            "@".repeat(100_000),
            "a@b".repeat(50_000),
            "%40".repeat(50_000),
            "a@" + ".".repeat(100_000),
            ("a@b." + "c".repeat(10)).repeat(10_000),
            "x".repeat(200_000) + "@",
        )
        // JIT-in isinməsi ölçməyə düşməsin.
        for (input in inputs) Util.redactEmails(input.take(2000))
        val started = System.nanoTime()
        for (input in inputs) {
            Util.redactEmails(input)
            Util.clean(input, 4)
            Util.secretSegment(input.take(Util.MAX_URL_LENGTH), 1, true)
            val url = "https://shop.az/" + input.take(Util.MAX_URL_LENGTH - 20)
            Util.cleanUrl(url)
            Util.stripClickIds(url)
            Util.campaignOf("https://shop.az/?utm_term=" + input.take(4000))
        }
        val millis = (System.nanoTime() - started) / 1_000_000
        // Köhnə regex 2000 «@» üçün ~6 saniyə çəkirdi; xətti axtarış bütün girişləri millisaniyələrdə bitirir.
        assertTrue("took ${millis}ms", millis < 1500)
    }

    @Test
    fun emailRedactionMatchesTheWebTracker() {
        assertEquals("[redacted]", Util.redactEmails("a@b.az"))
        assertEquals("/u/[redacted]/x", Util.redactEmails("/u/a@b.az/x"))
        assertEquals("?m=[redacted]&n=1", Util.redactEmails("?m=a%40b.com&n=1"))
        assertEquals("write to [redacted] please", Util.redactEmails("write to User.Test@Example.COM please"))
        // `@` hissənin birinci simvoludursa və ya domenə oxşayan davam yoxdursa toxunulmur.
        assertEquals("@handle", Util.redactEmails("@handle"))
        assertEquals("a@b", Util.redactEmails("a@b"))
        assertEquals("a@b.c", Util.redactEmails("a@b.c"))
        assertEquals("a@.az", Util.redactEmails("a@.az"))
        assertEquals("no mail here", Util.redactEmails("no mail here"))
    }

    // ---- 7. Çağırış anındakı surət məhduddur -------------------------------------------------------

    @Test
    fun snapshotIsBoundedAndSurvivesHugeOrSelfReferentialInput() {
        val huge = mapOf<String, Any?>("items" to (0 until 1_000_000).toList())
        assertSame(Util.OVERSIZED, Util.snapshot(huge))
        val endless = mapOf<String, Any?>("items" to Iterable { generateSequence(1) { it + 1 }.iterator() })
        assertSame(Util.OVERSIZED, Util.snapshot(endless))
        assertSame(Util.OVERSIZED, Util.snapshot(mapOf("text" to "x".repeat(Util.MAX_SNAPSHOT_CHARS + 1))))
        val self = HashMap<String, Any?>()
        self["self"] = self
        self["list"] = arrayListOf<Any?>(self)
        assertNotNull(Util.snapshot(self))

        val normal = Util.snapshot(mapOf("a" to 1, "b" to listOf("x", mapOf("c" to true))))
        assertEquals(mapOf("a" to 1, "b" to listOf("x", mapOf("c" to true))), normal)

        // Həddən böyük parametrlər atılır, event özü gedir.
        val rig = Rig()
        val core = rig.core()
        core.track("Lead", Util.snapshot(huge), null)
        core.identify("user-1", Util.snapshot(huge))
        core.flush(force = true)
        assertFalse(event(rig, "Lead").has("props"))
        assertTrue(rig.env.logs.any { it.contains("too large") })
    }

    // ---- 8. Konfiq hədləri, Retry-After, saat ---------------------------------------------------

    @Test
    fun remoteConfigValuesAreClampedToSafeBounds() {
        val low = RemoteConfig.parse("""{"ttl_s":1,"session_timeout_s":1,"flush":{"interval_s":1,"max_batch":1,"max_queue":1}}""")!!
        assertEquals(60_000L, low.ttlMs)
        assertEquals(60_000L, low.sessionTimeoutMs)
        assertEquals(10_000L, low.flushIntervalMs)
        assertEquals(10, low.maxBatch)
        assertEquals(10, low.maxQueue)
        val high = RemoteConfig.parse("""{"ttl_s":99999999,"session_timeout_s":99999999,"flush":{"interval_s":99999,"max_batch":9999,"max_queue":100000}}""")!!
        assertEquals(7 * 86_400_000L, high.ttlMs)
        assertEquals(86_400_000L, high.sessionTimeoutMs)
        assertEquals(3_600_000L, high.flushIntervalMs)
        assertEquals(100, high.maxBatch)
        assertEquals(5000, high.maxQueue)
    }

    @Test
    fun retryAfterGetsPositiveJitter() {
        val rig = Rig()
        rig.env.randomValue = 1.0
        val core = rig.core()
        core.track("Lead", null, null)
        rig.transport.status = 429
        rig.transport.retryAfter = 100
        core.flush(force = true)
        rig.transport.status = 200
        // 100 s + 20%: 119 saniyədə hələ gözlənilir (məcburi flush da), 121-də göndərilir.
        rig.env.time += 119_000
        core.flush(force = true)
        assertTrue(rig.queue.size() > 0)
        rig.env.time += 2_000
        core.flush()
        assertEquals(0, rig.queue.size())
    }

    @Test
    fun backoffSurvivesClockMovingBackwards() {
        val rig = Rig()
        val core = rig.core()
        core.track("Lead", null, null)
        rig.transport.status = 503
        core.flush(force = true)
        rig.transport.status = 200
        // Saat on gün geri çəkilib: köhnə hədd sonsuz gözlətmir.
        rig.env.time -= 10 * 86_400_000L
        core.flush()
        assertEquals(0, rig.queue.size())
    }

    @Test
    fun notModifiedResetsTheConfigFailureCounter() {
        val rig = Rig()
        val core = rig.core()
        rig.transport.configStatus = 500
        repeat(5) { core.refreshConfig(force = true) }
        rig.transport.configStatus = 304
        core.refreshConfig(force = true)
        // Konfiqin ömrü bitəndən sonrakı ilk uğursuzluq yenə ən qısa fasilə ilə təkrarlanır.
        rig.env.time += 3_600_001
        rig.transport.configStatus = 500
        core.refreshConfig()
        val calls = rig.transport.configCalls
        rig.env.time += 5_000
        core.refreshConfig()
        assertEquals(calls + 1, rig.transport.configCalls)
    }

    @Test
    fun foregroundRespectsConfigBackoff() {
        val rig = Rig()
        val core = rig.core()
        rig.transport.configStatus = 500
        core.onForeground()
        val calls = rig.transport.configCalls
        core.onBackground()
        core.onForeground()
        core.flush()
        assertEquals("fasilə bitməmiş konfiq yenidən soruşulmur", calls, rig.transport.configCalls)
    }

    // ---- 9. Razılığın geri alınması dərhaldır ---------------------------------------------------

    @Test
    fun gateBlocksNetworkAndAdDataImmediately() {
        val rig = Rig(granted)
        rig.env.adLookup = AdIdLookup { AdInfo(AD_ID, false) }
        val core = rig.core()
        // GAID oxunub və ilk toplu onunla gedib.
        core.onForeground()
        assertTrue(rig.transport.bodies.any { it.contains(AD_ID) })
        val sentBefore = rig.transport.bodies.size
        core.onDeepLink("https://shop.az/?utm_source=fb&gclid=GVAL9")
        core.track("Lead", null, null)

        // Açıq çağırış qadağanı çağıran axında qoyub, nüvə hələ `setConsent`-i icra etməyib.
        rig.gate.hold(denyAnalytics = true, denyAds = false)
        val calls = rig.transport.configCalls
        core.flush(force = true)
        core.refreshConfig(force = true)
        core.onForeground()
        assertEquals(sentBefore, rig.transport.bodies.size)
        assertEquals(calls, rig.transport.configCalls)
        rig.gate.release(denyAnalytics = true, denyAds = false)

        rig.gate.hold(denyAnalytics = false, denyAds = true)
        core.flush(force = true)
        assertTrue(rig.transport.posts.size > sentBefore)
        for (batch in rig.transport.posts.drop(sentBefore)) {
            val ctx = batch.getJSONObject("ctx")
            assertFalse(ctx.getJSONObject("consent").getBoolean("ads"))
            assertFalse(ctx.has("ids"))
            assertFalse(batch.toString().contains("GVAL9"))
            assertFalse(batch.toString().contains(AD_ID))
            assertValid(batch)
        }
    }

    private class FailingStore : Store {
        val map = HashMap<String, String>()
        var failOn: String? = null
        override fun get(key: String): String? = map[key]
        override fun put(key: String, value: String) {
            if (key == failOn) throw IllegalStateException("disk full")
            map[key] = value
        }
        override fun remove(key: String) { map.remove(key) }
    }

    @Test
    fun consentWithdrawalSurvivesDiskFailure() {
        val store = FailingStore()
        store.map[Core.K_BINDING] = Core.binding(KEY, DEFAULT_ENDPOINT)
        store.map[Core.K_CONFIG] = "{\"enabled\":true}"
        store.map[Core.K_CONSENT] = "11"
        val queue = FakeQueue()
        val transport = FakeTransport()
        val core = Core(KEY, opts(debug = true), store, queue, transport, FakeEnv()).also { it.start() }
        core.track("Before", null, null)
        assertTrue(queue.size() > 0)

        store.failOn = Core.K_CONSENT
        core.setConsent(false, false)
        // Yazı alınmasa da geri alınma yaddaşda qüvvədədir.
        assertNull(core.anonymousId)
        assertEquals(0, queue.size())
        core.track("After", null, null)
        core.refreshConfig(force = true)
        core.flush(force = true)
        assertEquals(0, queue.size())
        assertEquals(0, transport.bodies.size)
        assertEquals("11", store.map[Core.K_CONSENT])

        // Disk düzələndə yazı təkrarlanır.
        store.failOn = null
        core.flush()
        assertEquals("00", store.map[Core.K_CONSENT])
    }

    // ---- 10. Razılığın üstünlük sırası --------------------------------------------------------

    @Test
    fun mostRestrictiveOfStoredAndInitConsentWins() {
        // Saxlanmış «hə», init-də açıq «yox»: yox.
        val denied = Rig(opts(consent = SmartBeeConsent(analytics = false, ads = false), debug = true))
        denied.store.map[Core.K_CONSENT] = "11"
        denied.store.map[Core.K_ANON] = "anon-old"
        val deniedCore = denied.core()
        deniedCore.track("Lead", null, null)
        assertNull(deniedCore.anonymousId)
        assertEquals(0, denied.queue.size())
        assertNull(denied.store.map[Core.K_ANON])

        // Saxlanmış «hə, hə», init-də reklam «yox».
        val noAds = Rig(opts(consent = SmartBeeConsent(analytics = true, ads = false), debug = true))
        noAds.store.map[Core.K_CONSENT] = "11"
        val noAdsCore = noAds.core()
        noAdsCore.track("Lead", null, null)
        noAdsCore.flush(force = true)
        assertFalse(ctxFor(noAds, "Lead").getJSONObject("consent").getBoolean("ads"))
        assertTrue(ctxFor(noAds, "Lead").getJSONObject("consent").getBoolean("analytics"))

        // Saxlanmış «yox», init-də «hə»: yox.
        val stored = Rig(opts(consent = SmartBeeConsent(analytics = true, ads = true), debug = true))
        stored.store.map[Core.K_CONSENT] = "00"
        val storedCore = stored.core()
        storedCore.track("Lead", null, null)
        assertEquals(0, stored.queue.size())

        // Sonrakı açıq `setConsent` ən təzə seçimdir və init-dəki dəyəri əvəz edir.
        storedCore.setConsent(true, true)
        storedCore.track("Lead", null, null)
        storedCore.flush(force = true)
        assertTrue(ctxFor(stored, "Lead").getJSONObject("consent").getBoolean("ads"))
        deniedCore.setConsent(true, false)
        deniedCore.track("Lead", null, null)
        deniedCore.flush(force = true)
        assertFalse(ctxFor(denied, "Lead").getJSONObject("consent").getBoolean("ads"))
    }

    @Test
    fun remoteDefaultNeverOverridesStatedConsent() {
        for (remote in listOf("""{"analytics":true,"ads":true}""", """{"analytics":false,"ads":false}""")) {
            val rig = Rig(opts(consent = SmartBeeConsent(analytics = true, ads = false), debug = true))
            rig.transport.configBody = """{"enabled":true,"consent_default":$remote}"""
            val core = rig.core()
            core.refreshConfig(force = true)
            core.track("Lead", null, null)
            core.flush(force = true)
            val consent = ctxFor(rig, "Lead").getJSONObject("consent")
            assertTrue(remote, consent.getBoolean("analytics"))
            assertFalse(remote, consent.getBoolean("ads"))
        }
        // Heç kim razılıq bildirməyibsə konfiqin dəyəri işləyir (susmaya görə davranış dəyişməyib).
        assertTrue(CONSENT_WHEN_UNSTATED)
        val unstated = Rig()
        unstated.transport.configBody = """{"enabled":true,"consent_default":{"analytics":true,"ads":false}}"""
        val core = unstated.core()
        core.refreshConfig(force = true)
        core.track("Lead", null, null)
        core.flush(force = true)
        assertFalse(ctxFor(unstated, "Lead").getJSONObject("consent").getBoolean("ads"))
    }

    // ---- 11. Açıq rədd: nə şəbəkə, nə identifikator -------------------------------------------

    @Test
    fun noNetworkWhileAnalyticsIsExplicitlyDenied() {
        val byInit = Rig(opts(consent = SmartBeeConsent(analytics = false, ads = false), debug = true), fresh = true)
        val byUser = Rig(opts(debug = true), fresh = true).also { it.store.map[Core.K_CONSENT] = "00" }
        for (rig in listOf(byInit, byUser)) {
            var reads = 0
            rig.env.adLookup = AdIdLookup { reads++; AdInfo(AD_ID, false) }
            val core = rig.core()
            core.onForeground()
            core.track("Lead", null, null)
            core.flush(force = true)
            core.refreshConfig(force = true)
            assertEquals(0, rig.transport.configCalls)
            assertEquals(0, rig.transport.bodies.size)
            assertEquals(0, reads)
            assertTrue(rig.store.map.keys.toString(), (rig.store.map.keys - Core.K_CONSENT).isEmpty())

            // Razılıq veriləndə konfiq dərhal alınır.
            rig.transport.configBody = """{"enabled":true}"""
            core.setConsent(true, true)
            assertEquals(1, rig.transport.configCalls)
            assertNotNull(core.anonymousId)
        }
    }

    @Test
    fun disabledAnswerWhileUndecidedCommitsNoIdentifiers() {
        val identifiers = setOf(Core.K_ANON, Core.K_USER, Core.K_SESSION, Core.K_SEQ, Core.K_CAMPAIGN, Core.K_LAST_LINK, Core.K_APP_VERSION)

        val unknown = Rig(fresh = true)
        unknown.transport.configStatus = 404
        unknown.transport.configError = UNKNOWN_KEY
        val first = unknown.core()
        first.identify("user-1", null)
        first.onDeepLink("https://shop.az/?utm_source=fb")
        first.onForeground()
        first.flush(force = true)
        assertTrue(first.paused)
        assertTrue(unknown.store.map.keys.toString(), unknown.store.map.keys.none { it in identifiers })
        assertEquals(0, unknown.queue.size())
        assertEquals(0, unknown.transport.bodies.size)

        val disabled = Rig(fresh = true)
        disabled.transport.configBody = """{"enabled":false}"""
        val second = disabled.core()
        second.identify("user-1", null)
        second.onForeground()
        second.flush(force = true)
        assertFalse(second.config.enabled)
        assertTrue(disabled.store.map.keys.toString(), disabled.store.map.keys.none { it in identifiers })
        assertEquals(0, disabled.transport.bodies.size)

        // Açar aktivləşəndə SDK işə düşür və identifikatorlar yalnız onda yazılır.
        disabled.transport.configBody = """{"enabled":true}"""
        second.refreshConfig(force = true)
        second.track("Lead", null, null)
        second.flush(force = true)
        assertNotNull(disabled.store.map[Core.K_ANON])
        assertTrue(disabled.transport.names.contains("Lead"))
    }

    // ---- 12. reset ------------------------------------------------------------------------------

    @Test
    fun resetClearsCampaignSequenceScreenAndIdentity() {
        val rig = Rig(granted)
        val core = rig.core()
        core.onDeepLink("https://shop.az/?utm_source=fb&gclid=G1")
        core.screen("Home", null)
        core.identify("user-1", null)
        core.track("Before", null, null)
        val oldAnon = core.anonymousId
        core.reset("11111111-2222-4333-8444-555555555555")

        assertEquals("11111111-2222-4333-8444-555555555555", core.anonymousId)
        assertNotEquals(oldAnon, core.anonymousId)
        for (k in listOf(Core.K_USER, Core.K_CAMPAIGN, Core.K_CAMPAIGN_AT, Core.K_SEQ, Core.K_SESSION, Core.K_LAST_LINK)) {
            assertNull(k, rig.store.map[k])
        }
        core.track("After", null, null)
        core.flush(force = true)
        val after = event(rig, "After")
        assertEquals("11111111-2222-4333-8444-555555555555", after.getString("anon_id"))
        assertFalse(after.has("user_id"))
        assertFalse("ekran adı silinir", after.has("screen"))
        assertFalse(ctxFor(rig, "After").has("campaign"))
        val restarted = rig.transport.events.last { it.optString("name") == "SessionStart" }
        assertEquals("sıra nömrəsi yenidən başlayır", 0L, restarted.getLong("seq"))
        assertEquals(1L, after.getLong("seq"))
        // Yararsız ID verilərsə nüvə özü yaradır.
        core.reset("not a valid id!")
        assertTrue(Util.ID_RE.matches(core.anonymousId!!))
    }

    // ---- 13. Kampaniya --------------------------------------------------------------------------

    @Test
    fun clickIdsAreNotPersistedWithoutAdsConsent() {
        val link = "https://shop.az/?utm_source=fb&gclid=GVAL9&fbclid=FVAL9&dclid=DVAL9&twclid=TVAL9&yclid=YVAL9&li_fat_id=LVAL9"
        val off = Rig(opts(consent = SmartBeeConsent(analytics = true, ads = false), debug = true))
        val offCore = off.core()
        offCore.onDeepLink(link)
        assertEquals(setOf("utm_source"), JSONObject(off.store.map[Core.K_CAMPAIGN]!!).keySet())
        for (row in off.queue.rows) for (id in listOf("GVAL9", "FVAL9", "DVAL9", "TVAL9", "YVAL9", "LVAL9")) assertFalse(row.payload.contains(id) || row.ctx.contains(id))

        val on = Rig(granted)
        val onCore = on.core()
        onCore.onDeepLink(link)
        assertEquals(
            setOf("utm_source", "gclid", "fbclid", "dclid", "twclid", "yclid", "li_fat_id"),
            JSONObject(on.store.map[Core.K_CAMPAIGN]!!).keySet(),
        )
        // Razılıq geri alınanda klik ID-ləri diskdən də silinir.
        onCore.setConsent(true, false)
        assertEquals(setOf("utm_source"), JSONObject(on.store.map[Core.K_CAMPAIGN]!!).keySet())
        onCore.flush(force = true)
        for (batch in on.transport.posts) assertValid(batch)
    }

    @Test
    fun storedCampaignExpiresAfterNinetyDays() {
        val rig = Rig(granted)
        val core = rig.core()
        core.onDeepLink("https://shop.az/?utm_source=fb&utm_campaign=spring")
        assertNotNull(rig.store.map[Core.K_CAMPAIGN_AT])
        rig.env.time += 89 * 86_400_000L
        core.track("Fresh", null, null)
        rig.env.time += 2 * 86_400_000L
        core.track("Stale", null, null)
        core.flush(force = true)
        assertEquals("fb", ctxFor(rig, "Fresh").getJSONObject("campaign").getString("utm_source"))
        assertFalse(ctxFor(rig, "Stale").has("campaign"))
        assertNull(rig.store.map[Core.K_CAMPAIGN])
        assertNull(rig.store.map[Core.K_CAMPAIGN_AT])

        // Vaxtı yazılmamış (köhnə formatlı) kampaniya da atılır.
        rig.store.map[Core.K_CAMPAIGN] = """{"utm_source":"old"}"""
        core.track("Legacy", null, null)
        assertNull(rig.store.map[Core.K_CAMPAIGN])
    }

    @Test
    fun campaignValuesAreSanitised() {
        val campaign = Util.campaignOf("https://shop.az/?utm_source=news&utm_term=a%40b.az&utm_content=" + "c".repeat(600) + "&utm_medium=mail;x")!!
        assertEquals("[redacted]", campaign.getString("utm_term"))
        assertEquals(512, campaign.getString("utm_content").length)
        // Kampaniya oxunanda yalnız `&` ayırıcıdır (veb tracker ilə eyni qayda).
        assertEquals("mail;x", campaign.getString("utm_medium"))
        // JWT gizlədilir, dəyəri ünvan olan parametr ünvan kimi təmizlənir.
        val scrubbed = Util.campaignOf("https://shop.az/?utm_content=$JWT&utm_source=https%3A%2F%2Fu%3Ap%40ref.az%2Fx%3Ftoken%3D1%26a%3D2")!!
        assertEquals("[redacted]", scrubbed.getString("utm_content"))
        assertEquals("https://ref.az/x?a=2", scrubbed.getString("utm_source"))
        assertNull(Util.campaignOf("https://shop.az/?gclid=G1", withClickIds = false))
    }

    // ---- 14. Ünvanların təmizlənməsi --------------------------------------------------------------

    @Test
    fun urlSanitisingVectors() {
        val vectors = listOf(
            // Həssas adlar: hissə kimi, registrdən asılı olmadan.
            "https://shop.az/p?oobCode=abc&auth_code=1&jwt=x&sig=1&utm_source=fb&q=shoes" to "https://shop.az/p?utm_source=fb&q=shoes",
            "https://shop.az/p?Access_Token=1&ID_TOKEN=2&refreshToken=3&x=1" to "https://shop.az/p?x=1",
            "https://shop.az/p?password=1&passwd=2&pwd=3&client_secret=4&api_key=5&apiKey=6&x=1" to "https://shop.az/p?x=1",
            "https://shop.az/p?sessionId=1&PHPSESSID=2&sid=3&otp=4&x=1" to "https://shop.az/p?x=1",
            "https://shop.az/p?phone=1&tel=2&msisdn=3&mobile=456&card=5&pan=6&iban=7&fin=8&email=9&x=1" to "https://shop.az/p?x=1",
            "https://shop.az/p?X-Amz-Signature=abc&X-Amz-Credential=def&key=1&x=1" to "https://shop.az/p?x=1",
            // Qısa sözlər yalnız bütöv söz kimi tutulur: adi adlar qalır.
            "https://shop.az/p?inside=1&hotel=2&company=3&keyword=shoes&design=4&final=5&pinned=6" to
                "https://shop.az/p?inside=1&hotel=2&company=3&keyword=shoes&design=4&final=5&pinned=6",
            // UTM və klik ID-ləri qalır.
            "https://shop.az/p?utm_source=fb&utm_campaign=code_red&gclid=G1&fbclid=F1&msclkid=M1" to
                "https://shop.az/p?utm_source=fb&utm_campaign=code_red&gclid=G1&fbclid=F1&msclkid=M1",
            // `;` ayırıcısı, mötərizəli və faizlə kodlanmış adlar.
            "https://shop.az/p?a=1;token=zz;b=2" to "https://shop.az/p?a=1;b=2",
            "https://shop.az/p?user%5Bemail%5D=x&pass%77ord=1&%2574oken=2&ok=1" to "https://shop.az/p?ok=1",
            // Dəyəri ünvan olan parametr eyni qaydalarla təmizlənir.
            "https://shop.az/r?next=https%3A%2F%2Fa.az%2Fcb%3Ftoken%3Dabc%26x%3D1&y=2" to
                "https://shop.az/r?next=https%3A%2F%2Fa.az%2Fcb%3Fx%3D1&y=2",
            "https://shop.az/r?next=%2Freset%3Fcode%3D123%26lang%3Daz" to "https://shop.az/r?next=%2Freset%3Flang%3Daz",
            "https://shop.az/r?next=https%3A%2F%2Fa.az%2Fhome" to "https://shop.az/r?next=https%3A%2F%2Fa.az%2Fhome",
            // Dəyəri JWT və ya başqa sirrə oxşayan (32+ hex) parametrin adı qalır, dəyəri gizlədilir; adi ədədə toxunulmur.
            "https://shop.az/p?state=$JWT&x=1" to "https://shop.az/p?state=[redacted]&x=1",
            "https://shop.az/p?order=1234567890123&ref=0123456789abcdef0123456789ABCDEF" to
                "https://shop.az/p?order=1234567890123&ref=[redacted]",
            // Yolun sirrə oxşayan hissələri.
            "https://shop.az/reset/$JWT/done" to "https://shop.az/reset/[redacted]/done",
            "https://shop.az/u/0123456789abcdef0123456789ABCDEF" to "https://shop.az/u/[redacted]",
            "https://shop.az/o/994501234567" to "https://shop.az/o/994501234567",
            // Sirr sözü olan hissədən (reset, verify, otp …) sonrakı hissə daha sərt yoxlanır.
            "https://shop.az/verify/994501234567" to "https://shop.az/verify/[redacted]",
            "https://shop.az/reset-password/9f8a7b6c5d4e/done" to "https://shop.az/reset-password/[redacted]/done",
            "https://shop.az/reset/summer-sale-2026" to "https://shop.az/reset/summer-sale-2026",
            "https://shop.az/card/4111111111111111" to "https://shop.az/card/[redacted]",
            "https://shop.az/o/%2B994501234567/x" to "https://shop.az/o/[redacted]/x",
            "https://shop.az/t/dGhpcyBpcyBhIHNlY3JldCB0b2tlbiB2YWx1ZSAxMjM0NTY3ODkw" to "https://shop.az/t/[redacted]",
            // Adi slug-lar, tirelərlə UUID və qısa ədədi ID-lər qalır.
            "https://shop.az/blog/my-great-post-2024" to "https://shop.az/blog/my-great-post-2024",
            "https://shop.az/item/550e8400-e29b-41d4-a716-446655440000" to "https://shop.az/item/550e8400-e29b-41d4-a716-446655440000",
            "https://shop.az/order/123456789" to "https://shop.az/order/123456789",
            "https://shop.az/kateqoriya/yeni-mehsullar-2026-qis-kolleksiyasi-endirimler-burada" to
                "https://shop.az/kateqoriya/yeni-mehsullar-2026-qis-kolleksiyasi-endirimler-burada",
            // Böyük və kiçik hərf, rəqəm qarışıq, ayırıcısı az olan 32+ simvolluq hissə base64url token sayılır.
            "https://shop.az/Kateqoriya/Yeni-Mehsullar-2026-Qis-Kolleksiyasi-Endirimler-Burada" to "https://shop.az/Kateqoriya/[redacted]",
            // Hash marşrutu yol kimi təmizlənir, başqa fraqment atılır.
            "myapp://open#/reset/9f8a7b6c5d4e?token=1&tab=2" to "myapp://open#/reset/[redacted]?tab=2",
            // İstifadəçi adı / parol, fraqment, e-poçt.
            "https://user:pw@shop.az/a?x=1#frag" to "https://shop.az/a?x=1",
            "myapp://open/a@b.az/x?m=c%40d.com" to "myapp://open/[redacted]/x?m=[redacted]",
            "myapp://product/42?ref=home" to "myapp://product/42?ref=home",
        )
        for ((input, expected) in vectors) assertEquals(input, expected, Util.cleanUrl(input))
        // Konfiqin `strip_params` siyahısı da tətbiq olunur.
        assertEquals("https://shop.az/p?b=2", Util.cleanUrl("https://shop.az/p?Ref=1&b=2", setOf("ref")))
        // Təmizləmə təkrar tətbiq olunanda nəticə dəyişmir.
        for ((_, expected) in vectors) assertEquals(expected, Util.cleanUrl(expected))
    }

    @Test
    fun clickIdStrippingKnowsNewIdsAndSeparators() {
        assertEquals("https://shop.az/p?a=1&utm_source=fb", Util.stripClickIds("https://shop.az/p?a=1&dclid=D&utm_source=fb&twclid=T&yclid=Y&li_fat_id=L"))
        assertEquals("https://shop.az/p?a=1;b=2#/x", Util.stripClickIds("https://shop.az/p?a=1;GCLID=G;b=2#/x"))
        assertEquals("https://shop.az/p", Util.stripClickIds("https://shop.az/p?gclid=G"))
        // İç-içə ünvanlardan (iki səviyyə), hash marşrutunun query-sindən və matris parametrlərindən də çıxır.
        assertEquals(
            "https://shop.az/p;v=2?r=https%3A%2F%2Fb.az%2F%3Fa%3D1#/list?tab=1",
            Util.stripClickIds("https://shop.az/p;gclid=M;v=2?r=https%3A%2F%2Fb.az%2F%3Fgclid%3DN%26a%3D1#/list?ttclid=T&tab=1"),
        )
    }

    @Test
    fun deepLinkEventCarriesSanitisedUrl() {
        val rig = Rig(granted)
        val core = rig.core()
        core.onDeepLink("https://shop.az/reset/$JWT?auth_code=1&utm_source=fb&gclid=G1")
        core.flush(force = true)
        assertEquals("https://shop.az/reset/[redacted]?utm_source=fb&gclid=G1", event(rig, "DeepLinkOpen").getJSONObject("props").getString("url"))
    }

    // ---- 15. Şəxsi məlumat ------------------------------------------------------------------------

    @Test
    fun piiKeysAreMatchedByPattern() {
        val mail = listOf("email", "Email", "E-Mail", "user_email", "contactEmail", "e_mail", "MAIL", "mailAddress")
        val phone = listOf("phone", "Phone_Number", "phoneNumber", "msisdn", "MSISDN", "mobile", "userMobile", "tel", "Tel", "home_tel")
        val forbidden = listOf(
            "password", "Password", "pass", "card", "card_number", "cardNumber", "CVV", "pin", "PIN", "fin", "FIN", "token", "accessToken",
        )
        // Sirr hissəsi olan adlar (dəqiq siyahıda olmayanlar) dəyər bayraq olanda saxlanır (`has_password: true`).
        val secretParts = listOf("user_password", "passwd", "pwd", "passport", "passportNo", "cvc", "iban", "IBAN_no", "secret", "has_cvv")
        val allowed = listOf(
            "value", "currency", "order_id", "passengers", "hotel", "final_price", "pinned", "finish", "telemetry", "title",
            "name", "plan", "", "card_type", "tokens", "smartphone", "token_count", "phone_model", "gift_card", "pin_color",
        )
        // E-poçt / telefon adlı açar yalnız dəyər bayraq (true / false / null) olmayanda atılır (veb tracker ilə eyni
        // qayda); dəqiq `email` / `phone` açarları və sirr adları dəyərdən asılı olmayaraq atılır.
        val exact = setOf("email", "phone")
        for (key in mail + phone) {
            assertTrue(key, Util.forbiddenKey(key, "x"))
            assertTrue(key, Util.forbiddenKey(key, 5_000_000))
            for (flag in listOf(true, false, null)) assertEquals(key, exact.contains(key.lowercase()), Util.forbiddenKey(key, flag))
        }
        for (key in forbidden) for (value in listOf("x", true, null)) assertTrue(key, Util.forbiddenKey(key, value))
        for (key in secretParts) {
            assertTrue(key, Util.forbiddenKey(key, "x"))
            assertTrue(key, Util.forbiddenKey(key, 5))
            for (flag in listOf(true, false, null)) assertFalse(key, Util.forbiddenKey(key, flag))
        }
        // Qısa çoxmənalı sözlər (adın son sözü kimi) yalnız dəyər bayraq olmayanda atılır.
        for (key in listOf("otp", "sms_otp", "ssn", "auth", "session", "cookie")) {
            assertTrue(key, Util.forbiddenKey(key, "x"))
            assertTrue(key, Util.forbiddenKey(key, 482913))
            for (flag in listOf(true, false, null)) assertFalse(key, Util.forbiddenKey(key, flag))
        }
        for (key in allowed) assertFalse(key, Util.forbiddenKey(key, "x"))
        // `*_sha256` açarı yalnız 64 simvolluq hex dəyərlə saxlanır; başqa dəyərdə ad sonluqsuz yoxlanır.
        val hash = "ab".repeat(32)
        val kept = Util.cleanObject(mapOf("email_sha256" to hash, "Email-SHA256" to hash, "phone_sha256" to "+994501234567", "password_sha256" to "hunter2"))
        assertEquals(setOf("email_sha256", "Email-SHA256"), kept?.keySet())
        // Kiçik ədəd sayğacdır (emails_sent: 5), bayraq dəyəri olan çoxmənalı açar qalır.
        assertFalse(Util.forbiddenKey("emails_sent", 5))
        assertFalse(Util.forbiddenKey("otp_sent", true))
        assertTrue(Util.forbiddenKey("user_otp", "482913"))
    }

    @Test
    fun propsDropPiiKeysAtAllDepthsAndRedactEmailValues() {
        val rig = Rig()
        val core = rig.core()
        core.track(
            "Lead",
            mapOf(
                "value" to 5,
                "User_Email" to "a@b.az",
                "note" to "contact a@b.az now",
                "nul\u0000l" to "ok",
                "pass\u0000word" to "secret-after-nul-strip",
                "nested" to mapOf("phoneNumber" to "+994501234567", "deep" to mapOf("card-number" to "4111"), "list" to listOf(mapOf("Otp" to 1, "keep" to "x@y.com"))),
            ),
            "bad id!",
        )
        core.flush(force = true)
        val lead = event(rig, "Lead")
        val props = lead.getJSONObject("props")
        assertEquals(5L, props.getLong("value"))
        assertFalse(props.has("User_Email"))
        assertEquals("contact [redacted] now", props.getString("note"))
        assertEquals("ok", props.getString("null"))
        assertFalse("NUL silinəndən sonra yoxlanır", props.has("password"))
        val nested = props.getJSONObject("nested")
        assertFalse(nested.has("phoneNumber"))
        val deep = nested.getJSONObject("deep")
        assertFalse(deep.has("card-number"))
        assertEquals(0, deep.length())
        val item = nested.getJSONArray("list").getJSONObject(0)
        assertFalse(item.has("Otp"))
        assertEquals("[redacted]", item.getString("keep"))
        assertFalse(lead.toString().contains("a@b.az"))
        // Atılan açarlar və yararsız eventId sazlama loquna yazılır; yararsız ID yerinə UUID gedir.
        assertTrue(rig.env.logs.any { it.contains("dropped forbidden key: User_Email") })
        assertTrue(rig.env.logs.any { it.contains("invalid eventId") })
        assertTrue(Util.ID_RE.matches(lead.getString("id")))
        assertNotEquals("bad id!", lead.getString("id"))
    }

    @Test
    fun traitsHashEmailAndPhoneUnderAnyKeySpelling() {
        val vectors = JSONObject(File(specDir, "vectors/hashing.json").readText())
        val email = vectors.getJSONArray("email").getJSONObject(0)
        val phone = vectors.getJSONArray("phone").getJSONObject(0)
        val spellings = listOf("email" to "phone", "E-Mail" to "Phone_Number", "userEmail" to "msisdn", "contact_mail" to "mobile", "MAIL" to "tel")
        for ((mailKey, phoneKey) in spellings) {
            val rig = Rig()
            val core = rig.core()
            core.identify("user-1", mapOf(mailKey to email.getString("input"), phoneKey to phone.getString("input"), "plan" to "pro", "bio" to "me: x@y.com"))
            core.flush(force = true)
            val traits = rig.transport.events.first { it.getString("type") == "identify" }.getJSONObject("traits")
            assertEquals(mailKey, email.getString("sha256"), traits.getString("email_sha256"))
            assertEquals(phoneKey, phone.getString("sha256"), traits.getString("phone_sha256"))
            assertEquals(setOf("email_sha256", "phone_sha256", "plan", "bio"), traits.keySet())
            assertEquals("me: [redacted]", traits.getString("bio"))
        }
        // Artıq hash olunmuş dəyər toxunulmaz ötürülür.
        val rig = Rig()
        val core = rig.core()
        core.identify("user-1", mapOf("email_sha256" to "ab".repeat(32)))
        core.flush(force = true)
        assertEquals("ab".repeat(32), rig.transport.events.first { it.getString("type") == "identify" }.getJSONObject("traits").getString("email_sha256"))
    }

    @Test
    fun emailOrPhoneShapedUserIdIsHashed() {
        val cases = listOf(
            "  User@Example.COM " to Util.sha256("user@example.com"),
            "a@b.az" to Util.sha256("a@b.az"),
            "+994 (50) 123-45-67" to Util.sha256("994501234567"),
            "+994501234567" to Util.sha256("994501234567"),
            "050.123.45.67" to Util.sha256("0501234567"),
            "012345678" to Util.sha256("012345678"),
            "050 123 45 67" to Util.sha256("0501234567"),
            "994501234567" to Util.sha256("994501234567"),
            // Adi ID-lər olduğu kimi qalır: qısa ədədlər, hərfli ID-lər, UUID.
            "user-42" to "user-42",
            "1234567" to "1234567",
            "123456789" to "123456789",
            "u_994501234567" to "u_994501234567",
            "550e8400-e29b-41d4-a716-446655440000" to "550e8400-e29b-41d4-a716-446655440000",
            "@handle" to "@handle",
            "12345678901234567890" to "12345678901234567890",
        )
        for ((input, expected) in cases) {
            val rig = Rig()
            val core = rig.core()
            core.identify(input, null)
            core.track("Lead", null, null)
            core.flush(force = true)
            assertEquals(input, expected, event(rig, "Lead").getString("user_id"))
            assertEquals(input, expected, rig.store.map[Core.K_USER])
            if (expected != input) {
                assertFalse(rig.transport.bodies.any { it.contains(input.trim()) })
                assertTrue(rig.env.logs.any { it.contains("its sha256 is sent instead") })
            }
            for (batch in rig.transport.posts) assertValid(batch)
        }
        assertEquals("b4c9a289323b21a01c3e940f150eb9b8c542587f1abfd8f0e1cc1ffc5e475514", Util.sha256("user@example.com"))
    }

    // ---- 17. GAID ilk topluya düşür ---------------------------------------------------------------

    @Test
    fun firstFlushWaitsBrieflyForTheFirstAdIdLookup() {
        val rig = Rig(granted)
        rig.env.adLookup = AdIdLookup { AdInfo(AD_ID, false) }
        rig.env.deferOffload = true
        val core = rig.core()
        core.onForeground()
        core.track("Early", null, null)
        core.flush()
        assertEquals("ilk oxunuş bitənə qədər göndəriş gözləyir", 0, rig.transport.bodies.size)
        assertEquals("event yığımı bloklanmır", listOf("SessionStart", "AppInstall", "AppOpen", "Early"), queued(rig))
        assertEquals(1, rig.env.scheduled.size)
        assertTrue(rig.env.scheduled[0].first in 2_000..3_000)

        // Oxunuş bitən kimi göndəriş özü başlayır və AppInstall / AppOpen GAID ilə gedir.
        rig.env.runOffloaded()
        assertEquals(0, rig.queue.size())
        for (batch in rig.transport.posts) assertEquals(AD_ID, batch.getJSONObject("ctx").getJSONObject("ids").getString("gaid"))
        assertTrue(rig.transport.names.containsAll(listOf("AppInstall", "AppOpen", "Early")))
    }

    @Test
    fun hungAdIdLookupDelaysTheFirstFlushByAtMostTheWaitLimit() {
        val rig = Rig(granted)
        rig.env.adLookup = AdIdLookup { AdInfo(AD_ID, false) }
        rig.env.deferOffload = true
        val core = rig.core()
        core.onForeground()
        assertEquals(0, rig.transport.bodies.size)
        rig.env.time += Core.AD_ID_WAIT_MS + 50
        rig.env.scheduled[0].second()
        assertEquals(0, rig.queue.size())
        assertTrue(rig.transport.names.contains("AppOpen"))
        assertFalse(rig.transport.bodies.any { it.contains(AD_ID) })

        // Reklam razılığı yoxdursa və ya toplama söndürülübsə gözləmə yoxdur.
        for (options in listOf(opts(consent = SmartBeeConsent(true, false)), opts(consent = SmartBeeConsent(true, true), collectAdvertisingId = false))) {
            val other = Rig(options)
            other.env.adLookup = AdIdLookup { AdInfo(AD_ID, false) }
            other.env.deferOffload = true
            other.core().onForeground()
            assertTrue(other.transport.names.contains("AppOpen"))
            assertTrue(other.env.offloaded.isEmpty())
        }
    }

    // ---- 18. Eventin vaxtı və keçidin təkrarı -----------------------------------------------------

    @Test
    fun eventTimeIsTheTimeOfTheCall() {
        val rig = Rig()
        val core = rig.core()
        val called = rig.env.time
        // İşçi axın 20 saniyə məşğul olub: event çağırış anının vaxtı ilə gedir.
        rig.env.time += 20_000
        core.track("Late", null, null, at = called)
        core.identify("user-1", null, at = called)
        core.screen("Home", null, at = called)
        core.onForeground(at = called)
        core.flush(force = true)
        for (name in listOf("Late", "ScreenView", "AppOpen")) assertEquals(name, Util.iso(called), event(rig, name).getString("ts"))
        assertEquals(Util.iso(called), rig.transport.events.first { it.getString("type") == "identify" }.getString("ts"))
        // Gecikmiş vaxt yeni sessiya yaratmır.
        assertEquals(1, rig.transport.names.count { it == "SessionStart" })
        for (batch in rig.transport.posts) assertValid(batch)
    }

    @Test
    fun appOpenIsRecordedBeforeTheConfigFetch() {
        val rig = Rig(granted)
        val core = rig.core()
        var queuedAtFetch: List<String> = emptyList()
        rig.transport.onConfig = { queuedAtFetch = queued(rig) }
        core.onForeground()
        assertTrue(queuedAtFetch.contains("AppOpen"))
    }

    @Test
    fun restoredIntentLinkIsNotCountedAgain() {
        val url = "https://shop.az/p/1?utm_source=fb"
        val rig = Rig(granted)
        rig.core().onDeepLink(url, auto = true)
        assertEquals(1, queued(rig).count { it == "DeepLinkOpen" })
        assertFalse("ünvanın özü saxlanmır, yalnız hash-i", rig.store.map[Core.K_LAST_LINK]!!.contains("shop.az"))

        // Proses bərpa olunub: eyni intent yenidən oxunur.
        rig.env.time += 60_000
        val restored = rig.core()
        restored.onDeepLink(url, auto = true)
        assertEquals(1, queued(rig).count { it == "DeepLinkOpen" })
        // Tətbiqin özü ötürdüyü keçid (istifadəçi yenidən toxunub) sayılır.
        restored.onDeepLink(url)
        assertEquals(2, queued(rig).count { it == "DeepLinkOpen" })
        // Müddət bitəndən sonra avtomatik oxunan eyni keçid də sayılır.
        rig.env.time += Core.LINK_RESTORE_MS + 1
        rig.core().onDeepLink(url, auto = true)
        assertEquals(3, queued(rig).count { it == "DeepLinkOpen" })
    }

    // ---- 19. Təkrar init ------------------------------------------------------------------------

    @Test
    fun repeatedInitOnlyTightens() {
        val rig = Rig(granted)
        var reads = 0
        rig.env.adLookup = AdIdLookup { reads++; AdInfo(AD_ID, false) }
        val core = rig.core()
        core.onForeground()
        assertEquals(1, reads)

        // Daha yumşaq seçimlər heç nəyi dəyişmir.
        core.restrict(SmartBeeConsent(true, true), collectAdvertisingId = true)
        core.restrict(null, collectAdvertisingId = true)
        core.track("Open", null, null)
        core.flush(force = true)
        assertEquals(AD_ID, ctxFor(rig, "Open").getJSONObject("ids").getString("gaid"))

        core.restrict(null, collectAdvertisingId = false)
        core.track("NoAdId", null, null)
        core.flush(force = true)
        assertTrue(ctxFor(rig, "NoAdId").getJSONObject("consent").getBoolean("ads"))
        assertFalse(ctxFor(rig, "NoAdId").has("ids"))

        core.restrict(SmartBeeConsent(true, false), collectAdvertisingId = true)
        core.restrict(SmartBeeConsent(true, true), collectAdvertisingId = true)
        core.track("NoAds", null, null)
        core.flush(force = true)
        assertFalse(ctxFor(rig, "NoAds").getJSONObject("consent").getBoolean("ads"))
        core.onBackground()
        core.onForeground()
        assertEquals("söndürüləndən sonra GAID oxunmur", 1, reads)

        core.restrict(SmartBeeConsent(false, true), collectAdvertisingId = true)
        assertNull(core.anonymousId)
        core.track("Denied", null, null)
        assertEquals(0, rig.queue.size())
        val calls = rig.transport.configCalls
        core.refreshConfig(force = true)
        assertEquals(calls, rig.transport.configCalls)
    }

    // ---- 20. AppInstall razılıq sonradan veriləndə -------------------------------------------------

    @Test
    fun appInstallIsEvaluatedWhenConsentIsGrantedLater() {
        val rig = Rig(opts(consent = SmartBeeConsent(analytics = false, ads = false), debug = true))
        val core = rig.core()
        assertEquals(0, rig.queue.size())
        core.setConsent(true, true)
        assertEquals(1, queued(rig).count { it == "AppInstall" })
        // Yenə yalnız bir dəfə.
        core.setConsent(false, false)
        core.setConsent(true, true)
        core.flush(force = true)
        assertEquals(0, rig.transport.names.count { it == "AppInstall" })
        val again = rig.core()
        again.setConsent(true, true)
        again.flush(force = true)
        assertEquals(0, rig.transport.names.count { it == "AppInstall" })
    }
}
