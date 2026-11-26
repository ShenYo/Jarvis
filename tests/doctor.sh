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

# --- not installed, and partial ----------------------------------------------
h="$root/empty"; cx="$h/.codex"; mkdir -p "$h"
run empty
expect "not installed: exit 0, one summary line with the setup guide, no PROBLEM and no check line" bash -c "
  grep -q '^doctor: Jarvis is not installed on this machine.*Next: see docs/setup-new-machine.md' '$log' &&
  ! grep -Eq '^(PROBLEM|ok|ERROR) ' '$log' && [ '$code' = 0 ]"
mkdir -p "$cx/hooks"; : >"$cx/hooks/jarvis-guard.py"
run empty
expect "not installed: a Codex guard left behind is a note, not a failure" bash -c "
  [ '$code' = 0 ] && grep -q '^note: the Codex guard is still installed' '$log'"

h="$root/partial"; cx="$h/.codex"; mkdir -p "$h"
ln -s "$repo" "$h/.Jarvis"
HOME="$h" CODEX_HOME="$cx" bash "$repo/scripts/apply-claude-guard.sh" >"$h.setup" 2>&1
run partial
expect "partial (only the guard record): still exit 1 with PROBLEM, not the not-installed line" bash -c "
  [ '$code' = 1 ] && grep -Eq '^PROBLEM +bridge ' '$log' && ! grep -q 'is not installed' '$log'"

# partial <name> <what is left>: a machine with only that left is an install, so doctor judges it: exit 1, no
# not-installed line. bare <name> makes the sandbox (HOME with ~/.Jarvis); $cfg is its Claude config dir.
bare() { h="$root/$1"; cx="$h/.codex"; cfg="$h/.claude"; mkdir -p "$h"; ln -s "$repo" "$h/.Jarvis"; runenv=""; }
inst_guard() { HOME="$h" CODEX_HOME="$cx" ${runenv:+env $runenv} bash "$repo/scripts/apply-claude-guard.sh" >>"$h.setup" 2>&1; }
inst_bridge() { HOME="$h" CODEX_HOME="$cx" bash "$repo/sync-personal-skills.sh" >>"$h.setup" 2>&1; }
partial() { # <name> <what>
  run "$1"
  expect "partial, $2: exit 1 and not reported as not installed" bash -c "[ '$code' = 1 ] && ! grep -q 'is not installed' '$log'"
}
bare unrelated; mkdir "$h/.agents"; run unrelated
expect "not installed: an unrelated ~/.agents directory is not evidence" bash -c "[ '$code' = 0 ] && grep -q 'is not installed' '$log'"
bare unrelated-file; : >"$h/.agents"; run unrelated-file
expect "not installed: an unrelated ~/.agents file is not evidence" bash -c "[ '$code' = 0 ] && grep -q 'is not installed' '$log'"
bare foreign-link; mkdir -p "$h/.claude/skills" "$h/other"; ln -s "$h/other" "$h/.claude/skills/theirs"; ln -s "$h/other" "$h/.claude/CLAUDE.md"; run foreign-link
expect "not installed: a person's own links elsewhere are not evidence" bash -c "[ '$code' = 0 ] && grep -q 'is not installed' '$log'"
bare idcfg-only; printf 'login=x\n' >"$h/cfgfile"; identity="$h/cfgfile"; run idcfg-only; identity=""
expect "not installed: an identity config file alone is not evidence" bash -c "[ '$code' = 0 ] && grep -q 'is not installed' '$log'"

bare p-norecord; inst_guard; rm -f "$cfg/claude-guard.applied.json"; partial p-norecord "guard entries and hooks without the record"
bare p-links; inst_bridge; rm "$h/.agents"; partial p-links "skill links and CLAUDE.md without ~/.agents"
bare p-hooks; inst_guard; rm -f "$cfg/claude-guard.applied.json"; echo '{}' >"$cfg/settings.json"; partial p-hooks "hook copies only"
bare p-entries; inst_guard; rm -f "$cfg/claude-guard.applied.json" "$cfg"/hooks/*.py; partial p-entries "settings hook entries only"
bare p-claudeid; mkdir -p "$cfg"; echo '{}' >"$cfg/agent-identity.applied.json"; partial p-claudeid "a Claude identity record"
bare p-codexid; mkdir -p "$cx"; echo '{}' >"$cx/agent-identity.applied.json"; partial p-codexid "a Codex identity record"
bare p-dangling; ln -s "$h/nowhere" "$h/.agents"; partial p-dangling "a dangling ~/.agents link"
bare p-md; mkdir -p "$cfg"; ln -s ../.agents/AGENTS.md "$cfg/CLAUDE.md"; partial p-md "a dangling CLAUDE.md link into ~/.agents"
bare p-skill; mkdir -p "$cfg/skills"; ln -s ../../.agents/skills/x "$cfg/skills/x"; partial p-skill "one dangling skill link"
bare p-require; mkdir -p "$cfg"; echo '{}' >"$cfg/agent-identity.require.json"; partial p-require "an identity switch record"
bare p-switch; mkdir -p "$cfg"; echo '{"env":{"JARVIS_REQUIRE_AGENT_IDENTITY":"1"}}' >"$cfg/settings.json"; partial p-switch "the switch in settings"
bare p-cfgdir; mkdir -p "$h/elsewhere"; runenv="CLAUDE_CONFIG_DIR=$h/elsewhere"; cfg="$h/elsewhere"; inst_guard; rm -f "$cfg/hooks/"*.py; echo '{}' >"$cfg/settings.json"
partial p-cfgdir "the guard record under CLAUDE_CONFIG_DIR"
runenv=""

# A skills-CLI layout, with no Jarvis anywhere: a real ~/.agents holding the person's own skills, and links
# that spell the same text as Jarvis's bridge. They resolve into that directory, not into a Jarvis checkout.
bare cli-layout; mkdir -p "$h/.agents/skills/foo" "$h/.claude/skills" "$cx/skills"; : >"$h/.agents/AGENTS.md"
ln -s ../../.agents/skills/foo "$h/.claude/skills/foo"; ln -s ../.agents/AGENTS.md "$h/.claude/CLAUDE.md"
ln -s ../../.agents/skills/foo "$cx/skills/foo"; ln -s ../.agents/AGENTS.md "$cx/AGENTS.md"
run cli-layout
expect "not installed: a skills CLI's own ~/.agents with links of the same spelling is not evidence" bash -c "
  [ '$code' = 0 ] && grep -q 'is not installed' '$log'"

bare p-envswitch; runenv="JARVIS_REQUIRE_AGENT_IDENTITY=1"; partial p-envswitch "the switch in the environment"; runenv=""
bare p-cxmd; mkdir -p "$cx"; ln -s ../.agents/AGENTS.md "$cx/AGENTS.md"; partial p-cxmd "a Codex AGENTS.md link into ~/.agents"
bare p-linkdir; mkdir -p "$h/real" "$h/.claude"; ln -s "$h/real" "$h/.claude/skills"
ln -s "$(find "$repo/.agents/skills" -mindepth 1 -maxdepth 2 -name SKILL.md | head -1 | xargs dirname)" "$h/real/x"
partial p-linkdir "a Jarvis skill link inside a skills directory that is itself a link"
hooks_json='{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"python3 /x/hooks/jarvis-guard.py --codex%s"}]}]}}'
bare p-reqid; mkdir -p "$cx"; printf "$hooks_json" ' --require-identity' >"$cx/hooks.json"; partial p-reqid "the Codex hook with --require-identity"
bare c-reqoff; mkdir -p "$cx"; printf "$hooks_json" '' >"$cx/hooks.json"; run c-reqoff
expect "not installed: a Codex hook entry without --require-identity is not evidence" bash -c "[ '$code' = 0 ] && grep -q 'is not installed' '$log'"
bare p-alias; ln -s "$repo" "$h/jv-checkout"; ln -s "$repo/.agents" "$h/alias"; mkdir -p "$h/.claude/skills"
ln -s "$h/alias/skills/$(find "$repo/.agents/skills" -mindepth 1 -maxdepth 2 -name SKILL.md | head -1 | xargs dirname | xargs basename)" "$h/.claude/skills/x"
doctor_was=$doctor; doctor="$h/jv-checkout/scripts/doctor.sh"; partial p-alias "a link by another spelling, doctor run through a linked checkout path"; doctor=$doctor_was
nojq="$root/nojq"; mkdir -p "$nojq"
for t in bash sh env git sed grep egrep awk cat cksum cmp diff find sort tr head tail mktemp cp mv rm dirname basename \
         readlink wc shasum sha256sum stat ls mkdir ln cut date uname tee true false test xargs rmdir chmod pwd; do
  p=$(command -v "$t" 2>/dev/null) && [ -x "$p" ] && ln -sf "$p" "$nojq/$t"
done
bare p-nojq; runpath=$nojq; run p-nojq; runpath=""
expect "no jq: doctor does not claim not installed; the checks report the missing jq (exit 2)" bash -c "
  [ '$code' = 2 ] && ! grep -q 'is not installed' '$log' && grep -q '^ERROR' '$log'"

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
  ! grep -q 'rulesets are not readable' '$log' &&
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

# --- the same Skill name offered by two providers ----------------------------
# A name the bridge links into ~/.claude/skills and a plugin, a synced bundle or Codex's .system tree offers too.
fixture dup-ok
run dup-ok
expect "no duplicate Skill name on a bridged machine: dup-skills and dup-codex are ok, exit 0" bash -c "
  test '$code' = 0 && grep -Eq '^ok +dup-skills +no Skill name is offered by more than one provider' '$log' &&
  grep -Eq '^ok +dup-codex ' '$log'"

# plugin_with <home> <key> <enabled> <skill dir name> <name:>: an installed plugin that offers one Skill.
plugin_with() {
  local home=$1 key=$2 on=$3 dir=$4 nm=$5 ip="$1/plugins-src/$2"
  put "$ip/skills/$dir/SKILL.md" $'---\nname: '"$nm"$'\ndescription: seeded\n---\nbody\n'
  put "$home/.claude/plugins/installed_plugins.json" "$(jq -n --arg k "$key" --arg p "$ip" '{version: 2, plugins: {($k): [{scope: "user", installPath: $p}]}}')"
  jq --arg k "$key" --argjson on "$on" '.enabledPlugins = ((.enabledPlugins // {}) + {($k): $on})' "$home/.claude/settings.json" >"$home/s.new" &&
    cat "$home/s.new" >"$home/.claude/settings.json"
}
skill_a=$(ls "$repo/.agents/skills" | head -1)

fixture dup-plugin; plugin_with "$h" demo@market true "$skill_a" "$skill_a"; run dup-plugin
expect "an enabled plugin offers a bridged Skill's name: dup-skills is UNVERIFIED naming both providers, exit 0" bash -c "
  test '$code' = 0 && grep -Eq '^UNVERIFIED +dup-skills +1 Skill name' '$log' &&
  grep -Eq '\| $skill_a: personal, plugin demo@market' '$log' && ! grep -q '^PROBLEM' '$log'"
expect "an enabled plugin offers a bridged Skill's name: the Codex line is not affected" grep -Eq '^ok +dup-codex ' "$log"
expect "the summary counts equal the result lines of each kind (a dup finding and a dup ok included)" bash -c "
  for w in ok skipped UNVERIFIED; do
    n=\$(grep -Ec \"^\$w +\" '$log'); grep -Eq \"\\(?\$n \$w[,)]\" <(grep '^doctor:' '$log') || { echo \"\$w: \$n lines, summary: \$(grep '^doctor:' '$log')\"; exit 1; }
  done"

fixture dup-plugin-off; plugin_with "$h" demo@market false "$skill_a" "$skill_a"; run dup-plugin-off
expect "a disabled plugin with the same name is not offered: dup-skills is ok" grep -Eq '^ok +dup-skills ' "$log"

fixture dup-plugin-name; plugin_with "$h" demo@market true other-dir "$skill_a"; run dup-plugin-name
expect "the name comes from the frontmatter, not the directory: a plugin directory named otherwise still collides" grep -Eq "\| $skill_a: personal, plugin demo@market" "$log"

fixture dup-plugin-versions; plugin_with "$h" demo@market true "$skill_a" other-name
put "$h/plugins-src/demo@market-v2/skills/other-name/SKILL.md" $'---\nname: other-name\n---\n'
jq -n --arg p1 "$h/plugins-src/demo@market" --arg p2 "$h/plugins-src/demo@market-v2" \
  '{version: 2, plugins: {"demo@market": [{installPath: $p1}, {installPath: $p2}]}}' >"$h/.claude/plugins/installed_plugins.json"
run dup-plugin-versions
expect "two installed versions of one plugin are one provider: not a duplicate" grep -Eq '^ok +dup-skills ' "$log"

fixture dup-two-plugins; plugin_with "$h" one@market true shared shared
put "$h/plugins-src/two@market/skills/shared/SKILL.md" $'---\nname: shared\n---\n'
jq -n --arg p1 "$h/plugins-src/one@market" --arg p2 "$h/plugins-src/two@market" \
  '{version: 2, plugins: {"one@market": [{installPath: $p1}], "two@market": [{installPath: $p2}]}}' >"$h/.claude/plugins/installed_plugins.json"
jq '.enabledPlugins["two@market"] = true' "$h/.claude/settings.json" >"$h/s.new" && cat "$h/s.new" >"$h/.claude/settings.json"
run dup-two-plugins
expect "two enabled plugins offering one name: UNVERIFIED, exit 0, not a PROBLEM" bash -c "
  test '$code' = 0 && grep -Eq '\| shared: plugin one@market, plugin two@market' '$log' && ! grep -q '^PROBLEM' '$log'"

fixture dup-synced
put "$h/.claude/skills/synced/bucket/$skill_a/SKILL.md" $'---\nname: '"$skill_a"$'\n---\n'
put "$h/.claude/plugins/synced/bucket/eng/skills/$skill_a/SKILL.md" $'---\nname: '"$skill_a"$'\n---\n'
run dup-synced
expect "Skills Anthropic syncs, as a bundle and inside a plugin, collide with a bridged name" bash -c "
  grep -Eq '\| $skill_a: Anthropic synced Skill, Anthropic synced plugin eng, personal' '$log'"

fixture dup-codex
put "$cx/skills/.system/$skill_a/SKILL.md" $'---\nname: '"$skill_a"$'\n---\n'
run dup-codex
expect "a Codex system Skill with a bridged name: dup-codex is UNVERIFIED naming both, dup-skills is not affected" bash -c "
  test '$code' = 0 && grep -Eq '^UNVERIFIED +dup-codex ' '$log' && grep -Eq '\| $skill_a: Codex system Skill, personal' '$log' &&
  grep -Eq '^ok +dup-skills ' '$log'"

fixture dup-nocodex nocodex; run dup-nocodex
expect "no Codex home: dup-codex is skipped" grep -Eq '^skipped +dup-codex ' "$log"

fixture dup-badjson; plugin_with "$h" demo@market true "$skill_a" "$skill_a"; printf 'not json\n' >"$h/.claude/settings.json"; run dup-badjson
expect "settings.json that is not JSON: dup-skills is UNVERIFIED saying plugins went unchecked, not ok" grep -Eq '^UNVERIFIED +dup-skills .*plugin Skills went unchecked' "$log"

fixture dup-badplugins; plugin_with "$h" demo@market true "$skill_a" "$skill_a"; printf 'not json\n' >"$h/.claude/plugins/installed_plugins.json"; run dup-badplugins
expect "installed_plugins.json that is not JSON: dup-skills is UNVERIFIED saying plugins went unchecked, not ok" grep -Eq '^UNVERIFIED +dup-skills .*installed_plugins.json.*plugin Skills went unchecked' "$log"

fixture dup-space
plugin_with "$h" demo@market true "$skill_a" "$skill_a"
mkdir -p "$h/plugins src/demo market"
cp -R "$h/plugins-src/demo@market/skills" "$h/plugins src/demo market/skills"
jq -n --arg p "$h/plugins src/demo market" '{version: 2, plugins: {"demo@market": [{installPath: $p}]}}' >"$h/.claude/plugins/installed_plugins.json"
run dup-space
expect "a plugin install path with a space is read whole: its duplicate name is found" grep -Eq "\| $skill_a: personal, plugin demo@market" "$log"

fixture dup-crlf; plugin_with "$h" demo@market true other-dir "$skill_a"
printf -- '---\r\nname: %s\r\ndescription: seeded\r\n---\r\nbody\r\n' "$skill_a" >"$h/plugins-src/demo@market/skills/other-dir/SKILL.md"
run dup-crlf
expect "a CRLF frontmatter name that differs from its directory name still collides" grep -Eq "\| $skill_a: personal, plugin demo@market" "$log"

fixture dup-body-name; plugin_with "$h" demo@market true other-dir other-name
printf -- '---\ndescription: no name here\n---\nname: %s\n' "$skill_a" >"$h/plugins-src/demo@market/skills/other-dir/SKILL.md"
run dup-body-name
expect "a name: line in the body, after the frontmatter, is ignored" grep -Eq '^ok +dup-skills ' "$log"

fixture dup-second-version; plugin_with "$h" demo@market true v1dir v1name
put "$h/plugins-src/demo@market-v2/skills/$skill_a/SKILL.md" $'---\nname: '"$skill_a"$'\n---\n'
jq -n --arg p1 "$h/plugins-src/demo@market" --arg p2 "$h/plugins-src/demo@market-v2" \
  '{version: 2, plugins: {"demo@market": [{installPath: $p1}, {installPath: $p2}]}}' >"$h/.claude/plugins/installed_plugins.json"
run dup-second-version
expect "only the second installed version offers the duplicated name: it is still found" grep -Eq "\| $skill_a: personal, plugin demo@market" "$log"

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

# --- agy instructions link ---------------------------------------------------
fixture agy-ok
mkdir -p "$h/.gemini/config"
HOME="$h" CODEX_HOME="$cx" bash "$repo/sync-personal-skills.sh" >>"$root/agy-ok.setup" 2>&1
run agy-ok
expect "agy link ok: doctor exits 0 and bridge is ok" bash -c "
  [ $code = 0 ] && [ -L '$h/.gemini/config/AGENTS.md' ] &&
  [ \"\$(readlink '$h/.gemini/config/AGENTS.md')\" = '../../.agents/AGENTS.md' ] &&
  grep -Eq '^ok +bridge ' '$log'"

rm "$h/.gemini/config/AGENTS.md"
run agy-missing
expect "agy link missing: doctor exits 1 and reports MISSING for ~/.gemini/config/AGENTS.md" bash -c "
  [ $code = 1 ] && grep -Eq '^PROBLEM +bridge ' '$log' && grep -q 'MISSING  .*\.gemini/config/AGENTS\.md' '$log'"

printf 'custom agy rules\n' >"$h/.gemini/config/AGENTS.md"
run agy-conflict
expect "agy link conflict: doctor exits 1 and reports CONFLICT for ~/.gemini/config/AGENTS.md" bash -c "
  [ $code = 1 ] && grep -Eq '^PROBLEM +bridge ' '$log' && grep -q 'CONFLICT .*\.gemini/config/AGENTS\.md' '$log'"

# Partial install: only ~/.gemini/config/AGENTS.md exists (no ~/.agents, no Claude/Codex).
h="$root/agy-only"; cx="$h/.codex"
mkdir -p "$h/.gemini/config"
ln -s "$repo" "$h/.Jarvis"
ln -s ../../.agents/AGENTS.md "$h/.gemini/config/AGENTS.md"
run agy-only
expect "agy-only partial install: doctor recognizes it as installed (not 'not installed') and exits 1" bash -c "
  [ $code = 1 ] && ! grep -q 'Jarvis is not installed' '$log' && grep -Eq '^PROBLEM +bridge ' '$log'"

# --- agy Skills native discovery and duplicates (dup-agy) --------------------
fixture dup-agy-none
run dup-agy-none
expect "no ~/.gemini/config: dup-agy is skipped" grep -Eq '^skipped +dup-agy ' "$log"

fixture dup-agy-ok
mkdir -p "$h/.gemini/config"
HOME="$h" CODEX_HOME="$cx" bash "$repo/sync-personal-skills.sh" >>"$root/dup-agy-ok.setup" 2>&1
run dup-agy-ok
expect "agy ok: dup-agy is ok, exits 0, and says agy reads ~/.agents/skills/ natively" bash -c "
  [ $code = 0 ] && grep -Eq '^ok +dup-agy .*agy reads ~/.agents/skills/ natively' '$log' && ! grep -q '^PROBLEM' '$log'"

fixture dup-agy-cfg
mkdir -p "$h/.gemini/config/skills"
HOME="$h" CODEX_HOME="$cx" bash "$repo/sync-personal-skills.sh" >>"$root/dup-agy-cfg.setup" 2>&1
ln -s "../../../.agents/skills/$skill_a" "$h/.gemini/config/skills/$skill_a"
run dup-agy-cfg
expect "agy duplicate in ~/.gemini/config/skills: dup-agy is UNVERIFIED (never PROBLEM), exit 0, names both providers" bash -c "
  [ $code = 0 ] && grep -Eq '^UNVERIFIED +dup-agy ' '$log' && ! grep -q '^PROBLEM' '$log' &&
  grep -Fq '| $skill_a: agy config (~/.gemini/config/skills), personal (~/.agents/skills)' '$log'"

fixture dup-agy-plugin
mkdir -p "$h/.gemini/config/plugins/demo-plug/skills/$skill_a"
HOME="$h" CODEX_HOME="$cx" bash "$repo/sync-personal-skills.sh" >>"$root/dup-agy-plugin.setup" 2>&1
printf -- '---\nname: %s\ndescription: plugin copy\n---\n' "$skill_a" >"$h/.gemini/config/plugins/demo-plug/skills/$skill_a/SKILL.md"
run dup-agy-plugin
expect "agy duplicate in ~/.gemini/config/plugins/*/skills: dup-agy is UNVERIFIED (never PROBLEM), exit 0, names both providers" bash -c "
  [ $code = 0 ] && grep -Eq '^UNVERIFIED +dup-agy ' '$log' && ! grep -q '^PROBLEM' '$log' &&
  grep -Fq '| $skill_a: agy plugin demo-plug, personal (~/.agents/skills)' '$log'"

echo
if [ "$fails" -gt 0 ]; then echo "$fails of $total failed"; exit 1; fi
echo "all $total passed"
