#!/usr/bin/env bash
# Tests for .agents/claude-guard/session-notes.py, run in a throwaway sandbox
# with a small git repo and synthetic transcripts. Set HOOK=<path> to point the
# test at another copy of the hook (how a mutant is checked).
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
hook=${HOOK:-$repo/.agents/claude-guard/session-notes.py}
root=$(mktemp -d "${TMPDIR:-/tmp}/session-notes-test.XXXXXX")
root=$(cd "$root" && pwd -P)
echo "sandbox: $root"

unset CLAUDE_PROJECT_DIR
proj="$root/proj"
plain="$root/plain"
mkdir -p "$proj" "$plain"
git -C "$proj" init -q
printf 'docs/temp/\n' >"$proj/.gitignore"

fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { # name, then a command that must succeed
  local name=$1; shift
  if "$@"; then ok "$name"; else fail "$name"; fi
}

out=""; rc=0
run() { # JSON on stdin of the hook; sets out and rc
  out=$(printf '%s' "$1" | python3 -I "$hook" 2>/dev/null); rc=$?
}
no_out() { test "$rc" = 0 && test -z "$out"; }
ctx_has() { jq -e --arg s "$1" '.hookSpecificOutput.additionalContext | contains($s)' <<<"$out" >/dev/null; }
event_is() { jq -e --arg e "$1" '.hookSpecificOutput.hookEventName == $e' <<<"$out" >/dev/null; }

usage() { # total tokens (>= 1002) as a main-thread usage line
  printf '{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":1000,"cache_read_input_tokens":%d}}}\n' $(($1 - 1002))
}
side()    { printf '{"type":"assistant","isSidechain":true,"message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":1000,"cache_read_input_tokens":%d}}}\n' $(($1 - 1002)); }
compact() { printf '{"type":"system","subtype":"compact_boundary","isSidechain":false,"compactMetadata":{"postTokens":%d}}\n' "$1"; }

t=0
transcript() { t=$((t + 1)); tpath="$root/t$t.jsonl"; cat >"$tpath"; }
prompt() { # session id, cwd (default proj); uses $tpath
  jq -nc --arg s "$1" --arg c "${2:-$proj}" --arg t "$tpath" \
    '{hook_event_name:"UserPromptSubmit",session_id:$s,cwd:$c,transcript_path:$t,prompt:"hi"}'
}
start() { # session id, source, cwd (default proj)
  jq -nc --arg s "$1" --arg o "$2" --arg c "${3:-$proj}" \
    '{hook_event_name:"SessionStart",session_id:$s,cwd:$c,source:$o}'
}
notes_file() { mkdir -p "$proj/docs/temp/session-notes"; : >"$proj/docs/temp/session-notes/$1.md"; echo "$proj/docs/temp/session-notes/$1.md"; }

# 1. Below the threshold: silent.
transcript < <(usage 100000)
run "$(prompt s1)"
check "below 300k: no output, exit 0" no_out

# 2. Above the threshold, no notes.
transcript < <(usage 400000)
run "$(prompt s2)"
check "above 300k: exit 0" test "$rc" = 0
check "above 300k: UserPromptSubmit JSON" event_is UserPromptSubmit
check "above 300k: says no notes yet" ctx_has "no notes yet"
check "above 300k: says 400k" ctx_has "400k"

# 3. Notes exist: the path is named.
f=$(notes_file s3)
transcript < <(usage 400000)
run "$(prompt s3)"
check "notes exist: full path in context" ctx_has "$f"
check "notes exist: not 'no notes yet'" bash -c '! jq -e ".hookSpecificOutput.additionalContext | contains(\"no notes yet\")" <<<"$1" >/dev/null' _ "$out"

# 4. A compaction after the big request wins.
transcript < <({ usage 400000; compact 40000; })
run "$(prompt s4)"
check "compact_boundary after big usage: no output" no_out

# 5. Sidechain usage is ignored.
transcript < <({ usage 50000; side 900000; })
run "$(prompt s5)"
check "huge sidechain usage ignored: no output" no_out

# 6. A garbage line does not hide the usage before it.
transcript < <({ usage 400000; echo 'not json {{{'; })
run "$(prompt s6)"
check "garbage trailing line: still hints" ctx_has "400k"

# 7. Threshold edges.
transcript < <(usage 300000)
run "$(prompt s7a)"
check "exactly 300000: hints" ctx_has "300k"
transcript < <(usage 299999)
run "$(prompt s7b)"
check "299999: no output" no_out

# 8. SessionStart.
f=$(notes_file s8)
run "$(start s8 compact)"
check "SessionStart compact + notes: SessionStart JSON" event_is SessionStart
check "SessionStart compact + notes: path in context" ctx_has "$f"
run "$(start s8none compact)"
check "SessionStart compact, no notes: no output" no_out
run "$(start s8 startup)"
check "SessionStart startup + notes: no output" no_out

# 9. CLAUDE_PROJECT_DIR wins over a non-repo cwd.
f=$(notes_file s9)
out=$(CLAUDE_PROJECT_DIR="$proj" python3 -I "$hook" <<<"$(start s9 compact "$plain")" 2>/dev/null); rc=$?
check "CLAUDE_PROJECT_DIR with non-repo cwd: finds notes" ctx_has "$f"
run "$(start s9 compact "$plain")"
check "non-repo cwd without CLAUDE_PROJECT_DIR: no output" no_out

# 10. Bad input never errors.
run 'this is not json'
check "stdin not JSON: no output, exit 0" no_out
run "$(jq -nc --arg t "$root/missing.jsonl" '{hook_event_name:"UserPromptSubmit",session_id:"s10",cwd:"/tmp",transcript_path:$t}')"
check "missing transcript: no output, exit 0" no_out

# 11. A session id with a slash is refused.
mkdir -p "$proj/docs/temp/session-notes/sub" && : >"$proj/docs/temp/session-notes/sub/s11.md"
run "$(start 'sub/s11' compact)"
check "session_id with slash: no output" no_out

# 12. Only the tail of a large transcript is read.
t=$((t + 1)); tpath="$root/t$t.jsonl"
{ head -c $((5 << 20)) /dev/zero | tr '\0' 'x' | fold -w 1000; echo; usage 400000; echo '{"type":"user"}'; } >"$tpath"
check "fixture is over 4 MiB" test "$(wc -c <"$tpath")" -gt $((4 << 20))
run "$(prompt s12)"
check "transcript over 4 MiB: tail read hints" ctx_has "400k"

if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failure(s)"; exit 1; fi
