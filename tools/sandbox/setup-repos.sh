#!/usr/bin/env bash
# Box-side repo setup — clone the sandbox repos into the invoking user's $HOME and
# symlink each into /opt (`git clone ~/<optname>`, then
# `sudo ln -s ~/<optname> /opt/<optname>`).
#
# Runs AS the unprivileged box user (e.g. `ubuntu`). The ONLY privileged action
# is the /opt symlink (one `sudo ln -s`, idempotently skipped if present).
#
# The repo table (rows "owner|repo|optname", separated by newlines or commas) comes
# from SANDBOX_REPOS, else from the file SANDBOX_REPOS_FILE, else from the `repos`
# file the host staged into the secrets dir. With no rows, the clone step is skipped.
#
# Secrets come from a mounted or copied directory (the HOST staged them there;
# see tools/sandbox/launch-vm.sh). Two auth modes, auto-detected by contents:
#
#   DEPLOY-KEY mode (preferred): per-repo private keys `<optname>.key` plus an
#     `ssh_config` snippet. Keys are copied to ~/.ssh (chmod 600), the ssh_config
#     is installed, and clones use the per-repo SSH host alias. The GitHub token
#     never enters the VM in this mode.
#
#   TOKEN-FALLBACK mode (opt-in on the host): a `gh_token` file holding the token
#     the operator supplied. Clones via `gh` if
#     present, else HTTPS with a short-lived credential helper; the remote is
#     reset to the plain https URL afterwards so the token is NOT persisted in
#     .git/config.
#
# Idempotent and re-runnable. Never sources/`. `s a secret file — tokens are read
# with `cat` only.
set -euo pipefail

SECRETS_DIR="${SANDBOX_SECRETS_DIR:-/run/sandbox-secrets}"
SSH_DIR="$HOME/.ssh"

log()  { printf '\033[36m[setup-repos]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[setup-repos] WARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[setup-repos] ERROR\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- repo table -------------------------------------------------------------
# Same format and rules as parse_repo_rows in lib/sandbox-common.sh; copied here
# because this script runs on the box without that library.

trim_ws() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Print normalized "owner|repo|optname" rows parsed from $1; warn and return 1 on a
# malformed row. The loop runs in a pipeline subshell, so its variables stay local.
parse_repo_rows() {
  printf '%s\n' "$1" | tr ',' '\n' | while IFS= read -r row; do
    row="$(trim_ws "${row%%#*}")"
    [ -n "$row" ] || continue
    IFS='|' read -r owner repo optname extra <<EOF
$row
EOF
    owner="$(trim_ws "$owner")"; repo="$(trim_ws "$repo")"; optname="$(trim_ws "$optname")"
    bad=0
    [ -n "$owner" ] && [ -n "$repo" ] && [ -n "$optname" ] && [ -z "$extra" ] || bad=1
    case "$owner$repo$optname" in *[!A-Za-z0-9._-]*) bad=1 ;; esac
    case "$repo" in .|..) bad=1 ;; esac
    case "$optname" in [!A-Za-z0-9]*) bad=1 ;; esac
    if [ "$bad" = "1" ]; then
      warn "malformed repo row '$row' (want owner|repo|optname)"
      exit 1
    fi
    printf '%s|%s|%s\n' "$owner" "$repo" "$optname"
  done
}

# Print the repo table: SANDBOX_REPOS, else SANDBOX_REPOS_FILE, else the staged
# $SECRETS_DIR/repos. Prints nothing when none is set. Dies on a malformed row.
load_repos() {
  local raw="" file="${SANDBOX_REPOS_FILE:-}"
  if [ -n "${SANDBOX_REPOS:-}" ] && [ -n "$file" ]; then
    die "set SANDBOX_REPOS or SANDBOX_REPOS_FILE, not both"
  fi
  if [ -z "${SANDBOX_REPOS:-}" ] && [ -z "$file" ] && [ -f "$SECRETS_DIR/repos" ]; then
    file="$SECRETS_DIR/repos"
  fi
  if [ -n "${SANDBOX_REPOS:-}" ]; then
    raw="$SANDBOX_REPOS"
  elif [ -n "$file" ]; then
    [ -r "$file" ] || die "repo table file not readable: $file"
    raw="$(cat "$file")"
  fi
  parse_repo_rows "$raw" || die "invalid repo table (see the warning above)"
}

# Symlink ~/<localdir> into /opt/<optname>; the sole privileged step. Idempotent.
link_opt() {
  local localdir="$1" optname="$2" target dst
  target="$HOME/$localdir"
  dst="/opt/$optname"
  if [ -L "$dst" ] || [ -e "$dst" ]; then
    log "  /opt/$optname already exists — leaving as-is"
    return 0
  fi
  log "  linking $dst -> $target (sudo)"
  sudo ln -s "$target" "$dst"
}

# --- deploy-key mode --------------------------------------------------------

deploy_key_present() {
  # True if at least one expected per-repo key file exists in the mount.
  local repos="$1" owner repo optname
  printf '%s\n' "$repos" | while IFS='|' read -r owner repo optname; do
    [ -n "$owner" ] || continue
    [ -f "$SECRETS_DIR/$optname.key" ] && { echo yes; break; }
  done | grep -q yes
}

install_ssh_config() {
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  if [ -f "$SECRETS_DIR/ssh_config" ]; then
    # Install our snippet into a dedicated include file; do not clobber a
    # user-managed ~/.ssh/config. Reference it from config via Include.
    cp "$SECRETS_DIR/ssh_config" "$SSH_DIR/sandbox_config"
    chmod 600 "$SSH_DIR/sandbox_config"
    local inc="Include ~/.ssh/sandbox_config"
    if [ ! -f "$SSH_DIR/config" ] || ! grep -qF "$inc" "$SSH_DIR/config"; then
      # Include must precede host-specific blocks; prepend it.
      if [ -f "$SSH_DIR/config" ]; then
        printf '%s\n%s' "$inc" "$(cat "$SSH_DIR/config")" > "$SSH_DIR/config.new"
        mv "$SSH_DIR/config.new" "$SSH_DIR/config"
      else
        printf '%s\n' "$inc" > "$SSH_DIR/config"
      fi
      chmod 600 "$SSH_DIR/config"
    fi
    log "installed ssh_config snippet (~/.ssh/sandbox_config)"
  else
    warn "deploy-key mode but no ssh_config snippet found — clones may fail"
  fi
}

install_deploy_key() {
  local optname="$1" key
  key="$SECRETS_DIR/$optname.key"
  [ -f "$key" ] || die "missing deploy key for $optname: $key"
  mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR"
  cp "$key" "$SSH_DIR/$optname.key"
  chmod 600 "$SSH_DIR/$optname.key"
}

# Clone via the per-repo SSH host alias defined in the ssh_config snippet.
# Convention: alias is `gh-<optname>` (see launch-vm.sh).
clone_deploy_key() {
  local owner="$1" repo="$2" localdir="$3" optname="$4" dest
  dest="$HOME/$localdir"
  install_deploy_key "$optname"
  if [ -d "$dest/.git" ]; then
    # Already cloned: converge toward latest, best-effort. ff-only never rewrites
    # or discards local work — it no-ops on divergence (warned), so a re-run is
    # safe and resumable.
    log "  ~/$localdir already cloned — git pull --ff-only (best effort)"
    git -C "$dest" pull --ff-only >/dev/null 2>&1 \
      || warn "  ~/$localdir: pull --ff-only skipped (diverged or offline) — leaving as-is"
    return 0
  fi
  log "  cloning $owner/$repo via gh-$optname -> ~/$localdir"
  git clone "git@gh-$optname:$owner/$repo.git" "$dest"
}

# --- token-fallback mode ----------------------------------------------------

clone_token() {
  local owner="$1" repo="$2" localdir="$3" token="$4" dest
  dest="$HOME/$localdir"
  if [ -d "$dest/.git" ]; then
    # Already cloned: converge toward latest via the transient credential helper
    # (token never persisted). ff-only is non-destructive, so a re-run is safe.
    log "  ~/$localdir already cloned — git pull --ff-only (best effort)"
    git -C "$dest" \
      -c "credential.helper=!f() { printf 'username=x-access-token\npassword=%s\n' \"$token\"; }; f" \
      pull --ff-only >/dev/null 2>&1 \
      || warn "  ~/$localdir: pull --ff-only skipped (diverged or offline) — leaving as-is"
    return 0
  fi
  if have gh; then
    log "  cloning $owner/$repo via gh -> ~/$localdir"
    GH_TOKEN="$token" gh repo clone "$owner/$repo" "$dest"
  else
    log "  cloning $owner/$repo via https (token, not persisted) -> ~/$localdir"
    # Pass the token through a transient credential helper so it never lands in
    # the committed remote URL or shell history. Reset the remote afterwards.
    git -c "credential.helper=!f() { printf 'username=x-access-token\npassword=%s\n' \"$token\"; }; f" \
      clone "https://github.com/$owner/$repo.git" "$dest"
    git -C "$dest" remote set-url origin "https://github.com/$owner/$repo.git"
  fi
}

# --- branch checkout --------------------------------------------------------

# If a branch was staged (SANDBOX_BRANCH / <secrets>/branch), check it out for the repo
# at $dest — best-effort, per repo: a full clone fetched all branches, so this works
# when the branch exists in that repo; otherwise stay on the default (warned). Lets a
# converge validate THIS branch's code instead of only the default (main).
checkout_branch() {
  local dest="$1" branch=""
  [ -n "${SANDBOX_BRANCH:-}" ] && branch="$SANDBOX_BRANCH"
  [ -z "$branch" ] && [ -f "$SECRETS_DIR/branch" ] && branch="$(cat "$SECRETS_DIR/branch")"
  [ -n "$branch" ] || return 0
  [ -d "$dest/.git" ] || return 0
  if git -C "$dest" checkout "$branch" >/dev/null 2>&1; then
    log "  checked out branch '$branch' in $(basename "$dest")"
  else
    warn "  branch '$branch' not found in $(basename "$dest") — staying on the default branch"
  fi
}

# --- npmrc (private npm registry auth) --------------------------------------

# First line of every ~/.npmrc this script writes. launch-remote.sh --reset removes
# ~/.npmrc only when this exact line is present, so it never deletes one it did not
# write. Keep the two copies identical.
NPMRC_MARKER="# written by Grow Box (setup-repos.sh); --reset removes this file"

# Install the staged .npmrc (a private npm registry's auth token) into $HOME/.npmrc
# so bun and npm authenticate to that registry instead of 401ing. Idempotent: always
# refreshes from the mount. Copied verbatim after the marker line; never sourced.
# No-op if not staged.
install_npmrc() {
  [ -f "$SECRETS_DIR/npmrc" ] || { log "no .npmrc staged — skipping (private-scope installs may 401)"; return 0; }
  ( umask 077; { printf '%s\n' "$NPMRC_MARKER"; cat "$SECRETS_DIR/npmrc"; } > "$HOME/.npmrc" )
  chmod 600 "$HOME/.npmrc"
  log "installed ~/.npmrc from mount — bun/npm authenticated to the private registry"
}

# --- main -------------------------------------------------------------------

main() {
  have git || die "git not installed — run provision.sh system first"
  [ -d "$SECRETS_DIR" ] || die "secrets dir not found: $SECRETS_DIR (mount it; see launch-vm.sh)"

  install_npmrc

  local repos
  repos="$(load_repos)" || exit 1
  if [ -z "$repos" ]; then
    log "no repos configured (SANDBOX_REPOS / SANDBOX_REPOS_FILE / $SECRETS_DIR/repos) — skipping clone"
    return 0
  fi

  local mode=""
  if deploy_key_present "$repos"; then
    mode="deploy-key"
  elif [ -f "$SECRETS_DIR/gh_token" ]; then
    mode="token"
  else
    die "no credentials in $SECRETS_DIR — expected <optname>.key (+ ssh_config) or gh_token"
  fi
  log "auth mode: $mode"

  local token=""
  if [ "$mode" = "deploy-key" ]; then
    install_ssh_config
  else
    token="$(cat "$SECRETS_DIR/gh_token")"
    [ -n "$token" ] || die "gh_token file is empty"
  fi

  local owner repo optname
  printf '%s\n' "$repos" | while IFS='|' read -r owner repo optname; do
    [ -n "$owner" ] || continue
    log "repo: $owner/$repo -> ~/$optname -> /opt/$optname"
    if [ "$mode" = "deploy-key" ]; then
      clone_deploy_key "$owner" "$repo" "$optname" "$optname"
    else
      clone_token "$owner" "$repo" "$optname" "$token"
    fi
    checkout_branch "$HOME/$optname"
    link_opt "$optname" "$optname"
  done

  log "done — repos cloned into \$HOME and symlinked under /opt"
}

# Run main only when executed directly (lets tests source this file).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
