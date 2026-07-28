#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cyan='\033[1;36m'
green='\033[1;32m'
yellow='\033[1;33m'
dim='\033[2m'
reset='\033[0m'

printf '%b\n' "${cyan}WARP${reset}  ${dim}isolated Linux development profiles${reset}"
printf '%s\n\n' '------------------------------------------------------------'

"$root/lib/status.sh"

printf '\n%bStart here%b\n' "$green" "$reset"
printf '  warp open [profile]   Enter a profile, building it if needed\n'
printf '  warp new              Create a new profile\n'
printf '  warp status [profile] See resources, SSH, and backups\n'

printf '\n%bManage%b\n' "$green" "$reset"
printf '  warp start|stop [profile]   Control a container without changing its files\n'
printf '  warp backup|restore [profile]  Protect or recover ~/work\n'
printf '  warp configure [profile]    Change profile settings\n'
printf '  warp update [profile]       Update OS packages\n'
printf '  warp rebuild [profile]      Recreate from its image, with backup prompt\n'

printf '\n%bConnect%b\n' "$green" "$reset"
printf '  warp ssh [profile]    Connect with SSH or VS Code Remote-SSH\n'
printf '\n%bRun `warp help` for all common commands. Profiles default to `dev`.%b\n' "$dim" "$reset"
