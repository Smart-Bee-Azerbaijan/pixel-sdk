import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { existsSync, readFileSync } from 'node:fs';

// The package is CommonJS (that is what Metro, Jest and CommonJS TypeScript consumers load); it is required as such.
const require = createRequire(import.meta.url);
const { createSmartBee } = require('../src/api.js');

const root = new URL('../', import.meta.url);
const read = (path) => readFileSync(new URL(path, root), 'utf8');
const KEY = 'demo0key01';
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

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

function withLinks(native) {
  native.handleDeepLink = (url) => { native.calls.push(['handleDeepLink', url]); };
  native.handleInitialLink = (url) => { native.calls.push(['handleInitialLink', url]); };
  return native;
}

function fakeLinking(initial) {
  const listeners = [];
  return {
    listeners,
    getInitialURL: async () => initial,
    addEventListener(type, handler) { listeners.push([type, handler]); return { remove() {} }; },
  };
}

test('init forwards the options to the native module, adds the wrapper version and resolves to true', async () => {
  const native = fakeNative();
  const sb = createSmartBee(native, { version: '1.0.0' });
  assert.equal(await sb.init(KEY, { debug: true, consent: { analytics: true, ads: false }, endpoint: 'https://proxy.example.com' }), true);
  assert.deepEqual(native.calls, [
    ['start', KEY, { debug: true, autoEvents: true, endpoint: 'https://proxy.example.com', consent: { analytics: true, ads: false }, collectAdvertisingId: true, wrapperVersion: '1.0.0' }],
  ]);
  assert.equal(sb.sdkVersion, '1.0.0');
});

test('init without options sends the defaults and no consent', async () => {
  const native = fakeNative();
  assert.equal(await createSmartBee(native, { version: '1.0.0' }).init(KEY), true);
  assert.deepEqual(native.calls, [
    ['start', KEY, { debug: false, autoEvents: true, endpoint: null, consent: null, collectAdvertisingId: true, wrapperVersion: '1.0.0' }],
  ]);
});

test('a repeated init is passed on to the native SDK and warns', async () => {
  const native = fakeNative();
  const warnings = [];
  const sb = createSmartBee(native, { warn: (m) => warnings.push(m) });
  assert.equal(await sb.init(KEY), true);
  assert.equal(warnings.length, 0);
  assert.equal(await sb.init(KEY, { consent: { analytics: false, ads: false }, collectAdvertisingId: false }), true);
  assert.equal(native.calls.length, 2);
  assert.deepEqual(native.calls[1][2].consent, { analytics: false, ads: false });
  assert.equal(native.calls[1][2].collectAdvertisingId, false);
  assert.equal(warnings.length, 1);
  assert.match(warnings[0], /^\[SmartBee\] init was already called/);
});

test('init resolves to false and does not call native when the key is malformed', async () => {
  for (const key of [undefined, null, '', 42, 'short', 'UPPERCASE1', 'has space1', 'k'.repeat(17)]) {
    const native = fakeNative();
    const warnings = [];
    assert.equal(await createSmartBee(native, { warn: (m) => warnings.push(m) }).init(key), false, String(key));
    assert.equal(native.calls.length, 0, String(key));
    assert.equal(warnings.length, 1, String(key));
  }
});

test('collectAdvertisingId is turned off only by an explicit false and is always sent as a boolean', async () => {
  const cases = [
    [undefined, true],
    [{}, true],
    [{ collectAdvertisingId: true }, true],
    [{ collectAdvertisingId: false }, false],
    [{ collectAdvertisingId: null }, true],
    [{ collectAdvertisingId: undefined }, true],
    [{ collectAdvertisingId: 0 }, true],
    [{ collectAdvertisingId: 'false' }, true],
    ['not-an-object', true],
  ];
  for (const [options, expected] of cases) {
    const native = fakeNative();
    await createSmartBee(native).init(KEY, options);
    assert.equal(native.calls[0][2].collectAdvertisingId, expected, JSON.stringify(options));
  }
});

test('consent fails closed in init: a missing or non-boolean purpose is false, with a warning', async () => {
  const cases = [
    [{ analytics: false }, { analytics: false, ads: false }, 1],
    [{ ads: false }, { analytics: false, ads: false }, 1],
    [{ analytics: true }, { analytics: true, ads: false }, 1],
    [{ ads: true }, { analytics: false, ads: true }, 1],
    [{ analytics: 'yes', ads: true }, { analytics: false, ads: true }, 1],
    [{}, { analytics: false, ads: false }, 1],
    ['yes', { analytics: false, ads: false }, 1],
    [{ analytics: true, ads: true }, { analytics: true, ads: true }, 0],
    [null, null, 0],
    [undefined, null, 0],
  ];
  for (const [consent, expected, warned] of cases) {
    const native = fakeNative();
    const warnings = [];
    assert.equal(await createSmartBee(native, { warn: (m) => warnings.push(m) }).init(KEY, { consent, autoEvents: false }), true);
    assert.deepEqual(native.calls[0][2].consent, expected, JSON.stringify(consent));
    assert.equal(native.calls[0][2].autoEvents, false);
    assert.equal(warnings.length, warned, JSON.stringify(consent));
  }
});

test('setConsent fails closed for a partial object and ignores a call without an object', () => {
  const native = fakeNative();
  const warnings = [];
  const sb = createSmartBee(native, { warn: (m) => warnings.push(m) });
  sb.setConsent({ analytics: true, ads: false });
  assert.equal(warnings.length, 0);
  sb.setConsent({ analytics: true });
  sb.setConsent({ ads: false });
  sb.setConsent({ analytics: 1, ads: true });
  sb.setConsent('yes');
  sb.setConsent();
  assert.deepEqual(native.calls, [
    ['setConsent', true, false],
    ['setConsent', true, false],
    ['setConsent', false, false],
    ['setConsent', false, true],
  ]);
  assert.equal(warnings.length, 5);
});

test('track, identify and screen pass their arguments as clean JSON', () => {
  const native = fakeNative();
  const sb = createSmartBee(native);
  const when = new Date('2026-11-25T07:00:00.000Z');
  sb.track('Purchase', { value: 250, when, fn() {}, missing: undefined, nested: { a: [1, undefined] } }, { eventId: 'order:A-1' });
  sb.track('Lead');
  sb.identify('user-42', { email: 'user@example.com' });
  sb.identify(42);
  sb.screen('Cart', { items: 2 });
  assert.deepEqual(native.calls, [
    ['track', 'Purchase', { value: 250, when: '2026-11-25T07:00:00.000Z', nested: { a: [1, null] } }, 'order:A-1'],
    ['track', 'Lead', null, null],
    ['identify', 'user-42', { email: 'user@example.com' }],
    ['identify', '42', null],
    ['screen', 'Cart', { items: 2 }],
  ]);
});

test('a name that is not a non-empty string is ignored, with a warning in development builds only', () => {
  for (const dev of [true, false]) {
    const native = withLinks(fakeNative());
    const warnings = [];
    const sb = createSmartBee(native, { dev, warn: (m) => warnings.push(m) });
    sb.track(42);
    sb.track('');
    sb.track(null, { a: 1 });
    sb.track({ name: 'Lead' });
    sb.identify(undefined);
    sb.identify(NaN);
    sb.identify({});
    sb.screen(7);
    sb.screen();
    sb.handleDeepLink(null);
    sb.handleDeepLink('');
    sb.handleDeepLink({ url: 'myapp://x' });
    assert.deepEqual(native.calls, [], 'dev=' + dev);
    assert.equal(warnings.length, dev ? 12 : 0, 'dev=' + dev);
  }
});

test('props that are not an object are dropped (the event is still sent), with a development warning', () => {
  const native = fakeNative();
  const warnings = [];
  const sb = createSmartBee(native, { dev: true, warn: (m) => warnings.push(m) });
  sb.track('Lead', 'not-an-object');
  sb.track('Lead', [1, 2]);
  sb.identify('u', 5);
  sb.screen('Home', () => {});
  sb.track('Lead', null);
  assert.deepEqual(native.calls, [
    ['track', 'Lead', null, null],
    ['track', 'Lead', null, null],
    ['identify', 'u', null],
    ['screen', 'Home', null],
    ['track', 'Lead', null, null],
  ]);
  assert.equal(warnings.length, 4);
});

test('props with a circular reference are dropped and the call does not throw', () => {
  const native = fakeNative();
  const circular = {};
  circular.self = circular;
  createSmartBee(native).track('Lead', circular);
  assert.deepEqual(native.calls, [['track', 'Lead', null, null]]);
});

test('infinite and NaN numbers are dropped; an object with a BigInt is dropped as a whole', () => {
  const native = fakeNative();
  const sb = createSmartBee(native);
  sb.track('Lead', { ok: 1, nan: NaN, inf: Infinity, nested: { v: -Infinity, keep: 0 } });
  sb.track('Lead', { big: 10n });
  assert.deepEqual(native.calls, [
    ['track', 'Lead', { ok: 1, nested: { keep: 0 } }, null],
    ['track', 'Lead', null, null],
  ]);
});

test('reset, flush and getAnonymousId', async () => {
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

test('without the native module nothing breaks, init resolves to false and one English warning is logged', async () => {
  for (const native of [undefined, null, {}]) {
    const warnings = [];
    const sb = createSmartBee(native, { warn: (m) => warnings.push(m) });
    assert.equal(await sb.init(KEY), false);
    sb.track('Lead', { a: 1 });
    sb.identify('u');
    sb.screen('Home');
    sb.setConsent({ analytics: true, ads: true });
    sb.handleDeepLink('myapp://x');
    sb.reset();
    sb.flush();
    assert.equal(await sb.getAnonymousId(), null);
    assert.equal(warnings.length, 1);
    assert.match(warnings[0], /^\[SmartBee\] the native module is not linked, so every call is a no-op/);
  }
});

test('public methods never throw or reject, even when the native call or the logger throws', async () => {
  const boom = () => { throw new Error('native crash'); };
  const native = { start: boom, track: boom, identify: boom, screen: boom, setConsent: boom, reset: boom, flush: boom, handleDeepLink: boom, getAnonymousId: boom };
  for (const warn of [() => {}, boom]) {
    const messages = [];
    const sb = createSmartBee(native, { dev: true, warn: warn === boom ? boom : (m) => messages.push(m) });
    assert.equal(await sb.init(KEY), false);
    assert.doesNotThrow(() => {
      sb.track('Lead');
      sb.track(1);
      sb.identify('u');
      sb.screen('Home');
      sb.setConsent({ analytics: true, ads: true });
      sb.setConsent({ analytics: true });
      sb.handleDeepLink('myapp://x');
      sb.reset();
      sb.flush();
    });
    assert.equal(await sb.getAnonymousId(), null);
    // In a development build the swallowed errors are reported.
    if (warn !== boom) assert.ok(messages.some((m) => m.includes('native crash')));
  }
});

test('links from Linking are forwarded on iOS and Android; the launch link goes through handleInitialLink', async () => {
  for (const platform of ['ios', 'android']) {
    const native = withLinks(fakeNative());
    const linking = fakeLinking('myapp://open?utm_source=fb');
    const sb = createSmartBee(native, { platform, linking });
    await sb.init(KEY);
    await sb.init(KEY);
    await tick();
    assert.equal(linking.listeners.length, 1, platform + ': the listener is attached once');
    linking.listeners[0][1]({ url: 'myapp://product/1' });
    linking.listeners[0][1]({});
    linking.listeners[0][1](null);
    assert.deepEqual(native.calls.filter((c) => c[0] !== 'start'), [
      ['handleInitialLink', 'myapp://open?utm_source=fb'],
      ['handleDeepLink', 'myapp://product/1'],
    ], platform);
  }
});

test('a native module without handleInitialLink receives the launch link through handleDeepLink', async () => {
  const native = fakeNative();
  native.handleDeepLink = (url) => { native.calls.push(['handleDeepLink', url]); };
  await createSmartBee(native, { platform: 'android', linking: fakeLinking('myapp://open') }).init(KEY);
  await tick();
  assert.deepEqual(native.calls.filter((c) => c[0] !== 'start'), [['handleDeepLink', 'myapp://open']]);
});

test('with autoEvents false links are not forwarded automatically, but handleDeepLink still works', async () => {
  const native = withLinks(fakeNative());
  const linking = fakeLinking('myapp://x');
  const sb = createSmartBee(native, { platform: 'ios', linking });
  await sb.init(KEY, { autoEvents: false });
  await tick();
  assert.equal(linking.listeners.length, 0);
  sb.handleDeepLink('myapp://manual?utm_source=mail');
  assert.deepEqual(native.calls.filter((c) => c[0] !== 'start'), [['handleDeepLink', 'myapp://manual?utm_source=mail']]);
});

test('links are not observed on an unknown platform, without native support, or when Linking fails', async () => {
  const other = withLinks(fakeNative());
  const a = fakeLinking('myapp://x');
  await createSmartBee(other, { platform: 'windows', linking: a }).init(KEY);
  assert.equal(a.listeners.length, 0);

  // No listener is attached when the native module has no handleDeepLink method.
  const old = fakeLinking('myapp://x');
  await createSmartBee(fakeNative(), { platform: 'android', linking: old }).init(KEY);
  assert.equal(old.listeners.length, 0);

  const ios = withLinks(fakeNative());
  const broken = { getInitialURL: () => { throw new Error('no linking'); }, addEventListener() { throw new Error('no linking'); } };
  assert.equal(await createSmartBee(ios, { platform: 'ios', linking: broken }).init(KEY), true);
  const rejecting = { getInitialURL: () => Promise.reject(new Error('denied')), addEventListener() {} };
  assert.equal(await createSmartBee(ios, { platform: 'ios', linking: rejecting }).init(KEY), true);
  await tick();
  assert.deepEqual(ios.calls.filter((c) => c[0] !== 'start'), []);
});

test('the package entry is CommonJS, exposes default / named exports and reads VERSION from package.json', () => {
  const pkg = JSON.parse(read('package.json'));
  assert.equal(pkg.type, undefined, 'no "type": "module": Jest and CommonJS consumers must be able to require the package');
  assert.equal(pkg.exports['.'].types, './index.d.ts');
  assert.equal(pkg.exports['.'].default, './src/index.js');
  assert.equal(pkg.exports['./jest/mock'], './jest/mock.js');
  for (const dir of ['src', 'jest']) assert.ok(pkg.files.includes(dir), dir);

  // The entry is loaded with a stubbed `react-native`, the way Metro or Jest would resolve it.
  const Module = require('node:module');
  const original = Module._load;
  const linking = fakeLinking(null);
  const native = withLinks(fakeNative());
  Module._load = function load(request, ...rest) {
    if (request === 'react-native') return { Linking: linking, NativeModules: { SmartBeePixel: native }, Platform: { OS: 'android' } };
    return original.call(this, request, ...rest);
  };
  let entry;
  try {
    entry = require('../src/index.js');
  } finally {
    Module._load = original;
  }
  assert.equal(entry.__esModule, true);
  assert.equal(entry.default, entry.SmartBee);
  assert.equal(entry.VERSION, pkg.version);
  assert.equal(entry.SmartBee.sdkVersion, pkg.version);
  for (const method of ['init', 'track', 'identify', 'screen', 'setConsent', 'reset', 'flush', 'handleDeepLink', 'getAnonymousId']) {
    assert.equal(typeof entry.SmartBee[method], 'function', method);
  }
  // The version marker that mobile/release.mjs rewrites must match package.json.
  assert.equal(/^export const VERSION = '([^']+)'/m.exec(read('src/index.js'))[1], pkg.version);
});

test('the Jest mock has the same surface as the real API and the type declarations', () => {
  const mock = require('../jest/mock.js');
  const real = createSmartBee(fakeNative(), { version: '1.0.0' });
  assert.equal(mock.__esModule, true);
  assert.equal(mock.default, mock.SmartBee);
  assert.deepEqual(Object.keys(mock.SmartBee).sort(), Object.keys(real).sort());
  const types = read('index.d.ts');
  const declared = types.slice(types.indexOf('export interface SmartBeeApi'));
  for (const member of Object.keys(real)) assert.match(declared, new RegExp('^\\s+(readonly )?' + member + '[(:]', 'm'), member);
});

test('the native files are in the package and the Swift bridge matches its Objective-C declarations', () => {
  for (const path of [
    'android/build.gradle',
    'android/src/main/java/az/smartbee/pixel/Core.kt',
    'android/src/main/java/az/smartbee/pixel/reactnative/SmartBeePixelModule.kt',
    'android/src/main/java/az/smartbee/pixel/reactnative/SmartBeePixelPackage.kt',
    'ios/Core/Core.swift',
    'ios/SmartBeePixelBridge.m',
    'ios/Resources/PrivacyInfo.xcprivacy',
    'smartbee-pixel.podspec',
  ]) {
    assert.ok(existsSync(new URL(path, root)), path);
  }
  // The Swift methods of the bridge and their Objective-C declarations must have the same selectors.
  const swift = read('ios/SmartBeePixelBridge.swift');
  const objc = read('ios/SmartBeePixelBridge.m');
  const swiftSelectors = [...swift.matchAll(/@objc\(([^)]+)\)\s*\n\s*func/g)].map((m) => m[1]).concat([...swift.matchAll(/@objc func (\w+)\(\)/g)].map((m) => m[1])).sort();
  const prefix = 'RCT_EXTERN_METHOD(';
  const objcSelectors = objc
    .split('\n')
    .filter((line) => line.startsWith(prefix))
    // "start:(NSString *)key options:(NSDictionary *)options" -> "start:options:"
    .map((line) => line.slice(prefix.length, line.lastIndexOf(')')).replace(/\([^)]*\)\s*\w+/g, '').replace(/\s+/g, ''))
    .sort();
  assert.equal(objcSelectors.length, 10);
  assert.deepEqual(objcSelectors, swiftSelectors);
  // Every native method the JavaScript side calls exists in both bridges.
  const kotlin = read('android/src/main/java/az/smartbee/pixel/reactnative/SmartBeePixelModule.kt');
  for (const method of ['start', 'track', 'identify', 'screen', 'setConsent', 'reset', 'flush', 'handleDeepLink', 'handleInitialLink', 'getAnonymousId']) {
    assert.match(kotlin, new RegExp('@ReactMethod\\s+fun ' + method + '\\('), 'Kotlin: ' + method);
    assert.ok(objcSelectors.some((selector) => selector === method || selector.startsWith(method + ':')), 'Objective-C: ' + method);
  }
});

test('the native bridges default a missing consent purpose to false, and a consent that is not an object to denied', () => {
  const kotlin = read('android/src/main/java/az/smartbee/pixel/reactnative/SmartBeePixelModule.kt');
  assert.match(kotlin, /SmartBeeConsent\(map\.bool\("analytics", false\), map\.bool\("ads", false\)\)/);
  // Present but not a map (and not null): both purposes denied.
  assert.match(kotlin, /options\.getType\("consent"\) == ReadableType\.Null -> null/);
  assert.match(kotlin, /else -> SmartBeeConsent\(false, false\)/);
  const swift = read('ios/SmartBeePixelBridge.swift');
  // A real boolean only: the number 1 is not consent.
  assert.match(swift, /CFGetTypeID\(number\) == CFBooleanGetTypeID\(\)/);
  assert.match(swift, /strictBool\(consent\["analytics"\]\) \?\? false/);
  assert.match(swift, /strictBool\(consent\["ads"\]\) \?\? false/);
  assert.doesNotMatch(swift, /consent\["(analytics|ads)"\] as\? Bool/);
  assert.match(swift, /config\.consent = SmartBeeConsent\(analytics: false, ads: false\)/);
});

test('track: a numeric eventId is sent as a string; other types are dropped with a development warning', () => {
  const native = fakeNative();
  const warnings = [];
  const sb = createSmartBee(native, { dev: true, warn: (m) => warnings.push(m) });
  sb.track('Purchase', null, { eventId: 1001 });
  sb.track('Purchase', null, { eventId: 0 });
  sb.track('Purchase', null, { eventId: NaN });
  sb.track('Purchase', null, { eventId: { id: 1 } });
  sb.track('Purchase', null, { eventId: true });
  sb.track('Purchase', null, { eventId: null });
  sb.track('Purchase', null, {});
  sb.track('Purchase', null, 'order-1');
  assert.deepEqual(native.calls.map((call) => call[3]), ['1001', '0', null, null, null, null, null, null]);
  assert.equal(warnings.length, 3);
  assert.ok(warnings.every((message) => message.includes('eventId')));
});

test('Android: the launch link is not reported again for a restored Activity', () => {
  const kotlin = read('android/src/main/java/az/smartbee/pixel/reactnative/SmartBeePixelModule.kt');
  // Recreated in the same process (savedInstanceState), and restored after the process was killed (stored marker).
  assert.match(kotlin, /seen\[activity\] = savedInstanceState != null/);
  assert.match(kotlin, /if \(restored == true\) return false/);
  assert.match(kotlin, /storedMatches\(app, hash, task\)/);
  // Only a hash of the link is stored, and only while the SDK has analytics consent.
  assert.match(kotlin, /putString\(PREF_LINK, hash\)/);
  assert.doesNotMatch(kotlin, /putString\([A-Z_]+, url\)/);
  assert.match(kotlin, /if \(SmartBee\.getAnonymousId\(\) == null\) return/);
  assert.match(kotlin, /if \(!analytics\) forgetStoredLink\(/);
});

test('advertising id: the option reaches both bridges; the Android permission and R8 rules ship with the package', () => {
  const pkg = JSON.parse(read('package.json'));

  // Both native bridges read the option and write it to SmartBeeOptions.
  assert.match(read('android/src/main/java/az/smartbee/pixel/reactnative/SmartBeePixelModule.kt'), /collectAdvertisingId = options\?\.bool\("collectAdvertisingId", true\)/);
  assert.match(read('ios/SmartBeePixelBridge.swift'), /options\?\["collectAdvertisingId"\] as\? Bool \{ config\.collectAdvertisingId = /);

  // The wrapper carries the source of the native SDK, not its AAR: the permission and the R8 rules must come with it.
  assert.match(read('android/src/main/AndroidManifest.xml'), /<uses-permission android:name="com\.google\.android\.gms\.permission\.AD_ID"/);
  assert.match(read('android/build.gradle'), /consumerProguardFiles 'consumer-rules\.pro'/);
  assert.ok(pkg.files.includes('android/consumer-rules.pro'));
  const rules = read('android/consumer-rules.pro');
  assert.match(rules, /-keep class com\.google\.android\.gms\.ads\.identifier\.AdvertisingIdClient \{/);
  assert.match(rules, /-keep class com\.google\.android\.gms\.ads\.identifier\.AdvertisingIdClient\$Info \{/);

  // iOS: AppTrackingTransparency is weak-linked (it does not exist on iOS 13).
  const podspec = read('smartbee-pixel.podspec');
  assert.match(podspec, /s\.frameworks = 'AdSupport'/);
  assert.match(podspec, /s\.weak_frameworks = 'AppTrackingTransparency'/);
});
