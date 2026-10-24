#!/usr/bin/env bash
# Check that every vendored Skill is byte-identical to what its lock entry
# recorded, and that the lock and the Skills directory name the same set.
#
# skillFolderHash in .agents/.skill-lock.json is the git tree id of the Skill's
# folder upstream. A folder committed here unchanged has the same tree id, so
# comparing ids needs no network and no CLI: any edit, added file or lost
# executable bit changes the id.
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
lock="$repo/.agents/.skill-lock.json"
rev=${1:-HEAD}
fail=0

while IFS=$'\t' read -r name want; do
  have=$(git -C "$repo" rev-parse -q --verify "$rev:.agents/skills/$name" 2>/dev/null) || have=missing
  if [ "$have" = "$want" ]; then
    echo "ok        $name"
  else
    echo "DIFFERS   $name  lock=$want  here=$have"
    fail=1
  fi
done < <(jq -r '.skills | to_entries[] | "\(.key)\t\(.value.skillFolderHash)"' "$lock")

while IFS= read -r dir; do
  jq -e --arg n "$dir" '.skills | has($n)' "$lock" >/dev/null \
    || { echo "UNLOCKED  $dir has no lock entry"; fail=1; }
done < <(git -C "$repo" ls-tree --name-only "$rev:.agents/skills/")

[ "$fail" = 0 ] && echo "every Skill matches its lock entry"
exit "$fail"
