#!/usr/bin/env bash
# Install the personal guard as a user-level agy PreToolUse hook.
#
# Both agy CLI and Antigravity IDE share ~/.gemini/config/hooks.json. The hook
# is .agents/claude-guard/bash-guard.py run with --agy, installed as
# ~/.gemini/config/hooks/jarvis-guard.py, and its top-level named group
# "jarvis-guard" is merged into ~/.gemini/config/hooks.json. The guard is
# copied, never linked, so a session keeps it on a machine where this
# repository is absent or broken.
#
# hooks.json belongs to the person and to other tools (herdr and orca-status
# keep top-level groups there). Every top-level key other than "jarvis-guard"
# stays exactly as it is.
#
# The file is parsed with jq, which keeps only the last of a key that appears
# twice in one object.
#
# Usage: apply-agy-guard.sh [--check]
#   (none)   install or update the guard
#   --check  change nothing; exit 0 when the hook and hooks.json already carry
#            the guard, 1 when applying would change something, 2 on error.
set -euo pipefail

usage() { sed -n '/^# Usage:/,/2 on error\./s/^# \{0,1\}//p' "$0"; }

check=0
for a in "$@"; do
  case "$a" in
    -h|--help) [ "$#" = 1 ] || { usage >&2; exit 2; }; usage; exit 0 ;;
    --check) [ "$check" = 0 ] || { usage >&2; exit 2; }; check=1 ;;
    *) usage >&2; exit 2 ;;
  esac
done

die() { printf 'apply-agy-guard: %s\n' "$*" >&2; exit 2; }

command -v jq >/dev/null || die "jq is required"

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
agy_home="$HOME/.gemini/config"
hooks_json="$agy_home/hooks.json"
hook_src="$here/.agents/claude-guard/bash-guard.py"
hook_dst="$agy_home/hooks/jarvis-guard.py"
[ -f "$hook_src" ] || die "$hook_src is missing"

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
snapshot=$(mktemp "${TMPDIR:-/tmp}/apply-agy-guard.XXXXXX")
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

# What agy runs. The interpreter is the one macOS ships, with -I so the
# working directory cannot plant a module. The timeout is 10 s: the guard's
# own budget is 6 s (see DEADLINE in bash-guard.py), and an 8 s watchdog
# emits deny before agy's timeout (agy also fails closed on error or timeout).
cmd='py=/usr/bin/python3; [ -x "$py" ] || py=python3; exec "$py" -I "$HOME/.gemini/config/hooks/jarvis-guard.py" --agy'
group=$(jq -n --arg c "$cmd" '{PreToolUse: [{matcher: "run_command", hooks: [{type: "command", command: $c, timeout: 10}]}]}')

merged=$(jq --argjson g "$group" '.["jarvis-guard"] = $g' <<<"$current")

same=0
[ "$(jq -S . <<<"$current")" = "$(jq -S . <<<"$merged")" ] && same=1
hook_same=0
cmp -s "$hook_src" "$hook_dst" && hook_same=1

if [ "$check" = 1 ]; then
  bad=0
  if [ "$same" = 1 ] && [ "$hook_same" = 1 ]; then
    echo "apply-agy-guard: $hooks_json and $hook_dst already carry the guard"
  else
    bad=1
    if [ "$same" = 0 ]; then
      echo "apply-agy-guard: $hooks_json differs from the guard:"
      diff <(jq -S . <<<"$current") <(jq -S . <<<"$merged") || true
    fi
    [ "$hook_same" = 1 ] || echo "apply-agy-guard: $hook_dst differs from $hook_src"
  fi
  exit "$bad"
fi

# The hook goes in before the entry that names it (agy fails closed, so an
# entry whose file is missing would block every run_command).
if [ "$hook_same" = 0 ]; then
  mkdir -p "$(dirname "$hook_dst")"
  tmp=$(mktemp "$hook_dst.XXXXXX")
  cp "$hook_src" "$tmp"
  mv "$tmp" "$hook_dst"
  echo "apply-agy-guard: wrote $hook_dst"
fi

if [ "$same" = 1 ]; then
  echo "apply-agy-guard: $hooks_json already carries the guard"
else
  mkdir -p "$(dirname "$hooks_json")"
  tmp=$(mktemp "$hooks_json.XXXXXX")
  if [ -e "$hooks_json" ]; then
    cp -p "$hooks_json" "$tmp"
  else
    chmod "$(printf '%o' $((0666 & ~$(umask))))" "$tmp"
  fi
  jq . <<<"$merged" >"$tmp"
  if [ -e "$hooks_json" ]; then now=$(cksum <"$hooks_json"); else now=absent; fi
  if [ "$now" != "$read_sum" ]; then
    rm -f "$tmp"
    die "$hooks_json changed while this ran, so it was not written (the hook file $hook_dst already was); run it again"
  fi
  if [ -e "$hooks_json" ]; then cp -p "$hooks_json" "$hooks_json.guard-backup"; fi
  mv "$tmp" "$hooks_json"
  echo "apply-agy-guard: wrote $hooks_json (previous copy: $hooks_json.guard-backup)"
fi
