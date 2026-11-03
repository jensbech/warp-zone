import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { filterItems, fuzzyScore } from '../cli/tool-picker.mjs';

const catalog = JSON.parse(readFileSync(new URL('../template/catalog.json', import.meta.url), 'utf8'));
const items = catalog.tools.filter((tool) => !tool.hidden);
const top = (query, count = 3) => filterItems(query, items).slice(0, count).map((item) => item.id);

assert.equal(fuzzyScore('xyz', 'node'), -1);
assert.ok(fuzzyScore('nd', 'node') > 0);
assert.ok(fuzzyScore('node', 'node') > fuzzyScore('node', 'nodejs'));
assert.equal(top('node')[0], 'node');
assert.equal(top('kubectl')[0], 'kubectl');
assert.equal(top('psql')[0], 'postgres-client');
assert.equal(top('golang')[0], 'go');
assert.ok(top('tf').includes('terraform') || top('tf').includes('tflint'));
assert.ok(top('k8s', 8).includes('k9s'));
assert.ok(top('pstgr').includes('postgres-client'));
assert.ok(top('lzgit').includes('lazygit'));
assert.ok(top('aws').includes('aws-cli'));
assert.equal(filterItems('zzzzqqq', items).length, 0);
assert.equal(filterItems('', items).length, items.length);
console.log('fuzzy ok');
