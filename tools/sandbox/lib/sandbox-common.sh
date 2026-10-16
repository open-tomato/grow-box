#!/usr/bin/env bash
# Shared, transport-agnostic core for the Grow Box sandbox launchers.
# SOURCED by tools/sandbox/launch-vm.sh (multipass transport) and launch-remote.sh
# (ssh transport). It sets NO shell options — a sourced library must not leak
# set -e/-u into its callers; each entrypoint sets its own.
#
# Provides: logging (log/warn/die/have), shell quoting (quote_arg), the repo table
# (parse_repo_rows, load_repos, repo_optnames), GitHub auth (resolve_token, deploy-key
# register/delete, run_cleanup), credential staging (ensure_stage + all stage_*), and
# the transport-parameterized runner run_cmd, which takes the NAME of an exec function
# so callers supply the transport: multipass exec / ssh.
#
# Frontends MUST set before calling staging/runners:
#   SANDBOX_NAME   instance name (VM name or ssh alias) — keys the staging dir + log text
# Optional: SANDBOX_LOG_TAG (log prefix), SANDBOX_CONFIG_DIR, SANDBOX_GH_TOKEN_FILE,
#           SANDBOX_NPMRC, SANDBOX_BRANCH.
# Repo table: SANDBOX_REPOS or SANDBOX_REPOS_FILE (see load_repos).
# Run step:   SANDBOX_RUN_CMD, SANDBOX_RUN_DIR (see run_cmd).
# Never sources a secret file — tokens are read with cat only.

# tools/sandbox — used by stage_scripts to find provision.sh/setup-repos.sh/.bun-version.
SANDBOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- repo table -------------------------------------------------------------
# Each row: "owner|repo|optname". owner/repo are the GitHub coordinates; optname is
# the clone dir under the box user's $HOME (~/<optname>), the /opt symlink name
# (/opt/<optname>), the deploy-key basename and the ssh alias (gh-<optname>).
# Filled by load_repos from SANDBOX_REPOS or SANDBOX_REPOS_FILE; there are no
# default rows. setup-repos.sh carries its own copy of the parser, because it runs
# on the box without this library.
REPOS=""

CONFIG_DIR="${SANDBOX_CONFIG_DIR:-$HOME/.config/grow-box-sandbox}"
TOKEN_FILE="${SANDBOX_GH_TOKEN_FILE:-$CONFIG_DIR/gh_token}"
NPMRC_PATH="${SANDBOX_NPMRC:-}"
# Optional git branch to check out for the cloned repos (default: each repo's default
# branch, i.e. main). Staged as a `branch` file so setup-repos.sh checks it out on both
# the VM and remote paths. Lets a converge test THIS branch's code, not just main.
SANDBOX_BRANCH="${SANDBOX_BRANCH:-}"
CREATED_KEYS_FILE="$CONFIG_DIR/created-keys.txt"

log()  { printf '\033[36m[%s]\033[0m %s\n' "${SANDBOX_LOG_TAG:-sandbox}" "$*"; }
warn() { printf '\033[33m[%s] WARN\033[0m %s\n' "${SANDBOX_LOG_TAG:-sandbox}" "$*" >&2; }
die()  { printf '\033[31m[%s] ERROR\033[0m %s\n' "${SANDBOX_LOG_TAG:-sandbox}" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Single-quote a string for safe embedding in a shell command that is re-parsed
# (ssh joins its command words and re-parses them in the remote login shell).
quote_arg() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# --- repo table parsing -----------------------------------------------------

# Strip leading and trailing whitespace from $1.
trim_ws() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Parse repo rows from $1 into normalized "owner|repo|optname" lines on stdout.
# Rows are separated by newlines or commas; blank rows and `#` comments are
# skipped; whitespace around fields is ignored. A malformed row (not exactly three
# fields, an empty field, or a character outside [A-Za-z0-9._-]) warns on stderr
# and returns 1. optname must start with a letter or digit: it becomes a path under
# $HOME and /opt. The loop runs in a pipeline subshell, so its variables stay local.
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

# Fill REPOS from SANDBOX_REPOS (inline rows) or SANDBOX_REPOS_FILE (a file of
# rows). Setting both is refused, so the table always has one source. Neither set
# leaves REPOS empty, and the clone steps are skipped. Dies on a malformed row or
# an unreadable file.
load_repos() {
  local raw=""
  if [ -n "${SANDBOX_REPOS:-}" ] && [ -n "${SANDBOX_REPOS_FILE:-}" ]; then
    die "set SANDBOX_REPOS or SANDBOX_REPOS_FILE, not both"
  fi
  if [ -n "${SANDBOX_REPOS:-}" ]; then
    raw="$SANDBOX_REPOS"
  elif [ -n "${SANDBOX_REPOS_FILE:-}" ]; then
    [ -r "$SANDBOX_REPOS_FILE" ] || die "SANDBOX_REPOS_FILE not readable: $SANDBOX_REPOS_FILE"
    raw="$(cat "$SANDBOX_REPOS_FILE")"
  fi
  REPOS="$(parse_repo_rows "$raw")" || die "invalid repo table (see the warning above)"
}

# Print the optname column of the rows in $1 (default: REPOS), one per line.
repo_optnames() {
  printf '%s\n' "${1-$REPOS}" | while IFS='|' read -r _ _ optname; do
    [ -n "$optname" ] && printf '%s\n' "$optname"
  done
}

# Resolve the GitHub token used ON THE HOST to register deploy keys, without ever
# sourcing a file. Order: env, gh, file. This token never goes to the box: the token
# fallback reads only an explicit token (resolve_fallback_token).
resolve_token() {
  if [ -n "${GH_TOKEN:-}" ]; then
    printf '%s' "$GH_TOKEN"; return 0
  fi
  if have gh && gh auth token >/dev/null 2>&1; then
    gh auth token; return 0
  fi
  if [ -f "$TOKEN_FILE" ]; then
    cat "$TOKEN_FILE"; return 0
  fi
  return 1
}

# The token the opt-in fallback copies to the box: only one the operator named
# explicitly, GH_TOKEN or the file SANDBOX_GH_TOKEN_FILE. Never `gh auth token`
# (usually a full-scope OAuth token) and never the default token file.
resolve_fallback_token() {
  if [ -n "${GH_TOKEN:-}" ]; then
    printf '%s' "$GH_TOKEN"; return 0
  fi
  if [ -n "${SANDBOX_GH_TOKEN_FILE:-}" ] && [ -f "$SANDBOX_GH_TOKEN_FILE" ]; then
    cat "$SANDBOX_GH_TOKEN_FILE"; return 0
  fi
  return 1
}

# True when the operator opted in to the token fallback.
token_fallback_allowed() { [ "${SANDBOX_ALLOW_TOKEN_FALLBACK:-0}" = "1" ]; }

# --- deploy-key registration ------------------------------------------------

# Register a public key as a read-only deploy key. Echoes the created key id on
# success; returns non-zero on failure. Prefers gh; falls back to curl.
register_deploy_key() {
  local owner="$1" repo="$2" title="$3" pubkey="$4" token="$5" resp id
  if have gh; then
    resp="$(GH_TOKEN="$token" gh api -X POST "repos/$owner/$repo/keys" \
      -f title="$title" -f key="$pubkey" -F read_only=true 2>/dev/null)" || return 1
  else
    resp="$(curl -fsSL -X POST \
      -H "Authorization: Bearer $token" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/$owner/$repo/keys" \
      -d "$(printf '{"title":%s,"key":%s,"read_only":true}' \
            "$(json_str "$title")" "$(json_str "$pubkey")")" 2>/dev/null)" || return 1
  fi
  # Extract the numeric id from the JSON response (no jq dependency on host).
  id="$(printf '%s' "$resp" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n1)"
  [ -n "$id" ] || return 1
  printf '%s' "$id"
}

# Minimal JSON string encoder (quotes + escapes backslash and double quote).
json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

delete_deploy_key() {
  local owner="$1" repo="$2" id="$3" token="$4"
  if have gh; then
    GH_TOKEN="$token" gh api -X DELETE "repos/$owner/$repo/keys/$id" >/dev/null 2>&1
  else
    curl -fsSL -X DELETE \
      -H "Authorization: Bearer $token" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/$owner/$repo/keys/$id" >/dev/null 2>&1
  fi
}

# --- cleanup mode -----------------------------------------------------------

run_cleanup() {
  local token
  token="$(resolve_token)" || die "no GitHub token available for cleanup (see usage)"
  [ -f "$CREATED_KEYS_FILE" ] || { log "no created-keys record at $CREATED_KEYS_FILE — nothing to clean"; exit 0; }
  log "deleting deploy keys recorded in $CREATED_KEYS_FILE"
  local owner repo id
  # Record format: "owner|repo|id"
  while IFS='|' read -r owner repo id; do
    [ -n "$owner" ] || continue
    if delete_deploy_key "$owner" "$repo" "$id" "$token"; then
      log "  deleted $owner/$repo key $id"
    else
      warn "  failed to delete $owner/$repo key $id (already gone?)"
    fi
  done < "$CREATED_KEYS_FILE"
  : > "$CREATED_KEYS_FILE"
  log "cleanup done"
}

# --- staging (idempotent) ---------------------------------------------------

# True if a usable deploy-key set is already staged: an ssh_config plus one
# <optname>.key per repo. Lets a re-run REUSE keys instead of registering new
# ones (avoids deploy-key accumulation on the repo).
deploy_keys_staged() {
  local staging="$1" owner repo optname
  [ -f "$staging/ssh_config" ] || return 1
  printf '%s\n' "$REPOS" | while IFS='|' read -r owner repo optname; do
    [ -n "$owner" ] || continue
    [ -f "$staging/$optname.key" ] || { echo missing; break; }
  done | grep -q missing && return 1
  return 0
}


# --- ssh-key (BYO) mode -----------------------------------------------------

# Validate the operator-supplied private key path: exists, readable, looks like a
# private key; warn (don't fail) on loose perms. bash 3.2-safe (no `stat -c`).
validate_ssh_key() {
  local key="$1" perms
  [ -n "$key" ] || die "SSH-KEY MODE: empty key path"
  [ -f "$key" ] || die "SSH-KEY MODE: key file not found: $key"
  [ -r "$key" ] || die "SSH-KEY MODE: key file not readable: $key"
  grep -q 'BEGIN .*PRIVATE KEY' "$key" 2>/dev/null \
    || die "SSH-KEY MODE: '$key' does not look like a private key (no 'BEGIN ... PRIVATE KEY')"
  # Portable perms read: BSD/macOS uses `stat -f %Lp`, GNU uses `stat -c %a`.
  perms="$(stat -f '%Lp' "$key" 2>/dev/null || stat -c '%a' "$key" 2>/dev/null || echo '')"
  case "$perms" in
    600|400|'') : ;;
    *) warn "key perms are $perms (looser than 600) — consider: chmod 600 $key" ;;
  esac
}

# Print the loud SSH-KEY MODE security warnings. Make the trade-off unmistakable.
warn_ssh_key_mode() {
  local key="$1"
  warn "SSH-KEY MODE (BYO key: $key)"
  warn "  This copies your PRIVATE SSH key into a throwaway VM (host staging dir + the VM's ~/.ssh)."
  warn "  A GitHub ACCOUNT ssh key grants full read+WRITE to every repo your account can reach —"
  warn "  far broader than the read-only deploy keys. Prefer those unless you specifically"
  warn "  need write or this convenience."
  warn "  Use a DEDICATED, easily-revocable key for the sandbox — not your primary key."
  warn "  NEVER hardcode the key path or contents in committed files, Makefiles, CI, or .env —"
  warn "  pass SANDBOX_SSH_KEY at runtime only."
  warn "  The key persists in the staging dir ($CONFIG_DIR/staging-$SANDBOX_NAME) AND the VM."
  warn "  'launch-vm.sh --destroy' removes the VM and the staging dir; launch-remote.sh --reset"
  warn "  removes it from the box. Revoke the key from GitHub when done."
}

# Stage the BYO private key into the deploy-key staging SHAPE so setup-repos.sh
# needs no change: copy the SAME key content to <staging>/<optname>.key for each
# repo and emit one `Host gh-<optname>` block into <staging>/ssh_config. No deploy
# keys are registered and no gh_token is written in this mode. Reads the repo
# table via a here-doc so the loop runs in THIS shell — bash 3.2-safe.
stage_ssh_key() {
  local staging="$1" key="$2" owner repo optname keypath
  validate_ssh_key "$key"
  warn_ssh_key_mode "$key"
  # Drop any prior deploy-key/token material so the mode is unambiguous.
  printf '%s\n' "$REPOS" | while IFS='|' read -r owner repo optname; do
    [ -n "$optname" ] || continue
    rm -f "$staging/$optname.key" "$staging/$optname.key.pub"
  done
  rm -f "$staging/gh_token"
  : > "$staging/ssh_config"
  while IFS='|' read -r owner repo optname; do
    [ -n "$owner" ] || continue
    keypath="$staging/$optname.key"
    cp "$key" "$keypath"
    chmod 600 "$keypath"
    {
      printf 'Host gh-%s\n' "$optname"
      printf '  HostName github.com\n'
      printf '  User git\n'
      printf '  IdentityFile ~/.ssh/%s.key\n' "$optname"
      printf '  IdentitiesOnly yes\n'
      printf '  StrictHostKeyChecking accept-new\n\n'
    } >> "$staging/ssh_config"
  done <<EOF
$REPOS
EOF
  log "BYO ssh key staged for $(printf '%s\n' "$REPOS" | grep -c '|') repo(s) — persistent in-box SSH git"
}

# Build deploy-key material into $staging. On any registration failure, returns
# non-zero; the caller stops, or falls back to the opt-in token mode. Reads the repo table via a
# here-string (not a pipe) so the loop runs in THIS shell and `return` aborts the
# whole function — bash 3.2-safe.
stage_deploy_keys() {
  local staging="$1" token="$2" stamp host
  host="$(hostname 2>/dev/null || echo sandbox-host)"
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
  : > "$staging/ssh_config"
  mkdir -p "$CONFIG_DIR"
  local owner repo optname keypath title id
  while IFS='|' read -r owner repo optname; do
    [ -n "$owner" ] || continue
    keypath="$staging/$optname.key"
    ssh-keygen -t ed25519 -N '' -C "sandbox-$optname" -f "$keypath" >/dev/null 2>&1 \
      || { warn "ssh-keygen failed for $optname"; return 1; }
    title="sandbox $host $stamp ($optname)"
    log "registering read-only deploy key for $owner/$repo"
    id="$(register_deploy_key "$owner" "$repo" "$title" "$(cat "$keypath.pub")" "$token")" \
      || { warn "deploy-key registration failed for $owner/$repo"; return 1; }
    # Record for cleanup (host-side).
    printf '%s|%s|%s\n' "$owner" "$repo" "$id" >> "$CREATED_KEYS_FILE"
    # ssh alias used by setup-repos.sh: gh-<optname>
    {
      printf 'Host gh-%s\n' "$optname"
      printf '  HostName github.com\n'
      printf '  User git\n'
      printf '  IdentityFile ~/.ssh/%s.key\n' "$optname"
      printf '  IdentitiesOnly yes\n'
      printf '  StrictHostKeyChecking accept-new\n\n'
    } >> "$staging/ssh_config"
    # The public key is not needed inside the VM.
    rm -f "$keypath.pub"
  done <<EOF
$REPOS
EOF
}

# Stage the explicit fallback token (opt-in only; see ensure_stage).
stage_token() {
  local staging="$1" token="$2" optname owner repo
  # Drop any partial deploy-key material.
  printf '%s\n' "$REPOS" | while IFS='|' read -r owner repo optname; do
    [ -n "$optname" ] || continue
    rm -f "$staging/$optname.key" "$staging/$optname.key.pub"
  done
  rm -f "$staging/ssh_config"
  printf '%s' "$token" > "$staging/gh_token"
  chmod 600 "$staging/gh_token"
  warn "token mode: the token you supplied (GH_TOKEN / SANDBOX_GH_TOKEN_FILE) is copied to the box"
  warn "  and stays there until --reset / --destroy. It can do whatever its scopes allow."
}

# --- npmrc (private npm registry auth) --------------------------------------

# Stage the host .npmrc into the secrets dir as `npmrc` (0600). setup-repos.sh
# installs it to ~/.npmrc on the box. If NPMRC_PATH is unset we reuse a
# previously-staged npmrc (resumable) or warn that private-registry installs may 401.
# Never sources the file — it is a credential, copied verbatim only.
stage_npmrc() {
  local staging="$1" perms
  if [ -n "$NPMRC_PATH" ]; then
    [ -f "$NPMRC_PATH" ] || die "--npmrc: file not found: $NPMRC_PATH"
    [ -r "$NPMRC_PATH" ] || die "--npmrc: file not readable: $NPMRC_PATH"
    perms="$(stat -f '%Lp' "$NPMRC_PATH" 2>/dev/null || stat -c '%a' "$NPMRC_PATH" 2>/dev/null || echo '')"
    case "$perms" in 600|400|'') : ;; *) warn "npmrc perms are $perms (looser than 600)" ;; esac
    cp "$NPMRC_PATH" "$staging/npmrc"
    chmod 600 "$staging/npmrc"
    warn "npmrc: a registry auth token WILL transit into the VM via the mount (~ubuntu/.npmrc)"
    log "staged .npmrc from $NPMRC_PATH — bun/npm will authenticate to the private registry" >&2
  elif [ -f "$staging/npmrc" ]; then
    log "reusing previously-staged .npmrc in $staging" >&2
  else
    warn "no .npmrc staged — installs from a private npm registry will fail with 401."
    warn "  pass --npmrc <path> (or SANDBOX_NPMRC=<path>) holding the registry's auth token."
  fi
}

# Re-stage the bootstrap scripts alongside the secrets so cloud-init/bootstrap
# run them from the mount — single source of truth (these repo files), no inline
# copy that could drift. ALWAYS run, so updated scripts propagate on re-run.
stage_scripts() {
  local staging="$1"
  cp "$SANDBOX_DIR/provision.sh"   "$staging/provision.sh"
  cp "$SANDBOX_DIR/setup-repos.sh" "$staging/setup-repos.sh"
  # provision.sh reads ../.bun-version relative to its own dir. The in-VM
  # bootstrap reconstructs a tools/sandbox/ layout from these flat files so that
  # read resolves; carry the pin alongside them.
  if [ -f "$SANDBOX_DIR/../.bun-version" ]; then
    cp "$SANDBOX_DIR/../.bun-version" "$staging/.bun-version"
  fi
  chmod +x "$staging/provision.sh" "$staging/setup-repos.sh"
}

# Stage the repo table as a `repos` file (normalized owner|repo|optname rows), which
# setup-repos.sh reads on the box. Clears a stale file when the table is empty, so a
# re-run without SANDBOX_REPOS clones nothing. ALWAYS run (like stage_scripts).
stage_repos() {
  local staging="$1"
  if [ -n "$REPOS" ]; then
    printf '%s\n' "$REPOS" > "$staging/repos"
  else
    rm -f "$staging/repos"
  fi
}

# Stage the requested git branch as a `branch` file (setup-repos.sh reads it and checks
# it out per repo, best-effort). Clears a stale file when no branch is requested, so a
# re-run without branch= reverts to the repo default. ALWAYS run (like stage_scripts).
stage_branch() {
  local staging="$1"
  if [ -n "$SANDBOX_BRANCH" ]; then
    printf '%s' "$SANDBOX_BRANCH" > "$staging/branch"
    log "staging branch '$SANDBOX_BRANCH' — cloned repos will check it out (default otherwise)" >&2
  else
    rm -f "$staging/branch"
  fi
}

# Ensure the stable per-VM staging dir exists with credentials + scripts.
# Echoes the staging path on stdout. Reuses staged deploy keys; never reuses a
# staged token; always re-stages scripts. In SSH-KEY MODE ($2 = key path) the BYO key always wins and is
# re-staged each run (resumable); token resolution is skipped by the caller.
ensure_stage() {
  local token="$1" ssh_key="${2:-}" staging
  staging="$CONFIG_DIR/staging-$SANDBOX_NAME"
  mkdir -p "$staging"
  chmod 700 "$staging"
  # The whole staging dir is copied or mounted onto the box, so a token from an
  # earlier run (perhaps a full-scope one) must never stay in it. Only the opt-in
  # fallback below writes a token, freshly, from GH_TOKEN / SANDBOX_GH_TOKEN_FILE.
  rm -f "$staging/gh_token"

  if [ -z "$REPOS" ]; then
    log "no repos configured (SANDBOX_REPOS / SANDBOX_REPOS_FILE) — skipping the clone steps" >&2
  elif [ -n "$ssh_key" ]; then
    # SSH-KEY MODE takes precedence — re-stage every run (idempotent).
    log "staging BYO ssh key in $staging (ssh-key mode — precedence over deploy-key/token)" >&2
    stage_ssh_key "$staging" "$ssh_key" 1>&2
  elif deploy_keys_staged "$staging"; then
    log "reusing existing deploy keys in $staging (no new key registered)" >&2
  else
    log "staging credentials in $staging (deploy-key mode)" >&2
    # Redirect stdout to stderr around the stagers: this function returns the
    # staging path on stdout, and the stagers' `log` helper prints to stdout.
    if stage_deploy_keys "$staging" "$token" 1>&2; then
      log "deploy-key mode ready — token stays on host" >&2
    elif ! token_fallback_allowed; then
      die "deploy-key registration failed (see above), and the token fallback is off.
  Fix the registration (the token needs admin rights on each repo to add a deploy key),
  or opt in to cloning with a token, which is COPIED TO THE BOX:
    SANDBOX_ALLOW_TOKEN_FALLBACK=1 with GH_TOKEN=... or SANDBOX_GH_TOKEN_FILE=<file>"
    else
      local fallback
      fallback="$(resolve_fallback_token)" || die "SANDBOX_ALLOW_TOKEN_FALLBACK=1 needs an explicit token: set GH_TOKEN or SANDBOX_GH_TOKEN_FILE (the \`gh auth token\` token is never copied to the box)"
      warn "deploy-key registration failed — falling back to token mode (SANDBOX_ALLOW_TOKEN_FALLBACK=1)"
      stage_token "$staging" "$fallback" 1>&2
    fi
  fi

  # Registry auth for bun/npm (independent of the git auth mode above).
  stage_npmrc "$staging"

  # Always refresh the scripts so updates propagate on re-run.
  log "re-staging bootstrap scripts (provision.sh, setup-repos.sh, .bun-version)" >&2
  stage_scripts "$staging" 1>&2
  stage_repos "$staging" 1>&2
  stage_branch "$staging" 1>&2

  printf '%s' "$staging"
}

# Check that $1 is this run's staging dir: a directory directly under
# $CONFIG_DIR/staging-<name>, with no `..` in the path. Dies otherwise. Every caller
# that copies or mounts staging checks first, so a failed staging step (an empty
# path) can never turn into copying `/` or another directory to the box.
require_staging_dir() {
  local src="$1" what="$2"
  case "$src" in
    */../*|*/..|../*) die "$what: refusing '$src' — the path contains '..'" ;;
  esac
  case "$src" in
    "$CONFIG_DIR"/staging-?*) : ;;
    *) die "$what: refusing '$src' — only a staging dir under $CONFIG_DIR/staging-<name> is copied to the box" ;;
  esac
  case "${src#"$CONFIG_DIR"/staging-}" in
    */*) die "$what: refusing '$src' — not a staging dir itself" ;;
  esac
  [ -n "$CONFIG_DIR" ] && [ -d "$src" ] || die "$what: refusing '$src' — no such staging dir"
}

# --- transport-parameterized runner -----------------------------------------
# <exec_fn> is the NAME of a function taking one command string and running it in a
# login shell through the frontend's transport (multipass exec / ssh), streaming.

# The directory the run step runs in: SANDBOX_RUN_DIR, else /opt/<optname> of the
# first repo row (the symlink setup-repos.sh creates). Empty when neither exists.
run_dir() {
  if [ -n "${SANDBOX_RUN_DIR:-}" ]; then
    printf '%s' "$SANDBOX_RUN_DIR"
    return 0
  fi
  local first
  first="$(repo_optnames | head -n1)"
  [ -n "$first" ] && printf '/opt/%s' "$first"
  return 0
}

# Run SANDBOX_RUN_CMD on the box inside run_dir (the login shell's home directory
# when run_dir is empty). An unset or empty SANDBOX_RUN_CMD skips the step with one
# log line and returns 0. Otherwise returns the command's own exit code.
run_cmd() {
  local ex="$1" dir cmd rc=0 rule
  if [ -z "${SANDBOX_RUN_CMD:-}" ]; then
    log "no SANDBOX_RUN_CMD set — skipping the run step"
    return 0
  fi
  dir="$(run_dir)"
  cmd="$SANDBOX_RUN_CMD"
  [ -n "$dir" ] && cmd="cd $(quote_arg "$dir") && $SANDBOX_RUN_CMD"
  rule="----------------------------------------------------------------------"
  log "running '$SANDBOX_RUN_CMD' in ${dir:-the login home} on '$SANDBOX_NAME' (stream below; skip with --no-run)"
  printf '\033[2m%s\033[0m\n' "$rule"
  "$ex" "$cmd" || rc=$?
  printf '\033[2m%s\033[0m\n' "$rule"
  if [ "$rc" -eq 0 ]; then
    log "run step PASSED on '$SANDBOX_NAME'"
  else
    warn "run step FAILED (exit $rc) on '$SANDBOX_NAME' — left up for inspection"
  fi
  return "$rc"
}
