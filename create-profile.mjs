#!/usr/bin/env node

import { access, chmod, copyFile, mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
import net from 'node:net';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { constants } from 'node:fs';
import process from 'node:process';
import { Command } from 'commander';
import chalk from 'chalk';
import { input, checkbox, confirm, select, Separator } from '@inquirer/prompts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const templateDir = path.join(__dirname, 'template');
const profilesRoot = path.join(process.env.HOME ?? '', 'warp');

// Docker's namespace is global to the daemon, so every warp-zone resource is
// prefixed and labelled — a profile named "dev" must not collide with whatever
// else happens to be called "dev" on this machine.
const RESOURCE_PREFIX = 'warp-';
const FIRST_SSH_PORT = 2200;

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

const toolOptions = [
  // Languages & runtimes
  { name: 'Node.js, corepack, pnpm, yarn', value: 'INCLUDE_NODE', group: 'Languages & runtimes' },
  { name: 'Python 3 (pip, venv)', value: 'INCLUDE_PYTHON', group: 'Languages & runtimes' },
  { name: 'Go', value: 'INCLUDE_GO', group: 'Languages & runtimes' },
  { name: 'Rust (rustup, cargo)', value: 'INCLUDE_RUST', group: 'Languages & runtimes' },
  { name: '.NET SDK 8 and 10', value: 'INCLUDE_DOTNET', group: 'Languages & runtimes' },
  { name: 'Java (default JDK)', value: 'INCLUDE_JAVA', group: 'Languages & runtimes' },
  { name: 'Ruby', value: 'INCLUDE_RUBY', group: 'Languages & runtimes' },
  { name: 'Bun', value: 'INCLUDE_BUN', group: 'Languages & runtimes' },
  { name: 'Deno', value: 'INCLUDE_DENO', group: 'Languages & runtimes' },
  // Cloud & infrastructure
  { name: 'kubectl', value: 'INCLUDE_KUBECTL', group: 'Cloud & infrastructure' },
  { name: 'Helm', value: 'INCLUDE_HELM', group: 'Cloud & infrastructure' },
  { name: 'k9s', value: 'INCLUDE_K9S', group: 'Cloud & infrastructure' },
  { name: 'Terraform', value: 'INCLUDE_TERRAFORM', group: 'Cloud & infrastructure' },
  { name: 'Pulumi CLI', value: 'INCLUDE_PULUMI', group: 'Cloud & infrastructure' },
  { name: 'AWS CLI v2', value: 'INCLUDE_AWS_CLI', group: 'Cloud & infrastructure' },
  { name: 'Azure CLI', value: 'INCLUDE_AZURE_CLI', group: 'Cloud & infrastructure' },
  { name: 'Google Cloud CLI', value: 'INCLUDE_GCLOUD', group: 'Cloud & infrastructure' },
  // Databases
  { name: 'PostgreSQL client (psql)', value: 'INCLUDE_POSTGRES_CLIENT', group: 'Databases' },
  { name: 'MySQL / MariaDB client', value: 'INCLUDE_MYSQL_CLIENT', group: 'Databases' },
  { name: 'Redis CLI', value: 'INCLUDE_REDIS', group: 'Databases' },
  { name: 'SQLite', value: 'INCLUDE_SQLITE', group: 'Databases' },
  // CLI utilities
  { name: 'GitHub CLI', value: 'INCLUDE_GH', group: 'CLI utilities' },
  { name: 'jira CLI', value: 'INCLUDE_JIRA', group: 'CLI utilities' },
  { name: 'Neovim', value: 'INCLUDE_NEOVIM', group: 'CLI utilities' },
  { name: 'lazygit', value: 'INCLUDE_LAZYGIT', group: 'CLI utilities' },
  { name: 'git-delta', value: 'INCLUDE_DELTA', group: 'CLI utilities' },
  { name: 'yq', value: 'INCLUDE_YQ', group: 'CLI utilities' },
  { name: 'direnv', value: 'INCLUDE_DIRENV', group: 'CLI utilities' },
  { name: 'HTTPie', value: 'INCLUDE_HTTPIE', group: 'CLI utilities' },
  { name: 'btop', value: 'INCLUDE_BTOP', group: 'CLI utilities' }
];

const presets = [
  { name: 'Minimal', value: 'minimal', tools: [] },
  { name: 'Node web app', value: 'node', tools: ['INCLUDE_NODE', 'INCLUDE_GH', 'INCLUDE_POSTGRES_CLIENT'] },
  { name: 'Python data', value: 'python', tools: ['INCLUDE_PYTHON', 'INCLUDE_SQLITE', 'INCLUDE_HTTPIE'] },
  { name: 'Cloud and Kubernetes', value: 'cloud', tools: ['INCLUDE_KUBECTL', 'INCLUDE_HELM', 'INCLUDE_K9S', 'INCLUDE_TERRAFORM', 'INCLUDE_PULUMI', 'INCLUDE_AZURE_CLI'] },
  { name: '.NET', value: 'dotnet', tools: ['INCLUDE_DOTNET'] },
  { name: 'Custom', value: 'custom', tools: [] }
];

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

const recipesDir = path.join(__dirname, 'recipes');

function recipePath(name) {
  if (name.includes('/') || name.endsWith('.env')) return path.resolve(name);
  return path.join(recipesDir, `${name}.env`);
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
  'SSH_PUBKEY'
]);

function structuredKeys() {
  return new Set([
    ...instanceKeys,
    'BASE_IMAGE',
    'CPUS',
    'MEMORY',
    'DOTFILES_DIR',
    'DOCKERD_ARGS',
    'INCLUDE_SSH',
    ...integrationOptions.map((option) => option.value),
    ...toolOptions.map((tool) => tool.value)
  ]);
}

const extraKeyPattern = /^(NODE_MAJOR|EXTRA_APT_PACKAGES|BACKUP_KEEP)$|_VERSION$/;

async function listRecipeFiles() {
  try {
    return (await readdir(recipesDir)).filter((file) => file.endsWith('.env')).sort()
      .map((file) => path.join(recipesDir, file));
  } catch {
    return [];
  }
}

async function loadRecipe(rp) {
  if (!(await exists(rp))) throw new Error(`No such recipe: ${rp}`);
  const entries = parseEnvFile(await readFile(rp, 'utf8'));
  const values = Object.fromEntries(entries);
  const known = structuredKeys();
  const setupCandidate = rp.replace(/\.env$/, '.setup.sh');
  return {
    values,
    defaults: {
      baseImage: values.BASE_IMAGE,
      cpus: values.CPUS,
      memory: values.MEMORY,
      dotfilesDir: values.DOTFILES_DIR ?? '',
      sshEnabled: values.INCLUDE_SSH === 'true',
      selectedIntegrations: integrationOptions.filter((option) => values[option.value] === 'true').map((option) => option.value),
      selectedTools: toolOptions.filter((tool) => values[tool.value] === 'true').map((tool) => tool.value)
    },
    extras: entries.filter(([key]) => !known.has(key)),
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

async function claimedSshPorts(exceptProfile) {
  const claimed = new Set();
  let entries = [];
  try {
    entries = await readdir(profilesRoot, { withFileTypes: true });
  } catch {
    return claimed;
  }
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name === exceptProfile) continue;
    try {
      const values = Object.fromEntries(parseEnvFile(await readFile(path.join(profilesRoot, entry.name, 'profile.env'), 'utf8')));
      if (values.SSH_PORT) claimed.add(Number(values.SSH_PORT));
    } catch {}
  }
  return claimed;
}

async function allocateSshPort(profileName, existing) {
  const claimed = await claimedSshPorts(profileName);
  if (existing && !claimed.has(Number(existing))) return String(existing);
  for (let port = FIRST_SSH_PORT; port < FIRST_SSH_PORT + 500; port += 1) {
    if (claimed.has(port)) continue;
    if (await portIsFree(port)) return String(port);
  }
  throw new Error(`No free port found between ${FIRST_SSH_PORT} and ${FIRST_SSH_PORT + 500}.`);
}

function commandExists(command) {
  try {
    execFileSync('which', [command], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

function validResources(cpus, memory) {
  return /^(max|[1-9][0-9]*)$/.test(cpus) && /^(max|[1-9][0-9]*[GM])$/.test(memory);
}

async function validateConfig(config) {
  const errors = [];
  const warnings = [];
  if (!commandExists('docker')) {
    errors.push('docker is not installed or not on PATH — https://docs.docker.com/desktop/setup/install/mac-install/');
  } else {
    try {
      execFileSync('docker', ['info'], { stdio: 'ignore' });
    } catch {
      errors.push('Cannot reach the Docker daemon. Start Docker Desktop (or your Docker runtime) and try again.');
    }
  }
  if (!commandExists('just')) errors.push('just is not installed or not on PATH.');
  if (!validResources(config.cpus, config.memory)) errors.push('CPU must be a positive number or "max"; memory must be like "8G", "512M", or "max".');
  if (config.dotfilesDir && !(await exists(config.dotfilesDir))) errors.push(`Dotfiles directory does not exist: ${config.dotfilesDir}`);
  if (config.sshEnabled && config.sshPubkey && !(await exists(config.sshPubkey))) warnings.push(`SSH public key was not found: ${config.sshPubkey}. Existing ~/.ssh/*.pub keys will be tried when opening.`);
  try {
    const availableKb = Number(execFileSync('df', ['-k', process.env.HOME ?? '/'], { encoding: 'utf8' }).trim().split('\n').at(-1).trim().split(/\s+/)[3]);
    if (availableKb < 50 * 1024 * 1024) warnings.push(`Only ${(availableKb / 1024 / 1024).toFixed(1)} GB free on the profile disk; 50 GB or more is recommended.`);
  } catch {}
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
    'bootstrap-home',
    'warp-init',
    'build.sh',
    'open.sh',
    'rebuild.sh',
    'ssh.sh',
    'README.md'
  ];

  for (const file of files) {
    await copyFile(path.join(templateDir, file), path.join(profileDir, file));
  }
  for (const file of ['bootstrap-home', 'warp-init', 'build.sh', 'open.sh', 'rebuild.sh', 'ssh.sh']) {
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
    await copyFile(path.join(__dirname, 'lib', file), path.join(profileDir, 'lib', file));
    await chmod(path.join(profileDir, 'lib', file), 0o755);
  }
}

const LABEL_WIDTH = 10;

function describeTools(selectedTools) {
  if (selectedTools.length === 0) {
    return chalk.dim('none — minimal base');
  }
  return selectedTools
    .map((value) => toolOptions.find((tool) => tool.value === value)?.name ?? value)
    .join(', ');
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
  console.log(`  ${label('Distro')}${distro}`);
  console.log(`  ${label('User')}${config.appUser}`);
  console.log(`  ${label('CPU/RAM')}${config.cpus} / ${config.memory}`);
  console.log(`  ${label('Tools')}${describeTools(config.selectedTools)}`);
  console.log(`  ${label('Dotfiles')}${describeDotfiles(config)}`);
  console.log(`  ${label('SSH')}${config.sshEnabled ? `ssh ${config.sshHostname || config.profileName}  ${chalk.dim(`(127.0.0.1:${config.sshPort}, key: ${config.sshPubkey})`)}` : chalk.dim(`disabled (port ${config.sshPort} reserved)`)}`);
  console.log(`  ${label('Docker')}${chalk.dim('engine inside the profile (docker-in-docker), state on volume ' + config.dockerVolume)}`);
  if (config.recipeExtras?.length) {
    console.log(`  ${label('Extras')}${config.recipeExtras.map(([key, value]) => `${key}=${value}`).join(', ')}`);
  }
  if (config.recipeSetup) {
    console.log(`  ${label('Setup')}${config.recipeSetup}`);
  }
  console.log();
}

async function promptForProfile(defaults) {
  console.log(chalk.cyanBright.bold('\n🌀 warp-zone — new profile'));
  console.log(chalk.dim('Build a reusable Linux dev world with your preferred distro and tools.'));
  console.log(chalk.dim(`Profiles are saved in ${profilesRoot}\n`));

  // Essentials — most profiles only need these two answers.
  const profileNameRaw = await input({
    message: 'Profile name',
    default: defaults.profileName
  });
  const profileName = sanitizeName(profileNameRaw);

  const recipeFiles = await listRecipeFiles();
  const startChoices = presets.map(({ name, value }) => ({ name, value }));
  if (recipeFiles.length) {
    startChoices.push(new Separator(chalk.dim('— Saved recipes —')));
    for (const file of recipeFiles) {
      startChoices.push({ name: path.basename(file, '.env'), value: `recipe:${file}` });
    }
  }
  const preset = await select({
    message: 'Starting point',
    choices: startChoices,
    default: defaults.preset
  });

  let fromRecipe = false;
  let recipeExtras = [];
  let recipeSetup = '';
  let presetTools = presets.find((option) => option.value === preset)?.tools ?? [];
  if (preset.startsWith('recipe:')) {
    const recipe = await loadRecipe(preset.slice('recipe:'.length));
    applyRecipeDefaults(defaults, recipe);
    fromRecipe = true;
    presetTools = recipe.defaults.selectedTools;
    recipeExtras = recipe.extras;
    recipeSetup = recipe.setup;
  }

  const baseImage = await select({
    message: 'Base distro',
    choices: distroOptions,
    default: defaults.baseImage
  });

  console.log(chalk.dim(`\n  Every profile already ships with: ${ALWAYS_INCLUDED}.`));
  const toolChoices = [];
  for (const group of [...new Set(toolOptions.map((tool) => tool.group))]) {
    toolChoices.push(new Separator(chalk.dim(`— ${group} —`)));
    for (const tool of toolOptions.filter((tool) => tool.group === group)) {
      toolChoices.push({ name: tool.name, value: tool.value, checked: false });
    }
  }
  const selectedTools = await checkbox({
    message: 'Optional tools (space to toggle)',
    choices: toolChoices.map((choice) => choice instanceof Separator ? choice : { ...choice, checked: defaults.selectedTools?.includes(choice.value) || presetTools.includes(choice.value) }),
    pageSize: 18,
    required: false,
    loop: false
  });

  // SSH access — a first-class question so it is always discoverable.
  console.log(
    chalk.dim('\n  Reach this profile from your Mac with `ssh <alias>` (e.g. VS Code Remote-SSH).')
  );
  const sshEnabled = await confirm({
    message: 'Enable SSH access into this profile?',
    default: defaults.sshEnabled ?? false
  });

  let sshHostname = '';
  let sshPubkey = '';
  if (sshEnabled) {
    sshHostname = await input({
      message: 'SSH host alias (what you type as `ssh <alias>` on your Mac)',
      default: defaults.sshHostname || profileName
    });
    sshPubkey = await input({
      message: 'Public key to authorize (a path on your Mac)',
      default: defaults.sshPubkey
    });
  }

  // Host integration — off by default, so a fresh profile is hermetic.
  console.log(
    chalk.dim('\n  By default a profile is sealed off from the host. Optionally mount your')
  );
  console.log(chalk.dim('  dotfiles read-only to bring in git identity and AI-assistant configs.'));
  const useDotfiles = await confirm({
    message: 'Link host dotfiles into this profile?',
    default: Boolean(defaults.dotfilesDir)
  });

  let dotfilesDir = '';
  let selectedIntegrations = [];
  if (useDotfiles) {
    dotfilesDir = await input({
      message: 'Dotfiles directory (mounted read-only at /mnt/dotfiles)',
      default: defaults.dotfilesDir
    });
    selectedIntegrations = await checkbox({
      message: 'What to link from your dotfiles (space to toggle)',
      choices: integrationOptions.map((opt) => ({ ...opt, checked: defaults.selectedIntegrations?.includes(opt.value) ?? true })),
      pageSize: integrationOptions.length,
      required: false
    });
  }

  // Advanced — everything here has a sensible default derived from the name, so
  // most profiles skip it entirely. The container and image names always follow
  // the profile name; they are not asked.
  let appUser = defaults.appUser ?? sanitizeUser(profileName);
  let appUid = defaults.appUid;
  const containerName = containerNameFor(profileName);
  const imageName = imageNameFor(profileName);
  const workVolume = workVolumeFor(profileName);
  const dockerVolume = dockerVolumeFor(profileName);
  const sshPort = await allocateSshPort(profileName, defaults.sshPort);
  let cpus = defaults.cpus;
  let memory = defaults.memory;

  const useAllResources = await confirm({
    message: 'Use all available CPU and memory?',
    default: cpus === 'max' && memory === 'max'
  });
  if (useAllResources) {
    cpus = 'max';
    memory = 'max';
  }

  const customize = await confirm({
    message: 'Customize advanced settings (Linux user, CPU, memory)?',
    default: false
  });

  if (customize) {
    appUser = sanitizeUser(await input({ message: 'Your username inside the container', default: appUser }));
    appUid = await input({ message: 'Linux uid for that user', default: appUid });
    cpus = await input({ message: 'CPUs ("max" = all host cores)', default: cpus });
    memory = await input({ message: 'Memory ("max" = all host RAM)', default: memory });
  }

  if (!validResources(cpus, memory)) throw new Error('CPU must be a positive number or "max"; memory must be like "8G", "512M", or "max".');

  return {
    profileName,
    containerName,
    imageName,
    workVolume,
    dockerVolume,
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
    selectedTools,
    fromRecipe,
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
    envLine('SSH_PUBKEY', config.sshPubkey)
  ];

  for (const integration of integrationOptions) {
    lines.push(envLine(integration.value, enabledIntegrations.has(integration.value) ? 'true' : 'false'));
  }

  for (const tool of toolOptions) {
    lines.push(envLine(tool.value, enabledTools.has(tool.value) ? 'true' : 'false'));
  }

  const knownKeys = new Set(lines.map((line) => line.slice(0, line.indexOf('='))));
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

async function main() {
  const program = new Command();

  program
    .name('warp-zone')
    .description('Create a reusable, minimal Linux dev-environment profile')
    .option('--dir <name>', 'profile directory name')
    .option('--yes', 'accept defaults where possible')
    .option('--configure', 'edit an existing profile')
    .option('--recipe <name>', 'create the profile from a saved recipe')
    .option('--export <name>', 'save a profile\'s setup as a recipe')
    .option('--list-recipes', 'list saved recipes')
    .parse(process.argv);

  const options = program.opts();

  if (options.listRecipes) {
    const files = await listRecipeFiles();
    if (!files.length) {
      console.log(chalk.dim('No recipes yet. Save one from an existing profile with: just save <profile> [name]'));
      return;
    }
    for (const file of files) {
      const name = path.basename(file, '.env');
      const content = await readFile(file, 'utf8');
      const recipe = await loadRecipe(file);
      const description = content.match(/^# description: (.*)$/m)?.[1] ?? '';
      const tools = recipe.defaults.selectedTools.map((value) => value.replace('INCLUDE_', '').toLowerCase());
      const bits = [recipe.defaults.baseImage ?? 'ubuntu:24.04'];
      bits.push(tools.length ? tools.join(', ') : 'minimal');
      if (recipe.defaults.sshEnabled) bits.push('ssh');
      for (const [key, value] of recipe.extras.filter(([k]) => extraKeyPattern.test(k))) {
        bits.push(`${key}=${value}`);
      }
      if (recipe.setup) bits.push('setup.sh');
      console.log(`${chalk.cyanBright.bold(name)}  ${chalk.dim(description)}`);
      console.log(`  ${chalk.dim(bits.join(' · '))}`);
      const unknown = recipe.extras.filter(([k]) => !extraKeyPattern.test(k)).map(([k]) => k);
      if (unknown.length) {
        console.log(`  ${chalk.yellow(`unrecognized key(s): ${unknown.join(', ')} — typo? (they are still written to profile.env)`)}`);
      }
    }
    console.log(chalk.dim('\nSpin one up: just up <recipe> [name] — or pick it as the starting point in `just new`.'));
    return;
  }

  if (options.export) {
    const profileName = sanitizeName(options.dir ?? DEFAULT_PROFILE_NAME);
    const envFile = path.join(profilesRoot, profileName, 'profile.env');
    if (!(await exists(envFile))) throw new Error(`No such profile: ${profileName}`);
    const recipeName = sanitizeName(options.export);
    const outPath = path.join(recipesDir, `${recipeName}.env`);
    const replaced = await exists(outPath);
    const lines = [`# description: exported from profile "${profileName}" on ${new Date().toISOString().slice(0, 10)}`];
    for (const [key, value] of parseEnvFile(await readFile(envFile, 'utf8'))) {
      if (!instanceKeys.has(key)) lines.push(envLine(key, value));
    }
    await mkdir(recipesDir, { recursive: true });
    await writeFile(outPath, `${lines.join('\n')}\n`);
    const setupSource = path.join(profilesRoot, profileName, 'setup.sh');
    if (await exists(setupSource)) {
      await copyFile(setupSource, path.join(recipesDir, `${recipeName}.setup.sh`));
    }
    console.log(chalk.greenBright(`✓ Saved recipe "${recipeName}" to ${outPath}${replaced ? chalk.yellow(' (replaced the previous version)') : ''}`));
    console.log(chalk.bold('\nSpin up a profile from it:'));
    console.log(chalk.cyan(`  just up ${recipeName} <name>`));
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
    dotfilesDir: path.join(process.env.HOME ?? '', 'proj/pers/dotfiles'),
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
      selectedIntegrations: integrationOptions.filter((option) => existingValues[option.value] === 'true').map((option) => option.value),
      selectedTools: toolOptions.filter((tool) => existingValues[tool.value] === 'true').map((tool) => tool.value)
    });
  }

  let recipeExtras = [];
  let recipeSetup = '';
  if (options.recipe) {
    const rp = recipePath(options.recipe);
    if (!(await exists(rp))) throw new Error(`No such recipe: ${options.recipe} (looked for ${rp})`);
    const recipe = await loadRecipe(rp);
    if (!options.dir) defaults.profileName = sanitizeName(path.basename(rp, '.env'));
    applyRecipeDefaults(defaults, recipe);
    recipeExtras = recipe.extras;
    recipeSetup = recipe.setup;
  }

  let config;
  const fromSaved = Boolean(options.configure || options.recipe);

  if (options.yes) {
    const profileName = sanitizeName(defaults.profileName);
    const appUser = defaults.appUser ?? sanitizeUser(profileName);
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
      // Minimal and hermetic by default — opt into tools and host dotfiles via the wizard.
      dotfilesDir: fromSaved ? (defaults.dotfilesDir ?? '') : '',
      selectedIntegrations: fromSaved ? (defaults.selectedIntegrations ?? []) : [],
      sshEnabled: fromSaved ? (defaults.sshEnabled ?? false) : false,
      sshHostname: options.configure ? (defaults.sshHostname ?? '') : '',
      sshPubkey: fromSaved ? (defaults.sshPubkey ?? '') : '',
      selectedTools: fromSaved ? (defaults.selectedTools ?? []) : []
    };
  } else {
    config = await promptForProfile(defaults);
    if (config.fromRecipe) {
      recipeExtras = config.recipeExtras;
      recipeSetup = config.recipeSetup;
    }
    summarize(config);
    if (options.configure && existingValues && config.profileName !== existingValues.PROFILE_NAME) {
      console.log(chalk.yellow(`Note: renaming creates a new profile "${config.profileName}" — the existing "${existingValues.PROFILE_NAME}" profile, container, and image are left untouched. Remove them with: just destroy ${existingValues.PROFILE_NAME}`));
    }
    const proceed = await confirm({ message: `Create profile "${config.profileName}"?`, default: true });
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

  console.log(chalk.greenBright(`\n✓ Created profile "${config.profileName}" at ${profileDir}`));
  console.log(chalk.dim(`  Tools: ${describeTools(config.selectedTools)}`));
  console.log(chalk.bold('\nNext step — build and enter it:'));
  const openCmd = config.profileName === DEFAULT_PROFILE_NAME ? 'just open' : `just open ${config.profileName}`;
  console.log(chalk.cyan(`  ${openCmd}`));

  if (options.configure && existingValues && config.profileName === existingValues.PROFILE_NAME) {
    const changed = (entries) => Object.entries(entries).some(([key, value]) => existingValues[key] !== value);
    const needsImageRebuild = changed({
      BASE_IMAGE: config.baseImage,
      APP_USER: config.appUser,
      APP_UID: config.appUid,
      INCLUDE_SSH: config.sshEnabled ? 'true' : 'false',
      ...Object.fromEntries(toolOptions.map((tool) => [tool.value, config.selectedTools.includes(tool.value) ? 'true' : 'false']))
    });
    const needsRecreate = changed({
      CPUS: config.cpus,
      MEMORY: config.memory,
      DOTFILES_DIR: config.dotfilesDir,
      SSH_PORT: config.sshPort
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
