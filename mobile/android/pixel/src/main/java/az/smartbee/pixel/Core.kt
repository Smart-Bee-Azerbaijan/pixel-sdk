package az.smartbee.pixel

import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicReference

/**
 * SDK-nın bütün məntiqi. Android-dən asılı deyil və axın (thread) yaratmır:
 * bütün metodlar bir axından ardıcıl çağırılmalıdır (bunu [SmartBee] təmin edir).
 *
 * @param gate açıq çağırışların çağıran axında dərhal qoyduğu razılıq qadağaları (bax [ConsentGate])
 * @param tombstone çağıran axının diskə yazdığı imtina nişanı (bax [ConsentTombstone]); başlanğıcda icra olunur
 */
internal class Core(
    private val key: String,
    private val options: SmartBeeOptions,
    private val disk: Store,
    private val queue: EventQueue,
    private val transport: Transport,
    private val env: Env,
    private val gate: ConsentGate = ConsentGate(),
    private val tombstone: ConsentTombstone? = null,
) {
    private val endpoint = options.endpoint.trimEnd('/')

    /** Keşlənmiş konfiq, ETag və növbə bu açar və ünvana aiddir; başqası ilə başladılanda atılır. */
    private val binding = binding(key, options.endpoint)
    var config: RemoteConfig = RemoteConfig.DEFAULT
        private set

    /** Razılıq məlum olana və SDK işlək olana qədər yaddaşdakı müvəqqəti qat, sonra birbaşa disk. */
    private var store: Store = disk
    private var analytics = true
    private var ads = true

    /** İstifadəçinin `setConsent` ilə saxlanmış seçimi (`10` kimi iki simvol); yoxdursa null. */
    private var userConsent: String? = null

    /** `init`-in `consent` seçimi. Sonrakı `setConsent` onu əvəz edir (yeni açıq seçim daha təzədir). */
    private var initConsent: SmartBeeConsent? = options.consent

    /** Təkrar `init` çağırışının qoyduğu məhdudiyyətlər: yalnız sərtləşdirir, növbəti `setConsent`-ə qədər qalır. */
    private var restrictAnalytics = false
    private var restrictAds = false
    private var collectAdId = options.collectAdvertisingId

    /** Razılıq diskə yazıla bilməyib: yaddaşda qüvvədədir, yazı növbəti `flush`-da təkrarlanır. */
    private var consentUnsaved: String? = null

    /** Bu açar və ünvan üçün konfiq nə vaxtsa alınıb (keşdə var). */
    private var haveConfig = false

    /**
     * Server açarı tanımır və ya açar söndürülüb (`unknown_key`). Heç nə göndərilmir və yeni event yığılmır, amma növbə
     * silinmir; [KEY_OFF_TTL_MS]-dən sonra konfiq yenidən soruşulur.
     */
    private var keyOff = false
    private var keyOffAt = 0L

    /**
     * Konfiq heç vaxt alınmayıb və nə tətbiq, nə istifadəçi razılıq bildirməyib: serverin `consent_default` dəyəri
     * hələ məlum deyil. Bu vəziyyətdə heç nə diskə yazılmır və göndərilmir; eventlər yaddaşda gözləyir.
     */
    private var undecided = false
    private val held = ArrayList<String>()
    private var anonId = ""
    private var userId: String? = null
    private var screenName: String? = null
    private var manualScreen = false
    private var foreground = false
    private var inSessionStart = false
    private var failures = 0
    private var nextAttemptAt = 0L
    private var holdUntil = 0L
    private var configFailures = 0
    private var configRetryAt = 0L
    private var started = false
    private var updateNoticed = false
    private var lastLink: String? = null
    private var lastLinkAt = 0L

    /** Yalnız yaddaşda yaşayan GAID: nə açar-dəyər yaddaşına, nə növbəyə yazılır. */
    private var adId: String? = null
    private var adIdAt = 0L
    private var adIdPending = false

    /** Prosesin ilk GAID oxunuşu: bitənə qədər (ən çox [AD_ID_WAIT_MS]) ilk göndəriş gözlədilir. */
    private var adIdFirstDone = false
    private var adIdStartedAt = 0L
    private var adIdWake = false

    /** Razılıq yoxdursa və ya hələ məlum deyilsə null. */
    val anonymousId: String? get() = if (started && analytics && !undecided) anonId else null

    val flushIntervalMs: Long get() = config.flushIntervalMs

    val debug: Boolean get() = options.debug

    /** Açar server tərəfindən söndürülüb (`unknown_key`): heç nə yığılmır və göndərilmir. */
    val paused: Boolean get() = keyOff

    private val autoEvents: Boolean get() = options.autoEvents

    private fun log(message: String) {
        if (options.debug) env.log(message)
    }

    /** Sazlama rejimində bir sətir yazır ([SmartBee]-nin öz xəbərləri üçün). */
    fun note(message: String) = log(message)

    // ---- Başlanğıc ----------------------------------------------------------------------------

    fun start() {
        // Əvvəlki prosesdə razılıq geri alınıb, amma işçi axın onu bazaya yaza bilməyib (proses ölüb): nişan hər
        // şeydən əvvəl icra olunur, yəni köhnə növbə və identifikatorlar heç nə göndərilmədən silinir.
        val tomb = tombstone?.snapshot()
        if (tomb != null) {
            if (tomb.erase) erase()
            // Nişanın «oxunmur» (`??`) dəyəri bazadakı yararlı dəyərin üstünə yazılmır: saxlanmış seçim (bəlkə də imtina)
            // qalır. Yararlı dəyər (o cümlədən yarımçıq nişanın `00`-ı) saxlanmış seçimdən təzədir və onu əvəz edir.
            tomb.consent?.let { value ->
                val stored = disk.get(K_CONSENT)
                if (CONSENT_RE.matches(value) || stored == null || !CONSENT_RE.matches(stored)) saveConsent(value)
            }
        }
        rebind()
        val cached = RemoteConfig.parse(disk.get(K_CONFIG))
        config = cached ?: RemoteConfig.DEFAULT
        haveConfig = cached != null
        keyOffAt = disk.get(K_KEY_OFF_AT)?.toLongOrNull() ?: 0L
        keyOff = keyOffAt != 0L
        noticeUpdate()
        userConsent = storedConsent()
        undecided = !haveConfig && !stated()
        resolve()
        if (undecided || dormant()) store = PendingStore(disk)
        if (analytics) {
            anonId = store.get(K_ANON)?.takeIf { Util.ID_RE.matches(it) } ?: env.uuid().also { store.put(K_ANON, it) }
            userId = store.get(K_USER)?.let { Util.text(it, MAX_USER_ID) }?.takeIf { it.isNotEmpty() }
        } else {
            anonId = env.uuid()
            forget()
        }
        started = true
        if (!config.enabled) clearQueue()
        if (!ads || tomb?.scrub == true) adsOff()
        lifecycleVersionEvents()
        // Nişan icra olundu: razılıq bazadadırsa və gözləyən çağırış yoxdursa fayl silinir.
        tombstone?.settle(consentSaved)
    }

    /**
     * Bazadakı razılıq. Dəyər var, amma oxunmursa (pozulmuş baza, yarımçıq nişan) bu, «heç vaxt bildirilməyib» demək
     * deyil: saxlanmış imtina itmiş ola bilər, ona görə hər iki məqsəd istifadəçinin imtinası (`00`) sayılır. Tətbiqin
     * `init`-dəki `consent` seçimi onu yumşalda bilmir; yalnız yeni `setConsent` əvəz edir (pozulmuş dəyər diskdə
     * qalır: növbəti açılışda yenə rədd sayılır). iOS ilə eyni qayda.
     */
    private fun storedConsent(): String? {
        val saved = consentUnsaved ?: disk.get(K_CONSENT) ?: return null
        if (CONSENT_RE.matches(saved)) return saved
        log("stored consent is unreadable: both purposes stay denied until setConsent is called")
        return CONSENT_DENIED
    }

    /** Razılıq bazadadır (yazısı gözləmir). */
    val consentSaved: Boolean get() = consentUnsaved == null

    /** Saxlanmış konfiq və növbə başqa açara və ya ünvana aiddirsə atılır (identifikatorlar və razılıq qalır). */
    private fun rebind() {
        if (disk.get(K_BINDING) == binding) return
        for (k in listOf(K_CONFIG, K_CONFIG_ETAG, K_CONFIG_AT, K_KEY_OFF_AT)) disk.remove(k)
        clearQueue()
    }

    /** Konfiq və ya növbə diskə yazılmazdan əvvəl onların hansı açara aid olduğu qeyd olunur. */
    private fun bind() {
        if (disk.get(K_BINDING) != binding) disk.put(K_BINDING, binding)
    }

    private fun clearQueue() {
        if (queue.size() > 0) queue.clear()
        if (disk.get(K_STUCK) != null) disk.remove(K_STUCK)
    }

    /** Növbəni say və bayt həddinə endirir; atılan (ən köhnə) eventlər sazlama rejimində xəbər verilir. */
    private fun trimQueue() {
        if (!options.debug) {
            queue.trim(config.maxQueue)
            return
        }
        val before = queue.size()
        queue.trim(config.maxQueue)
        val dropped = before - queue.size()
        if (dropped > 0) log("queue is full (limit ${config.maxQueue} events / 5 MB), dropped $dropped oldest events")
    }

    /** Razılığı tətbiq (`init` seçimi) və ya istifadəçi (`setConsent`) bildiribsə true. */
    private fun stated(): Boolean = userConsent != null || initConsent != null

    /** Analitika tətbiq və ya istifadəçi tərəfindən açıq şəkildə rədd edilib: şəbəkəyə çıxılmır. */
    private fun deniedByHost(): Boolean = restrictAnalytics || (stated() && !analytics)

    /** Açar söndürülüb və ya konfiq SDK-nı söndürüb: event yığılmır və göndərilmir. */
    private fun dormant(): Boolean = keyOff || !config.enabled

    /**
     * Qüvvədə olan razılığı hesablayır. Hər məqsəd üçün ən məhdudlaşdırıcı açıq dəyər qalib gəlir: istifadəçinin
     * saxlanmış seçimi ilə `init`-in `consent` seçimindən biri `false` deyirsə nəticə `false`-dur. Heç biri yoxdursa
     * konfiqin `consent_default` dəyəri işləyir, o da [CONSENT_WHEN_UNSTATED]-dən yuxarı qalxa bilmir.
     */
    private fun resolve() {
        val user = userConsent
        val init = initConsent
        val a: Boolean
        val d: Boolean
        if (user != null || init != null) {
            a = (user == null || user[0] == '1') && (init == null || init.analytics)
            d = (user == null || user[1] == '1') && (init == null || init.ads)
        } else {
            a = CONSENT_WHEN_UNSTATED && config.consentAnalytics
            d = CONSENT_WHEN_UNSTATED && config.consentAds
        }
        analytics = a && !restrictAnalytics
        ads = d && !restrictAds
    }

    /** Analitika razılığı yoxdur: növbə, gözləyən eventlər və bütün identifikatorlar silinir. */
    private fun forget() {
        held.clear()
        store = disk
        undecided = false
        erase()
        userId = null
        lastLink = null
        dropAdId()
    }

    /** Növbəni və bütün identifikatorları diskdən silir. */
    private fun erase() {
        clearQueue()
        for (k in listOf(K_ANON, K_USER, K_SESSION, K_SEQ, K_CAMPAIGN, K_CAMPAIGN_AT, K_LAST_LINK)) disk.remove(k)
    }

    /**
     * Razılıq müsbət həll olundu: gözləyən yazılar diskə, gözləyən eventlər növbəyə keçir. SDK söndürülübsə
     * (açar naməlumdur və ya konfiq `enabled: false` deyir) identifikatorlar diskə yazılmır.
     *
     * Razılıq məlum olmayanda gələn keçidin klik ID-ləri yalnız yaddaşda saxlanır (gözləyən kampaniya və gözləyən
     * `DeepLinkOpen` eventi). Reklam razılığı yoxdursa onlar diskə yazılmazdan əvvəl, burada silinir; varsa itmir.
     */
    private fun settle() {
        if (dormant()) {
            held.clear()
            return
        }
        val adsOn = ads && !gate.adsDenied
        if (!adsOn) scrubCampaign()
        (store as? PendingStore)?.commit()
        store = disk
        if (held.isNotEmpty()) {
            bind()
            val ctx = context()
            if (ads) disk.put(K_ADS_ROWS, "1")
            for (payload in held) queue.add(ctx, if (adsOn) payload else withoutClickIds(payload))
            trimQueue()
            held.clear()
        }
    }

    /** `analytics` dəyəri dəyişə biləcək hər yerdən sonra çağırılır (razılıq artıq məlumdur). */
    private fun applyConsent(was: Boolean) {
        undecided = false
        if (!analytics) {
            forget()
            return
        }
        // Razılıq geri alınıb yenidən verilibsə köhnə anonim ID ilə əlaqə qalmamalıdır.
        if (!was) anonId = env.uuid()
        settle()
        store.put(K_ANON, anonId)
        if (!ads) adsOff()
        // Razılıq SDK başlayandan sonra verilibsə AppInstall / AppUpdate indi qiymətləndirilir (yenə bir dəfə).
        lifecycleVersionEvents()
    }

    /** İlk quraşdırmada AppInstall, versiya dəyişəndən sonrakı ilk açılışda AppUpdate. */
    private fun lifecycleVersionEvents() {
        if (!started || !analytics || dormant()) return
        val app = env.deviceContext().optJSONObject("app") ?: return
        val current = app.optString("version") + "|" + app.optString("build")
        val previous = store.get(K_APP_VERSION)
        if (previous == current) return
        store.put(K_APP_VERSION, current)
        if (!autoEvents || !config.auto("lifecycle")) return
        if (previous == null) {
            // SDK mövcud tətbiqə yeniləmə ilə əlavə olunubsa köhnə istifadəçi yeni quraşdırma sayılmır.
            if (env.firstInstall()) track("AppInstall", null, null, ORIGIN_AUTO)
        } else {
            track("AppUpdate", mapOf("previous_version" to previous.substringBefore('|'), "previous_build" to previous.substringAfter('|')), null, ORIGIN_AUTO)
        }
    }

    // ---- Açıq əməliyyatlar --------------------------------------------------------------------

    /**
     * `at`: eventin vaxtı (Unix, ms). [SmartBee] onu çağırış anında qeyd edir ki, işçi axın yavaş göndərişlə məşğul
     * olanda event gec vaxtla damğalanmasın (iOS ilə eyni qayda). Verilməyibsə indiki vaxt götürülür.
     */
    fun track(name: String?, props: Map<String, Any?>?, eventId: String?, origin: String = ORIGIN_CODE, at: Long? = null) {
        if (!started || !analytics || dormant()) return
        if (name == null || !Util.NAME_RE.matches(name)) {
            log("invalid event name: $name")
            return
        }
        if (config.blockedEvents.contains(name) || sampledOut()) return
        val event = base("track", origin, at)
        event.put("name", name)
        if (eventId != null) {
            if (Util.ID_RE.matches(eventId)) event.put("id", eventId) else log("invalid eventId, a generated id is used instead")
        }
        // Mətn dəyəri ünvandırsa ünvan kimi təmizlənir: konfiqin `strip_params` siyahısı və reklam razılığı ilə.
        Util.cleanObject(sized(props), ::log, config.stripParams, ads && !gate.adsDenied)?.let { event.put("props", it) }
        enqueue(event)
    }

    /** Həddən böyük `props` / `traits` (bax [Util.snapshot]) atılır, event onsuz gedir. */
    private fun sized(map: Map<String, Any?>?): Map<String, Any?>? {
        if (map !== Util.OVERSIZED) return map
        log("props are too large or self-referential, dropped")
        return null
    }

    fun identify(id: String?, traits: Map<String, Any?>?, at: Long? = null) {
        if (!started || !analytics || dormant()) return
        // E-poçt ünvanına və ya telefon nömrəsinə oxşayan istifadəçi ID-si açıq göndərilmir və saxlanmır: yerinə
        // normallaşdırılmış dəyərin SHA-256-sı işlədilir (veb tracker ilə eyni qayda, bax [Util.userId]).
        val user = Util.userId(id)
        if (user == null) {
            log("invalid user id")
            return
        }
        if (user != Util.text(id.orEmpty())) log("user id looks like an e-mail address or a phone number, its sha256 is sent instead")
        userId = user
        store.put(K_USER, user)
        if (sampledOut()) return
        val event = base("identify", ORIGIN_CODE, at)
        event.put("user_id", user)
        // E-poçt və telefon cihazı yalnız hash şəklində tərk edir. Açar adı dəqiq `email` / `phone` olmaya bilər
        // (`Email`, `user_email`, `msisdn`): belə açarın açıq dəyəri onsuz da atılır, hash isə itməməlidir.
        Util.cleanTraits(sized(traits), ::log, config.stripParams, ads && !gate.adsDenied)?.let { event.put("traits", it) }
        enqueue(event)
    }

    fun screen(name: String?, props: Map<String, Any?>?, origin: String = ORIGIN_CODE, at: Long? = null) {
        // Ekran adında e-poçta və telefon nömrəsinə bənzər hissələr gizlədilir (veb tracker-dəki səhifə başlığı kimi).
        // Ad ünvan şəklindədirsə ünvan kimi təmizlənir (konfiqin `strip_params` siyahısı və reklam razılığı ilə).
        val cleaned = Util.text(Util.label(Util.text(name.orEmpty(), MAX_SCREEN_INPUT), config.stripParams, ads && !gate.adsDenied), MAX_SCREEN_NAME)
        if (cleaned.isEmpty()) return
        if (origin == ORIGIN_AUTO) {
            // Avtomatik ad (Activity sinfi) söndürülübsə heç yerə yazılmır; örtüklərdə nativ ekran yalnız birdir;
            // tətbiq ekranı özü adlandırırsa avtomatik ad onu əvəz etmir.
            if (!autoEvents || !config.auto("screens") || options.wrapper != null || manualScreen) return
        } else {
            manualScreen = true
        }
        screenName = cleaned
        track("ScreenView", props, null, origin, at)
    }

    /**
     * İstifadəçinin seçimi əvvəlcə diskə yazılır, sonra yaddaşda qüvvəyə minir. Yazı alınmasa da seçim yaddaşda
     * tətbiq olunur və yazı sonra təkrarlanır: disk xətası köhnə razılığı geri qaytara bilməz.
     */
    fun setConsent(newAnalytics: Boolean?, newAds: Boolean?) {
        if (!started) return
        val was = analytics
        val value = (if (newAnalytics ?: analytics) "1" else "0") + (if (newAds ?: ads) "1" else "0")
        saveConsent(value)
        userConsent = value
        // Yeni açıq seçim `init`-dəki dəyərdən və təkrar `init`-in məhdudiyyətlərindən sonra gəlib.
        initConsent = null
        restrictAnalytics = false
        restrictAds = false
        resolve()
        applyConsent(was)
        // Analitika rədd ediləndə konfiq soruşulmurdu: razılıq veriləndə indi alınır.
        refreshConfig()
    }

    private fun saveConsent(value: String) {
        try {
            disk.put(K_CONSENT, value)
            consentUnsaved = null
        } catch (t: Throwable) {
            consentUnsaved = value
            log("consent could not be saved, it stays in effect in memory and the write is retried")
        }
    }

    /**
     * Təkrar `init` çağırışının seçimləri: yalnız sərtləşdirən hissəsi tətbiq olunur (`consent`-in `false` olan
     * məqsədləri və `collectAdvertisingId = false`); heç nə yumşaldılmır.
     */
    fun restrict(consent: SmartBeeConsent?, collectAdvertisingId: Boolean) {
        if (!started) return
        val was = analytics
        if (!collectAdvertisingId) collectAdId = false
        if (consent != null && !consent.analytics) restrictAnalytics = true
        if (consent != null && !consent.ads) restrictAds = true
        resolve()
        if (!analytics && was) applyConsent(was) else if (!ads) adsOff()
        refreshAdId()
    }

    /** `newId`: yeni anonim ID (açıq çağırışda yaradılır ki, `getAnonymousId()` dərhal onu qaytarsın). */
    fun reset(newId: String? = null) {
        if (!started) return
        flush(force = true)
        userId = null
        screenName = null
        manualScreen = false
        lastLink = null
        for (k in listOf(K_USER, K_SESSION, K_SEQ, K_CAMPAIGN, K_CAMPAIGN_AT, K_LAST_LINK)) store.remove(k)
        anonId = newId?.takeIf { Util.ID_RE.matches(it) } ?: env.uuid()
        if (analytics) store.put(K_ANON, anonId)
    }

    /**
     * Tətbiq ön plana keçdi. `tracked = false`: həyat dövrü izlənmir və arxa fon xəbəri gəlməyəcək,
     * ona görə sessiya əvvəlki kimi son fəaliyyətdən keçən vaxtla bitir. `at`: keçidin anı.
     * AppOpen konfiq sorğusundan əvvəl yazılır: yavaş şəbəkə onu gecikdirmir.
     */
    fun onForeground(tracked: Boolean = true, at: Long? = null) {
        if (!started) return
        if (tracked && !foreground) {
            // Sessiya tətbiq arxa fonda `session_timeout_s`-dən çox qaldıqda yenilənir (PROTOCOL.md 5.5).
            val (id, last) = savedSession()
            if (id.isNotEmpty() && env.now() - last > config.sessionTimeoutMs) store.remove(K_SESSION)
            foreground = true
        }
        // GAID hər ön plana keçiddə yenidən oxunur (istifadəçi onu sıfırlaya və ya məhdudlaşdıra bilər).
        refreshAdId(force = true)
        if (autoEvents && config.auto("lifecycle")) track("AppOpen", null, null, ORIGIN_AUTO, at)
        refreshConfig()
        flush()
    }

    /** Tətbiq arxa fona keçdi: növbə dərhal göndərilir. */
    fun onBackground() {
        if (!started) return
        foreground = false
        val (id, _) = savedSession()
        if (id.isNotEmpty()) store.put(K_SESSION, id + "|" + env.now())
        flush(force = true)
    }

    /**
     * `auto = true`: keçid Activity-nin intent-indən oxunub. Belə keçid proses bərpa olunanda (sistem tətbiqi öldürüb
     * yenidən yaradanda) eyni intent-lə yenə gələ bilər, ona görə son işlənmiş keçidin hash-i və vaxtı saxlanır və
     * [LINK_RESTORE_MS] ərzində eyni keçid yenidən sayılmır.
     */
    fun onDeepLink(url: String?, auto: Boolean = false, at: Long? = null) {
        if (!started || url.isNullOrEmpty()) return
        // Uzunluq hər hansı emaldan (regex, hash, təmizləmə) əvvəl yoxlanır.
        if (url.length > Util.MAX_URL_LENGTH) {
            log("deep link is longer than ${Util.MAX_URL_LENGTH} characters, ignored")
            return
        }
        if (!analytics || dormant()) return
        if (!Util.isLink(url)) {
            log("not a deep link, ignored")
            return
        }
        // Eyni keçid tətbiqə bir neçə yoldan ötürülə bilər: qısa müddətdə təkrarı bir dəfə sayılır (iOS ilə eyni qayda).
        val now = env.now()
        if (url == lastLink && now >= lastLinkAt && now - lastLinkAt < LINK_REPEAT_MS) return
        val hash = Util.sha256(url).substring(0, 16)
        if (auto) {
            val saved = store.get(K_LAST_LINK).orEmpty()
            val seenAt = saved.substringAfter('|', "").toLongOrNull() ?: 0L
            if (saved.substringBefore('|') == hash && now >= seenAt && now - seenAt < LINK_RESTORE_MS) return
        }
        lastLink = url
        lastLinkAt = now
        store.put(K_LAST_LINK, "$hash|$now")
        // Reklam razılığı yoxdursa klik ID-ləri nə diskə yazılır, nə göndərilir (UTM qalır). Razılıq hələ məlum
        // deyilsə `store` yaddaşdakı qatdır və event yaddaşda gözləyir: diskə nəyin düşəcəyini [settle] həll edir.
        val adsOn = ads && !gate.adsDenied
        Util.campaignOf(url, withClickIds = adsOn, extraStrip = config.stripParams)?.let {
            store.put(K_CAMPAIGN, it.toString())
            store.put(K_CAMPAIGN_AT, now.toString())
        }
        if (autoEvents && config.auto("deeplinks")) {
            // Reklam razılığı yoxdursa klik ID-ləri ünvanda da qalmır (kontekstin `campaign` hissəsi ilə eyni qayda).
            track("DeepLinkOpen", mapOf("url" to Util.cleanUrl(url, config.stripParams, ads = adsOn)), null, ORIGIN_AUTO, at)
        }
    }

    // ---- Eventin qurulması --------------------------------------------------------------------

    private fun sampledOut(): Boolean = config.sample < 1.0 && Util.fraction(anonId) >= config.sample

    /** Saxlanmış sessiya: ID və son fəaliyyət vaxtı. Yoxdursa və ya pozulubsa ID boşdur. */
    private fun savedSession(): Pair<String, Long> {
        val raw = store.get(K_SESSION).orEmpty()
        val sep = raw.lastIndexOf('|')
        if (sep <= 0) return "" to 0L
        val id = raw.substring(0, sep)
        val last = raw.substring(sep + 1).toLongOrNull() ?: 0L
        return if (Util.ID_RE.matches(id) && last > 0L) id to last else "" to 0L
    }

    /** `now` eventin vaxtıdır, `clock` cihazın indiki vaxtı. */
    private fun session(now: Long, clock: Long): String {
        var (id, last) = savedSession()
        var elapsed = now - last
        var stamp = now
        // Çağırış anında qeyd olunmuş vaxt növbədə gözləyərkən sessiyanın son vaxtından geri qala bilər;
        // cihazın saatı geri çəkilməyibsə bu, yeni sessiya demək deyil.
        if (elapsed < 0 && last <= clock) {
            elapsed = 0
            stamp = last
        }
        // Ön planda sessiya bitmir; ön plan vəziyyəti məlum deyilsə son fəaliyyətdən keçən vaxta baxılır.
        val expired = !foreground && elapsed > config.sessionTimeoutMs
        val fresh = id.isEmpty() || expired || elapsed < -60_000
        if (fresh) id = env.uuid()
        store.put(K_SESSION, "$id|$stamp")
        if (fresh && !inSessionStart && autoEvents) {
            inSessionStart = true
            try {
                track("SessionStart", null, null, ORIGIN_AUTO, now)
            } finally {
                inSessionStart = false
            }
        }
        return id
    }

    private fun nextSeq(): Long {
        val saved = store.get(K_SEQ)?.toLongOrNull() ?: -1L
        val next = if (saved < -1L || saved >= MAX_SEQ) 0L else saved + 1
        store.put(K_SEQ, next.toString())
        return next
    }

    private fun base(type: String, origin: String, at: Long?): JSONObject {
        val clock = env.now()
        val now = at ?: clock
        val sessionId = session(now, clock)
        val event = JSONObject()
        event.put("id", env.uuid())
        event.put("type", type)
        event.put("ts", Util.iso(now))
        event.put("anon_id", anonId)
        event.put("session_id", sessionId)
        event.put("seq", nextSeq())
        userId?.let { event.put("user_id", it) }
        if (origin != ORIGIN_CODE) event.put("origin", origin)
        screenName?.let { event.put("screen", JSONObject().put("name", it)) }
        return event
    }

    private fun dropCampaign() {
        store.remove(K_CAMPAIGN)
        store.remove(K_CAMPAIGN_AT)
    }

    /** Saxlanmış kampaniya; [CAMPAIGN_TTL_MS]-dən köhnədirsə və ya pozulubsa silinir. */
    private fun campaign(): JSONObject? {
        val saved = store.get(K_CAMPAIGN) ?: return null
        val storedAt = store.get(K_CAMPAIGN_AT)?.toLongOrNull() ?: 0L
        if (storedAt <= 0L || env.now() - storedAt > CAMPAIGN_TTL_MS) {
            dropCampaign()
            return null
        }
        return try {
            val parsed = JSONObject(saved)
            val out = JSONObject()
            for (name in parsed.keys()) {
                // Saxlanmış dəyər göndərilməzdən əvvəl yenə təmizlənir (veb tracker-in `pickCampaign` funksiyası kimi).
                val value = (parsed.opt(name) as? String)?.let { Util.campaignValue(it, config.stripParams, ads, Util.CAMPAIGN.contains(name)) }
                if (!value.isNullOrEmpty()) out.put(name, value)
            }
            // Reklam razılığı yoxdursa klik ID-ləri göndərilmir.
            if (!ads) for (id in Util.CLICK_IDS) out.remove(id)
            if (out.length() == 0) null else out
        } catch (e: Exception) {
            dropCampaign()
            null
        }
    }

    /** Reklam razılığı yoxdur: saxlanmış kampaniyadan klik ID-ləri diskdən də silinir. */
    private fun scrubCampaign() {
        val saved = store.get(K_CAMPAIGN) ?: return
        try {
            val parsed = JSONObject(saved)
            var changed = false
            for (id in Util.CLICK_IDS) if (parsed.has(id)) {
                parsed.remove(id)
                changed = true
            }
            if (!changed) return
            if (parsed.length() == 0) dropCampaign() else store.put(K_CAMPAIGN, parsed.toString())
        } catch (e: Exception) {
            dropCampaign()
        }
    }

    /**
     * Reklam razılığı yoxdur (geri alınıb, təkrar `init` məhdudlaşdırıb və ya konfiqin `consent_default` dəyəri
     * dəyişib): klik ID-ləri və reklam sahələri diskdən də silinir — saxlanmış kampaniyadan və növbədəki sətirlərdən.
     */
    private fun adsOff() {
        scrubCampaign()
        scrubQueue()
        // Cari ekran adı sonrakı eventlərə də yazılır: o da klik ID-siz qalmalıdır.
        screenName = screenName?.let { withoutClickIdsName(it) }?.takeIf { it.isNotEmpty() }
    }

    /**
     * Növbədəki sətirləri yerində təmizləyir: kontekstdən `ids` və klik ID-ləri çıxır, `consent.ads` false olur,
     * hər eventin `props` və `traits` hissəsi reklam razılığı olmadan yenidən təmizlənir (ünvan dəyərlərindən klik
     * ID-ləri silinir; veb tracker-in `scrubEvents` funksiyası kimi). Təmizlənmiş sətir razılıq yenidən veriləndə də reklam üçün
     * yararlı olmur. [K_ADS_ROWS] yoxdursa növbədə reklam razılığı ilə yazılmış sətir yoxdur və növbə oxunmur.
     */
    private fun scrubQueue() {
        if (disk.get(K_ADS_ROWS) == null) return
        val cache = HashMap<String, String>()
        queue.rewrite { row ->
            // Pozulmuş sətirə toxunulmur: [body] onu göndərişdə növbədən siləcək.
            val ctx = cache.getOrPut(row.ctx) { withoutAds(row.ctx) ?: row.ctx }
            val payload = withoutClickIds(row.payload)
            if (ctx == row.ctx && payload == row.payload) null else QueuedEvent(row.id, ctx, payload)
        }
        disk.remove(K_ADS_ROWS)
    }

    private fun context(): String {
        val ctx = Util.clampContext(env.deviceContext())
        ctx.put("platform", "android")
        ctx.put("consent", JSONObject().put("analytics", analytics).put("ads", ads))
        campaign()?.let { ctx.put("campaign", it) }
        val text = ctx.toString()
        if (!ctx.has("campaign") || Util.utf8Size(text) <= MAX_CTX_BYTES) return text
        // Serverin `ctx` həddi 8 KB-dır: böyük kampaniya sonrakı bütün topluları rədd etdirərdi.
        log("campaign too large, dropped")
        dropCampaign()
        ctx.remove("campaign")
        return ctx.toString()
    }

    private fun enqueue(event: JSONObject) {
        val payload = event.toString()
        if (Util.utf8Size(payload) > MAX_EVENT_BYTES) {
            log("event too large, dropped: " + event.optString("name"))
            return
        }
        if (undecided) {
            held.add(payload)
            if (held.size > MAX_HELD) {
                held.removeAt(0)
                log("more than $MAX_HELD events are waiting for the consent decision, dropped the oldest")
            }
            return
        }
        bind()
        val ctx = context()
        // Reklam razılığı ilə yazılan sətir: razılıq geri alınanda növbə təmizlənməlidir (bax [scrubQueue]).
        if (ads) disk.put(K_ADS_ROWS, "1")
        queue.add(ctx, payload)
        trimQueue()
        if (queue.size() >= config.maxBatch) flush()
    }

    // ---- Göndərmə -----------------------------------------------------------------------------

    /** `until` hələ gəlməyibsə true. Saat geri çəkilibsə (hədd ağlasığmaz uzaqdadırsa) köhnə hədd sonsuz gözlətmir. */
    private fun waiting(until: Long, now: Long): Boolean = now < until && until - now <= MAX_WAIT_MS

    private fun backoff(count: Int): Long {
        val base = minOf(BACKOFF_BASE_MS shl minOf(count - 1, 20), BACKOFF_MAX_MS)
        return (base * (0.8 + env.random() * 0.4)).toLong()
    }

    /**
     * Növbəni toplu-toplu göndərir. Uğursuzluqdan sonra artan fasilə gözlənilir;
     * `force` bu fasiləni nəzərə almır (arxa fona keçid, əl ilə flush), serverin `Retry-After` tələbini isə almır.
     */
    fun flush(force: Boolean = false) {
        if (!started) return
        consentUnsaved?.let {
            saveConsent(it)
            if (consentSaved) tombstone?.settle(true)
        }
        val now = env.now()
        if (undecided || keyOff) {
            // Razılıq məlum deyil və ya açar söndürülüb: əvvəlcə konfiq alınmalıdır (öz fasilələri ilə).
            refreshConfig()
            if (undecided || keyOff) return
        }
        if (!analytics || !config.enabled) {
            clearQueue()
            return
        }
        if (gate.analyticsDenied) return
        if (waiting(holdUntil, now)) return
        if (!force && waiting(nextAttemptAt, now)) return
        if (!force && adIdWait(now)) return
        var limit = config.maxBatch
        var rounds = 0
        val rewritten = HashMap<String, String>()
        var stuck = Stuck.parse(disk.get(K_STUCK))
        while (rounds++ < MAX_BATCHES_PER_FLUSH) {
            // Razılıq bu arada (başqa axında) geri alına bilər: hər sorğudan əvvəl yoxlanır.
            if (gate.analyticsDenied) return
            // Təcrid rejimi (bax [Stuck]): sətirlər bir-bir göndərilir.
            val rows = queue.peek(if (stuck != null && stuck.solo > 0) 1 else limit)
            if (rows.isEmpty()) {
                if (stuck != null) disk.remove(K_STUCK)
                return
            }
            // Eyni kontekstli ardıcıl eventlər bir topluya düşür (PROTOCOL.md 5.3). Ölçü UTF-8 baytla sayılır.
            // Müqayisə göndərilən kontekstlə aparılır: reklam razılığı geri alınıbsa yalnız reklam sahələri ilə
            // fərqlənən sətirlər eyni topluya düşür.
            val ctx = outgoing(rows[0].ctx, rewritten)
            val batch = ArrayList<QueuedEvent>()
            var bytes = Util.utf8Size(ctx) + 256
            for (row in rows) {
                val size = Util.utf8Size(row.payload)
                if (outgoing(row.ctx, rewritten) != ctx || (batch.isNotEmpty() && bytes + size > MAX_BODY_BYTES)) break
                batch.add(row)
                bytes += size + 1
            }
            val built = body(ctx, batch)
            if (built.bad.isNotEmpty()) {
                // Pozulmuş sətirlər: təkrar cəhdin mənası yoxdur. Yalnız onlar silinir, toplunun qalanı göndərilir.
                log("dropped ${built.bad.size} corrupt queue rows")
                queue.remove(built.bad)
            }
            val json = built.json ?: continue
            val result = try {
                transport.post("$endpoint/v1/e", json)
            } catch (e: Exception) {
                HttpResult(-1)
            }
            when (result.verdict(built.sent.size)) {
                HttpResult.RETRY -> {
                    failures++
                    // Serverin tələbi 0–20% müsbət kənarlaşma ilə: bütün cihazlar eyni saniyədə qayıtmasın.
                    val retryAfter = result.retryAfterSec?.let { (it.coerceIn(1, 3600) * 1000 * (1.0 + env.random() * 0.2)).toLong() }
                    val wait = retryAfter ?: backoff(failures)
                    nextAttemptAt = now + wait
                    if (retryAfter != null) holdUntil = now + retryAfter
                    log("send failed (${result.status}), retry in ${wait}ms")
                    if (!Stuck.counts(result.status)) {
                        // 5xx / şəbəkə xətası / 408 / 429: toplunun özü ilə bağlı deyil, ardıcıl 4xx sayğacı sıfırlanır.
                        if (stuck != null && stuck.solo == 0) disk.remove(K_STUCK)
                        return
                    }
                    // Tanınan kodu olmayan 4xx (WAF, proksi): eyni toplu ardıcıl rədd olunursa növbə əbədi bağlanmamalıdır.
                    val head = Util.sha256(batch[0].payload).substring(0, 16)
                    val solo = stuck?.solo ?: 0
                    var known = stuck?.takeIf { it.key == head }
                    if (known == null || now < known.since) known = Stuck(head, 0, now, solo)
                    val fails = known.fails + 1
                    if (solo == 0 && fails >= STUCK_BATCH_TRIES) {
                        // Toplu təcrid olunur: onun sətirləri bir-bir göndərilir (413-dəki bölmə yolu kimi).
                        stuck = Stuck(head, 0, known.since, built.sent.size)
                        disk.put(K_STUCK, stuck.text())
                        log("the same batch was rejected $fails times with ${result.status} and no known error code: its ${built.sent.size} events are now sent one by one")
                        if (built.sent.size > 1) continue
                        return
                    }
                    if (solo > 0 && (fails >= STUCK_ROW_TRIES || now - known.since >= STUCK_ROW_MS)) {
                        // Tək event də rədd olunur: atılır, qalan sətirlər davam edir.
                        log("event rejected $fails times with ${result.status} and no known error code, dropped: " + eventLabel(batch[0].payload))
                        queue.remove(built.sent)
                        stuck = if (solo > 1) Stuck("", 0, now, solo - 1) else null
                        if (stuck != null) disk.put(K_STUCK, stuck.text()) else disk.remove(K_STUCK)
                        failures = 0
                        nextAttemptAt = 0
                        continue
                    }
                    stuck = Stuck(head, fails, known.since, solo)
                    disk.put(K_STUCK, stuck.text())
                    return
                }
                HttpResult.SPLIT -> {
                    // Toplu server üçün böyükdür: hamısını atmaq əvəzinə yarısı ilə yenidən cəhd olunur.
                    limit = maxOf(1, built.sent.size / 2)
                    log("batch too large (413), retrying with $limit events")
                    continue
                }
                HttpResult.KEY_OFF -> {
                    log("batch rejected (${result.status} unknown_key), dropped ${built.sent.size} events")
                    queue.remove(built.sent)
                    keyDisabled(now)
                    return
                }
                HttpResult.DROP -> log("batch rejected (${result.status} ${result.error.orEmpty()}), dropped ${built.sent.size} events")
            }
            // Qəbul olundu və ya qəti rədd edildi: təkrar göndərilmir.
            failures = 0
            nextAttemptAt = 0
            holdUntil = 0
            queue.remove(built.sent)
            if (stuck != null) {
                // Təcrid olunmuş toplunun növbəti sətri; hamısı bitibsə adi göndərişə qayıdılır.
                stuck = if (stuck.solo > 1) Stuck("", 0, now, stuck.solo - 1) else null
                if (stuck != null) disk.put(K_STUCK, stuck.text()) else disk.remove(K_STUCK)
            }
        }
    }

    /** Sazlama loqu üçün eventin qısa təsviri (ad və ya tip, ID). */
    private fun eventLabel(payload: String): String = try {
        val event = JSONObject(payload)
        event.optString("name", event.optString("type")) + " " + event.optString("id")
    } catch (e: Exception) {
        "unreadable event"
    }

    /**
     * Tanınan `error` kodu olmayan `4xx` cavabı ilə ardıcıl rədd olunan toplunun vəziyyəti (bazada [K_STUCK] açarında,
     * proses yenidən başlasa da itmir). `key`: növbənin başındakı eventin mətninin hash-i; `fails`: bu başlıqla ardıcıl
     * rədlərin sayı; `since`: ilk rəddin vaxtı; `solo`: sıfırdan böyükdürsə təcrid rejimidir və hələ bu qədər sətir
     * bir-bir göndəriləcək.
     *
     * Qayda: eyni toplu [STUCK_BATCH_TRIES] dəfə ardıcıl rədd olunursa sətirləri bir-bir göndərilir; tək göndərilən
     * sətir [STUCK_ROW_TRIES] dəfə və ya [STUCK_ROW_MS] ərzində rədd olunursa atılır və qalanlar davam edir.
     * `5xx`, şəbəkə xətası, `408` və `429` sayılmır: onlar əvvəlki kimi hədsiz, artan fasilə ilə təkrarlanır.
     */
    private class Stuck(val key: String, val fails: Int, val since: Long, val solo: Int) {
        fun text(): String = "$key|$fails|$since|$solo"

        companion object {
            /** Tanınan kodu olmayan `4xx` (serverin fasilə tələbləri `408` / `429` istisna). */
            fun counts(status: Int): Boolean = status in 400..499 && status != 408 && status != 429

            fun parse(text: String?): Stuck? {
                val parts = text?.split('|') ?: return null
                if (parts.size != 4) return null
                val fails = parts[1].toIntOrNull() ?: return null
                val since = parts[2].toLongOrNull() ?: return null
                val solo = parts[3].toIntOrNull() ?: return null
                if (fails < 0 || solo < 0 || solo > RemoteConfig.MAX_BATCH) return null
                return Stuck(parts[0], fails, since, solo)
            }
        }
    }

    /**
     * Növbədəki sətirin göndərilən konteksti. Kontekst event növbəyə düşəndə qurulur; reklam razılığı indi yoxdursa
     * (sonradan geri alınıb) sətir `ctx.ids`-siz, klik ID-lərsiz (UTM qalır) və `consent.ads = false` ilə gedir:
     * server eventi reklam platformalarına yalnız `consent.ads` true olanda ötürür. Əks istiqamət yoxdur:
     * razılıqsız yaranmış sətir razılıq veriləndən sonra da `ads: false` ilə gedir. Razılıq geri alınanda sətirlər
     * diskdə də təmizlənir ([scrubQueue]); bura ikinci müdafiə xəttidir: imtina çağıran axında artıq qoyulub
     * ([ConsentGate]), amma nüvə onu hələ icra etməyib. `cache` bir `flush` daxilində eyni konteksti təkrar
     * çevirməmək üçündür.
     */
    private fun outgoing(ctx: String, cache: MutableMap<String, String>): String {
        if (ads && !gate.adsDenied) return ctx
        // Pozulmuş sətir olduğu kimi qalır: `body` də onu oxuya bilməyəcək və sətir növbədən silinəcək.
        return cache.getOrPut(ctx) { withoutAds(ctx) ?: ctx }
    }

    /** Kontekstin reklam sahələri olmayan halı (`ids` və klik ID-ləri yox, `consent.ads` false); oxunmursa null. */
    private fun withoutAds(ctx: String): String? = try {
        val context = JSONObject(ctx)
        context.remove("ids")
        val consent = context.optJSONObject("consent") ?: JSONObject().put("analytics", analytics).also { context.put("consent", it) }
        consent.put("ads", false)
        context.optJSONObject("campaign")?.let { campaign ->
            for (id in Util.CLICK_IDS) campaign.remove(id)
            if (campaign.length() == 0) context.remove("campaign")
        }
        context.toString()
    } catch (e: Exception) {
        null
    }

    /** Qurulmuş toplu: `json` null-dursa göndəriləsi sətir yoxdur. `bad` pozulmuş sətirlər, `sent` topluya düşənlərdir. */
    private class Built(val json: String?, val bad: List<Long>, val sent: List<Long>)

    /**
     * `ctx` artıq [outgoing]-dən keçmiş kontekstdir. Kontekstdə reklam razılığı yoxdursa (razılıqsız yaranmış və ya
     * razılığı sonradan geri alınmış sətirlər) eventlərin `props` / `traits` ünvanları da klik ID-lərsiz gedir.
     * Oxunmayan sətir ayrıca qeyd olunur: bir pozulmuş sətir bütün toplunu itirmir.
     */
    private fun body(ctx: String, batch: List<QueuedEvent>): Built {
        val context = try {
            JSONObject(ctx)
        } catch (e: Exception) {
            return Built(null, batch.map { it.id }, emptyList())
        }
        val adsOff = context.optJSONObject("consent")?.optBoolean("ads", false) != true
        val events = JSONArray()
        val bad = ArrayList<Long>()
        val sent = ArrayList<Long>()
        for (row in batch) {
            val event = try {
                JSONObject(row.payload)
            } catch (e: Exception) {
                bad.add(row.id)
                continue
            }
            if (adsOff) withoutClickIds(event)
            events.put(event)
            sent.add(row.id)
        }
        if (sent.isEmpty()) return Built(null, bad, sent)
        attachAdId(context)
        val sdk = JSONObject().put("name", "android").put("version", SDK_VERSION)
        // Yararsız örtük adı sxemi pozardı: göndərilmir.
        Util.wrapperName(options.wrapper)?.let { wrapper ->
            sdk.put("wrapper", wrapper)
            Util.wrapperVersion(options.wrapperVersion)?.let { sdk.put("wrapper_version", it) }
        }
        val json = JSONObject()
            .put("v", 1)
            .put("key", key)
            .put("sent_at", Util.iso(env.now()))
            .put("sdk", sdk)
            .put("ctx", context)
            .put("events", events)
            .toString()
        return Built(json, bad, sent)
    }

    /**
     * Eventin `props` və `traits` hissəsini və ekran adını (`screen.name`) reklam razılığı olmadan yenidən təmizləyir (veb
     * tracker-in `scrubEvents` funksiyası kimi; vebdə ekran adının qarşılığı səhifə başlığıdır): ünvan dəyərlərindən
     * (`DeepLinkOpen`-in `url`-i, tətbiqin öz verdiyi `link`, `landing`, ünvan şəklində ekran adı …) klik ID-ləri silinir,
     * UTM və başqa parametrlər qalır. Artıq təmizlənmiş dəyər dəyişmir. Dəyişiklik olubsa true.
     */
    private fun withoutClickIds(event: JSONObject): Boolean {
        var changed = false
        for (field in AD_FIELDS) {
            val value = event.optJSONObject(field) ?: continue
            val cleaned = Util.clean(value, 4, {}, config.stripParams, false) as? JSONObject ?: continue
            if (cleaned.toString() == value.toString()) continue
            if (cleaned.length() == 0) event.remove(field) else event.put(field, cleaned)
            changed = true
        }
        val screen = event.optJSONObject("screen")
        val name = screen?.opt("name") as? String
        if (screen != null && name != null) {
            val cleaned = withoutClickIdsName(name)
            if (cleaned != name) {
                if (cleaned.isEmpty()) event.remove("screen") else screen.put("name", cleaned)
                changed = true
            }
        }
        return changed
    }

    /** Ekran adı reklam razılığı olmadan yenidən təmizlənir (bax [Util.label]); nəticə boş ola bilər. */
    private fun withoutClickIdsName(name: String): String = Util.text(Util.label(name, config.stripParams, false), MAX_SCREEN_NAME)

    /** Saxlanan (və ya saxlanacaq) eventin mətni üçün eyni təmizləmə; dəyişiklik yoxdursa mətn olduğu kimi qayıdır. */
    private fun withoutClickIds(payload: String): String {
        if (!payload.contains("\"props\"") && !payload.contains("\"traits\"") && !payload.contains("\"screen\"")) return payload
        return try {
            val event = JSONObject(payload)
            if (withoutClickIds(event)) event.toString() else payload
        } catch (e: Exception) {
            payload
        }
    }

    // ---- Reklam ID-si (GAID) -------------------------------------------------------------------

    /** GAID yalnız tətbiq söndürməyibsə və həm analitika, həm reklam razılığı qüvvədədirsə oxunur və göndərilir. */
    private fun adIdAllowed(): Boolean =
        collectAdId && started && analytics && ads && !undecided && !dormant() && !gate.analyticsDenied && !gate.adsDenied

    private fun dropAdId() {
        adId = null
        adIdAt = 0
    }

    /**
     * GAID-i oxuyur: ilk dəfə, icazə yenidən yarananda və (`force`) hər ön plana keçiddə. Oxuma bloklayır, ona görə
     * nüvənin axınından kənarda gedir ([Env.offload]). İcazə yoxdursa (razılıq geri alınıb) yaddaşdakı dəyər silinir.
     */
    fun refreshAdId(force: Boolean = false) {
        if (!adIdAllowed()) {
            dropAdId()
            return
        }
        if (adIdPending) return
        val now = env.now()
        if (!force && adIdAt != 0L) return
        try {
            val lookup = env.adIdLookup()
            if (lookup == null) {
                adIdAt = now
                adIdFirstDone = true
                return
            }
            adIdPending = true
            adIdStartedAt = now
            val found = AtomicReference<AdInfo?>()
            env.offload(
                {
                    // Kitabxana yoxdur, Play xidmətləri cavab vermir və s.: GAID sadəcə yoxdur.
                    found.set(try { lookup.read() } catch (t: Throwable) { null })
                },
                {
                    adIdPending = false
                    // Cavab gələnə qədər razılıq geri alına bilər.
                    if (adIdAllowed()) {
                        adId = Util.adId(found.get())
                        adIdAt = env.now()
                    } else {
                        dropAdId()
                    }
                    if (!adIdFirstDone) {
                        adIdFirstDone = true
                        // İlk oxunuşu gözləyən göndəriş (AppInstall / AppOpen) indi GAID ilə gedir.
                        if (adIdWake) flush()
                    }
                },
            )
        } catch (t: Throwable) {
            adIdPending = false
            adIdFirstDone = true
            adId = null
            adIdAt = now
        }
    }

    /**
     * Prosesin ilk GAID oxunuşu hələ davam edirsə true: göndəriş ən çox [AD_ID_WAIT_MS] gözlədilir ki, ilk toplu
     * (AppInstall, AppOpen) GAID-siz getməsin. Event yığımı bloklanmır; oxunuş bitəndə və ya vaxt dolanda göndəriş
     * özü təkrarlanır.
     */
    private fun adIdWait(now: Long): Boolean {
        if (adIdFirstDone || !adIdPending || !adIdAllowed()) return false
        if (now - adIdStartedAt !in 0 until AD_ID_WAIT_MS) return false
        if (!adIdWake) {
            adIdWake = true
            env.later(AD_ID_WAIT_MS - (now - adIdStartedAt) + 50) { flush() }
        }
        return true
    }

    /**
     * GAID-i göndərilən toplunun kontekstinə əlavə edir. Növbədəki sətirlərin konteksti GAID daşımır (diskə yazılmır),
     * ona görə razılıq geri alınandan sonra göndərilən heç bir topluda, köhnə sətirlər daxil, GAID olmur.
     * Reklam razılığı olmadan yaranmış sətirlərə sonradan da əlavə edilmir.
     */
    private fun attachAdId(ctx: JSONObject) {
        if (!adIdAllowed()) {
            dropAdId()
            return
        }
        val id = adId ?: return
        if (ctx.optJSONObject("consent")?.optBoolean("ads", false) != true) return
        val ids = ctx.optJSONObject("ids") ?: JSONObject().also { ctx.put("ids", it) }
        ids.put("gaid", id)
    }

    // ---- Konfiq -------------------------------------------------------------------------------

    /** Yeni SDK versiyası çıxıbsa sazlama rejimində bir dəfə xəbər verir (konfiqin `sdk_latest` sahəsi). */
    private fun noticeUpdate() {
        if (updateNoticed) return
        val latest = config.sdkLatest
        if (!Util.newerVersion(latest, SDK_VERSION)) return
        updateNoticed = true
        log("SmartBee Pixel $latest is available (this app uses $SDK_VERSION). Update the dependency to get fixes.")
    }

    /** Konfiq köhnəlibsə serverdən yeniləyir. */
    fun refreshConfig(force: Boolean = false) {
        if (!started) return
        fetchConfig(force)
        // Konfiq razılığı (`consent_default`) dəyişə bilər: GAID-in icazəsi də burada yoxlanır.
        refreshAdId()
    }

    /** Server açarı tanımır (`unknown_key`): SDK dayanır, növbə və keşlənmiş konfiq qalır, sonra yenidən yoxlanır. */
    private fun keyDisabled(now: Long) {
        keyOff = true
        keyOffAt = now
        held.clear()
        bind()
        disk.put(K_KEY_OFF_AT, now.toString())
        log("the key is unknown or disabled (unknown_key): nothing is sent, the queue is kept, next check in ${KEY_OFF_TTL_MS / 60_000} min")
    }

    private fun fetchConfig(force: Boolean) {
        // Analitika açıq şəkildə rədd edilibsə şəbəkəyə çıxılmır (IP və açar serverə getmir).
        if (gate.analyticsDenied || deniedByHost()) return
        val now = env.now()
        if (!force) {
            if (waiting(configRetryAt, now)) return
            if (keyOff) {
                if (now - keyOffAt in 0 until KEY_OFF_TTL_MS) return
            } else {
                val fetchedAt = disk.get(K_CONFIG_AT)?.toLongOrNull() ?: 0L
                if (haveConfig && fetchedAt != 0L && now - fetchedAt in 0 until config.ttlMs) return
            }
        }
        val result = try {
            transport.get("$endpoint/v1/$key/config", if (haveConfig) disk.get(K_CONFIG_ETAG) else null)
        } catch (e: Exception) {
            HttpResult(-1)
        }
        val parsed = if (result.status == 200) RemoteConfig.parse(result.body) else null
        when {
            parsed != null -> {
                config = parsed
                noticeUpdate()
                bind()
                disk.put(K_CONFIG, result.body.orEmpty())
                result.etag?.let { disk.put(K_CONFIG_ETAG, it) } ?: disk.remove(K_CONFIG_ETAG)
                disk.put(K_CONFIG_AT, now.toString())
                haveConfig = true
            }
            result.status == 304 && haveConfig -> disk.put(K_CONFIG_AT, now.toString())
            // Yalnız serverin öz açıq cavabı açarı söndürür; başqa hər 404 / 4xx / 5xx müvəqqətidir (PROTOCOL.md 5.6).
            result.status == 404 && result.error == HttpResult.ERROR_UNKNOWN_KEY -> {
                configFailures = 0
                configRetryAt = 0
                keyDisabled(now)
                return
            }
            else -> {
                // Cavab alınmadı: keşlənmiş konfiq qüvvədə qalır, növbəti cəhd artan fasilə ilə.
                configFailures++
                configRetryAt = now + backoff(configFailures)
                return
            }
        }
        configFailures = 0
        configRetryAt = 0
        if (keyOff) {
            keyOff = false
            keyOffAt = 0
            disk.remove(K_KEY_OFF_AT)
        }
        // Yeni konfiqin `consent_default` dəyəri: tətbiq razılıq verməyibsə və istifadəçi seçim etməyibsə
        // dərhal qüvvəyə minir (iOS ilə eyni qayda). Açıq bildirilmiş razılığa konfiq toxunmur.
        val was = analytics
        resolve()
        applyConsent(was)
        if (!config.enabled) clearQueue()
    }

    companion object {
        const val ORIGIN_CODE = "code"
        const val ORIGIN_AUTO = "auto"
        const val MAX_EVENT_BYTES = 32_000
        const val MAX_BODY_BYTES = 450_000

        /** Serverin `ctx` həddi 8 KB-dır. */
        const val MAX_CTX_BYTES = 7_000
        const val MAX_USER_ID = 128
        const val MAX_SCREEN_NAME = 128

        /** Ekran adının təmizlənməzdən əvvəlki ən böyük uzunluğu. */
        const val MAX_SCREEN_INPUT = 2048

        /** JSON ədədinin itkisiz saxlaya bildiyi ən böyük tam ədəd (2^53). */
        const val MAX_SEQ = 9_007_199_254_740_992L

        /** Razılıq məlum olana qədər yaddaşda gözləyən eventlərin ən böyük sayı. */
        const val MAX_HELD = 100

        /** Bu müddətdə təkrar ötürülən eyni keçid bir dəfə sayılır. */
        const val LINK_REPEAT_MS = 5_000L

        /** Activity-dən oxunan eyni keçid bu müddətdə (proses bərpa olunsa da) yenidən sayılmır. */
        const val LINK_RESTORE_MS = 1_800_000L
        const val MAX_BATCHES_PER_FLUSH = 20
        const val BACKOFF_BASE_MS = 5_000L
        const val BACKOFF_MAX_MS = 3_600_000L

        /** Ən uzun mümkün gözləmə (1 saat + 20% kənarlaşma); bundan uzaq hədd saatın geri çəkilməsi deməkdir. */
        const val MAX_WAIT_MS = BACKOFF_MAX_MS + BACKOFF_MAX_MS / 5 + 1_000L

        /** Söndürülmüş açar bu müddətdən sonra yenidən yoxlanır. */
        const val KEY_OFF_TTL_MS = 3_600_000L

        /** Saxlanmış kampaniyanın (son toxunuş) ömrü: 90 gün. */
        const val CAMPAIGN_TTL_MS = 90L * 86_400_000L

        /** Prosesin ilk göndərişi ilk GAID oxunuşunu ən çox bu qədər gözləyir. */
        const val AD_ID_WAIT_MS = 2_500L

        const val K_ANON = "anon_id"
        const val K_USER = "user_id"
        const val K_SESSION = "session"
        const val K_SEQ = "seq"
        const val K_CONSENT = "consent"
        const val K_CAMPAIGN = "campaign"
        const val K_CAMPAIGN_AT = "campaign_at"
        const val K_LAST_LINK = "last_link"
        const val K_APP_VERSION = "app_version"
        const val K_CONFIG = "config"
        const val K_CONFIG_ETAG = "config_etag"
        const val K_CONFIG_AT = "config_at"
        const val K_BINDING = "binding"
        const val K_KEY_OFF_AT = "key_off_at"

        /** Növbədə reklam razılığı ilə (`consent.ads: true`) yazılmış sətir ola bilər. */
        const val K_ADS_ROWS = "ads_rows"

        /** Tanınan kodu olmayan `4xx` ilə ardıcıl rədd olunan toplunun vəziyyəti (bax [Stuck]). */
        const val K_STUCK = "stuck"

        /** Eyni toplu bu qədər ardıcıl kodsuz `4xx` alandan sonra sətirləri bir-bir göndərilir. */
        const val STUCK_BATCH_TRIES = 3

        /** Tək göndərilən event bu qədər kodsuz `4xx` alandan və ya bu müddətdən sonra (hansı tez olsa) atılır. */
        const val STUCK_ROW_TRIES = 5
        const val STUCK_ROW_MS = 3L * 86_400_000L

        /** Reklam razılığı geri alınanda yenidən təmizlənən event hissələri. */
        val AD_FIELDS = listOf("props", "traits")

        /** Saxlanmış razılığın yararlı forması: analitika və reklam üçün `0` / `1`. */
        val CONSENT_RE = Regex("^[01]{2}$")
        const val CONSENT_DENIED = "00"

        /** Keşin və növbənin aid olduğu açar və ünvan. */
        fun binding(key: String, endpoint: String): String = key + "|" + endpoint.trimEnd('/')
    }
}
