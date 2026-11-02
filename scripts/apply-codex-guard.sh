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
# The agent-identity switch of the guard (refuse every GitHub write from a
# runtime whose identity is not applied) is an argument of the hook's command,
# --require-identity, because a Codex hook does not see the environment. Adding
# or removing it changes the entry's hash, so the switch needs a trust in /hooks
# too. With neither flag the switch keeps the state the installed hook has, so
# updating the guard never turns it off; a first install starts with it off.
#
# Whether Codex trusts the installed entry is read from $CODEX_HOME/config.toml:
# [hooks.state."<hooks.json path>:pre_tool_use:<group>:<handler>"] holds the
# trusted_hash Codex stored in /hooks, which is sha256 of the compact, key-sorted
# JSON of the entry (see trust_check). Reading it needs a python3 with tomllib
# (3.11+); without one the trust state cannot be verified, and --check and
# --trust say so and fail. This script never writes trusted_hash or enabled:
# trusting is the person's act in /hooks.
#
# Usage: apply-codex-guard.sh [--check | --trust] [--require-identity | --no-require-identity]
#   (none)                 install or update the guard; report whether Codex trusts it
#   --check                change nothing; exit 0 when the hook and hooks.json already carry
#                          the guard and Codex trusts it, 1 when applying would change
#                          something or Codex does not trust the entry (UNTRUSTED, DISABLED,
#                          or not verifiable), 2 on error.
#   --trust                change nothing; report only whether Codex trusts the installed
#                          entry; exit 0 when it does, 1 when it does not
#   --require-identity     write the entry with the agent-identity switch on
#   --no-require-identity  write the entry with it off
#   (neither)              keep the switch as the installed entry has it (off on a first install)
set -euo pipefail

usage() { sed -n '/^# Usage:/,/off on a first install/s/^# \{0,1\}//p' "$0"; }

check=0 trust_only=0 req=keep
if [ "$#" = 1 ]; then
  case "$1" in -h|--help) usage; exit 0 ;; esac
fi
for a in "$@"; do
  case "$a" in
    --check) [ "$check" = 0 ] || { usage >&2; exit 2; }; check=1 ;;
    --trust) [ "$trust_only" = 0 ] || { usage >&2; exit 2; }; trust_only=1 ;;
    --require-identity) [ "$req" = keep ] || { usage >&2; exit 2; }; req=on ;;
    --no-require-identity) [ "$req" = keep ] || { usage >&2; exit 2; }; req=off ;;
    *) usage >&2; exit 2 ;;
  esac
done
[ "$trust_only" = 0 ] || [ "$#" = 1 ] || { usage >&2; exit 2; }

die() { printf 'apply-codex-guard: %s\n' "$*" >&2; exit 2; }

command -v jq >/dev/null || die "jq is required"

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
codex_home="${CODEX_HOME:-$HOME/.codex}"
hooks_json="$codex_home/hooks.json"
hook_src="$here/.agents/claude-guard/bash-guard.py"
hook_dst="$codex_home/hooks/jarvis-guard.py"
[ -f "$hook_src" ] || die "$hook_src is missing"

# The path Codex names the file by in its trust records (verified against Codex 0.166):
# with CODEX_HOME set, that directory made canonical (/tmp/x is /private/tmp/x, a trailing
# slash goes) plus /hooks.json; with it unset, $HOME/.codex/hooks.json exactly as written,
# links in HOME or in .codex not resolved. A hooks.json that is itself a link is never
# resolved. The write below goes through links to the end of the chain.
if [ -n "${CODEX_HOME:-}" ]; then
  named_dir=$(cd "$CODEX_HOME" 2>/dev/null && pwd -P) || named_dir=$CODEX_HOME
  hooks_named="${named_dir%/}/hooks.json"
else
  hooks_named="$HOME/.codex/hooks.json"
fi

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

# What Codex runs. The interpreter is the one macOS ships, with -I so the
# working directory cannot plant a module; the path is resolved by the shell
# Codex starts, from CODEX_HOME or the default, the same as this script does.
# The timeout is 10 s: the guard's own budget is 6 s (see DEADLINE in
# bash-guard.py), and a hook that overruns lets the command run. The switch is
# the last argument, as the flag says, or as the installed entry has it.
cmd='py=/usr/bin/python3; [ -x "$py" ] || py=python3; exec "$py" -I "${CODEX_HOME:-$HOME/.codex}/hooks/jarvis-guard.py" --codex'
installed_on=$(jq -r '
  def own_h: (.command? // "") | contains("/hooks/jarvis-guard.py");
  [(.hooks.PreToolUse // [])[] | .hooks[]? | select(own_h)] | first | (.command // "") | endswith(" --require-identity")' \
  <<<"$current" 2>/dev/null) || installed_on=false
case "$req" in on) sw=1 ;; off) sw=0 ;; *) if [ "$installed_on" = true ]; then sw=1; else sw=0; fi ;; esac
[ "$sw" = 0 ] || cmd="$cmd --require-identity"
group=$(jq -n --arg c "$cmd" '{matcher: "^Bash$", hooks: [{type: "command", command: $c, timeout: 10,
  statusMessage: "Codex guard: checking the command"}]}')
# A fresh install starts with the switch off. If Claude Code's switch is on (apply-agent-identity.sh
# --require left its record), say that Codex is now the uncovered side.
have_own=$(jq -r '
  def own_h: (.command? // "") | contains("/hooks/jarvis-guard.py");
  any((.hooks.PreToolUse // [])[]? | .hooks[]?; own_h)' <<<"$current" 2>/dev/null) || have_own=false
claude_req="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agent-identity.require.json"
warn_off=0
if [ "$have_own" != true ] && [ "$sw" = 0 ] &&
   jq -e '.env.JARVIS_REQUIRE_AGENT_IDENTITY == "1"' "$claude_req" >/dev/null 2>&1; then
  warn_off=1
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

# Does Codex trust the Jarvis entry in the given hooks.json text? Sets trust_state to OK,
# UNTRUSTED, DISABLED, NOT-INSTALLED or UNVERIFIABLE, trust_msg to one line saying why and
# trust_fix to what to do (empty when OK). The entry is found as the merge finds it, by the hook
# file its command names: event PreToolUse, group index g, handler index h. Codex's trust
# hash is sha256 of the compact JSON, keys sorted at every level, of
#   {"event_name": "pre_tool_use", "matcher": <the group's, omitted when absent>,
#    "hooks": [{"type", "command", "timeout" (default 600), "async" (default false),
#               "statusMessage" and "additionalContextLimit" (each only when present)}]}
# which jq -cS prints the way serde does; the same figures were checked on 2026-11-02
# against every handler of a real hooks.json and config.toml (11 of 11). The stored hash is
# [hooks.state."<hooks.json as Codex names it>:pre_tool_use:<g>:<h>"].trusted_hash.
trust_check() { # hooks.json text
  local at g h key compact py p out stored enabled feature unknown want cfg="$codex_home/config.toml" fix
  trust_state="" trust_msg="" trust_fix=""
  fix="open /hooks in Codex and trust the Jarvis guard (until then Codex skips it)"
  at=$(jq -r '
    def own_h: (.command? // "") | contains("/hooks/jarvis-guard.py");
    first((.hooks.PreToolUse // []) | to_entries[] | .key as $g
          | ((.value.hooks // []) | to_entries[]) | select(.value | own_h) | [$g, .key]) // empty
    | @tsv' <<<"$1" 2>/dev/null) || at=""
  if [ -z "$at" ]; then
    trust_state=NOT-INSTALLED
    trust_msg="$hooks_named has no Jarvis guard entry under PreToolUse"
    trust_fix="run bash $here/scripts/apply-codex-guard.sh to install it, then $fix"
    return 0
  fi
  g=${at%%$'\t'*} h=${at##*$'\t'}
  key="$hooks_named:pre_tool_use:$g:$h"
  # A key this formula does not know may be part of Codex's hash (additionalContextLimit was added
  # that way), so the answer would be a guess: refuse to give one. A null value counts as absent.
  unknown=$(jq -r --argjson g "$g" --argjson h "$h" '
    (.hooks.PreToolUse[$g].hooks[$h] | with_entries(select(.value != null)) | keys)
    - ["type", "command", "timeout", "async", "statusMessage", "additionalContextLimit"] | join(", ")' <<<"$1")
  if [ -n "$unknown" ]; then
    trust_state=UNVERIFIABLE
    trust_msg="could not verify whether Codex trusts the entry $key: it has the key(s) $unknown, which this script's hash formula does not know, and Codex may count them"
    trust_fix="check with Codex (/hooks shows whether it trusts the entry), and update trust_check in $here/scripts/apply-codex-guard.sh to the formula of this Codex"
    return 0
  fi
  # Codex hashes the compact JSON with keys sorted; jq -cS prints it the same way, with one known
  # difference: jq writes U+007F as \u007f where serde writes the raw character, so a command that
  # contains DEL would hash differently here. Not handled.
  compact=$(jq -cS --argjson g "$g" --argjson h "$h" '
    .hooks.PreToolUse[$g] as $grp | ($grp.hooks[$h] | with_entries(select(.value != null))) as $x |
    {event_name: "pre_tool_use"}
    + (if ($grp.matcher // null) != null then {matcher: $grp.matcher} else {} end)
    + {hooks: [{type: $x.type, command: $x.command, timeout: ($x.timeout // 600), async: ($x.async // false)}
               + (if $x | has("statusMessage") then {statusMessage: $x.statusMessage} else {} end)
               + (if $x | has("additionalContextLimit") then {additionalContextLimit: $x.additionalContextLimit} else {} end)]}' <<<"$1")
  py=""
  for p in $(type -ap python3 python3.14 python3.13 python3.12 python3.11 2>/dev/null); do
    if "$p" -I -c 'import tomllib' 2>/dev/null; then py=$p; break; fi
  done
  if [ -z "$py" ]; then
    trust_state=UNVERIFIABLE
    trust_msg="could not verify whether Codex trusts the entry $key: reading $cfg needs a python3 with tomllib (Python 3.11 or newer) on PATH"
    trust_fix="install Python 3.11 or newer (macOS: brew install python@3.13) so that python3 on PATH has tomllib, then run this again"
    return 0
  fi
  if ! out=$("$py" -I -c '
import hashlib, sys, tomllib
compact, cfg, key = sys.argv[1:4]
try:
    with open(cfg, "rb") as fh:
        data = tomllib.load(fh)
except FileNotFoundError:
    data = {}
node = data
for part in ("hooks", "state"):
    node = node.get(part, {}) if isinstance(node, dict) else {}
entry = node.get(key, {}) if isinstance(node, dict) else {}
if not isinstance(entry, dict):
    entry = {}
stored = entry.get("trusted_hash", "")
features = data.get("features", {})
off = ""
if isinstance(features, dict):
    for name in ("hooks", "codex_hooks"):
        if features.get(name) is False:
            off = name
            break
print("sha256:" + hashlib.sha256(compact.encode("utf-8")).hexdigest())
print(stored if isinstance(stored, str) else "")
print("false" if entry.get("enabled") is False else "")
print(off)
' "$compact" "$cfg" "$key" 2>&1); then
    trust_state=UNVERIFIABLE
    trust_msg="could not verify whether Codex trusts the entry $key: $cfg could not be read as TOML (${out##*$'\n'})"
    trust_fix="fix $cfg by hand, then run this again"
    return 0
  fi
  want=$(sed -n 1p <<<"$out"); stored=$(sed -n 2p <<<"$out"); enabled=$(sed -n 3p <<<"$out"); feature=$(sed -n 4p <<<"$out")
  if [ -n "$feature" ]; then
    trust_state=DISABLED
    trust_msg="$cfg has $feature = false under [features], which turns off every Codex hook, so Codex skips the Jarvis guard"
    trust_fix="remove $feature = false from [features] in $cfg (or set it to true), then check /hooks"
  elif [ "$enabled" = false ]; then
    trust_state=DISABLED
    trust_msg="Codex has the Jarvis guard entry $key switched off (enabled = false in $cfg), so it skips it"
    trust_fix="enable (and trust) the Jarvis guard in /hooks"
  elif [ -z "$stored" ]; then
    trust_state=UNTRUSTED
    trust_msg="$cfg has no trusted_hash for the Jarvis guard entry $key, so Codex skips it"
    trust_fix="$fix"
  elif [ "$stored" != "$want" ]; then
    trust_state=UNTRUSTED
    trust_msg="the trusted_hash for $key in $cfg is not the hash of the entry now in $hooks_named (the entry changed since it was trusted), so Codex skips it"
    trust_fix="$fix"
  else
    trust_state=OK
    trust_msg="Codex trusts the Jarvis guard entry $key"
  fi
}

switch_word() { if [ "$sw" = 1 ]; then echo on; else echo off; fi; }
trust_print() {
  echo "apply-codex-guard: trust: $trust_state - $trust_msg"
  [ -z "$trust_fix" ] || echo "apply-codex-guard: fix: $trust_fix"
}

warn_codex_off() {
  [ "$warn_off" = 1 ] || return 0
  echo "apply-codex-guard: WARN: Claude Code's agent-identity switch is on ($claude_req), but this install starts Codex's off, so Codex GitHub writes are not covered; turn it on with bash $here/scripts/apply-codex-guard.sh --require-identity (and trust the guard in /hooks), or bash $here/scripts/apply-agent-identity.sh --require"
}

if [ "$trust_only" = 1 ]; then
  trust_check "$current"
  trust_print
  [ "$trust_state" = OK ]
  exit $?
fi

if [ "$check" = 1 ]; then
  bad=0
  if [ "$same" = 1 ] && [ "$hook_same" = 1 ]; then
    echo "apply-codex-guard: $hooks_json and $hook_dst already carry the guard"
  else
    bad=1
    if [ "$same" = 0 ]; then
      echo "apply-codex-guard: $hooks_json differs from the guard:"
      diff <(jq -S . <<<"$current") <(jq -S . <<<"$merged") || true
    fi
    [ "$hook_same" = 1 ] || echo "apply-codex-guard: $hook_dst differs from $hook_src"
  fi
  echo "apply-codex-guard: the agent-identity switch is $(switch_word) in the hook command"
  warn_codex_off
  trust_check "$current"
  trust_print
  [ "$trust_state" = OK ] || bad=1
  exit "$bad"
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
echo "apply-codex-guard: the agent-identity switch is $(switch_word) in the hook command"
warn_codex_off
# What was just written (or was already there) is what Codex reads next.
trust_check "$merged"
trust_print
