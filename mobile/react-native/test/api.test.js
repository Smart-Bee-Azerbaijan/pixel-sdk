import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createSmartBee } from '../src/api.js';

function fakeNative() {
  const calls = [];
  const record = (name) => (...args) => { calls.push([name, ...args]); };
  return {
    calls,
    start: record('start'), track: record('track'), identify: record('identify'), screen: record('screen'),
    setConsent: record('setConsent'), reset: record('reset'), flush: record('flush'),
    getAnonymousId: async () => 'anon-1',
  };
}

test('init seçimləri nativ modula ötürür və örtük versiyasını əlavə edir', async () => {
  const native = fakeNative();
  const sb = createSmartBee(native, { version: '1.0.0' });
  await sb.init('demo0andr1', { debug: true, consent: { analytics: true, ads: false }, endpoint: 'https://proxy.example.com' });
  await sb.init('demo0andr1');
  assert.deepEqual(native.calls, [
    ['start', 'demo0andr1', { debug: true, autoEvents: true, endpoint: 'https://proxy.example.com', consent: { analytics: true, ads: false }, wrapperVersion: '1.0.0' }],
    ['start', 'demo0andr1', { debug: false, autoEvents: true, endpoint: null, consent: null, wrapperVersion: '1.0.0' }],
  ]);
});

test('yarımçıq razılıq seçimi nəzərə alınmır', async () => {
  const native = fakeNative();
  await createSmartBee(native).init('demo0andr1', { consent: { analytics: true }, autoEvents: false });
  assert.equal(native.calls[0][2].consent, null);
  assert.equal(native.calls[0][2].autoEvents, false);
});

test('track, identify və screen parametrləri təmiz JSON kimi ötürülür', () => {
  const native = fakeNative();
  const sb = createSmartBee(native);
  const when = new Date('2026-11-25T07:00:00.000Z');
  sb.track('Purchase', { value: 250, when, fn() {}, missing: undefined, nested: { a: [1, undefined] } }, { eventId: 'order:A-1' });
  sb.track('Lead');
  sb.track('Lead', 'not-an-object');
  sb.identify('user-42', { email: 'a@b.az' });
  sb.identify(42);
  sb.screen('Cart', { items: 2 });
  assert.deepEqual(native.calls, [
    ['track', 'Purchase', { value: 250, when: '2026-11-25T07:00:00.000Z', nested: { a: [1, null] } }, 'order:A-1'],
    ['track', 'Lead', null, null],
    ['track', 'Lead', null, null],
    ['identify', 'user-42', { email: 'a@b.az' }],
    ['identify', '42', null],
    ['screen', 'Cart', { items: 2 }],
  ]);
});

test('dövri istinadlı parametrlər atılır, çağırış xəta vermir', () => {
  const native = fakeNative();
  const circular = {};
  circular.self = circular;
  createSmartBee(native).track('Lead', circular);
  assert.deepEqual(native.calls, [['track', 'Lead', null, null]]);
});

test('setConsent yalnız iki boolean ilə ötürülür', () => {
  const native = fakeNative();
  const warnings = [];
  const sb = createSmartBee(native, { warn: (m) => warnings.push(m) });
  sb.setConsent({ analytics: true, ads: false });
  sb.setConsent({ analytics: true });
  sb.setConsent('yes');
  sb.setConsent();
  assert.deepEqual(native.calls, [['setConsent', true, false]]);
  assert.equal(warnings.length, 3);
});

test('reset, flush və getAnonymousId', async () => {
  const native = fakeNative();
  const sb = createSmartBee(native);
  sb.reset();
  sb.flush();
  assert.deepEqual(native.calls, [['reset'], ['flush']]);
  assert.equal(await sb.getAnonymousId(), 'anon-1');
  native.getAnonymousId = async () => null;
  assert.equal(await sb.getAnonymousId(), null);
  native.getAnonymousId = async () => { throw new Error('bridge'); };
  assert.equal(await sb.getAnonymousId(), null);
});

test('nativ modul yoxdursa heç nə sınmır və bir dəfə xəbərdarlıq verilir', async () => {
  const warnings = [];
  for (const native of [undefined, null, {}]) {
    const sb = createSmartBee(native, { warn: (m) => warnings.push(m) });
    await sb.init('demo0andr1');
    sb.track('Lead', { a: 1 });
    sb.identify('u');
    sb.screen('Home');
    sb.reset();
    sb.flush();
    assert.equal(await sb.getAnonymousId(), null);
  }
  assert.equal(warnings.length, 3);
});

test('nativ çağırış xəta atsa belə açıq metodlar istisna atmır', async () => {
  const boom = () => { throw new Error('native crash'); };
  const sb = createSmartBee({ start: boom, track: boom, identify: boom, screen: boom, setConsent: boom, reset: boom, flush: boom, getAnonymousId: boom });
  await assert.doesNotReject(sb.init('k'));
  assert.doesNotThrow(() => {
    sb.track('Lead');
    sb.identify('u');
    sb.screen('Home');
    sb.setConsent({ analytics: true, ads: true });
    sb.reset();
    sb.flush();
  });
  assert.equal(await sb.getAnonymousId(), null);
});

// ---- Audit (AUDIT.md, bölmə 7) ----------------------------------------------

function fakeLinking(initial) {
  const listeners = [];
  return {
    listeners,
    getInitialURL: async () => initial,
    addEventListener(type, handler) { listeners.push([type, handler]); return { remove() {} }; },
  };
}

test('audit: iOS-da keçidlər Linking-dən nativ SDK-ya ötürülür', async () => {
  const native = fakeNative();
  native.handleDeepLink = (url) => { native.calls.push(['handleDeepLink', url]); };
  const linking = fakeLinking('myapp://open?utm_source=fb');
  const sb = createSmartBee(native, { platform: 'ios', linking });
  await sb.init('demo0ios01');
  await sb.init('demo0ios01');
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(linking.listeners.length, 1, 'dinləyici yalnız bir dəfə qoşulur');
  linking.listeners[0][1]({ url: 'myapp://product/1' });
  linking.listeners[0][1]({});
  linking.listeners[0][1](null);
  assert.deepEqual(native.calls.filter((c) => c[0] === 'handleDeepLink'), [
    ['handleDeepLink', 'myapp://open?utm_source=fb'],
    ['handleDeepLink', 'myapp://product/1'],
  ]);
});

test('audit: Android-də, autoEvents söndürüləndə və Linking xəta verəndə keçidlər izlənmir', async () => {
  const android = fakeNative();
  android.handleDeepLink = () => { throw new Error('should not be called'); };
  const a = fakeLinking('myapp://x');
  await createSmartBee(android, { platform: 'android', linking: a }).init('demo0andr1');
  assert.equal(a.listeners.length, 0);

  const ios = fakeNative();
  ios.handleDeepLink = () => {};
  const b = fakeLinking('myapp://x');
  await createSmartBee(ios, { platform: 'ios', linking: b }).init('demo0ios01', { autoEvents: false });
  assert.equal(b.listeners.length, 0);

  const broken = { getInitialURL: () => { throw new Error('no linking'); }, addEventListener() { throw new Error('no linking'); } };
  await assert.doesNotReject(createSmartBee(ios, { platform: 'ios', linking: broken }).init('demo0ios01'));
  const rejecting = { getInitialURL: () => Promise.reject(new Error('denied')), addEventListener() {} };
  await assert.doesNotReject(createSmartBee(ios, { platform: 'ios', linking: rejecting }).init('demo0ios01'));
  await new Promise((r) => setTimeout(r, 0));
});

test('audit: sonsuz və NaN ədədlər atılır, BigInt olan obyekt bütövlükdə atılır', () => {
  const native = fakeNative();
  const sb = createSmartBee(native);
  sb.track('Lead', { ok: 1, nan: NaN, inf: Infinity, nested: { v: -Infinity, keep: 0 } });
  sb.track('Lead', { big: 10n });
  assert.deepEqual(native.calls, [
    ['track', 'Lead', { ok: 1, nested: { keep: 0 } }, null],
    ['track', 'Lead', null, null],
  ]);
});

test('audit: VERSION package.json ilə eynidir və nativ fayllar paketə daxildir', async () => {
  const { readFileSync, existsSync } = await import('node:fs');
  const root = new URL('../', import.meta.url);
  const pkg = JSON.parse(readFileSync(new URL('package.json', root), 'utf8'));
  const index = readFileSync(new URL('src/index.js', root), 'utf8');
  assert.equal(/export const VERSION = '([^']+)'/.exec(index)[1], pkg.version);
  for (const path of ['android/build.gradle', 'android/src/main/java/az/smartbee/pixel/Core.kt', 'ios/Core/Core.swift', 'ios/SmartBeePixelBridge.m', 'ios/Resources/PrivacyInfo.xcprivacy', 'smartbee-pixel.podspec']) {
    assert.ok(existsSync(new URL(path, root)), path);
  }
  // Körpünün Swift metodları ilə Objective-C bəyanları eyni selektorlara malik olmalıdır.
  const swift = readFileSync(new URL('ios/SmartBeePixelBridge.swift', root), 'utf8');
  const objc = readFileSync(new URL('ios/SmartBeePixelBridge.m', root), 'utf8');
  const swiftSelectors = [...swift.matchAll(/@objc\(([^)]+)\)\s*\n\s*func/g)].map((m) => m[1]).concat([...swift.matchAll(/@objc func (\w+)\(\)/g)].map((m) => m[1])).sort();
  const prefix = 'RCT_EXTERN_METHOD(';
  const objcSelectors = objc
    .split('\n')
    .filter((line) => line.startsWith(prefix))
    // "start:(NSString *)key options:(NSDictionary *)options" -> "start:options:"
    .map((line) => line.slice(prefix.length, line.lastIndexOf(')')).replace(/\([^)]*\)\s*\w+/g, '').replace(/\s+/g, ''))
    .sort();
  assert.equal(objcSelectors.length, 9);
  assert.deepEqual(objcSelectors, swiftSelectors);
});
