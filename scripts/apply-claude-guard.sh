#!/usr/bin/env bash
# Merge the personal Claude Code guard into ~/.claude/settings.json.
#
# The guard is .agents/claude-guard/guard.json: permission deny and ask rules,
# auto-mode classifier rules, a PreToolUse hook entry, and settings it sets or
# removes. The hook itself, bash-guard.py, is installed as
# ~/.claude/hooks/claude-guard.py. Both are copied, never linked, so a Claude
# session keeps its guard on a machine where this repository is absent or
# broken.
#
# The settings file belongs to the person, not to this script. Rules the
# person added stay. The guard's own rules are tracked in a record of what was
# applied last (~/.claude/claude-guard.applied.json), which is how a rule
# retired from guard.json is removed on the next run instead of lingering.
#
# Usage: apply-claude-guard.sh [--check]
#   --check  change nothing; exit 0 when the settings already carry the guard,
#            1 when applying would change them, 2 on error.
set -euo pipefail

usage() { sed -n '/^# Usage:/,/2 on error/s/^# \{0,1\}//p' "$0"; }

check=0
case "${1-}" in
  "") ;;
  --check) check=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

die() { printf 'apply-claude-guard: %s\n' "$*" >&2; exit 2; }

command -v jq >/dev/null || die "jq is required"

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
guard="$here/.agents/claude-guard/guard.json"
claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
settings="$claude_home/settings.json"
record="$claude_home/claude-guard.applied.json"
hook_src="$here/.agents/claude-guard/bash-guard.py"
hook_dst="$claude_home/hooks/claude-guard.py"

jq -e 'type == "object"' "$guard" >/dev/null 2>&1 || die "$guard is not a JSON object"
[ -f "$hook_src" ] || die "$hook_src is missing"

# Write through a link, so a settings file kept by a dotfiles manager stays
# where that manager put it.
if [ -L "$settings" ]; then
  target=$(readlink "$settings")
  case "$target" in /*) ;; *) target="$(dirname "$settings")/$target" ;; esac
  settings="$target"
fi

if [ -e "$settings" ]; then
  jq -e 'type == "object"' "$settings" >/dev/null 2>&1 ||
    die "$settings is not a JSON object; fix it by hand first, nothing was changed"
  current=$(cat "$settings")
else
  current='{}'
fi

if [ -e "$record" ]; then
  jq -e 'type == "object"' "$record" >/dev/null 2>&1 ||
    die "$record is not a JSON object; nothing was changed"
  previous=$(cat "$record")
else
  previous='{}'
fi

# For each list the guard manages: drop what the previous guard added, keep
# everything else in its order, then append the guard's entries. "$defaults"
# leads an autoMode list, where the classifier splices in its built-in rules.
merged=$(jq -n \
  --argjson cur "$current" --argjson prev "$previous" --slurpfile g "$guard" '
  $g[0] as $new |
  def lists: [["permissions","deny"], ["permissions","ask"],
              ["autoMode","hard_deny"], ["autoMode","soft_deny"],
              ["hooks","PreToolUse"]];
  def merge_list($p):
    (($cur | getpath($p)) // []) as $have |
    (($prev | getpath($p)) // []) as $old |
    (($new | getpath($p)) // []) as $want |
    ($have | map(select(. as $e | ($old | index([$e])) == null and ($want | index([$e])) == null))) as $kept |
    if ($want | index(["$defaults"])) != null
    then ["$defaults"] + ($kept | map(select(. != "$defaults"))) + ($want | map(select(. != "$defaults")))
    else $kept + $want end;
  reduce lists[] as $p ($cur;
    if ($new | getpath($p)) == null then . else setpath($p; merge_list($p)) end) |
  if $new.permissions.disableBypassPermissionsMode == null then .
  else .permissions.disableBypassPermissionsMode = $new.permissions.disableBypassPermissionsMode end |
  reduce (($new["$unset"] // [])[]) as $k (.; del(.[$k]))')

settings_same=0
[ "$(jq -S . <<<"$current")" = "$(jq -S . <<<"$merged")" ] && settings_same=1
hook_same=0
cmp -s "$hook_src" "$hook_dst" && hook_same=1

if [ "$check" = 1 ]; then
  [ "$settings_same" = 1 ] && [ "$hook_same" = 1 ] && {
    echo "apply-claude-guard: $settings and $hook_dst already carry the guard"
    exit 0
  }
  if [ "$settings_same" = 0 ]; then
    echo "apply-claude-guard: $settings differs from the guard:"
    diff <(jq -S . <<<"$current") <(jq -S . <<<"$merged") || true
  fi
  [ "$hook_same" = 0 ] && echo "apply-claude-guard: $hook_dst differs from $hook_src"
  exit 1
fi

# The hook goes in before the settings that name it: a hook entry whose file
# is missing blocks every Bash call, because it fails closed.
if [ "$hook_same" = 0 ]; then
  mkdir -p "$(dirname "$hook_dst")"
  tmp=$(mktemp "$hook_dst.XXXXXX")
  cp "$hook_src" "$tmp"
  mv "$tmp" "$hook_dst"
  echo "apply-claude-guard: wrote $hook_dst"
fi

if [ "$settings_same" = 1 ]; then
  echo "apply-claude-guard: $settings already carries the guard"
  cmp -s "$guard" "$record" 2>/dev/null || cp "$guard" "$record"
  exit 0
fi

mkdir -p "$(dirname "$settings")"
[ -e "$settings" ] && cp -p "$settings" "$settings.guard-backup"
tmp=$(mktemp "$settings.XXXXXX")
jq . <<<"$merged" > "$tmp"
mv "$tmp" "$settings"
cp "$guard" "$record"
echo "apply-claude-guard: wrote $settings (previous copy: $settings.guard-backup)"
