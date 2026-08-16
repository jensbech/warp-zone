#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cmd="${1:-warp}"

cyan='\033[1;36m'
green='\033[1;32m'
red='\033[1;31m'
dim='\033[2m'
reset='\033[0m'

row() { printf "  ${green}%-30s${reset} ${dim}%s${reset}\n" "$1" "$2"; }
row_danger() { printf "  ${red}%-30s${reset} ${dim}%s${reset}\n" "$1" "$2"; }

printf '%b\n' "${cyan}🌀 warp-zone${reset}  ${dim}isolated Linux dev profiles · ~/container · default: dev${reset}"
printf '\n'

"$root/lib/status.sh"

printf '\n%bGet started%b\n' "$green" "$reset"
row "$cmd new" 'Create a profile (interactive wizard)'
row "$cmd open [profile]" 'Build (if needed) and enter a profile'
row "$cmd ssh [profile]" 'SSH into a profile (if SSH enabled)'
row "$cmd run <profile> <cmd>" 'Run a one-off command in a profile'
row "$cmd forward <port> [profile]" 'Forward a container port to localhost (via SSH)'

printf '\n%bManage%b\n' "$green" "$reset"
row "$cmd list" 'List your profiles'
row "$cmd status [profile]" 'Show profile state, resources, SSH, and backups'
row "$cmd configure [profile]" 'Change profile settings with the wizard'
row "$cmd start/stop [profile]" 'Control a container without changing its files'
row "$cmd backup [profile]" 'Back up ~/work'
row "$cmd restore [profile]" 'Restore ~/work from a backup'
row "$cmd build [profile]" 'Build the image only'
row "$cmd rebuild [profile]" 'Rebuild image and recreate container'
row "$cmd update [profile]" 'Update OS packages in a container'
row "$cmd update-all" 'Update OS packages in every container (parallel)'
row "$cmd logs [profile]" "Show a container's logs"
row "$cmd prune" 'Remove stopped containers and unused images'
row "$cmd doctor" 'Check your setup for problems'
row_danger "$cmd destroy [profile]" 'Delete a profile, its container, and image'
row "$cmd install-global" 'Install the warp command for use anywhere'

printf '\n%bTip: profile defaults to "dev" when omitted.%b\n' "$dim" "$reset"
