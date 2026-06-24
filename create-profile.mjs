#!/usr/bin/env node

import { access, copyFile, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { constants } from 'node:fs';
import process from 'node:process';
import { Command } from 'commander';
import chalk from 'chalk';
import { input, checkbox, confirm, select, Separator } from '@inquirer/prompts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const templateDir = path.join(__dirname, 'work-ubuntu');
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

async function copyTemplateProfile(profileDir) {
  await mkdir(profileDir, { recursive: true });
  await mkdir(path.join(profileDir, 'templates'), { recursive: true });

  const files = [
    'Containerfile',
    'bootstrap-work-ubuntu-home',
    'build.sh',
    'open.sh',
    'rebuild.sh',
    'README.md'
  ];

  for (const file of files) {
    await copyFile(path.join(templateDir, file), path.join(profileDir, file));
  }

  const templateFiles = ['.bashrc', '.zshenv', '.zshrc'];
  for (const file of templateFiles) {
    await copyFile(path.join(templateDir, 'templates', file), path.join(profileDir, 'templates', file));
  }
}

function describeTools(selectedTools) {
  if (selectedTools.length === 0) {
    return chalk.dim('none — minimal base');
  }
  return selectedTools
    .map((value) => toolOptions.find((tool) => tool.value === value)?.name ?? value)
    .join(', ');
}

function summarize(config) {
  const distro = distroOptions.find((d) => d.value === config.baseImage)?.name ?? config.baseImage;
  console.log(chalk.bold('\nReview'));
  console.log(`  ${chalk.dim('Name'.padEnd(8))}${config.profileName}`);
  console.log(`  ${chalk.dim('Distro'.padEnd(8))}${distro}`);
  console.log(`  ${chalk.dim('User'.padEnd(8))}${config.appUser}`);
  console.log(`  ${chalk.dim('CPU/RAM'.padEnd(8))}${config.cpus} / ${config.memory}`);
  console.log(`  ${chalk.dim('Tools'.padEnd(8))}${describeTools(config.selectedTools)}`);
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
    message: 'Optional tools — leave empty for a minimal base (space to toggle)',
    choices: toolChoices,
    pageSize: 18,
    required: false,
    loop: false
  });

  // Advanced — sensible defaults are derived from the name; only ask if wanted.
  const customize = await confirm({
    message: 'Customize advanced settings (user, CPU, memory, dotfiles)?',
    default: false
  });

  let appUser = defaults.appUser;
  let appUid = defaults.appUid;
  let containerName = profileName;
  let imageName = `${profileName}:latest`;
  let cpus = defaults.cpus;
  let memory = defaults.memory;
  let dotfilesDir = defaults.dotfilesDir;

  if (customize) {
    appUser = await input({ message: 'Linux username', default: appUser });
    appUid = await input({ message: 'Linux uid', default: appUid });
    containerName = await input({ message: 'Container name', default: containerName });
    imageName = await input({ message: 'Image name', default: imageName });
    cpus = await input({ message: 'CPUs ("max" = all host cores)', default: cpus });
    memory = await input({ message: 'Memory ("max" = all host RAM)', default: memory });
    dotfilesDir = await input({ message: 'Dotfiles directory', default: dotfilesDir });
  }

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
    selectedTools
  };
}

async function writeProfileEnv(profileDir, config) {
  const enabledTools = new Set(config.selectedTools);
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
    envLine('DOTFILES_DIR', config.dotfilesDir)
  ];

  for (const tool of toolOptions) {
    lines.push(envLine(tool.value, enabledTools.has(tool.value) ? 'true' : 'false'));
  }

  await writeFile(path.join(profileDir, 'profile.env'), `${lines.join('\n')}\n`);
}

async function main() {
  const program = new Command();

  program
    .name('warp-zone')
    .description('Create a reusable Linux dev-environment profile from the work-ubuntu template')
    .option('--dir <name>', 'profile directory name')
    .option('--yes', 'accept defaults where possible')
    .parse(process.argv);

  const options = program.opts();
  const defaults = {
    profileName: options.dir ?? DEFAULT_PROFILE_NAME,
    baseImage: 'ubuntu:24.04',
    appUser: 'elk',
    appUid: '1001',
    cpus: 'max',
    memory: 'max',
    dotfilesDir: path.join(process.env.HOME ?? '', 'proj/pers/dotfiles')
  };

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
      dotfilesDir: defaults.dotfilesDir,
      // Minimal by default — opt into tools explicitly via the wizard.
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
}

main().catch((error) => {
  console.error(chalk.red(error instanceof Error ? error.message : String(error)));
  process.exit(1);
});
