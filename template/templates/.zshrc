ZSH_THEME="robbyrussell"
plugins=(git)
source "$ZSH/oh-my-zsh.sh"

if [ -n "$PROFILE_PROMPT" ]; then
  PROMPT="%F{green}${PROFILE_PROMPT}%f %F{cyan}%~%f %# "
fi

if [ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]; then
  source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
fi

if [ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]; then
  source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
fi

setopt AUTO_CD
cdpath=($HOME/work $cdpath)

alias c='clear'
alias ww='cd $HOME/work && clear'
alias nb='git checkout -b'
alias check='git checkout'
alias main='git checkout main'
alias stable='git checkout stable'
alias pull='git pull'
alias stash='git stash'
alias pop='git stash pop'
alias root='cd $(git rev-parse --show-toplevel)'
alias cat='batcat'
alias ll='eza -al --group-directories-first'
alias l='eza -al --group-directories-first'
alias now='TZ=Europe/Oslo date +"%H:%M:%S"'
alias nowtz='date -u +"%Y-%m-%dT%H:%M:%SZ"'

if command -v kubectl >/dev/null 2>&1; then
  alias kb='kubectl'
fi

if command -v dotnet >/dev/null 2>&1; then
  alias dn='dotnet'
  alias nukenet='dotnet nuget locals all --clear && dotnet build'
fi

if command -v k9s >/dev/null 2>&1; then
  alias knis='k9s'
fi

if command -v jira >/dev/null 2>&1; then
  alias j='jira'
fi
