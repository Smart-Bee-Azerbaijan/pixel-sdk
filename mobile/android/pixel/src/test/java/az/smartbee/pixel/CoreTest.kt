package az.smartbee.pixel

import com.networknt.schema.InputFormat
import com.networknt.schema.JsonSchema
import com.networknt.schema.JsonSchemaFactory
import com.networknt.schema.SpecVersion
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

private const val KEY = "demo0andr1"

/** Android-in JSONObject sinifində keySet yoxdur. */
private fun JSONObject.keySet(): Set<String> = keys().asSequence().toSet()

private class FakeStore : Store {
    val map = HashMap<String, String>()
    override fun get(key: String): String? = map[key]
    override fun put(key: String, value: String) { map[key] = value }
    override fun remove(key: String) { map.remove(key) }
}

private class FakeQueue : EventQueue {
    val rows = ArrayList<QueuedEvent>()
    private var nextId = 1L
    override fun add(ctx: String, payload: String) { rows.add(QueuedEvent(nextId++, ctx, payload)) }
    override fun peek(limit: Int): List<QueuedEvent> = rows.take(limit)
    override fun remove(ids: List<Long>) { rows.removeAll { it.id in ids } }
    override fun size(): Int = rows.size
    override fun trim(max: Int) { while (rows.size > max) rows.removeAt(0) }
    override fun clear() { rows.clear() }
}

private class FakeTransport : Transport {
    val posts = ArrayList<JSONObject>()
    val urls = ArrayList<String>()
    var status = 200
    var retryAfter: Long? = null
    var configStatus = 200
    var configBody: String? = null
    var configEtag: String? = "W/\"1\""
    var configCalls = 0
    var lastEtag: String? = null
    var throwOnPost = false

    override fun post(url: String, json: String): HttpResult {
        if (throwOnPost) throw IllegalStateException("network down")
        urls.add(url)
        posts.add(JSONObject(json))
        return HttpResult(status, retryAfterSec = retryAfter)
    }

    override fun get(url: String, etag: String?): HttpResult {
        configCalls++
        lastEtag = etag
        urls.add(url)
        return HttpResult(configStatus, if (configStatus == 200) configBody else null, configEtag)
    }

    val events: List<JSONObject>
        get() = posts.flatMap { p -> p.getJSONArray("events").let { a -> (0 until a.length()).map { a.getJSONObject(it) } } }
    val names: List<String> get() = events.map { if (it.getString("type") == "track") it.getString("name") else it.getString("type") }
}

private class FakeEnv : Env {
    var time = 1_795_590_000_000L
    var version = "1.2.3"
    var build = "45"
    private var counter = 0
    val logs = ArrayList<String>()
    override fun now(): Long = time
    override fun uuid(): String = "00000000-0000-4000-8000-" + (++counter).toString().padStart(12, '0')
    override fun log(message: String) { logs.add(message) }
    override fun deviceContext(): JSONObject = JSONObject()
        .put("locale", "az-AZ").put("tz", "Asia/Baku")
        .put("screen", JSONObject().put("w", 1080).put("h", 2400).put("density", 2.75))
        .put("app", JSONObject().put("id", "az.smartbee.demo").put("version", version).put("build", build))
        .put("os", JSONObject().put("name", "Android").put("version", "14"))
        .put("device", JSONObject().put("manufacturer", "Google").put("model", "Pixel 8").put("type", "phone"))
}

private class Rig(options: SmartBeeOptions = SmartBeeOptions(debug = true)) {
    val store = FakeStore()
    val queue = FakeQueue()
    val transport = FakeTransport()
    val env = FakeEnv()
    var options = options
    fun core(): Core = Core(KEY, options, store, queue, transport, env).also { it.start() }
}

class CoreTest {
    private val specDir = File(System.getProperty("spec.dir") ?: error("spec.dir is not set"))
    private val schema: JsonSchema = JsonSchemaFactory.getInstance(SpecVersion.VersionFlag.V202012)
        .getSchema(File(specDir, "schema/batch.v1.schema.json").readText())

    private fun assertValid(batch: JSONObject) {
        val errors = schema.validate(batch.toString(), InputFormat.JSON)
        assertTrue("schema errors: $errors", errors.isEmpty())
    }

    @Test
    fun firstStartSendsInstallAndValidBatch() {
        val rig = Rig()
        val core = rig.core()
        core.track("Purchase", mapOf("value" to 250, "currency" to "AZN", "contents" to listOf(mapOf("id" to "p1", "quantity" to 2))), "order:A-1001")
        core.flush(force = true)

        assertEquals(1, rig.transport.posts.size)
        val batch = rig.transport.posts[0]
        assertValid(batch)
        assertEquals("https://c.cdnsb.net/v1/e", rig.transport.urls.last())
        assertEquals(1, batch.getInt("v"))
        assertEquals(KEY, batch.getString("key"))
        assertEquals("android", batch.getJSONObject("sdk").getString("name"))
        val ctx = batch.getJSONObject("ctx")
        assertEquals("android", ctx.getString("platform"))
        assertEquals("az.smartbee.demo", ctx.getJSONObject("app").getString("id"))
        assertTrue(ctx.getJSONObject("consent").getBoolean("analytics"))
        assertEquals(listOf("SessionStart", "AppInstall", "Purchase"), rig.transport.names)

        val purchase = rig.transport.events.last()
        assertEquals("order:A-1001", purchase.getString("id"))
        assertEquals(250L, purchase.getJSONObject("props").getLong("value"))
        assertFalse(purchase.has("origin"))
        assertEquals("auto", rig.transport.events[0].getString("origin"))
        val seqs = rig.transport.events.map { it.getLong("seq") }
        assertEquals(seqs.sorted(), seqs)
        assertEquals(0, rig.queue.size())
    }

    @Test
    fun secondStartHasNoInstallAndVersionChangeSendsUpdate() {
        val rig = Rig()
        rig.core().flush(force = true)
        rig.transport.posts.clear()

        rig.core().flush(force = true)
        assertEquals(emptyList<String>(), rig.transport.names)

        rig.env.version = "1.3.0"
        rig.env.build = "46"
        rig.core().flush(force = true)
        assertEquals(listOf("AppUpdate"), rig.transport.names)
        val props = rig.transport.events[0].getJSONObject("props")
        assertEquals("1.2.3", props.getString("previous_version"))
        assertEquals("45", props.getString("previous_build"))
    }

    @Test
    fun anonymousIdAndSessionPersistAcrossRestarts() {
        val rig = Rig()
        val first = rig.core()
        first.track("Lead", null, null)
        first.flush(force = true)
        val second = rig.core()
        second.track("Lead", null, null)
        second.flush(force = true)
        val events = rig.transport.events.filter { it.optString("name") == "Lead" }
        assertEquals(events[0].getString("anon_id"), events[1].getString("anon_id"))
        assertEquals(events[0].getString("session_id"), events[1].getString("session_id"))
        assertEquals(first.anonymousId, second.anonymousId)
        assertEquals(1, rig.transport.names.count { it == "SessionStart" })
    }

    @Test
    fun sessionExpiresAfterTimeout() {
        val rig = Rig()
        val core = rig.core()
        core.track("Lead", null, null)
        rig.env.time += 31 * 60_000
        core.track("Lead", null, null)
        core.flush(force = true)
        val leads = rig.transport.events.filter { it.optString("name") == "Lead" }
        assertNotEquals(leads[0].getString("session_id"), leads[1].getString("session_id"))
        assertEquals(2, rig.transport.names.count { it == "SessionStart" })
    }

    @Test
    fun propsAreSanitized() {
        val rig = Rig()
        val core = rig.core()
        core.track(
            "Lead",
            mapOf(
                "email" to "a@b.az", "Password" to "x", "nan" to Double.NaN, "obj" to Any(), "nothing" to null,
                "nested" to mapOf("phone" to "1", "ok" to 1, "deep" to mapOf("a" to mapOf("b" to mapOf("c" to 1)))),
                "list" to listOf(1, mapOf("token" to "t", "keep" to true)),
            ),
            null,
        )
        core.flush(force = true)
        val props = rig.transport.events.last().getJSONObject("props")
        assertEquals(setOf("nested", "list", "nothing"), props.keySet())
        assertTrue(props.isNull("nothing"))
        val nested = props.getJSONObject("nested")
        assertEquals(setOf("ok", "deep"), nested.keySet())
        assertEquals(0, nested.getJSONObject("deep").getJSONObject("a").length())
        val list = props.getJSONArray("list")
        assertEquals(setOf("keep"), list.getJSONObject(1).keySet())
        assertValid(rig.transport.posts[0])
    }

    @Test
    fun invalidNamesBlockedEventsAndOversizedEventsAreDropped() {
        val rig = Rig()
        rig.store.put(Core.K_CONFIG, """{"enabled":true,"blocked_events":["Search"]}""")
        val core = rig.core()
        core.track("my event!", null, null)
        core.track("", null, null)
        core.track(null, null, null)
        core.track("Search", null, null)
        core.track("Lead", mapOf("blob" to "x".repeat(40_000)), null)
        core.track("Contact", null, "bad id with spaces")
        core.flush(force = true)
        assertEquals(listOf("SessionStart", "AppInstall", "Contact"), rig.transport.names)
        assertTrue(rig.transport.events.last().getString("id").startsWith("00000000-"))
    }

    @Test
    fun identifyHashesEmailAndPhoneUsingSpecVectors() {
        val vectors = JSONObject(File(specDir, "vectors/hashing.json").readText())
        val emails = vectors.getJSONArray("email")
        val phones = vectors.getJSONArray("phone")
        for (i in 0 until emails.length()) {
            val rig = Rig()
            val core = rig.core()
            val email = emails.getJSONObject(i)
            val phone = phones.getJSONObject(i)
            core.identify("user-42", mapOf("email" to email.getString("input"), "phone" to phone.getString("input"), "plan" to "pro"))
            core.track("Lead", null, null)
            core.flush(force = true)
            assertValid(rig.transport.posts[0])
            val identify = rig.transport.events.first { it.getString("type") == "identify" }
            val traits = identify.getJSONObject("traits")
            assertEquals(setOf("plan", "email_sha256", "phone_sha256"), traits.keySet())
            assertEquals(email.getString("sha256"), traits.getString("email_sha256"))
            assertEquals(phone.getString("sha256"), traits.getString("phone_sha256"))
            assertEquals("user-42", rig.transport.events.last().getString("user_id"))
            assertFalse(rig.transport.posts.toString().contains(email.getString("normalized")))
        }
    }

    @Test
    fun invalidUserIdIsIgnored() {
        val rig = Rig()
        val core = rig.core()
        core.identify("", null)
        core.identify(null, null)
        core.identify("x".repeat(129), null)
        core.flush(force = true)
        assertFalse(rig.transport.names.contains("identify"))
    }

    @Test
    fun withoutAnalyticsConsentNothingIsSentOrStored() {
        val rig = Rig(SmartBeeOptions(consent = Consent(analytics = false, ads = false)))
        val core = rig.core()
        core.track("Lead", null, null)
        core.identify("user-1", null)
        core.onForeground()
        core.onDeepLink("myapp://open?utm_source=fb")
        core.flush(force = true)
        assertEquals(0, rig.transport.posts.size)
        assertEquals(0, rig.queue.size())
        assertNull(core.anonymousId)
        assertNull(rig.store.get(Core.K_ANON))
        assertNull(rig.store.get(Core.K_USER))
        assertNull(rig.store.get(Core.K_CAMPAIGN))

        core.setConsent(true, null)
        core.track("Lead", null, null)
        core.flush(force = true)
        assertTrue(rig.transport.names.contains("Lead"))
        assertEquals(core.anonymousId, rig.store.get(Core.K_ANON))
    }

    @Test
    fun revokingConsentClearsQueueAndIdentityAndIsRemembered() {
        val rig = Rig()
        val core = rig.core()
        core.identify("user-1", null)
        core.track("Lead", null, null)
        core.setConsent(false, false)
        assertEquals(0, rig.queue.size())
        assertNull(rig.store.get(Core.K_ANON))
        assertNull(rig.store.get(Core.K_USER))
        core.flush(force = true)
        assertEquals(0, rig.transport.posts.size)

        val restarted = rig.core()
        restarted.track("Lead", null, null)
        restarted.flush(force = true)
        assertEquals(0, rig.transport.posts.size)
    }

    @Test
    fun withoutAdsConsentClickIdsAreNotSent() {
        val rig = Rig()
        val core = rig.core()
        core.onDeepLink("https://shop.az/p/1?utm_source=fb&fbclid=FB1&gclid=G1&token=SECRET#frag")
        core.flush(force = true)
        // Başlanğıc eventləri keçiddən əvvəl növbəyə düşüb, ona görə kampaniyasız ayrıca topludadır.
        val campaign = rig.transport.posts.last().getJSONObject("ctx").getJSONObject("campaign")
        assertEquals(setOf("utm_source", "fbclid", "gclid"), campaign.keySet())
        val link = rig.transport.events.first { it.optString("name") == "DeepLinkOpen" }
        assertEquals("https://shop.az/p/1?utm_source=fb&fbclid=FB1&gclid=G1", link.getJSONObject("props").getString("url"))
        assertFalse(rig.transport.posts.toString().contains("SECRET"))

        rig.transport.posts.clear()
        core.setConsent(null, false)
        core.track("Lead", null, null)
        core.flush(force = true)
        val ctx = rig.transport.posts[0].getJSONObject("ctx")
        assertEquals(setOf("utm_source"), ctx.getJSONObject("campaign").keySet())
        assertFalse(ctx.getJSONObject("consent").getBoolean("ads"))
        assertValid(rig.transport.posts[0])
    }

    @Test
    fun retryableFailuresKeepEventsAndBackOff() {
        val rig = Rig()
        val core = rig.core()
        core.track("Lead", null, null)
        val queued = rig.queue.size()

        for (status in listOf(500, 429, 408, -1)) {
            rig.transport.status = status
            core.flush(force = true)
            assertEquals("status $status", queued, rig.queue.size())
        }
        val attempts = rig.transport.posts.size
        // Fasilə bitməmiş adi flush yeni cəhd etmir.
        core.flush()
        assertEquals(attempts, rig.transport.posts.size)

        rig.transport.throwOnPost = true
        core.flush(force = true)
        assertEquals(queued, rig.queue.size())
        rig.transport.throwOnPost = false

        rig.env.time += 2 * Core.BACKOFF_MAX_MS
        rig.transport.status = 200
        core.flush()
        assertEquals(0, rig.queue.size())
        // Təkrar göndərişdə event ID-ləri eynidir (server dedup edir).
        val ids = rig.transport.posts.map { p -> p.getJSONArray("events").getJSONObject(0).getString("id") }.toSet()
        assertEquals(1, ids.size)
    }

    @Test
    fun retryAfterHeaderIsHonoured() {
        val rig = Rig()
        val core = rig.core()
        core.track("Lead", null, null)
        rig.transport.status = 429
        rig.transport.retryAfter = 120
        core.flush(force = true)
        rig.transport.status = 200
        rig.env.time += 119_000
        core.flush()
        assertTrue(rig.queue.size() > 0)
        rig.env.time += 2_000
        core.flush()
        assertEquals(0, rig.queue.size())
    }

    @Test
    fun nonRetryableRejectionDropsBatch() {
        val rig = Rig()
        val core = rig.core()
        core.track("Lead", null, null)
        rig.transport.status = 403
        core.flush(force = true)
        assertEquals(0, rig.queue.size())
        assertEquals(1, rig.transport.posts.size)
    }

    @Test
    fun queueSurvivesRestartAndIsBounded() {
        val rig = Rig()
        rig.store.put(Core.K_CONFIG, """{"enabled":true,"flush":{"max_batch":100,"max_queue":10}}""")
        rig.transport.status = 500
        val core = rig.core()
        for (i in 0 until 30) core.track("Lead", mapOf("i" to i), null)
        assertEquals(10, rig.queue.size())

        rig.transport.status = 200
        rig.transport.posts.clear()
        rig.env.time += 2 * Core.BACKOFF_MAX_MS
        rig.core().flush(force = true)
        val indexes = rig.transport.events.map { it.getJSONObject("props").getInt("i") }
        assertEquals((20 until 30).toList(), indexes)
    }

    @Test
    fun batchesAreSplitByContextAndSize() {
        val rig = Rig()
        rig.store.put(Core.K_CONFIG, """{"enabled":true,"flush":{"max_batch":100,"max_queue":1000}}""")
        rig.transport.status = 500
        val core = rig.core()
        for (i in 0 until 3) core.track("Lead", null, null)
        rig.env.version = "2.0.0"
        for (i in 0 until 2) core.track("Contact", null, null)

        rig.transport.status = 200
        rig.transport.posts.clear()
        core.flush(force = true)
        assertEquals(2, rig.transport.posts.size)
        assertEquals("1.2.3", rig.transport.posts[0].getJSONObject("ctx").getJSONObject("app").getString("version"))
        assertEquals("2.0.0", rig.transport.posts[1].getJSONObject("ctx").getJSONObject("app").getString("version"))
        assertEquals(2, rig.transport.posts[1].getJSONArray("events").length())
        rig.transport.posts.forEach { assertValid(it) }

        // 20 KB-lıq 40 event (~800 KB) bir topluya sığmır.
        rig.transport.posts.clear()
        for (i in 0 until 40) core.track("Lead", mapOf("blob" to "x".repeat(20_000)), null)
        core.flush(force = true)
        assertTrue(rig.transport.posts.size >= 2)
        rig.transport.posts.forEach { assertTrue(it.toString().length <= 500 * 1024) }
        assertEquals(40, rig.transport.events.size)
    }

    @Test
    fun maxBatchTriggersAutomaticFlush() {
        val rig = Rig()
        rig.store.put(Core.K_CONFIG, """{"enabled":true,"flush":{"max_batch":5}}""")
        val core = rig.core()
        rig.transport.posts.clear()
        for (i in 0 until 12) core.track("Lead", null, null)
        assertTrue(rig.transport.posts.isNotEmpty())
        rig.transport.posts.forEach { assertTrue(it.getJSONArray("events").length() <= 5) }
    }

    @Test
    fun remoteConfigIsFetchedCachedAndCanDisableSdk() {
        val rig = Rig()
        rig.transport.configBody = """{"v":1,"key":"$KEY","rev":2,"enabled":true,"ttl_s":3600,"sample":1,"unknown_field":{"x":1}}"""
        val core = rig.core()
        core.refreshConfig()
        assertEquals(1, rig.transport.configCalls)
        assertEquals("https://c.cdnsb.net/v1/$KEY/config", rig.transport.urls.last())
        core.refreshConfig()
        assertEquals("ttl bitməyib", 1, rig.transport.configCalls)

        rig.env.time += 3_600_001
        rig.transport.configStatus = 304
        core.refreshConfig()
        assertEquals(2, rig.transport.configCalls)
        assertEquals("W/\"1\"", rig.transport.lastEtag)
        assertTrue(core.config.enabled)

        // Kill-switch: konfiq enabled=false qaytarır.
        core.track("Lead", null, null)
        rig.env.time += 3_600_001
        rig.transport.configStatus = 200
        rig.transport.configBody = """{"v":1,"key":"$KEY","rev":3,"enabled":false}"""
        core.refreshConfig()
        assertFalse(core.config.enabled)
        assertEquals(0, rig.queue.size())
        core.track("Lead", null, null)
        core.flush(force = true)
        assertEquals(0, rig.transport.posts.size)
        assertFalse(rig.core().config.enabled)
    }

    @Test
    fun unknownKeyDisablesSdkAndNetworkErrorKeepsOldConfig() {
        val rig = Rig()
        val core = rig.core()
        rig.transport.configStatus = -1
        core.refreshConfig()
        assertTrue(core.config.enabled)
        rig.transport.configStatus = 404
        core.refreshConfig(force = true)
        assertFalse(core.config.enabled)
        core.track("Lead", null, null)
        assertEquals(0, rig.queue.size())
    }

    @Test
    fun samplingZeroDropsEverything() {
        val rig = Rig()
        rig.store.put(Core.K_CONFIG, """{"enabled":true,"sample":0}""")
        val core = rig.core()
        core.track("Lead", null, null)
        core.identify("u", null)
        core.flush(force = true)
        assertEquals(0, rig.transport.posts.size)
    }

    @Test
    fun fractionMatchesWebTracker() {
        // Veb tracker-dəki FNV-1a ilə eyni dəyərlər (Node ilə hesablanıb).
        assertEquals(2166136261.0 / 4294967296.0, Util.fraction(""), 1e-12)
        val a = Util.fraction("a1b2c3d4-0000-4000-8000-000000000001")
        assertTrue(a >= 0.0 && a < 1.0)
        assertEquals(a, Util.fraction("a1b2c3d4-0000-4000-8000-000000000001"), 0.0)
        assertEquals(3826002220.0 / 4294967296.0, Util.fraction("a"), 1e-12)
    }

    @Test
    fun screenAndLifecycleEvents() {
        val rig = Rig()
        val core = rig.core()
        core.onForeground()
        core.screen("ProductDetail", null, Core.ORIGIN_AUTO)
        core.track("AddToCart", null, null)
        core.screen("Cart", mapOf("items" to 2))
        core.onBackground()
        assertEquals(listOf("SessionStart", "AppInstall", "AppOpen", "ScreenView", "AddToCart", "ScreenView"), rig.transport.names)
        val events = rig.transport.events
        assertFalse(events[2].has("screen"))
        assertEquals("ProductDetail", events[4].getJSONObject("screen").getString("name"))
        assertEquals("auto", events[3].getString("origin"))
        assertFalse(events[5].has("origin"))
        assertEquals(2L, events[5].getJSONObject("props").getLong("items"))
        rig.transport.posts.forEach { assertValid(it) }
    }

    @Test
    fun autoEventsCanBeDisabledLocallyAndRemotely() {
        val local = Rig(SmartBeeOptions(autoEvents = false))
        val a = local.core()
        a.onForeground()
        a.screen("Home", null, Core.ORIGIN_AUTO)
        a.onDeepLink("myapp://x?utm_source=fb")
        a.track("Lead", null, null)
        a.flush(force = true)
        assertEquals(listOf("Lead"), local.transport.names)

        val remote = Rig()
        remote.store.put(Core.K_CONFIG, """{"enabled":true,"auto":{"lifecycle":false,"screens":false,"deeplinks":false}}""")
        val b = remote.core()
        b.onForeground()
        b.screen("Home", null, Core.ORIGIN_AUTO)
        b.onDeepLink("myapp://x?utm_source=fb")
        b.track("Lead", null, null)
        b.flush(force = true)
        assertEquals(listOf("SessionStart", "Lead"), remote.transport.names)
        assertEquals("Home", remote.transport.events.last().getJSONObject("screen").getString("name"))
    }

    @Test
    fun resetCreatesNewIdentity() {
        val rig = Rig()
        val core = rig.core()
        core.identify("user-42", null)
        val before = core.anonymousId
        core.reset()
        core.track("Lead", null, null)
        core.flush(force = true)
        val lead = rig.transport.events.last()
        assertNotEquals(before, lead.getString("anon_id"))
        assertFalse(lead.has("user_id"))
        assertEquals(core.anonymousId, lead.getString("anon_id"))
        assertEquals(core.anonymousId, rig.store.get(Core.K_ANON))
    }

    @Test
    fun wrapperIsReported() {
        val rig = Rig(SmartBeeOptions(wrapper = "flutter", wrapperVersion = "1.0.0"))
        val core = rig.core()
        core.flush(force = true)
        val sdk = rig.transport.posts[0].getJSONObject("sdk")
        assertEquals("flutter", sdk.getString("wrapper"))
        assertEquals("1.0.0", sdk.getString("wrapper_version"))
        assertValid(rig.transport.posts[0])
    }

    @Test
    fun customEndpointIsUsed() {
        val rig = Rig(SmartBeeOptions(endpoint = "https://proxy.example.com/"))
        val core = rig.core()
        core.flush(force = true)
        assertEquals("https://proxy.example.com/v1/e", rig.transport.urls.last())
    }

    @Test
    fun remoteConfigParsingIsDefensive() {
        assertNull(RemoteConfig.parse(null))
        assertNull(RemoteConfig.parse("not json"))
        val c = RemoteConfig.parse("""{"sample":5,"ttl_s":1,"flush":{"max_batch":9999,"interval_s":0},"blocked_events":[1,"A"],"auto":{"screens":false}}""")!!
        assertEquals(1.0, c.sample, 0.0)
        assertEquals(60_000L, c.ttlMs)
        assertEquals(100, c.maxBatch)
        assertEquals(1000L, c.flushIntervalMs)
        assertEquals(setOf("A"), c.blockedEvents)
        assertFalse(c.auto("screens"))
        assertTrue(c.auto("lifecycle"))
    }

    @Test
    fun turkishLocaleDoesNotBreakKeyMatching() {
        // Türk / Azərbaycan dil ayarında "PIN".lowercase() "pın" verir; SDK dildən asılı olmamalıdır.
        val previous = java.util.Locale.getDefault()
        java.util.Locale.setDefault(java.util.Locale("tr", "TR"))
        try {
            val cleaned = Util.cleanObject(mapOf("PIN" to "1", "EMAIL" to "a@b.az", "FIN" to "x", "TITLE" to "ok"))!!
            assertEquals(setOf("TITLE"), cleaned.keySet())
            assertEquals("https://a.az/p?I=1", Util.cleanUrl("https://a.az/p?PIN=9&ID_TOKEN=z&API_KEY=k&I=1", setOf("pin")))
            assertEquals("farid.i@example.com", Util.normalizeEmail(" Farid.I@EXAMPLE.COM "))
            assertEquals("2026-11-25T07:00:05.120Z", Util.iso(1_795_590_005_120L))
            assertEquals(64, Util.sha256("İstanbul").length)
        } finally {
            java.util.Locale.setDefault(previous)
        }
    }

    @Test
    fun helpers() {
        assertEquals("2026-11-25T07:00:05.120Z", Util.iso(1_795_590_005_120L))
        assertEquals("myapp://open", Util.cleanUrl("myapp://open?token=1&Email=a%40b.az#x"))
        assertEquals("https://a.az/p?x=1", Util.cleanUrl("https://a.az/p?x=1&sid=9", setOf("sid")))
        assertNull(Util.campaignOf("https://a.az/p?x=1"))
        // Audit: veb tracker ilə eyni təmizləmə qaydaları.
        assertEquals("myapp://u/[redacted]/orders?ref=[redacted]&x=1", Util.cleanUrl("myapp://u/Farid.Test@Example.com/orders?ref=a%40b.az&x=1&refresh_token=zz&API_KEY=k"))
        assertEquals("https://shop.az/p", Util.cleanUrl("https://user:pass@shop.az/p?client_secret=1&otp=2"))
        assertEquals("https://mail.shop.az/x", Util.cleanUrl("https://mail.shop.az/x#frag"))
        assertEquals(JSONArray(listOf(1L, "a")).toString(), (Util.clean(arrayOf(1, "a"), 2) as JSONArray).toString())
    }
}
