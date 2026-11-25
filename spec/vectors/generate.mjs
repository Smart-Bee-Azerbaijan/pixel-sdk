// Test vektorlarını yaradır: `node vectors/generate.mjs`
// Vektorlar repo-da saxlanır; bu skript yalnız onları yenidən qurmaq üçündür.
import { mkdirSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const dir = dirname(fileURLToPath(import.meta.url));
const write = (path, data) => {
  mkdirSync(dirname(join(dir, path)), { recursive: true });
  writeFileSync(join(dir, path), JSON.stringify(data, null, 2) + '\n');
};
const sha256 = (s) => createHash('sha256').update(s, 'utf8').digest('hex');

const head = { v: 1, key: 'k7m2x9qa4t', sent_at: '2026-11-25T07:00:05.120Z' };
const web = { sdk: { name: 'web', version: '1.0.0' }, ctx: { platform: 'web' } };
const anon = 'a1b2c3d4-0000-4000-8000-000000000001';
const pageView = { id: 'e1', type: 'track', name: 'PageView', ts: '2026-11-25T07:00:00Z', anon_id: 'a1' };

// ---- Yararlı toplular -------------------------------------------------------

write('valid/web-minimal.json', {
  description: 'Veb: ən kiçik yararlı toplu, tək PageView',
  batch: {
    ...head, ...web,
    events: [{ id: '3f2b8c1e-6a4d-4e2f-9b7a-1c5d8e9f0a2b', type: 'track', name: 'PageView', ts: '2026-11-25T07:00:00.000Z', anon_id: anon, origin: 'auto' }],
  },
});

write('valid/web-purchase.json', {
  description: 'Veb: tam kontekst, identify və Purchase',
  batch: {
    ...head,
    sdk: web.sdk,
    ctx: {
      platform: 'web', locale: 'az-AZ', tz: 'Asia/Baku', ua: 'Mozilla/5.0',
      screen: { w: 1920, h: 1080, density: 1 },
      consent: { analytics: true, ads: true },
      campaign: { utm_source: 'facebook', utm_medium: 'cpc', fbclid: 'IwAR0abc' },
      ids: { fbp: 'fb.1.1700000000000.1234567890' },
    },
    events: [
      { id: 'e-0001', type: 'identify', ts: '2026-11-25T07:00:01Z', anon_id: anon, user_id: 'user-42', session_id: 's-1', seq: 7,
        traits: { email_sha256: sha256('a@b.az') } },
      { id: 'order:A-1001', type: 'track', name: 'Purchase', ts: '2026-11-25T07:00:02.5Z', anon_id: anon, user_id: 'user-42', session_id: 's-1', seq: 8,
        props: { value: 250, currency: 'AZN', order_id: 'A-1001', contents: [{ id: 'p1', quantity: 2, item_price: 125 }] },
        page: { url: 'https://shop.az/thank-you', referrer: 'https://shop.az/checkout', title: 'Təşəkkürlər' } },
    ],
  },
});

write('valid/android-full.json', {
  description: 'Android: Flutter örtüyü ilə, avtomatik və kod eventləri',
  batch: {
    ...head,
    sdk: { name: 'android', version: '1.0.0', wrapper: 'flutter', wrapper_version: '1.0.0' },
    ctx: {
      platform: 'android', locale: 'az-AZ', tz: 'Asia/Baku',
      screen: { w: 1080, h: 2400, density: 2.75 },
      consent: { analytics: true, ads: false },
      app: { id: 'az.shop.app', version: '1.2.3', build: '45' },
      os: { name: 'Android', version: '14' },
      device: { manufacturer: 'Google', model: 'Pixel 8', type: 'phone' },
    },
    events: [
      { id: '3f2b8c1e-6a4d-4e2f-9b7a-1c5d8e9f0a2c', type: 'track', name: 'AppOpen', ts: '2026-11-25T06:59:00.000Z', anon_id: 'i-9f1c', session_id: 's-2', seq: 0, origin: 'auto' },
      { id: '3f2b8c1e-6a4d-4e2f-9b7a-1c5d8e9f0a2d', type: 'track', name: 'AddToCart', ts: '2026-11-25T06:59:30.000Z', anon_id: 'i-9f1c', session_id: 's-2', seq: 1,
        props: { content_ids: ['p1'], value: 125, currency: 'AZN' }, screen: { name: 'ProductDetail' } },
    ],
  },
});

write('valid/ios-future-fields.json', {
  description: 'iOS: naməlum sahələr və naməlum event tipi rədd olunmamalıdır (irəliyə uyğunluq)',
  batch: {
    ...head,
    future_field: { x: 1 },
    sdk: { name: 'ios', version: '1.4.0' },
    ctx: { platform: 'ios', app: { id: 'az.shop.app' }, ids: { idfv: '6D92078A-8246-4BA4-AE5B-76104861E7DC', att: 'denied' }, new_ctx: true },
    events: [
      { id: 'x1', type: 'alias', ts: '2026-11-25T07:00:00Z', anon_id: 'i-1', extra: [1, 2] },
      { id: 'x2', type: 'track', name: 'Rule_Checkout_Click', ts: '2026-11-25T07:00:00Z', anon_id: 'i-1', origin: 'rule', rule_id: 'r-17' },
    ],
  },
});

// ---- Yararsız toplular ------------------------------------------------------

const invalid = (name, description, batch) => write(`invalid/${name}.json`, { description, batch });
const { key: _key, ...headNoKey } = head;
const { name: _name, ...pvNoName } = pageView;
const { anon_id: _anon, ...pvNoAnon } = pageView;

invalid('missing-key', 'Açar yoxdur', { ...headNoKey, ...web, events: [pageView] });
invalid('bad-key', 'Açar formatı səhvdir (böyük hərf, tire)', { ...head, key: 'SB-TEST', ...web, events: [pageView] });
invalid('wrong-version', 'Protokol versiyası 1 deyil', { ...head, v: 2, ...web, events: [pageView] });
invalid('empty-events', 'Event siyahısı boşdur', { ...head, ...web, events: [] });
invalid('too-many-events', 'Topluda 100-dən çox event var', {
  ...head, ...web, events: Array.from({ length: 101 }, (_, i) => ({ ...pageView, id: `e${i}` })),
});
invalid('track-without-name', 'track eventində ad yoxdur', { ...head, ...web, events: [pvNoName] });
invalid('bad-event-name', 'Event adında boşluq və icazəsiz simvol var', { ...head, ...web, events: [{ ...pageView, name: 'my event!' }] });
invalid('identify-without-user', 'identify eventində user_id yoxdur', { ...head, ...web, events: [{ ...pvNoName, type: 'identify' }] });
invalid('missing-anon-id', 'anon_id yoxdur', { ...head, ...web, events: [pvNoAnon] });
invalid('bad-timestamp', 'Vaxt UTC ISO formatında deyil', { ...head, ...web, events: [{ ...pageView, ts: '25.11.2026 11:00' }] });
invalid('missing-platform', 'ctx.platform yoxdur', { ...head, sdk: web.sdk, ctx: {}, events: [pageView] });
invalid('props-not-object', 'props obyekt deyil', { ...head, ...web, events: [{ ...pageView, name: 'Purchase', props: 'value=1' }] });

// ---- Konfiq və hash ---------------------------------------------------------

write('config-default.json', {
  v: 1, key: 'k7m2x9qa4t', rev: 12, enabled: true, sample: 1, ttl_s: 3600, session_timeout_s: 1800,
  consent_default: { analytics: true, ads: true },
  auto: { page_view: true, spa: true, forms: true, outbound: true, contact_links: true, lifecycle: true, screens: true, deeplinks: true },
  blocked_events: [], strip_params: [],
  flush: { interval_s: 30, max_batch: 50, max_queue: 1000 },
  rules: [],
});

const hashed = (input, normalized) => ({ input, normalized, sha256: sha256(normalized) });
write('hashing.json', {
  description: 'identify üçün normallaşdırma və SHA-256. Hər SDK bu girişlərdən eyni normalized və sha256 dəyərlərini almalıdır.',
  email: [hashed('  A@B.az ', 'a@b.az'), hashed('User.Test@Example.COM', 'user.test@example.com')],
  phone: [hashed('+994 (50) 123-45-67', '994501234567'), hashed('994501234567', '994501234567')],
});

// Təmizləmə vektorları (sanitize-url.json, sanitize-props.json, identity.json, campaign.json) burada yaradılmır:
// girişlər həmin fayllarda əl ilə yazılır, gözlənilən dəyərlər isə istinad tətbiqin (veb tracker) nəticəsidir və
// `SB_UPDATE_VECTORS=1 npm test -w tracker` ilə yenilənir (bax tracker/test/vectors.test.js). Eyni fayllar
// Android (SanitizeVectorsTest.kt) və iOS (SanitizeVectorsTests.swift) testlərində oxunur.
