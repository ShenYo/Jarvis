#!/usr/bin/env bash
# Behaviour tests for sync-personal-skills.sh, the Skill bridge.
#
# Every case runs the script with HOME (and CODEX_HOME) pointed at a scratch
# directory holding its own small ~/.Jarvis fixture, so nothing here reads or
# writes the real ~/.claude, ~/.codex, ~/.agents or this checkout's Skills.
#
# SCRIPT_UNDER_TEST=<path> runs another copy of the script, so a mutated copy
# or the script at origin/main can be shown to fail this test.
#
# Sandboxes are left in place; see tests/claude-guard.sh for why.
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="${SCRIPT_UNDER_TEST:-$repo/sync-personal-skills.sh}"
root=$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/sync-skills-test.XXXXXX")" && pwd -P)
echo "sandboxes: $root"

fails=0
total=0

ok()  { total=$((total + 1)); echo "ok   $1"; }
bad() { total=$((total + 1)); fails=$((fails + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && sed 's/^/     /' "$2" | head -8; }

# home <name>: a sandbox HOME with a fixture ~/.Jarvis holding the Skills
# alpha and beta, one grouped Skill (grp/gamma, linked as grp-gamma), and the
# personal instructions file. The Codex home exists, so both tools are bridged.
home() {
  local h="$root/$1"
  mkdir -p "$h/.Jarvis/.agents/skills/alpha" "$h/.Jarvis/.agents/skills/beta" \
           "$h/.Jarvis/.agents/skills/grp/gamma" "$h/.codex"
  printf 'name: alpha\n' >"$h/.Jarvis/.agents/skills/alpha/SKILL.md"
  printf 'name: beta\n'  >"$h/.Jarvis/.agents/skills/beta/SKILL.md"
  printf 'name: grp-gamma\n' >"$h/.Jarvis/.agents/skills/grp/gamma/SKILL.md"
  printf 'rules\n' >"$h/.Jarvis/.agents/AGENTS.md"
  echo "$h"
}

# run <name>: run the script in that sandbox; sets $code and writes <name>.log.
run() {
  HOME="$root/$1" CODEX_HOME="$root/$1/.codex" bash "$script" >"$root/$1.log" 2>&1
  code=$?
}

# A clean home links everything and exits 0.
h=$(home clean); run clean
if [ "$code" = 0 ] \
   && [ "$(readlink "$h/.claude/skills/alpha")" = "../../.agents/skills/alpha" ] \
   && [ "$(readlink "$h/.codex/skills/grp-gamma")" = "../../.agents/skills/grp/gamma" ] \
   && [ "$(find "$h/.claude/skills" -type l | wc -l | tr -d ' ')" = 3 ] \
   && [ "$(find "$h/.codex/skills" -type l | wc -l | tr -d ' ')" = 3 ]; then
  ok "clean home links every Skill into both tools and exits 0"
else
  bad "clean home links every Skill into both tools and exits 0 (exit $code)" "$root/clean.log"
fi

# Running again changes nothing and still exits 0 (correct entries accepted).
run clean
if [ "$code" = 0 ] && ! grep -q '^linked ' "$root/clean.log" && ! grep -q CONFLICT "$root/clean.log"; then
  ok "a second run accepts the correct entries and links nothing"
else
  bad "a second run accepts the correct entries and links nothing (exit $code)" "$root/clean.log"
fi

# An absolute spelling of the right target is also correct.
h=$(home absolute); run absolute
ln -sfn "$h/.Jarvis/.agents/skills/alpha" "$h/.claude/skills/alpha"
run absolute
if [ "$code" = 0 ] && ! grep -q CONFLICT "$root/absolute.log"; then
  ok "an equivalent absolute spelling of the right target is accepted"
else
  bad "an equivalent absolute spelling of the right target is accepted (exit $code)" "$root/absolute.log"
fi

# A dangling entry is replaced.
h=$(home dangling); run dangling
ln -sfn "$h/nowhere" "$h/.claude/skills/beta"
run dangling
if [ "$code" = 0 ] \
   && [ "$(readlink "$h/.claude/skills/beta")" = "../../.agents/skills/beta" ] \
   && ! grep -q CONFLICT "$root/dangling.log"; then
  ok "a dangling entry is replaced"
else
  bad "a dangling entry is replaced (exit $code)" "$root/dangling.log"
fi

# wrong <name> <tool dir> <kind>: a live entry that is not the canonical Skill.
# The entry must be reported, the run must fail, and the entry must be left
# byte-for-byte as it was.
wrong() {
  local name=$1 tool=$2 kind=$3 h entry before after
  h=$(home "$name"); run "$name"
  entry="$h/$tool/skills/alpha"
  rm "$entry"
  mkdir -p "$h/elsewhere/alpha"
  printf 'name: alpha\n' >"$h/elsewhere/alpha/SKILL.md"
  case $kind in
    link) ln -s "$h/elsewhere/alpha" "$entry" ;;
    dir)  cp -R "$h/elsewhere/alpha" "$entry" ;;
    file) printf 'x\n' >"$entry" ;;
  esac
  before=$( { readlink "$entry" || echo notlink; ls -la "$entry"/ 2>/dev/null; cat "$entry" 2>/dev/null; } )
  run "$name"
  after=$( { readlink "$entry" || echo notlink; ls -la "$entry"/ 2>/dev/null; cat "$entry" 2>/dev/null; } )
  if [ "$code" != 0 ] && grep -q "^CONFLICT .*$tool/skills/alpha" "$root/$name.log" \
     && grep -q "expected a link to $h/.Jarvis/.agents/skills/alpha\\." "$root/$name.log" \
     && [ "$before" = "$after" ]; then
    ok "wrong-target $kind under $tool: CONFLICT, nonzero exit, entry unchanged"
  else
    bad "wrong-target $kind under $tool: CONFLICT, nonzero exit, entry unchanged (exit $code)" "$root/$name.log"
  fi
}
wrong wrong-claude-link .claude link
wrong wrong-codex-link  .codex  link
wrong wrong-claude-dir  .claude dir
wrong wrong-claude-file .claude file

echo
if [ "$fails" -gt 0 ]; then echo "$fails of $total failed"; exit 1; fi
echo "all $total passed"
