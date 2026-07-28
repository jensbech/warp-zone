#!/usr/bin/env node

import { access, chmod, copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
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
const profilesRoot = path.join(process.env.HOME ?? '', 'container');

// Neutral, minimal default — a fresh Linux box with just the essentials.
const DEFAULT_PROFILE_NAME = 'dev';
const ALWAYS_INCLUDED = 'git, ripgrep, jq, fzf, bat, eza, tmux, zsh';

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
  { name: 'Docker CLI + Compose', value: 'INCLUDE_DOCKER', group: 'Cloud & infrastructure' },
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
  { name: 'Node web app', value: 'node', tools: ['INCLUDE_NODE', 'INCLUDE_GH', 'INCLUDE_DOCKER', 'INCLUDE_POSTGRES_CLIENT'] },
  { name: 'Python data', value: 'python', tools: ['INCLUDE_PYTHON', 'INCLUDE_SQLITE', 'INCLUDE_HTTPIE'] },
  { name: 'Cloud and Kubernetes', value: 'cloud', tools: ['INCLUDE_KUBECTL', 'INCLUDE_HELM', 'INCLUDE_K9S', 'INCLUDE_TERRAFORM', 'INCLUDE_PULUMI', 'INCLUDE_AZURE_CLI'] },
  { name: '.NET', value: 'dotnet', tools: ['INCLUDE_DOTNET', 'INCLUDE_DOCKER'] },
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

function envLine(key, value) {
  return `${key}=${JSON.stringify(value)}`;
}

async function exists(targetPath) {
  try {
    await access(targetPath, constants.F_OK);
    return true;
  } catch {
    return false;
  }
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
  if (!commandExists('container')) errors.push('Apple\'s container CLI is not installed or not on PATH.');
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
    'Containerfile',
    'bootstrap-home',
    'build.sh',
    'open.sh',
    'rebuild.sh',
    'ssh.sh',
    'README.md'
  ];

  for (const file of files) {
    await copyFile(path.join(templateDir, file), path.join(profileDir, file));
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
  console.log(`  ${label('SSH')}${config.sshEnabled ? `ssh ${config.sshHostname || config.profileName}  ${chalk.dim(`(key: ${config.sshPubkey})`)}` : chalk.dim('disabled')}`);
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

  const preset = await select({
    message: 'Starting point',
    choices: presets.map(({ name, value }) => ({ name, value })),
    default: defaults.preset
  });

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
  const presetTools = presets.find((option) => option.value === preset)?.tools ?? [];
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
  const customize = await confirm({
    message: 'Customize advanced settings (Linux user, CPU, memory)?',
    default: false
  });

  let appUser = defaults.appUser;
  let appUid = defaults.appUid;
  const containerName = profileName;
  const imageName = `${profileName}:latest`;
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

  if (customize) {
    appUser = await input({ message: 'Your username inside the container', default: appUser });
    appUid = await input({ message: 'Linux uid for that user', default: appUid });
    cpus = await input({ message: 'CPUs ("max" = all host cores)', default: cpus });
    memory = await input({ message: 'Memory ("max" = all host RAM)', default: memory });
  }

  if (!validResources(cpus, memory)) throw new Error('CPU must be a positive number or "max"; memory must be like "8G", "512M", or "max".');

  return {
    profileName,
    containerName,
    imageName,
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
    selectedTools
  };
}

async function writeProfileEnv(profileDir, config) {
  const enabledTools = new Set(config.selectedTools);
  const enabledIntegrations = new Set(config.selectedIntegrations);
  const lines = [
    envLine('PROFILE_NAME', config.profileName),
    envLine('CONTAINER_NAME', config.containerName),
    envLine('IMAGE_NAME', config.imageName),
    envLine('BASE_IMAGE', config.baseImage),
    envLine('APP_USER', config.appUser),
    envLine('APP_UID', config.appUid),
    envLine('PROFILE_PROMPT', config.profilePrompt),
    envLine('CPUS', config.cpus),
    envLine('MEMORY', config.memory),
    // Empty DOTFILES_DIR means hermetic: no host mount, no dotfiles pulled in.
    envLine('DOTFILES_DIR', config.dotfilesDir),
    // SSH access: install/enable flag, host alias, and the host public key to authorize.
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

  await writeFile(path.join(profileDir, 'profile.env'), `${lines.join('\n')}\n`);
}

async function main() {
  const program = new Command();

  program
    .name('warp-zone')
    .description('Create a reusable, minimal Linux dev-environment profile')
    .option('--dir <name>', 'profile directory name')
    .option('--yes', 'accept defaults where possible')
    .option('--configure', 'edit an existing profile')
    .parse(process.argv);

  const options = program.opts();
  const defaults = {
    profileName: options.dir ?? DEFAULT_PROFILE_NAME,
    baseImage: 'ubuntu:24.04',
    appUser: 'dev',
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
    const lines = (await readFile(existingEnv, 'utf8')).trim().split('\n');
    existingValues = Object.fromEntries(lines.map((line) => {
      const index = line.indexOf('=');
      return [line.slice(0, index), JSON.parse(line.slice(index + 1))];
    }));
    Object.assign(defaults, {
      profileName: existingValues.PROFILE_NAME,
      baseImage: existingValues.BASE_IMAGE,
      appUser: existingValues.APP_USER,
      appUid: existingValues.APP_UID,
      cpus: existingValues.CPUS,
      memory: existingValues.MEMORY,
      dotfilesDir: existingValues.DOTFILES_DIR,
      sshPubkey: existingValues.SSH_PUBKEY,
      sshEnabled: existingValues.INCLUDE_SSH === 'true',
      sshHostname: existingValues.SSH_HOSTNAME,
      selectedIntegrations: integrationOptions.filter((option) => existingValues[option.value] === 'true').map((option) => option.value),
      selectedTools: toolOptions.filter((tool) => existingValues[tool.value] === 'true').map((tool) => tool.value)
    });
  }

  let config;

  if (options.yes) {
    const profileName = sanitizeName(defaults.profileName);
    config = {
      profileName,
      containerName: profileName,
      imageName: `${profileName}:latest`,
      baseImage: defaults.baseImage,
      appUser: defaults.appUser,
      appUid: defaults.appUid,
      profilePrompt: defaults.appUser.toUpperCase(),
      cpus: defaults.cpus,
      memory: defaults.memory,
      // Minimal and hermetic by default — opt into tools and host dotfiles via the wizard.
      dotfilesDir: '',
      selectedIntegrations: [],
      sshEnabled: false,
      sshHostname: '',
      sshPubkey: '',
      selectedTools: []
    };
  } else {
    config = await promptForProfile(defaults);
    summarize(config);
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
    const overwrite = await confirm({
      message: `Profile ${chalk.yellow(config.profileName)} already exists. Refresh its scripts and settings from the latest template?`,
      default: false
    });

    if (!overwrite) {
      console.error(chalk.red(`Profile directory already exists: ${profileDir}`));
      process.exit(1);
    }

    // Re-copy the template files too, so template fixes reach existing profiles.
    await copyTemplateProfile(profileDir);
    await writeProfileEnv(profileDir, config);
  } else {
    await copyTemplateProfile(profileDir);
    await writeProfileEnv(profileDir, config);
  }

  console.log(chalk.greenBright(`\n✓ Created profile "${config.profileName}" at ${profileDir}`));
  console.log(chalk.dim(`  Tools: ${describeTools(config.selectedTools)}`));
  console.log(chalk.bold('\nNext step — build and enter it:'));
  const openCmd = config.profileName === DEFAULT_PROFILE_NAME ? 'just open' : `just open ${config.profileName}`;
  console.log(chalk.cyan(`  ${openCmd}`));

  if (options.configure && existingValues) {
    const needsRebuild = Object.entries({
      BASE_IMAGE: config.baseImage,
      APP_USER: config.appUser,
      APP_UID: config.appUid,
      CPUS: config.cpus,
      MEMORY: config.memory,
      DOTFILES_DIR: config.dotfilesDir,
      INCLUDE_SSH: config.sshEnabled ? 'true' : 'false',
      ...Object.fromEntries(toolOptions.map((tool) => [tool.value, config.selectedTools.includes(tool.value) ? 'true' : 'false']))
    }).some(([key, value]) => existingValues[key] !== value);
    if (needsRebuild && await confirm({ message: 'These changes require a rebuild. Rebuild now?', default: false })) {
      execFileSync(path.join(profileDir, 'rebuild.sh'), { stdio: 'inherit' });
    }
  }
}

main().catch((error) => {
  console.error(chalk.red(error instanceof Error ? error.message : String(error)));
  process.exit(1);
});
