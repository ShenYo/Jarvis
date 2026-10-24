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
# person wrote stay, including one that happens to equal a guard rule. The
# record ~/.claude/claude-guard.applied.json lists the entries the guard
# itself added, which is how a rule retired from guard.json, or a whole list
# it stops managing, leaves the settings on the next run instead of lingering.
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

# Write through links, to the end of the chain, so a settings file kept by a
# dotfiles manager stays where that manager put it.
hops=0
while [ -L "$settings" ]; do
  hops=$((hops + 1))
  [ "$hops" -le 40 ] || die "$settings: too many levels of links"
  target=$(readlink "$settings")
  case "$target" in /*) ;; *) target="$(dirname "$settings")/$target" ;; esac
  settings="$target"
done

if [ -e "$settings" ]; then
  jq -e 'type == "object"' "$settings" >/dev/null 2>&1 ||
    die "$settings is not a JSON object; fix it by hand first, nothing was changed"
  current=$(cat "$settings")
else
  current='{}'
fi
read_sum=$(cksum <"$settings" 2>/dev/null || echo absent)

if [ -e "$record" ]; then
  jq -e 'type == "object"' "$record" >/dev/null 2>&1 ||
    die "$record is not a JSON object; nothing was changed"
  previous=$(cat "$record")
else
  previous='{}'
fi

# For each list the guard manages, whether or not this revision still has it:
#   retire  entries the previous run added that the guard no longer has
#   keep    everything else already there, in its order
#   append  the guard's entries not already present
# An entry counts as the guard's only when the guard added it: one the person
# already had stays theirs, and is never retired. "$defaults" leads an
# autoMode list, where the classifier splices in its built-in rules.
#
# A record from before ownership was tracked is a copy of the guard it
# applied; every entry in it counts as the guard's.
result=$(jq -n \
  --argjson cur "$current" --argjson prev "$previous" --slurpfile g "$guard" '
  $g[0] as $new |
  def lists: [["permissions","deny"], ["permissions","ask"],
              ["autoMode","hard_deny"], ["autoMode","soft_deny"],
              ["hooks","PreToolUse"]];
  def has_e($a; $e): ($a | index([$e])) != null;
  def owned_before($p):
    if ($prev | has("owned")) then ($prev.owned[$p | join(".")] // [])
    else (($prev | getpath($p)) // []) end;
  def step($p):
    (($cur | getpath($p)) // []) as $have |
    owned_before($p) as $old |
    (($new | getpath($p)) // []) as $want |
    ($old | map(select(. as $e | has_e($want; $e) | not))) as $retire |
    ($have | map(select(. as $e | (has_e($retire; $e) or has_e($want; $e)) | not))) as $kept |
    ($want | map(select(. != "$defaults" and (. as $e | (has_e($have; $e) | not) or has_e($old; $e))))) as $owned |
    { list: (if has_e($want; "$defaults")
             then ["$defaults"] + ($kept | map(select(. != "$defaults"))) + ($want | map(select(. != "$defaults")))
             else $kept + $want end),
      owned: $owned,
      either: (($old + $owned) | unique),
      touched: (($have | length) > 0 or ($want | length) > 0) };
  reduce lists[] as $p ({settings: $cur, owned: {}, either: {}};
    step($p) as $s |
    if $s.touched
    then .settings |= setpath($p; $s.list) | .owned[$p | join(".")] = $s.owned
         | .either[$p | join(".")] = $s.either
    else . end) |
  .settings |= (
    if $new.permissions.disableBypassPermissionsMode == null then .
    else .permissions.disableBypassPermissionsMode = $new.permissions.disableBypassPermissionsMode end |
    reduce (($new["$unset"] // [])[]) as $k (.; del(.[$k]))) |
  {settings, record: {version: 2, owned}, pending: {version: 2, owned: .either}}')
merged=$(jq '.settings' <<<"$result")
new_record=$(jq '.record' <<<"$result")
# Written before the settings and replaced after them: if the run stops in
# between, the next one still counts both the old and the new guard entries as
# the guard's, and retires whichever it no longer has.
pending_record=$(jq '.pending' <<<"$result")

record_same=0
if [ -e "$record" ] && [ "$(jq -S . <<<"$new_record")" = "$(jq -S . "$record")" ]; then
  record_same=1
fi

write_record() { # [content], default the final record
  local content=${1:-$new_record} tmp
  [ "$#" = 0 ] && [ "$record_same" = 1 ] && return 0
  mkdir -p "$(dirname "$record")"
  tmp=$(mktemp "$record.XXXXXX")
  jq . <<<"$content" >"$tmp"
  mv "$tmp" "$record"
}

settings_same=0
[ "$(jq -S . <<<"$current")" = "$(jq -S . <<<"$merged")" ] && settings_same=1
hook_same=0
cmp -s "$hook_src" "$hook_dst" && hook_same=1

if [ "$check" = 1 ]; then
  if [ "$settings_same" = 1 ] && [ "$hook_same" = 1 ]; then
    echo "apply-claude-guard: $settings and $hook_dst already carry the guard"
    exit 0
  fi
  if [ "$settings_same" = 0 ]; then
    echo "apply-claude-guard: $settings differs from the guard:"
    diff <(jq -S . <<<"$current") <(jq -S . <<<"$merged") || true
  fi
  [ "$hook_same" = 1 ] || echo "apply-claude-guard: $hook_dst differs from $hook_src"
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
  write_record
  exit 0
fi

mkdir -p "$(dirname "$settings")"
tmp=$(mktemp "$settings.XXXXXX")
jq . <<<"$merged" >"$tmp"
# Someone may have saved the file since it was read; writing now would drop
# their change.
if [ "$(cksum <"$settings" 2>/dev/null || echo absent)" != "$read_sum" ]; then
  rm -f "$tmp"
  die "$settings changed while this ran; nothing was written, run it again"
fi
if [ -e "$settings" ]; then cp -p "$settings" "$settings.guard-backup"; fi
write_record "$pending_record"
mv "$tmp" "$settings"
write_record "$new_record"
echo "apply-claude-guard: wrote $settings (previous copy: $settings.guard-backup)"
