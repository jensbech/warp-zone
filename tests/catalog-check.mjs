#!/usr/bin/env node

import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const catalogPath = path.join(root, 'template', 'catalog.json');
const installer = readFileSync(path.join(root, 'template', 'install-tools.sh'), 'utf8');
const online = process.argv.includes('--online');
const onlyArg = process.argv.find((arg) => arg.startsWith('--only='));
const only = onlyArg ? new Set(onlyArg.slice(7).split(',')) : null;

const legacyToggles = [
  'NODE', 'PYTHON', 'GO', 'RUST', 'DOTNET', 'JAVA', 'RUBY', 'BUN', 'DENO', 'KUBECTL', 'HELM', 'K9S', 'TERRAFORM',
  'PULUMI', 'AWS_CLI', 'AZURE_CLI', 'GCLOUD', 'POSTGRES_CLIENT', 'MYSQL_CLIENT', 'REDIS', 'SQLITE', 'GH', 'JIRA',
  'NEOVIM', 'LAZYGIT', 'DELTA', 'YQ', 'DIRENV', 'HTTPIE', 'BTOP', 'SSH'
];
const methodKeys = ['apt', 'release', 'npm', 'uv', 'script', 'stage'];
const archs = ['amd64', 'arm64'];

const errors = [];
const fail = (id, message) => errors.push(`${id}: ${message}`);

let catalog;
try {
  catalog = JSON.parse(readFileSync(catalogPath, 'utf8'));
} catch (error) {
  console.error(`catalog.json does not parse: ${error.message}`);
  process.exit(1);
}

const ids = new Set();
for (const tool of catalog.tools) ids.add(tool.id);

const methodsOf = (tool) => (Array.isArray(tool.install) ? tool.install : [tool.install]);

for (const tool of catalog.tools) {
  const id = tool.id ?? '(missing id)';
  if (typeof tool.id !== 'string' || !/^[a-z0-9][a-z0-9-]*$/.test(tool.id)) fail(id, 'id must match [a-z0-9-]');
  for (const field of ['label', 'group', 'keywords']) {
    if (typeof tool[field] !== 'string' || !tool[field].trim()) fail(id, `missing ${field}`);
  }
  if (catalog.tools.filter((other) => other.id === tool.id).length > 1) fail(id, 'duplicate id');
  if (!tool.install) fail(id, 'missing install');
  const methods = tool.install ? methodsOf(tool) : [];
  const hasStage = methods.some((method) => method.stage);
  if (!tool.check && !tool.hidden && !hasStage) fail(id, 'missing check command');
  for (const requirement of tool.requires ?? []) {
    if (!ids.has(requirement)) fail(id, `requires unknown tool "${requirement}"`);
  }
  for (const method of methods) {
    const kinds = methodKeys.filter((key) => key in method);
    if (kinds.length !== 1) {
      fail(id, `install needs exactly one of ${methodKeys.join('/')}, found [${kinds.join(', ')}]`);
      continue;
    }
    const [kind] = kinds;
    if (method.repo && !(method.repo in catalog.repos)) fail(id, `unknown apt repo "${method.repo}"`);
    if (kind === 'apt' && !/^[a-z0-9][a-z0-9+.:_ -]*$/.test(method.apt)) fail(id, 'invalid apt package list');
    if (kind === 'script' && !new RegExp(`^install_script_${method.script.replace(/-/g, '_')}\\(\\)`, 'm').test(installer)) {
      fail(id, `install-tools.sh has no install_script_${method.script.replace(/-/g, '_')}`);
    }
    if (kind === 'release') {
      if (typeof method.release !== 'string' || !method.release.startsWith('https://')) fail(id, 'release url must be https');
      if (!method.bin && !method.dir) fail(id, 'release needs bin or dir');
      if (method.dir && !method.dir.startsWith('/')) fail(id, 'dir must be absolute');
      if (method.release.includes('{arch}')) {
        for (const arch of archs) {
          if (method.arch && !method.arch[arch]) fail(id, `arch map is missing ${arch}`);
        }
      } else if (method.arch) {
        fail(id, 'arch map given but url has no {arch}');
      }
      if (method.release.includes('{version}') && !method.version && !method.gh && !method.latest) {
        fail(id, 'url uses {version} but there is no pinned version, gh repo or latest source');
      }
    }
    if ((kind === 'npm' || kind === 'uv') && !(tool.requires ?? []).includes(kind === 'npm' ? 'node' : 'uv')) {
      fail(id, `${kind} install must require ${kind === 'npm' ? 'node' : 'uv'}`);
    }
  }
}

for (const name of legacyToggles) {
  const id = name.toLowerCase().replace(/_/g, '-');
  if (!ids.has(id)) fail(`INCLUDE_${name}`, `no catalog tool with id "${id}"`);
}
for (const name of ['NODE_MAJOR', 'PNPM_VERSION', 'YARN_VERSION']) {
  if (!(name in catalog.vars)) fail(name, 'missing from vars');
}

const byGroup = new Map();
for (const tool of catalog.tools.filter((entry) => !entry.hidden)) byGroup.set(tool.group, (byGroup.get(tool.group) ?? 0) + 1);

const versionVar = (id) => `${id.toUpperCase().replace(/-/g, '_')}_VERSION`;

async function fetchOk(url, { range = true } = {}) {
  const attempt = async () => {
    const response = await fetch(url, { headers: range ? { Range: 'bytes=0-0' } : {}, redirect: 'follow', signal: AbortSignal.timeout(30000) });
    await response.body?.cancel();
    return response;
  };
  let last;
  for (let i = 0; i < 3; i += 1) {
    try {
      last = await attempt();
      if (last.ok) return last;
    } catch (error) {
      last = { ok: false, status: String(error.cause?.code ?? error.message) };
    }
  }
  return last;
}

async function resolveVersion(method) {
  if (method.version) return method.version.replace(/^v/, '');
  if (method.latest) {
    const response = await fetch(method.latest.url, { signal: AbortSignal.timeout(30000) });
    const data = await response.json();
    const value = method.latest.jq.slice(1).split('.').reduce((acc, key) => acc?.[key], data);
    return String(value).replace(/^v/, '');
  }
  if (method.gh) {
    const response = await fetch(`https://github.com/${method.gh}/releases/latest`, { signal: AbortSignal.timeout(30000) });
    await response.body?.cancel();
    const tag = response.url.split('/').pop();
    return tag.replace(new RegExp(`^${method.tag_prefix ?? ''}`), '').replace(/^v/, '');
  }
  return '';
}

async function pool(items, size, worker) {
  const queue = [...items];
  await Promise.all(Array.from({ length: size }, async () => {
    while (queue.length) await worker(queue.shift());
  }));
}

if (online) {
  const jobs = [];
  for (const tool of catalog.tools) {
    if (only && !only.has(tool.id)) continue;
    for (const method of methodsOf(tool)) jobs.push({ tool, method });
  }
  await pool(jobs, 8, async ({ tool, method }) => {
    try {
      if (method.release) {
        const version = await resolveVersion(method);
        if (method.release.includes('{version}') && !version) return fail(tool.id, 'could not resolve a version');
        for (const arch of archs) {
          const url = method.release.replaceAll('{version}', version).replaceAll('{arch}', method.arch?.[arch] ?? arch);
          const response = await fetchOk(url);
          if (!response.ok) fail(tool.id, `${arch}: HTTP ${response.status} for ${url}`);
        }
      } else if (method.npm) {
        for (const pkg of method.npm.split(' ')) {
          const response = await fetchOk(`https://registry.npmjs.org/${pkg.replace('/', '%2F')}`, { range: false });
          if (!response.ok) fail(tool.id, `npm package ${pkg}: HTTP ${response.status}`);
        }
      } else if (method.uv) {
        const pkg = method.uv.replace(/\[.*\]$/, '');
        const response = await fetchOk(`https://pypi.org/pypi/${pkg}/json`, { range: false });
        if (!response.ok) fail(tool.id, `PyPI package ${pkg}: HTTP ${response.status}`);
      }
    } catch (error) {
      fail(tool.id, `online check crashed: ${error.message}`);
    }
  });
}

if (errors.length) {
  console.error(errors.sort().join('\n'));
  console.error(`\n${errors.length} problem(s) in ${catalog.tools.length} catalog entries.`);
  process.exit(1);
}
const summary = [...byGroup].map(([group, count]) => `${group}: ${count}`).join('\n  ');
console.log(`catalog ok: ${catalog.tools.length} entries${online ? ' (online checks passed)' : ''}\n  ${summary}`);
