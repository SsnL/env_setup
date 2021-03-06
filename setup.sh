#!/bin/bash

set -eo pipefail

VERBOSE=false
DRY_RUN=false
SELECTED_SECTIONS=()

while test $# -gt 0; do
  case "$1" in
    -h|--help)
      echo "Set up environment"
      echo " "
      echo "$0 [options] [sections selected to force execute, empty means executing all outdated sections]"
      echo " "
      echo "options:"
      echo "-h, --help                show brief help"
      echo "-v, --verbose             turn on verbose mode"
      echo "-vv                       turn on \`set -x\` and verbose mode"
      echo "--dry-run                 dry-run"
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
    --dry-run)
      DRY_RUN=true
      set -x
      shift
      ;;
    *)
      SELECTED_SECTIONS+=("$1")
      shift
      ;;
  esac
done

# set-up
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

real_user=$(who am i | awk '{print $1}')

# inspiration: https://github.com/pietern/pytorch-dockerfiles/blob/a06f8c4020112fdc6c1ac755ce3b475aa8d7fd51/common/install_conda.sh#L27-L32
function as_real_user() {
  sudo -H -u $real_user env -u SUDO_UID -u SUDO_GID -u SUDO_COMMAND -u SUDO_USER env "PATH=$PATH" "LD_LIBRARY_PATH=$LD_LIBRARY_PATH" $*
}

STORE_FILENAME=".ssnl_env_setup"
as_real_user touch $HOME/$STORE_FILENAME
DIR=$(as_real_user mktemp -d /tmp/setup.XXXXXXXXX)

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
  PKG_MANAGER="as_real_user brew"
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

if [[ "$OSTYPE" == "darwin"* ]]; then
  function sed_inplace() {
    sed -i '' "$@"
  }
else
  function sed_inplace() {
    sed -i "$@"
  }
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
    echo -e "Script is\n\n$(printf %s "$SCRIPT" | indent)\n"
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
    for SELECTED_SECTION in ${SELECTED_SECTIONS[@]}; do
      if [[ "$(to_lower $NAME)" == "$(to_lower $SELECTED_SECTION)" ]]; then
        if $VERBOSE ; then
          echo "$NAME has matched sha but is in the list of forced run sections"
        fi
        local RUN=1
      fi
    done
  else
    #  run outdated if not selected sections are specified
    if [[ ${#SELECTED_SECTIONS[@]} -eq 0 ]]; then
      local RUN=1
    fi
  fi

  if [[ "$RUN" == "1" ]]; then
    if $DRY_RUN ; then
      echo -e "skipped (dry-run. will run otherwise)!\n"
    else
      if $VERBOSE ; then
        local CONTENT_BEFORE="$(cat $HOME/$STORE_FILENAME)"
      fi
      sed_inplace "/^$NAME[[:space:]]/d" $HOME/$STORE_FILENAME
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
    fi
  else
    echo -e "skipped!\n"
  fi
  ) | indent
}

pushd $DIR > /dev/null

# topological order
# TODO: maybe use tsort?

# zsh
run_if_needed "zsh" <<- 'EOM'
if [[ -z $(command -v zsh) ]]; then
  $PKG_MANAGER update -qq
  $PKG_MANAGER install zsh -q -y
  chsh -s $(which zsh) $real_user
fi
EOM

# oh-my-zsh
run_if_needed "oh-my-zsh" <<- 'EOM'
if ! which git > /dev/null ; then
  $PKG_MANAGER update -qq
  $PKG_MANAGER install git -q -y
fi
if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh)"
fi

# installl powerline fonts for agnoster theme
if [[ "$PKG_MANAGER" == *"apt"* ]]; then
  $PKG_MANAGER update -qq
  $PKG_MANAGER install fonts-powerline -q -y
else
  # clone
  as_real_user git clone https://github.com/powerline/fonts.git --depth=1
  # install
  cd fonts
  as_real_user ./install.sh
  # clean-up a bit
  cd ..
  as_real_user rm -rf fonts
fi

# set theme
as_real_user sed_inplace "s/^ZSH_THEME=.*$/ZSH_THEME=\"agnoster\"/g" $HOME/.zshrc
EOM

# basic shell setup
run_if_needed "basic_shell" <<- 'EOM'
if ! which vim > /dev/null ; then
  $PKG_MANAGER update -qq
  $PKG_MANAGER install vim -q -y
fi
as_real_user cat <<- 'EOT' >> $HOME/.zshrc
unsetopt correct_all
unsetopt correct
# User specific aliases and functions for all shells
export EDITOR=vim
alias gr="grep -nr"
alias gh="history | grep"
EOT
EOM

# npm
run_if_needed "npm" <<- 'EOM'
if ! which npm > /dev/null ; then
  if [[ "$PKG_MANAGER" == *"apt"* ]]; then
    curl -sL https://deb.nodesource.com/setup_12.x | sudo -E bash -
    apt-get install -y nodejs
  fi
fi
if which npm > /dev/null ; then
  npm install -g http-server
fi
EOM

# git
run_if_needed "git" <<- 'EOM'
if ! which git > /dev/null ; then
  $PKG_MANAGER update -qq
  $PKG_MANAGER install git -q -y
fi
git config --global core.editor "vim"
# aliases
as_real_user cat <<- 'EOT' >> $HOME/.zshrc
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

# miniconda3
# TODO: check version
run_if_needed "conda" <<- 'EOM'
# just for test and installs below
export PATH=$HOME/miniconda3/bin:$PATH
if [[ -z $(command -v conda) ]]; then
  as_real_user wget https://repo.anaconda.com/miniconda/$MINICONDA_INSTALL_SH -O ./miniconda.sh
  as_real_user bash ./miniconda.sh -b -f -p $HOME/miniconda3

  as_real_user cat <<- 'EOT' >> $HOME/.zshrc
# miniconda
export PATH=$HOME/miniconda3/bin:$PATH
EOT
fi
$PKG_MANAGER update -qq
$PKG_MANAGER install gcc g++ make -q -y
$PKG_MANAGER install xvfb xserver-xephyr vnc4server python-opengl ffmpeg -q -y
as_real_user conda install jupyter ipython numpy scipy yaml matplotlib scikit-image scikit-learn \
                           six pytest mkl mkl-include pyyaml setuptools cmake cffi typing sphinx \
                           ninja tqdm imageio psutil pandas seaborn -y
as_real_user conda install -c conda-forge jupyterlab -y
as_real_user conda install -c conda-forge jupyter_contrib_nbextensions -y
as_real_user conda install -c pytorch pytorch torchvision cudatoolkit=10.2 -y
as_real_user pip install -q oyaml codemod threadpoolctl ring easydict
as_real_user conda install -c conda-forge ffmpeg imageio-ffmpeg -y
as_real_user pip install -q dominate visdom opencv-python aiohttp setproctitle shortuuid einops
as_real_user pip install -q pyvirtualdisplay gym pyro-ppl box2d-py roboschool atari-py
as_real_user pip uninstall pillow -y
as_real_user pip install -q git+https://github.com/CMA-ES/pycma.git@master
as_real_user pip install -q dill casadi plotille einops gym-minigrid
CC="cc -mavx2" as_real_user pip install -U --force-reinstall -q pillow-simd
EOM

# cuda home
# TODO: check os
# TODO: check compute capability
run_if_needed "cuda" <<- 'EOM'
if [[ "$OSTYPE" == "linux-gnu" ]]; then
  NVIDIA_GPUS=$(lspci | grep NVIDIA)
  if [[ ! -z "$NVIDIA_GPUS" ]]; then
    if [[ ! -d "/usr/local/cuda" ]]; then
      # cuda 10.2
      $PKG_MANAGER update -qq
      $PKG_MANAGER install gcc g++ libxml2 make -q -y
      curl -fsSL https://developer.download.nvidia.com/compute/cuda/10.2/Prod/local_installers/cuda_10.2.89_440.33.01_linux.run -O
      sh cuda_10.2.89_440.33.01_linux.run --driver --toolkit --samples --override --silent

      # cudnn 7.6.5
      # from https://gitlab.com/nvidia/container-images/cuda/-/blob/d442ff6975fb8310da90e6c3f35a988b6920b017/dist/centos7/10.2/devel/cudnn7/Dockerfile
      CUDNN_DOWNLOAD_SUM=600267f2caaed2fd58eb214ba669d8ea35f396a7d19b94822e6b36f9f7088c20 && \
      curl -fsSL http://developer.download.nvidia.com/compute/redist/cudnn/v7.6.5/cudnn-10.2-linux-x64-v7.6.5.32.tgz -O && \
      echo "$CUDNN_DOWNLOAD_SUM  cudnn-10.2-linux-x64-v7.6.5.32.tgz" | sha256sum -c - && \
      tar --no-same-owner -xzf cudnn-10.2-linux-x64-v7.6.5.32.tgz -C /usr/local && \
      rm cudnn-10.2-linux-x64-v7.6.5.32.tgz && \
      (printf "/usr/local/cuda/lib64\n\n" | tee -a /etc/ld.so.conf) && \
      /sbin/ldconfig
    fi
  as_real_user cat <<- 'EOT' >> $HOME/.zshrc
# cuda
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
EOT
  fi
fi
EOM

run_if_needed "gcp" <<- 'EOM'
as_real_user curl https://sdk.cloud.google.com | env CLOUDSDK_CORE_DISABLE_PROMPTS=1 bash
EOM

# tmux plugin manager
# tmux better mouse mode
run_if_needed "tmux" <<- 'EOM'
$PKG_MANAGER update -qq
$PKG_MANAGER install tmux -q -y
if [[ ! -d "$HOME/.tmux/plugins/tpm" ]]; then
  as_real_user git clone https://github.com/tmux-plugins/tpm $HOME/.tmux/plugins/tpm
  as_real_user cat <<- 'EOT' >> $HOME/.tmux.conf
# List of plugins
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'nhdaly/tmux-better-mouse-mode'

set -g default-terminal "screen-256color"
set-option -g mouse on
set-option -g history-limit 20000
bind c new-window -c "#{pane_current_path}"
bind '"' split-window -c "#{pane_current_path}"
bind % split-window -h -c "#{pane_current_path}"

# Initialize TMUX plugin manager (keep this line at the very bottom of tmux.conf)
run -b '~/.tmux/plugins/tpm/tpm'
EOT
  as_real_user tmux source $HOME/.tmux.conf
fi

# helper
as_real_user cat <<- 'EOT' >> $HOME/.zshrc
# tmux
zmodload zsh/mathfunc
function tmux-split-cmd() {
  local COMMAND=( ${@} )
  COMMAND="$(printf "%q " "${COMMAND[@]}")"
  local DENOM=${DENOM:-2}
  local ZSH_COMMAND="source $HOME/.zshrc; echo $COMMAND; echo; echo; $COMMAND; zsh -i"
  tmux split-window -dh -p $((int(rint(100./$DENOM)))) -t $TMUX_PANE "zsh -c '$ZSH_COMMAND'"
}
EOT
EOM

# gdb
run_if_needed "gdb" <<- 'EOM'
if [[ ! "$OSTYPE" == "darwin"* ]]; then
  # gdb dashboard
  as_real_user wget -q git.io/.gdbinit -O $HOME/.gdbinit

  # helpers
  as_real_user cat <<- 'EOT' >> $HOME/.zshrc
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
fi
EOM

# TODO: npm global dir https://docs.npmjs.com/resolving-eacces-permissions-errors-when-installing-packages-globally
# TODO: vim, ctrl-p, NERDTree, https://github.com/scrooloose/nerdcommenter

tset

echo "All done!"
echo "Run \`exec zsh --login\` after this!"

popd > /dev/null
