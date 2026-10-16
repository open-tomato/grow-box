#!/usr/bin/env bash
# Host-side SSH launcher for the Grow Box sandbox. Converges an ALREADY-EXISTING
# Ubuntu host reachable via `ssh <name>`, reusing lib/sandbox-common.sh (repo table,
# auth, staging, run_cmd). Where launch-vm.sh uses multipass create/mount/exec, this
# uses cloud-init-equivalent host prep, rsync/scp of the staged secrets, and ssh. No
# /etc/grow-box-sandbox marker is written on the host.
#
# CONVERGENT / IDEMPOTENT / RESUMABLE — re-run to pick up after a partial failure.
# Requires: `ssh <name>` works by pubkey (no prompt) and the box's <ip> is known.
#
# Modes:
#   launch-remote.sh --name N --ip I         converge (prep + provision + clone + run step)
#   launch-remote.sh --name N --ip I --regenerate   soft reset, then a fresh converge
#   launch-remote.sh --name N --reset        soft reset (repos/symlinks/secrets)
#   launch-remote.sh --name N --purge --confirm purge   full purge (also docker; no reinstall)
#   launch-remote.sh --cleanup               delete the deploy keys this tool created
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sandbox-common.sh
. "$HERE/lib/sandbox-common.sh"
# SANDBOX_LOG_TAG/SANDBOX_NAME are read only inside lib/sandbox-common.sh (log/warn/die,
# ensure_stage, run_cmd). The source= directive above resolves relative to shellcheck's
# invocation cwd, not this script's dir, so run from the repo root it can't statically
# see that cross-file use and flags these SC2034 — false positives (see launch-vm.sh).
# shellcheck disable=SC2034
SANDBOX_LOG_TAG=launch-remote

# --- config / flags ---------------------------------------------------------
NAME=""                       # ssh alias + identity + staging-dir key
IP=""                         # the box's known IPv4 (reported at the end of a converge)
SSH_KEY_PATH="${SANDBOX_SSH_KEY:-}"
# NPMRC_PATH inherited from the lib (SANDBOX_NPMRC); --npmrc overrides.
RUN_STEP="${SANDBOX_NO_RUN:+0}"; RUN_STEP="${RUN_STEP:-1}"
DO_RESET=0
DO_PURGE=0
DO_REGEN=0
CONFIRM=""
# Remote paths (under the ssh user's home; 0700). Copied fresh each run; --reset
# removes. Read by run_bootstrap and run_reset/run_purge.
SECRETS_REMOTE=".cache/grow-box-sandbox/secrets"
DEST_REMOTE=".cache/grow-box-sandbox/bootstrap"
SANDBOX_MARKER="/etc/grow-box-sandbox"
# First line setup-repos.sh writes into the ~/.npmrc it creates (keep identical).
NPMRC_MARKER="# written by Grow Box (setup-repos.sh); --reset removes this file"

# Sudo handling. A converge authenticates to root ~5× (prep ×3, provision-system,
# /opt symlink); on a password-sudo box that means 5 prompts, and silent-on-success
# steps look identical to a rejection. So on such a box we OFFER to install a
# TEMPORARY passwordless-sudo drop-in for the ssh user for the duration — removed at
# the end AND on failure/Ctrl-C (via the EXIT trap). --nopasswd-sudo pre-consents
# (and auto-removes, for automation). A NOPASSWD box is fully unattended already.
NOPASSWD_SUDO="${SANDBOX_NOPASSWD_SUDO:-0}"   # 1 = pre-consent to the temp NOPASSWD install
NOPASSWD_SUDOERS="/etc/sudoers.d/grow-box-sandbox"
NOPASSWD_INSTALLED=0                          # 1 once we've installed the drop-in
NOPASSWD_KEEP=0                               # 1 if the operator chose to keep it
SUDO_MODE=""                                  # cached remote sudo mode: nopasswd | askpass
RUSER=""                                      # the box's ssh user (for messaging)

usage() {
  cat >&2 <<EOF
usage: launch-remote.sh --name <ssh-alias> --ip <ip> [options]   converge the SSH host
       launch-remote.sh --name N --ip I --regenerate    soft reset, then a fresh converge
       launch-remote.sh --name N --reset                soft reset (repos/symlinks/secrets)
       launch-remote.sh --name N --purge --confirm purge  full purge (also docker; no reinstall)
       launch-remote.sh --cleanup                       delete the deploy keys this tool created

required: --name (the 'ssh <name>' alias; also identity + staging-dir key)
          --ip   (the box's IPv4; reported at the end of a converge)

options:
  --npmrc PATH        stage an .npmrc (auth for a private npm registry) onto the box
  --ssh-key PATH      BYO PRIVATE ssh key → persistent in-box git (see security notes)
  --no-run            do NOT run the run step (SANDBOX_RUN_CMD)
  --branch NAME       check out this branch in the cloned repos (default: main) — test
                        THIS branch's code on the box, not just main
  --nopasswd-sudo     pre-consent to a TEMPORARY passwordless-sudo drop-in for the
                        duration (auto-removed at the end); otherwise, on a password-sudo
                        box you're asked interactively

environment:
  SANDBOX_REPOS       repo rows "owner|repo|optname", separated by newlines or commas;
                        each is cloned to ~/<optname> and linked at /opt/<optname>
  SANDBOX_REPOS_FILE  a file of such rows (instead of SANDBOX_REPOS). Neither set: no clone
  SANDBOX_RUN_CMD     the command the run step runs on the box. Unset: the step is skipped
  SANDBOX_RUN_DIR     where it runs (default: /opt/<optname> of the first repo row)

sudo: a NOPASSWD box runs unattended. On a password-sudo box, converge authenticates to
root ~5× — a silent step that just closes the connection is a SUCCESS, not a failure. To
avoid the repeated prompts, accept the offer (or pass --nopasswd-sudo) to install a
temporary /etc/sudoers.d drop-in that is removed at the end and on failure/Ctrl-C.

IDEMPOTENT + RESUMABLE: re-run to converge after a partial failure.
auth precedence: --ssh-key (ssh-key) > deploy-key (token can register) > token fallback.
token fallback: off unless SANDBOX_ALLOW_TOKEN_FALLBACK=1; it copies the GH_TOKEN or
SANDBOX_GH_TOKEN_FILE token to the box (never the \`gh auth token\` token).
EOF
}

# Required-arg validator for converge.
require_converge_args() {
  [ -n "$NAME" ] || { warn "missing required --name (ssh alias)"; usage; exit 2; }
  [ -n "$IP" ]   || { warn "missing required --ip (box address)"; usage; exit 2; }
}

# --- SSH/scp transport ------------------------------------------------------
# CRUCIAL: unlike `multipass exec -- bash -lc "$1"` (argv, no re-parse), `ssh host …`
# JOINS its command words and re-parses them through the remote LOGIN shell. So the
# whole command is pre-quoted as ONE remote word with quote_arg (from the lib), or
# spaces/&&/pipes break.

# Login-shell exec, streaming (no capture) — matches multipass exec's bash -lc so
# /etc/profile.d (bun + node PATH) is sourced. quote_arg keeps $1 a single word.
rexec()     { ssh "$NAME" "bash -lc $(quote_arg "$1")"; }
rexec_tty() { ssh -t "$NAME" "bash -lc $(quote_arg "$1")"; }

# Auto-detect sudo: 'nopasswd' if `sudo -n true` works over ssh, else 'askpass'.
# Cached in SUDO_MODE (one probe per run; also flipped to nopasswd after we install a
# temporary drop-in, and back to askpass after we remove it).
remote_sudo_mode() {
  if [ -z "$SUDO_MODE" ]; then
    if ssh -o BatchMode=yes "$NAME" 'sudo -n true' >/dev/null 2>&1; then
      SUDO_MODE=nopasswd
    else
      SUDO_MODE=askpass
    fi
  fi
  echo "$SUDO_MODE"
}

# Run a command as root on the box, dispatching on the detected sudo mode.
rroot() {
  if [ "$(remote_sudo_mode)" = "nopasswd" ]; then
    ssh "$NAME" "sudo -n bash -lc $(quote_arg "$1")"
  else
    ssh -t "$NAME" "sudo bash -lc $(quote_arg "$1")"
  fi
}

# Choose the copy tool: rsync only if it's on the LOCAL host AND on the remote
# ($1 = 'yes'/'no' from a remote probe); otherwise scp.
pick_copy_tool() {
  if have rsync && [ "$1" = "yes" ]; then echo rsync; else echo scp; fi
}

# Mirror a local dir to the box. Probes the remote for rsync, then rsync-mirrors or
# falls back to scp -r. The remote dir's parent is created first. Only this tool's
# staging dir may be copied (require_staging_dir): rsync --delete of "/" or of any
# other dir would upload it to the box.
rcopy() {
  local src="$1" dst="$2" remote_rsync tool parent
  require_staging_dir "$src" "rcopy"
  parent="$(dirname "$dst")"
  ssh "$NAME" "mkdir -p '$parent'"
  remote_rsync="$(ssh -o BatchMode=yes "$NAME" 'command -v rsync >/dev/null 2>&1 && echo yes || echo no' 2>/dev/null)"
  tool="$(pick_copy_tool "${remote_rsync:-no}")"
  if [ "$tool" = "rsync" ]; then
    rsync -az --delete -e ssh "$src/" "$NAME:$dst/"
  else
    ssh "$NAME" "rm -rf '$dst'"
    scp -rq "$src" "$NAME:$dst"
  fi
}

# --- temporary passwordless sudo (throwaway box UX) -------------------------

# On a password-sudo box, offer to install a TEMPORARY NOPASSWD drop-in for the ssh
# user so the converge runs unattended (one password entry to install it). A NOPASSWD
# box needs nothing. Honors --nopasswd-sudo (pre-consent). Non-interactive + askpass +
# no flag → warn and proceed (rroot will still prompt, which won't work headless).
maybe_setup_nopasswd() {
  [ "$(remote_sudo_mode)" = "nopasswd" ] && { log "sudo: passwordless already active on '$NAME' — unattended."; return 0; }

  RUSER="$(rexec 'id -un' 2>/dev/null | tr -d '\r')"
  local do_install=0
  if [ "$NOPASSWD_SUDO" = "1" ]; then
    do_install=1
  elif [ -e /dev/tty ]; then
    warn "sudo on '$NAME' needs a password. A converge authenticates to root ~5× — and a"
    warn "  silent step that just closes the connection is a SUCCESS, not a failure."
    warn "  I can install a TEMPORARY passwordless-sudo drop-in for '$RUSER' for the duration."
    warn "  RISK: this grants '$RUSER' full NOPASSWD sudo until it's removed. It is removed at the"
    warn "  end AND on failure/Ctrl-C. Only accept on a THROWAWAY sandbox box you control."
    printf '\033[36m[launch-remote]\033[0m Install temporary passwordless sudo for %s? [y/N] ' "$RUSER" >&2
    local ans=""; read -r ans </dev/tty || ans=""
    case "$ans" in y|Y|yes|YES) do_install=1 ;; *) do_install=0 ;; esac
  else
    warn "sudo on '$NAME' needs a password but this run is non-interactive (no tty) — it will stall."
    warn "  Configure passwordless sudo on the box, or run interactively (with --nopasswd-sudo), then re-run."
    return 0
  fi

  if [ "$do_install" != "1" ]; then
    log "keeping password sudo — you'll be prompted per root step (a silent step that closes = success)."
    return 0
  fi

  log "installing $NOPASSWD_SUDOERS on '$NAME' (one sudo password now)…"
  # Safe: write to a temp file, validate with visudo, then install atomically 0440
  # root:root. Never leave an unvalidated file live in sudoers.d (a broken one wedges
  # ALL sudo). Runs as root via rroot (still askpass here → one prompt).
  if rroot 'u="${SUDO_USER:-$(logname 2>/dev/null)}"; t="$(mktemp)"; printf "%s ALL=(ALL) NOPASSWD:ALL\n" "$u" > "$t" && visudo -cf "$t" >/dev/null && install -m 0440 -o root -g root "$t" /etc/sudoers.d/grow-box-sandbox; r=$?; rm -f "$t"; exit $r'; then
    NOPASSWD_INSTALLED=1
    SUDO_MODE=nopasswd
    log "passwordless sudo installed for '$RUSER' — the rest of the run is unattended."
  else
    warn "failed to install the NOPASSWD drop-in on '$NAME' — falling back to per-step password prompts."
    SUDO_MODE=askpass
  fi
}

# Remove the temporary drop-in. Non-interactive (sudo is passwordless now). Idempotent.
remove_nopasswd() {
  [ "$NOPASSWD_INSTALLED" = "1" ] || return 0
  if ssh -o BatchMode=yes "$NAME" "sudo -n rm -f $NOPASSWD_SUDOERS" >/dev/null 2>&1; then
    log "removed the temporary passwordless-sudo drop-in ($NOPASSWD_SUDOERS) from '$NAME'."
  else
    warn "could NOT auto-remove $NOPASSWD_SUDOERS from '$NAME' — remove it by hand:"
    warn "    ssh $NAME 'sudo rm -f $NOPASSWD_SUDOERS'"
  fi
  NOPASSWD_INSTALLED=0
  SUDO_MODE=askpass
}

# End-of-run disposition: --nopasswd-sudo auto-removes; interactively, ask keep/remove.
finalize_nopasswd() {
  [ "$NOPASSWD_INSTALLED" = "1" ] || return 0
  if [ "$NOPASSWD_SUDO" = "1" ] || [ ! -e /dev/tty ]; then
    remove_nopasswd; return 0
  fi
  printf '\033[33m[launch-remote]\033[0m Keep the temporary passwordless-sudo drop-in on %s? [y/N] ' "$NAME" >&2
  local ans=""; read -r ans </dev/tty || ans=""
  case "$ans" in
    y|Y|yes|YES)
      NOPASSWD_KEEP=1
      warn "KEEPING $NOPASSWD_SUDOERS on '$NAME' — '$RUSER' has passwordless sudo until you remove it:"
      warn "    ssh $NAME 'sudo rm -f $NOPASSWD_SUDOERS'"
      ;;
    *) remove_nopasswd ;;
  esac
}

# Single EXIT trap (armed in main): tear down the temporary NOPASSWD drop-in on ANY
# exit — normal, error, or Ctrl-C — unless the operator kept it.
_cleanup() {
  if [ "$NOPASSWD_INSTALLED" = "1" ] && [ "$NOPASSWD_KEEP" != "1" ]; then
    remove_nopasswd
  fi
}

# --- preflight / host-prep / bootstrap --------------------------------------

# Pubkey login must work without a prompt.
preflight() {
  if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$NAME" true >/dev/null 2>&1; then
    die "cannot 'ssh $NAME' by pubkey without a prompt. Set up the host alias + key first
  (test:  ssh $NAME true ;  add a key:  ssh-copy-id $NAME)."
  fi
  log "preflight: 'ssh $NAME' works (pubkey, no prompt)"
}

# cloud-init-equivalent, idempotent. Writes NO /etc/grow-box-sandbox marker: this host
# was not created by the sandbox, so it is not marked as throwaway.
# Each rroot ends with an `echo ok:` so a silent-on-success step is never mistaken for
# a failure (esp. under per-step password prompts, where no output looks like rejection).
prepare_host() {
  log "prepare-host: base tools + bun PATH + docker group (idempotent)"
  # openssh-client (clone over ssh) + rsync (secrets copy). provision.sh system also
  # installs them, but ensure them up front so rcopy/clone can't fail first.
  rroot 'if command -v rsync >/dev/null 2>&1 && command -v ssh >/dev/null 2>&1; then echo "  ok: openssh-client + rsync (present)"; else export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq openssh-client rsync && echo "  ok: installed openssh-client + rsync"; fi'
  # bun on PATH for login shells (mirrors cloud-init; node-path.sh comes from provision.sh
  # system). The \" / \$ are escaped so the FILE gets literal $HOME/$PATH (expanded at login,
  # not now). rroot single-quotes the whole arg, so this survives the remote bash -lc intact.
  rroot 'echo "export PATH=\"\$HOME/.bun/bin:\$PATH\"" > /etc/profile.d/bun-path.sh && chmod 0644 /etc/profile.d/bun-path.sh && echo "  ok: /etc/profile.d/bun-path.sh"'
  # Add the SSH user (NOT root — $(id -un) under sudo is root) to the docker group.
  # Best-effort: the group may not exist until provision installs docker.io; a re-run
  # after provisioning adds the membership.
  rroot 'usermod -aG docker "$SUDO_USER" 2>/dev/null; echo "  ok: docker group ($SUDO_USER)"'
}

# The ssh user's home on the box, as an absolute path. Dies when it cannot be read,
# so a failed read never turns the rm -rf targets below into paths under /.
remote_home() {
  local rhome; rhome="$(rexec 'printf %s "$HOME"')"
  case "$rhome" in
    /?*) printf '%s' "$rhome" ;;
    *) die "could not read the home directory of the ssh user on '$NAME' (got '$rhome')" ;;
  esac
}

# The clone targets under the box user's home $1, one quoted path per repo row in
# $2 (default: REPOS), space-separated. Empty when the table is empty.
clone_targets() {
  local rhome="$1" rows="${2-$REPOS}" out="" optname
  while IFS= read -r optname; do
    [ -n "$optname" ] && out="$out $(quote_arg "$rhome/$optname")"
  done <<EOF
$(repo_optnames "$rows")
EOF
  printf '%s' "${out# }"
}

# The root command that removes the quoted clone targets $1, in one of two modes:
#   residue  leave a git checkout (setup-repos pulls it); remove root-owned or empty
#   reset    remove a git checkout too
# Anything else at a target may be the user's own files: the command checks EVERY
# target first, prints "GROWBOX-REFUSE <path>" and exits 3 at the first one it
# refuses, so nothing is removed. `stat -c` is GNU (the box); `stat -f` is the BSD
# fallback. $3 is the log text for each removal.
guarded_remove_cmd() {
  local targets="$1" mode="$2" verb="$3"
  printf '%s' "m=$mode
gb_removable() {
  [ -e \"\$1\" ] || return 2
  if [ -e \"\$1/.git\" ]; then [ \"\$m\" = reset ] && return 0; return 2; fi
  [ \"\$(stat -c %u \"\$1\" 2>/dev/null || stat -f %u \"\$1\")\" = 0 ] && return 0
  [ -d \"\$1\" ] && [ -z \"\$(ls -A \"\$1\")\" ] && return 0
  return 1
}
for d in $targets; do
  gb_removable \"\$d\"; r=\$?
  if [ \"\$r\" = 1 ]; then echo \"GROWBOX-REFUSE \$d\"; exit 3; fi
done
for d in $targets; do
  gb_removable \"\$d\"; r=\$?
  if [ \"\$r\" = 0 ]; then echo \"  $verb \$d\"; rm -rf \"\$d\"; fi
done"
}

# Run guarded_remove_cmd as root and stop the run, naming the path, when it refuses
# a target. $1 targets, $2 mode, $3 log text, $4 what to tell the operator.
run_guarded_remove() {
  local out rc=0 refused
  out="$(rroot "$(guarded_remove_cmd "$1" "$2" "$3")")" || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out" | grep -v '^GROWBOX-REFUSE ' || true
  [ "$rc" -eq 0 ] && return 0
  refused="$(printf '%s\n' "$out" | sed -n 's/^GROWBOX-REFUSE //p' | head -n1)"
  die "clone target ${refused:-(unknown)} is not a git checkout, not root-owned and not empty —
  it may hold your files, so nothing was removed. $4"
}

# Operator-driven bootstrap: copy secrets, rebuild the tools/sandbox layout so
# provision.sh's ../.bun-version read resolves, then run the privilege phases.
run_bootstrap() {
  local staging="$1"
  log "bootstrap: copy staged secrets → ~/$SECRETS_REMOTE (0700)"
  rcopy "$staging" "$SECRETS_REMOTE"
  rexec "chmod -R go-rwx '$SECRETS_REMOTE' 2>/dev/null || true"

  # The system phase runs via rroot (sudo) where $HOME is /root, but the scripts are
  # staged in the SSH user's home. Resolve that home once (rexec runs AS the user) and
  # pass an ABSOLUTE path — mirrors the VM's absolute /opt/sandbox-bootstrap.
  local rhome; rhome="$(remote_home)" || exit 1

  log "bootstrap: reconstruct tools/sandbox layout under ~/$DEST_REMOTE"
  rexec "set -e
    mkdir -p '$DEST_REMOTE/tools/sandbox'
    cp '$SECRETS_REMOTE/provision.sh'   '$DEST_REMOTE/tools/sandbox/provision.sh'
    cp '$SECRETS_REMOTE/setup-repos.sh' '$DEST_REMOTE/tools/sandbox/setup-repos.sh'
    [ -f '$SECRETS_REMOTE/.bun-version' ] && cp '$SECRETS_REMOTE/.bun-version' '$DEST_REMOTE/tools/.bun-version' || true
    chmod +x '$DEST_REMOTE/tools/sandbox/provision.sh' '$DEST_REMOTE/tools/sandbox/setup-repos.sh'"

  log "bootstrap: provision.sh system (root)"
  rroot "bash $rhome/$DEST_REMOTE/tools/sandbox/provision.sh system"

  log "bootstrap: provision.sh user"
  rexec "bash \$HOME/$DEST_REMOTE/tools/sandbox/provision.sh user"

  # Self-heal: a container still running from an earlier clone can recreate a
  # bind-mount source as root after the repo is removed, leaving root-owned NON-repo
  # residue at a clone target that blocks setup-repos' clone with "destination already
  # exists". At each target that isn't a git checkout, remove it as root ONLY when it
  # is root-owned (that residue) or an empty dir. Anything else belongs to the user:
  # stop and name it. A valid checkout (has .git) is left for setup-repos to pull.
  local targets
  targets="$(clone_targets "$rhome")"
  if [ -n "$targets" ]; then
    log "bootstrap: clearing any non-repo residue at the clone targets"
    run_guarded_remove "$targets" residue "cleaning non-repo residue at" \
      "Move it, or pick another optname for that repo."
  fi

  # setup-repos.sh does one `sudo ln -s` per repo for the /opt symlink → needs a TTY
  # under password sudo. Route through rexec_tty when sudo isn't passwordless. It reads
  # the staged `repos` and `branch` files from the secrets dir.
  log "bootstrap: setup-repos.sh (clone + /opt symlink)"
  local repo_cmd="SANDBOX_SECRETS_DIR=\$HOME/$SECRETS_REMOTE bash \$HOME/$DEST_REMOTE/tools/sandbox/setup-repos.sh"
  if [ "$(remote_sudo_mode)" = "nopasswd" ]; then
    rexec "$repo_cmd"
  else
    rexec_tty "$repo_cmd"
  fi
}

main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --name)        shift; NAME="${1:-}" ;;
      --name=*)      NAME="${1#--name=}" ;;
      --ip)          shift; IP="${1:-}" ;;
      --ip=*)        IP="${1#--ip=}" ;;
      --npmrc)       shift; NPMRC_PATH="${1:-}" ;;
      --npmrc=*)
        # shellcheck disable=SC2034  # NPMRC_PATH read by lib/sandbox-common.sh's stage_npmrc
        NPMRC_PATH="${1#--npmrc=}"
        ;;
      --ssh-key)     shift; SSH_KEY_PATH="${1:-}" ;;
      --ssh-key=*)   SSH_KEY_PATH="${1#--ssh-key=}" ;;
      --no-run)      RUN_STEP=0 ;;
      --nopasswd-sudo) NOPASSWD_SUDO=1 ;;
      --branch)      shift; SANDBOX_BRANCH="${1:-}" ;;
      --branch=*)
        # shellcheck disable=SC2034  # SANDBOX_BRANCH read by lib/sandbox-common.sh's stage_branch
        SANDBOX_BRANCH="${1#--branch=}"
        ;;
      --reset)       DO_RESET=1 ;;
      --purge)       DO_PURGE=1 ;;
      --regenerate)  DO_REGEN=1 ;;
      --confirm)     shift; CONFIRM="${1:-}" ;;
      --confirm=*)   CONFIRM="${1#--confirm=}" ;;
      --cleanup)     run_cleanup; exit 0 ;;
      -*) warn "unknown flag: $1"; usage; exit 2 ;;
      *)  warn "unexpected argument: $1"; usage; exit 2 ;;
    esac
    shift
  done

  # shellcheck disable=SC2034  # SANDBOX_NAME read by lib/sandbox-common.sh's ensure_stage (see note above)
  SANDBOX_NAME="$NAME"          # staging key for ensure_stage (may be empty for --cleanup, handled above)
  load_repos                    # SANDBOX_REPOS / SANDBOX_REPOS_FILE → REPOS (may be empty)

  # One EXIT trap for the whole run: tears down any temporary NOPASSWD drop-in on
  # normal exit, error, or Ctrl-C (no-op when none is in play).
  trap _cleanup EXIT

  # Teardown modes (name only) — checked before require_converge_args since --reset
  # and --purge do not need --ip.
  if [ "$DO_PURGE" = "1" ]; then run_purge; exit $?; fi
  if [ "$DO_RESET" = "1" ]; then run_reset; exit $?; fi
  # Regenerate = reset (remove repos/secrets/symlinks) then re-converge. Needs name+ip.
  if [ "$DO_REGEN" = "1" ]; then run_regenerate; exit $?; fi

  converge
}

# Stage credentials (deploy-key / ssh-key / token) via the lib. Mirrors launch-vm.
# With an empty repo table there is nothing to clone, so no token is resolved.
stage_all() {
  local staging
  if [ -z "$REPOS" ]; then
    staging="$(ensure_stage "")" || return 1
  elif [ -n "$SSH_KEY_PATH" ]; then
    log "ssh-key mode ($SSH_KEY_PATH) — skipping token resolution + deploy-key registration"
    staging="$(ensure_stage "" "$SSH_KEY_PATH")" || return 1
  else
    local token
    token="$(resolve_token)" || die \
"no GitHub token found. Provide one via:
  - export GH_TOKEN=...            (env)
  - gh auth login                 (then \`gh auth token\` is used)
  - $TOKEN_FILE                   (a file containing only the token)
or use SSH-KEY MODE:  --ssh-key PATH"
    staging="$(ensure_stage "$token")" || return 1
  fi
  printf '%s' "$staging"
}

converge() {
  require_converge_args
  preflight
  maybe_setup_nopasswd     # offer temp NOPASSWD on a password-sudo box (unattended run)
  # stage_all runs in a subshell, where `die` ends only the subshell: check its
  # status and the dir here, so a failed staging step stops the run.
  local staging; staging="$(stage_all)" || exit 1
  require_staging_dir "$staging" "converge"
  prepare_host
  run_bootstrap "$staging"

  local run_rc=0
  if [ "$RUN_STEP" = "1" ]; then
    run_cmd rexec || run_rc=$?
  else
    log "skipping the run step (--no-run)"
  fi

  finalize_nopasswd        # remove (or, interactively, keep) the temp NOPASSWD drop-in
  log "box '$NAME' ($IP) converged. Shell in:  ssh $NAME"
  local optname
  while IFS= read -r optname; do
    [ -n "$optname" ] && log "  repo: ~/$optname -> /opt/$optname"
  done <<EOF
$(repo_optnames)
EOF
  log "deploy-key hygiene: created key IDs recorded in $CREATED_KEYS_FILE (remove with --cleanup)"
  return "$run_rc"
}

# Regenerate = a soft reset (remove repos, /opt symlinks, staged secrets) followed by
# a fresh converge. Toolchain/OS/docker are kept, so this is a fast "start the repos
# + convergence over" — NOT a purge (which removes docker and does NOT reinstall).
# Needs name + ip; accepts all converge args.
run_regenerate() {
  require_converge_args
  log "regenerate '$NAME': soft reset, then a fresh converge (toolchain kept)"
  run_reset
  converge
}

# The repo rows a reset removes: REPOS when set, else the table staged on the host
# for this box by the last converge (so a reset needs no SANDBOX_REPOS).
reset_rows() {
  if [ -n "$REPOS" ]; then
    printf '%s' "$REPOS"
    return 0
  fi
  local staged="$CONFIG_DIR/staging-$NAME/repos"
  [ -f "$staged" ] && parse_repo_rows "$(cat "$staged")"
  return 0
}

# The user command that removes the git and registry credentials a converge left in
# the box user's home $1 for the repo rows $2: every ~/.ssh/<name>.key the
# ~/.ssh/sandbox_config snippet names (so keys of rows no longer in the table go
# too), ~/.ssh/<optname>.key per row, the snippet itself, the one Include line
# setup-repos.sh added to ~/.ssh/config, and ~/.npmrc only when its first line is the
# Grow Box marker. ~/.ssh/config is rewritten in place (owner and mode stay), and
# only when mktemp worked and grep exited 0 or 1.
credentials_clean_cmd() {
  local rhome="$1" rows="$2" ssh_dir keys="" optname
  ssh_dir="$rhome/.ssh"
  while IFS= read -r optname; do
    [ -n "$optname" ] && keys="$keys $(quote_arg "$ssh_dir/$optname.key")"
  done <<EOF
$(repo_optnames "$rows")
EOF
  printf '%s' "sd=$(quote_arg "$ssh_dir")
s=\"\$sd/sandbox_config\"
if [ -f \"\$s\" ]; then
  sed -n 's|^[[:space:]]*IdentityFile[[:space:]][[:space:]]*~/\\.ssh/\\([A-Za-z0-9][A-Za-z0-9._-]*\\.key\\)[[:space:]]*\$|\\1|p' \"\$s\" |
    while IFS= read -r k; do rm -f \"\$sd/\$k\"; done
fi
rm -f$keys \"\$s\"
c=\"\$sd/config\"
if [ -f \"\$c\" ] && grep -qxF 'Include ~/.ssh/sandbox_config' \"\$c\"; then
  if t=\"\$(mktemp)\" && [ -n \"\$t\" ]; then
    grep -vxF 'Include ~/.ssh/sandbox_config' \"\$c\" > \"\$t\"; r=\$?
    if [ \"\$r\" -le 1 ]; then cat \"\$t\" > \"\$c\"; else echo 'reset: could not filter ~/.ssh/config — left unchanged' >&2; fi
    rm -f \"\$t\"
  else
    echo 'reset: mktemp failed — ~/.ssh/config left unchanged' >&2
  fi
fi
n=$(quote_arg "$rhome/.npmrc")
if [ -f \"\$n\" ] && [ \"\$(head -n1 \"\$n\")\" = $(quote_arg "$NPMRC_MARKER") ]; then rm -f \"\$n\"; fi"
}

# Soft reset: remove what this tool created on the box + host, leave the OS/toolchain.
run_reset() {
  [ -n "$NAME" ] || { warn "missing required --name for --reset"; usage; exit 2; }
  log "reset '$NAME': removing repos, /opt symlinks, staged secrets, deploy keys and the .npmrc it wrote"
  preflight
  local rhome rows targets links="" optname
  rhome="$(remote_home)" || exit 1
  rows="$(reset_rows)"
  targets="$(clone_targets "$rhome" "$rows")"
  # Clones first, as ROOT (a container started from a clone can leave root-owned
  # files), and guarded: a target that is not a git checkout, root-owned or empty may
  # be the user's own dir (an optname like Documents is valid), so the reset stops
  # there before removing anything. $HOME under sudo is /root, so use $rhome.
  if [ -n "$targets" ]; then
    run_guarded_remove "$targets" reset "removing clone" \
      "Move it, or remove it by hand, then re-run --reset."
  else
    log "reset: no repo table (SANDBOX_REPOS or a staged one) — cloned repos left in place"
  fi
  # Credentials, as the ssh user (the files are theirs): deploy keys, the ssh
  # snippet and its Include line, and a .npmrc Grow Box wrote.
  rexec "$(credentials_clean_cmd "$rhome" "$rows")" || warn "reset: could not remove every credential in ~/.ssh / ~/.npmrc — check by hand"
  rroot "rm -rf $(quote_arg "$rhome/$SECRETS_REMOTE") $(quote_arg "$rhome/$DEST_REMOTE")"
  while IFS= read -r optname; do
    [ -n "$optname" ] && links="$links /opt/$optname"
  done <<EOF
$(repo_optnames "$rows")
EOF
  [ -z "$links" ] || rroot "rm -f${links}"   # only the symlinks are removed
  # Host-side staging dir for this box.
  rm -rf "$CONFIG_DIR/staging-$NAME"
  log "reset done — toolchain (docker/bun) and OS left intact. Deploy keys kept (--cleanup to remove)."
}

# Full purge: soft reset + remove docker, the sandbox marker and the sudoers drop-in.
# GATED behind --confirm purge.
run_purge() {
  [ -n "$NAME" ] || { warn "missing required --name for --purge"; usage; exit 2; }
  if [ "$CONFIRM" != "purge" ]; then
    warn "REFUSING --purge without confirmation. This will, on '$NAME':"
    warn "  - everything --reset does (repos, /opt symlinks, staged secrets, box-side credentials)"
    warn "  - apt-get remove docker.io docker-compose-v2"
    warn "  - delete $SANDBOX_MARKER and $NOPASSWD_SUDOERS if present"
    warn "Re-run to confirm:  launch-remote.sh --name $NAME --purge --confirm=purge"
    exit 2
  fi
  log "purge '$NAME': confirmed — soft reset, then docker + sandbox marker + sudoers drop-in removal"
  run_reset
  rroot 'export DEBIAN_FRONTEND=noninteractive; apt-get remove -y -qq docker.io docker-compose-v2 || true'
  # Last: removing the drop-in can turn later sudo calls back into password prompts.
  rroot "rm -f $SANDBOX_MARKER $NOPASSWD_SUDOERS"
  log "purge done on '$NAME'."
}

# Sourcing guard: run main only when executed directly (lets tests source us).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
