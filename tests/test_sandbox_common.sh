#!/usr/bin/env bash
# Verifies the shared lib exists, sources cleanly (no set -e leak), and defines the
# transport-agnostic auth/staging surface, the repo table and the run step. Sourced
# by tests/run.sh (already under set -uo pipefail), so we source the lib in a
# subshell to contain any globals.
: "${REPO_ROOT:?run via tests/run.sh}"
LIB="$REPO_ROOT/tools/sandbox/lib/sandbox-common.sh"
SR="$REPO_ROOT/tools/sandbox/setup-repos.sh"

assert_eq "lib file exists" "$( [ -f "$LIB" ] && echo yes || echo no )" "yes"

# launch-vm.sh must source the lib (checked without sourcing
# launch-vm.sh itself — it sets set -uo pipefail and would run main). Match ONLY the
# `. …sandbox-common.sh` source statement, not the `# shellcheck source=` comment.
srcline="$(grep -E '^[[:space:]]*\. .*lib/sandbox-common\.sh' "$REPO_ROOT/tools/sandbox/launch-vm.sh")"
assert_contains "launch-vm sources the lib" "$srcline" "sandbox-common.sh"

# Source the lib and assert the key functions are defined.
( set +u
  # shellcheck disable=SC1090
  . "$LIB"
  for fn in log warn die have quote_arg resolve_token register_deploy_key delete_deploy_key \
            run_cleanup ensure_stage stage_deploy_keys stage_ssh_key stage_token \
            stage_npmrc stage_scripts stage_repos stage_branch deploy_keys_staged \
            parse_repo_rows load_repos repo_optnames run_dir run_cmd; do
    [ "$(type -t "$fn")" = "function" ] || { echo "MISSING $fn"; exit 3; }
  done
) >/dev/null 2>&1
assert_eq "lib defines auth, staging, repo-table and run functions" "$?" "0"

# SANDBOX_LOG_TAG is honored by log().
# shellcheck disable=SC2034  # SANDBOX_LOG_TAG is read by log() inside the sourced lib, not here
tag_out="$( set +u; SANDBOX_LOG_TAG=launch-vm; . "$LIB"; log hello 2>&1 )"
assert_contains "log honors SANDBOX_LOG_TAG" "$tag_out" "[launch-vm]"

# --- repo table: SANDBOX_REPOS / SANDBOX_REPOS_FILE --------------------------
nl_rows="$( set +u; unset SANDBOX_REPOS_FILE; SANDBOX_REPOS=$'own|app|app\n\n  own | lib | lib-opt  \n'
  . "$LIB"; load_repos; printf '%s' "$REPOS" )"
assert_eq "SANDBOX_REPOS newline form parses (blank rows, spaces ignored)" "$nl_rows" $'own|app|app\nown|lib|lib-opt'

comma_rows="$( set +u; unset SANDBOX_REPOS_FILE; SANDBOX_REPOS='own|app|app, own|lib|lib-opt'
  . "$LIB"; load_repos; printf '%s' "$REPOS" )"
assert_eq "SANDBOX_REPOS comma form parses" "$comma_rows" $'own|app|app\nown|lib|lib-opt'

rfdir="$(mktemp -d)"
printf '# the repos for this box\nown|app|app\nown|lib|lib-opt  # second\n' > "$rfdir/repos.txt"
# shellcheck disable=SC2034  # SANDBOX_REPOS_FILE is read by load_repos inside the sourced $LIB
file_rows="$( set +u; unset SANDBOX_REPOS; SANDBOX_REPOS_FILE="$rfdir/repos.txt"
  . "$LIB"; load_repos; printf '%s' "$REPOS" )"
assert_eq "SANDBOX_REPOS_FILE form parses (comments skipped)" "$file_rows" $'own|app|app\nown|lib|lib-opt'

assert_fail "SANDBOX_REPOS and SANDBOX_REPOS_FILE together are refused" \
  bash -c 'SANDBOX_REPOS="o|r|n"; SANDBOX_REPOS_FILE="$2"; . "$1"; load_repos' _ "$LIB" "$rfdir/repos.txt"
assert_fail "SANDBOX_REPOS_FILE that does not exist is refused" \
  bash -c 'unset SANDBOX_REPOS; SANDBOX_REPOS_FILE="$2"; . "$1"; load_repos' _ "$LIB" "$rfdir/absent.txt"
rm -rf "$rfdir"

for bad in 'own|app' 'own|app|app|extra' 'own||app' 'own|..|app' 'own|app|.hidden' 'own|app|a;rm'; do
  assert_fail "malformed repo row '$bad' is refused" \
    bash -c 'unset SANDBOX_REPOS_FILE; SANDBOX_REPOS="$2"; . "$1"; load_repos' _ "$LIB" "$bad"
done
# Control: the same command accepts a well-formed row, so the failures above are the rows.
bash -c 'unset SANDBOX_REPOS_FILE; SANDBOX_REPOS="$2"; . "$1"; load_repos' _ "$LIB" 'own|.github|dotgithub' >/dev/null 2>&1
assert_eq "well-formed repo row (repo may start with a dot) is accepted" "$?" "0"

empty_rows="$( set +u; unset SANDBOX_REPOS SANDBOX_REPOS_FILE; . "$LIB"; load_repos; printf '[%s]' "$REPOS" )"
assert_eq "no SANDBOX_REPOS / SANDBOX_REPOS_FILE → empty table (no default rows)" "$empty_rows" "[]"

opts="$( set +u; . "$LIB"; repo_optnames $'o|r|one\no|r2|two' | tr '\n' ' ' )"
assert_eq "repo_optnames lists the optname column" "$opts" "one two "

# --- stage_repos writes/clears the staged `repos` file ------------------------
srdir="$(mktemp -d)"
( set +u; . "$LIB"; REPOS=$'o|r|one\no|r2|two'; stage_repos "$srdir" >/dev/null 2>&1 )
assert_eq "stage_repos writes the repos file" "$(cat "$srdir/repos" 2>/dev/null)" $'o|r|one\no|r2|two'
( set +u; . "$LIB"; REPOS=""; stage_repos "$srdir" >/dev/null 2>&1 )
assert_eq "stage_repos clears the repos file when the table is empty" "$( [ -f "$srdir/repos" ] && echo present || echo gone )" "gone"
rm -rf "$srdir"

# --- ensure_stage with an empty table skips git credentials (one log line) -----
cfg="$(mktemp -d)"
# shellcheck disable=SC2034  # SANDBOX_CONFIG_DIR/SANDBOX_NAME are read inside the sourced $LIB
es_out="$( set +u; unset SANDBOX_REPOS SANDBOX_REPOS_FILE SANDBOX_NPMRC; SANDBOX_CONFIG_DIR="$cfg"; SANDBOX_NAME=t
  . "$LIB"; load_repos; ensure_stage "" 2>&1 >/dev/null )"
assert_eq "ensure_stage logs the clone skip exactly once" \
  "$(printf '%s\n' "$es_out" | grep -c 'skipping the clone steps')" "1"
assert_eq "ensure_stage stages no git credentials without repos" \
  "$(find "$cfg/staging-t" -type f \( -name ssh_config -o -name gh_token -o -name repos -o -name '*.key' \) | wc -l | tr -d ' ')" "0"
assert_eq "ensure_stage still stages the bootstrap scripts" \
  "$( [ -f "$cfg/staging-t/setup-repos.sh" ] && echo yes || echo no )" "yes"
rm -rf "$cfg"

# --- run_cmd: SANDBOX_RUN_CMD in SANDBOX_RUN_DIR ------------------------------
# Skipped when SANDBOX_RUN_CMD is empty: the exec-fn is never called, and rc is 0.
# shellcheck disable=SC2034  # SANDBOX_NAME/SANDBOX_RUN_* are read by run_cmd inside the sourced $LIB
skip_out="$( set +u; SANDBOX_NAME=t; SANDBOX_RUN_CMD=""; . "$LIB"
  _fake() { echo "EXEC-CALLED:$1"; return 9; }; run_cmd _fake 2>&1; echo "rc=$?" )"
assert_contains "run_cmd skips with one log line when SANDBOX_RUN_CMD is empty" "$skip_out" "no SANDBOX_RUN_CMD set — skipping the run step"
assert_contains "run_cmd skip is not an error" "$skip_out" "rc=0"
case "$skip_out" in *EXEC-CALLED*) called=yes;; *) called=no;; esac
assert_eq "run_cmd skip never calls the exec-fn" "$called" "no"
# shellcheck disable=SC2034  # SANDBOX_NAME is read by run_cmd inside the sourced $LIB
skip_unset="$( set +u; unset SANDBOX_RUN_CMD; SANDBOX_NAME=t; . "$LIB"
  _fake() { echo "EXEC-CALLED"; }; run_cmd _fake 2>&1; echo "rc=$?" )"
assert_contains "run_cmd skips when SANDBOX_RUN_CMD is unset" "$skip_unset" "rc=0"

# Runs the command inside SANDBOX_RUN_DIR (a path with a space, to prove the quoting)
# through a real shell, and returns the command's own exit code.
rundir_root="$(mktemp -d)"; rundir="$rundir_root/run dir"; mkdir -p "$rundir"
# shellcheck disable=SC2034  # SANDBOX_NAME/SANDBOX_RUN_* are read by run_cmd inside the sourced $LIB
run_out="$( set +u; SANDBOX_NAME=t; SANDBOX_RUN_DIR="$rundir"; SANDBOX_RUN_CMD='pwd > where.txt; exit 7'
  . "$LIB"; _sh() { bash -c "$1"; }; run_cmd _sh >/dev/null 2>&1; echo "rc=$?" )"
assert_eq "run_cmd runs SANDBOX_RUN_CMD inside SANDBOX_RUN_DIR" "$(cat "$rundir/where.txt" 2>/dev/null)" "$rundir"
assert_eq "run_cmd propagates the command's exit code" "$run_out" "rc=7"
# shellcheck disable=SC2034  # SANDBOX_NAME/SANDBOX_RUN_* are read by run_cmd inside the sourced $LIB
ok_out="$( set +u; SANDBOX_NAME=t; SANDBOX_RUN_DIR="$rundir"; SANDBOX_RUN_CMD='true'
  . "$LIB"; _sh() { bash -c "$1"; }; run_cmd _sh >/dev/null 2>&1; echo "rc=$?" )"
assert_eq "run_cmd returns 0 when the command passes" "$ok_out" "rc=0"
rm -rf "$rundir_root"

# Without SANDBOX_RUN_DIR, the run dir is /opt/<optname> of the FIRST repo row.
# shellcheck disable=SC2034  # SANDBOX_NAME/SANDBOX_RUN_CMD are read by run_cmd inside the sourced $LIB
def_out="$( set +u; unset SANDBOX_RUN_DIR; SANDBOX_NAME=t; SANDBOX_RUN_CMD='make check'; . "$LIB"
  REPOS=$'own|app|first\nown|lib|second'
  _fake() { echo "EXEC:$1"; }; run_cmd _fake 2>&1 )"
assert_contains "run_cmd defaults to /opt/<first optname>" "$def_out" "EXEC:cd '/opt/first' && make check"

# --- provision.sh installs the ssh client + rsync (needed on a bare SSH host) ---
PROV="$REPO_ROOT/tools/sandbox/provision.sh"
apt_line="$(grep 'apt-get install -y -qq curl ca-certificates git jq yamllint shellcheck' "$PROV" | head -1)"
assert_contains "provision system installs openssh-client" "$apt_line" "openssh-client"
assert_contains "provision system installs rsync" "$apt_line" "rsync"

# --- stage_branch writes/clears the staged `branch` file ---------------------
# shellcheck disable=SC2034  # SANDBOX_BRANCH is read by stage_branch inside the sourced $LIB
brdir="$(mktemp -d)"
( set +u; SANDBOX_BRANCH=feat/xyz; . "$LIB"; stage_branch "$brdir" >/dev/null 2>&1 )
assert_eq "stage_branch writes the branch file" "$(cat "$brdir/branch" 2>/dev/null)" "feat/xyz"
# shellcheck disable=SC2034  # SANDBOX_BRANCH is read by stage_branch inside the sourced $LIB
( set +u; SANDBOX_BRANCH=""; . "$LIB"; stage_branch "$brdir" >/dev/null 2>&1 )
assert_eq "stage_branch clears the branch file when unset" "$( [ -f "$brdir/branch" ] && echo present || echo gone )" "gone"
rm -rf "$brdir"

# --- setup-repos.sh reads the same table on the box ---------------------------
sdir="$(mktemp -d)"
printf 'own|app|app\nown|lib|lib-opt\n' > "$sdir/repos"
# shellcheck disable=SC2034  # SANDBOX_SECRETS_DIR is read by the sourced $SR
staged="$( set +u; unset SANDBOX_REPOS SANDBOX_REPOS_FILE; SANDBOX_SECRETS_DIR="$sdir"
  . "$SR"; load_repos )"
assert_eq "setup-repos reads the staged repos file by default" "$staged" $'own|app|app\nown|lib|lib-opt'
# shellcheck disable=SC2034  # SANDBOX_REPOS/SANDBOX_SECRETS_DIR are read by the sourced $SR
envwins="$( set +u; unset SANDBOX_REPOS_FILE; SANDBOX_REPOS='own|x|x, own|y|y'; SANDBOX_SECRETS_DIR="$sdir"
  . "$SR"; load_repos )"
assert_eq "setup-repos: SANDBOX_REPOS (comma form) wins over the staged file" "$envwins" $'own|x|x\nown|y|y'
assert_fail "setup-repos refuses a malformed row" \
  bash -c 'unset SANDBOX_REPOS_FILE; SANDBOX_REPOS="own|app"; SANDBOX_SECRETS_DIR="$2"; . "$1"; load_repos' _ "$SR" "$sdir"
rm -f "$sdir/repos"
sr_out="$(unset SANDBOX_REPOS SANDBOX_REPOS_FILE; HOME="$sdir" SANDBOX_SECRETS_DIR="$sdir" bash "$SR" 2>&1)"; sr_rc=$?
assert_eq "setup-repos with no table exits 0" "$sr_rc" "0"
assert_contains "setup-repos with no table skips the clone with one log line" "$sr_out" "skipping clone"
rm -rf "$sdir"
