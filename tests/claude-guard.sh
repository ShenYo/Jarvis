#!/usr/bin/env bash
# Tests for scripts/apply-claude-guard.sh, each in its own sandbox
# CLAUDE_CONFIG_DIR, so the real ~/.claude is never read or written.
#
# Sandboxes are left under the printed directory rather than removed: the
# guard this script installs refuses recursive deletion, and a test that has
# to step around its own subject is not testing it.
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
apply="$repo/scripts/apply-claude-guard.sh"
guard="$repo/.agents/claude-guard/guard.json"
root=$(mktemp -d "${TMPDIR:-/tmp}/claude-guard-test.XXXXXX")
echo "sandboxes: $root"

fails=0
n=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { # name, then a command that must succeed
  local name=$1; shift
  if "$@"; then ok "$name"; else fail "$name"; fi
}
sandbox() { n=$((n + 1)); dir="$root/$n"; mkdir -p "$dir"; s="$dir/settings.json"; r="$dir/claude-guard.applied.json"; }
run() { CLAUDE_CONFIG_DIR="$dir" bash "$apply" "$@" >"$dir/out" 2>&1; }
q() { jq -e "$1" "$s" >/dev/null; }
q_file() { jq -e "$1" "$2" >/dev/null; }

first_deny=$(jq -r '.permissions.deny[0]' "$guard")

# 1. No settings file: the guard is written whole, and the record kept.
sandbox
run; rc=$?
check "fresh: exit 0" test "$rc" = 0
check "fresh: every deny rule present" q "(.permissions.deny | sort) == ($(jq -c '.permissions.deny | sort' "$guard"))"
check "fresh: bypass mode disabled" q '.permissions.disableBypassPermissionsMode == "disable"'
check "fresh: record equals guard" cmp -s "$guard" "$r"
check "fresh: hook installed" cmp -s "$repo/.agents/claude-guard/bash-guard.py" "$dir/hooks/claude-guard.py"
check "fresh: hook entry fails closed" q '.hooks.PreToolUse[-1].matcher == "Bash" and .hooks.PreToolUse[-1].hooks[0].onFailure == "block"'

# 2. Existing settings: everything the person wrote survives.
sandbox
cat >"$s" <<'EOF'
{
  "model": "opus",
  "skipDangerousModePermissionPrompt": true,
  "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "true"}]}],
            "PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": "other-tool"}]}]},
  "permissions": {"defaultMode": "auto", "deny": ["Bash(user-rule *)"], "allow": ["Bash(npm test)"]},
  "autoMode": {"environment": ["Source control: example"]}
}
EOF
run
check "keep: unrelated keys untouched" q '.model == "opus" and .hooks.Stop[0].hooks[0].command == "true" and .permissions.defaultMode == "auto"'
check "keep: another tool's PreToolUse hook stays first" q '.hooks.PreToolUse[0].hooks[0].command == "other-tool" and (.hooks.PreToolUse | length) == 2'
check "keep: person's deny and allow rules stay" q '(.permissions.deny | index("Bash(user-rule *)")) != null and .permissions.allow == ["Bash(npm test)"]'
check "keep: person's rule stays ahead of the guard's" q '.permissions.deny[0] == "Bash(user-rule *)"'
check "keep: autoMode environment untouched" q '.autoMode.environment == ["Source control: example"]'
check "keep: \$defaults leads hard_deny" q '.autoMode.hard_deny[0] == "$defaults"'
check "keep: unset key removed" q 'has("skipDangerousModePermissionPrompt") | not'
check "keep: backup written" test -f "$s.guard-backup"

# 3. A second run changes nothing, and --check agrees.
cp "$s" "$dir/before"
run; rc=$?
check "idempotent: exit 0" test "$rc" = 0
check "idempotent: file unchanged" cmp -s "$s" "$dir/before"
run --check; rc=$?
check "idempotent: --check exit 0" test "$rc" = 0

# 3b. A hook edited in place is drift, and a run puts it back.
echo "# edited" >>"$dir/hooks/claude-guard.py"
run --check; rc=$?
check "hook drift: --check exit 1" test "$rc" = 1
run
check "hook drift: run restores the hook" cmp -s "$repo/.agents/claude-guard/bash-guard.py" "$dir/hooks/claude-guard.py"
check "hook drift: settings untouched" cmp -s "$s" "$dir/before"

# 4. A rule the previous guard added, and this one no longer has, is retired.
#    A person's rule that happens to look similar is not.
sandbox
jq '.permissions.deny += ["Bash(retired *)"]' "$guard" >"$r"
jq -n --slurpfile g "$guard" '{permissions: {deny: (["Bash(mine *)"] + $g[0].permissions.deny + ["Bash(retired *)"])}}' >"$s"
run
check "retire: dropped rule removed" q '(.permissions.deny | index("Bash(retired *)")) == null'
check "retire: person's rule kept" q '(.permissions.deny | index("Bash(mine *)")) != null'

# 5. A rule the person and the guard share appears once.
sandbox
printf '{"permissions": {"deny": [%s]}}\n' "$(jq -n --arg r "$first_deny" '$r')" >"$s"
run
check "dedupe: shared rule appears once" q "[.permissions.deny[] | select(. == $(jq -n --arg r "$first_deny" '$r'))] | length == 1"

# 6. The person's own classifier rules stay, and "$defaults" is spliced once,
#    first, wherever the person had put it.
sandbox
echo '{"autoMode": {"hard_deny": ["Never touch prod", "$defaults"]}}' >"$s"
run
check "defaults: person's hard_deny rule kept" q '(.autoMode.hard_deny | index("Never touch prod")) != null'
check "defaults: \$defaults first and once" q '.autoMode.hard_deny[0] == "$defaults" and ([.autoMode.hard_deny[] | select(. == "$defaults")] | length == 1)'

# 7. A settings file that is not JSON is refused and left alone.
sandbox
printf '{ "model": ' >"$s"
cp "$s" "$dir/before"
run; rc=$?
check "invalid: exit 2" test "$rc" = 2
check "invalid: file unchanged" cmp -s "$s" "$dir/before"
check "invalid: no record written" test ! -e "$r"

# 8. --check on settings without the guard reports and changes nothing.
sandbox
echo '{"model": "opus"}' >"$s"
cp "$s" "$dir/before"
run --check; rc=$?
check "check: exit 1 on drift" test "$rc" = 1
check "check: file unchanged" cmp -s "$s" "$dir/before"
check "check: no record written" test ! -e "$r"

# 9. A settings file that is a link keeps being a link; its target is updated.
sandbox
mkdir -p "$dir/dotfiles"
echo '{"model": "opus"}' >"$dir/dotfiles/settings.json"
ln -s dotfiles/settings.json "$s"
run
check "link: still a link" test -L "$s"
check "link: target carries the guard" q_file '.permissions.disableBypassPermissionsMode == "disable" and .model == "opus"' "$dir/dotfiles/settings.json"

echo
if [ "$fails" -gt 0 ]; then echo "$fails failure(s)"; exit 1; fi
echo "all passed"
