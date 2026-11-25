import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import Ajv2020 from 'ajv/dist/2020.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const load = (p) => JSON.parse(readFileSync(join(root, p), 'utf8'));

const ajv = new Ajv2020({ allErrors: true, strict: true, strictRequired: false });
const validateBatch = ajv.compile(load('schema/batch.v1.schema.json'));
const validateConfig = ajv.compile(load('schema/config.v1.schema.json'));

const validFiles = readdirSync(join(root, 'vectors/valid'));
const invalidFiles = readdirSync(join(root, 'vectors/invalid'));

test('vektorlar mövcuddur', () => {
  assert.ok(validFiles.length >= 4);
  assert.ok(invalidFiles.length >= 12);
});

for (const file of validFiles) {
  test(`valid/${file} sxemdən keçir`, () => {
    const { batch } = load(`vectors/valid/${file}`);
    assert.equal(validateBatch(batch), true, JSON.stringify(validateBatch.errors, null, 2));
  });
}

for (const file of invalidFiles) {
  test(`invalid/${file} rədd olunur`, () => {
    const { batch } = load(`vectors/invalid/${file}`);
    assert.equal(validateBatch(batch), false);
  });
}

test('susmaya görə konfiq sxemdən keçir', () => {
  assert.equal(validateConfig(load('vectors/config-default.json')), true, JSON.stringify(validateConfig.errors));
});

test('konfiqdə naməlum sahə rədd olunmur', () => {
  assert.equal(validateConfig({ ...load('vectors/config-default.json'), future: 1 }), true);
});

// Normallaşdırma qaydalarının istinad tətbiqi (PROTOCOL.md, 6.1).
const normEmail = (s) => s.trim().toLowerCase();
const normPhone = (s) => s.replace(/[^0-9]/g, '');
const sha256 = (s) => createHash('sha256').update(s, 'utf8').digest('hex');

test('e-poçt və telefon: normallaşdırma və SHA-256', () => {
  const v = load('vectors/hashing.json');
  for (const { input, normalized, sha256: expected } of v.email) {
    assert.equal(normEmail(input), normalized);
    assert.equal(sha256(normEmail(input)), expected);
  }
  for (const { input, normalized, sha256: expected } of v.phone) {
    assert.equal(normPhone(input), normalized);
    assert.equal(sha256(normPhone(input)), expected);
  }
});

// Ortaq təmizləmə vektorları: gözlənilən dəyərlər veb tracker-in nəticəsidir (tracker/test/vectors.test.js) və eyni
// fayllar Android (SanitizeVectorsTest.kt) və iOS (SanitizeVectorsTests.swift) testlərində işlədilir. Burada yalnız
// faylların quruluşu yoxlanır ki, yarımçıq və ya gözlənilən dəyəri olmayan giriş repo-ya düşməsin.
const sanitizeFiles = {
  'sanitize-url.json': { min: 60, check: (c) => typeof c.url === 'string' && typeof c.expected === 'string' && c.url.length <= 4096 && c.expected.length <= 2048 },
  // kind: label — ekran adı / səhifə başlığı: giriş və gözlənilən dəyər mətndir.
  'sanitize-props.json': { min: 40, check: (c) => (c.kind === 'label' ? typeof c.input === 'string' && typeof c.expected === 'string' :
    (c.kind === 'props' || c.kind === 'traits') && isObject(c.input) && (c.expected === null || isObject(c.expected))) },
  'identity.json': { min: 25, check: (c) => typeof c.input === 'string' && (c.expected === null || (typeof c.expected === 'string' && c.expected.length > 0 && c.expected.length <= 128)) },
  'campaign.json': { min: 20, check: (c) => typeof c.url === 'string' && (c.expected === null || (isObject(c.expected) && Object.values(c.expected).every((v) => typeof v === 'string' && v.length > 0 && v.length <= 512))) },
};
function isObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

for (const [file, { min, check }] of Object.entries(sanitizeFiles)) {
  test(`vectors/${file}: quruluş`, () => {
    const data = load(`vectors/${file}`);
    assert.equal(typeof data.description, 'string');
    assert.ok(Array.isArray(data.cases) && data.cases.length >= min, `ən azı ${min} giriş`);
    const names = new Set();
    for (const c of data.cases) {
      assert.ok(typeof c.name === 'string' && c.name.length > 0, 'ad boşdur');
      assert.ok(!names.has(c.name), `ad təkrarlanır: ${c.name}`);
      names.add(c.name);
      assert.ok('expected' in c, `expected yoxdur: ${c.name}`);
      assert.ok(check(c), `yararsız giriş: ${c.name}`);
      if ('ads' in c) assert.equal(typeof c.ads, 'boolean', c.name);
      if ('strip' in c) assert.ok(Array.isArray(c.strip) && c.strip.every((s) => typeof s === 'string'), c.name);
    }
  });
}

test('vectors/identity.json və sanitize-props.json: hash-lər hashing.json ilə eyni normallaşdırmadan alınır', () => {
  const identity = load('vectors/identity.json').cases;
  const byInput = (input) => identity.find((c) => c.input === input).expected;
  assert.equal(byInput('user@example.com'), sha256('user@example.com'));
  assert.equal(byInput('  user@example.com\t\n'), sha256('user@example.com'));
  assert.equal(byInput('User.Test@Example.COM'), sha256(normEmail('User.Test@Example.COM')));
  assert.equal(byInput('+994 (50) 123-45-67'), sha256(normPhone('+994 (50) 123-45-67')));
  const traits = load('vectors/sanitize-props.json').cases.find((c) => c.kind === 'traits' && c.input.email === '  User@Example.COM ');
  assert.equal(traits.expected.email_sha256, sha256('user@example.com'));
  assert.equal(traits.expected.phone_sha256, sha256('994501234567'));
});
