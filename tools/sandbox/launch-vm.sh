#!/usr/bin/env bash
# Host-side launcher for the Grow Box sandbox VM (multipass).
#
# Runs on the OPERATOR's machine (macOS/Linux; bash 3.2-safe). It does ALL
# token/key provisioning BEFORE the VM boots, so the GitHub token stays on the
# HOST in the preferred (deploy-key) mode.
#
# CONVERGENT / IDEMPOTENT / RESUMABLE: if a run fails, the next one resumes; if the
# scripts change, the next one applies them. Re-running launch-vm.sh after any
# partial failure converges instead of erroring. Each step is state-checked:
#
#   ensure_stage   stable per-VM staging dir ($CONFIG_DIR/staging-<vm>, 0700).
#                  REUSES existing valid deploy keys (no accumulation); only
#                  registers a new deploy key when one isn't already staged.
#                  ALWAYS re-stages the bootstrap scripts so updates propagate.
#   ensure_vm      reuse the VM if `multipass info` succeeds; else launch it.
#   ensure_mount   mount the staging dir at /run/sandbox-secrets only if not
#                  already mounted (idempotent; tolerates "already mounted").
#   run_bootstrap  `multipass exec <vm> -- sudo bash sandbox-bootstrap.sh`. This
#                  is what DECOUPLES provisioning from cloud-init first-boot
#                  timing — the bootstrap runs only after the mount is confirmed,
#                  so cloud-init does not race `multipass mount`.
#   run_cmd        run SANDBOX_RUN_CMD in the VM (skipped when it is unset).
#
# A failure in any step leaves the VM resumable: just re-run launch-vm.sh.
#
# Repo table: SANDBOX_REPOS (rows "owner|repo|optname", separated by newlines or
# commas) or SANDBOX_REPOS_FILE. Each repo is cloned to ~ubuntu/<optname> and linked
# at /opt/<optname>. With neither set, nothing is cloned.
#
# Auth model: three modes, in PRECEDENCE order:
#   SSH-KEY mode (opt-in) — set SANDBOX_SSH_KEY / --ssh-key <path> to a PRIVATE
#     ssh key on the host. It is staged per-repo (same content, <optname>.key
#     filename) + an ssh_config, identical in SHAPE to deploy-key mode, so the VM
#     side (setup-repos.sh) needs NO change. The key is copied into the VM and
#     gives PERSISTENT in-box SSH git (clone + later pull/push). No token is
#     resolved and no deploy keys are registered. BROADER ACCESS than the other
#     two modes — see the loud warnings in stage_ssh_key().
#   DEPLOY-KEY mode (preferred default) registers a read-only deploy key per repo
#     and keeps the token on the host.
#   TOKEN-FALLBACK (opt-in, SANDBOX_ALLOW_TOKEN_FALLBACK=1) runs only when deploy-key
#     registration fails: it writes the explicit GH_TOKEN / SANDBOX_GH_TOKEN_FILE
#     token into the staging dir, which is copied into the VM (warned). Without the
#     opt-in, a registration failure stops the run.
#
# Precedence: SANDBOX_SSH_KEY (ssh-key) > deploy-key > opt-in token fallback.
#
# Modes:
#   launch-vm.sh [VM_NAME]       converge the sandbox VM (default below)
#   launch-vm.sh --ssh-key PATH  BYO private ssh key (persistent in-box git)
#   launch-vm.sh --destroy       multipass delete --purge <vm> (+ best-effort
#                                unmount) so the operator can start clean
#   launch-vm.sh --cleanup       delete the deploy keys this tool created
#
# Never sources a secret file — tokens are read with `cat` only, never `. file`.
set -uo pipefail

VM_NAME="${SANDBOX_VM:-growbox-sandbox}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Shared, transport-agnostic core (auth, staging, runners). Sets no shell options.
# shellcheck source=lib/sandbox-common.sh
. "$HERE/lib/sandbox-common.sh"

# SANDBOX_LOG_TAG/SANDBOX_NAME are read only inside lib/sandbox-common.sh (log/warn/die,
# ensure_stage, warn_ssh_key_mode, run_cmd). shellcheck resolves the `source=` directive
# relative to its invocation cwd, not this script's dir, so run from the repo root it
# can't statically see that cross-file use and flags these SC2034 — false positives.
# shellcheck disable=SC2034
SANDBOX_LOG_TAG=launch-vm     # keep the [launch-vm] log prefix
SANDBOX_NAME="$VM_NAME"       # staging dir key used by ensure_stage

# Opt-in BYO-key mode: path to a PRIVATE ssh key on the host. Set via env or the
# --ssh-key flag (the flag overrides the env). When non-empty → SSH-KEY MODE,
# which takes precedence over deploy-key and token modes.
SSH_KEY_PATH="${SANDBOX_SSH_KEY:-}"
# Run SANDBOX_RUN_CMD inside the VM after convergence and stream its output to THIS
# terminal. Default on (a no-op while SANDBOX_RUN_CMD is unset); disable with
# --no-run or SANDBOX_NO_RUN=1.
RUN_STEP="${SANDBOX_NO_RUN:+0}"; RUN_STEP="${RUN_STEP:-1}"
REGENERATE=0   # --regenerate: destroy (verify gone) then recreate, in one run
# Bridge the VM onto a host interface so it gets a LAN IP (reachable by other
# hosts), instead of multipass's NAT-only address. Set to a bridgeable interface
# from `multipass networks` (e.g. en0). Empty = default
# multipass NAT (host-only). Applied at LAUNCH only — an existing VM must be
# destroyed + recreated to change it.
NETWORK="${SANDBOX_NETWORK:-}"
CLOUD_INIT="$HERE/cloud-init.yaml"
MOUNT_POINT="/run/sandbox-secrets"

# --- destroy mode -----------------------------------------------------------

# Reset path: tear the VM down so the operator can start clean. Best-effort
# unmount first, then delete --purge. Idempotent: a missing VM is not an error.
run_destroy() {
  have multipass || die "multipass not on PATH — nothing to destroy"
  if multipass info "$VM_NAME" >/dev/null 2>&1; then
    log "unmounting $MOUNT_POINT from '$VM_NAME' (best effort)"
    multipass umount "$VM_NAME:$MOUNT_POINT" >/dev/null 2>&1 || true
    log "destroying VM '$VM_NAME' (multipass delete --purge)"
    if multipass delete --purge "$VM_NAME" >/dev/null 2>&1; then
      log "VM '$VM_NAME' destroyed"
    else
      die "failed to destroy '$VM_NAME' — try: multipass delete --purge $VM_NAME"
    fi
  else
    log "no VM named '$VM_NAME' — nothing to destroy"
  fi
  log "deploy keys are kept; run 'launch-vm.sh --cleanup' to remove them too"
}

# Delete this VM's host staging dir (deploy-key private keys, any token or .npmrc).
# Only on --destroy: --regenerate keeps it, so the recreated VM reuses the registered
# deploy keys instead of registering new ones.
remove_host_staging() {
  [ -n "$VM_NAME" ] || return 0
  if [ -d "$CONFIG_DIR/staging-$VM_NAME" ]; then
    rm -rf "$CONFIG_DIR/staging-$VM_NAME"
    log "removed the host staging dir $CONFIG_DIR/staging-$VM_NAME"
  fi
}

# Confirm the VM is actually gone before a regenerate recreates it. `multipass
# delete --purge` is synchronous, but poll a few times in case the daemon lags —
# recreating while a same-named VM lingers would fail.
verify_vm_gone() {
  for _ in 1 2 3 4 5; do
    multipass info "$VM_NAME" >/dev/null 2>&1 || { log "confirmed '$VM_NAME' is gone"; return 0; }
    sleep 1
  done
  die "'$VM_NAME' still present after destroy — clear it manually: multipass delete --purge $VM_NAME"
}

# --- VM lifecycle (idempotent) ----------------------------------------------

# Reuse the VM if it exists; else launch it. Never fails on "already exists".
ensure_vm() {
  have multipass || die "multipass not on PATH — install multipass, or use launch-remote.sh against an existing host"
  [ -f "$CLOUD_INIT" ] || die "cloud-init not found: $CLOUD_INIT"
  if multipass info "$VM_NAME" >/dev/null 2>&1; then
    log "reusing existing VM '$VM_NAME'"
    [ -n "$NETWORK" ] && warn "  --network only applies at LAUNCH — this VM keeps its current NICs; 'launch-vm.sh --destroy' then re-run to (re)bridge onto '$NETWORK'"
    return 0
  fi
  local net_args=()
  if [ -n "$NETWORK" ]; then
    net_args=(--network "$NETWORK")
    log "bridging VM onto host interface '$NETWORK' — it will get a LAN IP via DHCP (macOS may prompt to authorize the bridge)"
  fi
  log "launching multipass VM '$VM_NAME' (24.04, cloud-init${NETWORK:+, network=$NETWORK})"
  multipass launch 24.04 --name "$VM_NAME" --cloud-init "$CLOUD_INIT" ${net_args[@]+"${net_args[@]}"} \
    || die "multipass launch failed for '$VM_NAME' — re-run launch-vm.sh to resume, or 'launch-vm.sh --destroy' to reset"
}

# List the VM's IPv4 address(es): the default multipass NAT plus any bridged LAN
# address. `multipass info` prints the first on the "IPv4:" line and extras on
# indented continuation lines.
# Excludes addresses starting 172. (where Docker's default bridge networks live in
# the VM) — never a LAN address — so the report shows just the multipass NAT + any
# bridged LAN IP.
vm_ipv4s() {
  multipass info "$VM_NAME" 2>/dev/null | awk '
    /^IPv4:/ { if ($2 ~ /^[0-9]+(\.[0-9]+){3}$/ && $2 !~ /^172\./) print $2; grab=1; next }
    grab && $1 ~ /^[0-9]+(\.[0-9]+){3}$/ { if ($1 !~ /^172\./) print $1; next }
    grab { grab=0 }
  '
}

# True if $MOUNT_POINT is already mounted in the VM (parse `multipass info`).
mount_present() {
  multipass info "$VM_NAME" 2>/dev/null | grep -q "$MOUNT_POINT"
}

# Mount the staging dir at $MOUNT_POINT only if not already mounted. Tolerates
# an "already mounted" race by re-checking after a failed attempt.
ensure_mount() {
  local staging="$1"
  if mount_present; then
    log "mount $MOUNT_POINT already present — leaving as-is"
    return 0
  fi
  log "mounting staged secrets into '$VM_NAME' at $MOUNT_POINT"
  if multipass mount "$staging" "$VM_NAME:$MOUNT_POINT" >/dev/null 2>&1; then
    return 0
  fi
  # Tolerate the case where it became mounted concurrently / already existed.
  if mount_present; then
    log "mount became present (tolerated an 'already mounted' condition)"
    return 0
  fi
  die "failed to mount $staging at $VM_NAME:$MOUNT_POINT — re-run launch-vm.sh to resume"
}

# Exec the in-VM bootstrap AFTER the mount is confirmed. This is the decoupling:
# the bootstrap (provision + clone) runs here, not in cloud-init first-boot, so
# it can never race the mount. On failure, point the operator at a simple re-run.
run_bootstrap() {
  log "running in-VM bootstrap (provision + clone) via multipass exec"
  if multipass exec "$VM_NAME" -- sudo bash /usr/local/sbin/sandbox-bootstrap.sh; then
    log "bootstrap complete"
    return 0
  fi
  warn "in-VM bootstrap failed (see the [sandbox-bootstrap] PHASE FAILED line above)"
  die "the VM is left resumable — just re-run launch-vm.sh to pick up where it left off"
}

# Transport: run a login-shell command in the VM, streaming (no capture).
vm_exec() { multipass exec "$VM_NAME" -- bash -lc "$1"; }

# --- usage / main -----------------------------------------------------------

usage() {
  cat >&2 <<EOF
usage: launch-vm.sh [VM_NAME]           converge the sandbox VM (default: $VM_NAME)
       launch-vm.sh --ssh-key PATH      BYO PRIVATE ssh key → persistent in-box git
       launch-vm.sh --npmrc PATH        stage an .npmrc (auth for a private npm registry) into the VM
       launch-vm.sh --branch NAME       check out this branch in the cloned repos (default: main)
       launch-vm.sh --no-run            converge only; do NOT run SANDBOX_RUN_CMD in the VM
       launch-vm.sh --network IFACE     bridge the VM onto a host iface (LAN IP; see 'multipass networks')
       launch-vm.sh --regenerate        destroy (verify gone) then recreate — all other flags apply
       launch-vm.sh --destroy           delete --purge the VM (reset to clean)
       launch-vm.sh --cleanup           delete the deploy keys this tool created

This command is IDEMPOTENT and RESUMABLE: re-run it after a partial failure or
after editing the staged scripts and it converges (re-stages + re-execs the
bootstrap). Use --destroy to start clean.

environment:
  SANDBOX_REPOS       repo rows "owner|repo|optname", separated by newlines or commas;
                        each is cloned to ~ubuntu/<optname> and linked at /opt/<optname>
  SANDBOX_REPOS_FILE  a file of such rows (instead of SANDBOX_REPOS). Neither set: no clone
  SANDBOX_RUN_CMD     the command the run step runs in the VM. Unset: the step is skipped
  SANDBOX_RUN_DIR     where it runs (default: /opt/<optname> of the first repo row)

auth precedence: SANDBOX_SSH_KEY/--ssh-key (ssh-key) > deploy-key (token can
register) > token fallback (opt-in: SANDBOX_ALLOW_TOKEN_FALLBACK=1).

  - SSH-KEY MODE (opt-in): SANDBOX_SSH_KEY=PATH or --ssh-key PATH stages your
    PRIVATE ssh key into the VM for PERSISTENT in-box git (clone + pull/push).
    BROADER ACCESS than the read-only modes — use a dedicated, revocable key.
  - DEPLOY-KEY mode resolves a token to register the keys (it stays on the host):
    token resolution order: \$GH_TOKEN, \`gh auth token\`, $TOKEN_FILE
  - TOKEN FALLBACK (opt-in): SANDBOX_ALLOW_TOKEN_FALLBACK=1 copies the GH_TOKEN or
    SANDBOX_GH_TOKEN_FILE token to the VM when deploy keys cannot be registered.
    The \`gh auth token\` token is never copied.
EOF
}

main() {
  # Arg parse: flags in any order; a lone non-flag is a positional VM name.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --destroy) run_destroy; remove_host_staging; exit 0 ;;
      --cleanup) run_cleanup; exit 0 ;;
      -h|--help) usage; exit 0 ;;
      --ssh-key)
        shift
        [ "$#" -gt 0 ] || { warn "--ssh-key requires a PATH argument"; usage; exit 2; }
        SSH_KEY_PATH="$1"
        ;;
      --ssh-key=*) SSH_KEY_PATH="${1#--ssh-key=}" ;;
      --npmrc)
        shift
        [ "$#" -gt 0 ] || { warn "--npmrc requires a PATH argument"; usage; exit 2; }
        NPMRC_PATH="$1"
        ;;
      --npmrc=*)
        # shellcheck disable=SC2034  # read by lib/sandbox-common.sh's stage_npmrc (see note above)
        NPMRC_PATH="${1#--npmrc=}"
        ;;
      --branch)
        shift
        [ "$#" -gt 0 ] || { warn "--branch requires a NAME argument"; usage; exit 2; }
        # shellcheck disable=SC2034  # read by lib/sandbox-common.sh's stage_branch
        SANDBOX_BRANCH="$1"
        ;;
      --branch=*)
        # shellcheck disable=SC2034  # read by lib/sandbox-common.sh's stage_branch
        SANDBOX_BRANCH="${1#--branch=}"
        ;;
      --no-run) RUN_STEP=0 ;;
      --regenerate) REGENERATE=1 ;;
      --network)
        shift
        [ "$#" -gt 0 ] || { warn "--network requires an interface (e.g. en0)"; usage; exit 2; }
        NETWORK="$1"
        ;;
      --network=*) NETWORK="${1#--network=}" ;;
      -*) warn "unknown flag: $1"; usage; exit 2 ;;
      *)  # positional VM name override
        VM_NAME="$1"
        # shellcheck disable=SC2034  # SANDBOX_NAME read by lib/sandbox-common.sh's ensure_stage (see note above)
        SANDBOX_NAME="$1"
        ;;
    esac
    shift
  done

  load_repos   # SANDBOX_REPOS / SANDBOX_REPOS_FILE → REPOS (may be empty)

  # --regenerate: destroy the VM, confirm it's gone, then fall through to the
  # normal converge below (recreating from scratch with all the same flags).
  if [ "$REGENERATE" = "1" ]; then
    log "regenerate: destroying '$VM_NAME', then recreating from scratch"
    run_destroy
    verify_vm_gone
  fi

  local token="" staging
  if [ -z "$REPOS" ]; then
    # Nothing to clone, so no git credentials to resolve or stage.
    staging="$(ensure_stage "")" || exit 1
  elif [ -n "$SSH_KEY_PATH" ]; then
    # SSH-KEY MODE: precedence over deploy-key/token — skip token resolution and
    # API registration entirely.
    log "ssh-key mode requested ($SSH_KEY_PATH) — skipping token resolution and deploy-key registration"
    staging="$(ensure_stage "" "$SSH_KEY_PATH")" || exit 1
  else
    token="$(resolve_token)" || die \
"no GitHub token found. Provide one via:
  - export GH_TOKEN=...                  (env)
  - gh auth login                        (then \`gh auth token\` is used)
  - $TOKEN_FILE                          (a file containing only the token)
or use SSH-KEY MODE:  SANDBOX_SSH_KEY=PATH (or --ssh-key PATH)"
    staging="$(ensure_stage "$token")" || exit 1
  fi

  # ensure_stage runs in a subshell, where `die` ends only the subshell: check its
  # status and the dir here, so a failed staging step never reaches multipass.
  require_staging_dir "$staging" "launch-vm"

  ensure_vm
  ensure_mount "$staging"
  run_bootstrap

  local run_rc=0
  if [ "$RUN_STEP" = "1" ]; then
    run_cmd vm_exec || run_rc=$?
  else
    log "skipping the run step (--no-run)"
  fi

  local ips; ips="$(vm_ipv4s | tr '\n' ' ')"
  log "VM IPv4 address(es): ${ips:-<none>}"
  if [ -n "$NETWORK" ]; then
    log "  bridged onto '$NETWORK' — the LAN address is the one on that interface's subnet"
  else
    log "  NAT-only (host-reachable, not LAN-reachable). For a LAN IP: launch-vm.sh --regenerate --network en0"
  fi

  log "VM '$VM_NAME' converged. Shell in:  multipass shell $VM_NAME"
  local optname
  while IFS= read -r optname; do
    [ -n "$optname" ] && log "  repo: ~ubuntu/$optname -> /opt/$optname"
  done <<EOF
$(repo_optnames)
EOF
  log "deploy-key hygiene: created key IDs recorded in $CREATED_KEYS_FILE"
  log "  remove stale keys with:  launch-vm.sh --cleanup"
  log "  reset the VM with:       launch-vm.sh --destroy"
  return "$run_rc"
}

main "$@"
