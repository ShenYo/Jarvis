#!/usr/bin/env bash
# Tests for scripts/apply-agy-guard.sh and for the guard run as an agy hook
# (bash-guard.py --agy), each in its own sandbox HOME, so the real ~/.gemini
# is never read or written.
set -uo pipefail

for v in $(compgen -e | grep -E '^(GIT_CONFIG_|GIT_AUTHOR_|GIT_COMMITTER_)'); do unset "$v"; done
unset GIT_SSH_COMMAND GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GH_CONFIG_DIR GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN \
  GITHUB_ENTERPRISE_TOKEN GH_HOST JARVIS_AGENT_IDENTITY JARVIS_REQUIRE_AGENT_IDENTITY CODEX_HOME CLAUDE_CONFIG_DIR XDG_CONFIG_HOME

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
apply="${APPLY_AGY_GUARD:-$repo/scripts/apply-agy-guard.sh}"
src="$repo/.agents/claude-guard/bash-guard.py"
root=$(mktemp -d "${TMPDIR:-/tmp}/agy-guard-test.XXXXXX")
echo "sandboxes: $root"

fails=0
total=0
ok()   { total=$((total + 1)); echo "ok   $1"; }
fail() { total=$((total + 1)); echo "FAIL $1"; fails=$((fails + 1)); }
check() {
  local name=$1; shift
  if "$@"; then ok "$name"; else fail "$name"; fi
}

n=0
sandbox() { n=$((n + 1)); dir="$root/$n"; cfg="$dir/.gemini/config"; mkdir -p "$cfg"; h="$cfg/hooks.json"; }
run() { HOME="$dir" bash "$apply" "$@" >"$dir/out" 2>&1; }
q() { jq -e "$1" "$h" >/dev/null; }
snapshot() {
  (cd "$dir" && find . \( -type f -o -type l \) ! -name out ! -name 'snap.*' ! -name before ! -name 'others.*' | sort |
    while read -r f; do printf '%s ' "$f"; cksum <"$f"; done)
}
others() { jq -S 'del(."jarvis-guard")' "$1"; }

# 1. Fresh apply in empty ~/.gemini/config
sandbox
run; rc=$?
check "fresh: exit 0" test "$rc" = 0
check "fresh: hook copied, not linked" test -f "$cfg/hooks/jarvis-guard.py" -a ! -L "$cfg/hooks/jarvis-guard.py"
check "fresh: hook is the repository's" cmp -s "$src" "$cfg/hooks/jarvis-guard.py"
check "fresh: jarvis-guard group has PreToolUse matcher run_command" q '."jarvis-guard".PreToolUse | length == 1 and .[0].matcher == "run_command"'
check "fresh: one command handler, timeout 10, runs /bin/sh -c with -I and --agy" q '."jarvis-guard".PreToolUse[0].hooks | length == 1 and .[0].type == "command" and .[0].timeout == 10 and (.[0].command | startswith("/bin/sh -c \u0027") and contains("-I") and contains("hooks/jarvis-guard.py") and endswith("--agy\u0027"))'

# 2. Idempotent re-run
snapshot >"$dir/snap.before"
run; rc=$?
snapshot >"$dir/snap.after"
check "idempotent: exit 0" test "$rc" = 0
check "idempotent: nothing changed" cmp -s "$dir/snap.before" "$dir/snap.after"
check "idempotent: no backup of unchanged file" test ! -e "$h.guard-backup"

# 3. --check reports each state without writing
snapshot >"$dir/snap.before"
run --check; rc=$?
snapshot >"$dir/snap.after"
check "--check applied: exit 0" test "$rc" = 0
check "--check applied: touches no file" cmp -s "$dir/snap.before" "$dir/snap.after"

sandbox
run --check; rc=$?
check "--check empty: exit 1" test "$rc" = 1
check "--check empty: writes nothing" test ! -e "$h" -a ! -e "$cfg/hooks/jarvis-guard.py"

sandbox
run
echo "# edited" >>"$cfg/hooks/jarvis-guard.py"
run --check; rc=$?
check "hook drift: --check exit 1" test "$rc" = 1
run
check "hook drift: re-run restores hook" cmp -s "$src" "$cfg/hooks/jarvis-guard.py"

# 4. Merge preserves herdr and orca-status byte-for-byte
sandbox
cat >"$h" <<'EOF'
{
  "herdr": {
    "PreInvocation": [
      {"command": "bash '/tmp/herdr.sh' session", "timeout": 10, "type": "command"}
    ]
  },
  "orca-status": {
    "PreToolUse": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "/bin/sh '/tmp/orca.sh'", "timeout": 10}]}
    ]
  }
}
EOF
cp "$h" "$dir/before"
others "$h" >"$dir/others.before"
run --check; rc=$?
check "merge: --check exit 1 before" test "$rc" = 1
run; rc=$?
others "$h" >"$dir/others.after"
check "merge: exit 0" test "$rc" = 0
check "merge: herdr and orca-status unchanged" cmp -s "$dir/others.before" "$dir/others.after"
check "merge: backup equals previous file" cmp -s "$dir/before" "$h.guard-backup"
run --check; rc=$?
check "merge: --check exit 0 after" test "$rc" = 0

# 5. Symlinked hooks.json writes through link
sandbox
mkdir -p "$dir/dotfiles"
echo '{"herdr":{"PreInvocation":[]}}' >"$dir/dotfiles/hooks.json"
ln -s "$dir/dotfiles/hooks.json" "$h"
run; rc=$?
check "symlink: exit 0" test "$rc" = 0
check "symlink: hooks.json stays a symlink" test -L "$h"
check "symlink: target has jarvis-guard" jq -e '."jarvis-guard" != null and .herdr != null' "$dir/dotfiles/hooks.json" >/dev/null

# 6. Invalid JSON is refused (exit 2) and left untouched
sandbox
printf '{not json\n' >"$h"
cp "$h" "$dir/before"
run; rc=$?
check "invalid json: exit 2" test "$rc" = 2
check "invalid json: file untouched" cmp -s "$dir/before" "$h"

# 7. Usage flags
sandbox
run --help; rc=$?
check "usage: --help exit 0" test "$rc" = 0
run --bogus; rc=$?
check "usage: unknown flag exit 2" test "$rc" = 2
run --check --check; rc=$?
check "usage: duplicate --check exit 2" test "$rc" = 2

# 8. Execute the installed hook command directly (word-split exec, no outer shell) against agy stdin payloads
sandbox
run
hook_cmd=$(jq -r '."jarvis-guard".PreToolUse[0].hooks[0].command' "$h")
exec_hook() {
  HOME="$dir" python3 -c 'import shlex, subprocess, sys; sys.exit(subprocess.run(shlex.split(sys.argv[1])).returncode)' "$hook_cmd" 2>"$dir/err"
}
probe_cmd() {
  local want=$1 cmd=$2 out rc got
  jq -n --arg c "$cmd" --arg d "$dir" '{toolCall:{id:"t1",name:"run_command",args:{CommandLine:$c}},cwd:$d,hookEventName:"PreToolUse"}' >"$dir/in.json"
  out=$(exec_hook <"$dir/in.json"); rc=$?
  got=$(printf '%s' "$out" | jq -r '.decision // empty' 2>/dev/null)
  got=${got:-allow}
  check "hook probe ($cmd): $want" test "$rc" = 0 -a "$got" = "$want"
}
probe_cmd deny "git push --force origin feat"
probe_cmd deny "git reset --hard HEAD~1"
probe_cmd deny "rm -rf /tmp/something"
probe_cmd deny "git commit --no-verify -m x"
probe_cmd deny "gh pr merge 1"
probe_cmd allow "git status"

jq -n --arg d "$dir" '{toolCall:{id:"t2",name:"view_file",args:{AbsolutePath:"/tmp/x"}},cwd:$d,hookEventName:"PreToolUse"}' >"$dir/noncmd.json"
out=$(exec_hook <"$dir/noncmd.json"); rc=$?
check "hook probe non-run_command: empty output, exit 0" test "$rc" = 0 -a -z "$out"

out=$(exec_hook <<<'{bad json'); rc=$?
got=$(printf '%s' "$out" | jq -r '.decision // empty' 2>/dev/null)
check "hook probe malformed json: fail-closed deny, exit 0" test "$rc" = 0 -a "$got" = deny

echo
if [ "$fails" -gt 0 ]; then echo "$fails of $total failed"; exit 1; fi
echo "all $total passed"
