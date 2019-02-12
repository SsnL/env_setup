#!/bin/bash

set -eo pipefail

VERBOSE=false
FORCE_RUNS=()

while test $# -gt 0; do
  case "$1" in
    -h|--help)
      echo "Set up environment"
      echo " "
      echo "$0 [options] [sections forced to execute]"
      echo " "
      echo "options:"
      echo "-h, --help                show brief help"
      echo "-v, --verbose             turn on verbose mode"
      echo "-vv                       turn on \`set -x\` and verbose mode"
      exit 0
      ;;
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    -vv)
      VERBOSE=true
      set -x
      shift
      ;;
    *)
      FORCE_RUNS+=("$1")
      shift
      ;;
  esac
done

# set-up
STORE_FILENAME=".ssnl_env_setup"
touch $HOME/$STORE_FILENAME
DIR=$(mktemp -d /tmp/setup.XXXXXXXXX)

if [[ "$OSTYPE" == "linux-gnu" ]]; then
  # Linux
  MINICONDA_INSTALL_SH="Miniconda3-latest-Linux-x86_64.sh"
  if which yum ; then
    PKG_MANAGER="yum"
  elif which apt-get ; then
    PKG_MANAGER="apt-get"
  fi
elif [[ "$OSTYPE" == "darwin"* ]]; then
  # macOS
  MINICONDA_INSTALL_SH="Miniconda3-latest-MacOSX-x86_64.sh"
  PKG_MANAGER="brew"
elif [[ "$OSTYPE" == "cygwin" ]]; then
  # POSIX compatibility layer and Linux environment emulation for Windows
  true
elif [[ "$OSTYPE" == "msys" ]]; then
  # Lightweight shell and GNU utilities compiled for Windows (part of MinGW)
  true
elif [[ "$OSTYPE" == "win32" ]]; then
  # Windows. Can this happen?
  true
elif [[ "$OSTYPE" == "freebsd"* ]]; then
  # ...
  true
else
  # Unknown.
  true
fi

function to_lower() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

function indent() {
  if (( $# == 1 )); then
    local INDENT=$1
  else
    local INDENT=2
  fi
  local INDENT=$( printf ' %.s' $(eval "echo {1.."$(($INDENT))"}"); )
  sed "s/^/$INDENT/"
}

SEEN_NAMES=()

function run_if_needed() {
  local SCRIPT="$(cat)"
  local NAME=$1

  echo "Setting up $NAME:"

  (
  if $VERBOSE ; then
    echo -e "Script is\n\n$(echo "$SCRIPT" | indent)\n"
  fi

  for SEEN_NAME in "$SEEN_NAMES"; do
    if [[ "$SEEN_NAME" == "$NAME" ]]; then
      echo "$NAME occured more than once!"
      exit 1
    fi
  done
  SEEN_NAMES+=($NAME)

  local SCRIPT_SHA=$(echo "$SCRIPT" | shasum -a 256 -t | cut -f 1 -d " ")
  local STORED_SHA=$(sed -n "/^$NAME/p" $HOME/$STORE_FILENAME | cut -f 2 -d " " -s)
  local NUM_STORED_SHA=$(echo "$STORED_SHA" | wc -l | tr -d '[:space:]')

  if (( $NUM_STORED_SHA > 1 )); then
    echo "Found $NUM_STORED_SHA entries of $NAME in $HOME/$STORE_FILENAME!"
    exit 1
  fi

  if $VERBOSE ; then
    echo "Script SHA256: $SCRIPT_SHA"
    echo "Stored SHA256: $STORED_SHA"
  fi

  local RUN=0

  if [[ "$SCRIPT_SHA" == "$STORED_SHA" ]]; then
    for FORCE_RUN in ${FORCE_RUNS[@]}; do
      if [[ "$(to_lower $NAME)" == "$(to_lower $FORCE_RUN)" ]]; then
        if $VERBOSE ; then
          echo "$NAME has matched sha but is in the list of forced run sections"
        fi
        local RUN=1
      fi
    done
  else
    local RUN=1
  fi

  if [[ "$RUN" == "1" ]]; then
    if $VERBOSE ; then
      local CONTENT_BEFORE="$(cat $HOME/$STORE_FILENAME)"
    fi
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' "/^$NAME[[:space:]]/d" $HOME/$STORE_FILENAME
    else
      sed -i "/^$NAME[[:space:]]/d" $HOME/$STORE_FILENAME
    fi
    eval "$SCRIPT"
    local RV=$?
    echo "$NAME $SCRIPT_SHA" >> $HOME/$STORE_FILENAME
    if $VERBOSE ; then
      echo ""
      echo "$HOME/$STORE_FILENAME diff: "
      local DIFF=$( diff -u <(echo "$CONTENT_BEFORE") $HOME/$STORE_FILENAME || true )
      if [[ ! $DIFF ]]; then
        local DIFF="NONE"
      fi
      echo "$DIFF"
      echo ""
    fi
    echo -e "done!\n"
    return $?
  else
    echo -e "skipped!\n"
  fi
  ) | indent
}

pushd $DIR > /dev/null

# zsh
run_if_needed "zsh" <<- 'EOM'
if [[ -z $(command -v zsh) ]]; then
  $PKG_MANAGER install zsh
  chsh -s $(which zsh)
fi
EOM

# oh-my-zsh
run_if_needed "oh-my-zsh" <<- 'EOM'
if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh)"
fi
EOM

# basic shell setup
run_if_needed "basic_shell" <<- 'EOM'
if ! which vim > /dev/null ; then
  $PKG_MANAGER install vim -q -y
fi
cat <<-'EOT' >> $HOME/.zshrc
unsetopt correct_all
unsetopt correct
# User specific aliases and functions for all shells
export EDITOR=vim
alias gr="grep -nr"
alias gh="history | grep"
EOT
EOM

# miniconda3
# TODO: check version
run_if_needed "conda" <<- 'EOM'
if [[ -z $(command -v conda) ]]; then
  wget https://repo.anaconda.com/miniconda/$MINICONDA_INSTALL_SH -O ./miniconda.sh
  bash ./miniconda.sh -b -f -p $HOME/miniconda3

  cat << 'EOT' >> $HOME/.zshrc
# miniconda
export PATH=$HOME/miniconda3/bin:$PATH
EOT
fi
EOM

# cuda home
run_if_needed "cuda" <<- 'EOM'
if [[ -d "/usr/local/cuda" ]]; then
  cat <<- 'EOT' >> $HOME/.zshrc
# cuda
export PATH=/usr/local/cuda/bin:$PATH
EOT
fi
EOM

# git
run_if_needed "git" <<- 'EOM'
if ! which git > /dev/null ; then
  $PKG_MANAGER install git -y -q
fi
git config --global core.editor "vim"
# aliases
cat <<- 'EOT' >> $HOME/.zshrc
# git
function gsub() {
  git submodule sync --recursive "$@" && \
  git submodule update --init --recursive "$@"
}
function grhr () {
  git fetch --all -p
  git reset --hard ${1:-origin}/$(git symbolic-ref --short HEAD)
}
EOT
EOM

# tmux plugin manager
# tmux better mouse mode
run_if_needed "tmux" <<- 'EOM'
if [[ ! -d "$HOME/.tmux/plugins/tpm" ]]; then

  git clone https://github.com/tmux-plugins/tpm $HOME/.tmux/plugins/tpm
  cat <<- 'EOT' >> $HOME/.tmux.conf
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
EOM

# gdb
run_if_needed "gdb" <<- 'EOM'
# gdb dashboard
wget -q git.io/.gdbinit -O $HOME/.gdbinit

# helpers
cat <<- 'EOT' >> $HOME/.zshrc
# gdb
function pgdb () {
  local TTY=$(tmux list-panes -s -F "#{pane_tty},#{pane_top},#{pane_left}" | \
              grep ",0,0$" | \
              cut -d',' -f 1)
  if [[ "$TTY" == "$(tty)" ]]; then
    local TTY=$(tmux list-panes -s -F "#{pane_tty},#{pane_top},#{pane_left},#{pane_active}" | \
                grep ",0,0$" | \
                sort -t"," -nk2 | \
                cut -d"," -f 1)
  fi
  echo "Using TTY as gdb dashboard: ${TTY}\n"
  echo -e "\033\0143Used as gdb dashboard: python $@" > $TTY  # clear & print
  gdb --eval-command "dashboard -output ${TTY}" --args python "$@"
  echo -e "\033\0143" > $TTY
  setterm -cursor on > $TTY
}
alias pgdb="gdb r --args python"
alias cpgdb="cuda-gdb -tui r --args python"
EOT
EOM

# TODO: fix printing of things like \033\0143 in script above when -v

# TODO: npm global dir https://docs.npmjs.com/resolving-eacces-permissions-errors-when-installing-packages-globally
# TODO: vim, ctrl-p, NERDTree, https://github.com/scrooloose/nerdcommenter
# TODO: codemod

# if [[ -n "$ZSH_VERSION" ]]; then
#   source $HOME/.zshrc
# fi

popd > /dev/null

