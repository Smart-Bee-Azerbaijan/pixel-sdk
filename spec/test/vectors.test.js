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
