#!/usr/bin/env bash
# Install the personal guard as a user-level Codex PreToolUse hook.
#
# Codex has no permission rules to merge, only hooks. The hook is
# .agents/claude-guard/bash-guard.py run with --codex, installed as
# $CODEX_HOME/hooks/jarvis-guard.py, and one PreToolUse group naming it is
# merged into $CODEX_HOME/hooks.json (CODEX_HOME defaults to ~/.codex). The
# guard is copied, never linked, so a Codex session keeps it on a machine where
# this repository is absent or broken.
#
# hooks.json belongs to the person and to other tools (Orca keeps entries
# there). Every entry that is not the guard's own group stays exactly as it
# is. The guard's handler is recognised by the hook file its command names, not
# by its position, so a re-run replaces it in place and a retired revision of
# it does not pile up. If a person put other handlers in the same group, they
# stay; only a group left with nothing in it goes.
#
# The file is parsed with jq, which keeps only the last of a key that appears
# twice in one object. A hooks.json that repeats a key loses the earlier
# copies when the script rewrites it; Codex's own reading of such a file is
# not known, so do not rely on duplicate keys.
#
# Codex runs a hook only after the person trusts it in /hooks, by hash, so the
# first install and every change to the hook or its entry needs trusting again.
# Codex also has no "ask" and runs the command when a hook fails; the guard's
# --codex mode turns both into denials (see bash-guard.py).
#
# Usage: apply-codex-guard.sh [--check]
#   --check  change nothing; exit 0 when the hook and hooks.json already carry
#            the guard, 1 when applying would change something, 2 on error.
set -euo pipefail

usage() { sed -n '/^# Usage:/,/2 on error/s/^# \{0,1\}//p' "$0"; }

[ "$#" -le 1 ] || { usage >&2; exit 2; }
check=0
case "${1-}" in
  "") ;;
  --check) check=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

die() { printf 'apply-codex-guard: %s\n' "$*" >&2; exit 2; }

command -v jq >/dev/null || die "jq is required"

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
codex_home="${CODEX_HOME:-$HOME/.codex}"
hooks_json="$codex_home/hooks.json"
hook_src="$here/.agents/claude-guard/bash-guard.py"
hook_dst="$codex_home/hooks/jarvis-guard.py"
[ -f "$hook_src" ] || die "$hook_src is missing"

# What Codex runs. The interpreter is the one macOS ships, with -I so the
# working directory cannot plant a module; the path is resolved by the shell
# Codex starts, from CODEX_HOME or the default, the same as this script does.
# The timeout is 10 s: the guard's own budget is 6 s (see DEADLINE in
# bash-guard.py), and a hook that overruns lets the command run.
cmd='py=/usr/bin/python3; [ -x "$py" ] || py=python3; exec "$py" -I "${CODEX_HOME:-$HOME/.codex}/hooks/jarvis-guard.py" --codex'
group=$(jq -n --arg c "$cmd" '{matcher: "^Bash$", hooks: [{type: "command", command: $c, timeout: 10,
  statusMessage: "Codex guard: checking the command"}]}')

# Write through links, to the end of the chain, so a file kept by a dotfiles
# manager stays where that manager put it.
hops=0
while [ -L "$hooks_json" ]; do
  hops=$((hops + 1))
  [ "$hops" -le 40 ] || die "$hooks_json: too many levels of links"
  target=$(readlink "$hooks_json")
  case "$target" in /*) ;; *) target="$(dirname "$hooks_json")/$target" ;; esac
  hooks_json="$target"
done

# The file is read once, into a copy, and everything below (the parse, and the
# checksum the concurrent-change check compares against) is of those bytes.
snapshot=$(mktemp "${TMPDIR:-/tmp}/apply-codex-guard.XXXXXX")
trap 'rm -f "$snapshot"' EXIT
if [ -e "$hooks_json" ]; then
  cp "$hooks_json" "$snapshot"
  jq -s -e 'length == 1 and (.[0] | type) == "object"' "$snapshot" >/dev/null 2>&1 ||
    die "$hooks_json is not a single JSON object; fix it by hand first, nothing was changed"
  current=$(cat "$snapshot")
  read_sum=$(cksum <"$snapshot")
else
  current='{}'
  read_sum=absent
fi

merged=$(jq --argjson g "$group" '
  def own_h: (.command? // "") | contains("/hooks/jarvis-guard.py");
  def own: any(.hooks[]?; own_h);
  if (.hooks // {} | type) != "object" then error("hooks is not an object")
  elif (.hooks.PreToolUse // [] | type) != "array" then error("hooks.PreToolUse is not a list")
  else
    (.hooks.PreToolUse // []) as $l |
    ([range(0; $l | length) | select($l[.] | own)] | first) as $at |
    .hooks.PreToolUse =
      (if $at == null then $l + [$g]
       else
         [range(0; $l | length) as $i | $l[$i] as $grp |
          if ($grp | own | not) then $grp
          else
            ($grp | .hooks |= map(select(own_h | not))) as $rest |
            if $i != $at then (if ($rest.hooks | length) > 0 then $rest else empty end)
            elif $grp.matcher == $g.matcher then
              # the guard shares this group with other handlers: swap its own
              # handler in place, where it stood
              $grp | .hooks |= (map(if own_h then $g.hooks[0] else . end)
                                | reduce .[] as $x ([]; if ($x | own_h) and any(.[]; own_h) then . else . + [$x] end))
            else
              (if ($rest.hooks | length) > 0 then $rest else empty end), $g
            end
          end]
       end)
  end' <<<"$current") ||
  die "$hooks_json has a hooks section of an unexpected shape; fix it by hand first, nothing was changed"

same=0
[ "$(jq -S . <<<"$current")" = "$(jq -S . <<<"$merged")" ] && same=1
hook_same=0
cmp -s "$hook_src" "$hook_dst" && hook_same=1

if [ "$check" = 1 ]; then
  if [ "$same" = 1 ] && [ "$hook_same" = 1 ]; then
    echo "apply-codex-guard: $hooks_json and $hook_dst already carry the guard"
    exit 0
  fi
  if [ "$same" = 0 ]; then
    echo "apply-codex-guard: $hooks_json differs from the guard:"
    diff <(jq -S . <<<"$current") <(jq -S . <<<"$merged") || true
  fi
  [ "$hook_same" = 1 ] || echo "apply-codex-guard: $hook_dst differs from $hook_src"
  exit 1
fi

# The hook goes in before the entry that names it. Codex fails open, so an
# entry whose file is missing would not even block, only leave a failed hook.
if [ "$hook_same" = 0 ]; then
  mkdir -p "$(dirname "$hook_dst")"
  tmp=$(mktemp "$hook_dst.XXXXXX")
  cp "$hook_src" "$tmp"
  mv "$tmp" "$hook_dst"
  echo "apply-codex-guard: wrote $hook_dst"
fi

if [ "$same" = 1 ]; then
  echo "apply-codex-guard: $hooks_json already carries the guard"
else
  mkdir -p "$(dirname "$hooks_json")"
  tmp=$(mktemp "$hooks_json.XXXXXX")
  # The new file takes the old one's mode (mktemp makes 0600), or the umask's
  # default when there is no old one.
  if [ -e "$hooks_json" ]; then
    cp -p "$hooks_json" "$tmp"
  else
    chmod "$(printf '%o' $((0666 & ~$(umask))))" "$tmp"
  fi
  jq . <<<"$merged" >"$tmp"
  # Someone may have saved the file since it was read; writing now would drop
  # their change.
  if [ -e "$hooks_json" ]; then now=$(cksum <"$hooks_json"); else now=absent; fi
  if [ "$now" != "$read_sum" ]; then
    rm -f "$tmp"
    die "$hooks_json changed while this ran, so it was not written (the hook file $hook_dst already was, and does nothing without its entry); run it again"
  fi
  if [ -e "$hooks_json" ]; then cp -p "$hooks_json" "$hooks_json.guard-backup"; fi
  mv "$tmp" "$hooks_json"
  echo "apply-codex-guard: wrote $hooks_json (previous copy: $hooks_json.guard-backup)"
fi

if [ "$hook_same" = 0 ] || [ "$same" = 0 ]; then
  echo "apply-codex-guard: Codex runs the hook only after it is trusted in /hooks;" \
    "trust it there now, and again after every change to it."
fi
