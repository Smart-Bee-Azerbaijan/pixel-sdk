// SDK testlərinin yazdığı topluları (hər sətirdə bir JSON) ortaq sxemlə yoxlayır.
// İstifadə: node spec/validate-batches.mjs <fayl.jsonl>
import { readFileSync } from 'node:fs';
import Ajv2020 from 'ajv/dist/2020.js';
import { batchSchema } from './index.js';

const file = process.argv[2];
if (!file) {
  console.error('fayl göstərilməyib');
  process.exit(2);
}

const validate = new Ajv2020({ allErrors: true, strict: true, strictRequired: false }).compile(batchSchema);
const lines = readFileSync(file, 'utf8').split('\n').filter((line) => line.trim() !== '');
let failed = 0;
lines.forEach((line, index) => {
  let batch;
  try {
    batch = JSON.parse(line);
  } catch {
    failed++;
    console.error(`sətir ${index + 1}: JSON oxunmadı`);
    return;
  }
  if (!validate(batch)) {
    failed++;
    console.error(`sətir ${index + 1}: ${JSON.stringify(validate.errors)}`);
  }
});

if (lines.length === 0) {
  console.error('fayl boşdur: heç bir toplu yoxlanmadı');
  process.exit(1);
}
console.log(`${lines.length} toplu yoxlandı, ${failed} yararsız`);
process.exit(failed ? 1 : 0);
