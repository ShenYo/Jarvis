#!/usr/bin/env bash
# Tests for scripts/bootstrap.sh, the staged machine setup.
#
# Each case runs in a sandbox HOME whose ~/.Jarvis is a throwaway clone of this checkout, with the
# script under test copied into it. The real ~/.claude, ~/.codex and ~/.Jarvis are never read or
# written, and Git's own configuration of the real checkout is not touched either, because the
# script sets core.hooksPath in the clone.
#
# BOOTSTRAP=<path> runs another copy of the script, e.g. a mutant that runs past a person-only
# stop, to show the cases fail without the stop.
#
# Sandboxes are left in place; see tests/claude-guard.sh for why.
set -uo pipefail

# Hermetic: an agent session's identity environment must not reach the script.
for v in $(compgen -e | grep -E '^(GIT_CONFIG_|GIT_AUTHOR_|GIT_COMMITTER_)'); do unset "$v"; done
unset GIT_SSH_COMMAND GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GH_CONFIG_DIR GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN \
  GITHUB_ENTERPRISE_TOKEN GH_HOST JARVIS_AGENT_IDENTITY JARVIS_REQUIRE_AGENT_IDENTITY CODEX_HOME CLAUDE_CONFIG_DIR \
  XDG_CONFIG_HOME JARVIS_AGENT_IDENTITY_FILE

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="${BOOTSTRAP:-$repo/scripts/bootstrap.sh}"
root=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-test.XXXXXX") && [ -n "$root" ] || exit 1
root=$(cd -P "$root" && pwd -P) || exit 1
echo "sandboxes: $root"

# ssh and gh: never the real ones (doctor's identity check would use them). Each fails.
mkdir -p "$root/bin"
for t in ssh gh; do printf '#!/bin/sh\nexit 1\n' >"$root/bin/$t"; chmod +x "$root/bin/$t"; done
export PATH="$root/bin:$PATH"

fails=0
total=0
ok()  { total=$((total + 1)); echo "ok   $1"; }
bad() { total=$((total + 1)); fails=$((fails + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && [ -f "$2" ] && sed 's/^/     /' "$2" | head -14; }
expect() { # <name> <condition command...>; the log of the last run is $log
  local name=$1; shift
  if "$@"; then ok "$name"; else bad "$name" "$log"; fi
}

sha256_stdin() { shasum -a 256 2>/dev/null | cut -d' ' -f1 || sha256sum | cut -d' ' -f1; }

# trust <codex home>: record Codex's trust of the installed guard entry the way /hooks does
# (see tests/doctor.sh and tests/codex-guard.sh for where the formula comes from).
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

# sandbox <name>: a HOME holding only a clone of this checkout, with the script under test in it.
sandbox() {
  h="$root/$1"; cx="$h/.codex"
  mkdir -p "$h"
  git clone -q --local "$repo" "$h/.Jarvis" >"$root/$1.clone" 2>&1 || { echo "sandbox $1: clone failed"; cat "$root/$1.clone"; exit 1; }
  cp "$script" "$h/.Jarvis/scripts/bootstrap.sh"
}

# run <name> [args]: the script in that sandbox; sets $code and $log.
run() {
  log="$root/$1.log"
  HOME="$h" bash "$h/.Jarvis/scripts/bootstrap.sh" ${2:+"$2"} >"$log" 2>&1 </dev/null
  code=$?
}

# state <home>: everything under the sandbox home, the clone included: links by target, files by content.
state() { (cd "$1" && find . | sort | while IFS= read -r f; do
  if [ -L "$f" ]; then printf '%s -> %s\n' "$f" "$(readlink "$f")"
  elif [ -f "$f" ]; then printf '%s %s\n' "$f" "$(cksum <"$f")"
  else printf '%s dir\n' "$f"; fi; done); }

stopped()   { [ "$code" = 3 ] && grep -q '^STOP  a person has to do this step: ' "$log"; }
stopline()  { grep -q "^STOP .*$1" "$log"; }
has()       { grep -q -- "$1" "$log"; }
hasnot()    { ! grep -q -- "$1" "$log"; }
# A stop says what, where, how to know it worked, and the command to resume.
complete_stop() { has '^      what:  ' && has '^      where: ' && has '^      worked: ' && has "^      resume: bash $h/.Jarvis/scripts/bootstrap.sh\$"; }

echo "== a clean HOME stops at the first person-only step, having changed nothing"
sandbox clean
before=$(state "$h")
run clean
expect "stops with exit 3 at 'install Claude Code'" stopped
expect "the stop names the step" stopline 'install Claude Code'
expect "the stop carries what, where, how to know, and the resume command" complete_stop
expect "it ran no later step" hasnot '== stage 2'
after=$(state "$h")
expect "nothing was written to the HOME" test "$before" = "$after"
expect "the Claude Code home was not created" test ! -e "$h/.claude"

echo "== after the person step, stage 1 and 2 run and the script stops at Codex's trust"
mkdir -p "$h/.claude" "$cx"      # the person installed and started Claude Code and Codex
run clean
expect "stops with exit 3 at 'trust the guard in Codex'" stopped
expect "the stop names the step" stopline 'trust the guard in Codex'
expect "the stop carries what, where, how to know, and the resume command" complete_stop
expect "Git hooks were turned on" test "$(git -C "$h/.Jarvis" config --get core.hooksPath)" = .githooks
expect "the bridge ran" has '^done  Skills bridge: checks passed:'
expect "Skills are linked for Claude Code" test -L "$h/.claude/skills/tdd"
expect "the personal instructions are linked" test -L "$h/.claude/CLAUDE.md"
expect "the Claude Code guard was applied" test -f "$h/.claude/hooks/claude-guard.py"
expect "the Codex guard was applied" test -f "$cx/hooks/jarvis-guard.py"
expect "it did not go on to the end" hasnot '^bootstrap: stages 1 and 2 are done'
expect "it never asked for the machine account" hasnot 'STOP.*identity'
expect "no identity config was written" test ! -e "$h/.Jarvis/config-local/agent-identity"

echo "== running again while the person step is still open changes nothing and stops at the same place"
before=$(state "$h")
run clean2
expect "same stop" stopline 'trust the guard in Codex'
after=$(state "$h")
expect "nothing changed (byte-compare)" test "$before" = "$after"

echo "== after the person trusts the hook, resuming continues to the end"
trust "$cx"
run resume
expect "exit 0" test "$code" = 0
expect "it says stages 1 and 2 are done" has '^bootstrap: stages 1 and 2 are done'
expect "Codex's trust is reported" has '^ok    Codex guard is installed and Codex trusts it'
expect "stage 3 is named optional and not demanded" has 'stage 3, the agent identity'

echo "== a second run changes nothing"
before=$(state "$h")
run second
after=$(state "$h")
expect "exit 0" test "$code" = 0
expect "the HOME and the clone are byte-identical" test "$before" = "$after"
expect "every step is reported already done" hasnot '^done  '

echo "== --check is doctor's report and changes nothing"
before=$(state "$h")
run check --check
chk="$log"; chkcode=$code
HOME="$h" bash "$h/.Jarvis/scripts/doctor.sh" >"$root/doctor.log" 2>&1 </dev/null; doccode=$?
after=$(state "$h")
expect "the HOME and the clone are byte-identical" test "$before" = "$after"
expect "output equals doctor's" cmp -s "$chk" "$root/doctor.log"
expect "exit status equals doctor's" test "$chkcode" = "$doccode"
expect "it reported the bridge" grep -Eq '^ok +bridge ' "$chk"

echo "== --check on a clean HOME is doctor's report too, and writes nothing"
sandbox cleancheck
before=$(state "$h")
run cleancheck --check
chk="$log"; chkcode=$code
HOME="$h" bash "$h/.Jarvis/scripts/doctor.sh" >"$root/doctor2.log" 2>&1 </dev/null; doccode=$?
after=$(state "$h")
expect "nothing was written" test "$before" = "$after"
expect "output equals doctor's" cmp -s "$chk" "$root/doctor2.log"
expect "exit status equals doctor's" test "$chkcode" = "$doccode"

echo "== a Claude-only machine (no Codex) completes without a stop"
sandbox noccodex
mkdir -p "$h/.claude"
run noccodex
expect "exit 0" test "$code" = 0
expect "Codex is skipped with a note" has '^note  Codex is not set up'
expect "it says stages 1 and 2 are done" has '^bootstrap: stages 1 and 2 are done'

echo "== a checkout that is not ~/.Jarvis is refused"
sandbox elsewhere
mv "$h/.Jarvis" "$h/Jarvis-copy"
mkdir -p "$h/.claude"
log="$root/elsewhere.log"
HOME="$h" bash "$h/Jarvis-copy/scripts/bootstrap.sh" >"$log" 2>&1 </dev/null; code=$?
refused() { [ "$code" = 1 ] && grep -q 'needs it at' "$log"; }
expect "exit 1 with the reason" refused

echo "== usage"
log="$root/usage.log"
HOME="$h" bash "$script" --nope >"$log" 2>&1; code=$?
expect "an unknown argument exits 2" test "$code" = 2

echo
echo "$((total - fails)) of $total passed"
if [ "$fails" = 0 ]; then echo "all $total passed"; exit 0; fi
echo "$fails FAILED"; exit 1
