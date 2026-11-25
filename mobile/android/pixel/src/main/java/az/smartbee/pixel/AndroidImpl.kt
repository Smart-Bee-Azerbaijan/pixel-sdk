package az.smartbee.pixel

import android.app.ActivityManager
import android.app.Application
import android.content.ContentValues
import android.content.Context
import android.content.res.Configuration
import android.database.DatabaseErrorHandler
import android.database.DefaultDatabaseErrorHandler
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.os.Build
import android.os.Process
import android.os.StrictMode
import android.util.Log
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.zip.GZIPOutputStream

/**
 * SDK-nın yeganə bazası: event növbəsi və açar-dəyər yaddaşı.
 *
 * Fayl tətbiqin şəxsi `noBackupFilesDir` qovluğundadır: Android-in avtomatik ehtiyat nüsxəsinə düşmür,
 * yəni anonim ID başqa cihaza bərpa olunub iki cihazda eyni olmur.
 */
internal class PixelDatabase(context: Context, tombstone: ConsentTombstone? = null) :
    SQLiteOpenHelper(
        context,
        File(context.noBackupFilesDir, "smartbee_pixel.db").absolutePath,
        null,
        1,
        DatabaseErrorHandler { db ->
            // Susmaya görə Android pozulmuş bazanı səssizcə silib yenisini yaradır və saxlanmış imtina itir.
            // Əvvəlcə nişan yazılır: razılıq «bildirilməyib» yox, «oxunmur» (rədd) sayılacaq.
            try {
                tombstone?.corrupted()
            } catch (t: Throwable) {
                // Nişan yazılmasa da baza bərpa olunmalıdır.
            }
            DefaultDatabaseErrorHandler().onCorruption(db)
        },
    ) {
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY AUTOINCREMENT, ctx TEXT NOT NULL, payload TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY NOT NULL, v TEXT NOT NULL)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        onCreate(db)
    }

    /**
     * Tətbiq SDK-nın köhnə versiyasına qaytarılıb: susmaya görə `SQLiteOpenHelper` istisna atır və SDK hər açılışda
     * ölü qalardı. Naməlum (daha yeni) sxem atılır və cədvəllər yenidən yaradılır: növbə və identifikatorlar itir,
     * SDK isə işləyir. Saxlanmış razılıq isə itmir: oxunursa yeni cədvələ köçürülür, oxunmursa «oxunmur» (rədd) kimi
     * qeyd olunur ki, əvvəlki imtina «heç vaxt bildirilməyib» sayılmasın.
     */
    override fun onDowngrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        val consent = try {
            db.rawQuery("SELECT v FROM kv WHERE k = 'consent'", null).use { c ->
                if (c.moveToFirst()) c.getString(0) ?: ConsentTombstone.CORRUPT else null
            }
        } catch (e: Exception) {
            ConsentTombstone.CORRUPT
        }
        db.execSQL("DROP TABLE IF EXISTS events")
        db.execSQL("DROP TABLE IF EXISTS kv")
        onCreate(db)
        if (consent != null) {
            val values = ContentValues()
            values.put("k", Core.K_CONSENT)
            values.put("v", consent)
            db.insertWithOnConflict("kv", null, values, SQLiteDatabase.CONFLICT_REPLACE)
        }
    }
}

/**
 * Razılıq nişanının faylı (bax [ConsentTombstone]): bazanın yanında, eyni `noBackupFilesDir` qovluğunda. Fayl bir
 * neçə baytdır və `setConsent`-i çağıran axında (bəlkə də əsas axında) yazılır, ona görə StrictMode-un disk qaydası
 * həmin an üçün götürülür (əks halda `penaltyDeath` işlədən tətbiq razılıq geri alınanda ölərdi). `fsync` edilmir:
 * məqsəd prosesin ölümünə davam gətirməkdir (yazılmış bayt nüvənin keşində qalır), əsas axını isə ləngitməməkdir.
 * Qovluğun yolu ilk əməliyyatda oxunur (`init` əsas axında diskə toxunmur).
 */
internal class ConsentFile(private val context: Context) : TombFile {
    private val file: File by lazy { File(context.noBackupFilesDir, "smartbee_pixel.consent") }

    private inline fun <T> io(block: () -> T): T {
        val policy = try {
            StrictMode.allowThreadDiskWrites()
        } catch (t: Throwable) {
            null
        }
        try {
            return block()
        } finally {
            if (policy != null) StrictMode.setThreadPolicy(policy)
        }
    }

    override fun read(): String? = io {
        when {
            !file.exists() -> null
            // Nişan bir sətirdir: böyük fayl pozulmuş sayılır.
            file.length() > MAX_BYTES -> ""
            else -> file.readText(Charsets.UTF_8)
        }
    }

    /**
     * Atomik yazı: mətn əvvəlcə yanındakı müvəqqəti fayla yazılır, sonra ad dəyişdirilir. Proses yazının ortasında
     * ölsə köhnə fayl bütöv qalır (yarımçıq və ya boş nişan yaranmır). Ad dəyişdirilə bilmirsə istisna atılır və
     * köhnə fayl yerində qalır.
     */
    override fun write(text: String) = io {
        val temp = File(file.path + ".tmp")
        try {
            FileOutputStream(temp).use { it.write(text.toByteArray(Charsets.UTF_8)) }
            replace(temp, file)
        } finally {
            if (temp.exists()) temp.delete()
        }
    }

    private fun replace(temp: File, target: File) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                java.nio.file.Files.move(
                    temp.toPath(), target.toPath(),
                    java.nio.file.StandardCopyOption.ATOMIC_MOVE, java.nio.file.StandardCopyOption.REPLACE_EXISTING,
                )
                return
            } catch (e: java.nio.file.AtomicMoveNotSupportedException) {
                // Aşağıdakı `rename` yoluna keçilir.
            }
        }
        // Android-in fayl sistemlərində `rename` hədəfi atomik əvəz edir.
        if (!temp.renameTo(target)) throw IOException("consent tombstone could not be written")
    }

    override fun delete() = io {
        if (file.exists() && !file.delete()) throw IOException("consent tombstone could not be deleted")
    }

    private companion object {
        const val MAX_BYTES = 64L
    }
}

/**
 * Açar-dəyər yaddaşı. Dəyərlər yaddaşda keşlənir; yazı dərhal diskə gedir. Əvvəlcə disk, sonra keş yenilənir:
 * yazı alınmasa (istisna) keş köhnə dəyərdə qalır və eyni dəyərin növbəti yazısı yenidən cəhd edir, yəni keşlə disk
 * heç vaxt ayrılmır (məsələn geri alınmış razılıq növbəti açılışda geri qayıtmır).
 */
internal class SqliteStore(private val helper: PixelDatabase) : Store {
    private val cache = HashMap<String, String>()

    init {
        helper.readableDatabase.query("kv", arrayOf("k", "v"), null, null, null, null, null).use { c ->
            while (c.moveToNext()) cache[c.getString(0)] = c.getString(1)
        }
    }

    override fun get(key: String): String? = cache[key]

    override fun put(key: String, value: String) {
        if (cache[key] == value) return
        val values = ContentValues()
        values.put("k", key)
        values.put("v", value)
        helper.writableDatabase.insertWithOnConflictOrThrow(values)
        cache[key] = value
    }

    override fun remove(key: String) {
        if (!cache.containsKey(key)) return
        helper.writableDatabase.delete("kv", "k = ?", arrayOf(key))
        cache.remove(key)
    }

    /** `insertWithOnConflict` xətanı udub -1 qaytarır; yazının alınmadığı çağırana bildirilməlidir. */
    private fun SQLiteDatabase.insertWithOnConflictOrThrow(values: ContentValues) {
        if (insertWithOnConflict("kv", null, values, SQLiteDatabase.CONFLICT_REPLACE) == -1L) {
            throw android.database.SQLException("kv write failed")
        }
    }
}

/**
 * SQLite üzərində event növbəsi.
 *
 * @param maxBytes növbənin diskdəki ən böyük ölçüsü (kontekst və event mətnlərinin UTF-8 baytları). Konfiqin
 * `max_queue` həddi sətir sayınadır (5000-ə qədər, hər event 32 KB-a qədər); bu hədd onu baytla tamamlayır.
 */
internal class SqliteQueue(private val helper: PixelDatabase, private val maxBytes: Long = MAX_QUEUE_BYTES) : EventQueue {
    private val writableDatabase: SQLiteDatabase get() = helper.writableDatabase
    private val readableDatabase: SQLiteDatabase get() = helper.readableDatabase

    /** Növbənin ölçüsü (bayt); mənfidirsə məlum deyil və növbəti [trim]-də bazadan hesablanır. */
    private var bytes = -1L

    override fun add(ctx: String, payload: String) {
        val values = ContentValues()
        values.put("ctx", ctx)
        values.put("payload", payload)
        writableDatabase.insert("events", null, values)
        if (bytes >= 0) bytes += Util.utf8Size(ctx) + Util.utf8Size(payload)
    }

    override fun peek(limit: Int): List<QueuedEvent> {
        val out = ArrayList<QueuedEvent>()
        readableDatabase.query("events", arrayOf("id", "ctx", "payload"), null, null, null, null, "id ASC", limit.toString()).use { c ->
            while (c.moveToNext()) out.add(QueuedEvent(c.getLong(0), c.getString(1), c.getString(2)))
        }
        return out
    }

    override fun remove(ids: List<Long>) {
        if (ids.isEmpty()) return
        // ID-lər yalnız bazanın öz verdiyi tam ədədlərdir.
        writableDatabase.delete("events", "id IN (" + ids.joinToString(",") + ")", null)
        bytes = -1
    }

    override fun size(): Int = readableDatabase.rawQuery("SELECT COUNT(*) FROM events", null).use { c ->
        if (c.moveToFirst()) c.getInt(0) else 0
    }

    override fun trim(max: Int) {
        val extra = size() - max
        if (extra > 0) {
            writableDatabase.execSQL("DELETE FROM events WHERE id IN (SELECT id FROM events ORDER BY id ASC LIMIT $extra)")
            bytes = -1
        }
        trimBytes()
    }

    /** Növbə [maxBytes]-dan böyükdürsə ən köhnə sətirlər atılır. */
    private fun trimBytes() {
        if (bytes < 0) {
            bytes = readableDatabase.rawQuery("SELECT COALESCE(SUM($ROW_BYTES), 0) FROM events", null).use { c ->
                if (c.moveToFirst()) c.getLong(0) else 0L
            }
        }
        if (bytes <= maxBytes) return
        var total = bytes
        var last = -1L
        readableDatabase.rawQuery("SELECT id, $ROW_BYTES FROM events ORDER BY id ASC", null).use { c ->
            while (total > maxBytes && c.moveToNext()) {
                last = c.getLong(0)
                total -= c.getLong(1)
            }
        }
        if (last >= 0) writableDatabase.delete("events", "id <= $last", null)
        bytes = total
    }

    override fun clear() {
        writableDatabase.delete("events", null, null)
        bytes = 0
    }

    override fun rewrite(transform: (QueuedEvent) -> QueuedEvent?) {
        var last = -1L
        while (true) {
            val page = ArrayList<QueuedEvent>()
            readableDatabase.query("events", arrayOf("id", "ctx", "payload"), "id > $last", null, null, null, "id ASC", REWRITE_PAGE.toString()).use { c ->
                while (c.moveToNext()) page.add(QueuedEvent(c.getLong(0), c.getString(1), c.getString(2)))
            }
            if (page.isEmpty()) break
            last = page[page.size - 1].id
            val changed = page.mapNotNull(transform)
            if (changed.isEmpty()) continue
            val db = writableDatabase
            // Səhifə ya bütöv yazılır, ya heç: yarımçıq təmizlənmiş sətir qalmır.
            db.beginTransaction()
            try {
                for (row in changed) {
                    val values = ContentValues()
                    values.put("ctx", row.ctx)
                    values.put("payload", row.payload)
                    db.update("events", values, "id = ${row.id}", null)
                }
                db.setTransactionSuccessful()
            } finally {
                db.endTransaction()
            }
        }
        bytes = -1
    }

    companion object {
        /** Növbənin diskdəki ən böyük ölçüsü: 5 MB. */
        const val MAX_QUEUE_BYTES = 5L * 1024 * 1024
        private const val REWRITE_PAGE = 100
        private const val ROW_BYTES = "LENGTH(CAST(ctx AS BLOB)) + LENGTH(CAST(payload AS BLOB))"
    }
}

/**
 * HttpURLConnection üzərində nəqliyyat. Yalnız HTTPS; sazlama rejimində lokal ünvanlara HTTP icazəlidir.
 */
internal class HttpTransport(private val debug: Boolean) : Transport {
    companion object {
        const val MAX_CONFIG_BYTES = 256 * 1024

        /** Rədd cavabının gövdəsindən oxunan ən böyük hissə (`{"ok":false,"error":"…"}` üçün artıqlaması ilə bəsdir). */
        const val MAX_ERROR_BYTES = 4096

        /** Axını ən çox `limit` bayta qədər oxuyur; limit aşılarsa null (böyük cavab yaddaşa yığılmır). */
        fun readLimited(input: InputStream, limit: Int): String? {
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                if (out.size() + n > limit) return null
                out.write(buffer, 0, n)
            }
            return String(out.toByteArray(), Charsets.UTF_8)
        }

        /** Yalnız HTTPS; sazlama rejimində lokal ünvanlara HTTP icazəlidir. */
        fun allowed(url: URL, debug: Boolean): Boolean {
            val local = url.host == "localhost" || url.host == "127.0.0.1" || url.host == "10.0.2.2"
            return url.protocol == "https" || (debug && local && url.protocol == "http")
        }
    }

    /**
     * Rədd cavabının (2xx olmayan) gövdəsi, məhdud ölçüdə: `error` kodunu oxumaq üçün (PROTOCOL.md 5.6).
     * Gövdə yoxdursa, böyükdürsə və ya oxunmursa null.
     */
    private fun errorBody(conn: HttpURLConnection): String? = try {
        conn.errorStream?.use { readLimited(it, MAX_ERROR_BYTES) }
    } catch (e: Exception) {
        null
    }

    private fun open(address: String): HttpURLConnection? {
        val url = URL(address)
        if (!allowed(url, debug)) return null
        val conn = url.openConnection() as HttpURLConnection
        conn.connectTimeout = 10_000
        conn.readTimeout = 15_000
        conn.instanceFollowRedirects = false
        conn.useCaches = false
        // Kuki: SDK özü heç bir kuki göndərmir və oxumur. Amma tətbiq `CookieHandler.setDefault(...)` qoyubsa
        // platformanın HttpURLConnection-u onu hər bağlantıda özü işlədir və bunu bir bağlantı üçün söndürməyin açıq
        // yolu yoxdur (`Cookie` başlığı sorğu göndəriləndə, bu koddan sonra əlavə olunur; `Set-Cookie` də birbaşa
        // tətbiqin kuki anbarına yazılır). Proses üzrə `CookieHandler`-i dəyişmək tətbiqin öz şəbəkəsinə toxunardı.
        conn.setRequestProperty("User-Agent", "SmartBeePixel-Android/$SDK_VERSION")
        return conn
    }

    /**
     * Ünvan icazəli deyil (HTTPS deyil və ya yararsızdır): sorğu göndərilmir. Nəticə şəbəkə xətası kimidir, yəni
     * yanlış `endpoint` seçimi növbəni silmir.
     */
    private fun blocked(): HttpResult {
        if (debug) Log.d("SmartBee", "endpoint is not allowed (HTTPS only), nothing is sent")
        return HttpResult(-1)
    }

    override fun post(url: String, json: String): HttpResult {
        val conn = try {
            open(url)
        } catch (e: Exception) {
            null
        } ?: return blocked()
        return try {
            val raw = ByteArrayOutputStream()
            GZIPOutputStream(raw).use { it.write(json.toByteArray(Charsets.UTF_8)) }
            val bytes = raw.toByteArray()
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.setFixedLengthStreamingMode(bytes.size)
            conn.setRequestProperty("Content-Type", "application/json")
            conn.setRequestProperty("Content-Encoding", "gzip")
            conn.outputStream.use { it.write(bytes) }
            val status = conn.responseCode
            val body = if (status in 200..299) null else errorBody(conn)
            HttpResult(status, body, retryAfterSec = conn.getHeaderField("Retry-After")?.trim()?.toLongOrNull())
        } catch (e: Exception) {
            HttpResult(-1)
        } finally {
            conn.disconnect()
        }
    }

    override fun get(url: String, etag: String?): HttpResult {
        val conn = try {
            open(url)
        } catch (e: Exception) {
            null
        } ?: return blocked()
        return try {
            conn.requestMethod = "GET"
            conn.setRequestProperty("Accept", "application/json")
            if (etag != null) conn.setRequestProperty("If-None-Match", etag)
            val status = conn.responseCode
            val body = when {
                status == 200 -> conn.inputStream.use { readLimited(it, MAX_CONFIG_BYTES) }
                status in 200..399 -> null
                else -> errorBody(conn)
            }
            HttpResult(status, body, conn.getHeaderField("ETag"))
        } catch (e: Exception) {
            HttpResult(-1)
        } finally {
            conn.disconnect()
        }
    }
}

/**
 * Google reklam ID-si (GAID). Kitabxana asılılıq kimi əlavə olunmayıb: `play-services-ads-identifier` tətbiqdə varsa
 * refleksiya ilə çağırılır, yoxdursa GAID sadəcə yoxdur. Çağırış bloklayır (Play xidmətlərinə qoşulur) və əsas
 * axında istisna atır, ona görə yalnız [AndroidEnv.offload] axınında işlədilir.
 */
internal class PlayAdId(private val context: Context) : AdIdLookup {
    override fun read(): AdInfo? {
        val client = try {
            Class.forName("com.google.android.gms.ads.identifier.AdvertisingIdClient")
        } catch (t: Throwable) {
            return null
        }
        val info = client.getMethod("getAdvertisingIdInfo", Context::class.java).invoke(null, context) ?: return null
        val id = info.javaClass.getMethod("getId").invoke(info) as? String
        // Seçim oxunmursa məhdudiyyət var sayılır.
        val limited = info.javaClass.getMethod("isLimitAdTrackingEnabled").invoke(info) as? Boolean ?: true
        return AdInfo(id, limited)
    }
}

/**
 * @param executor nüvənin axını; verilibsə bloklayan işlər ([offload]) ayrıca qısaömürlü axında gedir
 * @param adIds reklam ID-sinin mənbəyi
 */
internal class AndroidEnv(
    private val context: Context,
    private val executor: ScheduledExecutorService? = null,
    private val adIds: AdIdLookup? = null,
) : Env {
    private val static: String by lazy { buildStatic().toString() }

    override fun adIdLookup(): AdIdLookup? = adIds

    override fun offload(work: () -> Unit, done: () -> Unit) {
        val core = executor
        if (core == null) {
            super.offload(work, done)
            return
        }
        val thread = Thread({
            try {
                work()
            } catch (t: Throwable) {
                Log.w("SmartBee", "background work failed", t)
            }
            try {
                core.execute {
                    try {
                        done()
                    } catch (t: Throwable) {
                        Log.w("SmartBee", "internal error", t)
                    }
                }
            } catch (t: Throwable) {
                // SDK bu arada dayandırılıb: nəticə lazım deyil.
            }
        }, "smartbee-pixel-io")
        thread.isDaemon = true
        thread.priority = Thread.MIN_PRIORITY + 1
        thread.start()
    }

    override fun later(delayMs: Long, work: () -> Unit) {
        try {
            executor?.schedule({
                try {
                    work()
                } catch (t: Throwable) {
                    Log.w("SmartBee", "internal error", t)
                }
            }, delayMs, TimeUnit.MILLISECONDS)
        } catch (t: Throwable) {
            // SDK bu arada dayandırılıb.
        }
    }

    override fun now(): Long = System.currentTimeMillis()
    override fun uuid(): String = UUID.randomUUID().toString()
    override fun log(message: String) {
        Log.d("SmartBee", message)
    }

    override fun firstInstall(): Boolean = try {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        info.firstInstallTime == info.lastUpdateTime
    } catch (e: Exception) {
        true
    }

    override fun deviceContext(): JSONObject {
        val ctx = JSONObject(static)
        ctx.put("locale", Locale.getDefault().toLanguageTag())
        ctx.put("tz", TimeZone.getDefault().id)
        return ctx
    }

    private fun buildStatic(): JSONObject {
        val ctx = JSONObject()
        val app = JSONObject().put("id", context.packageName)
        try {
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            info.versionName?.let { app.put("version", it) }
            @Suppress("DEPRECATION")
            val code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
            app.put("build", code.toString())
        } catch (e: Exception) {
            // Versiya oxunmasa da paket adı göndərilir.
        }
        ctx.put("app", app)
        ctx.put("os", JSONObject().put("name", "Android").put("version", Build.VERSION.RELEASE ?: ""))
        val metrics = context.resources.displayMetrics
        val layout = context.resources.configuration.screenLayout and Configuration.SCREENLAYOUT_SIZE_MASK
        ctx.put(
            "device",
            JSONObject()
                .put("manufacturer", Build.MANUFACTURER ?: "")
                .put("model", Build.MODEL ?: "")
                .put("type", if (layout >= Configuration.SCREENLAYOUT_SIZE_LARGE) "tablet" else "phone"),
        )
        ctx.put("screen", JSONObject().put("w", metrics.widthPixels).put("h", metrics.heightPixels).put("density", metrics.density.toDouble()))
        return ctx
    }
}

/**
 * Çox prosesli tətbiqlərdə SDK yalnız əsas prosesdə işləyir: hər proses öz razılıq, sıra nömrəsi və
 * sessiya vəziyyətini qursaydı eyni bazaya ziddiyyətli yazılar gedərdi.
 */
internal object Processes {
    fun isMain(context: Context): Boolean = try {
        val main = context.applicationInfo?.processName ?: context.packageName
        val current = current(context)
        // Proses adı oxunmursa SDK söndürülmür.
        current.isNullOrEmpty() || main.isNullOrEmpty() || current == main
    } catch (t: Throwable) {
        true
    }

    private fun current(context: Context): String? {
        if (Build.VERSION.SDK_INT >= 28) return Application.getProcessName()
        val pid = Process.myPid()
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        return manager?.runningAppProcesses?.firstOrNull { it.pid == pid }?.processName
    }
}
