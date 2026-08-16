if [ -f "$HOME/.zshenv" ]; then
  . "$HOME/.zshenv"
fi

if [ -f "$HOME/.bashrc.local" ]; then
  . "$HOME/.bashrc.local"
fi
