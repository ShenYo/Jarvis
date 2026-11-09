#!/usr/bin/env bash
# Check that every vendored Skill is byte-identical to what its lock entry
# recorded, and that the lock and the Skills directory name the same set.
#
# skillFolderHash in .agents/.skill-lock.json is the git tree id of the Skill's
# folder upstream. A folder committed here unchanged has the same tree id, so
# comparing ids needs no network and no CLI: any edit, added file or lost
# executable bit changes the id.
#
# A Skill named in `maintained` is written in this repository, not installed by
# a CLI, so it has no lock entry. Should one ever gain a lock entry, a CLI has
# installed a Skill over it, and the check fails.
set -uo pipefail

maintained=" session-notes "

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
  locked=0
  jq -e --arg n "$dir" '.skills | has($n)' "$lock" >/dev/null && locked=1
  case $maintained in
    *" $dir "*)
      if [ "$locked" = 1 ]; then echo "LOCKED    $dir is maintained here but has a lock entry"; fail=1
      else echo "here      $dir"; fi ;;
    *) [ "$locked" = 1 ] || { echo "UNLOCKED  $dir has no lock entry"; fail=1; } ;;
  esac
done < <(git -C "$repo" ls-tree --name-only "$rev:.agents/skills/")

[ "$fail" = 0 ] && echo "every Skill matches its lock entry or is maintained here"
exit "$fail"
