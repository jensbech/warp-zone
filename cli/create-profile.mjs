#!/usr/bin/env node

import { access, chmod, copyFile, mkdir, readdir, readFile, rm, statfs, writeFile } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import net from 'node:net';
import { execFile, execFileSync } from 'node:child_process';
import { parseArgs, promisify } from 'node:util';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { constants } from 'node:fs';
import process from 'node:process';
import chalk from 'chalk';
import { input, checkbox, confirm, select, Separator } from '@inquirer/prompts';
import { pickTools, orderByGroup } from './tool-picker.mjs';

const execFileAsync = promisify(execFile);

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..');
const templateDir = path.join(repoRoot, 'template');
const profilesRoot = path.join(process.env.HOME ?? '', 'warp');

// Docker's namespace is global to the daemon, so every warp-zone resource is
// prefixed and labelled — a profile named "dev" must not collide with whatever
// else happens to be called "dev" on this machine.
const RESOURCE_PREFIX = 'warp-';
const FIRST_SSH_PORT = 2200;
const FIRST_T3CODE_PORT = 3773;
const T3CODE_TOOL = 't3code';
const TAILSCALE_TOOL = 'tailscale';
const DEFAULT_TAILSCALE_TAGS = 'tag:warp';

const containerNameFor = (profile) => `${RESOURCE_PREFIX}${profile}`;
const imageNameFor = (profile) => `${RESOURCE_PREFIX}${profile}:latest`;
const workVolumeFor = (profile) => `${RESOURCE_PREFIX}${profile}-work`;
const dockerVolumeFor = (profile) => `${RESOURCE_PREFIX}${profile}-docker`;

// Neutral, minimal default — a fresh Linux box with just the essentials.
const DEFAULT_PROFILE_NAME = 'dev';
const ALWAYS_INCLUDED = 'git, ripgrep, jq, fzf, bat, eza, tmux, zsh, Claude Code';

const distroOptions = [
  { name: 'Ubuntu 24.04 LTS', value: 'ubuntu:24.04' },
  { name: 'Ubuntu 22.04 LTS', value: 'ubuntu:22.04' },
  { name: 'Debian 12 (Bookworm)', value: 'debian:12' }
];

const catalog = JSON.parse(readFileSync(path.join(templateDir, 'catalog.json'), 'utf8'));
const catalogById = new Map(catalog.tools.map((tool) => [tool.id, tool]));
const pickableTools = catalog.tools.filter((tool) => !tool.hidden);
const catalogOrder = new Map(catalog.tools.map((tool, index) => [tool.id, index]));

const legacyKeyFor = (id) => `INCLUDE_${id.toUpperCase().replace(/-/g, '_')}`;
const toolIdFromLegacyKey = (key) => {
  if (!key.startsWith('INCLUDE_') || key === 'INCLUDE_SSH') return null;
  const id = key.slice('INCLUDE_'.length).toLowerCase().replace(/_/g, '-');
  return catalogById.has(id) ? id : null;
};
const legacyToolKeys = new Set(pickableTools.map((tool) => legacyKeyFor(tool.id)));

function toolsFromValues(values) {
  const ids = new Set((values.TOOLS ?? '').split(/\s+/).filter(Boolean));
  for (const [key, value] of Object.entries(values)) {
    const id = toolIdFromLegacyKey(key);
    if (id && value === 'true') ids.add(id);
  }
  return [...ids].filter((id) => catalogById.has(id) && !catalogById.get(id).hidden).sort((a, b) => catalogOrder.get(a) - catalogOrder.get(b));
}

function unknownToolIds(values) {
  return (values.TOOLS ?? '').split(/\s+/).filter((id) => id && !catalogById.has(id));
}

const extraAptFromValues = (values) => (values.EXTRA_APT_PACKAGES ?? '').split(/\s+/).filter(Boolean);

function impliedTools(selected) {
  const have = new Set(selected);
  const implied = [];
  const visit = (id) => {
    for (const requirement of catalogById.get(id)?.requires ?? []) {
      if (!have.has(requirement)) {
        have.add(requirement);
        implied.push(requirement);
        visit(requirement);
      }
    }
  };
  selected.forEach(visit);
  return implied;
}

// Optional host integrations. All off by default — a fresh profile is hermetic
// (no host mount). Enabling these bind-mounts a host dotfiles dir read-only and
// pulls in the selected pieces during bootstrap.
const integrationOptions = [
  { name: 'Git identity (user.name / user.email)', value: 'LINK_GIT_IDENTITY' },
  { name: 'Claude config (settings.json, CLAUDE.md)', value: 'LINK_CLAUDE' },
  { name: 'opencode config (opencode.json, AGENTS.md)', value: 'LINK_OPENCODE' },
  { name: 'GitHub Copilot instructions', value: 'LINK_COPILOT' }
];

function sanitizeName(value) {
  return value.toLowerCase().replace(/[^a-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '') || 'profile';
}

function sanitizeUser(value) {
  return value.toLowerCase().replace(/[^a-z0-9_-]+/g, '-').replace(/^[^a-z_]+/, '').replace(/-+$/, '') || 'dev';
}

const sharedRecipesDir = path.join(repoRoot, 'recipes');
const localRecipesDir = path.join(process.env.XDG_CONFIG_HOME || path.join(process.env.HOME ?? '', '.config'), 'warp-zone', 'recipes');

const SOURCE_LABELS = { local: 'local', repo: 'repo', file: 'file' };

async function collectRecipes() {
  const found = new Map();
  for (const [source, dir] of [['repo', sharedRecipesDir], ['local', localRecipesDir]]) {
    let files = [];
    try {
      files = (await readdir(dir)).filter((file) => file.endsWith('.env'));
    } catch {}
    for (const file of files) {
      const name = path.basename(file, '.env');
      const previous = found.get(name);
      found.set(name, { name, source, file: path.join(dir, file), overrides: Boolean(previous) });
    }
  }
  return [...found.values()].sort((a, b) => a.name.localeCompare(b.name));
}

async function resolveRecipe(name) {
  if (name.includes('/') || name.endsWith('.env')) {
    const file = path.resolve(name);
    if (!(await exists(file))) throw new Error(`No such recipe file: ${file}`);
    return { name: path.basename(file, '.env'), source: 'file', file };
  }
  const recipes = await collectRecipes();
  const match = recipes.find((recipe) => recipe.name === name);
  if (!match) {
    const available = recipes.map((recipe) => recipe.name).join(', ');
    throw new Error(`No such recipe: ${name}${available ? ` (available: ${available})` : ' (none saved yet)'}. List them with: just recipes`);
  }
  return match;
}

const instanceKeys = new Set([
  'PROFILE_NAME',
  'CONTAINER_NAME',
  'IMAGE_NAME',
  'WORK_VOLUME',
  'DOCKER_VOLUME',
  'APP_USER',
  'APP_UID',
  'PROFILE_PROMPT',
  'SSH_PORT',
  'SSH_HOSTNAME',
  'SSH_PUBKEY',
  'T3CODE_PORT'
]);

const structuredKeys = new Set([
  ...instanceKeys,
  'BASE_IMAGE',
  'CPUS',
  'MEMORY',
  'DOTFILES_DIR',
  'DOCKERD_ARGS',
  'INCLUDE_SSH',
  'T3CODE_SERVE',
  'T3CODE_ACCESS',
  'TAILSCALE_TAGS',
  'TOOLS',
  'EXTRA_APT_PACKAGES',
  ...integrationOptions.map((option) => option.value),
  ...legacyToolKeys
]);

const managedToolKeys = new Set(['TOOLS', 'EXTRA_APT_PACKAGES', ...legacyToolKeys]);

const extraKeyPattern = /^(NODE_MAJOR|EXTRA_APT_PACKAGES|BACKUP_KEEP)$|_VERSION$/;

async function loadRecipe(rp) {
  const content = await readFile(rp, 'utf8');
  const entries = parseEnvFile(content);
  const values = Object.fromEntries(entries);
  const setupCandidate = rp.replace(/\.env$/, '.setup.sh');
  return {
    description: content.match(/^# description: (.*)$/m)?.[1] ?? '',
    defaults: {
      baseImage: values.BASE_IMAGE,
      cpus: values.CPUS,
      memory: values.MEMORY,
      dotfilesDir: values.DOTFILES_DIR ?? '',
      sshEnabled: values.INCLUDE_SSH === 'true',
      t3codeServe: values.T3CODE_SERVE === 'true',
      t3codeAccess: values.T3CODE_ACCESS,
      tailscaleTags: values.TAILSCALE_TAGS,
      selectedIntegrations: integrationOptions.filter((option) => values[option.value] === 'true').map((option) => option.value),
      selectedTools: toolsFromValues(values),
      extraApt: extraAptFromValues(values),
      unknownTools: unknownToolIds(values)
    },
    extras: entries.filter(([key]) => !structuredKeys.has(key)),
    setup: (await exists(setupCandidate)) ? setupCandidate : ''
  };
}

function applyRecipeDefaults(defaults, recipe) {
  for (const [key, value] of Object.entries(recipe.defaults)) {
    if (value !== undefined) defaults[key] = value;
  }
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function envLine(key, value) {
  return `${key}=${shellQuote(value)}`;
}

function parseEnvValue(raw) {
  const trimmed = raw.trim();
  if (trimmed.length >= 2 && trimmed.startsWith("'") && trimmed.endsWith("'")) {
    return trimmed.slice(1, -1).replace(/'\\''/g, "'");
  }
  if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
    try {
      return JSON.parse(trimmed);
    } catch {
      return trimmed.slice(1, -1);
    }
  }
  return trimmed;
}

function parseEnvFile(content) {
  const entries = [];
  for (const line of content.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const index = line.indexOf('=');
    if (index === -1) continue;
    entries.push([line.slice(0, index), parseEnvValue(line.slice(index + 1))]);
  }
  return entries;
}

async function exists(targetPath) {
  try {
    await access(targetPath, constants.F_OK);
    return true;
  } catch {
    return false;
  }
}

// Every profile publishes its own sshd on 127.0.0.1:<port>, whether or not SSH
// is switched on, so turning SSH on later never needs the container recreated.
// A port has to clear both checks: not claimed by another profile, and free on
// this host right now.
function portIsFree(port) {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.once('error', () => resolve(false));
    server.once('listening', () => server.close(() => resolve(true)));
    server.listen(port, '127.0.0.1');
  });
}

async function claimedPorts(key, exceptProfile) {
  let entries;
  try {
    entries = await readdir(profilesRoot, { withFileTypes: true });
  } catch {
    return new Set();
  }
  const ports = await Promise.all(entries
    .filter((entry) => entry.isDirectory() && entry.name !== exceptProfile)
    .map(async (entry) => {
      try {
        const content = await readFile(path.join(profilesRoot, entry.name, 'profile.env'), 'utf8');
        return Number(parseEnvFile(content).findLast(([name]) => name === key)?.[1]);
      } catch {
        return NaN;
      }
    }));
  return new Set(ports.filter(Number.isFinite));
}

async function allocatePort(key, first, profileName, existing) {
  const claimed = await claimedPorts(key, profileName);
  if (existing && !claimed.has(Number(existing))) return String(existing);
  for (let port = first; port < first + 500; port += 1) {
    if (claimed.has(port)) continue;
    if (await portIsFree(port)) return String(port);
  }
  throw new Error(`No free port found between ${first} and ${first + 500}.`);
}

const allocateSshPort = (profileName, existing) => allocatePort('SSH_PORT', FIRST_SSH_PORT, profileName, existing);
const allocateT3codePort = (profileName, existing) => allocatePort('T3CODE_PORT', FIRST_T3CODE_PORT, profileName, existing);

function withT3code(selectedTools, serve, access = 'local') {
  if (!serve) return selectedTools;
  const wanted = [T3CODE_TOOL];
  if (access === 'tailscale') wanted.push(TAILSCALE_TOOL);
  const added = wanted.filter((id) => !selectedTools.includes(id) && catalogById.has(id));
  if (!added.length) return selectedTools;
  return [...selectedTools, ...added].sort((a, b) => catalogOrder.get(a) - catalogOrder.get(b));
}

async function commandExists(command) {
  const dirs = (process.env.PATH ?? '').split(path.delimiter).filter(Boolean);
  const found = await Promise.all(dirs.map((dir) => access(path.join(dir, command), constants.X_OK).then(() => true, () => false)));
  return found.includes(true);
}

async function dockerDaemonError() {
  if (!(await commandExists('docker'))) {
    return 'docker is not installed or not on PATH — https://docs.docker.com/get-started/get-docker/';
  }
  try {
    await execFileAsync('docker', ['info']);
    return null;
  } catch {
    return process.platform === 'linux'
      ? 'Cannot reach the Docker daemon. Start it (sudo systemctl start docker) and make sure your user is in the docker group.'
      : 'Cannot reach the Docker daemon. Start Docker Desktop (or your Docker runtime) and try again.';
  }
}

async function lowDiskWarning() {
  try {
    const stats = await statfs(process.env.HOME ?? '/');
    const availableKb = (stats.bavail * stats.bsize) / 1024;
    if (availableKb < 50 * 1024 * 1024) return `Only ${(availableKb / 1024 / 1024).toFixed(1)} GB free on the profile disk; 50 GB or more is recommended.`;
  } catch {}
  return null;
}

function validResources(cpus, memory) {
  return /^(max|[1-9][0-9]*)$/.test(cpus) && /^(max|[1-9][0-9]*[GM])$/.test(memory);
}

async function validateConfig(config) {
  const [dockerError, justExists, dotfilesExists, pubkeyExists, diskWarning] = await Promise.all([
    dockerDaemonError(),
    commandExists('just'),
    config.dotfilesDir ? exists(config.dotfilesDir) : true,
    config.sshEnabled && config.sshPubkey ? exists(config.sshPubkey) : true,
    lowDiskWarning()
  ]);
  const errors = [];
  const warnings = [];
  if (dockerError) errors.push(dockerError);
  if (!justExists) errors.push('just is not installed or not on PATH.');
  if (!validResources(config.cpus, config.memory)) errors.push('CPU must be a positive number or "max"; memory must be like "8G", "512M", or "max".');
  if (!dotfilesExists) errors.push(`Dotfiles directory does not exist: ${config.dotfilesDir}`);
  if (!pubkeyExists) warnings.push(`SSH public key was not found: ${config.sshPubkey}. Existing ~/.ssh/*.pub keys will be tried when opening.`);
  if (diskWarning) warnings.push(diskWarning);
  for (const warning of warnings) console.log(chalk.yellow(`Warning: ${warning}`));
  if (errors.length) throw new Error(errors.join('\n'));
}

async function copyTemplateProfile(profileDir) {
  await mkdir(profileDir, { recursive: true });
  await mkdir(path.join(profileDir, 'templates'), { recursive: true });
  await mkdir(path.join(profileDir, 'lib'), { recursive: true });

  const files = [
    'Dockerfile',
    '.dockerignore',
    'catalog.json',
    'install-tools.sh',
    'bootstrap-home',
    'warp-init',
    'tailnet',
    'build.sh',
    'open.sh',
    'rebuild.sh',
    'ssh.sh',
    'README.md'
  ];

  for (const file of files) {
    await copyFile(path.join(templateDir, file), path.join(profileDir, file));
  }
  for (const file of ['bootstrap-home', 'warp-init', 'tailnet', 'build.sh', 'open.sh', 'rebuild.sh', 'ssh.sh']) {
    await chmod(path.join(profileDir, file), 0o755);
  }

  const setupTarget = path.join(profileDir, 'setup.sh');
  if (!(await exists(setupTarget))) {
    await copyFile(path.join(templateDir, 'setup.sh'), setupTarget);
  }

  const templateFiles = ['.bashrc', '.zshenv', '.zshrc'];
  for (const file of templateFiles) {
    await copyFile(path.join(templateDir, 'templates', file), path.join(profileDir, 'templates', file));
  }

  for (const file of ['helpers.sh', 'backup.sh', 'restore.sh']) {
    await copyFile(path.join(repoRoot, 'lib', file), path.join(profileDir, 'lib', file));
    await chmod(path.join(profileDir, 'lib', file), 0o755);
  }
}

const LABEL_WIDTH = 10;

function tailnetPolicyLines(tags) {
  const list = tags.split(',').filter(Boolean);
  const owners = list.map((tag) => `"${tag}": ["autogroup:admin"]`).join(', ');
  const dst = list.map((tag) => `"${tag}:443"`).join(', ');
  return [
    `"tagOwners": { ${owners} },`,
    '"acls": [',
    `  { "action": "accept", "src": ["autogroup:member"], "dst": [${dst}] }`,
    ']'
  ];
}

function printTailnetPolicy(tags) {
  console.log(chalk.yellow(`\n  ${tags} needs two entries in your tailnet policy (https://login.tailscale.com/admin/acls/file):`));
  for (const line of tailnetPolicyLines(tags)) console.log(`    ${line}`);
  console.log(chalk.dim('  Without "tagOwners" Tailscale refuses the login; without the "acls" rule none of your devices can reach the profile, so pairing fails.\n'));
}

function describeTools(selectedTools, extraApt = []) {
  if (selectedTools.length === 0 && extraApt.length === 0) {
    return chalk.dim('none — minimal base');
  }
  const names = selectedTools.map((id) => catalogById.get(id)?.label ?? id);
  const implied = impliedTools(selectedTools).map((id) => catalogById.get(id)?.label ?? id);
  const parts = [...names, ...extraApt.map((pkg) => `${pkg} (apt)`)];
  const text = parts.join(', ');
  return implied.length ? `${text} ${chalk.dim(`+ required: ${implied.join(', ')}`)}` : text;
}

function describeDotfiles(config) {
  if (!config.dotfilesDir) {
    return chalk.dim('none — hermetic (no host mount)');
  }
  const links = config.selectedIntegrations.length
    ? config.selectedIntegrations
        .map((value) => integrationOptions.find((opt) => opt.value === value)?.name ?? value)
        .join(', ')
    : chalk.dim('mounted, nothing linked');
  return `${config.dotfilesDir}\n  ${' '.repeat(LABEL_WIDTH)}${chalk.dim('links:')} ${links}`;
}

function summarize(config) {
  const distro = distroOptions.find((d) => d.value === config.baseImage)?.name ?? config.baseImage;
  const label = (text) => chalk.dim(text.padEnd(LABEL_WIDTH));
  console.log(chalk.bold('\nReview'));
  console.log(`  ${label('Name')}${config.profileName}`);
  if (config.startedFrom) console.log(`  ${label('From')}${config.startedFrom}`);
  console.log(`  ${label('Distro')}${distro}`);
  console.log(`  ${label('User')}${config.appUser}`);
  console.log(`  ${label('CPU/RAM')}${config.cpus} / ${config.memory}`);
  console.log(`  ${label('Tools')}${describeTools(config.selectedTools, config.extraApt)}`);
  console.log(`  ${label('Dotfiles')}${describeDotfiles(config)}`);
  console.log(`  ${label('SSH')}${config.sshEnabled ? `ssh ${config.sshHostname || config.profileName}  ${chalk.dim(`(127.0.0.1:${config.sshPort}, key: ${config.sshPubkey})`)}` : chalk.dim(`disabled (port ${config.sshPort} reserved)`)}`);
  const t3codeReach = config.t3codeAccess === 'tailscale' ? `localhost:${config.t3codePort} + https://${config.profileName}.<your-tailnet>.ts.net  ${chalk.dim('(own tailnet node, ' + (config.tailscaleTags ? 'tagged ' + config.tailscaleTags : 'untagged') + '; log in once with `tailnet` inside)')}` : `localhost:${config.t3codePort} only`;
  console.log(`  ${label('T3 Code')}${config.t3codeServe ? `${t3codeReach}  ${chalk.dim('(pair with: just t3 ' + config.profileName + (config.t3codeAccess === 'tailscale' ? ' qr' : '') + ')')}` : chalk.dim('not served')}`);
  console.log(`  ${label('Docker')}${chalk.dim('engine inside the profile (docker-in-docker), state on volume ' + config.dockerVolume)}`);
  if (config.recipeExtras?.length) {
    console.log(`  ${label('Extras')}${config.recipeExtras.map(([key, value]) => `${key}=${value}`).join(', ')}`);
  }
  if (config.recipeSetup) {
    console.log(`  ${label('Setup')}${config.recipeSetup}`);
  }
  console.log();
}

async function promptForProfile(defaults, { startedFrom = '', configuring = false } = {}) {
  console.log(chalk.cyanBright.bold(configuring ? `\n🌀 warp-zone — configure ${defaults.profileName}` : '\n🌀 warp-zone — new profile'));
  console.log(chalk.dim(`Profiles live in ${profilesRoot}. Press Enter to accept the suggested answer.\n`));

  const profileNameRaw = await input({
    message: 'Profile name',
    default: defaults.profileName
  });
  const profileName = sanitizeName(profileNameRaw);

  let recipeExtras = [];
  let recipeSetup = '';
  if (!configuring && !startedFrom) {
    const recipes = await collectRecipes();
    if (recipes.length) {
      const startChoices = [{ name: 'Minimal (clean Linux box)', value: '', description: `Just ${ALWAYS_INCLUDED}` }];
      startChoices.push(new Separator(chalk.dim('— Saved recipes —')));
      for (const recipe of recipes) {
        const info = await loadRecipe(recipe.file);
        startChoices.push({
          name: `${recipe.name} ${chalk.dim(`(${SOURCE_LABELS[recipe.source]})`)}`,
          value: recipe.file,
          description: info.description || undefined
        });
      }
      const chosen = await select({ message: 'Start from', choices: startChoices });
      if (chosen) {
        const recipe = await loadRecipe(chosen);
        applyRecipeDefaults(defaults, recipe);
        recipeExtras = recipe.extras;
        recipeSetup = recipe.setup;
        const picked = recipes.find((entry) => entry.file === chosen);
        startedFrom = `recipe ${picked.name} (${SOURCE_LABELS[picked.source]})`;
      }
    }
  }

  console.log(chalk.dim(`\n  Every profile already ships with: ${ALWAYS_INCLUDED}.`));
  if (defaults.unknownTools?.length) {
    console.log(chalk.yellow(`  Ignoring tool id(s) not in the catalog: ${defaults.unknownTools.join(', ')}`));
  }
  const picked = await pickTools({
    message: 'Optional tools',
    items: orderByGroup(pickableTools).map(({ id, label, group, keywords, requires }) => ({ id, label, group, keywords, requires })),
    selected: defaults.selectedTools ?? [],
    extras: defaults.extraApt ?? [],
    pageSize: 12
  });
  const extraApt = picked.extras;

  const t3codeServe = await confirm({
    message: 'Serve T3 Code (web GUI for Claude Code / Codex) from this profile, reachable in your host browser?',
    default: defaults.t3codeServe ?? picked.selected.includes(T3CODE_TOOL)
  });
  let t3codeAccess = 'local';
  if (t3codeServe) {
    t3codeAccess = await select({
      message: 'Who can reach T3 Code?',
      choices: [
        { name: 'Local only (this computer)', value: 'local', description: 'Bound to 127.0.0.1 on this host.' },
        {
          name: 'Tailscale (all devices on your tailnet)',
          value: 'tailscale',
          description: 'The profile joins your tailnet as its own machine, named after the profile, and publishes T3 Code at https://<profile>.<tailnet>.ts.net. Nothing is tied to this host. Log in once with `tailnet` inside the shell.'
        }
      ],
      default: defaults.t3codeAccess ?? 'local'
    });
  }
  let tailscaleTags = defaults.tailscaleTags ?? DEFAULT_TAILSCALE_TAGS;
  let tailscalePolicyPending = false;
  if (t3codeAccess === 'tailscale') {
    const fenced = await select({
      message: 'How should the profile join your tailnet?',
      choices: [
        {
          name: 'Fenced in with an ACL tag (needs a one-time edit of your tailnet policy)',
          value: true,
          description: 'The node can reach nothing on your tailnet unless a rule says so. The tag must be listed under "tagOwners" in your policy first, or Tailscale refuses the login.'
        },
        {
          name: 'Untagged, as one of your own devices (works right away)',
          value: false,
          description: 'No policy edit needed, but the profile can reach whatever you can reach on your tailnet.'
        }
      ],
      default: tailscaleTags !== ''
    });
    tailscaleTags = fenced
      ? (await input({
          message: 'Tailscale ACL tag(s) for this node (comma-separated)',
          default: tailscaleTags || DEFAULT_TAILSCALE_TAGS,
          validate: (value) => value.split(',').every((tag) => /^tag:[A-Za-z][A-Za-z0-9-]*$/.test(tag.trim())) || 'Tags look like tag:warp (letters, digits and dashes).'
        })).split(',').map((tag) => tag.trim()).join(',')
      : '';
    const alreadySetUp = configuring && defaults.t3codeAccess === 'tailscale' && defaults.tailscaleTags === tailscaleTags;
    if (tailscaleTags && !alreadySetUp) {
      printTailnetPolicy(tailscaleTags);
      const policy = await select({
        message: 'Are both entries in your tailnet policy?',
        choices: [
          { name: 'Yes, they are there', value: 'done' },
          { name: 'Not yet - remind me when I log the profile in', value: 'later' },
          { name: 'Skip the tag and join untagged instead', value: 'untagged' }
        ],
        default: 'later'
      });
      if (policy === 'untagged') tailscaleTags = '';
      tailscalePolicyPending = policy === 'later';
    }
  }
  const selectedTools = withT3code(picked.selected.slice().sort((a, b) => catalogOrder.get(a) - catalogOrder.get(b)), t3codeServe, t3codeAccess);

  let baseImage = defaults.baseImage;
  let appUser = defaults.appUser ?? sanitizeUser(profileName);
  let appUid = defaults.appUid;
  let cpus = defaults.cpus;
  let memory = defaults.memory;
  let sshEnabled = defaults.sshEnabled ?? false;
  let sshHostname = defaults.sshHostname ?? '';
  let sshPubkey = defaults.sshPubkey ?? '';
  let dotfilesDir = defaults.dotfilesDir ?? '';
  let selectedIntegrations = defaults.selectedIntegrations ?? [];

  console.log(chalk.dim(`\n  Defaults: ${distroOptions.find((d) => d.value === baseImage)?.name ?? baseImage}, user ${appUser}, ${cpus} CPU / ${memory} RAM, no SSH, no host mount.`));
  const customize = await confirm({
    message: 'Customize advanced settings (distro, user, CPU/RAM, SSH, dotfiles)?',
    default: configuring
  });

  if (customize) {
    baseImage = await select({ message: 'Base distro', choices: distroOptions, default: baseImage });
    appUser = sanitizeUser(await input({ message: 'Username inside the container', default: appUser }));
    appUid = await input({ message: 'Linux uid for that user', default: appUid });
    cpus = await input({ message: 'CPUs ("max" = all host cores)', default: cpus });
    memory = await input({ message: 'Memory ("max" = all host RAM)', default: memory });

    sshEnabled = await confirm({
      message: 'Enable SSH access (e.g. VS Code Remote-SSH, port forwarding)?',
      default: sshEnabled
    });
    if (sshEnabled) {
      sshHostname = await input({ message: 'SSH host alias (`ssh <alias>` on your host)', default: sshHostname || profileName });
      sshPubkey = await input({ message: 'Public key to authorize (path on your host)', default: sshPubkey });
    }

    const useDotfiles = await confirm({
      message: 'Mount host dotfiles read-only (git identity, AI-assistant configs)?',
      default: Boolean(dotfilesDir)
    });
    if (useDotfiles) {
      dotfilesDir = await input({ message: 'Dotfiles directory (mounted at /mnt/dotfiles)', default: defaults.dotfilesDir || defaults.suggestedDotfiles || '' });
      selectedIntegrations = await checkbox({
        message: 'What to link from your dotfiles (space to toggle)',
        choices: integrationOptions.map((opt) => ({ ...opt, checked: defaults.selectedIntegrations?.includes(opt.value) ?? true })),
        pageSize: integrationOptions.length,
        required: false
      });
    } else {
      dotfilesDir = '';
      selectedIntegrations = [];
    }
  }

  if (!validResources(cpus, memory)) throw new Error('CPU must be a positive number or "max"; memory must be like "8G", "512M", or "max".');

  const sshPort = await allocateSshPort(profileName, defaults.sshPort);
  const t3codePort = t3codeServe ? await allocateT3codePort(profileName, defaults.t3codePort) : '';

  return {
    profileName,
    containerName: containerNameFor(profileName),
    imageName: imageNameFor(profileName),
    workVolume: workVolumeFor(profileName),
    dockerVolume: dockerVolumeFor(profileName),
    sshPort,
    baseImage,
    appUser,
    appUid,
    profilePrompt: appUser.toUpperCase(),
    cpus,
    memory,
    dotfilesDir,
    selectedIntegrations,
    sshEnabled,
    sshHostname,
    sshPubkey,
    t3codeServe,
    t3codePort,
    t3codeAccess,
    tailscaleTags,
    tailscalePolicyPending,
    selectedTools,
    extraApt,
    startedFrom,
    recipeExtras,
    recipeSetup
  };
}

async function writeProfileEnv(profileDir, config, extraEntries = []) {
  const enabledTools = new Set(config.selectedTools);
  const enabledIntegrations = new Set(config.selectedIntegrations);
  const lines = [
    envLine('PROFILE_NAME', config.profileName),
    envLine('CONTAINER_NAME', config.containerName),
    envLine('IMAGE_NAME', config.imageName),
    envLine('WORK_VOLUME', config.workVolume),
    envLine('DOCKER_VOLUME', config.dockerVolume),
    envLine('BASE_IMAGE', config.baseImage),
    envLine('APP_USER', config.appUser),
    envLine('APP_UID', config.appUid),
    envLine('PROFILE_PROMPT', config.profilePrompt),
    envLine('CPUS', config.cpus),
    envLine('MEMORY', config.memory),
    // Empty DOTFILES_DIR means hermetic: no host mount, no dotfiles pulled in.
    envLine('DOTFILES_DIR', config.dotfilesDir),
    // Extra flags for the profile's own dockerd, e.g. "--mtu 1400".
    envLine('DOCKERD_ARGS', config.dockerdArgs ?? ''),
    // Always published on 127.0.0.1 so SSH can be switched on later without
    // recreating the container; INCLUDE_SSH only decides whether sshd is installed.
    envLine('SSH_PORT', config.sshPort),
    envLine('INCLUDE_SSH', config.sshEnabled ? 'true' : 'false'),
    envLine('SSH_HOSTNAME', config.sshHostname),
    envLine('SSH_PUBKEY', config.sshPubkey),
    envLine('T3CODE_SERVE', config.t3codeServe ? 'true' : 'false'),
    envLine('T3CODE_PORT', config.t3codePort ?? ''),
    envLine('T3CODE_ACCESS', config.t3codeServe ? (config.t3codeAccess ?? 'local') : 'local'),
    envLine('TAILSCALE_TAGS', config.tailscaleTags ?? DEFAULT_TAILSCALE_TAGS)
  ];

  for (const integration of integrationOptions) {
    lines.push(envLine(integration.value, enabledIntegrations.has(integration.value) ? 'true' : 'false'));
  }

  lines.push(envLine('TOOLS', [...enabledTools].sort().join(' ')));
  if (config.extraApt?.length) lines.push(envLine('EXTRA_APT_PACKAGES', config.extraApt.join(' ')));

  const knownKeys = new Set(lines.map((line) => line.slice(0, line.indexOf('='))));
  for (const key of managedToolKeys) knownKeys.add(key);
  for (const [key, value] of extraEntries) {
    if (!knownKeys.has(key)) {
      lines.push(envLine(key, value));
      knownKeys.add(key);
    }
  }

  const envPath = path.join(profileDir, 'profile.env');
  if (await exists(envPath)) {
    for (const [key, value] of parseEnvFile(await readFile(envPath, 'utf8'))) {
      if (!knownKeys.has(key)) lines.push(envLine(key, value));
    }
  }

  await writeFile(envPath, `${lines.join('\n')}\n`);
}

const cliOptions = {
  dir: { type: 'string' },
  yes: { type: 'boolean' },
  configure: { type: 'boolean' },
  recipe: { type: 'string' },
  export: { type: 'string' },
  shared: { type: 'boolean' },
  forget: { type: 'string' },
  'list-recipes': { type: 'boolean' },
  help: { type: 'boolean', short: 'h' }
};

const HELP = `warp-zone — create isolated Linux dev profiles

Usage: cli/create-profile.mjs [options]

  (no options)         interactive wizard
  --dir <name>         profile name (default: dev)
  --yes                create with defaults, no prompts
  --recipe <name>      start from a saved recipe (local or repo)
  --configure          edit the existing profile given by --dir
  --export <name>      save profile --dir as recipe <name> (local by default)
  --shared             with --export: save into the repo's recipes/ instead
  --list-recipes       list saved recipes and where they come from
  --forget <name>      delete a local recipe
`;

function parseCli() {
  try {
    return parseArgs({ args: process.argv.slice(2), options: cliOptions, strict: true, allowPositionals: false }).values;
  } catch (error) {
    throw new Error(`${error.message}\n\n${HELP}`);
  }
}

async function exportRecipe(profileName, recipeNameRaw, { shared = false } = {}) {
  const envFile = path.join(profilesRoot, profileName, 'profile.env');
  if (!(await exists(envFile))) throw new Error(`No such profile: ${profileName}`);
  const recipeName = sanitizeName(recipeNameRaw);
  const targetDir = shared ? sharedRecipesDir : localRecipesDir;
  const outPath = path.join(targetDir, `${recipeName}.env`);
  const replaced = await exists(outPath);
  const lines = [`# description: exported from profile "${profileName}" on ${new Date().toISOString().slice(0, 10)}`];
  for (const [key, value] of parseEnvFile(await readFile(envFile, 'utf8'))) {
    if (!instanceKeys.has(key)) lines.push(envLine(key, value));
  }
  await mkdir(targetDir, { recursive: true });
  await writeFile(outPath, `${lines.join('\n')}\n`);
  const setupSource = path.join(profilesRoot, profileName, 'setup.sh');
  const setupTarget = path.join(targetDir, `${recipeName}.setup.sh`);
  if (await exists(setupSource)) {
    await copyFile(setupSource, setupTarget);
  } else {
    await rm(setupTarget, { force: true });
  }
  const where = shared ? 'repo' : 'local';
  console.log(chalk.greenBright(`✓ Saved ${where} recipe "${recipeName}" to ${outPath}${replaced ? chalk.yellow(' (replaced the previous version)') : ''}`));
  if (!shared) {
    const repoCopy = path.join(sharedRecipesDir, `${recipeName}.env`);
    if (await exists(repoCopy)) console.log(chalk.dim(`  It overrides the repo recipe of the same name.`));
  }
  return recipeName;
}

async function forgetRecipe(nameRaw) {
  const name = sanitizeName(nameRaw);
  const envPath = path.join(localRecipesDir, `${name}.env`);
  if (!(await exists(envPath))) {
    const inRepo = await exists(path.join(sharedRecipesDir, `${name}.env`));
    throw new Error(inRepo
      ? `"${name}" is a shared repo recipe, not a local one. Remove recipes/${name}.env from the repo to delete it.`
      : `No local recipe named "${name}". See: just recipes`);
  }
  await rm(envPath, { force: true });
  await rm(path.join(localRecipesDir, `${name}.setup.sh`), { force: true });
  console.log(chalk.greenBright(`✓ Deleted local recipe "${name}"`));
  if (await exists(path.join(sharedRecipesDir, `${name}.env`))) {
    console.log(chalk.dim(`  The repo recipe "${name}" is visible again.`));
  }
}

async function listRecipes() {
  const recipes = await collectRecipes();
  if (!recipes.length) {
    console.log(chalk.dim('No recipes yet. Save one from an existing profile with: just save <profile> [name]'));
    return;
  }
  for (const entry of recipes) {
    const recipe = await loadRecipe(entry.file);
    const tools = [...recipe.defaults.selectedTools, ...recipe.defaults.extraApt.map((pkg) => `apt:${pkg}`)];
    const bits = [recipe.defaults.baseImage ?? 'ubuntu:24.04'];
    bits.push(tools.length ? tools.join(', ') : 'minimal');
    if (recipe.defaults.sshEnabled) bits.push('ssh');
    for (const [key, value] of recipe.extras.filter(([k]) => extraKeyPattern.test(k))) {
      bits.push(`${key}=${value}`);
    }
    if (recipe.setup) bits.push('setup.sh');
    const origin = entry.source === 'local'
      ? chalk.green(entry.overrides ? '[local, overrides repo]' : '[local]')
      : chalk.blue('[repo]');
    console.log(`${chalk.cyanBright.bold(entry.name)} ${origin}  ${chalk.dim(recipe.description)}`);
    console.log(`  ${chalk.dim(bits.join(' · '))}`);
    const unknown = [...recipe.extras.filter(([k]) => !extraKeyPattern.test(k)).map(([k]) => k), ...recipe.defaults.unknownTools.map((id) => `TOOLS:${id}`)];
    if (unknown.length) {
      console.log(`  ${chalk.yellow(`unrecognized key(s): ${unknown.join(', ')} — typo? (they are still written to profile.env)`)}`);
    }
  }
  console.log(chalk.dim('\nSpin one up: just up <recipe> [name] — or pick it as the starting point in `just new`.'));
  console.log(chalk.dim('Delete a local recipe: just forget-recipe <name>'));
}

async function suggestDotfiles() {
  const home = process.env.HOME ?? '';
  for (const candidate of ['dotfiles', '.dotfiles']) {
    if (await exists(path.join(home, candidate))) return path.join(home, candidate);
  }
  return '';
}

async function nextCommandPrefix() {
  return (await exists(path.join(process.env.HOME ?? '', '.local', 'bin', 'warp'))) ? 'warp' : 'just';
}

async function main() {
  const options = parseCli();

  if (options.help) {
    console.log(HELP);
    return;
  }

  if (options['list-recipes']) {
    await listRecipes();
    return;
  }

  if (options.forget) {
    await forgetRecipe(options.forget);
    return;
  }

  if (options.export) {
    const profileName = sanitizeName(options.dir ?? DEFAULT_PROFILE_NAME);
    const recipeName = await exportRecipe(profileName, options.export, { shared: Boolean(options.shared) });
    const cmd = await nextCommandPrefix();
    console.log(chalk.bold('\nSpin up a profile from it:'));
    console.log(chalk.cyan(`  ${cmd} up ${recipeName} <name>`));
    return;
  }

  if (options.configure && options.recipe) {
    throw new Error('Use either --configure or --recipe, not both.');
  }

  const defaults = {
    profileName: options.dir ?? DEFAULT_PROFILE_NAME,
    baseImage: 'ubuntu:24.04',
    appUid: '1001',
    cpus: '2',
    memory: '8G',
    dotfilesDir: '',
    suggestedDotfiles: await suggestDotfiles(),
    sshPubkey: path.join(process.env.HOME ?? '', '.ssh/id_ed25519.pub')
  };

  const existingEnv = path.join(profilesRoot, sanitizeName(defaults.profileName), 'profile.env');
  let existingValues;
  if (options.configure && !(await exists(existingEnv))) throw new Error(`No such profile: ${defaults.profileName}`);
  if (options.configure) {
    existingValues = Object.fromEntries(parseEnvFile(await readFile(existingEnv, 'utf8')));
    Object.assign(defaults, {
      profileName: existingValues.PROFILE_NAME,
      baseImage: existingValues.BASE_IMAGE,
      appUser: existingValues.APP_USER,
      appUid: existingValues.APP_UID,
      cpus: existingValues.CPUS,
      memory: existingValues.MEMORY,
      sshPort: existingValues.SSH_PORT,
      dotfilesDir: existingValues.DOTFILES_DIR,
      sshPubkey: existingValues.SSH_PUBKEY,
      sshEnabled: existingValues.INCLUDE_SSH === 'true',
      sshHostname: existingValues.SSH_HOSTNAME,
      t3codeServe: existingValues.T3CODE_SERVE === 'true',
      t3codePort: existingValues.T3CODE_PORT,
      t3codeAccess: existingValues.T3CODE_ACCESS,
      tailscaleTags: existingValues.TAILSCALE_TAGS,
      selectedIntegrations: integrationOptions.filter((option) => existingValues[option.value] === 'true').map((option) => option.value),
      selectedTools: toolsFromValues(existingValues),
      extraApt: extraAptFromValues(existingValues),
      unknownTools: unknownToolIds(existingValues)
    });
  }

  let recipeExtras = [];
  let recipeSetup = '';
  let startedFrom = '';
  if (options.recipe) {
    const resolved = await resolveRecipe(options.recipe);
    const recipe = await loadRecipe(resolved.file);
    if (!options.dir) defaults.profileName = sanitizeName(resolved.name);
    applyRecipeDefaults(defaults, recipe);
    recipeExtras = recipe.extras;
    recipeSetup = recipe.setup;
    startedFrom = `recipe ${resolved.name} (${SOURCE_LABELS[resolved.source]})`;
  }

  let config;
  const fromSaved = Boolean(options.configure || options.recipe);
  let interactive = false;

  if (options.yes) {
    const profileName = sanitizeName(defaults.profileName);
    const appUser = defaults.appUser ?? sanitizeUser(profileName);
    const t3codeServe = fromSaved ? (defaults.t3codeServe ?? false) : false;
    config = {
      profileName,
      containerName: containerNameFor(profileName),
      imageName: imageNameFor(profileName),
      workVolume: workVolumeFor(profileName),
      dockerVolume: dockerVolumeFor(profileName),
      sshPort: await allocateSshPort(profileName, defaults.sshPort),
      baseImage: defaults.baseImage,
      appUser,
      appUid: defaults.appUid,
      profilePrompt: appUser.toUpperCase(),
      cpus: defaults.cpus,
      memory: defaults.memory,
      dotfilesDir: fromSaved ? (defaults.dotfilesDir ?? '') : '',
      selectedIntegrations: fromSaved ? (defaults.selectedIntegrations ?? []) : [],
      sshEnabled: fromSaved ? (defaults.sshEnabled ?? false) : false,
      sshHostname: options.configure ? (defaults.sshHostname ?? '') : '',
      sshPubkey: fromSaved ? (defaults.sshPubkey ?? '') : '',
      t3codeServe,
      t3codePort: t3codeServe ? await allocateT3codePort(profileName, defaults.t3codePort) : '',
      t3codeAccess: t3codeServe ? (defaults.t3codeAccess ?? 'local') : 'local',
      tailscaleTags: defaults.tailscaleTags ?? DEFAULT_TAILSCALE_TAGS,
      selectedTools: withT3code(fromSaved ? (defaults.selectedTools ?? []) : [], t3codeServe, t3codeServe ? (defaults.t3codeAccess ?? 'local') : 'local'),
      extraApt: fromSaved ? (defaults.extraApt ?? []) : []
    };
  } else {
    interactive = true;
    config = await promptForProfile(defaults, { startedFrom, configuring: Boolean(options.configure) });
    recipeExtras = config.recipeExtras.length ? config.recipeExtras : recipeExtras;
    recipeSetup = config.recipeSetup || recipeSetup;
    summarize(config);
    if (options.configure && existingValues && config.profileName !== existingValues.PROFILE_NAME) {
      console.log(chalk.yellow(`Note: renaming creates a new profile "${config.profileName}" — the existing "${existingValues.PROFILE_NAME}" profile, container, and image are left untouched. Remove them with: just destroy ${existingValues.PROFILE_NAME}`));
    }
    const proceed = await confirm({ message: options.configure ? `Save settings for "${config.profileName}"?` : `Create profile "${config.profileName}"?`, default: true });
    if (!proceed) {
      console.log(chalk.dim('Cancelled.'));
      process.exit(0);
    }
  }

  await validateConfig(config);

  await mkdir(profilesRoot, { recursive: true });

  const profileDir = path.join(profilesRoot, config.profileName);

  if (await exists(profileDir)) {
    const overwrite = options.configure || await confirm({
      message: `Profile ${chalk.yellow(config.profileName)} already exists. Refresh its scripts and settings from the latest template?`,
      default: false
    });

    if (!overwrite) {
      console.error(chalk.red(`Profile directory already exists: ${profileDir}`));
      process.exit(1);
    }
  }

  // Re-copy the template files too, so template fixes reach existing profiles.
  await copyTemplateProfile(profileDir);
  if (recipeSetup) {
    await copyFile(recipeSetup, path.join(profileDir, 'setup.sh'));
  }
  await writeProfileEnv(profileDir, config, recipeExtras);

  const cmd = await nextCommandPrefix();
  console.log(chalk.greenBright(`\n✓ ${options.configure ? 'Updated' : 'Created'} profile "${config.profileName}" at ${profileDir}`));
  console.log(chalk.dim(`  Tools: ${describeTools(config.selectedTools, config.extraApt)}`));

  let savedRecipe = '';
  if (interactive && !options.configure) {
    if (await confirm({ message: 'Save this setup as a local recipe to reuse it later?', default: false })) {
      const recipeName = await input({ message: 'Recipe name', default: config.profileName });
      savedRecipe = await exportRecipe(config.profileName, recipeName);
    }
  }

  console.log(chalk.bold('\nNext step — build and enter it:'));
  console.log(chalk.cyan(`  ${cmd} open ${config.profileName}`));
  if (config.t3codeServe) {
    console.log(chalk.dim(`Then open T3 Code in your browser: ${cmd} t3 ${config.profileName}`));
    if (config.t3codeAccess === 'tailscale') {
      console.log(chalk.dim(`Inside the shell, run \`tailnet\` once to log the profile in to your tailnet; then: ${cmd} t3 ${config.profileName} qr`));
      console.log(chalk.dim('`tailnet` also waits for a Tailnet Lock signature if your tailnet needs one, and lets you pick an exit node at the end.'));
      if (config.tailscaleTags && config.tailscalePolicyPending !== false) {
        console.log(chalk.yellow('\nBefore logging in:'));
        printTailnetPolicy(config.tailscaleTags);
      }
    }
  }
  if (savedRecipe) {
    console.log(chalk.dim(`Later, make another one from the saved recipe: ${cmd} up ${savedRecipe} <name>`));
  }

  if (options.configure && existingValues && config.profileName === existingValues.PROFILE_NAME) {
    const changed = (entries) => Object.entries(entries).some(([key, value]) => existingValues[key] !== value);
    const needsImageRebuild = changed({
      BASE_IMAGE: config.baseImage,
      APP_USER: config.appUser,
      APP_UID: config.appUid,
      INCLUDE_SSH: config.sshEnabled ? 'true' : 'false'
    }) || toolsFromValues(existingValues).join(' ') !== config.selectedTools.join(' ')
      || extraAptFromValues(existingValues).join(' ') !== (config.extraApt ?? []).join(' ');
    const needsRecreate = changed({
      CPUS: config.cpus,
      MEMORY: config.memory,
      DOTFILES_DIR: config.dotfilesDir,
      SSH_PORT: config.sshPort,
      T3CODE_SERVE: config.t3codeServe ? 'true' : 'false',
      T3CODE_PORT: config.t3codePort ?? '',
      T3CODE_ACCESS: config.t3codeServe ? (config.t3codeAccess ?? 'local') : 'local',
      TAILSCALE_TAGS: config.tailscaleTags ?? DEFAULT_TAILSCALE_TAGS
    });
    if (needsImageRebuild) {
      if (await confirm({ message: 'These changes require an image rebuild. Rebuild now?', default: false })) {
        execFileSync(path.join(profileDir, 'rebuild.sh'), [], { stdio: 'inherit' });
      }
    } else if (needsRecreate) {
      if (await confirm({ message: 'These changes only require recreating the container (no image rebuild). Recreate now?', default: false })) {
        execFileSync(path.join(profileDir, 'rebuild.sh'), ['--skip-build'], { stdio: 'inherit' });
      }
    } else {
      const runtimeChanged = changed({
        SSH_HOSTNAME: config.sshHostname,
        SSH_PUBKEY: config.sshPubkey,
        ...Object.fromEntries(integrationOptions.map((opt) => [opt.value, config.selectedIntegrations.includes(opt.value) ? 'true' : 'false']))
      });
      if (runtimeChanged) {
        console.log(chalk.dim(`Settings saved — they take effect on the next \`just open ${config.profileName}\`.`));
      }
    }
  }
}

main().catch((error) => {
  console.error(chalk.red(error instanceof Error ? error.message : String(error)));
  process.exit(1);
});
