# SmartBee Pixel — Protokol v1

Vəziyyət: **qaralama**. Təsdiqlənəndən sonra bu sənəddəki hər şey dondurulur: yalnız yeni, məcburi olmayan sahələr əlavə oluna bilər.

Maşınla yoxlanan forma: [schema/batch.v1.schema.json](schema/batch.v1.schema.json), [schema/config.v1.schema.json](schema/config.v1.schema.json). Sənədlə sxem ziddiyyət təşkil edərsə, sxem əsasdır.

## 1. Adlar

Brend adı yalnız bu cədvəldə və SDK-ların açıq səthində işlənir. Protokolun özündə (yollar, sahə adları) brend yoxdur.

| Yer | Dəyər |
|---|---|
| Host | `c.cdnsb.net` |
| Veb qlobal funksiya | `smartbee` |
| Android | `az.smartbee:pixel`, sinif `SmartBee` |
| iOS | `SmartBeePixel`, sinif `SmartBee` |
| React Native | `@smartbee/pixel` |
| Flutter | `smartbee_pixel` |

## 2. Anlayışlar

- **Layihə**: bir müştərinin bütün mənbələri.
- **Mənbə**: bir veb sayt, bir Android tətbiqi və ya bir iOS tətbiqi. Hər mənbənin öz **açarı** var.
- **Açar**: `^[a-z0-9]{8,16}$`. Gizli deyil (saytın kodunda və tətbiqin içində görünür). Server onu mənbənin icazəli domenləri / paket adı ilə birlikdə yoxlayır.

## 3. Endpoint-lər

| Metod və yol | Təyinat |
|---|---|
| `GET /v1/{key}.js` | Veb skript. Konfiq skriptin içindədir. |
| `GET /v1/{key}/config` | Mobil SDK-lar üçün konfiq (JSON). |
| `POST /v1/e` | Event toplusu. Veb və mobil üçün eyni format. |

Naməlum və ya söndürülmüş açar:

- `/v1/{key}.js` — `200`, heç nə etməyən skript (müştəri saytında konsol xətası olmasın).
- `/v1/{key}/config` — `404`. SDK bunu "söndürülüb" kimi qəbul edir.
- `/v1/e` — `403`.

## 4. Veb snippet

```html
<script>
!function(w,d,n,u,t,s){if(w[n])return;t=w[n]=function(){t.q.push(arguments)};t.q=[];t.l=+new Date;t.v=1;
s=d.createElement('script');s.async=1;s.src=u;(d.head||d.documentElement).appendChild(s)
}(window,document,'smartbee','https://c.cdnsb.net/v1/KEY.js');
</script>
```

Snippet-in tracker ilə müqaviləsi:

- `window.smartbee.q` — skript yüklənənə qədərki çağırışların siyahısı (hər biri `arguments` obyekti). Tracker yüklənəndə onları sıra ilə icra edir.
- `window.smartbee.l` — snippet-in işlədiyi vaxt (ms).
- `window.smartbee.v` — snippet versiyası (`1`).
- Snippet ikinci dəfə daxil edilərsə, heç nə etmir.
- `init` çağırışı lazım deyil: açar skriptin URL-indədir, tracker özü başlayır və ilk `PageView`-u özü göndərir.

Skript `Cache-Control: private, no-cache` və `ETag` ilə verilir: brauzer hər yükləmədə yoxlayır, aralıq keşlər (CDN) saxlamır. ETag tracker versiyasından və konfiqin `rev` dəyərindən hesablanır.

## 5. Event toplusu: `POST /v1/e`

### 5.1 Sorğu

- Gövdə: JSON, UTF-8.
- `Content-Type`: veb `text/plain` göndərir (`sendBeacon` preflight-sız işləsin), mobil `application/json`. Server başlığa baxmadan gövdəni JSON kimi oxuyur.
- Mobil `Content-Encoding: gzip` işlədə bilər.
- Veb sorğuları cookie ilə gedir (`credentials: include`).

### 5.2 Limitlər

| Limit | Dəyər |
|---|---|
| Topludakı event sayı | 1–100 |
| Gövdə ölçüsü (sıxılmamış) | 500 KB; veb `sendBeacon` üçün 60 KB |
| Bir eventin ölçüsü | 32 KB |
| Kontekstin (`ctx`) ölçüsü | 8 KB |
| `props` / `traits` dərinliyi | 4 səviyyə |
| Event adı | `^[A-Za-z][A-Za-z0-9_]{0,63}$` |

Limiti aşan toplu `413` alır. SDK toplunu göndərməzdən əvvəl özü bölür.

### 5.3 Toplunun quruluşu

```json
{
  "v": 1,
  "key": "k7m2x9qa4t",
  "sent_at": "2026-11-25T07:00:05.120Z",
  "sdk": { "name": "android", "version": "1.0.0" },
  "ctx": { "platform": "android" },
  "events": [ { "id": "…", "type": "track", "name": "Purchase", "ts": "…", "anon_id": "…" } ]
}
```

| Sahə | Məcburi | Təsvir |
|---|---|---|
| `v` | bəli | Protokol versiyası, `1`. |
| `key` | bəli | Mənbə açarı. |
| `sent_at` | bəli | Göndərmə anı, klient saatı ilə. Server onu qəbul anı ilə müqayisə edib klient saatının xətasını düzəldir. |
| `sdk.name` | bəli | `web`, `android`, `ios`. |
| `sdk.version` | bəli | SDK versiyası (semver). |
| `sdk.wrapper` | xeyr | `react-native` və ya `flutter`. |
| `sdk.wrapper_version` | xeyr | Örtüyün versiyası. |
| `ctx` | bəli | Kontekst, 5.4-ə bax. Topludakı bütün eventlərə aiddir. |
| `events` | bəli | Eventlər, 5.5-ə bax. |

Kontekst dəyişərsə (məsələn tətbiq yeniləndi), SDK köhnə kontekstli eventləri ayrıca topluda göndərir.

### 5.4 Kontekst (`ctx`)

Yalnız `platform` məcburidir. Qalanları mövcud olduqda göndərilir.

| Sahə | Platforma | Təsvir |
|---|---|---|
| `platform` | hamısı | `web`, `android`, `ios`. |
| `locale` | hamısı | Məsələn `az-AZ`. |
| `tz` | hamısı | IANA adı, məsələn `Asia/Baku`. |
| `screen` | hamısı | `{ "w": 1080, "h": 2400, "density": 2.75 }`. |
| `consent` | hamısı | `{ "analytics": true, "ads": true }`, 7-ci bölməyə bax. |
| `campaign` | hamısı | Son toxunuş: `utm_source`, `utm_medium`, `utm_campaign`, `utm_term`, `utm_content`, `fbclid`, `gclid`, `ttclid` və s. |
| `ids` | hamısı | Platforma identifikatorları: `fbp`, `fbc`, `ttp` (veb); `gaid` (Android); `idfa`, `idfv`, `att` (iOS). |
| `ua` | veb | `navigator.userAgent`. |
| `app` | mobil | `{ "id": "az.shop.app", "version": "1.2.3", "build": "45" }`. `id` paket adı / bundle ID-dir və açarla birlikdə yoxlanır. |
| `os` | mobil | `{ "name": "Android", "version": "14" }`. |
| `device` | mobil | `{ "manufacturer": "Google", "model": "Pixel 8", "type": "phone" }`. |

IP ünvanını və qəbul vaxtını server özü təyin edir, klient göndərmir.

### 5.5 Event

| Sahə | Məcburi | Təsvir |
|---|---|---|
| `id` | bəli | `^[A-Za-z0-9_.:-]{1,64}$`. Susmaya görə UUID v4. Dedup açarıdır və platformalara `event_id` kimi ötürülür. |
| `type` | bəli | `track` və ya `identify`. Server tanımadığı tipi rədd etmir, saxlayır. |
| `ts` | bəli | Hadisənin anı, klient saatı ilə, UTC, `2026-11-25T07:00:00.000Z` formatında. |
| `anon_id` | bəli | Anonim identifikator, 6-cı bölməyə bax. |
| `name` | `track` üçün | Event adı. Standart adlar: [EVENTS.md](EVENTS.md). |
| `user_id` | `identify` üçün | Müştərinin öz istifadəçi ID-si. `identify`-dan sonrakı bütün eventlərdə də göndərilir. |
| `session_id` | xeyr | Sessiya identifikatoru. |
| `seq` | xeyr | Quraşdırma üzrə artan sayğac. Sıralama və itki aşkarlama üçündür. |
| `origin` | xeyr | `code` (susmaya görə), `auto` (SDK-nın avtomatik eventi) və ya `rule` (uzaqdan qayda). |
| `rule_id` | xeyr | `origin: rule` olduqda qaydanın ID-si. |
| `props` | xeyr | Event parametrləri. İstifadəçinin verdiyi hər şey yalnız burada olur. |
| `traits` | xeyr | Yalnız `identify`: istifadəçi xüsusiyyətləri. |
| `page` | veb | `{ "url": "…", "referrer": "…", "title": "…" }`. |
| `screen` | mobil | `{ "name": "ProductDetail" }`. |

İstifadəçi parametrləri heç vaxt eventin yuxarı səviyyəsinə qarışdırılmır, ona görə sistem sahələrini üstələyə bilmir.

### 5.6 Cavab

| Kod | Mənası | SDK-nın hərəkəti |
|---|---|---|
| `2xx` | Qəbul olundu | Toplunu növbədən silir. |
| `400`, `403`, `413`, digər `4xx` | Toplu yararsızdır | Silir, təkrar göndərmir. |
| `408`, `429` | Müvəqqəti | Saxlayır, `Retry-After`-ə əməl edir. |
| `5xx`, şəbəkə xətası | Müvəqqəti | Saxlayır, artan fasilə ilə təkrar edir. |

- Təkrar cəhd fasiləsi: 5 s-dən başlayır, hər dəfə ikiqat artır, maksimum 1 saat, ±20% təsadüfi kənarlaşma.
- Server ayrı-ayrı yararsız eventləri atır, qalanını qəbul edir və `200` qaytarır. Yalnız toplunun zərfi (`v`, `key`, JSON) yararsızdırsa `400` verir.
- Cavab gövdəsi `{"ok":true,"accepted":n,"rejected":n}` formasındadır, yalnız sazlama üçündür. SDK gövdəyə güvənmir.
- Server `id` üzrə dedup edir, ona görə eyni toplunu təkrar göndərmək təhlükəsizdir.

### 5.7 Mənbə yoxlaması

- **Veb:** `Origin` başlığı (yoxdursa `page.url`) mənbənin icazəli domenləri ilə tutuşdurulur. Uyğun gəlməyən eventlər yazılmır, paneldə "qeydiyyatsız domen" kimi sayılır.
- **Mobil:** `ctx.app.id` mənbənin qeydiyyatdakı paket adı / bundle ID-si ilə tutuşdurulur.
- Hər ikisində açar və IP üzrə rate limit var.

### 5.8 CORS və cookie

- `Access-Control-Allow-Origin`: sorğunun `Origin` dəyəri (ulduz yox).
- `Access-Control-Allow-Credentials: true`.
- `cdnsb.net` cookie-ləri `SameSite=None; Secure` olmalıdır. Üçüncü tərəf cookie-lərini bloklayan brauzerlərdə gəlmir, ona görə əsas identifikator `anon_id`-dir.

## 6. İdentifikatorlar

| | Veb | Mobil |
|---|---|---|
| `anon_id` | Müştərinin öz domenində birinci tərəf cookie (subdomenlər arasında ortaq) + localStorage | Tətbiqin yaddaşında saxlanan UUID (quraşdırma ID-si) |
| `session_id` | 30 dəqiqə fəaliyyətsizlikdən sonra yenilənir | Tətbiq 30 dəqiqədən çox arxa fonda qaldıqda yenilənir |
| `user_id` | `identify` ilə verilir | `identify` ilə verilir |

- `reset()` (çıxış): `user_id` silinir, yeni `anon_id` və `session_id` yaradılır.
- Sessiya müddəti konfiqdən dəyişdirilə bilər (`session_timeout_s`).

### 6.1 Şəxsi məlumat

- `traits`-də e-poçt və telefon açıq göndərilmir. SDK onları normallaşdırıb SHA-256 ilə hash edir və `email_sha256`, `phone_sha256` kimi göndərir.
- E-poçt: boşluqlar silinir, kiçik hərfə çevrilir.
- Telefon: yalnız rəqəmlər, ölkə kodu ilə (E.164, `+` işarəsiz).
- `props` daxilində `email`, `phone`, `password` kimi açarlar SDK tərəfindən atılır və sazlama rejimində xəbərdarlıq verilir.
- URL-lərdən (`page.url`, `page.referrer`, form və keçid ünvanları) həssas query parametrləri (`token`, `password`, `email`, `access_token`, `code`, `secret`, `api_key` və s., üstəlik konfiqdəki `strip_params`) silinir; hash marşrutunun query hissəsi də eyni qaydadan keçir.
- URL-in host-dan sonrakı hissəsində e-poçta bənzər mətn `[redacted]` ilə əvəz olunur.

## 7. Razılıq (consent)

İki məqsəd var:

| `analytics` | `ads` | Davranış |
|---|---|---|
| `false` | — | Heç nə göndərilmir və saxlanmır. Növbə silinir. |
| `true` | `false` | Eventlər göndərilir, amma reklam platformalarına ötürülmür; reklam identifikatorları (`gaid`, `idfa`, `fbp` və s.) göndərilmir. |
| `true` | `true` | Tam rejim. |

- Başlanğıc dəyəri konfiqdəki `consent_default`-dan gəlir, `init` seçimi və ya `setConsent` onu üstələyir.
- Seçim saxlanır və növbəti səhifələrdə / açılışlarda qüvvədə qalır.

## 8. Konfiq

`GET /v1/{key}/config` cavabı və veb skriptin içindəki konfiq eyni formadadır. Sxem: [schema/config.v1.schema.json](schema/config.v1.schema.json).

```json
{
  "v": 1,
  "key": "k7m2x9qa4t",
  "rev": 12,
  "enabled": true,
  "sample": 1,
  "ttl_s": 3600,
  "session_timeout_s": 1800,
  "consent_default": { "analytics": true, "ads": true },
  "auto": { "page_view": true, "lifecycle": true },
  "blocked_events": [],
  "strip_params": [],
  "flush": { "interval_s": 30, "max_batch": 50, "max_queue": 1000 },
  "rules": []
}
```

| Sahə | Təsvir |
|---|---|
| `rev` | Konfiqin versiyası, hər dəyişiklikdə artır. |
| `enabled` | `false` olarsa SDK heç nə göndərmir və növbəni silir (kill-switch). |
| `sample` | 0–1. Nümunələmə `anon_id` üzrə aparılır ki, istifadəçi ya tam daxil olsun, ya tam kənarda qalsın. |
| `ttl_s` | Mobil SDK konfiqi bu müddətdən tez-tez yeniləmir. |
| `auto` | Avtomatik eventlərin açarları. Veb: `page_view`, `spa`, `forms`, `outbound`, `contact_links`, `scroll`. Mobil: `lifecycle`, `screens`, `deeplinks`. |
| `blocked_events` | Bu adlı eventlər SDK-da atılır. |
| `flush` | Növbənin parametrləri. `max_queue` aşılanda ən köhnə eventlər atılır. |
| `rules` | Kodsuz event qaydaları. Formatı 6-cı mərhələdə təsvir olunacaq. SDK tanımadığı qayda tipini ötürür. |

Mobil SDK konfiqi `If-None-Match` ilə soruşur və diskdə saxlayır. Konfiq alınmayıbsa, SDK susmaya görə dəyərlərlə işləyir və eventləri növbədə saxlayır.

## 9. Uyğunluq qaydaları

1. Server tanımadığı sahələri rədd etmir. SDK tanımadığı konfiq sahələrini ötürür.
2. `v: 1` daxilində sahə silinmir, tipi və mənası dəyişmir, məcburi sahə əlavə olunmur.
3. Uyğunsuz dəyişiklik yalnız `/v2` ilə gəlir; `/v1` paralel işləməkdə qalır.
4. Server ən azı `v: 1`-in bütün buraxılmış SDK versiyalarını qəbul edir.
