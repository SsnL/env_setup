#!/bin/bash

DIR=$(mktemp -d /tmp/foo.XXXXXXXXX)

pushd $DIR

# zsh
if [[ -z $(command -v zsh) ]]; then
  apt install zsh
  chsh -s $(which zsh)
fi

# oh-my-zsh
if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh)"
fi

# miniconda3
# TODO: check version
if [[ -z $(command -v conda) ]]; then
  wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O ./miniconda.sh
  bash ./miniconda.sh -b -p $HOME/miniconda3

  cat <<EOT >> $HOME/.zshrc
# miniconda
export PATH=\$HOME/miniconda3/bin:\$PATH
EOT
fi

# tmux plugin manager
# tmux better mouse mode
if [[ ! -d "$HOME/.tmux/plugins/tpm" ]]; then

  git clone https://github.com/tmux-plugins/tpm $HOME/.tmux/plugins/tpm
  cat <<EOT >> $HOME/.tmux.conf
# List of plugins
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'nhdaly/tmux-better-mouse-mode'

# Initialize TMUX plugin manager (keep this line at the very bottom of tmux.conf)
run -b '~/.tmux/plugins/tpm/tpm'

set-option -g mouse on
set-option -g history-limit 20000
EOT
  tmux source $HOME/.tmux.conf
fi

# cuda home
if [[ -d "/usr/local/cuda" ]]; then
  cat <<EOT >> $HOME/.zshrc
# cuda
export PATH=/usr/local/cuda/bin:\$PATH
EOT
fi

# git 
git config --global core.editor "vim"
# aliases
cat <<EOT >> $HOME/.zshrc
# git
alias gsub="git submodule sync --recursive; git submodule update --init --recursive"
EOT

# TODO: gdb
# TODO: npm global dir https://docs.npmjs.com/resolving-eacces-permissions-errors-when-installing-packages-globally
# TODO: vim, ctrl-p, NERDTree, https://github.com/scrooloose/nerdcommenter
# TODO: codemod

if [[ -n "$ZSH_VERSION" ]]; then
  source $HOME/.zshrc
fi
popd

