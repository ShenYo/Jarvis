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
  HOME="$h" PATH="${RUNPATH:-$PATH}" bash "$h/.Jarvis/scripts/bootstrap.sh" ${2:+"$2"} >"$log" 2>&1 </dev/null
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
nobefore()  { ! grep -q BEFORE-BRIDGE "$root/guard-calls.log"; }
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
expect "the unchanged guard is not reported as done again" hasnot '^done  Codex guard'
expect "the stop shows Codex's own reason" has 'no trusted_hash'
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

# ---- person-only stops and what they must not do -----------------------------------------------

echo "== jq missing: stops, naming only jq"
nojq="$root/nojq"; mkdir -p "$nojq"
for t in bash git sed grep find dirname basename cksum sort tr wc mktemp ln mkdir cp mv rm chmod diff env cat head tail readlink \
  cut python3 awk uname ls id date cmp touch tee xargs perl realpath sleep true false; do
  p=$(command -v "$t" 2>/dev/null) && [ -x "$p" ] && ln -sf "$p" "$nojq/$t"
done
sandbox nojq
mkdir -p "$h/.claude"
RUNPATH="$nojq" run nojq
expect "exit 3 with the four fields" complete_stop
expect "it names jq" stopline 'install what the guard needs: jq'
expect "worked: names jq and not tomllib" has '^      worked: command -v jq succeeds$'

echo "== Codex present, python3 without tomllib: the stop names tomllib"
sandbox notoml
mkdir -p "$h/.claude" "$cx"
stub="$root/notoml-bin"; mkdir -p "$stub"
printf '#!/bin/sh\nexit 1\n' >"$stub/python3"; chmod +x "$stub/python3"
RUNPATH="$stub:$PATH" run notoml
expect "exit 3 at the tool stop" stopped
expect "it names tomllib" stopline 'tomllib'
expect "worked: names tomllib" has "^      worked: python3 -c 'import tomllib' succeeds\$"

echo "== core.hooksPath: a LOCAL value elsewhere is kept, with a note"
sandbox hplocal
mkdir -p "$h/.claude"
git -C "$h/.Jarvis" config --local core.hooksPath /elsewhere
run hplocal
expect "the note is printed" has "^note  core.hooksPath is '/elsewhere'"
expect "the value is unchanged" test "$(git -C "$h/.Jarvis" config --local --get core.hooksPath)" = /elsewhere
expect "the run still completes" test "$code" = 0

echo "== core.hooksPath: a GLOBAL value elsewhere does not stop the clone from getting .githooks"
sandbox hpglobal
mkdir -p "$h/.claude"
printf '[core]\n\thooksPath = /elsewhere\n' >"$h/.gitconfig"
run hpglobal
expect "the local value is .githooks" test "$(git -C "$h/.Jarvis" config --local --get core.hooksPath)" = .githooks
expect "the run completes" test "$code" = 0

echo "== stage order: no guard is applied or checked before the bridge has linked the Skills"
sandbox order
mkdir -p "$h/.claude" "$cx"
for g in apply-claude-guard apply-codex-guard; do
  mv "$h/.Jarvis/scripts/$g.sh" "$h/.Jarvis/scripts/$g.real.sh"
  {
    echo '#!/usr/bin/env bash'
    echo "if [ -L \"$h/.claude/skills/tdd\" ]; then echo \"bridged $g \$*\" >>\"$root/guard-calls.log\"; else echo \"BEFORE-BRIDGE $g \$*\" >>\"$root/guard-calls.log\"; fi"
    echo "exec bash \"$h/.Jarvis/scripts/$g.real.sh\" \"\$@\""
  } >"$h/.Jarvis/scripts/$g.sh"
done
rm -f "$root/guard-calls.log"
run order
expect "the guards were reached" test -s "$root/guard-calls.log"
expect "every guard call came after the bridge" nobefore

# What the bridge refuses (sync-personal-skills.sh --check says CONFLICT or SHADOWED) is a stop, found
# before anything is written. MISSING and DANGLING are not: a normal run repairs them.
conflict_case() { # <name> <what the HOME holds, as a function name>; sets $before/$after around the run
  sandbox "$1"
  mkdir -p "$h/.claude" "$cx"
  "$2"
  before=$(state "$h")
  run "$1"
  after=$(state "$h")
}
untouched() { test "$before" = "$after"; }

echo "== an existing ~/.claude/CLAUDE.md is a stop, found before anything is written"
real_claude() { printf 'my rules\n' >"$h/.claude/CLAUDE.md"; }
conflict_case conflict real_claude
expect "exit 3 with what, where, worked and resume" complete_stop
expect "it names the bridge's conflict step" stopline 'Skills bridge reports as a conflict'
expect "what carries the bridge's own CONFLICT line" has 'what: .*CONFLICT .*CLAUDE.md is a real file'
expect "the HOME and the clone are byte-identical" untouched
expect "the file is untouched" test "$(cat "$h/.claude/CLAUDE.md")" = 'my rules'
other_claude() { printf 'other\n' >"$h/other.md"; ln -s "$h/other.md" "$h/.claude/CLAUDE.md"; }
conflict_case conflict2 other_claude
expect "a live link elsewhere is the same stop" complete_stop
expect "nothing was written for the link either" untouched

echo "== a directory at ~/.claude/CLAUDE.md is a stop, nothing written"
dir_claude() { mkdir "$h/.claude/CLAUDE.md"; }
conflict_case cdir dir_claude
expect "exit 3 with the four fields" complete_stop
expect "nothing was written" untouched

echo "== an existing ~/.codex/AGENTS.md is a stop, nothing written"
real_codex() { printf 'codex rules\n' >"$cx/AGENTS.md"; }
conflict_case cxconf real_codex
expect "exit 3 with the four fields" complete_stop
expect "what carries the bridge's CONFLICT line for Codex" has 'what: .*CONFLICT .*[.]codex/AGENTS.md is a real file'
expect "the HOME and the clone are byte-identical" untouched
expect "the file is untouched" test "$(cat "$cx/AGENTS.md")" = 'codex rules'

echo "== a non-empty ~/.codex/AGENTS.override.md is a stop (SHADOWED), nothing written"
override() { printf 'override\n' >"$cx/AGENTS.override.md"; }
conflict_case shadow override
expect "exit 3 with the four fields" complete_stop
expect "what carries the bridge's SHADOWED line" has 'what: .*SHADOWED .*AGENTS.override.md'
expect "the HOME and the clone are byte-identical" untouched

echo "== a pre-existing real directory where the bridge would link a Skill is a stop, nothing written"
skill_dir() { mkdir -p "$h/.claude/skills/tdd"; ln -s .Jarvis/.agents "$h/.agents"; }   # with ~/.agents present, the other way in
conflict_case cskill skill_dir
expect "exit 3 with the four fields" complete_stop
expect "what carries the bridge's CONFLICT line for the Skill" has 'what: .*CONFLICT Claude Code: .*skills/tdd is not a symlink'
expect "the HOME and the clone are byte-identical" untouched

echo "== a dangling ~/.claude/CLAUDE.md is not a stop: it is relinked"
sandbox dangling
mkdir -p "$h/.claude"
ln -s /nonexistent/rules.md "$h/.claude/CLAUDE.md"
run dangling
expect "exit 0" test "$code" = 0
expect "no stop" hasnot '^STOP'
expect "the link now leads to the personal instructions" test "$(cat "$h/.claude/CLAUDE.md")" = "$(cat "$h/.Jarvis/.agents/AGENTS.md")"

echo "== Codex's hooks = false: the stop gives the real fix, not '/hooks'"
sandbox nohooks
mkdir -p "$h/.claude" "$cx"
run nohooks
printf '\n[features]\nhooks = false\n' >>"$cx/config.toml"
run nohooks2
expect "exit 3 with the four fields" complete_stop
expect "it is not the trust-in-/hooks step" hasnot 'STOP .*trust the guard in Codex'
expect "what carries --trust's fix" has 'what: .*remove hooks = false from \[features\]'

echo "== Codex's entry switched off with enabled = false: the stop sends the person to /hooks"
sandbox disabled
mkdir -p "$h/.claude" "$cx"
run disabled
trust "$cx"
printf 'enabled = false\n' >>"$cx/config.toml"   # in the entry's own table, the last one trust() wrote
run disabled2
expect "exit 3 with the four fields" complete_stop
expect "it is the /hooks step" stopline 'enable the guard in Codex'
expect "where: inside Codex" has 'where: .*inside Codex'
expect "it is not the config step" hasnot 'make the Jarvis guard runnable'

echo "== Claude Code's identity switch on: Codex's 'not covered' warning is shown"
sandbox swon
mkdir -p "$h/.claude" "$cx"
JARVIS_REQUIRE_AGENT_IDENTITY=1 run swon
expect "the first run shows the warning" has 'Codex GitHub writes are not covered'
JARVIS_REQUIRE_AGENT_IDENTITY=1 run swon2
echo "     (a re-run, guard applied and trust open: warning shown = $(grep -c 'not covered' "$log"))"

echo "== python3 missing with Codex present: worked names python3 and tomllib"
nopy="$root/nopy"; mkdir -p "$nopy"
for t in "$nojq"/*; do [ "$(basename "$t")" = python3 ] || ln -sf "$(readlink "$t")" "$nopy/$(basename "$t")"; done
ln -sf "$(command -v jq)" "$nopy/jq"
sandbox nopy
mkdir -p "$h/.claude" "$cx"
RUNPATH="$nopy" run nopy
expect "exit 3 at the tool stop" stopped
expect "it names python3" stopline 'python3'
expect "worked: names python3 and tomllib" has "^      worked: command -v python3 succeeds, and python3 -c 'import tomllib' succeeds\$"

echo "== the resume command is shell-quoted and carries the homes that were set"
sandbox "sp ace"
log="$root/space.log"
HOME="$h" CLAUDE_CONFIG_DIR="$h/cl aude" CODEX_HOME="$h/cx home" bash "$h/.Jarvis/scripts/bootstrap.sh" >"$log" 2>&1 </dev/null; code=$?
resumeline=$(grep '^      resume: ' "$log")
want="      resume: CLAUDE_CONFIG_DIR=$(printf '%q' "$h/cl aude") CODEX_HOME=$(printf '%q' "$h/cx home") bash $(printf '%q' "$h/.Jarvis/scripts/bootstrap.sh")"
expect "the path with a space is escaped and the homes are carried" test "$resumeline" = "$want"
expect "the escaped line has a backslash-space" grep -qF '\ ' "$log"

echo "== usage"
log="$root/usage.log"
HOME="$h" bash "$script" --nope >"$log" 2>&1; code=$?
expect "an unknown argument exits 2" test "$code" = 2

echo
echo "$((total - fails)) of $total passed"
if [ "$fails" = 0 ]; then echo "all $total passed"; exit 0; fi
echo "$fails FAILED"; exit 1
