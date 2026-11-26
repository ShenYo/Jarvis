#!/usr/bin/env bash
# Remove what the Jarvis installers added to this machine, and nothing else.
#
# It is the inverse of apply-claude-guard.sh, sync-personal-skills.sh and
# apply-agent-identity.sh, in this order:
#   1  the guard: the entries the record claude-guard.applied.json lists leave
#      settings.json (rules the person wrote stay, even one equal to a guard
#      rule: one occurrence of each listed entry goes), then the record and the
#      copied hooks (claude-guard.py, jarvis-session-notes.py,
#      jarvis-shell-syntax.py), each hook only if it is byte-identical to the
#      copy this checkout installs and no settings entry still names it. When the
#      record is missing or unreadable, settings.json is not JSON, or the backup
#      path is taken, none of the guard is removed: every piece is reported as
#      "left" and the run exits 1
#   1b agy guard ($HOME/.gemini/config): removes the "jarvis-guard" group from
#      hooks.json (other groups such as herdr and orca-status stay), and removes
#      hooks/jarvis-guard.py if byte-identical to this checkout's bash-guard.py
#      and no hooks.json entry still names it
#   2  the bridge: ~/.claude/skills/<name>, ~/.claude/CLAUDE.md, under
#      $CODEX_HOME (default ~/.codex) skills/<name> and AGENTS.md,
#      ~/.gemini/config/AGENTS.md, then ~/.agents
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
#   --remove   do it. settings.json is first copied to settings.json.uninstall-backup,
#              which must not exist yet
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
agents_users=0   # a kept link that still goes through ~/.agents
bridge_link() {
  local l=$1 root=$2 got
  if [ ! -L "$l" ]; then
    if [ -e "$l" ]; then left "$l" "not a link; not ours"; fi
    return 0
  fi
  if ! got=$(resolve "$l"); then
    left "$l" "dangling link to $(readlink "$l"); not removed, check it"
    case $(readlink "$l") in *.agents|*.agents/*) agents_users=1 ;; esac
  elif [ "$got" = "$root" ] || [[ "$got" == "$root"/* ]]; then
    do_rm "$l" "link into $here"
  else
    left "$l" "points at $got, outside $root"
    case $(readlink "$l") in *.agents|*.agents/*) agents_users=1 ;; esac
  fi
}

# --- 1. the guard ----------------------------------------------------------------
echo ""
echo "== guard ($claude_home) =="
# follow <path>: the end of a chain of links, which is where the installers write.
follow() {
  local p=$1 n=0 t
  while [ -L "$p" ]; do
    n=$((n + 1)); [ "$n" -le 40 ] || die "$1: too many levels of links"
    t=$(readlink "$p")
    case $t in /*) p=$t ;; *) p="$(dirname "$p")/$t" ;; esac
  done
  printf '%s\n' "$p"
}
real_settings=$(follow "$settings")

# The lists the guard manages, read from the installer so the two cannot drift.
managed=$(sed -n '/def lists:/,/;$/p' "$here/scripts/apply-claude-guard.sh" |
  grep -o '\["[A-Za-z_]*","[A-Za-z_]*"\]' | jq -sc 'map(join("."))') || managed='[]'
[ "$managed" != '[]' ] || die "cannot read the managed lists from $here/scripts/apply-claude-guard.sh"
# The hook copies apply-claude-guard.sh makes: name under hooks/, source in the checkout.
hook_names=(claude-guard.py jarvis-session-notes.py jarvis-shell-syntax.py)
hook_srcs=(bash-guard.py session-notes.py shell-syntax.py)
ref_re='hooks/(claude-guard|jarvis-session-notes|jarvis-shell-syntax)\.py'
refs_in() { jq --arg re "$ref_re" '[.. | strings | select(test($re))] | length' <<<"$1"; }
names_hook() { jq -e --arg n "hooks/$2" '[.. | strings | select(contains($n))] | length > 0' <<<"$1" >/dev/null; }

guard_stop=0
guard_problem() { printf 'PROBLEM  %s\n' "$1" >&2; fail=1; guard_stop=1; }

cur='' refs_now=0
if [ -e "$real_settings" ]; then
  if jq -e 'type == "object"' "$real_settings" >/dev/null 2>&1; then
    cur=$(cat "$real_settings"); refs_now=$(refs_in "$cur")
    read_sum=$(cksum <"$real_settings")
  else
    guard_problem "$real_settings is not a JSON object; fix it by hand. The guard's record, hooks and settings entries are left in place."
  fi
fi
present=()
for i in "${!hook_names[@]}"; do
  if [ -e "$claude_home/hooks/${hook_names[$i]}" ] || [ -L "$claude_home/hooks/${hook_names[$i]}" ]; then present+=("$i"); fi
done

owned='' have_record=0
if [ "$guard_stop" = 0 ]; then
  if [ -e "$record" ] || [ -L "$record" ]; then
    have_record=1
    # A record from before ownership was tracked (no "owned") is a copy of the
    # guard it applied: all of it counts. Otherwise "owned" must be an object of
    # arrays, under the paths the installer manages.
    if ! owned=$(jq -c --argjson m "$managed" '
        if type != "object" then error("record")
        elif has("owned") then
          .owned as $o |
          if ($o | type) != "object" then error("owned")
          elif (($o | keys) - $m | length) > 0 then error("path")
          elif ([$o[] | type == "array"] | all | not) then error("values")
          else $o end
        else . as $r | $m | map(. as $k | {key: $k, value: ($r | getpath($k | split(".")) // [])})
             | map(select(.value | type == "array" and length > 0)) | from_entries end' "$record" 2>/dev/null); then
      guard_problem "$record cannot be read as a guard record (it must be a JSON object whose owned map is an object of arrays under the lists apply-claude-guard.sh manages); fix it by hand. The guard's record, hooks and settings entries are left in place."
    fi
  elif [ "${#present[@]}" -gt 0 ] || [ "$refs_now" -gt 0 ]; then
    guard_problem "no $record, but the guard's hooks or settings entries are here: nothing shows Jarvis added them, so they are left in place."
  else
    echo "no $record: the guard was not applied here (or already removed)"
  fi
fi

new="$cur" backup="$real_settings.uninstall-backup" edit=0
if [ "$guard_stop" = 0 ] && [ "$have_record" = 1 ] && [ -n "$cur" ]; then
  new=$(jq --argjson o "$owned" '
    def drop_last($e): (to_entries | map(select(.value == $e)) | last | .key) as $i
                       | if $i == null then . else .[:$i] + .[$i + 1:] end;
    reduce ($o | keys[]) as $k (.;
      ($k | split(".")) as $p |
      if (getpath($p) | type) == "array"
      then setpath($p; reduce $o[$k][] as $e (getpath($p); drop_last($e)))
           | if (getpath($p) | length) == 0 or ($p[0] == "autoMode" and getpath($p) == ["$defaults"])
             then delpaths([$p]) else . end
      else . end)
    | reduce ["hooks","autoMode","permissions"][] as $k (.; if .[$k] == {} then del(.[$k]) else . end)' <<<"$cur")
  [ "$(jq -S . <<<"$cur")" = "$(jq -S . <<<"$new")" ] || edit=1
  if [ "$edit" = 1 ] && { [ -e "$backup" ] || [ -L "$backup" ]; }; then
    guard_problem "$backup already exists; this run would overwrite it (or write through it). Move it away, then run this again. The guard's record, hooks and settings entries are left in place."
  fi
fi

guard_leave_all() {
  [ ! -e "$record" ] && [ ! -L "$record" ] || left "$record" "guard left whole, see PROBLEM above"
  [ ! -e "$real_settings" ] || left "$real_settings" "guard left whole, see PROBLEM above"
  for i in ${present[@]+"${present[@]}"}; do left "$claude_home/hooks/${hook_names[$i]}" "guard left whole, see PROBLEM above"; done
}
if [ "$guard_stop" = 0 ] && [ "$have_record" = 1 ] && [ "$edit" = 1 ]; then
  if [ "$act" = 1 ]; then
    tmp=$(mktemp "$real_settings.XXXXXX")
    jq . <<<"$new" >"$tmp"
    # Someone may have saved the file since it was read; replacing it now would drop their change
    # (apply-claude-guard.sh makes the same check).
    if [ "$(cksum <"$real_settings" 2>/dev/null || echo absent)" != "$read_sum" ]; then
      rm -f "$tmp"
      guard_problem "$real_settings changed while this ran; nothing was written. Run it again. The guard's record, hooks and settings entries are left in place."
    else
      cp -p "$real_settings" "$backup"
      mv "$tmp" "$real_settings"
      printf 'edited   %s  (guard entries from %s taken out; previous copy: %s)\n' "$real_settings" "$record" "$backup"
    fi
  else
    printf 'would edit  %s  (take out the guard entries listed in %s, one occurrence of each; every other entry stays; previous copy would go to %s)\n' "$real_settings" "$record" "$backup"
  fi
elif [ "$guard_stop" = 0 ] && [ "$have_record" = 1 ]; then
  if [ -n "$cur" ]; then echo "no guard entry from the record is in $real_settings; nothing to take out"
  else echo "no $settings: nothing to take entries out of"; fi
fi
if [ "$guard_stop" = 0 ]; then
  if [ "$have_record" = 1 ]; then
    if [ -n "$new" ] && jq -e '.permissions.disableBypassPermissionsMode != null' <<<"$new" >/dev/null 2>&1; then
      left "$real_settings permissions.disableBypassPermissionsMode" "the guard sets it but does not record whether you had it; remove it by hand if you want it gone"
    fi
    do_rm "$record" "the guard's record of what it added"
  fi
  for i in ${present[@]+"${present[@]}"}; do
    h="$claude_home/hooks/${hook_names[$i]}"
    if [ -n "$new" ] && names_hook "$new" "${hook_names[$i]}"; then
      left "$h" "an entry in $real_settings still names it (not one the record lists); removing it would break that entry"
    elif [ -f "$h" ] && [ ! -L "$h" ] && cmp -s "$h" "$here/.agents/claude-guard/${hook_srcs[$i]}"; then
      do_rm "$h" "hook copied by apply-claude-guard.sh, identical to this checkout's ${hook_srcs[$i]}"
    else
      left "$h" "not byte-identical to this checkout's ${hook_srcs[$i]} (edited, a link, or not copied by the installer); delete it by hand if you want it gone. doctor.sh reports the machine as installed until you do"
    fi
  done
else
  guard_leave_all
fi
prev_b=''
# (settings.json.agent-identity-backup is not listed: step 3's --unapply overwrites it.)
for b in "$settings.guard-backup" "$real_settings.guard-backup" "$settings.uninstall-backup" "$backup"; do
  [ "$b" = "$prev_b" ] && continue
  prev_b=$b
  if [ -e "$b" ] || [ -L "$b" ]; then left "$b" "backup kept; delete it yourself when you no longer need it"; fi
done

# --- 1b. agy guard ---------------------------------------------------------------
agy_home="$HOME/.gemini/config"
agy_hooks="$agy_home/hooks.json"
agy_hook_dst="$agy_home/hooks/jarvis-guard.py"
real_agy_hooks=$(follow "$agy_hooks")
echo ""
echo "== agy guard ($agy_home) =="
agy_stop=0 agy_cur='' agy_new='' agy_edit=0 agy_sum=''
agy_backup="$real_agy_hooks.uninstall-backup"
if [ -e "$real_agy_hooks" ]; then
  if jq -e 'type == "object"' "$real_agy_hooks" >/dev/null 2>&1; then
    agy_cur=$(cat "$real_agy_hooks")
    agy_sum=$(cksum <"$real_agy_hooks")
    agy_new=$(jq 'del(."jarvis-guard")' <<<"$agy_cur")
    [ "$(jq -S . <<<"$agy_cur")" = "$(jq -S . <<<"$agy_new")" ] || agy_edit=1
    if [ "$agy_edit" = 1 ] && { [ -e "$agy_backup" ] || [ -L "$agy_backup" ]; }; then
      printf 'PROBLEM  %s already exists; this run would overwrite it (or write through it). Move it away, then run this again. The agy guard is left in place.\n' "$agy_backup" >&2
      fail=1; agy_stop=1
    fi
  else
    printf 'PROBLEM  %s is not a JSON object; fix it by hand. The agy guard is left in place.\n' "$real_agy_hooks" >&2
    fail=1; agy_stop=1
  fi
fi
if [ "$agy_stop" = 0 ]; then
  if [ "$agy_edit" = 1 ]; then
    if [ "$act" = 1 ]; then
      tmp=$(mktemp "$real_agy_hooks.XXXXXX")
      jq . <<<"$agy_new" >"$tmp"
      if [ "$(cksum <"$real_agy_hooks" 2>/dev/null || echo absent)" != "$agy_sum" ]; then
        rm -f "$tmp"
        printf 'PROBLEM  %s changed while this ran; nothing was written. Run it again. The agy guard is left in place.\n' "$real_agy_hooks" >&2
        fail=1; agy_stop=1
      else
        cp -p "$real_agy_hooks" "$agy_backup"
        mv "$tmp" "$real_agy_hooks"
        printf 'edited   %s  (jarvis-guard group taken out; previous copy: %s)\n' "$real_agy_hooks" "$agy_backup"
      fi
    else
      printf 'would edit  %s  (take out jarvis-guard group; every other group stays; previous copy would go to %s)\n' "$real_agy_hooks" "$agy_backup"
    fi
  else
    echo "no jarvis-guard entry in $real_agy_hooks"
  fi
fi
if [ "$agy_stop" = 0 ] && { [ -e "$agy_hook_dst" ] || [ -L "$agy_hook_dst" ]; }; then
  if [ -n "$agy_new" ] && jq -e '[.. | strings | select(contains("hooks/jarvis-guard.py"))] | length > 0' <<<"$agy_new" >/dev/null 2>&1; then
    left "$agy_hook_dst" "an entry in $real_agy_hooks still names it; removing it would break that entry"
  elif [ -f "$agy_hook_dst" ] && [ ! -L "$agy_hook_dst" ] && cmp -s "$agy_hook_dst" "$here/.agents/claude-guard/bash-guard.py"; then
    do_rm "$agy_hook_dst" "hook copied by apply-agy-guard.sh, identical to this checkout's bash-guard.py"
  else
    left "$agy_hook_dst" "not byte-identical to this checkout's bash-guard.py (edited, a link, or not copied by the installer); delete it by hand if you want it gone"
  fi
elif [ "$agy_stop" = 1 ]; then
  [ ! -e "$real_agy_hooks" ] || left "$real_agy_hooks" "agy guard left whole, see PROBLEM above"
  { [ ! -e "$agy_hook_dst" ] && [ ! -L "$agy_hook_dst" ]; } || left "$agy_hook_dst" "agy guard left whole, see PROBLEM above"
fi
prev_b=''
for b in "$agy_hooks.guard-backup" "$real_agy_hooks.guard-backup" "$agy_hooks.uninstall-backup" "$agy_backup"; do
  [ "$b" = "$prev_b" ] && continue
  prev_b=$b
  if [ -e "$b" ] || [ -L "$b" ]; then left "$b" "backup kept; delete it yourself when you no longer need it"; fi
done

# --- 2. the bridge ---------------------------------------------------------------
echo ""
echo "== bridge =="
skills_root="$here/.agents/skills"
scan_failed=0
bridge_dir() { # <dir> <label>
  local d=$1 listing l
  [ -d "$d" ] || { echo "no $d: nothing to unlink"; return 0; }
  # -H: the directory itself may be a link (a dotfiles checkout); its entries are what count.
  if ! listing=$(find -H "$d" -mindepth 1 -maxdepth 1 2>&1 | sort); then
    printf 'PROBLEM  %s cannot be scanned (%s); its links are left in place.\n' "$d" "$(printf '%s' "$listing" | head -1)" >&2
    fail=1; scan_failed=1
    return 0
  fi
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    bridge_link "$l" "$skills_root"
  done <<<"$listing"
}
bridge_dir "$HOME/.claude/skills" "Claude Code"
bridge_link "$HOME/.claude/CLAUDE.md" "$here/.agents/AGENTS.md"
if [ -d "$codex_home" ]; then
  bridge_dir "$codex_home/skills" "Codex"
  bridge_link "$codex_home/AGENTS.md" "$here/.agents/AGENTS.md"
else
  echo "no $codex_home: Codex bridge skipped"
fi
if [ -d "$HOME/.gemini/config" ]; then
  bridge_link "$HOME/.gemini/config/AGENTS.md" "$here/.agents/AGENTS.md"
else
  echo "no $HOME/.gemini/config: agy instructions skipped"
fi
# Last: every other link resolves through ~/.agents, so it stays until they are judged. It also stays
# when a skills directory could not be scanned or a link that is kept still goes through it: removing it
# would leave those links dangling.
if [ -L "$HOME/.agents" ] && { [ "$scan_failed" = 1 ] || [ "$agents_users" = 1 ]; }; then
  left "$HOME/.agents" "a skills directory could not be scanned, or a link that is kept still goes through it; fix that, then run this again"
  printf 'PROBLEM  %s is kept because links that stay in place resolve through it.\n' "$HOME/.agents" >&2
  fail=1
else
  bridge_link "$HOME/.agents" "$here/.agents"
fi

# --- 3. the identity -------------------------------------------------------------
echo ""
echo "== agent identity =="
ident="$here/scripts/apply-agent-identity.sh"
unapply() { # <label> <record> <detail> <args...>
  local label=$1 rec=$2 detail=$3; shift 3
  if [ ! -e "$rec" ] && [ ! -L "$rec" ]; then
    echo "$label: not applied (no $rec); skipped"
  elif [ "$act" = 1 ]; then
    echo "$label: bash $ident $*"
    bash "$ident" "$@" || { echo "PROBLEM  $label: apply-agent-identity.sh $* failed; see above" >&2; fail=1; }
  else
    printf 'would run  bash %s %s  (%s is applied; %s; record %s)\n' "$ident" "$*" "$label" "$detail" "$rec"
  fi
}
cl_bak="$real_settings.agent-identity-backup"
cx_cfg=$(follow "$codex_home/config.toml"); cx_bak="$cx_cfg.agent-identity-backup"
cl_keys=$(jq -r '(.env // {}) | keys | join(", ")' "$claude_home/agent-identity.applied.json" 2>/dev/null) || cl_keys=''
cx_git=$(jq -r '.gitconfig // empty' "$codex_home/agent-identity.applied.json" 2>/dev/null) || cx_git=''
unapply "Claude Code" "$claude_home/agent-identity.applied.json" \
  "it takes the env keys ${cl_keys:-the record lists} out of $real_settings, copying it to $cl_bak first (replacing any copy there), and deletes the record" --unapply
unapply "Codex" "$codex_home/agent-identity.applied.json" \
  "it takes its block out of $cx_cfg, copying it to $cx_bak first (replacing any copy there), deletes ${cx_git:-the gitconfig the record names} and the record" --unapply --codex
if [ -e "$claude_home/agent-identity.require.json" ]; then
  echo "NOTE     the identity switch is on ($claude_home/agent-identity.require.json): --unapply leaves it on, so GitHub writes stay refused."
  echo "         Turn it off first with: bash $ident --unrequire"
fi

echo ""
echo "left alone: this checkout ($here), the Codex guard (scripts/apply-codex-guard.sh), and anything above marked 'left'. See docs/uninstall.md."
[ "$act" = 1 ] || echo "That was a dry run. To do it: bash $here/scripts/uninstall.sh --remove"
exit "$fail"
