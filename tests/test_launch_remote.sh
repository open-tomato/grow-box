#!/usr/bin/env bash
# launch-remote.sh frontend: usage/guards (subprocess), and decision logic (sourced
# with stubbed transport). Sourced by tests/run.sh (already set -uo pipefail).
: "${REPO_ROOT:?run via tests/run.sh}"
RL="$REPO_ROOT/tools/sandbox/launch-remote.sh"

assert_eq "launch-remote exists+exec" "$( [ -x "$RL" ] && echo yes || echo no )" "yes"

# No args → usage error mentioning the required params.
out="$(bash "$RL" 2>&1)"; rc=$?
assert_not_eq "no-args exits non-zero" "$rc" "0"
assert_contains "no-args prints usage (name)" "$out" "name"
assert_contains "no-args prints usage (ip)"   "$out" "ip"

# Converge with name but no ip → error about ip.
out="$(bash "$RL" --name box 2>&1)"; rc=$?
assert_not_eq "missing ip exits non-zero" "$rc" "0"
assert_contains "missing ip is reported" "$out" "ip"

# --- transport decision logic (source with stubbed ssh/have) -----------------
# remote_sudo_mode: nopasswd when the probe succeeds, askpass when it fails.
mode_pass="$( set +u; . "$RL"; NAME=box; ssh() { return 0; }; remote_sudo_mode )"
assert_eq "sudo mode nopasswd when 'sudo -n' works" "$mode_pass" "nopasswd"

# shellcheck disable=SC2034  # NAME is read by remote_sudo_mode inside the sourced script, not here
mode_fail="$( set +u; . "$RL"; NAME=box; ssh() { return 1; }; remote_sudo_mode )"
assert_eq "sudo mode askpass when 'sudo -n' fails" "$mode_fail" "askpass"

# pick_copy_tool: rsync when both ends have it, scp when the remote lacks it.
tool_yes="$( set +u; . "$RL"; have() { return 0; }; pick_copy_tool yes )"
assert_eq "copy tool rsync when both have rsync" "$tool_yes" "rsync"

tool_no="$( set +u; . "$RL"; have() { return 0; }; pick_copy_tool no )"
assert_eq "copy tool scp when remote lacks rsync" "$tool_no" "scp"

tool_local_absent="$( set +u; . "$RL"; have() { return 1; }; pick_copy_tool yes )"
assert_eq "copy tool scp when local lacks rsync" "$tool_local_absent" "scp"

# quote_arg must round-trip a nasty string (spaces, quotes, $, &&) through eval.
rt="$( set +u; . "$RL"; s="cd /o && x \"y\" 'z' \$P"; eval "printf %s $(quote_arg "$s")" )"
assert_eq "quote_arg round-trips safely" "$rt" "cd /o && x \"y\" 'z' \$P"

# --- prepare_host orchestration (stub the transport, assert the commands) -----
prep="$( set +u; . "$RL"; NAME=box
  rroot() { echo "ROOT: $1"; }
  rexec() { echo "EXEC: $1"; }
  prepare_host 2>&1 )"
assert_contains "prepare_host writes bun-path profile" "$prep" "/etc/profile.d/bun-path.sh"
assert_contains "prepare_host adds user to docker group" "$prep" "usermod -aG docker"
# The throwaway marker is NOT written by prepare_host: the host was not created by the sandbox.
case "$prep" in *"/etc/grow-box-sandbox"*) marker=written;; *) marker=absent;; esac
assert_eq "prepare_host does NOT write the marker" "$marker" "absent"

# --- run_bootstrap runs the three phases in order ----------------------------
# rexec's HOME-probe branching is a top-level function (not defined inline inside the
# "$( )" below): bash 3.2 (macOS system bash) mis-parses a `case`/`esac`
# defined inside a function that is itself declared inside a command substitution —
# a real parser bug, not a style choice. Keeping the case outside sidesteps it.
rexec_home_probe() {
  case "$1" in
    *'printf %s'*) printf %s "/home/tester" ;;
    *) echo "EXEC: $1" ;;
  esac
}
# shellcheck disable=SC2034  # NAME/SECRETS_REMOTE/DEST_REMOTE are read by run_bootstrap inside the sourced script, not here
boot="$( set +u; . "$RL"; NAME=box; SECRETS_REMOTE=.s; DEST_REMOTE=.d
  REPOS=$'own|app|app\nown|lib|lib'
  rcopy() { echo "COPY: $1 -> $2"; }
  rroot() { echo "ROOT: $1"; }
  rexec() { rexec_home_probe "$1"; }
  rexec_tty() { echo "TTY: $1"; }
  remote_sudo_mode() { echo nopasswd; }
  run_bootstrap /fake/staging 2>&1 )"
assert_contains "bootstrap copies staging" "$boot" "COPY: /fake/staging"
assert_contains "bootstrap runs provision system as root" "$boot" "provision.sh system"
assert_contains "bootstrap runs provision user"           "$boot" "provision.sh user"
assert_contains "bootstrap self-heals non-repo residue"   "$boot" "cleaning non-repo residue"
assert_contains "bootstrap residue targets come from the repo table" "$boot" "for d in '/home/tester/app' '/home/tester/lib'; do"
assert_contains "bootstrap runs setup-repos"              "$boot" "setup-repos.sh"

# With an empty repo table there is nothing to clean before the clone step.
boot0="$( set +u; . "$RL"; NAME=box; SECRETS_REMOTE=.s; DEST_REMOTE=.d; REPOS=""
  rcopy() { :; }; rroot() { echo "ROOT: $1"; }; rexec() { rexec_home_probe "$1"; }
  rexec_tty() { :; }; remote_sudo_mode() { echo nopasswd; }
  run_bootstrap /fake/staging 2>&1 )"
case "$boot0" in *"non-repo residue"*) residue=ran;; *) residue=skipped;; esac
assert_eq "bootstrap skips the residue clean without repos" "$residue" "skipped"

# A home directory that cannot be read stops the bootstrap before any rm -rf.
boot_nohome="$( set +u; . "$RL"; NAME=box; SECRETS_REMOTE=.s; DEST_REMOTE=.d; REPOS='own|app|app'
  rcopy() { :; }; rroot() { echo "ROOT: $1"; }; rexec() { printf ''; }
  rexec_tty() { :; }; remote_sudo_mode() { echo nopasswd; }
  run_bootstrap /fake/staging 2>&1; echo "rc=$?" )"
assert_contains "bootstrap refuses an unreadable remote home" "$boot_nohome" "could not read the home directory"
case "$boot_nohome" in *"ROOT: "*) rooted=yes;; *) rooted=no;; esac
assert_eq "bootstrap runs nothing as root without a home" "$rooted" "no"

# --- run_bootstrap: system phase uses the ssh user's ABSOLUTE home, not root's $HOME ---
bs="$( set +u; . "$RL"; NAME=box; SECRETS_REMOTE=.s; DEST_REMOTE=.d
  rexec()     { rexec_home_probe "$1"; }
  rcopy()     { echo "COPY: $1 -> $2"; }
  rroot()     { echo "ROOT: $1"; }
  rexec_tty() { echo "TTY: $1"; }
  remote_sudo_mode() { echo nopasswd; }
  run_bootstrap /fake/staging 2>&1 )"
assert_contains "bootstrap system phase uses the resolved user home" "$bs" "ROOT: bash /home/tester/.d/tools/sandbox/provision.sh system"
case "$bs" in *'ROOT: bash $HOME'*) hb=bad;; *) hb=good;; esac
assert_eq "bootstrap system phase does NOT use root \$HOME" "$hb" "good"

# --- purge is gated: without --confirm purge it refuses BEFORE any ssh --------
# Put a failing 'ssh' on PATH; if purge reaches ssh the test would show 'SSH-CALLED'.
fakebin="$(mktemp -d)"
printf '#!/bin/sh\necho SSH-CALLED >&2\nexit 0\n' > "$fakebin/ssh"; chmod +x "$fakebin/ssh"
out="$(PATH="$fakebin:$PATH" bash "$RL" --name box --purge 2>&1)"; rc=$?
assert_not_eq "purge without confirm exits non-zero" "$rc" "0"
assert_contains "purge without confirm demands confirm=purge" "$out" "confirm=purge"
case "$out" in *SSH-CALLED*) reached=yes;; *) reached=no;; esac
assert_eq "purge gate blocks before ssh" "$reached" "no"
rm -rf "$fakebin"

# purge with confirm=purge but no name → still requires a name.
out="$(bash "$RL" --purge --confirm purge 2>&1)"; rc=$?
assert_not_eq "purge without name exits non-zero" "$rc" "0"
assert_contains "purge without name reports it" "$out" "name"

# --- run_reset targets the expected paths (stub transport) -------------------
# Removes the repos/staged dirs as ROOT using the resolved user home (not $HOME,
# which is /root under sudo), then the /opt symlinks named by the repo table.
# shellcheck disable=SC2034  # NAME/SANDBOX_NAME/SECRETS_REMOTE/DEST_REMOTE/CONFIG_DIR are read by run_reset inside the sourced script, not here
rst="$( set +u; . "$RL"; NAME=box; SANDBOX_NAME=box; SECRETS_REMOTE=.s; DEST_REMOTE=.d; CONFIG_DIR=/nonexistent-cfg
  REPOS=$'own|app|app\nown|lib|lib'
  preflight() { :; }
  rexec() { rexec_home_probe "$1"; }
  rroot() { echo "ROOT: $1"; }
  run_reset 2>&1 )"
assert_contains "reset removes the repos through the guarded removal (resolved home)" "$rst" \
  "for d in '/home/tester/app' '/home/tester/lib'; do"
assert_contains "reset removes the secrets and bootstrap dirs as ROOT (resolved home)" "$rst" \
  "ROOT: rm -rf '/home/tester/.s' '/home/tester/.d'"
assert_contains "reset unlinks the /opt symlinks from the table" "$rst" "ROOT: rm -f /opt/app /opt/lib"
case "$rst" in *"docker rm"*) stops=yes;; *) stops=no;; esac
assert_eq "reset stops no containers by name" "$stops" "no"

# Without SANDBOX_REPOS, reset reads the table this box's last converge staged on the host.
rcfg="$(mktemp -d)"; mkdir -p "$rcfg/staging-box"; printf 'own|old|old\n' > "$rcfg/staging-box/repos"
# shellcheck disable=SC2034  # read by run_reset inside the sourced script, not here
rst2="$( set +u; . "$RL"; NAME=box; SANDBOX_NAME=box; SECRETS_REMOTE=.s; DEST_REMOTE=.d; CONFIG_DIR="$rcfg"; REPOS=""
  preflight() { :; }; rexec() { rexec_home_probe "$1"; }; rroot() { echo "ROOT: $1"; }
  run_reset 2>&1 )"
assert_contains "reset falls back to the staged repo table" "$rst2" "for d in '/home/tester/old'; do"
assert_contains "reset unlinks the staged table's symlink" "$rst2" "ROOT: rm -f /opt/old"
assert_eq "reset removes the host staging dir" "$( [ -d "$rcfg/staging-box" ] && echo present || echo gone )" "gone"
rm -rf "$rcfg"

# With no table anywhere, reset still removes the staged dirs and says so.
# shellcheck disable=SC2034  # read by run_reset inside the sourced script, not here
rst3="$( set +u; . "$RL"; NAME=box; SANDBOX_NAME=box; SECRETS_REMOTE=.s; DEST_REMOTE=.d; CONFIG_DIR=/nonexistent-cfg; REPOS=""
  preflight() { :; }; rexec() { rexec_home_probe "$1"; }; rroot() { echo "ROOT: $1"; }
  run_reset 2>&1 )"
assert_contains "reset without a table removes the staged dirs" "$rst3" "ROOT: rm -rf '/home/tester/.s' '/home/tester/.d'"
assert_contains "reset without a table says the clones stay" "$rst3" "cloned repos left in place"
case "$rst3" in *"ROOT: rm -f /opt"*) unlinked=yes;; *) unlinked=no;; esac
assert_eq "reset without a table unlinks nothing under /opt" "$unlinked" "no"

# --- purge (confirmed): reset, docker, then the marker + sudoers drop-in --------
# shellcheck disable=SC2034  # NAME/CONFIRM are read by run_purge inside the sourced script, not here
pg="$( set +u; . "$RL"; NAME=box; CONFIRM=purge
  rexec()     { echo "READ:$1"; }
  run_reset() { echo "RESET"; }
  rroot()     { echo "ROOT:$1"; }
  run_purge 2>&1 )"
assert_contains "purge runs the soft reset" "$pg" "RESET"
assert_contains "purge removes docker" "$pg" "apt-get remove -y -qq docker.io docker-compose-v2"
assert_contains "purge removes the marker and the sudoers drop-in" "$pg" "ROOT:rm -f /etc/grow-box-sandbox /etc/sudoers.d/grow-box-sandbox"
case "$pg" in *READ:*|*"rm -rf"*|*userdel*|*groupdel*) extra=yes;; *) extra=no;; esac
assert_eq "purge removes only the reset targets, docker, the marker and the drop-in" "$extra" "no"
o_reset=$(printf '%s\n' "$pg" | grep -n 'RESET' | head -1 | cut -d: -f1)
o_drop=$(printf '%s\n' "$pg" | grep -n 'sudoers.d' | tail -1 | cut -d: -f1)
assert_eq "purge removes the drop-in last" "$( [ -n "$o_reset" ] && [ -n "$o_drop" ] && [ "$o_reset" -lt "$o_drop" ] && echo yes || echo no )" "yes"

# --- an unknown flag is rejected; --no-run is accepted ------------------------
fakebin="$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' > "$fakebin/ssh"; chmod +x "$fakebin/ssh"
out="$(PATH="$fakebin:$PATH" bash "$RL" --name box --ip 192.0.2.10 --bogus 2>&1)"; rc=$?
assert_eq "an unknown flag exits 2" "$rc" "2"
assert_contains "an unknown flag is reported" "$out" "unknown flag"
# Control: --no-run parses and the run proceeds to preflight (where the failing ssh stops it).
out="$(PATH="$fakebin:$PATH" bash "$RL" --name box --ip 192.0.2.10 --no-run 2>&1)"
case "$out" in *"unknown flag"*) known=no;; *) known=yes;; esac
assert_eq "--no-run is a known flag" "$known" "yes"
assert_contains "--no-run run reaches preflight" "$out" "cannot 'ssh box'"
rm -rf "$fakebin"

# --- converge: run step on by default, --no-run skips it, rc propagates --------
# stage_all returns a real staging dir under a temp CONFIG_DIR: converge checks it.
conv_cfg="$(mktemp -d)"; mkdir -p "$conv_cfg/staging-box"
conv_stubs() {
  CONFIG_DIR="$conv_cfg"
  require_converge_args() { :; }; preflight() { :; }; maybe_setup_nopasswd() { :; }
  stage_all() { printf '%s' "$CONFIG_DIR/staging-box"; }; prepare_host() { :; }; run_bootstrap() { :; }
  finalize_nopasswd() { :; }
}
# shellcheck disable=SC2034  # NAME/IP/RUN_STEP are read by converge inside the sourced script, not here
cv="$( set +u; . "$RL"; NAME=box; IP=192.0.2.10; RUN_STEP=1; REPOS='own|app|app'; conv_stubs
  run_cmd() { echo "RUN(exec=$1)"; return 5; }
  converge 2>&1; echo "rc=$?" )"
assert_contains "converge runs run_cmd over rexec" "$cv" "RUN(exec=rexec)"
assert_contains "converge returns the run step's exit code" "$cv" "rc=5"
assert_contains "converge reports the repo links from the table" "$cv" "repo: ~/app -> /opt/app"
# shellcheck disable=SC2034  # NAME/IP/RUN_STEP are read by converge inside the sourced script, not here
cvn="$( set +u; . "$RL"; NAME=box; IP=192.0.2.10; RUN_STEP=0; REPOS=""; conv_stubs
  run_cmd() { echo "RUN-CALLED"; return 5; }
  converge 2>&1; echo "rc=$?" )"
assert_contains "converge with --no-run logs the skip" "$cvn" "skipping the run step (--no-run)"
case "$cvn" in *RUN-CALLED*) ran=yes;; *) ran=no;; esac
assert_eq "converge with --no-run never calls run_cmd" "$ran" "no"
assert_contains "converge with --no-run returns 0" "$cvn" "rc=0"
rm -rf "$conv_cfg"

# run_regenerate resets THEN converges (never the reverse, and never a purge).
# shellcheck disable=SC2034  # IP is consumed by require_converge_args (stubbed here) inside the sourced $RL
rgn="$( set +u; . "$RL"; NAME=box; IP=192.0.2.10
  require_converge_args() { :; }
  run_reset() { echo RESET; }
  converge()  { echo CONVERGE; }
  run_regenerate 2>&1 )"
r_at=$(printf '%s\n' "$rgn" | grep -n RESET    | head -1 | cut -d: -f1)
c_at=$(printf '%s\n' "$rgn" | grep -n CONVERGE | head -1 | cut -d: -f1)
assert_eq "regenerate resets before converging" "$( [ -n "$r_at" ] && [ -n "$c_at" ] && [ "$r_at" -lt "$c_at" ] && echo yes || echo no )" "yes"

# ===================== temporary NOPASSWD sudo =====================

# remote_sudo_mode caches SUDO_MODE (no re-probe when already set).
smc="$( set +u; . "$RL"; NAME=box; SUDO_MODE=nopasswd
  ssh() { echo PROBED >&2; return 1; }
  remote_sudo_mode )"
assert_eq "remote_sudo_mode returns cached SUDO_MODE without probing" "$smc" "nopasswd"

# Forced (--nopasswd-sudo) install on an askpass box: writes a validated sudoers drop-in
# and flips the cached mode to nopasswd (rroot is NOT redirected → its arg is observable).
nin="$( set +u; . "$RL"; NAME=box; NOPASSWD_SUDO=1; SUDO_MODE=askpass
  rexec() { echo user; }
  rroot() { echo "ROOT: $1"; return 0; }
  maybe_setup_nopasswd
  echo "INSTALLED=$NOPASSWD_INSTALLED MODE=$SUDO_MODE" )"
assert_contains "nopasswd install targets the sudoers.d drop-in" "$nin" "/etc/sudoers.d/grow-box-sandbox"
assert_contains "nopasswd install grants NOPASSWD:ALL"           "$nin" "NOPASSWD:ALL"
assert_contains "nopasswd install validates via visudo -cf"     "$nin" "visudo -cf"
assert_contains "nopasswd install sets state + caches nopasswd"  "$nin" "INSTALLED=1 MODE=nopasswd"

# Already-passwordless box: no install attempted.
nno="$( set +u; . "$RL"; NAME=box; NOPASSWD_SUDO=1; SUDO_MODE=nopasswd
  rroot() { echo "SHOULD-NOT-INSTALL: $1"; }
  maybe_setup_nopasswd
  echo "INSTALLED=$NOPASSWD_INSTALLED" )"
case "$nno" in *SHOULD-NOT-INSTALL*) hit=bad;; *) hit=good;; esac
assert_eq "nopasswd skips install when sudo is already passwordless" "$hit" "good"
assert_contains "nopasswd no-op leaves state uninstalled" "$nno" "INSTALLED=0"

# remove_nopasswd runs a non-interactive `sudo -n rm` of the drop-in (record args to a
# file, since remove_nopasswd redirects the ssh call to /dev/null) and clears state.
rmf="$(mktemp)"
( set +u; . "$RL"; NAME=box; NOPASSWD_INSTALLED=1
  ssh() { echo "$*" >> "$rmf"; return 0; }
  remove_nopasswd >/dev/null 2>&1 )
assert_contains "remove_nopasswd runs 'sudo -n rm' of the drop-in" "$(cat "$rmf")" "sudo -n rm -f /etc/sudoers.d/grow-box-sandbox"
rm -f "$rmf"

# remove_nopasswd reports removal and re-arms askpass.
nrm="$( set +u; . "$RL"; NAME=box; NOPASSWD_INSTALLED=1
  ssh() { return 0; }
  remove_nopasswd 2>&1
  echo "INSTALLED=$NOPASSWD_INSTALLED MODE=$SUDO_MODE" )"
assert_contains "remove_nopasswd reports removal"                "$nrm" "removed the temporary passwordless-sudo drop-in"
assert_contains "remove_nopasswd clears state + re-arms askpass" "$nrm" "INSTALLED=0 MODE=askpass"

# _cleanup tears down the drop-in on exit (state-observable, since remove_nopasswd
# silences the ssh command).
ncl="$( set +u; . "$RL"; NAME=box; NOPASSWD_INSTALLED=1; NOPASSWD_KEEP=0
  ssh()   { return 0; }
  _cleanup >/dev/null 2>&1
  echo "INSTALLED=$NOPASSWD_INSTALLED" )"
assert_contains "_cleanup clears the drop-in state" "$ncl" "INSTALLED=0"

# _cleanup honors keep (leaves the drop-in installed).
# shellcheck disable=SC2034  # NAME/NOPASSWD_KEEP read by _cleanup inside the sourced $RL
nck="$( set +u; . "$RL"; NAME=box; NOPASSWD_INSTALLED=1; NOPASSWD_KEEP=1
  ssh() { return 0; }
  _cleanup
  echo "INSTALLED=$NOPASSWD_INSTALLED" )"
assert_contains "_cleanup keeps the drop-in when NOPASSWD_KEEP=1" "$nck" "INSTALLED=1"

# finalize under --nopasswd-sudo auto-removes (no interactive keep prompt).
# shellcheck disable=SC2034  # NAME/NOPASSWD_SUDO read by finalize_nopasswd inside the sourced $RL
nfin="$( set +u; . "$RL"; NAME=box; NOPASSWD_SUDO=1; NOPASSWD_INSTALLED=1
  ssh() { return 0; }
  finalize_nopasswd 2>&1
  echo "INSTALLED=$NOPASSWD_INSTALLED" )"
assert_contains "finalize auto-removes under --nopasswd-sudo" "$nfin" "INSTALLED=0"
