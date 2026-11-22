#!/usr/bin/env bash
# Remove what the Jarvis installers added to this machine, and nothing else.
#
# It is the inverse of apply-claude-guard.sh, sync-personal-skills.sh and
# apply-agent-identity.sh, in this order:
#   1  the guard: the entries the record claude-guard.applied.json lists leave
#      settings.json (rules the person wrote stay, even one equal to a guard
#      rule), then the record and the copied hooks (claude-guard.py,
#      jarvis-session-notes.py, jarvis-shell-syntax.py)
#   2  the bridge: ~/.claude/skills/<name>, ~/.claude/CLAUDE.md, and under
#      $CODEX_HOME (default ~/.codex) skills/<name> and AGENTS.md, then ~/.agents
#      -- each only when it is a link that resolves into this checkout
#   3  the identity: apply-agent-identity.sh --unapply (and --unapply --codex),
#      only for a runtime whose agent-identity.applied.json exists
#
# It never touches this checkout, a .guard-backup file (they are listed), a link
# that points elsewhere (reported, left), or an entry it did not add. It deletes
# named files and links only, never a directory tree. The Claude config
# directory is $CLAUDE_CONFIG_DIR, else ~/.claude, for the guard and the
# identity, as apply-claude-guard.sh and apply-agent-identity.sh read it; the
# bridge is always under ~/.claude, as sync-personal-skills.sh makes it.
#
# Usage: uninstall.sh [--dry-run | --remove]
#   --dry-run  the default: change nothing, print each path it would change and why
#   --remove   do it. settings.json is first copied to settings.json.uninstall-backup
# Exit 0 when done (or when the dry run finished), 1 when a step failed, 2 on usage.
set -euo pipefail

usage() { sed -n '/^# Usage:/,/^# Exit 0/s/^# \{0,1\}//p' "$0"; }

act=0
case "${1-}" in
  ""|--dry-run) ;;
  --remove) act=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }

die() { printf 'uninstall: %s\n' "$*" >&2; exit 2; }
command -v jq >/dev/null || die "jq is required"
[ -n "${HOME:-}" ] || die "HOME is not set"

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
codex_home="${CODEX_HOME:-$HOME/.codex}"
settings="$claude_home/settings.json"
record="$claude_home/claude-guard.applied.json"
fail=0

if [ "$act" = 1 ]; then echo "uninstall: --remove: acting"; else echo "uninstall: dry run (nothing is changed; --remove acts)"; fi

# do_rm <path> <why>: remove one file or link, or say it would.
do_rm() {
  if [ "$act" = 1 ]; then rm -f -- "$1"; printf 'removed  %s  (%s)\n' "$1" "$2"
  else printf 'would remove  %s  (%s)\n' "$1" "$2"; fi
}
left() { printf 'left     %s  (%s)\n' "$1" "$2"; }

# resolve <path>: where a link finally leads, physically; nothing if it dangles.
resolve() {
  local p=$1 n=0 t d
  while [ -L "$p" ]; do
    n=$((n + 1)); [ "$n" -le 40 ] || return 1
    t=$(readlink "$p")
    case $t in /*) p=$t ;; *) p="$(dirname "$p")/$t" ;; esac
  done
  [ -e "$p" ] || return 1
  d=$(cd -P "$(dirname "$p")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$d" "$(basename "$p")"
}

# bridge_link <path> <expected prefix: a resolved path or directory>
# Remove a link only if it resolves to the prefix or below it.
bridge_link() {
  local l=$1 root=$2 got
  if [ ! -L "$l" ]; then
    if [ -e "$l" ]; then left "$l" "not a link; not ours"; fi
    return 0
  fi
  if ! got=$(resolve "$l"); then
    left "$l" "dangling link to $(readlink "$l"); not removed, check it"
  elif [ "$got" = "$root" ] || [[ "$got" == "$root"/* ]]; then
    do_rm "$l" "link into $here"
  else
    left "$l" "points at $got, outside $here"
  fi
}

# --- 1. the guard ----------------------------------------------------------------
echo ""
echo "== guard ($claude_home) =="
# Follow links to the end of the chain, as apply-claude-guard.sh writes there.
real_settings=$settings
hops=0
while [ -L "$real_settings" ]; do
  hops=$((hops + 1)); [ "$hops" -le 40 ] || die "$settings: too many levels of links"
  t=$(readlink "$real_settings")
  case $t in /*) real_settings=$t ;; *) real_settings="$(dirname "$real_settings")/$t" ;; esac
done

if [ ! -e "$record" ]; then
  echo "no $record: the guard was not applied here (or already removed); settings.json is not touched"
elif ! jq -e 'type == "object"' "$record" >/dev/null 2>&1; then
  echo "PROBLEM  $record is not a JSON object; fix it by hand. The guard is left in place." >&2
  fail=1
else
  # What the guard added, by list path. A record from before ownership was
  # tracked (no "owned") is a copy of the guard it applied: all of it counts.
  owned=$(jq -c '. as $r | if has("owned") then .owned
    else [["permissions","deny"],["permissions","ask"],["autoMode","hard_deny"],["autoMode","soft_deny"],
          ["hooks","PreToolUse"],["hooks","UserPromptSubmit"],["hooks","SessionStart"],["hooks","PostToolUse"]]
         | map({key: join("."), value: ($r | getpath(.) // [])}) | map(select(.value | length > 0)) | from_entries end' "$record" 2>/dev/null) ||
    owned=''
  if [ -z "$owned" ]; then
    echo "PROBLEM  $record cannot be read as a guard record; fix it by hand. The guard is left in place." >&2
    fail=1
  elif [ ! -e "$real_settings" ]; then
    echo "no $settings: nothing to take entries out of"
  elif ! jq -e 'type == "object"' "$real_settings" >/dev/null 2>&1; then
    echo "PROBLEM  $real_settings is not a JSON object; fix it by hand. The guard is left in place." >&2
    fail=1
  else
    cur=$(cat "$real_settings")
    new=$(jq --argjson o "$owned" '
      reduce ($o | keys[]) as $k (.;
        ($k | split(".")) as $p |
        if (getpath($p) | type) == "array"
        then setpath($p; getpath($p) | map(select(. as $e | ($o[$k] | index([$e])) == null)))
             | if (getpath($p) | length) == 0 or ($p[0] == "autoMode" and getpath($p) == ["$defaults"])
               then delpaths([$p]) else . end
        else . end)
      | reduce ["hooks","autoMode","permissions"][] as $k (.; if .[$k] == {} then del(.[$k]) else . end)' <<<"$cur")
    if [ "$(jq -S . <<<"$cur")" = "$(jq -S . <<<"$new")" ]; then
      echo "no guard entry from the record is in $real_settings; nothing to take out"
    else
      if [ "$act" = 1 ]; then
        cp -p "$real_settings" "$real_settings.uninstall-backup"
        tmp=$(mktemp "$real_settings.XXXXXX")
        jq . <<<"$new" >"$tmp"
        mv "$tmp" "$real_settings"
        printf 'edited   %s  (guard entries from %s taken out; previous copy: %s)\n' "$real_settings" "$record" "$real_settings.uninstall-backup"
      else
        printf 'would edit  %s  (take out the guard entries listed in %s; every other entry stays)\n' "$real_settings" "$record"
      fi
    fi
    if jq -e '.permissions.disableBypassPermissionsMode != null' "$real_settings" >/dev/null 2>&1; then
      left "$real_settings permissions.disableBypassPermissionsMode" "the guard sets it but does not record whether you had it; remove it by hand if you want it gone"
    fi
    do_rm "$record" "the guard's record of what it added"
  fi
fi
for f in claude-guard.py jarvis-session-notes.py jarvis-shell-syntax.py; do
  if [ -e "$claude_home/hooks/$f" ] || [ -L "$claude_home/hooks/$f" ]; then do_rm "$claude_home/hooks/$f" "hook copied by apply-claude-guard.sh"; fi
done
for b in "$settings.guard-backup" "$real_settings.guard-backup" "$settings.agent-identity-backup" "$real_settings.agent-identity-backup"; do
  [ "$b" = "${prev_b-}" ] && continue
  prev_b=$b
  [ -e "$b" ] && left "$b" "backup kept; delete it yourself when you no longer need it"
done

# --- 2. the bridge ---------------------------------------------------------------
echo ""
echo "== bridge =="
skills_root="$here/.agents/skills"
bridge_dir() { # <dir> <label>
  local d=$1 l
  [ -d "$d" ] || { echo "no $d: nothing to unlink"; return 0; }
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    bridge_link "$l" "$skills_root"
  done < <(find "$d" -mindepth 1 -maxdepth 1 -type l | sort)
}
bridge_dir "$HOME/.claude/skills" "Claude Code"
bridge_link "$HOME/.claude/CLAUDE.md" "$here/.agents/AGENTS.md"
if [ -d "$codex_home" ]; then
  bridge_dir "$codex_home/skills" "Codex"
  bridge_link "$codex_home/AGENTS.md" "$here/.agents/AGENTS.md"
else
  echo "no $codex_home: Codex bridge skipped"
fi
# Last: every other link resolves through ~/.agents, so it stays until they are judged.
bridge_link "$HOME/.agents" "$here/.agents"

# --- 3. the identity -------------------------------------------------------------
echo ""
echo "== agent identity =="
ident="$here/scripts/apply-agent-identity.sh"
unapply() { # <label> <record> <args...>
  local label=$1 rec=$2; shift 2
  if [ ! -e "$rec" ] && [ ! -L "$rec" ]; then
    echo "$label: not applied (no $rec); skipped"
  elif [ "$act" = 1 ]; then
    echo "$label: bash $ident $*"
    bash "$ident" "$@" || { echo "PROBLEM  $label: apply-agent-identity.sh $* failed; see above" >&2; fail=1; }
  else
    printf 'would run  bash %s %s  (%s is applied: %s)\n' "$ident" "$*" "$label" "$rec"
  fi
}
unapply "Claude Code" "$claude_home/agent-identity.applied.json" --unapply
unapply "Codex" "$codex_home/agent-identity.applied.json" --unapply --codex
if [ -e "$claude_home/agent-identity.require.json" ]; then
  echo "NOTE     the identity switch is on ($claude_home/agent-identity.require.json): --unapply leaves it on, so GitHub writes stay refused."
  echo "         Turn it off first with: bash $ident --unrequire"
fi

echo ""
echo "left alone: this checkout ($here), the Codex guard (scripts/apply-codex-guard.sh), and anything above marked 'left'. See docs/uninstall.md."
[ "$act" = 1 ] || echo "That was a dry run. To do it: bash $here/scripts/uninstall.sh --remove"
exit "$fail"
