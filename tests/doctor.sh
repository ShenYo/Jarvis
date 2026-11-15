#!/usr/bin/env bash
# Tests for scripts/doctor.sh, the read-only aggregate of the machine checks.
#
# Every case builds a sandbox HOME (with CODEX_HOME inside it) whose ~/.Jarvis is
# a link to this checkout, and brings it to the state under test by running the
# real bridge and apply scripts in it. The real ~/.claude, ~/.codex and identity
# configuration are never read or written, and `ssh` and `gh` are stubs on PATH
# that fail and log, so no case needs a network or a credential.
#
# DOCTOR=<path> runs another script, e.g. an absent one, to show the cases fail
# before the code exists.
#
# Sandboxes are left in place; see tests/claude-guard.sh for why.
set -uo pipefail

# Hermetic: an agent session's identity environment must not reach the checks.
for v in $(compgen -e | grep -E '^(GIT_CONFIG_|GIT_AUTHOR_|GIT_COMMITTER_)'); do unset "$v"; done
unset GIT_SSH_COMMAND GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GH_CONFIG_DIR GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN \
  GITHUB_ENTERPRISE_TOKEN GH_HOST JARVIS_AGENT_IDENTITY JARVIS_REQUIRE_AGENT_IDENTITY CODEX_HOME CLAUDE_CONFIG_DIR \
  XDG_CONFIG_HOME JARVIS_AGENT_IDENTITY_FILE

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
doctor="${DOCTOR:-$repo/scripts/doctor.sh}"
root=$(mktemp -d "${TMPDIR:-/tmp}/doctor-test.XXXXXX") && [ -n "$root" ] || exit 1
root=$(cd -P "$root" && pwd -P) || exit 1
echo "sandboxes: $root"

# ssh and gh: never the real ones. Each call is logged; each fails.
mkdir -p "$root/bin"
for t in ssh gh; do
  printf '#!/bin/sh\necho "%s $*" >>"%s/net.log"\nexit 1\n' "$t" "$root" >"$root/bin/$t"
  chmod +x "$root/bin/$t"
done
export PATH="$root/bin:$PATH"

fails=0
total=0
ok()   { total=$((total + 1)); echo "ok   $1"; }
bad()  { total=$((total + 1)); fails=$((fails + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && [ -f "$2" ] && sed 's/^/     /' "$2" | head -14; }
expect() { # <name> <condition command...>; the log of the last run is $log
  local name=$1; shift
  if "$@"; then ok "$name"; else bad "$name" "$log"; fi
}

sha256_stdin() { shasum -a 256 2>/dev/null | cut -d' ' -f1 || sha256sum | cut -d' ' -f1; }

# trust <codex home>: record Codex's trust of the installed guard entry the way
# /hooks does (see tests/codex-guard.sh for where the formula comes from).
trust() {
  local d=$1 g h hash
  read -r g h < <(jq -r 'first(.hooks.PreToolUse | to_entries[] | .key as $g | .value.hooks | to_entries[]
    | select(.value.command | contains("/hooks/jarvis-guard.py")) | "\($g) \(.key)")' "$d/hooks.json")
  hash=$(jq -cS --argjson g "$g" --argjson h "$h" '.hooks.PreToolUse[$g] as $grp | $grp.hooks[$h] as $x
    | {event_name: "pre_tool_use", matcher: $grp.matcher,
       hooks: [{type: $x.type, command: $x.command, timeout: ($x.timeout // 600), async: ($x.async // false), statusMessage: $x.statusMessage}]}' \
    "$d/hooks.json" | tr -d '\n' | sha256_stdin)
  printf '\n[hooks.state."%s/hooks.json:pre_tool_use:%s:%s"]\ntrusted_hash = "sha256:%s"\n' "$(cd "$d" && pwd -P)" "$g" "$h" "$hash" >>"$d/config.toml"
}

# fixture <name> [nocodex]: a machine that is fully set up: Skills bridged, both
# guards installed, Codex trusting its guard. Sets $h (HOME) and $cx (CODEX_HOME).
fixture() {
  h="$root/$1"; cx="$h/.codex"
  mkdir -p "$h"
  ln -s "$repo" "$h/.Jarvis"
  [ "${2:-}" = nocodex ] || mkdir -p "$cx"
  HOME="$h" CODEX_HOME="$cx" bash "$repo/sync-personal-skills.sh" >"$root/$1.setup" 2>&1 || { echo "fixture $1: bridge failed"; sed 's/^/  /' "$root/$1.setup"; }
  HOME="$h" CODEX_HOME="$cx" bash "$repo/scripts/apply-claude-guard.sh" >>"$root/$1.setup" 2>&1 || echo "fixture $1: claude guard failed"
  if [ -d "$cx" ]; then
    HOME="$h" CODEX_HOME="$cx" bash "$repo/scripts/apply-codex-guard.sh" >>"$root/$1.setup" 2>&1 || echo "fixture $1: codex guard failed"
    trust "$cx"
  fi
}

# run <name>: doctor in that sandbox; sets $code and $log.
run() {
  log="$root/$1.log"
  HOME="$h" CODEX_HOME="$cx" JARVIS_AGENT_IDENTITY_FILE="${identity:-$h/no-identity}" bash "$doctor" ${2:+"$2"} >"$log" 2>&1
  code=$?
}

line()    { grep -Eq "^$1 +$2 " "$log"; }          # <word> <check name>
live()    { line UNVERIFIED live-callback && grep -q 'docs/guard.md' "$log"; }
lastline() { tail -1 "$log"; }

# state <home>: everything under the sandbox home, links by target and files by
# content, without following ~/.Jarvis into the checkout.
state() { (cd "$1" && find . | sort | while IFS= read -r f; do
  if [ -L "$f" ]; then printf '%s -> %s\n' "$f" "$(readlink "$f")"
  elif [ -f "$f" ]; then printf '%s %s\n' "$f" "$(cksum <"$f")"
  else printf '%s dir\n' "$f"; fi; done); }
# repo_state: the checkout's status and the content of every modified or untracked file.
repo_state() {
  git -C "$repo" status --porcelain
  git -C "$repo" ls-files -m -o --exclude-standard | sort | while IFS= read -r f; do
    printf '%s %s\n' "$f" "$(cksum <"$repo/$f" 2>/dev/null || echo gone)"; done
  git -C "$repo" rev-parse HEAD
}

# --- a correct machine -------------------------------------------------------
fixture good; run good
expect "correct setup: exit 0" test "$code" = 0
expect "correct setup: every check is ok, identity optional" bash -c "
  for c in bridge skill-lock claude-guard codex-guard; do grep -Eq \"^ok +\$c \" '$log' || exit 1; done
  grep -Eq '^skipped +identity .*not configured \\(optional\\)' '$log' && ! grep -q '^PROBLEM' '$log'"
expect "correct setup: live callback is UNVERIFIED" live
expect "correct setup: the last line is a summary with a next step" bash -c "tail -1 '$log' | grep -q '^doctor: no problem found.*Next:'"
expect "correct setup: no network call was made" test ! -e "$root/net.log"

# --- stale guard -------------------------------------------------------------
fixture stale-guard
printf '# drift\n' >>"$h/.claude/hooks/claude-guard.py"
run stale-guard
expect "stale guard: exit 1" test "$code" = 1
expect "stale guard: the Claude guard line is a PROBLEM with its fix command" bash -c "
  grep -Eq '^PROBLEM +claude-guard ' '$log' && grep -Eq 'fix: bash .*/scripts/apply-claude-guard.sh' '$log'"
expect "stale guard: the other checks still ran and passed" bash -c "grep -Eq '^ok +bridge ' '$log' && grep -Eq '^ok +codex-guard ' '$log'"
expect "stale guard: live callback is UNVERIFIED" live
expect "stale guard: the last line says Next with the fix" bash -c "tail -1 '$log' | grep -Eq '^doctor: 1 problem.*Next: bash .*apply-claude-guard.sh'"

# --- wrong-target Skill in the bridge ----------------------------------------
fixture wrong-target
skill=$(ls "$h/.claude/skills" | head -1)
rm "$h/.claude/skills/$skill"; mkdir -p "$h/elsewhere/$skill"; ln -s "$h/elsewhere/$skill" "$h/.claude/skills/$skill"
run wrong-target
expect "wrong-target Skill: exit 1" test "$code" = 1
expect "wrong-target Skill: the bridge line is a PROBLEM naming the CONFLICT" bash -c "
  grep -Eq '^PROBLEM +bridge ' '$log' && grep -q 'CONFLICT Claude Code' '$log' && grep -Eq 'fix: bash .*sync-personal-skills.sh' '$log'"
expect "wrong-target Skill: live callback is UNVERIFIED" live

# --- Codex trust missing, and hook disabled ----------------------------------
fixture untrusted
rm "$cx/config.toml"
run untrusted
expect "Codex trust missing: exit 1" test "$code" = 1
expect "Codex trust missing: the Codex guard line is a PROBLEM that says UNTRUSTED and how to fix" bash -c "
  grep -Eq '^PROBLEM +codex-guard ' '$log' && grep -q 'trust: UNTRUSTED' '$log' && grep -Eq 'fix: open /hooks in Codex and trust' '$log'"
expect "Codex trust missing: live callback is UNVERIFIED" live

fixture disabled
printf '\n[features]\nhooks = false\n' >>"$cx/config.toml"
run disabled
expect "Codex hook disabled: exit 1 and the Codex guard line is a PROBLEM saying DISABLED" bash -c "
  test '$code' = 1 && grep -Eq '^PROBLEM +codex-guard ' '$log' && grep -q 'trust: DISABLED' '$log'"
expect "Codex hook disabled: live callback is UNVERIFIED" live

# --- no Codex ----------------------------------------------------------------
fixture nocodex nocodex; run nocodex
expect "no Codex home: exit 0 and the Codex guard line says it is not set up" bash -c "
  test '$code' = 0 && grep -Eq '^skipped +codex-guard .*not set up' '$log' && ! grep -q '^PROBLEM' '$log'"
expect "no Codex home: live callback is UNVERIFIED" live

# --- identity ----------------------------------------------------------------
fixture noident; run noident
expect "no identity configured: exit 0, both identity lines say optional and skipped" bash -c "
  test '$code' = 0 && grep -Eq '^skipped +identity +not configured \\(optional\\)' '$log' &&
  grep -Eq '^skipped +identity-codex +not configured \\(optional\\)' '$log'"

fixture ident-broken
printf 'login=\nnonsense\n' >"$h/identity-file"
identity="$h/identity-file"; run ident-broken; identity=""
expect "identity configured but broken: exit 1, a PROBLEM with its fix" bash -c "
  test '$code' = 1 && grep -Eq '^PROBLEM +identity ' '$log' && grep -Eq 'fix: bash .*apply-agent-identity.sh --check' '$log'"
expect "identity configured but broken: live callback is UNVERIFIED" live

# --- read-only ---------------------------------------------------------------
# A passing machine, a machine with every kind of fault, and one that was never
# set up (where a bridge run that is not a check would create every link).
fixture ro-good
fixture ro-faulty
printf '# drift\n' >>"$h/.claude/hooks/claude-guard.py"
rm "$cx/config.toml"
rm "$h/.claude/skills/$(ls "$h/.claude/skills" | head -1)"
fresh="$root/ro-fresh"; mkdir -p "$fresh/.codex"; ln -s "$repo" "$fresh/.Jarvis"; ln -s .Jarvis/.agents "$fresh/.agents"
for name in ro-good ro-faulty ro-fresh; do
  h="$root/$name"; cx="$h/.codex"
  before=$(state "$h"); rbefore=$(repo_state)
  run "$name"
  after=$(state "$h"); rafter=$(repo_state)
  expect "read-only on $name: the sandbox home is identical before and after" test "$before" = "$after"
  expect "read-only on $name: the checkout (status and content) is identical before and after" test "$rbefore" = "$rafter"
  expect "read-only on $name: live callback is UNVERIFIED" live
done
expect "read-only: the faulty and the fresh machine exit 1, the good one 0" bash -c "
  test \"\$(grep -c '^PROBLEM' '$root/ro-good.log')\" = 0 && grep -q '^PROBLEM' '$root/ro-faulty.log' && grep -q '^PROBLEM' '$root/ro-fresh.log'"

# --- usage -------------------------------------------------------------------
h="$root/good"; cx="$h/.codex"
log="$root/usage.log"
HOME="$h" CODEX_HOME="$cx" bash "$doctor" --bogus >"$log" 2>&1; c1=$?
HOME="$h" CODEX_HOME="$cx" bash "$doctor" --check extra >"$log.2" 2>&1; c2=$?
HOME="$h" CODEX_HOME="$cx" bash "$doctor" --help >"$log.3" 2>&1; c3=$?
expect "usage: an unknown argument exits 2, two arguments exit 2, --help exits 0" test "$c1$c2$c3" = 220

echo
if [ "$fails" -gt 0 ]; then echo "$fails of $total failed"; exit 1; fi
echo "all $total passed"
