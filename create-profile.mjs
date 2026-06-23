#!/usr/bin/env node

import { access, copyFile, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { constants } from 'node:fs';
import process from 'node:process';
import { Command } from 'commander';
import chalk from 'chalk';
import { input, checkbox, confirm } from '@inquirer/prompts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const templateDir = path.join(__dirname, 'work-ubuntu');
const profilesRoot = path.join(process.env.HOME ?? '', 'container');

const toolOptions = [
  { name: 'Node.js, corepack, pnpm, yarn', value: 'INCLUDE_NODE' },
  { name: '.NET SDK 8 and 10', value: 'INCLUDE_DOTNET' },
  { name: 'Azure CLI', value: 'INCLUDE_AZURE_CLI' },
  { name: 'Pulumi CLI', value: 'INCLUDE_PULUMI' },
  { name: 'kubectl', value: 'INCLUDE_KUBECTL' },
  { name: 'GitHub CLI', value: 'INCLUDE_GH' },
  { name: 'jira CLI', value: 'INCLUDE_JIRA' },
  { name: 'k9s', value: 'INCLUDE_K9S' },
  { name: 'Python 3', value: 'INCLUDE_PYTHON' }
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

async function promptForProfile(defaults) {
  console.log(chalk.cyanBright.bold('\nContainer Profile Setup'));
  console.log(chalk.dim('Create a reusable Apple container profile with your preferred tools.'));
  console.log(chalk.dim(`Profiles are saved in ${profilesRoot}\n`));

  // Essentials — most profiles only need these two answers.
  const profileNameRaw = await input({
    message: 'Profile name',
    default: defaults.profileName
  });
  const profileName = sanitizeName(profileNameRaw);

  const selectedTools = await checkbox({
    message: 'Tools to include (space to toggle, enter to confirm)',
    choices: toolOptions.map((tool) => ({ ...tool, checked: true })),
    pageSize: toolOptions.length
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
    cpus = await input({ message: 'CPUs', default: cpus });
    memory = await input({ message: 'Memory', default: memory });
    dotfilesDir = await input({ message: 'Dotfiles directory', default: dotfilesDir });
  }

  return {
    profileName,
    containerName,
    imageName,
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
    .name('create-container-profile')
    .description('Create a reusable Apple container profile from the work-ubuntu template')
    .option('--dir <name>', 'profile directory name')
    .option('--yes', 'accept defaults where possible')
    .parse(process.argv);

  const options = program.opts();
  const defaults = {
    profileName: options.dir ?? 'work-ubuntu',
    appUser: 'elk',
    appUid: '1001',
    cpus: '8',
    memory: '16G',
    dotfilesDir: path.join(process.env.HOME ?? '', 'proj/pers/dotfiles')
  };

  let config;

  if (options.yes) {
    const profileName = sanitizeName(defaults.profileName);
    config = {
      profileName,
      containerName: profileName,
      imageName: `${profileName}:latest`,
      appUser: defaults.appUser,
      appUid: defaults.appUid,
      profilePrompt: defaults.appUser.toUpperCase(),
      cpus: defaults.cpus,
      memory: defaults.memory,
      dotfilesDir: defaults.dotfilesDir,
      selectedTools: toolOptions.map((tool) => tool.value)
    };
  } else {
    config = await promptForProfile(defaults);
  }

  await mkdir(profilesRoot, { recursive: true });

  const profileDir = path.join(profilesRoot, config.profileName);

  if (await exists(profileDir)) {
    const overwrite = await confirm({
      message: `Profile directory ${chalk.yellow(config.profileName)} already exists. Overwrite profile.env only?`,
      default: false
    });

    if (!overwrite) {
      console.error(chalk.red(`Profile directory already exists: ${profileDir}`));
      process.exit(1);
    }

    await writeProfileEnv(profileDir, config);
  } else {
    await copyTemplateProfile(profileDir);
    await writeProfileEnv(profileDir, config);
  }

  console.log(chalk.greenBright(`\n✓ Created profile "${config.profileName}" at ${profileDir}`));
  console.log(chalk.bold('\nNext step — build and enter it:'));
  console.log(chalk.cyan(`  just open ${config.profileName}`));
}

main().catch((error) => {
  console.error(chalk.red(error instanceof Error ? error.message : String(error)));
  process.exit(1);
});
