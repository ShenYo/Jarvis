#!/usr/bin/env bash
# Merge the personal Claude Code guard into ~/.claude/settings.json.
#
# The guard is .agents/claude-guard/guard.json: permission deny and ask rules,
# auto-mode classifier rules, and settings it sets or removes. It is copied
# into the settings file, never linked, so a Claude session keeps its guard on
# a machine where this repository is absent or broken.
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

usage() { sed -n '14,16s/^# \{0,1\}//p' "$0"; }

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

jq -e 'type == "object"' "$guard" >/dev/null 2>&1 || die "$guard is not a JSON object"

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
              ["autoMode","hard_deny"], ["autoMode","soft_deny"]];
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

if [ "$(jq -S . <<<"$current")" = "$(jq -S . <<<"$merged")" ]; then
  echo "apply-claude-guard: $settings already carries the guard"
  if [ "$check" = 0 ] && ! cmp -s "$guard" "$record" 2>/dev/null; then
    cp "$guard" "$record"
  fi
  exit 0
fi

if [ "$check" = 1 ]; then
  echo "apply-claude-guard: $settings differs from the guard:"
  diff <(jq -S . <<<"$current") <(jq -S . <<<"$merged") || true
  exit 1
fi

mkdir -p "$(dirname "$settings")"
[ -e "$settings" ] && cp -p "$settings" "$settings.guard-backup"
tmp=$(mktemp "$settings.XXXXXX")
jq . <<<"$merged" > "$tmp"
mv "$tmp" "$settings"
cp "$guard" "$record"
echo "apply-claude-guard: wrote $settings (previous copy: $settings.guard-backup)"
