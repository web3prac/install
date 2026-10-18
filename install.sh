#!/usr/bin/env bash
# Smart one-shot installer for Ubuntu.
# Checks every tool first: if it is already installed it is SKIPPED, otherwise it is installed.
# Tools: curl, wget, git, jq, unzip, Go, Java (JDK), Maven, Docker, Docker Compose,
#        Python 2.7, Node 18 + npm, geth 1.11.6, Truffle, Hyperledger Fabric.
# Run with:  bash install.sh
set -euo pipefail

NODE_VER="v18.20.8"
GETH_FILE="geth-linux-amd64-1.11.6-ea9e62ca"

INSTALLED=()
SKIPPED=()
FAILED=()

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
skip() { printf '\033[1;36m[skip]\033[0m %s already installed\n' "$1"; SKIPPED+=("$1"); }
warn() { printf '\n\033[1;33m[warn] %s\033[0m\n' "$*"; }

if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as a normal user (not root/sudo). It will call sudo when needed."
  exit 1
fi

have() { command -v "$1" >/dev/null 2>&1; }

# apt_tool <display name> <command to check> <apt package(s)...>
apt_tool() {
  local name="$1" cmd="$2"; shift 2
  if have "$cmd"; then
    skip "$name"
  else
    log "Installing $name"
    if sudo apt-get install -y "$@"; then INSTALLED+=("$name"); else FAILED+=("$name"); fi
  fi
}

add_path_line() {
  local line='export PATH="$HOME/node18/bin:$HOME/.npm-global/bin:$HOME/geth1116:$PATH"'
  grep -qxF "$line" ~/.bashrc 2>/dev/null || echo "$line" >> ~/.bashrc
}

export PATH="$HOME/node18/bin:$HOME/.npm-global/bin:$HOME/geth1116:$PATH"

log "Refreshing apt package lists"
sudo apt-get update

# ---------------------------------------------------------------- base tools
apt_tool "curl"  curl  curl
apt_tool "wget"  wget  wget
apt_tool "git"   git   git
apt_tool "jq"    jq    jq
apt_tool "unzip" unzip unzip
apt_tool "xz-utils" xz xz-utils
apt_tool "Go"    go    golang-go
apt_tool "Java (JDK)" javac default-jdk
apt_tool "Maven" mvn   maven

# ---------------------------------------------------------------- docker
apt_tool "Docker" docker docker.io

if docker compose version >/dev/null 2>&1 || have docker-compose; then
  skip "Docker Compose"
else
  log "Installing Docker Compose"
  if apt-cache show docker-compose-v2 >/dev/null 2>&1; then
    pkg="docker-compose-v2"
  elif apt-cache show docker-compose-plugin >/dev/null 2>&1; then
    pkg="docker-compose-plugin"
  else
    pkg="docker-compose"
  fi
  if sudo apt-get install -y "$pkg"; then INSTALLED+=("Docker Compose"); else FAILED+=("Docker Compose"); fi
fi

sudo systemctl enable --now docker >/dev/null 2>&1 || true
if id -nG "$USER" | grep -qw docker; then
  skip "docker group membership"
else
  sudo usermod -aG docker "$USER"
  INSTALLED+=("docker group membership")
fi

# ---------------------------------------------------------------- python 2.7
if have python2 || have python2.7; then
  skip "Python 2.7"
elif apt-cache show python2 >/dev/null 2>&1; then
  log "Installing Python 2.7"
  if sudo apt-get install -y python2; then INSTALLED+=("Python 2.7"); else FAILED+=("Python 2.7"); fi
else
  warn "python2 is not in your Ubuntu repos (Ubuntu 24.04+). Use pyenv: 'pyenv install 2.7.18'."
  FAILED+=("Python 2.7 (not in repos)")
fi

# ---------------------------------------------------------------- node 18 + npm
if [ -x "$HOME/node18/bin/node" ] && [ -x "$HOME/node18/bin/npm" ]; then
  skip "Node.js + npm (~/node18)"
elif have node && have npm; then
  skip "Node.js + npm (system)"
else
  log "Installing Node.js ${NODE_VER} + npm"
  cd ~
  if [ -f "node-${NODE_VER}-linux-x64.tar.xz" ]; then
    echo "Archive already downloaded, reusing it."
  else
    curl -fLO "https://nodejs.org/dist/${NODE_VER}/node-${NODE_VER}-linux-x64.tar.xz"
  fi
  mkdir -p ~/node18
  tar xf "node-${NODE_VER}-linux-x64.tar.xz" -C ~/node18 --strip-components=1
  rm -f "node-${NODE_VER}-linux-x64.tar.xz"
  INSTALLED+=("Node.js + npm")
fi
add_path_line
if have npm; then
  [ "$(npm config get prefix)" = "$HOME/.npm-global" ] || npm config set prefix "$HOME/.npm-global"
  node -v && npm -v
fi

# ---------------------------------------------------------------- geth 1.11.6
if [ -x "$HOME/geth1116/geth" ]; then
  skip "geth 1.11.6 (~/geth1116)"
else
  log "Installing geth 1.11.6"
  cd ~
  if [ -f "${GETH_FILE}.tar.gz" ]; then
    echo "Archive already downloaded, reusing it."
  else
    curl -fLO "https://gethstore.blob.core.windows.net/builds/${GETH_FILE}.tar.gz"
  fi
  tar xzf "${GETH_FILE}.tar.gz"
  mkdir -p ~/geth1116
  mv "${GETH_FILE}/geth" ~/geth1116/
  rm -rf "${GETH_FILE}"*
  INSTALLED+=("geth 1.11.6")
fi

# ---------------------------------------------------------------- truffle
if have truffle; then
  skip "Truffle"
else
  log "Installing Truffle"
  if npm install -g truffle; then INSTALLED+=("Truffle"); else FAILED+=("Truffle"); fi
fi

# ---------------------------------------------------------------- fabric
FABRIC_DIR="$HOME/fabric"
if [ -x "$FABRIC_DIR/fabric-samples/bin/peer" ]; then
  skip "Hyperledger Fabric binaries + samples"
  FABRIC_NEED_BIN=0
else
  FABRIC_NEED_BIN=1
fi

# Which Fabric docker images are missing?
FABRIC_NEED_IMG=0
if have docker; then
  if ! sg docker -c "docker images --format '{{.Repository}}'" 2>/dev/null | grep -q '^hyperledger/fabric-peer$'; then
    FABRIC_NEED_IMG=1
  else
    skip "Hyperledger Fabric docker images"
  fi
fi

if [ "$FABRIC_NEED_BIN" = 1 ] || [ "$FABRIC_NEED_IMG" = 1 ]; then
  log "Installing Hyperledger Fabric (only the missing parts)"
  mkdir -p "$FABRIC_DIR" && cd "$FABRIC_DIR"
  if [ ! -f install-fabric.sh ]; then
    curl -fSLO https://raw.githubusercontent.com/hyperledger/fabric/main/scripts/install-fabric.sh
  fi
  chmod +x install-fabric.sh
  args=()
  [ "$FABRIC_NEED_IMG" = 1 ] && args+=(docker)
  [ "$FABRIC_NEED_BIN" = 1 ] && args+=(samples binary)
  # 'sg docker' applies the new docker group immediately, no re-login needed for this step
  if sg docker -c "./install-fabric.sh ${args[*]}"; then
    INSTALLED+=("Hyperledger Fabric (${args[*]})")
  else
    FAILED+=("Hyperledger Fabric")
  fi
fi

# ---------------------------------------------------------------- summary
log "Summary"
echo "Installed now : ${INSTALLED[*]:-none}"
echo "Skipped       : ${SKIPPED[*]:-none}"
echo "Failed        : ${FAILED[*]:-none}"

log "Versions"
{ have curl && curl --version | head -1; } || true
{ have git && git --version; } || true
{ have go && go version; } || true
{ have java && java -version 2>&1 | head -1; } || true
{ have mvn && mvn -version | head -1; } || true
{ have docker && docker --version; } || true
{ docker compose version 2>/dev/null || { have docker-compose && docker-compose --version; }; } || true
{ have python2 && python2 --version 2>&1; } || true
{ have node && node -v; } || true
{ have npm && npm -v; } || true
{ [ -x "$HOME/geth1116/geth" ] && "$HOME/geth1116/geth" version | head -2; } || true
{ have truffle && truffle version | head -1; } || true
{ [ -x "$FABRIC_DIR/fabric-samples/bin/peer" ] && "$FABRIC_DIR/fabric-samples/bin/peer" version | head -2; } || true

echo
echo "IMPORTANT: log out and back in (or run 'newgrp docker') so Docker works without sudo,"
echo "and run 'source ~/.bashrc' in any terminal that was already open."
[ "${#FAILED[@]}" -eq 0 ] || exit 1
