import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const load = (p) => JSON.parse(readFileSync(join(here, p), 'utf8'));

export const batchSchema = load('schema/batch.v1.schema.json');
export const configSchema = load('schema/config.v1.schema.json');
export const defaultConfig = load('vectors/config-default.json');

/** Protokol limitləri (PROTOCOL.md, 5.2). */
export const LIMITS = Object.freeze({
  maxEvents: 100,
  maxBodyBytes: 500 * 1024,
  maxEventBytes: 32 * 1024,
  maxDepth: 4,
  /** ctx obyektinin sıxılmamış JSON ölçüsü. */
  maxCtxBytes: 8 * 1024,
  /** Bütün gövdənin iç-içəlik dərinliyi. */
  maxBatchDepth: 12,
});
