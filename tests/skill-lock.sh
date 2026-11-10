#!/usr/bin/env bash
# Behaviour tests for scripts/check-skill-lock.sh.
#
# CI runs the script against the real tree, which takes neither of the
# branches that guard "the vendored Skills are not ours to edit": a Skill
# maintained here that a CLI later locks, and a Skill on disk that is neither
# locked nor maintained here. Each case builds a scratch Git repository with
# its own copy of the script and fixture lock file, and asserts the exit
# status and the line the script reports.
#
# SCRIPT_UNDER_TEST=<path> runs another copy of the script, so a mutated copy
# can be shown to fail this test.
#
# Sandboxes are left in place; see tests/claude-guard.sh for why.
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="${SCRIPT_UNDER_TEST:-$repo/scripts/check-skill-lock.sh}"
root=$(mktemp -d "${TMPDIR:-/tmp}/skill-lock-test.XXXXXX")
echo "sandboxes: $root"

fails=0
total=0

# fixture <name> <skill>...: a repository with the script, the named Skills
# committed, and a lock file that records every Skill given as "lock:<name>"
# with its real tree id; a plain <name> is committed but left out of the lock.
fixture() {
  local name=$1 w="$root/$1" arg skill
  shift
  git init -q -b main "$w"
  mkdir -p "$w/scripts" "$w/.agents/skills"
  cp "$script" "$w/scripts/check-skill-lock.sh"
  for arg in "$@"; do
    skill=${arg#lock:}
    mkdir -p "$w/.agents/skills/$skill"
    printf '%s\n' "$skill" >"$w/.agents/skills/$skill/SKILL.md"
  done
  git -C "$w" add -A
  git -C "$w" -c user.name=t -c user.email=t@example.invalid commit -q -m "chore: seed"
  {
    printf '{"skills":{'
    local first=1
    for arg in "$@"; do
      case $arg in lock:*) ;; *) continue ;; esac
      skill=${arg#lock:}
      [ "$first" = 1 ] || printf ','
      first=0
      printf '"%s":{"skillFolderHash":"%s"}' "$skill" \
        "$(git -C "$w" rev-parse "HEAD:.agents/skills/$skill")"
    done
    printf '}}\n'
  } >"$w/.agents/.skill-lock.json"
}

# expect <name> <want-exit> <want-line> : run the fixture's script and check
# the exit status and that the output holds the line (empty: no line wanted).
expect() {
  local name=$1 want_exit=$2 want_line=$3 got
  total=$((total + 1))
  bash "$root/$name/scripts/check-skill-lock.sh" >"$root/$name.log" 2>&1
  got=$?
  if [ "$got" = "$want_exit" ] && { [ -z "$want_line" ] || grep -Fq -- "$want_line" "$root/$name.log"; }; then
    echo "ok   $name: exit $want_exit${want_line:+, reports '$want_line'}"
  else
    echo "FAIL $name: want exit $want_exit with '${want_line}', got exit $got"
    sed 's/^/     /' "$root/$name.log" | head -8
    fails=$((fails + 1))
  fi
}

# A locked Skill and a maintained one with no lock entry: the real layout.
fixture clean lock:alpha session-notes
expect clean 0 "here      session-notes"

# A maintained Skill that the lock also names: a CLI installed over it.
fixture locked lock:alpha lock:session-notes
expect locked 1 "LOCKED    session-notes is maintained here but has a lock entry"

# A Skill on disk that is neither locked nor maintained here.
fixture unlocked lock:alpha session-notes beta
expect unlocked 1 "UNLOCKED  beta has no lock entry"

# A name that only occurs inside a maintained name is not maintained.
fixture substring lock:alpha session-notes notes session
expect substring 1 "UNLOCKED  notes has no lock entry"
expect substring 1 "UNLOCKED  session has no lock entry"

echo
if [ "$fails" -gt 0 ]; then echo "$fails of $total failed"; exit 1; fi
echo "all $total passed"
