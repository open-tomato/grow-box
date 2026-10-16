#!/usr/bin/env bash
# Privacy check on every commit in a range: the files each commit adds or changes, as that commit
# holds them, so something added in one commit and removed in a later one is still found.
# Usage: bash scripts/privacy-history.sh <range>   e.g. origin/integration..HEAD, or HEAD for all
# Exit: 0 nothing found, 1 findings, 2 a scan could not run.
set -euo pipefail
range="${1:?usage: privacy-history.sh <range>}"
root="$(git rev-parse --show-toplevel)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
denylist=()
if [ -n "${PRIVACY_DENYLIST:-}" ]; then denylist=(--denylist "$PRIVACY_DENYLIST"); fi
status=0
for commit in $(git rev-list --reverse "$range"); do
  files="$work/$commit"
  mkdir -p "$files"
  git diff-tree --root --no-commit-id --name-only -r --diff-filter=ACMRT -z "$commit" |
    while IFS= read -r -d '' file; do
      mkdir -p "$files/$(dirname "$file")"
      git show "$commit:$file" > "$files/$file"
    done
  args=("$files")
  if git cat-file -e "$commit:.privacy-reviewed" 2>/dev/null; then
    git show "$commit:.privacy-reviewed" > "$work/reviewed-$commit"
    args+=(--reviewed "$work/reviewed-$commit")
  fi
  result=0
  out="$(PRIVACY_DENYLIST= bun "$root/scripts/privacy-check.ts" "${args[@]}" ${denylist[@]+"${denylist[@]}"} 2>&1)" || result=$?
  if [ "$result" -ne 0 ]; then
    echo "commit ${commit:0:12}:"
    printf '%s\n' "$out"
    if [ "$result" -eq 2 ] || [ "$status" -eq 2 ]; then status=2; else status=1; fi
  fi
done
exit "$status"
