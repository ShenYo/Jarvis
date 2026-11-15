#!/usr/bin/env bash
# Tests for scripts/doctor.sh, the read-only aggregate of the machine checks.
#
# Every case builds a sandbox HOME (with CODEX_HOME inside it) whose ~/.Jarvis is
# a link to this checkout, and brings it to the state under test by running the
# real bridge and apply scripts in it. The real ~/.claude, ~/.codex and identity
# configuration are never read or written, and `ssh` and `gh` are stubs on PATH
# that fail and log, so no case needs a network or a credential.
#
# DOCTOR=<path> runs another script, e.g. an absent one, to show the cases fail
# before the code exists.
#
# Sandboxes are left in place; see tests/claude-guard.sh for why.
set -uo pipefail

# Hermetic: an agent session's identity environment must not reach the checks.
for v in $(compgen -e | grep -E '^(GIT_CONFIG_|GIT_AUTHOR_|GIT_COMMITTER_)'); do unset "$v"; done
unset GIT_SSH_COMMAND GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GH_CONFIG_DIR GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN \
  GITHUB_ENTERPRISE_TOKEN GH_HOST JARVIS_AGENT_IDENTITY JARVIS_REQUIRE_AGENT_IDENTITY CODEX_HOME CLAUDE_CONFIG_DIR \
  XDG_CONFIG_HOME JARVIS_AGENT_IDENTITY_FILE

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
doctor="${DOCTOR:-$repo/scripts/doctor.sh}"
root=$(mktemp -d "${TMPDIR:-/tmp}/doctor-test.XXXXXX") && [ -n "$root" ] || exit 1
root=$(cd -P "$root" && pwd -P) || exit 1
echo "sandboxes: $root"

# ssh and gh: never the real ones. Each call is logged; each fails.
mkdir -p "$root/bin"
for t in ssh gh; do
  printf '#!/bin/sh\necho "%s $*" >>"%s/net.log"\nexit 1\n' "$t" "$root" >"$root/bin/$t"
  chmod +x "$root/bin/$t"
done
export PATH="$root/bin:$PATH"

fails=0
total=0
ok()   { total=$((total + 1)); echo "ok   $1"; }
bad()  { total=$((total + 1)); fails=$((fails + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && [ -f "$2" ] && sed 's/^/     /' "$2" | head -14; }
expect() { # <name> <condition command...>; the log of the last run is $log
  local name=$1; shift
  if "$@"; then ok "$name"; else bad "$name" "$log"; fi
}

sha256_stdin() { shasum -a 256 2>/dev/null | cut -d' ' -f1 || sha256sum | cut -d' ' -f1; }

# trust <codex home>: record Codex's trust of the installed guard entry the way
# /hooks does (see tests/codex-guard.sh for where the formula comes from).
trust() {
  local d=$1 g h hash
  read -r g h < <(jq -r 'first(.hooks.PreToolUse | to_entries[] | .key as $g | .value.hooks | to_entries[]
    | select(.value.command | contains("/hooks/jarvis-guard.py")) | "\($g) \(.key)")' "$d/hooks.json")
  hash=$(jq -cS --argjson g "$g" --argjson h "$h" '.hooks.PreToolUse[$g] as $grp | $grp.hooks[$h] as $x
    | {event_name: "pre_tool_use", matcher: $grp.matcher,
       hooks: [{type: $x.type, command: $x.command, timeout: ($x.timeout // 600), async: ($x.async // false), statusMessage: $x.statusMessage}]}' \
    "$d/hooks.json" | tr -d '\n' | sha256_stdin)
  printf '\n[hooks.state."%s/hooks.json:pre_tool_use:%s:%s"]\ntrusted_hash = "sha256:%s"\n' "$(cd "$d" && pwd -P)" "$g" "$h" "$hash" >>"$d/config.toml"
}

# fixture <name> [nocodex]: a machine that is fully set up: Skills bridged, both
# guards installed, Codex trusting its guard. Sets $h (HOME) and $cx (CODEX_HOME).
fixture() {
  h="$root/$1"; cx="$h/.codex"
  mkdir -p "$h"
  ln -s "$repo" "$h/.Jarvis"
  [ "${2:-}" = nocodex ] || mkdir -p "$cx"
  HOME="$h" CODEX_HOME="$cx" bash "$repo/sync-personal-skills.sh" >"$root/$1.setup" 2>&1 || { echo "fixture $1: bridge failed"; sed 's/^/  /' "$root/$1.setup"; }
  HOME="$h" CODEX_HOME="$cx" bash "$repo/scripts/apply-claude-guard.sh" >>"$root/$1.setup" 2>&1 || echo "fixture $1: claude guard failed"
  if [ -d "$cx" ]; then
    HOME="$h" CODEX_HOME="$cx" bash "$repo/scripts/apply-codex-guard.sh" >>"$root/$1.setup" 2>&1 || echo "fixture $1: codex guard failed"
    trust "$cx"
  fi
}

# run <name>: doctor in that sandbox; sets $code and $log.
run() {
  log="$root/$1.log"
  env ${runenv:-} HOME="$h" CODEX_HOME="$cx" JARVIS_AGENT_IDENTITY_FILE="${identity:-$h/no-identity}" STUB_DIR="${stubdir:-}" \
    PATH="${runpath:-$PATH}" bash "$doctor" ${2:+"$2"} >"$log" 2>&1
  code=$?
}

line()    { grep -Eq "^$1 +$2 " "$log"; }          # <word> <check name>
live()    { line UNVERIFIED live-callback && grep -q 'docs/guard.md' "$log"; }
lastline() { tail -1 "$log"; }

# state <home>: everything under the sandbox home, links by target and files by
# content, without following ~/.Jarvis into the checkout.
state() { (cd "$1" && find . | sort | while IFS= read -r f; do
  if [ -L "$f" ]; then printf '%s -> %s\n' "$f" "$(readlink "$f")"
  elif [ -f "$f" ]; then printf '%s %s\n' "$f" "$(cksum <"$f")"
  else printf '%s dir\n' "$f"; fi; done); }
# repo_state: the checkout's status and the content of every modified or untracked file.
repo_state() {
  git -C "$repo" status --porcelain
  git -C "$repo" ls-files -m -o --exclude-standard | sort | while IFS= read -r f; do
    printf '%s %s\n' "$f" "$(cksum <"$repo/$f" 2>/dev/null || echo gone)"; done
  git -C "$repo" rev-parse HEAD
}

# The identity check's own stubs are the ones tests/agent-identity.sh uses, taken from it so that there is one
# copy: `ssh` and `gh` answer from files in $STUB_DIR, and nothing reaches a network.
mkdir -p "$root/idbin"
for t in ssh gh; do
  awk -v start="cat >\"\$root/bin/$t\" <<'EOF'" '$0 == start {f = 1; next} f && $0 == "EOF" {exit} f' \
    "$repo/tests/agent-identity.sh" >"$root/idbin/$t"
  [ -s "$root/idbin/$t" ] || echo "FAIL could not take the $t stub from tests/agent-identity.sh"
  chmod +x "$root/idbin/$t"
done
idpath="$root/idbin:$PATH"

put() { mkdir -p "$(dirname "$1")"; printf '%s' "$2" >"$1"; }

# ident_fixture <name>: a fully set-up machine that also has an identity configured, for both runtimes,
# every check passing against the stubs, and nothing applied yet. Sets $identity, $stubdir, $runpath.
ident_fixture() {
  fixture "$1"
  local st="$h/stub" cfgd="$h/idcfg"
  mkdir -p "$h/.ssh" "$cfgd" "$st/gh-agent" "$st/gh-operator"
  chmod 700 "$h/.ssh" "$cfgd"
  identity="$cfgd/agent-identity"
  cat >"$identity" <<'CFG'
login=bot-agent
email=1+bot-agent@users.noreply.github.com
ssh_key=~/.ssh/agent_key
gh_config_dir=~/.config/gh-agent
repos=acme/app
codex_ssh_key=~/.ssh/codex_key
CFG
  chmod 600 "$identity"
  for k in agent_key codex_key; do
    put "$h/.ssh/$k" "FAKE PRIVATE KEY"; chmod 600 "$h/.ssh/$k"
    put "$h/.ssh/$k.pub" "ssh-ed25519 AAAAFAKE bot-agent"
  done
  put "$st/ssh.out" "Hi bot-agent! You've successfully authenticated, but GitHub does not provide shell access."; put "$st/ssh.rc" 1
  put "$st/gh-agent/auth_status.out" $'github.com\n  \xe2\x9c\x93 Logged in to github.com account bot-agent (keyring)\n  - Active account: true'
  put "$st/gh-agent/user.out" "bot-agent"
  put "$st/gh-agent/repo.acme__app.out" '{"permissions":{"admin":false,"maintain":false,"push":true,"pull":true}}'
  put "$st/gh-agent/rulesets.acme__app.out" "[]"
  put "$st/gh-agent/invitations.out" "[]"
  put "$st/gh-operator/user.out" "owner-person"
  put "$st/ssh.default.out" "Hi owner-person! You've successfully authenticated, but GitHub does not provide shell access."; put "$st/ssh.default.rc" 1
  stubdir=$st runpath=$idpath
}
# ident_apply: apply the identity for both runtimes with the real script, as a person would.
ident_apply() {
  local a
  for a in "" --codex; do
    HOME="$h" CODEX_HOME="$cx" JARVIS_AGENT_IDENTITY_FILE="$identity" STUB_DIR="$stubdir" PATH="$runpath" \
      bash "$repo/scripts/apply-agent-identity.sh" ${a:+"$a"} >>"$h.setup" 2>&1 </dev/null ||
      { echo "fixture: applying the identity ${a:-for Claude Code} failed"; tail -5 "$h.setup"; }
  done
}
clear_ident() { identity="" stubdir="" runpath=""; }

# --- a correct machine -------------------------------------------------------
fixture good; run good
expect "correct setup: exit 0" test "$code" = 0
expect "correct setup: every check is ok, identity optional" bash -c "
  for c in bridge skill-lock claude-guard codex-guard; do grep -Eq \"^ok +\$c \" '$log' || exit 1; done
  grep -Eq '^skipped +identity .*not configured \\(optional\\)' '$log' && ! grep -q '^PROBLEM' '$log'"
expect "correct setup: live callback is UNVERIFIED" live
expect "correct setup: the last line is a summary with a next step" bash -c "tail -1 '$log' | grep -q '^doctor: no problem found.*Next:'"
expect "correct setup: no network call was made" test ! -e "$root/net.log"

# --- stale guard -------------------------------------------------------------
fixture stale-guard
printf '# drift\n' >>"$h/.claude/hooks/claude-guard.py"
run stale-guard
expect "stale guard: exit 1" test "$code" = 1
expect "stale guard: the Claude guard line is a PROBLEM with its fix command" bash -c "
  grep -Eq '^PROBLEM +claude-guard ' '$log' && grep -Eq 'fix: bash .*/scripts/apply-claude-guard.sh' '$log'"
expect "stale guard: the other checks still ran and passed" bash -c "grep -Eq '^ok +bridge ' '$log' && grep -Eq '^ok +codex-guard ' '$log'"
expect "stale guard: live callback is UNVERIFIED" live
expect "stale guard: the last line says Next with the fix" bash -c "tail -1 '$log' | grep -Eq '^doctor: 1 problem.*Next: bash .*apply-claude-guard.sh'"

# --- wrong-target Skill in the bridge ----------------------------------------
fixture wrong-target
skill=$(ls "$h/.claude/skills" | head -1)
rm "$h/.claude/skills/$skill"; mkdir -p "$h/elsewhere/$skill"; ln -s "$h/elsewhere/$skill" "$h/.claude/skills/$skill"
run wrong-target
expect "wrong-target Skill: exit 1" test "$code" = 1
expect "wrong-target Skill: the bridge line is a PROBLEM naming the CONFLICT" bash -c "
  grep -Eq '^PROBLEM +bridge ' '$log' && grep -q 'CONFLICT Claude Code' '$log' && grep -Eq 'fix: bash .*sync-personal-skills.sh' '$log'"
expect "wrong-target Skill: live callback is UNVERIFIED" live

# --- Codex trust missing, and hook disabled ----------------------------------
fixture untrusted
rm "$cx/config.toml"
run untrusted
expect "Codex trust missing: exit 1" test "$code" = 1
expect "Codex trust missing: the Codex guard line is a PROBLEM that says UNTRUSTED, and the fix is /hooks, not another apply" bash -c "
  grep -Eq '^PROBLEM +codex-guard ' '$log' && grep -q 'trust: UNTRUSTED' '$log' &&
  grep -Fq 'fix: open /hooks in Codex and trust (or enable) the Jarvis guard; the installed guard itself is current' '$log' &&
  ! grep -Eq 'fix: bash .*apply-codex-guard.sh' '$log'"
expect "Codex trust missing: live callback is UNVERIFIED" live

fixture disabled
printf '\n[features]\nhooks = false\n' >>"$cx/config.toml"
run disabled
expect "Codex hook disabled: exit 1 and the Codex guard line is a PROBLEM saying DISABLED" bash -c "
  test '$code' = 1 && grep -Eq '^PROBLEM +codex-guard ' '$log' && grep -q 'trust: DISABLED' '$log'"
expect "Codex hook disabled: live callback is UNVERIFIED" live

# --- no Codex ----------------------------------------------------------------
fixture nocodex nocodex; run nocodex
expect "no Codex home: exit 0 and the Codex guard line says it is not set up" bash -c "
  test '$code' = 0 && grep -Eq '^skipped +codex-guard .*not set up' '$log' && ! grep -q '^PROBLEM' '$log'"
expect "no Codex home: live callback is UNVERIFIED" live

# --- identity ----------------------------------------------------------------
fixture noident; run noident
expect "no identity configured: exit 0, both identity lines say optional and skipped" bash -c "
  test '$code' = 0 && grep -Eq '^skipped +identity +not configured \\(optional\\)' '$log' &&
  grep -Eq '^skipped +identity-codex +not configured \\(optional\\)' '$log'"

fixture ident-broken
printf 'login=\nnonsense\n' >"$h/identity-file"
identity="$h/identity-file"; run ident-broken; identity=""
expect "identity configured but broken: exit 1, a PROBLEM with its fix" bash -c "
  test '$code' = 1 && grep -Eq '^PROBLEM +identity ' '$log' && grep -Eq 'fix: bash .*apply-agent-identity.sh --check' '$log'"
expect "identity configured but broken: live callback is UNVERIFIED" live

# --- identity: applied, ready, stale, warned ---------------------------------
ident_fixture id-applied; name=id-applied; ident_apply; run id-applied
expect "identity applied: exit 0, both identity lines ok" bash -c "
  test '$code' = 0 && grep -Eq '^ok +identity ' '$log' && grep -Eq '^ok +identity-codex ' '$log' && ! grep -q '^PROBLEM' '$log'"
expect "identity applied: live callback is UNVERIFIED" live
clear_ident

ident_fixture id-ready; run id-ready
expect "identity configured, never applied: exit 1, a PROBLEM that says not applied, with the apply command" bash -c "
  test '$code' = 1 && grep -Eq '^PROBLEM +identity ' '$log' && grep -q 'state: ready' '$log' &&
  grep -Eq 'fix: bash .*apply-agent-identity.sh ' '$log' && grep -Eq '^PROBLEM +identity-codex ' '$log' &&
  grep -Eq 'fix: bash .*apply-agent-identity.sh --codex' '$log'"
expect "identity configured, never applied: live callback is UNVERIFIED" live
clear_ident

ident_fixture id-stale; name=id-stale; ident_apply
jq 'del(.env.GH_CONFIG_DIR)' "$h/.claude/settings.json" >"$h/s.new" && cat "$h/s.new" >"$h/.claude/settings.json"
run id-stale
expect "identity applied, then settings drifted: exit 1, the Claude identity line is a PROBLEM" bash -c "
  test '$code' = 1 && grep -Eq '^PROBLEM +identity ' '$log' && grep -q 'state: ready' '$log'"
clear_ident

# A permanent "was not checked" warning (rulesets unreadable) is UNVERIFIED and does not fail the run.
rulesets_unreadable() { put "$stubdir/gh-agent/rulesets.acme__app.out" '{"message":"Upgrade to GitHub Pro"}'; put "$stubdir/gh-agent/rulesets.acme__app.rc" 1; }
ident_fixture id-warn; name=id-warn; ident_apply
rulesets_unreadable
run id-warn; cp "$log" "$root/id-warn-only.log"
expect "identity applied with a permanent warning (rulesets unreadable): exit 0, UNVERIFIED with the count and the first warning, not ok" bash -c "
  test '$code' = 0 && grep -Eq '^UNVERIFIED +identity +passes, with 1 warning\\(s\\); first: repo acme/app: its rulesets are not readable' '$log' &&
  grep -q 'WARN  repo acme/app' '$log' && ! grep -Eq '^ok +identity ' '$log'"
# ... and the same machine with the switch on in one runtime only is a different result: a PROBLEM, exit 1.
jq '.env.JARVIS_REQUIRE_AGENT_IDENTITY = "1"' "$h/.claude/settings.json" >"$h/s.new" && cat "$h/s.new" >"$h/.claude/settings.json"
run id-warn
expect "a permanent warning plus a switch on in one runtime only: exit 1, a PROBLEM, not the same as the permanent warning alone" bash -c "
  test '$code' = 1 && grep -Eq '^PROBLEM +identity ' '$log' && grep -q 'WARN  agent-identity switch' '$log' &&
  ! cmp -s '$log' '$root/id-warn-only.log' && grep -Eq 'fix: bash .*apply-agent-identity.sh --check' '$log'"
clear_ident

# --- identity: evidence without a config file --------------------------------
fixture sw-on
printf '{"env":{"JARVIS_REQUIRE_AGENT_IDENTITY":"1"}}\n' >"$h/.claude/agent-identity.require.json"
run sw-on
expect "switch on, no config file: the identity is not skipped as optional; exit 1" bash -c "
  test '$code' = 1 && grep -Eq '^PROBLEM +identity ' '$log' && ! grep -Eq '^skipped +identity ' '$log'"
fixture sw-settings
jq '.env.JARVIS_REQUIRE_AGENT_IDENTITY = "1"' "$h/.claude/settings.json" >"$h/s.new" && cat "$h/s.new" >"$h/.claude/settings.json"
run sw-settings
expect "switch in settings.json, no config file: the identity is not skipped as optional; exit 1" bash -c "
  grep -Eq '^PROBLEM +identity ' '$log' && ! grep -Eq '^skipped +identity ' '$log'"
fixture sw-env
runenv="JARVIS_REQUIRE_AGENT_IDENTITY=1" run sw-env; runenv=""
expect "switch in the environment, no config file: the identity is not skipped as optional; exit 1" bash -c "
  test '$code' = 1 && grep -Eq '^PROBLEM +identity ' '$log' && ! grep -Eq '^skipped +identity ' '$log'"
fixture sw-codex
HOME="$h" CODEX_HOME="$cx" bash "$repo/scripts/apply-codex-guard.sh" --require-identity >"$h.setup2" 2>&1; trust "$cx"
run sw-codex
expect "switch on in the Codex hook only, no config file: not skipped as optional; exit 1" bash -c "
  test '$code' = 1 && grep -Eq '^PROBLEM +identity-codex ' '$log' && ! grep -Eq '^skipped +identity' '$log'"
fixture sw-home-record
mkdir -p "$h/other"; printf '{"env":{"JARVIS_REQUIRE_AGENT_IDENTITY":"1"}}\n' >"$h/.claude/agent-identity.require.json"
runenv="CLAUDE_CONFIG_DIR=$h/other" run sw-home-record; runenv=""
expect "require record in ~/.claude while CLAUDE_CONFIG_DIR points elsewhere: not skipped as optional" bash -c "
  grep -Eq '^PROBLEM +identity ' '$log' && ! grep -Eq '^skipped +identity ' '$log'"
fixture rec-only
printf '{}\n' >"$h/.claude/agent-identity.applied.json"
run rec-only
expect "an applied record, no config file: the identity is not skipped as optional; exit 1" bash -c "
  test '$code' = 1 && grep -Eq '^PROBLEM +identity ' '$log'"
fixture rec-codex
printf '{}\n' >"$cx/agent-identity.applied.json"
run rec-codex
expect "a Codex applied record, no config file: identity-codex runs and is a PROBLEM, identity stays optional" bash -c "
  test '$code' = 1 && grep -Eq '^PROBLEM +identity-codex ' '$log' && grep -Eq '^skipped +identity +not configured' '$log'"
fixture id-dir
mkdir -p "$h/identdir"; identity="$h/identdir"; run id-dir; identity=""
expect "identity path is a directory: the check runs and reports, it is not skipped" bash -c "
  test '$code' = 1 && grep -Eq '^PROBLEM +identity ' '$log' && ! grep -Eq '^skipped +identity ' '$log'"
fixture id-dangling
ln -s "$h/nowhere" "$h/identlink"; identity="$h/identlink"; run id-dangling; identity=""
expect "identity path is a dangling link: the check runs and reports, it is not skipped" bash -c "
  test '$code' = 1 && grep -Eq '^PROBLEM +identity ' '$log'"

# --- Codex guard: what is UNVERIFIED and what is a PROBLEM -------------------
# A PATH with the tools the checks need and a python3 that has no tomllib, so Codex's trust cannot be read.
nopy="$root/nopy"; mkdir -p "$nopy"
for t in bash sh env jq git sed grep egrep awk cat cksum cmp diff find sort tr head tail mktemp cp mv rm dirname basename \
         readlink wc shasum sha256sum stat ls mkdir ln cut date uname tee true false test xargs rmdir chmod pwd; do
  p=$(command -v "$t" 2>/dev/null) && [ -x "$p" ] && ln -sf "$p" "$nopy/$t"
done
printf '#!/bin/sh\nexit 1\n' >"$nopy/python3"; chmod +x "$nopy/python3"

fixture no-tomllib; runpath=$nopy; run no-tomllib; runpath=""
expect "no tomllib: the Codex guard line is UNVERIFIED, doctor exits 0" bash -c "
  test '$code' = 0 && grep -Eq '^UNVERIFIED +codex-guard ' '$log' && grep -q 'tomllib' '$log' && ! grep -q '^PROBLEM' '$log'"

# The same, with an applied identity: identity-codex says UNVERIFIED too, so the two lines agree.
nopy2="$root/nopy2"; mkdir -p "$nopy2"
for f in "$nopy"/*; do ln -sf "$(readlink "$f" 2>/dev/null || echo "$f")" "$nopy2/$(basename "$f")"; done
ln -sf "$root/idbin/ssh" "$nopy2/ssh"; ln -sf "$root/idbin/gh" "$nopy2/gh"
ident_fixture id-no-tomllib; ident_apply
runpath=$nopy2; run id-no-tomllib; runpath=""
expect "no tomllib with an applied identity: codex-guard and identity-codex are both UNVERIFIED, exit 0, and the line says config.toml went unchecked" bash -c "
  test '$code' = 0 && grep -Eq '^UNVERIFIED +codex-guard ' '$log' && grep -Eq '^UNVERIFIED +identity-codex .*config.toml could not be parsed' '$log' &&
  grep -q 'MISSING  no python3 with tomllib' '$log' && ! grep -q '^PROBLEM' '$log'"
clear_ident

ident_fixture id-nt-never
runpath=$nopy2; run id-nt-never; runpath=""
expect "no tomllib and the Codex identity never applied: identity-codex is a PROBLEM that says not applied, fix --codex" bash -c "
  test '$code' = 1 && grep -Eq '^PROBLEM +identity-codex .*not applied' '$log' && ! grep -Eq '^UNVERIFIED +identity-codex' '$log' &&
  grep -Eq 'fix: bash .*apply-agent-identity.sh --codex' '$log'"
clear_ident
ident_fixture id-nt-other; ident_apply
rm "$h/.ssh/codex_key"
runpath=$nopy2; run id-nt-other; runpath=""
expect "no tomllib and a failing line unrelated to tomllib beside it: identity-codex is a PROBLEM, not UNVERIFIED" bash -c "
  test '$code' = 1 && grep -Eq '^PROBLEM +identity-codex ' '$log' && ! grep -Eq '^UNVERIFIED +identity-codex' '$log'"
clear_ident
fixture no-tomllib-stale
printf '# drift\n' >>"$cx/hooks/jarvis-guard.py"
runpath=$nopy; run no-tomllib-stale; runpath=""
expect "no tomllib and a stale Codex guard: a PROBLEM, not UNVERIFIED" bash -c "
  test '$code' = 1 && grep -Eq '^PROBLEM +codex-guard ' '$log' && grep -Eq 'fix: bash .*apply-codex-guard.sh' '$log'"

fixture hook-unknown-key
jq '.hooks.PreToolUse |= map(.hooks |= map(if (.command // "" | contains("jarvis-guard.py")) then . + {futureKey: 1} else . end))' \
  "$cx/hooks.json" >"$h/hj.new" && cat "$h/hj.new" >"$cx/hooks.json"
run hook-unknown-key
expect "a key in the hook entry the trust formula does not know, with the entry stale: a PROBLEM" bash -c "
  test '$code' = 1 && grep -Eq '^PROBLEM +codex-guard ' '$log'"

fixture bad-toml
printf 'this is = not [valid\n' >"$cx/config.toml"
run bad-toml
expect "config.toml that does not parse: the Codex guard line is a PROBLEM, not UNVERIFIED" bash -c "
  test '$code' = 1 && grep -Eq '^PROBLEM +codex-guard ' '$log' && ! grep -Eq '^UNVERIFIED +codex-guard ' '$log'"

fixture stale-and-untrusted
printf '# drift\n' >>"$cx/hooks/jarvis-guard.py"; rm "$cx/config.toml"
run stale-and-untrusted
expect "a stale Codex guard that is also untrusted: the fix is to apply it, then trust" bash -c "
  grep -Eq 'fix: bash .*apply-codex-guard.sh   \(then open /hooks' '$log'"

# --- a check that cannot run -------------------------------------------------
fixture cannot-run
printf 'this is not json\n' >"$h/.claude/settings.json"
run cannot-run
expect "a check that exits 2 (settings.json is not JSON): doctor exits 2 and names the check" bash -c "
  test '$code' = 2 && grep -Eq '^ERROR +claude-guard ' '$log' && tail -1 '$log' | grep -q 'could not run 1 check(s) (first: claude-guard)'"
expect "a check that exits 2: the other checks still ran" bash -c "grep -Eq '^ok +bridge ' '$log' && grep -Eq '^UNVERIFIED +live-callback ' '$log'"

# --- a Skill changed in the working tree -------------------------------------
# The lock check reads HEAD; this checks the working tree. The checkout is the real one, so the change is made in a
# copy of the checkout's .agents/skills tree view: a scratch repository with the same layout.
scratch="$root/lockrepo"
mkdir -p "$scratch/scripts" "$scratch/.agents/skills"
cp "$repo/scripts/doctor.sh" "$repo/scripts/check-skill-lock.sh" "$repo/scripts/apply-claude-guard.sh" \
   "$repo/scripts/apply-codex-guard.sh" "$repo/scripts/apply-agent-identity.sh" "$scratch/scripts/"
cp "$repo/sync-personal-skills.sh" "$scratch/"
mkdir -p "$scratch/.agents/claude-guard"; cp "$repo"/.agents/claude-guard/* "$scratch/.agents/claude-guard/"
printf 'name: demo\n' >"$scratch/.agents/skills/SKILL.md" 2>/dev/null; rm -f "$scratch/.agents/skills/SKILL.md"
mkdir -p "$scratch/.agents/skills/demo" "$scratch/.agents/skills/session-notes"
printf 'name: demo\n' >"$scratch/.agents/skills/demo/SKILL.md"; printf 'name: session-notes\n' >"$scratch/.agents/skills/session-notes/SKILL.md"
printf 'rules\n' >"$scratch/.agents/AGENTS.md"
git -C "$scratch" init -q && git -C "$scratch" add -A >/dev/null 2>&1
git -C "$scratch" -c user.email=t@example.invalid -c user.name=t commit -qm base
tree=$(git -C "$scratch" rev-parse HEAD:.agents/skills/demo)
printf '{"skills":{"demo":{"skillFolderHash":"%s"}}}\n' "$tree" >"$scratch/.agents/.skill-lock.json"
git -C "$scratch" add -A >/dev/null 2>&1; git -C "$scratch" -c user.email=t@example.invalid -c user.name=t commit -qm lock
lock_run() { # <name>: doctor from the scratch repository, with a home whose ~/.Jarvis is that repository
  h="$root/$1"; cx="$h/.codex"; mkdir -p "$h" "$cx"; ln -s "$scratch" "$h/.Jarvis"
  HOME="$h" CODEX_HOME="$cx" bash "$scratch/sync-personal-skills.sh" >/dev/null 2>&1
  log="$root/$1.log"
  HOME="$h" CODEX_HOME="$cx" JARVIS_AGENT_IDENTITY_FILE="$h/no-identity" bash "$scratch/scripts/doctor.sh" >"$log" 2>&1; code=$?
}
lock_run lock-clean
expect "skill-lock in a scratch repository whose Skill matches its lock: ok" grep -Eq '^ok +skill-lock ' "$log"
printf 'patched\n' >>"$scratch/.agents/skills/demo/SKILL.md"
lock_run lock-patched
expect "a vendored Skill patched in the working tree: skill-lock is a PROBLEM although HEAD matches the lock" bash -c "
  grep -Eq '^PROBLEM +skill-lock ' '$log' && grep -q 'working tree' '$log'"
git -C "$scratch" checkout -q -- .agents/skills/demo/SKILL.md
printf 'x\n' >"$scratch/.agents/skills/demo/extra.md"
lock_run lock-untracked
expect "an untracked file in a Skill: skill-lock is a PROBLEM" grep -Eq '^PROBLEM +skill-lock ' "$log"
rm "$scratch/.agents/skills/demo/extra.md"
printf 'edited\n' >>"$scratch/.agents/skills/session-notes/SKILL.md"
lock_run lock-maintained
expect "an uncommitted edit to session-notes (maintained here, no lock entry) is not a PROBLEM" bash -c "
  grep -Eq '^ok +skill-lock ' '$log' && ! grep -Eq '^PROBLEM +skill-lock' '$log'"
printf 'patched\n' >>"$scratch/.agents/skills/demo/SKILL.md"
lock_run lock-both
expect "with session-notes edited too, a patched vendored Skill is still a PROBLEM" grep -Eq '^PROBLEM +skill-lock ' "$log"
git -C "$scratch" checkout -q -- .agents/skills

# --- terminal control characters in what is printed --------------------------
fixture ctrl
esc=$(printf '\033')
ln -s "$h/nowhere" "$h/.claude/skills/x${esc}[2Jy"
ln -s "$h/nowhere" "$h/.claude/skills/$(printf 'x\302\2332Jy')"
run ctrl
expect "a Skill entry whose name holds an escape character: doctor reports it without the escape character" bash -c "
  test '$code' = 1 && grep -Eq '^PROBLEM +bridge ' '$log' && grep -q 'DANGLING' '$log' && ! grep -q \"\$(printf '\\033')\" '$log'"
expect "a Skill entry whose name holds a C1 control character (UTF-8 U+009B): doctor reports it without that character" bash -c "
  grep -q 'DANGLING' '$log' && ! LC_ALL=C grep -q \"\$(printf '\\302\\233')\" '$log'"

# --- read-only ---------------------------------------------------------------
# A passing machine, a machine with every kind of fault, and one that was never
# set up (where a bridge run that is not a check would create every link).
fixture ro-good
fixture ro-faulty
printf '# drift\n' >>"$h/.claude/hooks/claude-guard.py"
rm "$cx/config.toml"
rm "$h/.claude/skills/$(ls "$h/.claude/skills" | head -1)"
fresh="$root/ro-fresh"; mkdir -p "$fresh/.codex"; ln -s "$repo" "$fresh/.Jarvis"; ln -s .Jarvis/.agents "$fresh/.agents"
for name in ro-good ro-faulty ro-fresh; do
  h="$root/$name"; cx="$h/.codex"
  before=$(state "$h"); rbefore=$(repo_state)
  run "$name"
  after=$(state "$h"); rafter=$(repo_state)
  expect "read-only on $name: the sandbox home is identical before and after" test "$before" = "$after"
  expect "read-only on $name: the checkout (status and content) is identical before and after" test "$rbefore" = "$rafter"
  expect "read-only on $name: live callback is UNVERIFIED" live
done
expect "read-only: the faulty and the fresh machine exit 1, the good one 0" bash -c "
  test \"\$(grep -c '^PROBLEM' '$root/ro-good.log')\" = 0 && grep -q '^PROBLEM' '$root/ro-faulty.log' && grep -q '^PROBLEM' '$root/ro-fresh.log'"

# --- usage -------------------------------------------------------------------
h="$root/good"; cx="$h/.codex"
log="$root/usage.log"
HOME="$h" CODEX_HOME="$cx" bash "$doctor" --bogus >"$log" 2>&1; c1=$?
HOME="$h" CODEX_HOME="$cx" bash "$doctor" "" extra >"$log.2" 2>&1; c2=$?
HOME="$h" CODEX_HOME="$cx" bash "$doctor" --help >"$log.3" 2>&1; c3=$?
expect "usage: an unknown argument exits 2, an empty plus an extra argument exits 2, --help exits 0" test "$c1$c2$c3" = 220
expect "usage: the two-argument case is refused for its count, not for an unknown flag" grep -q '^Usage:' "$log.2"

echo
if [ "$fails" -gt 0 ]; then echo "$fails of $total failed"; exit 1; fi
echo "all $total passed"
