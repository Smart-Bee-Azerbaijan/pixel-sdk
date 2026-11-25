# SmartBee Pixel — Standart eventlər v1

Vəziyyət: **qaralama**.

Standart adlar olduğu kimi yazılmalıdır (böyük-kiçik hərf fərqlidir). Bu siyahıda olmayan hər ad xüsusi (custom) event sayılır və eyni `track` metodu ilə göndərilir. Xüsusi ad `^[A-Za-z][A-Za-z0-9_]{0,63}$` qaydasına uyğun olmalıdır.

Reklam platformalarının (Meta, TikTok, Google) event adlarına çevirmə cədvəli serverdən ötürmə mərhələsində əlavə olunacaq.

## Kommersiya və konversiya

| Event | Nə vaxt | Tövsiyə olunan parametrlər |
|---|---|---|
| `ViewContent` | Məhsula, elana, məqaləyə baxış | `content_ids`, `content_type`, `content_name`, `content_category`, `value`, `currency` |
| `Search` | Axtarış | `search_string` |
| `AddToCart` | Səbətə əlavə | `content_ids`, `contents`, `value`, `currency` |
| `AddToWishlist` | İstək siyahısına əlavə | `content_ids`, `value`, `currency` |
| `InitiateCheckout` | Ödənişə başlama | `contents`, `num_items`, `value`, `currency` |
| `AddPaymentInfo` | Ödəniş məlumatının daxil edilməsi | `value`, `currency` |
| `Purchase` | Sifarişin tamamlanması | `value`\*, `currency`\*, `order_id`, `contents`, `num_items` |
| `Lead` | Müraciət, form | `value`, `currency` |
| `CompleteRegistration` | Qeydiyyatın tamamlanması | `method` |
| `Contact` | Əlaqə cəhdi | `method` |
| `Subscribe` | Ödənişli abunəlik | `value`, `currency` |
| `StartTrial` | Sınaq müddəti | `value`, `currency` |
| `Schedule` | Görüş təyini | — |
| `SubmitApplication` | Ərizə göndərilməsi | — |
| `FindLocation` | Filial / ünvan axtarışı | — |
| `CustomizeProduct` | Məhsulun fərdiləşdirilməsi | `content_ids` |
| `Donate` | İanə | `value`, `currency` |
| `Login` | Hesaba giriş | `method` |

\* `Purchase` üçün `value` və `currency` məcburidir. Onlarsız event qəbul olunur, amma paneldə xəbərdarlıq göstərilir və reklam platformalarına ötürülmür.

## Avtomatik eventlər

`PageView`, `FormSubmit`, `OutboundClick`, `ContactClick`, `AppInstall`, `AppUpdate`, `AppOpen`, `SessionStart`, `ScreenView`, `DeepLinkOpen`. Təsviri: [SDK-API.md](SDK-API.md). Bu adları əl ilə göndərmək tövsiyə olunmur (ikiqat sayılma).

## Parametrlər

| Parametr | Tip | Təsvir |
|---|---|---|
| `value` | ədəd | Məbləğ. Sətir yox, ədəd olmalıdır. |
| `currency` | sətir | ISO 4217, üç böyük hərf (`AZN`, `USD`). |
| `order_id` | sətir | Sifariş nömrəsi. `Purchase`-in təkrar sayılmasının qarşısını alır. |
| `content_ids` | sətir massivi | Məhsul / elan ID-ləri. |
| `content_type` | sətir | `product` və ya `product_group`. |
| `content_name` | sətir | Ad. |
| `content_category` | sətir | Kateqoriya. |
| `contents` | obyekt massivi | `[{ "id": "p1", "quantity": 2, "item_price": 25 }]` |
| `num_items` | tam ədəd | Məhsul sayı. |
| `search_string` | sətir | Axtarış sorğusu. |
| `method` | sətir | Üsul (`email`, `google`, `phone`, `whatsapp` və s.). |

Başqa hər açar icazəlidir və olduğu kimi saxlanır.

## Qadağan olunmuş açarlar

`props` daxilində bu açarlar SDK tərəfindən atılır: `email`, `phone`, `password`, `pass`, `token`, `card`, `card_number`, `cvv`, `pin`, `fin`. E-poçt və telefon yalnız `identify` ilə, hash olunmuş şəkildə göndərilir.
