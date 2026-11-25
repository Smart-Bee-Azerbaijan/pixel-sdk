package az.smartbee.pixel

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.ByteArrayInputStream
import java.net.URL

/** Android-ə bağlı qatın (SQLite, kontekst, nəqliyyat qaydaları) Robolectric ilə yoxlanması. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AndroidLayerTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext()

    @Test
    fun databaseLivesInNoBackupDirectory() {
        val db = PixelDatabase(context)
        db.writableDatabase
        val path = db.readableDatabase.path
        assertTrue(path, path.startsWith(context.noBackupFilesDir.absolutePath))
        assertFalse(context.getDatabasePath("smartbee_pixel.db").exists())
        db.close()
    }

    @Test
    fun queueKeepsOrderSurvivesReopenAndTrims() {
        val first = PixelDatabase(context)
        val queue = SqliteQueue(first)
        queue.clear()
        for (i in 1..5) queue.add("{\"c\":1}", "{\"n\":$i}")
        assertEquals(5, queue.size())
        assertEquals(listOf("{\"n\":1}", "{\"n\":2}"), queue.peek(2).map { it.payload })
        queue.remove(listOf(queue.peek(1)[0].id))
        queue.remove(emptyList())
        first.close()

        val reopened = SqliteQueue(PixelDatabase(context))
        assertEquals(4, reopened.size())
        assertEquals("{\"n\":2}", reopened.peek(1)[0].payload)
        assertEquals("{\"c\":1}", reopened.peek(1)[0].ctx)
        reopened.trim(2)
        assertEquals(listOf("{\"n\":4}", "{\"n\":5}"), reopened.peek(10).map { it.payload })
        reopened.trim(10)
        assertEquals(2, reopened.size())
        reopened.clear()
        assertEquals(0, reopened.size())
        assertTrue(reopened.peek(10).isEmpty())
    }

    @Test
    fun queueStoresTextThatLooksLikeSqlVerbatim() {
        val queue = SqliteQueue(PixelDatabase(context))
        queue.clear()
        val evil = "'); DROP TABLE events; --"
        queue.add(evil, evil)
        assertEquals(evil, queue.peek(1)[0].payload)
        assertEquals(evil, queue.peek(1)[0].ctx)
        assertEquals(1, queue.size())
    }

    @Test
    fun storePersistsAcrossInstances() {
        val a = SqliteStore(PixelDatabase(context))
        a.put("anon_id", "id-1")
        a.put("anon_id", "id-2")
        a.put("consent", "10")
        a.put("gone", "x")
        a.remove("gone")
        a.remove("never-existed")
        assertEquals("id-2", a.get("anon_id"))

        val b = SqliteStore(PixelDatabase(context))
        assertEquals("id-2", b.get("anon_id"))
        assertEquals("10", b.get("consent"))
        assertNull(b.get("gone"))
        b.put("k'; DROP TABLE kv; --", "v")
        assertEquals("v", SqliteStore(PixelDatabase(context)).get("k'; DROP TABLE kv; --"))
    }

    @Test
    fun coreWorksOnTopOfRealStorage() {
        val database = PixelDatabase(context)
        val queue = SqliteQueue(database).also { it.clear() }
        val posts = ArrayList<String>()
        val transport = object : Transport {
            override fun post(url: String, json: String): HttpResult {
                posts.add(json)
                return HttpResult(200)
            }

            override fun get(url: String, etag: String?): HttpResult = HttpResult(200, "{\"enabled\":true}")
        }
        val core = Core("demo0andr1", opts(), SqliteStore(database), queue, transport, AndroidEnv(context))
        core.start()
        // İlk işə düşmədə razılıq konfiq cavabından sonra məlum olur.
        core.refreshConfig()
        core.track("Purchase", mapOf("value" to 250, "currency" to "AZN"), "order:A-1")
        assertTrue(queue.size() >= 2)
        core.flush(force = true)
        assertEquals(0, queue.size())
        assertTrue(posts.joinToString().contains("\"name\":\"Purchase\""))
        assertTrue(posts.joinToString().contains("\"platform\":\"android\""))

        // Yenidən başlayanda identifikator eynidir və AppInstall təkrarlanmır.
        val again = Core("demo0andr1", opts(), SqliteStore(PixelDatabase(context)), queue, transport, AndroidEnv(context))
        again.start()
        assertEquals(core.anonymousId, again.anonymousId)
        posts.clear()
        again.flush(force = true)
        assertFalse(posts.joinToString().contains("AppInstall"))
    }

    @Test
    fun deviceContextHasRequiredFields() {
        val ctx = AndroidEnv(context).deviceContext()
        assertEquals(context.packageName, ctx.getJSONObject("app").getString("id"))
        assertEquals("Android", ctx.getJSONObject("os").getString("name"))
        assertNotNull(ctx.getJSONObject("device").getString("type"))
        assertTrue(ctx.getString("tz").isNotEmpty())
        assertTrue(ctx.getString("locale").isNotEmpty())
        assertFalse("reklam identifikatoru oxunmur", ctx.has("ids"))
    }

    @Test
    fun transportAllowsOnlyHttps() {
        assertTrue(HttpTransport.allowed(URL("https://c.cdnsb.net/v1/e"), debug = false))
        assertFalse(HttpTransport.allowed(URL("http://c.cdnsb.net/v1/e"), debug = false))
        assertFalse(HttpTransport.allowed(URL("http://c.cdnsb.net/v1/e"), debug = true))
        assertFalse(HttpTransport.allowed(URL("http://localhost:8787/v1/e"), debug = false))
        assertTrue(HttpTransport.allowed(URL("http://10.0.2.2:8787/v1/e"), debug = true))
        // İcazəsiz ünvana sorğu göndərilmir: şəbəkəyə çıxmadan rədd olunur.
        assertEquals(-1, HttpTransport(false).post("http://example.invalid/v1/e", "{}").status)
        assertEquals(-1, HttpTransport(false).get("http://example.invalid/v1/x/config", null).status)
        assertEquals(-1, HttpTransport(false).post("not a url", "{}").status)
    }

    @Test
    fun responseReadingIsBounded() {
        assertEquals("abc", HttpTransport.readLimited(ByteArrayInputStream("abc".toByteArray()), 10))
        assertNull(HttpTransport.readLimited(ByteArrayInputStream(ByteArray(300_000)), HttpTransport.MAX_CONFIG_BYTES))
        assertEquals("", HttpTransport.readLimited(ByteArrayInputStream(ByteArray(0)), 10))
    }
}
