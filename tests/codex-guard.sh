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

# Hermetic: this suite may run inside an agent session whose environment carries the applied
# identity; none of it may reach the hook. Every case sets what it needs.
for v in $(compgen -e | grep -E '^(GIT_CONFIG_|GIT_AUTHOR_|GIT_COMMITTER_)'); do unset "$v"; done
unset GIT_SSH_COMMAND GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GH_CONFIG_DIR GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN \
  GITHUB_ENTERPRISE_TOKEN GH_HOST JARVIS_AGENT_IDENTITY JARVIS_REQUIRE_AGENT_IDENTITY CODEX_HOME CLAUDE_CONFIG_DIR XDG_CONFIG_HOME

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
apply="$repo/scripts/apply-codex-guard.sh"
src="$repo/.agents/claude-guard/bash-guard.py"
root=$(mktemp -d "${TMPDIR:-/tmp}/codex-guard-test.XXXXXX")
echo "sandboxes: $root"
# the require record of Claude Code, which apply-codex-guard.sh reads, comes from an empty directory unless a case says otherwise
mkdir -p "$root/no-claude"; export CLAUDE_CONFIG_DIR="$root/no-claude"
# ... and so is HOME, whose ~/.claude it also reads
mkdir -p "$root/home"; export HOME="$root/home"

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

# Record Codex's trust of the installed guard entry, the way /hooks does: a trusted_hash in
# config.toml under the entry's key. The hash is worked out here from the formula Codex uses (sha256
# of the compact JSON, keys sorted, of the event, the group's matcher and the handler), and the golden
# cases below pin that formula to a value Codex itself stored.
sha256_stdin() { shasum -a 256 2>/dev/null | cut -d' ' -f1 || sha256sum | cut -d' ' -f1; }
trust_hook() { # [dir] [the directory the key names: Codex canonicalises CODEX_HOME]
  local d=${1:-$dir} g h hash
  read -r g h < <(jq -r 'first(.hooks.PreToolUse | to_entries[] | .key as $g | .value.hooks | to_entries[]
    | select(.value.command | contains("/hooks/jarvis-guard.py")) | "\($g) \(.key)")' "$d/hooks.json")
  hash=$(jq -cS --argjson g "$g" --argjson h "$h" '.hooks.PreToolUse[$g] as $grp | $grp.hooks[$h] as $x
    | {event_name: "pre_tool_use", matcher: $grp.matcher,
       hooks: [{type: $x.type, command: $x.command, timeout: ($x.timeout // 600), async: ($x.async // false), statusMessage: $x.statusMessage}]}' \
    "$d/hooks.json" | tr -d '\n' | sha256_stdin)
  printf '\n[hooks.state."%s/hooks.json:pre_tool_use:%s:%s"]\ntrusted_hash = "sha256:%s"\n' "${2:-$(cd "$d" && pwd -P)}" "$g" "$h" "$hash" >>"$d/config.toml"
}

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
check "fresh: the switch is off in the hook command" bash -c "grep -q 'agent-identity switch is off' '$dir/out'"
check "fresh: reports UNTRUSTED with the fix" bash -c "grep -q 'trust: UNTRUSTED' '$dir/out' && grep -q 'open /hooks in Codex and trust the Jarvis guard (until then Codex skips it)' '$dir/out'"
check "fresh: no stray error output" bash -c "! grep -qi 'no such file\\|error' '$dir/out'"

# 2. A second apply changes nothing and says nothing about trust.
snapshot >"$dir/snap.before"
run; rc=$?
snapshot >"$dir/snap.after"
check "idempotent: exit 0" test "$rc" = 0
check "idempotent: nothing changed" cmp -s "$dir/snap.before" "$dir/snap.after"
check "idempotent: no backup of an unchanged file" test ! -e "$h.guard-backup"
check "idempotent: no trust prompt" bash -c "! grep -q 'trusted in' '$dir/out'"

# 3. --check: 0 when applied and trusted, writes nothing; 1 when not.
trust_hook
snapshot >"$dir/snap.before"
run --check; rc=$?
snapshot >"$dir/snap.after"
check "--check applied and trusted: exit 0" test "$rc" = 0
check "--check applied and trusted: says Codex trusts it" grep -q 'trust: OK' "$dir/out"
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
trust_hook
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
trust_hook
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

# --- the agent-identity switch in the hook command -------------------------------

sw_on='.hooks.PreToolUse[0].hooks[0].command | endswith(" --codex --require-identity")'
sw_off='.hooks.PreToolUse[0].hooks[0].command | endswith(" --codex")'

# 8. --require-identity writes the switch; --no-require-identity takes it out.
sandbox
run --require-identity; rc=$?
check "switch on: exit 0" test "$rc" = 0
check "switch on: the command ends with --codex --require-identity" q "$sw_on"
check "switch on: still one guard group, 10 s, with a status message" q "$own_count == 1 and .hooks.PreToolUse[0].hooks[0].timeout == 10 and (.hooks.PreToolUse[0].hooks[0].statusMessage | length > 0)"
check "switch on: says the switch is on" grep -q 'agent-identity switch is on' "$dir/out"
check "switch on: --check says the same" bash -c "CODEX_HOME='$dir' bash '$apply' --check --require-identity 2>&1 | grep -q 'agent-identity switch is on'"
run --no-require-identity; rc=$?
check "switch off: exit 0" test "$rc" = 0
check "switch off: the command ends with --codex" q "$sw_off"
check "switch off: says the switch is off" grep -q 'agent-identity switch is off' "$dir/out"

# 8b. With neither flag the installed state stays, on or off, through a re-run and an update
#     of the hook file (what a Jarvis update does).
sandbox
run --require-identity
echo "# stale" >>"$dir/hooks/jarvis-guard.py"
run; rc=$?
check "keep on: a plain re-run exits 0" test "$rc" = 0
check "keep on: the switch is still on" q "$sw_on"
check "keep on: the hook file was refreshed" cmp -s "$src" "$dir/hooks/jarvis-guard.py"
run --check; rc=$?
check "keep on: --check without a flag does not call the switch drift (only trust is missing)" bash -c "test $rc = 1 && ! grep -q 'differs from the guard' '$dir/out'"
run --check --no-require-identity; rc=$?
check "keep on: --check --no-require-identity sees the difference" bash -c "test $rc = 1 && grep -q 'differs from the guard' '$dir/out'"
sandbox
run
run; rc=$?
check "keep off: a plain re-run keeps it off" bash -c "test $rc = 0 && jq -e '$sw_off' '$h' >/dev/null"
sandbox
printf '{"hooks": {"PreToolUse": [{"matcher": "^Bash$", "hooks": [{"type": "command", "command": "python3 ~/.codex/hooks/jarvis-guard.py --codex --require-identity", "timeout": 3}]}]}}\n' >"$h"
run; rc=$?
check "keep on: an older revision of the entry that had the switch keeps it" bash -c "test $rc = 0 && jq -e '$sw_on' '$h' >/dev/null"
sandbox
run --require-identity --no-require-identity; rc=$?
check "usage: both switch flags exit 2" test "$rc" = 2
run --require-identity --require-identity; rc=$?
check "usage: a repeated switch flag exits 2" test "$rc" = 2
check "usage: nothing written" test -z "$(ls -A "$dir" | grep -v '^out$')"

# --- whether Codex trusts the entry ---------------------------------------------

# 9. OK, UNTRUSTED (hash missing, entry changed), DISABLED; --check fails on all but OK, and a plain run
#    only reports. Nothing is ever written to config.toml by the script.
sandbox
run
trust_hook
cp "$dir/config.toml" "$dir/toml.before"
run --check; rc=$?
check "trust OK: --check exit 0" test "$rc" = 0
check "trust OK: reported" grep -q "trust: OK - Codex trusts the Jarvis guard entry $(cd "$dir" && pwd -P)/hooks.json:pre_tool_use:0:0" "$dir/out"
run --trust; rc=$?
check "trust OK: --trust exit 0" test "$rc" = 0
run; rc=$?
check "trust OK: a plain run reports it" bash -c "test $rc = 0 && grep -q 'trust: OK' '$dir/out'"
check "trust OK: config.toml untouched" cmp -s "$dir/config.toml" "$dir/toml.before"

sandbox
run
printf '[hooks.state."%s/hooks.json:pre_tool_use:0:0"]\nenabled = true\n' "$(cd "$dir" && pwd -P)" >"$dir/config.toml"
run --check; rc=$?
check "trust missing hash: --check exit 1" test "$rc" = 1
check "trust missing hash: UNTRUSTED with the fix" bash -c "grep -q 'trust: UNTRUSTED' '$dir/out' && grep -q 'no trusted_hash' '$dir/out' && grep -q 'open /hooks in Codex and trust the Jarvis guard (until then Codex skips it)' '$dir/out'"
run --trust; rc=$?
check "trust missing hash: --trust exit 1" test "$rc" = 1
sandbox
run
run --check; rc=$?
check "trust no config.toml: UNTRUSTED, exit 1" bash -c "test $rc = 1 && grep -q 'trust: UNTRUSTED' '$dir/out'"
check "trust no config.toml: --check did not create it" test ! -e "$dir/config.toml"

sandbox
run
trust_hook
run --require-identity
check "trust after a changed command: the plain run that changes it says UNTRUSTED" grep -q 'trust: UNTRUSTED' "$dir/out"
run --check; rc=$?
check "trust after a changed command: --check exit 1" test "$rc" = 1
check "trust after a changed command: UNTRUSTED, the entry changed since" bash -c "grep -q 'trust: UNTRUSTED' '$dir/out' && grep -q 'the entry changed since it was trusted' '$dir/out'"
rm -f "$dir/config.toml"; trust_hook   # /hooks stores the new hash
run --check; rc=$?
check "trust after a re-trust: OK again" bash -c "test $rc = 0 && grep -q 'trust: OK' '$dir/out'"
sandbox
run
trust_hook
sed -i.bak 's/--codex/--codex --edited/' "$h" && rm -f "$h.bak"
run --trust; rc=$?
check "trust after a hand-edited command: UNTRUSTED" bash -c "test $rc = 1 && grep -q 'trust: UNTRUSTED' '$dir/out'"

sandbox
run
trust_hook
printf 'enabled = false\n' >>"$dir/config.toml"
run --check; rc=$?
check "trust disabled: --check exit 1" test "$rc" = 1
check "trust disabled: DISABLED with its own fix" bash -c "grep -q 'trust: DISABLED' '$dir/out' && grep -q 'enabled = false' '$dir/out' && grep -q 'fix: enable (and trust) the Jarvis guard in /hooks' '$dir/out'"
sandbox
run
trust_hook
printf 'enabled = true\n' >>"$dir/config.toml"
run --trust; rc=$?
check "trust enabled = true: OK" test "$rc" = 0

# the guard's entry among other tools' entries: the key names its own group and handler index
sandbox
cat >"$h" <<'EOF'
{"hooks": {"PreToolUse": [
  {"hooks": [{"type": "command", "command": "other-a"}, {"type": "command", "command": "other-b"}]},
  {"matcher": "^Bash$", "hooks": [{"type": "command", "command": "mine"}, {"type": "command", "command": "python3 ~/.codex/hooks/jarvis-guard.py", "timeout": 3}]}
]}}
EOF
run
trust_hook
run --trust; rc=$?
check "trust key: group 1, handler 1" bash -c "test $rc = 0 && grep -q 'hooks.json:pre_tool_use:1:1' '$dir/out'"

# 9b. A path through a link is named as Codex names it: $CODEX_HOME/hooks.json, not its target.
sandbox
mkdir -p "$dir/dotfiles"
echo '{"hooks": {"Stop": []}}' >"$dir/dotfiles/hooks.json"
ln -s dotfiles/hooks.json "$h"
run
trust_hook
run --trust; rc=$?
check "trust through a link: the key is the CODEX_HOME path" bash -c "test $rc = 0 && grep -q 'trust: OK' '$dir/out'"

# 9c. No python3 with tomllib: the trust state cannot be read, so --check and --trust fail and say how
#     to fix it; a plain run still succeeds and says it could not verify.
sandbox
run
trust_hook
nopy="$dir/nopy-bin"; mkdir -p "$nopy"
for t in jq cat cp rm mv mkdir chmod cksum cmp diff sed tr dirname readlink mktemp basename stat date sort head cut shasum sha256sum; do
  tp=$(command -v "$t") && ln -s "$tp" "$nopy/$t"
done
printf '#!/bin/sh\nexit 1\n' >"$nopy/python3"; chmod +x "$nopy/python3"
bash_bin=$(command -v bash)
CODEX_HOME="$dir" PATH="$nopy" "$bash_bin" "$apply" --check >"$dir/out" 2>&1; rc=$?
check "no tomllib: --check exit 1" test "$rc" = 1
check "no tomllib: says the trust state could not be verified and how to install Python 3.11+" bash -c "grep -q 'trust: UNVERIFIABLE' '$dir/out' && grep -q 'could not verify' '$dir/out' && grep -q 'Python 3.11' '$dir/out'"
CODEX_HOME="$dir" PATH="$nopy" "$bash_bin" "$apply" --trust >"$dir/out" 2>&1; rc=$?
check "no tomllib: --trust exit 1" test "$rc" = 1
CODEX_HOME="$dir" PATH="$nopy" "$bash_bin" "$apply" >"$dir/out" 2>&1; rc=$?
check "no tomllib: a plain run exits 0 and says it could not verify" bash -c "test $rc = 0 && grep -q 'could not verify' '$dir/out'"
# the same files, with a python that has tomllib: OK (the control)
run --trust; rc=$?
check "no tomllib control: with a tomllib python the same files are OK" test "$rc" = 0

# 9d. A config.toml that does not parse cannot be verified either.
sandbox
run
printf 'this is = not [valid\n' >"$dir/config.toml"
run --check; rc=$?
check "bad TOML: --check exit 1, UNVERIFIABLE" bash -c "test $rc = 1 && grep -q 'trust: UNVERIFIABLE' '$dir/out' && grep -q 'as TOML' '$dir/out'"

# 9e. Golden: the shape of a real hooks.json and config.toml pair (entries of Orca and of this script, the
#     trusted_hash Codex itself stored for the guard's entry on 2026-11-02). The hash does not depend on the
#     path; the key does, so the fixture's key is built from the sandbox.
sandbox
cat >"$h" <<'EOF'
{"hooks": {"PreToolUse": [
  {"hooks": [{"type": "command", "command": ": orca-agent-hook-form=1; /bin/sh \"$HOME/.orca/agent-hooks/codex-hook.sh\" || :", "timeout": 10}]},
  {"matcher": "^Bash$", "hooks": [{"type": "command", "command": "py=/usr/bin/python3; [ -x \"$py\" ] || py=python3; exec \"$py\" -I \"${CODEX_HOME:-$HOME/.codex}/hooks/jarvis-guard.py\" --codex", "timeout": 10, "statusMessage": "Codex guard: checking the command"}]}
]}}
EOF
printf '[hooks.state."%s/hooks.json:pre_tool_use:1:0"]\ntrusted_hash = "sha256:9d92c2ae47506c624a661fb3224e58cde3005ba7cb91b900ca5017fb6950e4b7"\n' "$(cd "$dir" && pwd -P)" >"$dir/config.toml"
run --trust; rc=$?
check "golden: the hash Codex stored for the real entry is the one computed" bash -c "test $rc = 0 && grep -q 'trust: OK' '$dir/out'"
sed -i.bak 's/"timeout": 10, "statusMessage"/"timeout": 11, "statusMessage"/' "$h" && rm -f "$h.bak"
run --trust; rc=$?
check "golden: a changed timeout is another hash" bash -c "test $rc = 1 && grep -q 'trust: UNTRUSTED' '$dir/out'"
# the defaults: no matcher, no timeout (600), no async (false), no status message; the canonical JSON by hand
sandbox
printf '{"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "python3 /x/hooks/jarvis-guard.py"}]}]}}\n' >"$h"
want=$(printf '%s' '{"event_name":"pre_tool_use","hooks":[{"async":false,"command":"python3 /x/hooks/jarvis-guard.py","timeout":600,"type":"command"}]}' | sha256_stdin)
printf '[hooks.state."%s/hooks.json:pre_tool_use:0:0"]\ntrusted_hash = "sha256:%s"\n' "$(cd "$dir" && pwd -P)" "$want" >"$dir/config.toml"
run --trust; rc=$?
check "golden defaults: no matcher, timeout 600, async false, no status message" bash -c "test $rc = 0 && grep -q 'trust: OK' '$dir/out'"

# 9f. A key of the entry that the hash formula does not know may be part of Codex's hash, so no answer is given.
sandbox
printf '{"hooks": {"PreToolUse": [{"matcher": "^Bash$", "hooks": [{"type": "command", "command": "python3 /x/hooks/jarvis-guard.py", "timeout": 10, "futureKey": 1}]}]}}\n' >"$h"
run --trust; rc=$?
check "unknown key: --trust exit 1, UNVERIFIABLE naming the key" bash -c "test $rc = 1 && grep -q 'trust: UNVERIFIABLE' '$dir/out' && grep -q 'futureKey' '$dir/out'"
run --check; rc=$?
check "unknown key: --check exit 1" bash -c "test $rc = 1 && grep -q 'trust: UNVERIFIABLE' '$dir/out'"
sed -i.bak 's/"futureKey": 1/"futureKey": null/' "$h" && rm -f "$h.bak"
run --trust
check "unknown key with a null value counts as absent (not UNVERIFIABLE)" bash -c "! grep -q 'UNVERIFIABLE' '$dir/out'"
# additionalContextLimit is part of the hash when present (canonical JSON by hand)
sandbox
printf '{"hooks": {"PreToolUse": [{"matcher": "^Bash$", "hooks": [{"type": "command", "command": "python3 /x/hooks/jarvis-guard.py", "additionalContextLimit": 5}]}]}}\n' >"$h"
want=$(printf '%s' '{"event_name":"pre_tool_use","hooks":[{"additionalContextLimit":5,"async":false,"command":"python3 /x/hooks/jarvis-guard.py","timeout":600,"type":"command"}],"matcher":"^Bash$"}' | sha256_stdin)
printf '[hooks.state."%s/hooks.json:pre_tool_use:0:0"]\ntrusted_hash = "sha256:%s"\n' "$(cd "$dir" && pwd -P)" "$want" >"$dir/config.toml"
run --trust; rc=$?
check "additionalContextLimit is hashed when present" bash -c "test $rc = 0 && grep -q 'trust: OK' '$dir/out'"
# null-valued matcher and statusMessage are absent for Codex, so for the hash
sandbox
printf '{"hooks": {"PreToolUse": [{"matcher": null, "hooks": [{"type": "command", "command": "python3 /x/hooks/jarvis-guard.py", "statusMessage": null}]}]}}\n' >"$h"
want=$(printf '%s' '{"event_name":"pre_tool_use","hooks":[{"async":false,"command":"python3 /x/hooks/jarvis-guard.py","timeout":600,"type":"command"}]}' | sha256_stdin)
printf '[hooks.state."%s/hooks.json:pre_tool_use:0:0"]\ntrusted_hash = "sha256:%s"\n' "$(cd "$dir" && pwd -P)" "$want" >"$dir/config.toml"
run --trust; rc=$?
check "null matcher and null statusMessage are dropped before hashing" bash -c "test $rc = 0 && grep -q 'trust: OK' '$dir/out'"

# 9g. The key names hooks.json as Codex does: CODEX_HOME made canonical (links, trailing slash), but with
#     CODEX_HOME unset $HOME/.codex/hooks.json exactly as written.
sandbox
run
trust_hook
ln -s "$dir" "$root/link$n"
CODEX_HOME="$root/link$n/" bash "$apply" --trust >"$dir/out" 2>&1; rc=$?
check "key: CODEX_HOME through a link and with a trailing slash is canonical" bash -c "test $rc = 0 && grep -q 'trust: OK - Codex trusts the Jarvis guard entry $(cd "$dir" && pwd -P)/hooks.json:pre_tool_use:0:0' '$dir/out'"
sandbox
mkdir -p "$dir/realhome"; ln -s "$dir/realhome" "$dir/homelink"
HOME="$dir/homelink" env -u CODEX_HOME bash "$apply" >/dev/null 2>&1
trust_hook "$dir/realhome/.codex" "$dir/homelink/.codex"
HOME="$dir/homelink" env -u CODEX_HOME bash "$apply" --trust >"$dir/out" 2>&1; rc=$?
check "key: CODEX_HOME unset keeps \$HOME/.codex unresolved (a linked HOME is not resolved)" bash -c "test $rc = 0 && grep -q 'trust: OK - Codex trusts the Jarvis guard entry $dir/homelink/.codex/hooks.json' '$dir/out'"
rm -f "$dir/realhome/.codex/config.toml"; trust_hook "$dir/realhome/.codex" "$(cd "$dir/realhome/.codex" && pwd -P)"
HOME="$dir/homelink" env -u CODEX_HOME bash "$apply" --trust >"$dir/out" 2>&1; rc=$?
check "key: CODEX_HOME unset, a state entry under the resolved path does not count" bash -c "test $rc = 1 && grep -q 'trust: UNTRUSTED' '$dir/out'"

# 9h. [features] hooks = false (or the legacy codex_hooks = false) turns every hook off.
for feat in hooks codex_hooks; do
  sandbox
  run
  trust_hook
  printf '[features]\n%s = false\n' "$feat" >>"$dir/config.toml"
  run --check; rc=$?
  check "features $feat = false: DISABLED, exit 1" bash -c "test $rc = 1 && grep -q 'trust: DISABLED' '$dir/out'"
  check "features $feat = false: the fix names the key" bash -c "grep -q 'fix: remove $feat = false from \\[features\\]' '$dir/out'"
done
sandbox
run
trust_hook
printf '[features]\nhooks = true\n' >>"$dir/config.toml"
run --trust; rc=$?
check "features hooks = true: still OK" test "$rc" = 0

# 9i. A fresh install while Claude Code's switch is on starts Codex's off, and says so.
sandbox
crd="$dir/claude"; mkdir -p "$crd"
echo '{"version": 1, "env": {"JARVIS_REQUIRE_AGENT_IDENTITY": "1"}, "env_created": false}' >"$crd/agent-identity.require.json"
CLAUDE_CONFIG_DIR="$crd" run; rc=$?
check "switch warning: a fresh install with Claude Code's switch on warns that Codex starts off" bash -c "test $rc = 0 && grep -q 'WARN: Claude Code.s agent-identity switch is on' '$dir/out' && grep -q 'Codex GitHub writes are not covered' '$dir/out' && grep -q -- '--require-identity' '$dir/out'"
CLAUDE_CONFIG_DIR="$crd" run
check "switch warning: not again once the entry exists" bash -c "! grep -q 'WARN' '$dir/out'"
sandbox
crd="$dir/claude"; mkdir -p "$crd"
echo '{"version": 1, "env": {"JARVIS_REQUIRE_AGENT_IDENTITY": "1"}}' >"$crd/agent-identity.require.json"
CLAUDE_CONFIG_DIR="$crd" run --require-identity
check "switch warning: none when the install turns the switch on" bash -c "! grep -q 'WARN' '$dir/out'"
sandbox
crd="$dir/claude"; mkdir -p "$crd"
echo '{"version": 1, "env": {"JARVIS_REQUIRE_AGENT_IDENTITY": "0"}}' >"$crd/agent-identity.require.json"
CLAUDE_CONFIG_DIR="$crd" run
check "switch warning: none when the record does not say 1" bash -c "! grep -q 'WARN' '$dir/out'"
sandbox
run
check "switch warning: none without a record" bash -c "! grep -q 'WARN' '$dir/out'"
sandbox
crd="$dir/claude"; mkdir -p "$crd"
echo '{"version": 1, "env": {"JARVIS_REQUIRE_AGENT_IDENTITY": "1"}}' >"$crd/agent-identity.require.json"
CLAUDE_CONFIG_DIR="$crd" run --check
check "switch warning: --check on a fresh home says it too" grep -q 'WARN: Claude Code.s agent-identity switch is on' "$dir/out"

# 9j. Claude Code's switch is on through its settings.json or its environment, with no record: a fresh install warns too.
sandbox
crd="$dir/claude"; mkdir -p "$crd"
echo '{"env": {"JARVIS_REQUIRE_AGENT_IDENTITY": "1"}}' >"$crd/settings.json"
CLAUDE_CONFIG_DIR="$crd" run
check "switch warning: Claude Code's switch on in settings.json (no record) warns" bash -c "grep -q 'WARN: Claude Code.s agent-identity switch is on (via $crd/settings.json)' '$dir/out'"
sandbox
JARVIS_REQUIRE_AGENT_IDENTITY=1 run
check "switch warning: Claude Code's switch on in the process environment warns" bash -c "grep -q 'WARN: Claude Code.s agent-identity switch is on (via the process environment)' '$dir/out'"
sandbox
crd="$dir/claude"; mkdir -p "$crd"
echo '{"env": {"JARVIS_REQUIRE_AGENT_IDENTITY": "0"}}' >"$crd/settings.json"
CLAUDE_CONFIG_DIR="$crd" JARVIS_REQUIRE_AGENT_IDENTITY=0 run
check "switch warning: none when settings.json and the environment say 0" bash -c "! grep -q 'WARN' '$dir/out'"
sandbox
crd="$dir/claude"; mkdir -p "$crd"
printf '{ not json' >"$crd/agent-identity.require.json"
CLAUDE_CONFIG_DIR="$crd" run
check "switch warning: a record that cannot be read counts as on (the guard fails closed)" bash -c "grep -q 'WARN: Claude Code.s agent-identity switch is on' '$dir/out'"

# 9k. --require-identity as a whole word anywhere after --codex is the switch, as the guard reads its arguments.
sandbox
cat >"$h" <<'EOF2'
{"hooks": {"PreToolUse": [{"matcher": "^Bash$", "hooks": [{"type": "command", "command": "python3 ~/.codex/hooks/jarvis-guard.py --codex --require-identity --extra", "timeout": 3}]}]}}
EOF2
run; rc=$?
check "switch word before another argument: a plain re-run keeps the switch on" bash -c "test $rc = 0 && jq -e '$sw_on' '$h' >/dev/null && grep -q 'agent-identity switch is on' '$dir/out'"
sandbox
cat >"$h" <<'EOF2'
{"hooks": {"PreToolUse": [{"matcher": "^Bash$", "hooks": [{"type": "command", "command": "python3 ~/.codex/hooks/jarvis-guard.py --codex --not--require-identity", "timeout": 3}]}]}}
EOF2
run
check "a word that only contains --require-identity is not the switch" bash -c "grep -q 'agent-identity switch is off' '$dir/out'"
sandbox
cat >"$h" <<'EOF2'
{"hooks": {"PreToolUse": [{"matcher": "^Bash$", "hooks": [{"type": "command", "command": "python3 ~/.codex/hooks/jarvis-guard.py --require-identity", "timeout": 3}]}]}}
EOF2
run
check "--require-identity before --codex is not the switch for the hook" bash -c "grep -q 'agent-identity switch is off' '$dir/out'"

# --- the installed hook, as Codex runs it --------------------------------------

sandbox
hookhome=$dir
run
cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$hookhome/hooks.json")
# the same hook as `apply-codex-guard.sh --require-identity` writes it
sandbox
run --require-identity
cmd_on=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$h")

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
probe deny 'gh release create v1.0.0 --notes-from-tag' "$feat" "$cp_pat"

echo "== ordinary work: no decision"
probe none 'git status' "$feat"
probe none 'ls -la' "$feat"
probe none 'git push origin feat/x' "$feat"
probe none 'gh pr view 12 --json state' "$feat"
probe none 'echo "git push --force is refused"' "$feat"

codex_fixture() { # dir: a CODEX_HOME whose record, config.toml block and gitconfig all agree
  local d=$1 blk sha
  mkdir -p "$d"
  blk=$'# >>> jarvis agent-identity: test\n[shell_environment_policy]\nset = { A = "1" }\n# <<< jarvis agent-identity\n'
  printf 'model = "x"\n\n%s' "$blk" >"$d/config.toml"
  printf '[credential]\n\thelper =\n' >"$d/agent-identity.gitconfig"
  sha=$("${py:-/usr/bin/python3}" -I -c 'import sys,hashlib; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$d/agent-identity.gitconfig")
  jq -n --arg block "$blk" --arg cfg "$d/config.toml" --arg gc "$d/agent-identity.gitconfig" --arg sha "$sha" \
    '{version: 1, set: {GH_CONFIG_DIR: "/agent/gh", JARVIS_AGENT_IDENTITY: "some-agent", GH_TOKEN: ""}, gitconfig: $gc, gitconfig_sha256: $sha, block: $block, prefix: "\n", config: $cfg}' >"$d/agent-identity.applied.json"
  CODEX_BLOCK=$blk
}
echo "== the Codex agent identity: applied when the record is in CODEX_HOME, which the hook can see (its policy env it cannot)"
# A second CODEX_HOME holding the same hook and a record; the earlier probes ran without one.
idhome="$root/id-home"; mkdir -p "$idhome/hooks"; # (IDENTITY_GUARD, test-only, points these cases at another copy of the guard, e.g. the old one, to show they fail)
cp "${IDENTITY_GUARD:-$hookhome/hooks/jarvis-guard.py}" "$idhome/hooks/jarvis-guard.py"
codex_fixture "$idhome"
hookhome_orig=$hookhome; saved_home=$hookhome; hookhome=$idhome
id_pat='Codex guard: *writes to GitHub*'
probe deny 'GH_TOKEN=x gh pr create --title t' "$feat" "$id_pat"
probe deny 'GIT_CONFIG_GLOBAL=/x git push origin feat/x' "$feat" "$id_pat"
probe deny 'GIT_CONFIG_SYSTEM=/x git push origin feat/x' "$feat" "$id_pat"
probe none 'git push origin feat/x' "$feat"
probe none 'gh pr create --title t' "$feat"
probe none 'gh pr view 12 --json state' "$feat"
GH_TOKEN=x probe none 'gh pr create --title t' "$feat"
export JARVIS_REQUIRE_AGENT_IDENTITY=1
probe none 'gh pr create --title t' "$feat"
unset JARVIS_REQUIRE_AGENT_IDENTITY
echo '{ not json' >"$idhome/agent-identity.applied.json"
probe deny 'gh pr create --title t' "$feat" 'Codex guard: *record*is unreadable*apply-agent-identity.sh --check --codex*'
probe deny 'git push origin feat/x' "$feat" "$id_pat"
probe none 'gh pr view 12 --json state' "$feat"
rm -f "$idhome/agent-identity.applied.json"
probe none 'GH_TOKEN=x gh pr create --title t' "$feat"
probe none 'git push origin feat/x' "$feat"
# The environment variable is Claude Code's switch: a Codex hook does not read it.
export JARVIS_REQUIRE_AGENT_IDENTITY=1
probe none 'gh pr create --title t' "$feat"
probe none 'git push origin feat/x' "$feat"
unset JARVIS_REQUIRE_AGENT_IDENTITY
# The switch is the argument the installed command ends with.
cmd_plain=$cmd; cmd=$cmd_on
probe deny 'gh pr create --title t' "$feat" 'Codex guard: *need this machine*agent-identity switch*apply-agent-identity.sh --check --codex*apply-agent-identity.sh --unrequire*'
probe deny 'git push origin feat/x' "$feat" 'Codex guard: *need this machine*'
probe none 'gh pr view 12 --json state' "$feat"
probe none 'git status' "$feat"
# a marker inherited from a Claude Code session is not a Codex identity
JARVIS_AGENT_IDENTITY=some-agent probe deny 'gh pr create --title t' "$feat" 'Codex guard: *need this machine*'
# with a sound record, the switch changes nothing
codex_fixture "$idhome"
probe none 'gh pr create --title t' "$feat"
probe none 'git push origin feat/x' "$feat"
# with a record that fails, the refusal names the switch and the way back too
echo '{ not json' >"$idhome/agent-identity.applied.json"
probe deny 'gh pr create --title t' "$feat" 'Codex guard: *record*is unreadable*agent-identity switch*apply-agent-identity.sh --check --codex*apply-agent-identity.sh --unrequire*'
probe none 'gh pr view 12 --json state' "$feat"
cmd=$cmd_plain
codex_fixture "$idhome"
hookhome=$saved_home

echo "== the record alone is not applied: what it lists must still be there"
stale_case() { # name, mutation (run in the fixture dir)
  local d="$root/cx-$1"
  mkdir -p "$d/hooks"; cp "${IDENTITY_GUARD:-$saved_home/hooks/jarvis-guard.py}" "$d/hooks/jarvis-guard.py"
  codex_fixture "$d"
  ( cd "$d" && eval "$2" )
  hookhome=$d
  probe deny 'gh pr create --title t' "$feat" 'Codex guard: *--check --codex*'
  probe deny 'git push origin feat/x' "$feat" 'Codex guard: *--check --codex*'
  probe none 'gh pr view 12 --json state' "$feat"
}
saved_home=$hookhome_orig
stale_case "block-gone" 'printf "model = \"x\"\n" >config.toml'
stale_case "block-edited" 'sed "s/A = \"1\"/A = \"2\"/" config.toml >c.new && mv c.new config.toml'
stale_case "block-twice" 'printf "%s" "$CODEX_BLOCK" >>config.toml'
stale_case "key-after-marker" 'printf "extra = 1\n" >>config.toml'
stale_case "comment-then-key-after-marker" 'printf "\n# note\nextra = 1\n" >>config.toml'
stale_case "gitconfig-gone" 'rm agent-identity.gitconfig'
stale_case "gitconfig-edited" 'printf "# x\n" >>agent-identity.gitconfig'
stale_case "config-gone" 'rm config.toml'
cmd_plain=$cmd; cmd=$cmd_on
hookhome="$root/cx-gitconfig-gone"
probe deny 'gh pr create --title t' "$feat" 'Codex guard: *--check --codex*agent-identity switch*--unrequire*'
probe none 'gh pr view 12 --json state' "$feat"
cmd=$cmd_plain
hookhome=$hookhome_orig
# the same files all agreeing: applied, and nothing is refused
mkdir -p "$root/cx-ok/hooks"; cp "${IDENTITY_GUARD:-$hookhome_orig/hooks/jarvis-guard.py}" "$root/cx-ok/hooks/jarvis-guard.py"
codex_fixture "$root/cx-ok"; hookhome="$root/cx-ok"
probe none 'gh pr create --title t' "$feat"
probe deny 'GH_TOKEN=x gh pr create --title t' "$feat" 'Codex guard: *writes to GitHub*'
# a blank line, a comment and then a table after the block is fine
mkdir -p "$root/cx-table/hooks"; cp "${IDENTITY_GUARD:-$hookhome_orig/hooks/jarvis-guard.py}" "$root/cx-table/hooks/jarvis-guard.py"
codex_fixture "$root/cx-table"; printf '\n# note\n[other]\nextra = 1\n' >>"$root/cx-table/config.toml"; hookhome="$root/cx-table"
probe none 'gh pr create --title t' "$feat"
hookhome=$hookhome_orig

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
