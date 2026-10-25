#!/usr/bin/env bash
# Tests for scripts/apply-codex-guard.sh and for the guard run as a Codex hook
# (bash-guard.py --codex), each in its own sandbox CODEX_HOME, so the real
# ~/.codex is never read or written.
#
# The hook probes run the command line exactly as apply-codex-guard.sh wrote it
# into hooks.json, feeding it the JSON Codex sends a PreToolUse hook for a
# shell command, and read the answer the way Codex does: only a "deny" stops
# the command, and a hook that exits non-zero or overruns lets it run.
#
# Sandboxes are left under the printed directory rather than removed; see
# tests/claude-guard.sh for why.
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
apply="$repo/scripts/apply-codex-guard.sh"
src="$repo/.agents/claude-guard/bash-guard.py"
root=$(mktemp -d "${TMPDIR:-/tmp}/codex-guard-test.XXXXXX")
echo "sandboxes: $root"

fails=0
n=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { # name, then a command that must succeed
  local name=$1; shift
  if "$@"; then ok "$name"; else fail "$name"; fi
}
sandbox() { n=$((n + 1)); dir="$root/$n"; mkdir -p "$dir"; h="$dir/hooks.json"; }
run() { CODEX_HOME="$dir" bash "$apply" "$@" >"$dir/out" 2>&1; }
q() { jq -e "$1" "$h" >/dev/null; }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
snapshot() { # every file the script could write; not the test's own output
  (cd "$dir" && find . \( -type f -o -type l \) ! -name out ! -name 'snap.*' ! -name before ! -name 'others.*' | sort |
    while read -r f; do printf '%s ' "$f"; cksum <"$f"; done)
}
# hooks.json with the guard's own group taken out, canonicalised: what must
# survive an apply untouched.
others() { jq -S 'del(.hooks.PreToolUse[]? | select(any(.hooks[]?; (.command // "") | contains("/hooks/jarvis-guard.py"))))' "$1"; }
own_count='([.hooks.PreToolUse[] | select(any(.hooks[]; .command | contains("/hooks/jarvis-guard.py")))] | length)'

# --- applying ----------------------------------------------------------------

# 1. Empty CODEX_HOME: the hook is copied and hooks.json created.
sandbox
run; rc=$?
check "fresh: exit 0" test "$rc" = 0
check "fresh: hook copied, not linked" test -f "$dir/hooks/jarvis-guard.py" -a ! -L "$dir/hooks/jarvis-guard.py"
check "fresh: hook is the repository's" cmp -s "$src" "$dir/hooks/jarvis-guard.py"
check "fresh: one PreToolUse group" q "$own_count == 1 and (.hooks.PreToolUse | length) == 1"
check "fresh: matcher is ^Bash\$" q '.hooks.PreToolUse[0].matcher == "^Bash$"'
check "fresh: one command handler, 10 s, with a status message" q '.hooks.PreToolUse[0].hooks | length == 1 and .[0].type == "command" and .[0].timeout == 10 and (.[0].statusMessage | length > 0)'
check "fresh: command runs the copy with -I and --codex" q '.hooks.PreToolUse[0].hooks[0].command | contains("-I") and contains("hooks/jarvis-guard.py") and endswith("--codex")'
check "fresh: says to trust it in /hooks" grep -q 'trusted in /hooks' "$dir/out"
check "fresh: no stray error output" bash -c "! grep -qi 'no such file\\|error' '$dir/out'"

# 2. A second apply changes nothing and says nothing about trust.
snapshot >"$dir/snap.before"
run; rc=$?
snapshot >"$dir/snap.after"
check "idempotent: exit 0" test "$rc" = 0
check "idempotent: nothing changed" cmp -s "$dir/snap.before" "$dir/snap.after"
check "idempotent: no backup of an unchanged file" test ! -e "$h.guard-backup"
check "idempotent: no trust prompt" bash -c "! grep -q 'trusted in' '$dir/out'"

# 3. --check: 0 when applied, writes nothing; 1 when not.
run --check; rc=$?
snapshot >"$dir/snap.after"
check "--check applied: exit 0" test "$rc" = 0
check "--check applied: touches no file" cmp -s "$dir/snap.before" "$dir/snap.after"
sandbox
run --check; rc=$?
check "--check empty home: exit 1" test "$rc" = 1
check "--check empty home: writes nothing" test -z "$(ls -A "$dir" | grep -v '^out$')"

# 3b. A hook edited in place is drift; --check says 1 and a run restores it.
sandbox
run
echo "# edited" >>"$dir/hooks/jarvis-guard.py"
run --check; rc=$?
check "hook drift: --check exit 1" test "$rc" = 1
run
check "hook drift: run restores the hook" cmp -s "$src" "$dir/hooks/jarvis-guard.py"

# 4. Other tools' entries stay exactly as they are, on every event.
sandbox
orca() { # an Orca-style catch-all group
  printf '{"hooks":[{"type":"command","command":": orca-agent-hook-form=1; /bin/sh \\"$HOME/.orca/agent-hooks/codex-hook.sh\\" || :","timeout":10}]}'
}
cat >"$h" <<EOF
{
  "hooks": {
    "SessionStart": [$(orca)],
    "UserPromptSubmit": [$(orca)],
    "PreToolUse": [
      $(orca),
      {"matcher": "^apply_patch\$", "hooks": [{"type": "command", "command": "other-tool", "timeout": 5}]}
    ],
    "PostToolUse": [$(orca)],
    "Stop": [$(orca)]
  },
  "other": {"keep": [1, 2, 3]}
}
EOF
jq -e . "$h" >/dev/null || fail "fixture is valid JSON"
cp "$h" "$dir/before"
others "$h" >"$dir/others.before"
run --check; rc=$?
check "merge: --check exit 1 before" test "$rc" = 1
run; rc=$?
others "$h" >"$dir/others.after"
check "merge: exit 0" test "$rc" = 0
check "merge: every other entry unchanged" cmp -s "$dir/others.before" "$dir/others.after"
check "merge: other PreToolUse groups keep their order, the guard is last" q '(.hooks.PreToolUse | length) == 3 and (.hooks.PreToolUse[0].hooks[0].command | startswith(": orca-agent-hook-form=1")) and .hooks.PreToolUse[1].matcher == "^apply_patch$" and .hooks.PreToolUse[2].matcher == "^Bash$"'
check "merge: exactly one guard group" q "$own_count == 1"
check "merge: backup is the previous file" cmp -s "$dir/before" "$h.guard-backup"
run --check; rc=$?
check "merge: --check exit 0 after" test "$rc" = 0

# 4b. An older revision of the guard's group is replaced where it stands,
#     found by the hook it names and not by position; a duplicate goes; the
#     person's own group stays.
sandbox
cat >"$h" <<'EOF'
{"hooks": {"PreToolUse": [
  {"matcher": "^Bash$", "hooks": [{"type": "command", "command": "python3 ~/.codex/hooks/jarvis-guard.py", "timeout": 3}]},
  {"matcher": "^Bash$", "hooks": [{"type": "command", "command": "mine", "timeout": 5}]},
  {"matcher": "Bash", "hooks": [{"type": "command", "command": "python3 /x/hooks/jarvis-guard.py --old"}]}
]}}
EOF
others "$h" >"$dir/others.before"
run
others "$h" >"$dir/others.after"
check "replace: one guard group, at the old position, current settings" q "$own_count == 1 and .hooks.PreToolUse[0].hooks[0].timeout == 10 and .hooks.PreToolUse[1].hooks[0].command == \"mine\" and (.hooks.PreToolUse | length) == 2"
check "replace: the person's own group untouched" cmp -s "$dir/others.before" "$dir/others.after"

# 5. Anything that is not a usable JSON object is refused; nothing is written.
for bad in 'not json {' '[1,2]' '"str"' '{"hooks": []}' '{"hooks": {"PreToolUse": {}}}' '{"hooks": {}} {"x": 1}' '{"x": 1} []'; do
  sandbox
  printf '%s\n' "$bad" >"$h"
  cp "$h" "$dir/before"
  run; rc=$?
  check "refuse '$bad': exit 2" test "$rc" = 2
  check "refuse '$bad': file unchanged" cmp -s "$h" "$dir/before"
  check "refuse '$bad': no hook, no backup" test ! -e "$dir/hooks" -a ! -e "$h.guard-backup"
done

# 5b. Extra arguments are a usage error, and nothing is written.
sandbox
run --check extra; rc=$?
check "usage: --check plus an argument exits 2" test "$rc" = 2
run --check --check; rc=$?
check "usage: a repeated flag exits 2" test "$rc" = 2
run bogus; rc=$?
check "usage: an unknown argument exits 2" test "$rc" = 2
check "usage: nothing written" test -z "$(ls -A "$dir" | grep -v '^out$')"

# 5c. Other handlers in the guard's own group survive a re-apply; only the
#     guard's handler is replaced, in place. A group left empty goes.
sandbox
cat >"$h" <<'EOF'
{"hooks": {"PreToolUse": [
  {"matcher": "^Bash$", "hooks": [
    {"type": "command", "command": "mine-first", "timeout": 5},
    {"type": "command", "command": "python3 ~/.codex/hooks/jarvis-guard.py", "timeout": 3},
    {"type": "command", "command": "mine-last"}]},
  {"matcher": "Bash|apply_patch", "hooks": [
    {"type": "command", "command": "python3 /x/hooks/jarvis-guard.py --old"},
    {"type": "command", "command": "mine-other-matcher"}]},
  {"matcher": "x", "hooks": [{"type": "command", "command": "python3 /y/hooks/jarvis-guard.py"}]}
]}}
EOF
run; rc=$?
check "shared group: exit 0" test "$rc" = 0
check "shared group: person's handlers kept, in order, guard in place" q '.hooks.PreToolUse[0].hooks | map(.command | if contains("jarvis-guard.py") then "G" else . end) == ["mine-first", "G", "mine-last"]'
check "shared group: guard handler is current" q '.hooks.PreToolUse[0].hooks[1].timeout == 10 and (.hooks.PreToolUse[0].hooks[1].command | endswith("--codex"))'
check "shared group: other matcher keeps its other handler, loses the guard's" q '.hooks.PreToolUse[1].matcher == "Bash|apply_patch" and (.hooks.PreToolUse[1].hooks | map(.command) == ["mine-other-matcher"])'
check "shared group: an emptied group is dropped" q '(.hooks.PreToolUse | length) == 2 and '"$own_count"' == 1'
cp "$h" "$dir/before"
run --check; rc=$?
check "shared group: --check exit 0 on the result" test "$rc" = 0
run
check "shared group: re-apply changes nothing" cmp -s "$dir/before" "$h"

# 5c2. The guard's first group has another matcher and holds a person's
#      handler beside a stale guard handler: the person's handler stays in its
#      group, and the guard gets a group of its own, ^Bash$, right after it.
sandbox
cat >"$h" <<'EOF'
{"hooks": {"PreToolUse": [
  {"matcher": "Bash|apply_patch", "hooks": [
    {"type": "command", "command": "python3 /x/hooks/jarvis-guard.py --old"},
    {"type": "command", "command": "mine-other-matcher", "timeout": 7}]}
]}}
EOF
run
check "other matcher: the person's group keeps its handler" q '.hooks.PreToolUse[0] == {"matcher": "Bash|apply_patch", "hooks": [{"type": "command", "command": "mine-other-matcher", "timeout": 7}]}'
check "other matcher: the guard has a ^Bash\$ group of its own after it" q '(.hooks.PreToolUse | length) == 2 and .hooks.PreToolUse[1].matcher == "^Bash$" and (.hooks.PreToolUse[1].hooks | length) == 1 and '"$own_count"' == 1'
cp "$h" "$dir/before"
run
check "other matcher: re-apply changes nothing" cmp -s "$dir/before" "$h"

# 5d. hooks.json keeps its file mode; a new one gets the umask's default.
sandbox
echo '{"hooks": {"Stop": []}}' >"$h"; chmod 644 "$h"
run
check "mode: existing 0644 stays 0644" test "$(mode "$h")" = 644
check "mode: the backup keeps it too" test "$(mode "$h.guard-backup")" = 644
sandbox
echo '{"hooks": {"Stop": []}}' >"$h"; chmod 640 "$h"
run
check "mode: existing 0640 stays 0640" test "$(mode "$h")" = 640
sandbox
(umask 022; run)
check "mode: a new file gets 0644 under umask 022" test "$(mode "$h")" = 644

# 5e. A change to hooks.json between the read and the write is caught: a jq
#     shim rewrites the file when the script is about to write it.
sandbox
mkdir -p "$dir/shim"
real_jq=$(command -v jq)
cat >"$dir/shim/jq" <<EOF
#!/bin/sh
if [ "\$#" = 1 ] && [ "\$1" = . ] && [ -n "\${SHIM_FILE-}" ]; then
  echo '{"hooks": {"Stop": []}, "saved": "meanwhile"}' >"\$SHIM_FILE"
fi
exec "$real_jq" "\$@"
EOF
chmod +x "$dir/shim/jq"
echo '{"hooks": {"Stop": []}}' >"$h"
PATH="$dir/shim:$PATH" SHIM_FILE="$h" run; rc=$?
check "concurrent: exit 2" test "$rc" = 2
check "concurrent: the other writer's file is intact" q '.saved == "meanwhile" and (.hooks | has("PreToolUse") | not)'
check "concurrent: no backup, no stray temp file" test ! -e "$h.guard-backup" -a "$(ls "$dir" | grep -c 'hooks.json\.')" = 0
check "concurrent: the message tells the truth about the hook file" bash -c "grep -q 'was not written' '$dir/out' && grep -q 'hook file' '$dir/out' && ! grep -q 'nothing was written' '$dir/out'"
check "concurrent: and the hook file is in fact there" test -f "$dir/hooks/jarvis-guard.py"

# 6. hooks.json that is a link keeps being a link; its target is updated.
sandbox
mkdir -p "$dir/dotfiles"
echo '{"hooks": {"Stop": []}}' >"$dir/dotfiles/hooks.json"
ln -s dotfiles/hooks.json "$h"
run
check "link: still a link" test -L "$h"
check "link: target carries the guard" jq -e "$own_count == 1 and (.hooks | has(\"Stop\"))" "$dir/dotfiles/hooks.json" >/dev/null

# 7. With CODEX_HOME unset, ~/.codex under HOME is the default.
sandbox
mkdir -p "$dir/home"
HOME="$dir/home" env -u CODEX_HOME bash "$apply" >"$dir/out" 2>&1
check "default home: installed under HOME/.codex" test -f "$dir/home/.codex/hooks.json" -a -f "$dir/home/.codex/hooks/jarvis-guard.py"

# --- the installed hook, as Codex runs it --------------------------------------

sandbox
hookhome=$dir
run
cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$hookhome/hooks.json")

git_init() {
  git init -q -b main "$1"
  git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
}
feat="$root/feat"; onmain="$root/onmain"
git_init "$feat"; git -C "$feat" switch -q -c feat/x
git_init "$onmain"
git -C "$onmain" remote add origin git@github.com:example/shared.git
git -C "$onmain" tag v1.0.0

total=0
# Run the line Codex runs, with the stdin given; print "<exit> <decision>
# <reason>". A hook that does not answer in time is "hang": Codex would run it.
fire() { # input file
  local out rc
  out=$(CODEX_HOME="$hookhome" perl -e 'alarm 10; exec @ARGV' sh -c "$cmd" <"$1" 2>"$root/stderr"); rc=$?
  if [ "$rc" = 142 ]; then echo "hang"; return; fi
  if [ -z "$out" ]; then printf '%s none ' "$rc"; return; fi
  printf '%s %s %s' "$rc" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "garbage"' 2>/dev/null || echo garbage)" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)"
}
verdict() { # name, want (deny|none), reason pattern, then fire's output
  local name=$1 want=$2 pat=$3 rc=$4 got=${5-} reason=${6-}
  total=$((total + 1))
  if [ "$rc" = 0 ] && [ "$got" = "$want" ] && [[ "$reason" == $pat ]]; then
    printf 'ok   %-5s %s\n' "$want" "$name"
  else
    printf 'FAIL want exit 0 %s %s, got exit %s %s %s: %s\n' "$want" "$pat" "$rc" "$got" "$reason" "$name"
    fails=$((fails + 1))
  fi
}
answer() { # name, want, pattern: judge the hook's reply to $root/in.json
  local res rc got reason
  res=$(fire "$root/in.json")
  if [ "$res" = hang ]; then rc=hang; got=; reason=; else rc=${res%% *}; res=${res#* }; got=${res%% *}; reason=${res#"$got"}; reason=${reason# }; fi
  verdict "$1" "$2" "$3" "$rc" "$got" "$reason"
}
probe() { # want, command, cwd, reason pattern
  local want=$1 cmdline=$2 cwd=${3:-$feat} pat=${4:-*}
  jq -n --arg c "$cmdline" --arg d "$cwd" \
    '{session_id: "s", turn_id: "t", cwd: $d, hook_event_name: "PreToolUse", model: "m", tool_name: "Bash", tool_use_id: "u", tool_input: {command: $c}}' >"$root/in.json"
  answer "${cmdline//$'\n'/⏎}" "$want" "$pat"
}
raw() { # name, want, reason pattern, raw stdin text
  printf '%s' "$4" >"$root/in.json"
  answer "$1" "$2" "$3"
}

echo "== prohibited: deny, in the Codex guard's name"
pro='Codex guard: *permanently prohibited*'
probe deny 'git push --force origin feat/x' "$feat" "$pro"
probe deny 'rm -rf build' "$feat" "$pro"
probe deny 'git -C . branch -D t1' "$feat" "$pro"
probe deny 'bash -c "git reset --hard HEAD"' "$feat" "$pro"
probe deny 'git rm README.md' "$feat" "$pro"

echo "== checkpoints: Claude mode asks, Codex cannot, so deny"
cp_pat='Codex guard: *human-review checkpoint*Codex cannot ask*exact command*'
probe deny 'git push origin main' "$feat" "$cp_pat"
probe deny 'git push' "$onmain" "$cp_pat"
probe deny 'gh pr merge 12 --squash' "$feat" "$cp_pat"
probe deny 'git push origin v1.0.0' "$onmain" "$cp_pat"
probe deny 'git push --follow-tags origin feat/x' "$onmain" "$cp_pat"

echo "== ordinary work: no decision"
probe none 'git status' "$feat"
probe none 'ls -la' "$feat"
probe none 'git push origin feat/x' "$feat"
probe none 'gh pr view 12 --json state' "$feat"
probe none 'echo "git push --force is refused"' "$feat"

echo "== the guard cannot decide: deny, exit 0"
raw "non-JSON input" deny 'Codex guard: *not JSON*' 'this is not json'
raw "empty input" deny 'Codex guard: *not JSON*' ''
raw "tool_input a list: main raises" deny 'Codex guard: the guard failed (AttributeError*not checked*' '{"tool_name":"Bash","tool_input":["x"],"cwd":"/"}'
raw "top level a list: main raises" deny 'Codex guard: the guard failed (AttributeError*' '[]'
raw "tool other than Bash" none '*' '{"tool_name":"apply_patch","tool_input":{"command":"git push --force"}}'

echo "== the guard hangs: deny before Codex's timeout, exit 0"
# Codex runs the command when a hook overruns its 10 s timeout. Input that
# never ends keeps the guard waiting on stdin, the way a hang would; the
# watchdog has to answer deny well inside the timeout. The time limit lives
# in a parent that forks the hook, because an alarm set before exec is
# inherited and would fire the guard's own handler, passing without it.
hang_out=$( (sleep 15) | CODEX_HOME="$hookhome" HANG_SECS="$root/hang-secs" perl -e '
  my $t = time; my $pid = fork; if (!$pid) { exec @ARGV }
  $SIG{ALRM} = sub { kill "KILL", $pid; exit 142 }; alarm 12;
  waitpid($pid, 0); my $rc = $? >> 8;
  open(my $f, ">", $ENV{HANG_SECS}); print $f time - $t; close $f; exit $rc' sh -c "$cmd" 2>"$root/stderr"); hang_rc=$?
# The guard has to answer before Codex gives up on it at 10 s.
if [ "$hang_rc" != 142 ] && [ "$(cat "$root/hang-secs" 2>/dev/null || echo 99)" -ge 10 ]; then hang_rc="late($(cat "$root/hang-secs")s)"; fi
if [ "$hang_rc" = 142 ]; then
  verdict "stdin never closes" deny 'Codex guard: *did not finish in time*' hang "" ""
else
  verdict "stdin never closes" deny 'Codex guard: *did not finish in time*' "$hang_rc" \
    "$(printf '%s' "$hang_out" | jq -r '.hookSpecificOutput.permissionDecision // "garbage"' 2>/dev/null || echo garbage)" \
    "$(printf '%s' "$hang_out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)"
fi

echo "== the answer is printed once, and the watchdog stays off after it"
# Each case runs a copy of the guard with one line of test code inserted at a
# point where an answer is already out (or was not needed), and the hook is
# then held there past the watchdog's 8 s. The copy lives in the sandbox; the
# guard itself carries no test hook. A marker file says the guard ran on to
# the end instead of being cut off by the watchdog.
py=$(command -v /usr/bin/python3 || command -v python3)
patched() { # name, want (deny|none), where (after|before), anchor line (exact), inserted code, stdin json
  local name=$1 want=$2 where=$3 anchor=$4 code=$5 json=$6 copy="$root/patched-$total.py" mark="$root/mark-$total"
  total=$((total + 1))
  "$py" -I - "$src" "$copy" "$where" "$anchor" "$code" "$mark" <<'PY' || { fail "$name: could not patch the guard copy"; return; }
import sys
src, dst, where, anchor, code, mark = sys.argv[1:7]
lines = open(src).read().split("\n")
at = [i for i, line in enumerate(lines) if line == anchor]
if len(at) != 1:
    sys.exit("anchor not found exactly once: " + anchor)
indent = anchor[:len(anchor) - len(anchor.lstrip())]
body = [indent + line for line in code.replace("MARK", repr(mark)).split("\n")]
i = at[0] + (1 if where == "after" else 0)
open(dst, "w").write("\n".join(lines[:i] + body + lines[i:]))
PY
  mkdir -p "$root/patched-home-$total/hooks"
  CODEX_HOME="$root/patched-home-$total" bash "$apply" >/dev/null 2>&1
  cp "$copy" "$root/patched-home-$total/hooks/jarvis-guard.py"
  printf '%s' "$json" >"$root/in.json"
  local out rc objs
  out=$(CODEX_HOME="$root/patched-home-$total" perl -e 'alarm 15; exec @ARGV' sh -c "$cmd" <"$root/in.json" 2>"$root/stderr"); rc=$?
  objs=$(printf '%s' "$out" | jq -s 'length' 2>/dev/null || echo bad)
  if [ "$rc" = 0 ] && [ -e "$mark" ] && { { [ "$want" = deny ] && [ "$objs" = 1 ] && [ "$(printf '%s' "$out" | jq -r .hookSpecificOutput.permissionDecision)" = deny ]; } || { [ "$want" = none ] && [ -z "$out" ]; }; }; then
    printf 'ok   %-5s %s\n' "$want" "$name"
  else
    printf 'FAIL %s: want %s, ran to the end: %s; got exit %s, %s object(s)\n' "$name" "$want" "$([ -e "$mark" ] && echo yes || echo no)" "$rc" "$objs"
    fails=$((fails + 1))
  fi
}
deny_json=$(jq -nc --arg d "$feat" '{tool_name:"Bash",cwd:$d,tool_input:{command:"git push --force"}}')
allow_json=$(jq -nc --arg d "$feat" '{tool_name:"Bash",cwd:$d,tool_input:{command:"git status"}}')
# The answer is out, then 9 s pass in emit: nothing may cut the guard off or
# add a second answer (the disarm in emit).
patched "9 s after the answer, inside emit: one object, not cut off" deny after \
  "    sys.stdout.flush()" 'import time; time.sleep(9); open(MARK, "w").close()' "$deny_json"
# emit succeeded and then something raised: the handler in main emits again,
# and the second answer must not print (the answered flag).
patched "an error after the answer: still one object" deny after \
  "    sys.stdout.flush()" 'open(MARK, "w").close(); raise RuntimeError("after the answer")' "$deny_json"
# No answer was needed, then 9 s pass in main: the watchdog must be off (the
# alarm(0) in main).
patched "9 s after no decision, in main: no output, not cut off" none before \
  "    return 0" 'import time; time.sleep(9); open(MARK, "w").close()' "$allow_json"

echo
if [ "$fails" -gt 0 ]; then echo "$fails failure(s)"; exit 1; fi
echo "all passed ($total hook probes)"
