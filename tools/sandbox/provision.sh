#!/usr/bin/env bash
# Provision the Grow Box sandbox toolchain — in privilege PHASES.
#
# OS-agnostic core shared by every sandbox runtime (Docker image, cloud-init VM,
# bare Ubuntu, macOS dev). Idempotent: re-running only installs what's missing.
#
# Privilege model: privileged work runs AS root in ONE explicit stage, never
# sprinkled `sudo`. Per-user work is unprivileged
# and lands in the INVOKING user's $HOME — so on the VM bun goes to the `ubuntu`
# user's ~/.bun, not /root/.bun.
#
#   provision.sh system   SYSTEM packages only (apt + /usr/local/bin binaries).
#                         The single privileged stage — MUST run as root.
#   provision.sh user     bun (pinned to tools/.bun-version) into ~/.bun of the
#                         invoking user. No root required, no sudo.
#   provision.sh all      (default) system then user; runs the system phase via
#                         sudo when not already root — convenience for a manual
#                         VM / Docker / macOS dev box.
#
# macOS: only `user` and `all` are meaningful. `all` provisions the brew lint
# subset (a dev path with caveats: no Linux-only tools) plus bun. There is no root-only `system` phase on macOS.
#
# Env overrides:
#   BUN_VERSION   pin bun (default: read from tools/.bun-version, else 1.3.14)
#   GITLEAKS_VERSION / YQ_VERSION   pin those binaries
#   NVM_VERSION / NODE_VERSION   pin nvm and the Node.js it installs
#   WITH_NODE=0   skip Node/npm in the Linux user phase (npm is a
#                 convenience next to bun). Default installs node into the invoking user's ~.
#   SKIP_DOCKER=1 skip docker install (e.g. Tier-1 image with no daemon). When
#                 unset the system phase installs docker.io + docker-compose-v2
#                 (the `docker compose` plugin).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$(cd "$HERE/.." && pwd)"

read_bun_version() {
  if [ -n "${BUN_VERSION:-}" ]; then
    printf '%s' "$BUN_VERSION"
  elif [ -f "$TOOLS_DIR/.bun-version" ]; then
    tr -d ' \t\n' < "$TOOLS_DIR/.bun-version"
  else
    printf '1.3.14'
  fi
}

BUN_VERSION="$(read_bun_version)"
GITLEAKS_VERSION="${GITLEAKS_VERSION:-8.18.4}"
YQ_VERSION="${YQ_VERSION:-v4.44.3}"
NVM_VERSION="${NVM_VERSION:-v0.40.5}"
NODE_VERSION="${NODE_VERSION:-v24.18.0}"

log()  { printf '\033[36m[provision]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[provision] WARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[provision] ERROR\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Map `uname -m` to the release-asset arch token. Vendors DISAGREE on the amd64
# token: gitleaks uses `x64` (asset_arch); mikefarah/yq uses `amd64` (yq_arch).
# Both use `arm64` for aarch64. (Verified against the v8.18.4 / v4.44.3 releases —
# `aarch64`, `amd64` for gitleaks, and `x64` for yq all 404.)
asset_arch() {   # gitleaks / bun style: x64 | arm64
  case "$(uname -m)" in
    x86_64|amd64) printf 'x64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

yq_arch() {      # mikefarah/yq style: amd64 | arm64
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

# --- user phase helpers -----------------------------------------------------

install_bun() {
  if have bun && [ "$(bun --version 2>/dev/null)" = "$BUN_VERSION" ]; then
    log "bun $BUN_VERSION already present"
    return
  fi
  log "installing bun $BUN_VERSION into $HOME/.bun"
  curl -fsSL https://bun.sh/install | bash -s "bun-v$BUN_VERSION"
}

install_npm() {
  if have node && [ "$(node -v 2>/dev/null)" = "$NODE_VERSION" ]; then
    log "Node.js $NODE_VERSION already present"
    return
  fi
  log "installing Node.js $NODE_VERSION via nvm $NVM_VERSION into $HOME/.nvm"
  # nvm is a shell function, not a binary: run its installer, then source nvm.sh
  # into THIS shell so `nvm`/`node`/`npm` are usable immediately — the installer
  # only appends to ~/.bashrc, which this non-interactive run never re-reads.
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1090
  . "$NVM_DIR/nvm.sh"
  # Pin the exact patch (not the `24` major) so the version check above stays
  # true on re-runs — `nvm install 24` would drift to a newer 24.x and reinstall.
  nvm install "$NODE_VERSION"
}

install_make() {
  if have make; then
    log "make already present"
    return
  fi
  # use brew in macOS and apt-get in Linux;
  if have brew; then
    install_make_brew
  elif have apt-get; then
    install_make_apt
  else
    die "no known package manager to install make"
  fi
}

install_make_brew() {
  log "installing make via brew"
  brew install make
}

install_make_apt() {
  log "installing make via apt-get"
  apt-get update -qq
  apt-get install -y -qq make
}

# --- system phase helpers (root only; no sudo here) -------------------------

# Move a downloaded binary onto PATH. The system phase is always root, so a
# plain mv is correct; we keep the writable-dir check for the macOS `all` path
# where this is reached via brew-installed equivalents (so it is unused there)
# but harmless if a future caller invokes it unprivileged.
install_bin() {
  local src dst
  src="$1"; dst="/usr/local/bin/$2"
  chmod +x "$src"
  mv "$src" "$dst"
}

install_yq() {
  have yq && { log "yq already present"; return; }
  local os arch
  os="$1"; arch="$(yq_arch)"
  log "installing yq $YQ_VERSION"
  curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${os}_${arch}" \
    -o /tmp/yq && install_bin /tmp/yq yq
}

install_gitleaks() {
  have gitleaks && { log "gitleaks already present"; return; }
  local osname arch
  osname="$1"; arch="$(asset_arch)"
  log "installing gitleaks $GITLEAKS_VERSION"
  curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_${osname}_${arch}.tar.gz" \
    | tar -xz -C /tmp gitleaks && install_bin /tmp/gitleaks gitleaks
}

# Put nvm-installed Node on PATH for ALL login shells — including the
# NON-interactive `bash -lc` the launchers use (multipass exec / ssh). Such a shell
# sources /etc/profile(.d) but NOT ~/.bashrc, where nvm's init lives, so without
# this `node` is absent there, and a tool with a `#!/usr/bin/env node` shebang
# fails or falls back to another runtime. This makes the exec context match an
# interactive shell. POSIX-sh safe; a no-op for users without ~/.nvm (e.g. root,
# or WITH_NODE=0). Root-only; idempotent.
write_node_login_path() {
  cat > /etc/profile.d/node-path.sh <<'EOF'
# Managed by tools/sandbox/provision.sh — nvm Node on PATH for login shells.
if [ -d "$HOME/.nvm/versions/node" ]; then
  for _d in "$HOME"/.nvm/versions/node/*/bin; do
    [ -d "$_d" ] && PATH="$_d:$PATH"
  done
  export PATH
fi
EOF
  chmod 0644 /etc/profile.d/node-path.sh
}

# Install the Ubuntu/Debian SYSTEM toolchain. Root-only; no bun here.
system_ubuntu() {
  log "installing system toolchain (apt + /usr/local/bin binaries)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  # openssh-client → git clone over SSH on a bare host; rsync → secrets copy for the
  # SSH-host sandbox (tools/sandbox/launch-remote.sh). unzip → bun installer.
  apt-get install -y -qq curl ca-certificates git jq yamllint shellcheck unzip openssh-client rsync
  install_yq linux
  install_gitleaks linux
  install_make
  write_node_login_path
  if [ "${SKIP_DOCKER:-0}" != "1" ]; then
    if ! have docker; then
      # docker.io = engine + CLI; docker-compose-v2 = the `docker compose`
      # subcommand (docker.io alone ships NO compose plugin, so
      # `docker compose --env-file …` fails with "unknown flag").
      log "installing docker.io + docker-compose-v2 (a daemon + the compose plugin)"
      apt-get install -y -qq docker.io docker-compose-v2
    elif ! docker compose version >/dev/null 2>&1; then
      # Resume path: engine already present from a prior run but the compose
      # plugin is missing — add just the plugin so `docker compose` works.
      log "docker present but 'docker compose' missing — installing docker-compose-v2 plugin"
      apt-get install -y -qq docker-compose-v2
    fi
  fi
}

# --- phases -----------------------------------------------------------------

phase_system() {
  case "$(uname -s)" in
    Linux)
      [ "$(id -u)" -eq 0 ] || die "run as root: sudo bash provision.sh system"
      system_ubuntu
      ;;
    Darwin)
      die "no 'system' phase on macOS — use 'provision.sh all' (brew subset + bun)"
      ;;
    *) die "unsupported OS: $(uname -s)" ;;
  esac
}

phase_user() {
  case "$(uname -s)" in
    Linux)
      install_bun
      # Node/npm is a convenience next to bun (e.g. `npm login`). Installed into
      # the INVOKING user's ~/.nvm — so in the VM this is the `ubuntu` user, never
      # root. Opt out with WITH_NODE=0.
      # NOTE: a private npm registry's 401 is fixed by ~/.npmrc (staged via
      # --npmrc), NOT by installing npm — bun reads the same auth token.
      [ "${WITH_NODE:-1}" = "0" ] || install_npm
      ;;
    Darwin)
      have brew || die "Homebrew required on macOS — install from https://brew.sh then re-run."
      install_npm
      install_bun
      ;;
    *) die "unsupported OS: $(uname -s)" ;;
  esac
}

# Run the system phase, elevating with sudo only when not already root. Used by
# the `all` convenience target so a manual operator does not pre-`sudo`.
run_system_elevated() {
  if [ "$(id -u)" -eq 0 ]; then
    phase_system
  elif have sudo; then
    log "elevating to root for the system phase (sudo)"
    sudo BUN_VERSION="$BUN_VERSION" GITLEAKS_VERSION="$GITLEAKS_VERSION" \
      YQ_VERSION="$YQ_VERSION" SKIP_DOCKER="${SKIP_DOCKER:-0}" \
      bash "$HERE/provision.sh" system
  else
    die "need root for the system phase and sudo is unavailable — run: sudo bash provision.sh system"
  fi
}

phase_all() {
  case "$(uname -s)" in
    Linux)
      run_system_elevated
      phase_user
      ;;
    Darwin)
      # macOS has no root system phase: provision the brew lint subset directly
      # (unprivileged), then bun. This is the dev path with caveats.
      warn "macOS = dev/tooling tier only: no Linux-only tools."
      have brew || die "Homebrew required on macOS — install from https://brew.sh then re-run."
      log "provisioning macOS lint subset via brew"
      local pkg
      for pkg in jq yamllint shellcheck yq gitleaks; do
        have "$pkg" || brew install "$pkg"
      done
      install_bun
      have docker || warn "docker not found — install Docker Desktop manually for the quick-compose path."
      ;;
    *) die "unsupported OS: $(uname -s)" ;;
  esac
}

verify() {
  log "verifying toolchain"
  local missing=0 t
  for t in bun git jq yamllint shellcheck yq gitleaks; do
    if have "$t"; then
      log "  ok  $t"
    else
      warn "  MISSING $t"; missing=1
    fi
  done
  [ "$missing" -eq 0 ] || die "toolchain incomplete — see warnings above"
  log "toolchain ready (bun $(bun --version))"
}

usage() {
  cat >&2 <<'EOF'
usage: provision.sh [system|user|all]
  system   install SYSTEM packages only (root only; the one privileged stage)
  user     install bun into the invoking user's ~/.bun (no root)
  all      (default) system (via sudo if needed) then user
EOF
  exit 2
}

main() {
  local phase="${1:-all}"
  case "$phase" in
    system) phase_system ;;
    user)   phase_user; verify ;;
    all)    phase_all; verify ;;
    -h|--help|help) usage ;;
    *) warn "unknown phase: $phase"; usage ;;
  esac
}

main "$@"
