package az.smartbee.pixel

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/**
 * Ortaq təmizləmə vektorları (spec/vectors/sanitize-url.json, sanitize-props.json, identity.json, campaign.json).
 * Eyni fayllar veb tracker-in (tracker/test/vectors.test.js; gözlənilən dəyərlər onun nəticəsidir) və iOS-un
 * (SanitizeVectorsTests.swift) testlərində də işlədilir: üç SDK eyni girişdən eyni nəticəni almalıdır. Uyğun gəlməyən
 * hər vektor adı, gözlənilən və alınan dəyəri ilə birlikdə xəta mətnində sadalanır.
 */
class SanitizeVectorsTest {
    private val dir = File(System.getProperty("spec.dir") ?: error("spec.dir is not set"), "vectors")

    /** JSON dəyərini tətbiqin SDK-ya verdiyi adi Kotlin dəyərinə çevirir (`Map`, `List`, mətn, ədəd, `Boolean`, null). */
    private fun plain(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> LinkedHashMap<String, Any?>().also { out -> for (key in value.keys()) out[key] = plain(value.get(key)) }
        is JSONArray -> (0 until value.length()).map { plain(value.get(it)) }
        else -> value
    }

    private fun isNull(value: Any?) = value == null || value === JSONObject.NULL

    /** JSON dəyərlərinin dərin müqayisəsi; ədədlər qiymətinə görə müqayisə olunur (`1` və `1.0` eynidir). */
    private fun same(expected: Any?, got: Any?): Boolean {
        if (isNull(expected) || isNull(got)) return isNull(expected) && isNull(got)
        if (expected is JSONObject) {
            if (got !is JSONObject || expected.length() != got.length()) return false
            for (key in expected.keys()) if (!got.has(key) || !same(expected.get(key), got.get(key))) return false
            return true
        }
        if (expected is JSONArray) {
            if (got !is JSONArray || expected.length() != got.length()) return false
            for (i in 0 until expected.length()) if (!same(expected.get(i), got.get(i))) return false
            return true
        }
        if (expected is Number) return got is Number && java.math.BigDecimal(expected.toString()).compareTo(java.math.BigDecimal(got.toString())) == 0
        return expected == got
    }

    private fun run(file: String, min: Int, actual: (JSONObject) -> Any?) {
        val cases = JSONObject(File(dir, file).readText(Charsets.UTF_8)).getJSONArray("cases")
        assertTrue("$file: at least $min cases expected, found ${cases.length()}", cases.length() >= min)
        val failed = ArrayList<String>()
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val name = case.getString("name")
            if (!case.has("expected")) fail("$file: \"$name\" has no expected value")
            val expected = case.get("expected")
            val got = try {
                actual(case)
            } catch (e: Exception) {
                "EXCEPTION $e"
            }
            if (!same(expected, got)) failed.add("$name\n  expected: $expected\n  actual:   $got")
        }
        assertTrue("$file: ${failed.size} of ${cases.length()} vectors differ from the web tracker:\n" + failed.joinToString("\n"), failed.isEmpty())
    }

    /** Konfiqin `strip_params` siyahısı real konfiq oxuyucusundan keçir (adlar kiçik hərfə çevrilir). */
    private fun strip(case: JSONObject): Set<String> {
        val list = case.optJSONArray("strip") ?: return emptySet()
        return RemoteConfig.parse(JSONObject().put("strip_params", list).toString())!!.stripParams
    }

    @Suppress("UNCHECKED_CAST")
    private fun input(case: JSONObject): Map<String, Any?> = plain(case.getJSONObject("input")) as Map<String, Any?>

    @Test
    fun urlsAreCleanedExactlyLikeTheWebTracker() = run("sanitize-url.json", 60) { case ->
        Util.cleanUrl(case.getString("url"), strip(case), ads = case.optBoolean("ads", true))
    }

    @Test
    fun propsAndTraitsAreCleanedExactlyLikeTheWebTracker() = run("sanitize-props.json", 40) { case ->
        when (case.getString("kind")) {
            // kind: label — ekran adı (vebdə səhifə başlığı): giriş və nəticə mətndir.
            "label" -> Util.label(case.getString("input"))
            "traits" -> Util.cleanTraits(input(case))
            else -> Util.cleanObject(input(case))
        }
    }

    @Test
    fun userIdsAreNormalisedExactlyLikeTheWebTracker() = run("identity.json", 25) { case ->
        Util.userId(case.getString("input"))
    }

    @Test
    fun campaignsAreReadExactlyLikeTheWebTracker() = run("campaign.json", 20) { case ->
        Util.campaignOf(case.getString("url"), withClickIds = case.optBoolean("ads", true))
    }

    /** `identify` / `track` / `onDeepLink` nüvədən keçəndə də eyni nəticə göndərilir (vektorların bir qismi ilə). */
    @Test
    fun coreSendsTheSameValuesAsTheVectors() {
        val failed = ArrayList<String>()
        val identities = JSONObject(File(dir, "identity.json").readText(Charsets.UTF_8)).getJSONArray("cases")
        for (i in 0 until identities.length()) {
            val case = identities.getJSONObject(i)
            val rig = Rig()
            val core = rig.core()
            core.identify(case.getString("input"), null)
            core.flush(force = true)
            val event = rig.transport.events.lastOrNull { it.optString("type") == "identify" }
            val got: Any? = event?.opt("user_id")
            if (!same(case.get("expected"), got)) failed.add("identity: ${case.getString("name")}: expected ${case.get("expected")}, actual $got")
        }
        val props = JSONObject(File(dir, "sanitize-props.json").readText(Charsets.UTF_8)).getJSONArray("cases")
        for (i in 0 until props.length()) {
            val case = props.getJSONObject(i)
            val traits = case.getString("kind") == "traits"
            val rig = Rig()
            val core = rig.core()
            if (case.getString("kind") == "label") {
                core.screen(case.getString("input"), null)
                core.flush(force = true)
                val got: Any? = rig.transport.events.lastOrNull { it.optString("name") == "ScreenView" }?.optJSONObject("screen")?.opt("name")
                if (!same(case.get("expected"), got)) failed.add("label: ${case.getString("name")}: expected ${case.get("expected")}, actual $got")
                continue
            }
            if (traits) core.identify("vector-user", input(case)) else core.track("VectorEvent", input(case), null)
            core.flush(force = true)
            val event = rig.transport.events.lastOrNull { if (traits) it.optString("type") == "identify" else it.optString("name") == "VectorEvent" }
            val got: Any? = event?.opt(if (traits) "traits" else "props")
            if (!same(case.get("expected"), got)) failed.add("props: ${case.getString("name")}: expected ${case.get("expected")}, actual $got")
        }
        assertTrue("${failed.size} vectors differ when sent through Core:\n" + failed.joinToString("\n"), failed.isEmpty())
    }
}
