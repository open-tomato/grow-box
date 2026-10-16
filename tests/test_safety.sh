#!/usr/bin/env bash
# Safety guards: staging must exist before anything is copied, converge never
# deletes a user's files, the token fallback is opt-in, and reset/destroy remove the
# credentials a run left behind. Every remote command is stubbed: the generated
# commands run against temp dirs on this machine, and launch-vm.sh runs with a
# fake `multipass` on PATH. Sourced by tests/run.sh (already set -uo pipefail).
# SC2034: the variables set before each `. "$RL"` / `. "$LIB"` are read inside the
# sourced scripts. SC2069: `2>&1 >/dev/null` is deliberate — it captures stderr only.
# shellcheck disable=SC2034,SC2069
: "${REPO_ROOT:?run via tests/run.sh}"
RL="$REPO_ROOT/tools/sandbox/launch-remote.sh"
VM="$REPO_ROOT/tools/sandbox/launch-vm.sh"
LIB="$REPO_ROOT/tools/sandbox/lib/sandbox-common.sh"
SR="$REPO_ROOT/tools/sandbox/setup-repos.sh"

# A fake bin dir whose multipass/ssh/gh only record their calls and fail.
safety_fakebin() {
  local d; d="$(mktemp -d)"
  for t in multipass ssh scp rsync gh; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexit 1\n' "$t" "$d" > "$d/$t"
    chmod +x "$d/$t"
  done
  printf '%s' "$d"
}

# ===================== 1. empty staging never reaches rcopy =====================

# converge: stage_all failing stops the run before anything is copied.
cv_fail="$( set +u; . "$RL"; NAME=box; IP=192.0.2.10; REPOS='own|app|app'
  preflight() { :; }; maybe_setup_nopasswd() { :; }; prepare_host() { :; }
  stage_all() { die "staging failed (test)"; }
  rcopy() { echo "RCOPY-CALLED src=[$1]"; }
  rexec() { echo "EXEC"; }; rroot() { echo "ROOT"; }; rexec_tty() { :; }
  remote_sudo_mode() { echo nopasswd; }; finalize_nopasswd() { :; }; run_cmd() { :; }
  converge 2>&1 )"; cv_fail_rc=$?
case "$cv_fail" in *RCOPY-CALLED*) copied=yes;; *) copied=no;; esac
assert_eq "remote converge: failing stage_all never reaches rcopy" "$copied" "no"
# The status of the command substitution itself: converge exits the subshell, so an
# `echo rc=` inside it would never run.
assert_not_eq "remote converge: failing stage_all exits non-zero" "$cv_fail_rc" "0"

# converge: stage_all succeeding with a path that is not a directory also stops.
cv_nodir="$( set +u; . "$RL"; NAME=box; IP=192.0.2.10; REPOS='own|app|app'
  preflight() { :; }; maybe_setup_nopasswd() { :; }; prepare_host() { :; }
  stage_all() { printf '/nonexistent/staging-box'; }
  rcopy() { echo "RCOPY-CALLED src=[$1]"; }
  rexec() { echo "EXEC"; }; rroot() { echo "ROOT"; }; rexec_tty() { :; }
  remote_sudo_mode() { echo nopasswd; }; finalize_nopasswd() { :; }; run_cmd() { :; }
  converge 2>&1; echo "rc=$?" )"
case "$cv_nodir" in *RCOPY-CALLED*) copied=yes;; *) copied=no;; esac
assert_eq "remote converge: a missing staging dir never reaches rcopy" "$copied" "no"

# rcopy refuses "", "/" and any dir outside $CONFIG_DIR/staging-*, before any ssh.
rcfg="$(mktemp -d)"; mkdir -p "$rcfg/staging-box" "$rcfg/elsewhere"
for src in "" "/" "$rcfg/elsewhere" "$rcfg/staging-box/../elsewhere"; do
  # shellcheck disable=SC2034  # CONFIG_DIR/NAME are read by rcopy inside the sourced $RL
  rc_out="$( set +u; . "$RL"; NAME=box; CONFIG_DIR="$rcfg"
    ssh() { echo "SSH-CALLED"; }; rsync() { echo "RSYNC-CALLED"; }; scp() { echo "SCP-CALLED"; }
    rcopy "$src" .cache/x 2>&1; echo "rc=$?" )"
  case "$rc_out" in *-CALLED*) moved=yes;; *) moved=no;; esac
  assert_eq "rcopy refuses src '[$src]' before any transfer" "$moved" "no"
  assert_contains "rcopy refuses src '[$src]' with an error" "$rc_out" "rcopy: refusing"
done
# Control: the box's own staging dir is accepted and the copy is attempted.
# shellcheck disable=SC2034  # CONFIG_DIR/NAME are read by rcopy inside the sourced $RL
rc_ok="$( set +u; . "$RL"; NAME=box; CONFIG_DIR="$rcfg"
  ssh() { echo "SSH-CALLED"; }; rsync() { echo "RSYNC-CALLED"; }; scp() { echo "SCP-CALLED"; }
  rcopy "$rcfg/staging-box" .cache/x 2>&1 )"
assert_contains "rcopy accepts \$CONFIG_DIR/staging-<name>" "$rc_ok" "SSH-CALLED"
rm -rf "$rcfg"

# launch-vm.sh: a staging failure inside ensure_stage stops before multipass runs.
vfake="$(safety_fakebin)"; vcfg="$(mktemp -d)"
vm_out="$(unset SANDBOX_REPOS SANDBOX_REPOS_FILE; PATH="$vfake:$PATH" HOME="$vcfg" \
  SANDBOX_CONFIG_DIR="$vcfg" SANDBOX_NPMRC="$vcfg/absent-npmrc" bash "$VM" 2>&1)"; vm_rc=$?
assert_not_eq "launch-vm: staging failure exits non-zero" "$vm_rc" "0"
assert_eq "launch-vm: staging failure never calls multipass" \
  "$(cat "$vfake/calls" 2>/dev/null | grep -c '^multipass')" "0"
assert_contains "launch-vm: staging failure names the cause" "$vm_out" "file not found"
rm -rf "$vfake" "$vcfg"

# ===================== 2. converge never deletes a user's files =====================

# The residue clean runs against a temp home through a local bash. A fake `stat`
# reports uid 0 for paths ending in "rootowned", so the root-owned branch is reachable
# without root. Only the guarded removal is executed; other root commands are echoed.
res_home="$(mktemp -d)"; sfake="$(mktemp -d)"
printf '#!/bin/sh\nfor a; do last="$a"; done\ncase "$last" in *rootowned) echo 0; exit 0;; esac\nexec /usr/bin/stat "$@"\n' > "$sfake/stat"
chmod +x "$sfake/stat"
residue_run() {   # $1 = repo table; runs run_bootstrap with the stubs below
  ( set +u; . "$RL"; NAME=box; SECRETS_REMOTE=.s; DEST_REMOTE=.d; REPOS="$1"
    rcopy() { :; }; rexec_tty() { :; }; remote_sudo_mode() { echo nopasswd; }
    rexec() { case "$1" in *'printf %s'*) printf %s "$res_home" ;; *SANDBOX_SECRETS_DIR=*setup-repos.sh*) echo "SETUP-REPOS-RAN" ;; *) : ;; esac; }
    rroot() { case "$1" in *GROWBOX-REFUSE*) PATH="$sfake:$PATH" bash -c "$1" ;; *) echo "ROOT: $1" ;; esac; }
    run_bootstrap "$res_home/../staging-box" 2>&1; echo "rc=$?" )
}
mkdir -p "$res_home/userdir" && echo keep > "$res_home/userdir/notes.txt"
res_user="$(residue_run 'own|userdir|userdir')"
assert_eq "residue clean keeps a user-owned non-git dir" "$(cat "$res_home/userdir/notes.txt" 2>/dev/null)" "keep"
assert_contains "residue clean names the refused path" "$res_user" "$res_home/userdir"
assert_contains "residue clean says to move it or pick another optname" "$res_user" "pick another optname"
case "$res_user" in *SETUP-REPOS-RAN*) cloned=yes;; *) cloned=no;; esac
assert_eq "residue refusal stops before setup-repos" "$cloned" "no"
mkdir -p "$res_home/emptydir"
residue_run 'own|emptydir|emptydir' >/dev/null
assert_eq "residue clean removes an empty dir" "$( [ -e "$res_home/emptydir" ] && echo present || echo gone )" "gone"
mkdir -p "$res_home/rootowned" && echo x > "$res_home/rootowned/f"
residue_run 'own|rootowned|rootowned' >/dev/null
assert_eq "residue clean removes a root-owned dir" "$( [ -e "$res_home/rootowned" ] && echo present || echo gone )" "gone"
mkdir -p "$res_home/repo/.git" && echo x > "$res_home/repo/f"
res_git="$(residue_run 'own|repo|repo')"
assert_eq "residue clean keeps a git checkout" "$( [ -f "$res_home/repo/f" ] && echo kept || echo gone )" "kept"
assert_contains "residue clean lets setup-repos run past a git checkout" "$res_git" "SETUP-REPOS-RAN"
rm -rf "$res_home" "$sfake"

# ===================== 3. the token fallback is opt-in =====================

tok_stage() {   # $1 = token passed in (as resolve_token would); env set by the caller
  ( set +u; . "$LIB"; SANDBOX_NAME=box; REPOS='own|app|app'
    stage_deploy_keys() { return 1; }; stage_npmrc() { :; }
    ensure_stage "$1" 2>&1 >/dev/null; echo "rc=$?" )
}
tcfg="$(mktemp -d)"
t_off="$(unset SANDBOX_ALLOW_TOKEN_FALLBACK SANDBOX_GH_TOKEN_FILE; GH_TOKEN=explicit-tok SANDBOX_CONFIG_DIR="$tcfg" tok_stage explicit-tok)"
assert_contains "no opt-in: deploy-key failure stops the run" "$t_off" "SANDBOX_ALLOW_TOKEN_FALLBACK=1"
case "$t_off" in *"rc=0"*) offrc=zero;; *) offrc=nonzero;; esac
assert_eq "no opt-in: exits non-zero" "$offrc" "nonzero"
assert_eq "no opt-in: no token is staged" "$( [ -f "$tcfg/staging-box/gh_token" ] && echo staged || echo absent )" "absent"
rm -rf "$tcfg"

tcfg="$(mktemp -d)"
t_on="$(unset SANDBOX_GH_TOKEN_FILE; SANDBOX_ALLOW_TOKEN_FALLBACK=1 GH_TOKEN=explicit-tok SANDBOX_CONFIG_DIR="$tcfg" tok_stage from-gh-auth)"
assert_eq "opt-in: the explicit GH_TOKEN is staged" "$(cat "$tcfg/staging-box/gh_token" 2>/dev/null)" "explicit-tok"
assert_contains "opt-in: the warning says the token is copied to the box" "$t_on" "copied to the box"
case "$t_on" in *"read-only token"*) ro=claimed;; *) ro=absent;; esac
assert_eq "opt-in: the warning no longer calls the token read-only" "$ro" "absent"
rm -rf "$tcfg"

tcfg="$(mktemp -d)"; printf 'file-tok' > "$tcfg/tokfile"
(unset GH_TOKEN; SANDBOX_ALLOW_TOKEN_FALLBACK=1 SANDBOX_GH_TOKEN_FILE="$tcfg/tokfile" SANDBOX_CONFIG_DIR="$tcfg" tok_stage from-gh-auth >/dev/null)
assert_eq "opt-in: a SANDBOX_GH_TOKEN_FILE token is staged" "$(cat "$tcfg/staging-box/gh_token" 2>/dev/null)" "file-tok"
rm -rf "$tcfg"

# The token `gh auth token` returns is never used for the fallback.
tcfg="$(mktemp -d)"
t_gh="$( set +u; unset GH_TOKEN SANDBOX_GH_TOKEN_FILE; SANDBOX_ALLOW_TOKEN_FALLBACK=1; SANDBOX_CONFIG_DIR="$tcfg"
  . "$LIB"; SANDBOX_NAME=box; REPOS='own|app|app'
  have() { return 0; }; gh() { echo gh-oauth-tok; }
  stage_deploy_keys() { return 1; }; stage_npmrc() { :; }
  ensure_stage "$(resolve_token)" 2>&1 >/dev/null; echo "rc=$?" )"
assert_eq "opt-in: the gh auth token is never staged" "$( [ -f "$tcfg/staging-box/gh_token" ] && echo staged || echo absent )" "absent"
assert_contains "opt-in without GH_TOKEN/SANDBOX_GH_TOKEN_FILE says what to set" "$t_gh" "GH_TOKEN or SANDBOX_GH_TOKEN_FILE"
rm -rf "$tcfg"

# A token staged by an earlier run is not reused without the opt-in.
tcfg="$(mktemp -d)"; mkdir -p "$tcfg/staging-box"; printf 'old-tok' > "$tcfg/staging-box/gh_token"
( set +u; unset SANDBOX_ALLOW_TOKEN_FALLBACK; SANDBOX_CONFIG_DIR="$tcfg"; . "$LIB"; SANDBOX_NAME=box; REPOS='own|app|app'
  stage_deploy_keys() { return 0; }; stage_npmrc() { :; }
  ensure_stage tok >/dev/null 2>&1 )
assert_eq "no opt-in: a stale staged token is removed" "$( [ -f "$tcfg/staging-box/gh_token" ] && echo staged || echo absent )" "absent"
rm -rf "$tcfg"

# A staged token never survives a run that does not stage a fresh explicit one.
stale_stage() {   # $1 = repo table; env comes from the caller
  ( set +u; SANDBOX_CONFIG_DIR="$tcfg"; . "$LIB"; SANDBOX_NAME=box; REPOS="$1"
    stage_deploy_keys() { return 1; }; stage_npmrc() { :; }
    ensure_stage tok 2>&1 >/dev/null; echo "rc=$?" )
}
stale_state() { if [ -f "$tcfg/staging-box/gh_token" ]; then cat "$tcfg/staging-box/gh_token"; else echo absent; fi; }

tcfg="$(mktemp -d)"; mkdir -p "$tcfg/staging-box"; printf 'old-tok' > "$tcfg/staging-box/gh_token"
: > "$tcfg/staging-box/ssh_config"; : > "$tcfg/staging-box/app.key"
(unset SANDBOX_ALLOW_TOKEN_FALLBACK; stale_stage 'own|app|app' >/dev/null)
assert_eq "reused deploy keys: a stale staged token is removed" "$(stale_state)" "absent"
rm -rf "$tcfg"

tcfg="$(mktemp -d)"; mkdir -p "$tcfg/staging-box"; printf 'old-tok' > "$tcfg/staging-box/gh_token"
(unset SANDBOX_ALLOW_TOKEN_FALLBACK; stale_stage '' >/dev/null)
assert_eq "empty repo table: a stale staged token is removed" "$(stale_state)" "absent"
rm -rf "$tcfg"

tcfg="$(mktemp -d)"; mkdir -p "$tcfg/staging-box"; printf 'old-tok' > "$tcfg/staging-box/gh_token"
(unset SANDBOX_GH_TOKEN_FILE; SANDBOX_ALLOW_TOKEN_FALLBACK=1 GH_TOKEN=explicit-tok stale_stage 'own|app|app' >/dev/null)
assert_eq "opt-in: a staged token is re-staged from GH_TOKEN, not reused" "$(stale_state)" "explicit-tok"
rm -rf "$tcfg"

tcfg="$(mktemp -d)"; mkdir -p "$tcfg/staging-box"; printf 'old-tok' > "$tcfg/staging-box/gh_token"
st_out="$(unset GH_TOKEN SANDBOX_GH_TOKEN_FILE; SANDBOX_ALLOW_TOKEN_FALLBACK=1 stale_stage 'own|app|app')"
assert_eq "opt-in without an explicit token: the staged token is removed" "$(stale_state)" "absent"
assert_contains "opt-in without an explicit token: the run stops" "$st_out" "needs an explicit token"
rm -rf "$tcfg"

# ===================== 4. reset and destroy remove credentials =====================

# setup-repos.sh marks the .npmrc it writes.
nh="$(mktemp -d)"; mkdir -p "$nh/secrets"; printf 'registry=https://npm.example.com/\n' > "$nh/secrets/npmrc"
( set +u; HOME="$nh"; SANDBOX_SECRETS_DIR="$nh/secrets"; . "$SR"; install_npmrc >/dev/null 2>&1 )
assert_eq "setup-repos marks the .npmrc it writes" "$(head -n1 "$nh/.npmrc" 2>/dev/null)" "# written by Grow Box (setup-repos.sh); --reset removes this file"
assert_contains "setup-repos keeps the staged .npmrc content" "$(cat "$nh/.npmrc" 2>/dev/null)" "registry=https://npm.example.com/"
rm -rf "$nh"

# run_reset removes the per-repo keys, the snippet, only our Include line, and a marked
# .npmrc. The credential command runs against a temp home through a local bash.
reset_home() {   # $1 = .npmrc first line; prints the temp home path
  local h; h="$(mktemp -d)"; mkdir -p "$h/.ssh"
  : > "$h/.ssh/app.key"; : > "$h/.ssh/lib.key"; : > "$h/.ssh/own.key"; : > "$h/.ssh/sandbox_config"
  printf 'Include ~/.ssh/sandbox_config\nHost mine\n  User me\n' > "$h/.ssh/config"
  printf '%s\nregistry=x\n' "$1" > "$h/.npmrc"
  printf '%s' "$h"
}
reset_run() {   # $1 = home, $2 = optional PATH prefix; the credential command runs locally
  ( set +u; . "$RL"; NAME=box; SANDBOX_NAME=box; SECRETS_REMOTE=.s; DEST_REMOTE=.d; CONFIG_DIR=/nonexistent-cfg
    REPOS=$'own|app|app\nown|lib|lib'; preflight() { :; }; reset_home_dir="$1"; reset_path="${2:-}"
    rexec() { case "$1" in *'printf %s'*) printf %s "$reset_home_dir" ;; *.ssh*) PATH="$reset_path$PATH" bash -c "$1" ;; *) : ;; esac; }
    rroot() { :; }
    run_reset >/dev/null 2>&1 )
}
h1="$(reset_home '# written by Grow Box (setup-repos.sh); --reset removes this file')"
reset_run "$h1"
assert_eq "reset removes each row's deploy key and the snippet" "$(ls "$h1/.ssh" | tr '\n' ' ')" "config own.key "
assert_eq "reset removes only the Include line it added" "$(cat "$h1/.ssh/config")" $'Host mine\n  User me'
assert_eq "reset removes a .npmrc Grow Box wrote" "$( [ -f "$h1/.npmrc" ] && echo present || echo gone )" "gone"
h2="$(reset_home 'registry=https://mine.example.com/')"
reset_run "$h2"
assert_eq "reset keeps a .npmrc Grow Box did not write" "$( [ -f "$h2/.npmrc" ] && echo present || echo gone )" "present"
assert_eq "reset still removes the keys when the .npmrc is not ours" "$( [ -f "$h2/.ssh/app.key" ] && echo present || echo gone )" "gone"
rm -rf "$h1" "$h2"

# ~/.ssh/config is left untouched when mktemp or the filtering grep fails.
cfgfake="$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' > "$cfgfake/mktemp"; chmod +x "$cfgfake/mktemp"
h3="$(reset_home 'registry=x')"; cfg_before="$(cat "$h3/.ssh/config")"
reset_run "$h3" "$cfgfake:"
assert_eq "reset keeps ~/.ssh/config intact when mktemp fails" "$(cat "$h3/.ssh/config")" "$cfg_before"
rm -f "$cfgfake/mktemp"
real_grep="$(command -v grep)"
printf '#!/bin/sh\ncase "$*" in *-vxF*) exit 2;; esac\nexec %s "$@"\n' "$real_grep" > "$cfgfake/grep"; chmod +x "$cfgfake/grep"
h4="$(reset_home 'registry=x')"; cfg_before="$(cat "$h4/.ssh/config")"
reset_run "$h4" "$cfgfake:"
assert_eq "reset keeps ~/.ssh/config intact when grep fails" "$(cat "$h4/.ssh/config")" "$cfg_before"
rm -rf "$cfgfake" "$h3" "$h4"

# Keys named in ~/.ssh/sandbox_config are removed even when their row left the table;
# only ~/.ssh/<name>.key entries count.
h5="$(reset_home 'registry=x')"; : > "$h5/.ssh/gone.key"; : > "$h5/.ssh/elsewhere.pem"
printf 'Host gh-gone\n  IdentityFile ~/.ssh/gone.key\nHost gh-x\n  IdentityFile ~/.ssh/elsewhere.pem\nHost gh-y\n  IdentityFile /etc/ssh/ssh_host_ed25519_key\n' > "$h5/.ssh/sandbox_config"
reset_run "$h5"
assert_eq "reset removes a key the snippet names but the table does not" "$( [ -f "$h5/.ssh/gone.key" ] && echo present || echo gone )" "gone"
assert_eq "reset keeps a snippet entry that is not a Grow Box key" "$( [ -f "$h5/.ssh/elsewhere.pem" ] && echo present || echo gone )" "present"
rm -rf "$h5"

# Reset removes a clone target only when it is a git checkout, root-owned or empty;
# anything else stops the reset, names the path, and nothing is removed.
rr_home="$(mktemp -d)"; rr_fake="$(mktemp -d)"
printf '#!/bin/sh\nfor a; do last="$a"; done\ncase "$last" in *rootowned) echo 0; exit 0;; esac\nexec /usr/bin/stat "$@"\n' > "$rr_fake/stat"; chmod +x "$rr_fake/stat"
reset_guard_run() {   # $1 = repo table
  ( set +u; . "$RL"; NAME=box; SANDBOX_NAME=box; SECRETS_REMOTE=.s; DEST_REMOTE=.d; CONFIG_DIR=/nonexistent-cfg
    REPOS="$1"; preflight() { :; }
    rexec() { case "$1" in *'printf %s'*) printf %s "$rr_home" ;; *) : ;; esac; }
    rroot() { case "$1" in *"$rr_home"*) PATH="$rr_fake:$PATH" bash -c "$1" ;; *) echo "ROOT: $1" ;; esac; }
    run_reset 2>&1; echo "rc=$?" )
}
mkdir -p "$rr_home/Documents" "$rr_home/repo/.git" && echo mine > "$rr_home/Documents/notes.txt"
rr_out="$(reset_guard_run $'own|repo|repo\nown|Documents|Documents')"
assert_eq "reset keeps a user-owned non-git dir" "$(cat "$rr_home/Documents/notes.txt" 2>/dev/null)" "mine"
assert_contains "reset names the refused path" "$rr_out" "$rr_home/Documents"
assert_eq "reset removes nothing when one target is refused" "$( [ -d "$rr_home/repo/.git" ] && echo kept || echo gone )" "kept"
case "$rr_out" in *"ROOT: rm -f /opt"*) rr_unlinked=yes;; *) rr_unlinked=no;; esac
assert_eq "a refused reset unlinks nothing under /opt" "$rr_unlinked" "no"
rm -rf "$rr_home/Documents"; mkdir -p "$rr_home/emptydir" "$rr_home/rootowned" && echo x > "$rr_home/rootowned/f"
reset_guard_run $'own|repo|repo\nown|emptydir|emptydir\nown|rootowned|rootowned' >/dev/null
assert_eq "reset removes a git checkout, an empty dir and a root-owned dir" \
  "$(ls "$rr_home" | tr '\n' ' ')" ""
rm -rf "$rr_home" "$rr_fake"

# launch-vm.sh --destroy deletes this VM's host staging dir, and only that one.
vfake="$(safety_fakebin)"; vcfg="$(mktemp -d)"
mkdir -p "$vcfg/staging-growbox-sandbox" "$vcfg/staging-other"; : > "$vcfg/staging-growbox-sandbox/app.key"
(unset SANDBOX_VM; PATH="$vfake:$PATH" HOME="$vcfg" SANDBOX_CONFIG_DIR="$vcfg" bash "$VM" --destroy >/dev/null 2>&1)
assert_eq "launch-vm --destroy deletes the VM's staging dir" "$( [ -d "$vcfg/staging-growbox-sandbox" ] && echo present || echo gone )" "gone"
assert_eq "launch-vm --destroy keeps other staging dirs" "$( [ -d "$vcfg/staging-other" ] && echo present || echo gone )" "present"
rm -rf "$vfake" "$vcfg"

# ===================== 5. README =====================
readme="$(cat "$REPO_ROOT/README.md")"
assert_contains "README has a Trust and safety section" "$readme" "## Trust and safety"
assert_contains "README warns SANDBOX_RUN_CMD is logged in clear" "$readme" "never put a secret in it"
assert_contains "README says the token fallback is opt-in" "$readme" "SANDBOX_ALLOW_TOKEN_FALLBACK=1"
