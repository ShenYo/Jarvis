#!/usr/bin/env bash
# Tests for .agents/claude-guard/shell-syntax.py, run in a throwaway sandbox.
# Set HOOK=<path> to point the test at another copy of the hook (how a mutant
# is checked).
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
hook=${HOOK:-$repo/.agents/claude-guard/shell-syntax.py}
root=$(mktemp -d "${TMPDIR:-/tmp}/shell-syntax-test.XXXXXX")
root=$(cd "$root" && pwd -P)
echo "sandbox: $root"

fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { # name, then a command that must succeed
  local name=$1; shift
  if "$@"; then ok "$name"; else fail "$name"; fi
}

out=""; err=""; rc=0
run() { # JSON on stdin of the hook; sets out, err and rc
  out=$(printf '%s' "$1" | python3 -I "$hook" 2>"$root/err"); rc=$?
  err=$(cat "$root/err")
}
edited() { jq -nc --arg f "$1" '{hook_event_name:"PostToolUse",tool_name:"Edit",tool_input:{file_path:$f}}'; }
silent() { test "$rc:$out:$err" = "0::"; }
flagged() { test "$rc" = 2 && test -z "$out" && [[ $err == *"$1"*"does not parse"* ]]; }

good='echo "ok"
if [ -n "$1" ]; then echo yes; fi'
bad='if [ -n "$1" ]; then
  echo yes'

printf '%s\n' "$good" >"$root/good.sh"
run "$(edited "$root/good.sh")"
check "a .sh file that parses: silent" silent

printf '%s\n' "$bad" >"$root/bad.sh"
run "$(edited "$root/bad.sh")"
check "a .sh file that does not parse: exit 2, names the file" flagged "$root/bad.sh"
check "a .sh file that does not parse: bash's own message is passed on" test -n "${err#*does not parse*:}"

printf '%s\n' "$bad" >"$root/bad.bash"
run "$(edited "$root/bad.bash")"
check "a .bash file that does not parse: flagged" flagged "$root/bad.bash"

printf '#!/usr/bin/env bash\n%s\n' "$bad" >"$root/pre-commit"
run "$(edited "$root/pre-commit")"
check "no suffix, #!/usr/bin/env bash: flagged" flagged "$root/pre-commit"

printf '#!/bin/sh\n%s\n' "$bad" >"$root/hook-sh"
run "$(edited "$root/hook-sh")"
check "no suffix, #!/bin/sh: flagged" flagged "$root/hook-sh"

printf '#!/usr/bin/env -S bash -e\n%s\n' "$bad" >"$root/env-s"
run "$(edited "$root/env-s")"
check "no suffix, env with an option: flagged" flagged "$root/env-s"

printf '#!/bin/zsh\n%s\n' "$bad" >"$root/zsh-script"
run "$(edited "$root/zsh-script")"
check "a zsh script: left alone" silent

printf '%s\n' "$bad" >"$root/notes.md"
run "$(edited "$root/notes.md")"
check "not a shell script: left alone" silent

printf '#!/usr/bin/env python3\nif True\n' >"$root/tool"
run "$(edited "$root/tool")"
check "a python script with no suffix: left alone" silent

run "$(jq -nc --arg f "$root/bad.sh" '{hook_event_name:"PostToolUse",tool_name:"Write",tool_input:{file_path:$f,content:"x"}}')"
check "a Write is checked too" flagged "$root/bad.sh"

run "$(edited "$root/missing.sh")"
check "a file that is gone: silent" silent

mkdir "$root/dir.sh"
run "$(edited "$root/dir.sh")"
check "a directory named like a script: silent" silent

printf '# sh notes\n%s\n' "$bad" >"$root/notes"
run "$(edited "$root/notes")"
check "a first line that is not #!: left alone" silent

# bash quotes the failing line back, so its message carries the raw byte.
printf 'echo caf\351 )\n' >"$root/latin1.sh"
run "$(edited "$root/latin1.sh")"
check "a parse error on a line that is not UTF-8: still flagged" flagged "$root/latin1.sh"

if [ -x /bin/bash ]; then
  mkdir "$root/fakebin"
  # Fake only for -n: python3 itself may be a bash shim found through PATH.
  printf '#!/bin/sh\ncase "$1" in -n) echo fake >&2; exit 1 ;; esac\nexec /bin/bash "$@"\n' >"$root/fakebin/bash"
  chmod +x "$root/fakebin/bash"
  PATH="$root/fakebin:$PATH" run "$(edited "$root/good.sh")"
  check "/bin/bash is preferred over a bash earlier on PATH" silent
fi

run '{"tool_input":{}}'
check "no file_path: silent" silent

run 'not json'
check "input that is not JSON: silent" silent

echo
if [ "$fails" -gt 0 ]; then echo "$fails failure(s)"; exit 1; fi
echo "all passed"
