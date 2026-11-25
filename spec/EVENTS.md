# SmartBee Pixel — Standard events v1

Status: **1.0 — frozen with SDK 1.0.0**.

Standard names must be written exactly as shown (they are case-sensitive). Every name that is not in this list is a custom event and is sent with the same `track` method. A custom name must match `^[A-Za-z][A-Za-z0-9_]{0,63}$`.

The table that maps these names to the event names of advertising platforms (Meta, TikTok, Google) will be added with the server-side forwarding stage.

## Commerce and conversion

| Event | When | Recommended parameters |
|---|---|---|
| `ViewContent` | A product, listing or article is viewed | `content_ids`, `content_type`, `content_name`, `content_category`, `value`, `currency` |
| `Search` | Search | `search_string` |
| `AddToCart` | Added to the cart | `content_ids`, `contents`, `value`, `currency` |
| `AddToWishlist` | Added to the wishlist | `content_ids`, `value`, `currency` |
| `InitiateCheckout` | Checkout started | `contents`, `num_items`, `value`, `currency` |
| `AddPaymentInfo` | Payment details entered | `value`, `currency` |
| `Purchase` | Order completed | `value`\*, `currency`\*, `order_id`, `contents`, `num_items` |
| `Lead` | Enquiry, form | `value`, `currency` |
| `CompleteRegistration` | Registration completed | `method` |
| `Contact` | Contact attempt | `method` |
| `Subscribe` | Paid subscription | `value`, `currency` |
| `StartTrial` | Trial period | `value`, `currency` |
| `Schedule` | Appointment booked | — |
| `SubmitApplication` | Application submitted | — |
| `FindLocation` | Branch / address lookup | — |
| `CustomizeProduct` | Product customised | `content_ids` |
| `Donate` | Donation | `value`, `currency` |
| `Login` | Sign-in | `method` |

\* `value` and `currency` are required for `Purchase`. Without them the event is accepted, but a warning is shown in the dashboard and it is not forwarded to advertising platforms.

## Automatic events

`PageView`, `FormSubmit`, `OutboundClick`, `ContactClick`, `AppInstall`, `AppUpdate`, `AppOpen`, `SessionStart`, `ScreenView`, `DeepLinkOpen`. They are described in [SDK-API.md](SDK-API.md). Sending these names manually is not recommended (double counting).

## Parameters

| Parameter | Type | Description |
|---|---|---|
| `value` | number | The amount. It must be a number, not a string. |
| `currency` | string | ISO 4217, three upper-case letters (`AZN`, `USD`). |
| `order_id` | string | The order number. It prevents a `Purchase` from being counted twice. |
| `content_ids` | array of strings | Product / listing IDs. |
| `content_type` | string | `product` or `product_group`. |
| `content_name` | string | The name. |
| `content_category` | string | The category. |
| `contents` | array of objects | `[{ "id": "p1", "quantity": 2, "item_price": 25 }]` |
| `num_items` | integer | The number of items. |
| `search_string` | string | The search query. |
| `method` | string | The method (`email`, `google`, `phone`, `whatsapp` and so on). |

Any other key is allowed and is stored as it is.

## Forbidden keys

Inside `props` these keys are dropped by the SDK: `email`, `phone`, `password`, `pass`, `token`, `card`, `card_number`, `cvv`, `pin`, `fin`. E-mail and phone are sent only through `identify`, in hashed form.
