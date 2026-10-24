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
# A copy of the repository whose guard.json is the real one passed through a
# jq filter: how a test stands in for a later revision of the guard.
alt_guard() {
  local alt="$root/alt-$n"
  mkdir -p "$alt/scripts" "$alt/.agents/claude-guard"
  cp "$apply" "$alt/scripts/"
  jq "$1" "$guard" >"$alt/.agents/claude-guard/guard.json"
  echo "$alt/scripts/apply-claude-guard.sh"
}
run_with() { local script=$1; shift; CLAUDE_CONFIG_DIR="$dir" bash "$script" "$@" >"$dir/out" 2>&1; }
snapshot() { # every file the script could write; not the test's own output
  (cd "$dir" && find . \( -type f -o -type l \) ! -name out ! -name 'snap.*' | sort |
    while read -r f; do printf '%s ' "$f"; cksum <"$f"; done)
}

first_deny=$(jq -r '.permissions.deny[0]' "$guard")

# 1. No settings file: the guard is written whole, and the record kept.
sandbox
run; rc=$?
check "fresh: exit 0" test "$rc" = 0
check "fresh: every deny rule present" q "(.permissions.deny | sort) == ($(jq -c '.permissions.deny | sort' "$guard"))"
check "fresh: bypass mode disabled" q '.permissions.disableBypassPermissionsMode == "disable"'
check "fresh: record lists the guard's deny rules as its own" q_file "(.owned[\"permissions.deny\"] | sort) == ($(jq -c '.permissions.deny | sort' "$guard"))" "$r"

# 2. Existing settings: everything the person wrote survives.
sandbox
cat >"$s" <<'EOF'
{
  "model": "opus",
  "skipDangerousModePermissionPrompt": true,
  "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "true"}]}]},
  "permissions": {"defaultMode": "auto", "deny": ["Bash(user-rule *)"], "allow": ["Bash(npm test)"]},
  "autoMode": {"environment": ["Source control: example"]}
}
EOF
run
check "keep: unrelated keys untouched" q '.model == "opus" and .hooks.Stop[0].hooks[0].command == "true" and .permissions.defaultMode == "auto"'
check "keep: person's deny and allow rules stay" q '(.permissions.deny | index("Bash(user-rule *)")) != null and .permissions.allow == ["Bash(npm test)"]'
check "keep: person's rule stays ahead of the guard's" q '.permissions.deny[0] == "Bash(user-rule *)"'
check "keep: autoMode environment untouched" q '.autoMode.environment == ["Source control: example"]'
check "keep: \$defaults leads hard_deny" q '.autoMode.hard_deny[0] == "$defaults"'
check "keep: unset key removed" q 'has("skipDangerousModePermissionPrompt") | not'
check "keep: backup written" test -f "$s.guard-backup"

# 3. A second run changes nothing, and --check agrees and writes nothing.
cp "$s" "$dir/before"
run; rc=$?
check "idempotent: exit 0" test "$rc" = 0
check "idempotent: file unchanged" cmp -s "$s" "$dir/before"
snapshot >"$dir/snap.before"
run --check; rc=$?
snapshot >"$dir/snap.after"
check "idempotent: --check exit 0" test "$rc" = 0
check "idempotent: --check touches no file" cmp -s "$dir/snap.before" "$dir/snap.after"
cp "$guard" "$r"  # an old-format record: --check must not upgrade it
snapshot >"$dir/snap.before"
run --check
snapshot >"$dir/snap.after"
check "idempotent: --check leaves an old record alone" cmp -s "$dir/snap.before" "$dir/snap.after"
run
check "idempotent: a run upgrades the old record" q_file '.version == 2' "$r"

# 4. A rule the previous guard added, and this one no longer has, is retired.
#    A person's rule that happens to look similar is not.
sandbox
jq '.permissions.deny += ["Bash(retired *)"]' "$guard" >"$r"
jq -n --slurpfile g "$guard" '{permissions: {deny: (["Bash(mine *)"] + $g[0].permissions.deny + ["Bash(retired *)"])}}' >"$s"
run
check "retire: dropped rule removed" q '(.permissions.deny | index("Bash(retired *)")) == null'
check "retire: person's rule kept" q '(.permissions.deny | index("Bash(mine *)")) != null'

# 4b. A rule the person already had is theirs, even when the guard has it
#     too: a later guard that drops it leaves it in place.
sandbox
printf '{"permissions": {"deny": [%s, "Bash(mine *)"]}}\n' "$(jq -n --arg r "$first_deny" '$r')" >"$s"
run
later=$(alt_guard ".permissions.deny |= map(select(. != $(jq -n --arg r "$first_deny" '$r')))")
run_with "$later"
check "ownership: person's copy of a retired guard rule kept" q "(.permissions.deny | index($(jq -n --arg r "$first_deny" '$r'))) != null"
second_deny=$(jq -r '.permissions.deny[1]' "$guard")
later=$(alt_guard ".permissions.deny |= map(select(. != $(jq -n --arg r "$second_deny" '$r')))")
run_with "$later"
check "ownership: the guard's own copy retired" q "(.permissions.deny | index($(jq -n --arg r "$second_deny" '$r'))) == null"

# 4c. A list the guard stops managing altogether takes the guard's entries
#     with it, and leaves the person's.
sandbox
echo '{"autoMode": {"soft_deny": ["$defaults", "Never deploy on Fridays"]}}' >"$s"
run
later=$(alt_guard 'del(.autoMode.soft_deny)')
run_with "$later"
check "dropped list: guard's soft_deny rules retired" q '[.autoMode.soft_deny[] | select(startswith("Human-Review Checkpoint"))] | length == 0'
check "dropped list: person's soft_deny rule kept" q '(.autoMode.soft_deny | index("Never deploy on Fridays")) != null'

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

# 10. A chain of links is followed to its end; every link stays a link.
sandbox
mkdir -p "$dir/dotfiles" "$dir/stow"
echo '{"model": "opus"}' >"$dir/dotfiles/settings.json"
ln -s ../dotfiles/settings.json "$dir/stow/settings.json"
ln -s stow/settings.json "$s"
run
check "chain: both links still links" test -L "$s" -a -L "$dir/stow/settings.json"
check "chain: final target carries the guard" q_file '.permissions.disableBypassPermissionsMode == "disable"' "$dir/dotfiles/settings.json"

echo
if [ "$fails" -gt 0 ]; then echo "$fails failure(s)"; exit 1; fi
echo "all passed"
