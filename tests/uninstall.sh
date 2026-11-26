#!/usr/bin/env bash
# Tests for scripts/uninstall.sh, the inverse of the three installers.
#
# One sandbox: a temporary HOME whose ~/.Jarvis is a link to this checkout, a
# CLAUDE_CONFIG_DIR of its own (apart from ~/.claude, as the installers use them
# apart), CODEX_HOME inside the HOME, and GIT_CONFIG_GLOBAL inside the HOME. The
# real installers bring it up, a person's own rule and a foreign link are added,
# and the uninstaller runs against it. The real home is never read or written;
# the test refuses to run when the sandbox HOME is the real one.
#
# UNINSTALL=<path> runs another script, e.g. a mutant, to show the cases fail.
#
# The sandbox is left in place; see tests/claude-guard.sh for why.
set -uo pipefail

real_home=$(cd -P "$HOME" 2>/dev/null && pwd -P) || real_home=$HOME

# Hermetic: an agent session's identity environment must not reach the scripts.
for v in $(compgen -e | grep -E '^(GIT_CONFIG_|GIT_AUTHOR_|GIT_COMMITTER_)'); do unset "$v"; done
unset GIT_SSH_COMMAND GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GH_CONFIG_DIR GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN \
  GITHUB_ENTERPRISE_TOKEN GH_HOST JARVIS_AGENT_IDENTITY JARVIS_REQUIRE_AGENT_IDENTITY CODEX_HOME CLAUDE_CONFIG_DIR \
  XDG_CONFIG_HOME JARVIS_AGENT_IDENTITY_FILE

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
uninstall="${UNINSTALL:-$repo/scripts/uninstall.sh}"
root=$(mktemp -d "${TMPDIR:-/tmp}/uninstall-test.XXXXXX") && [ -n "$root" ] || exit 1
root=$(cd -P "$root" && pwd -P) || exit 1
H="$root/home"
if [ "$H" = "$real_home" ] || [ "$root" = "$real_home" ]; then echo "refusing: the sandbox is the real home" >&2; exit 2; fi
echo "sandbox: $root"

mkdir -p "$H/.codex" "$H/.ssh" "$H/idcfg" "$H/stub/gh-agent" "$H/stub/gh-operator" "$root/bin"
chmod 700 "$H/.ssh" "$H/idcfg"
ln -s "$repo" "$H/.Jarvis"
CFG="$root/claude-cfg"; mkdir -p "$CFG"
CX="$H/.codex"
IDENT="$H/idcfg/agent-identity"

# Every run of anything under test goes through here: nothing reads the real home.
sbx() {
  env HOME="$H" CLAUDE_CONFIG_DIR="$CFG" CODEX_HOME="$CX" GIT_CONFIG_GLOBAL="$H/.gitconfig" \
    JARVIS_AGENT_IDENTITY_FILE="$IDENT" STUB_DIR="$H/stub" PATH="$root/bin:$PATH" "$@"
}

fails=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; fails=$((fails + 1)); [ -n "${2:-}" ] && [ -f "$2" ] && sed 's/^/     /' "$2" | head -20; }
expect() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name" "${log:-}"; fi; }

# ssh and gh for the identity script: the stubs tests/agent-identity.sh keeps, so there is one copy.
for t in ssh gh; do
  awk -v start="cat >\"\$root/bin/$t\" <<'EOF'" '$0 == start {f = 1; next} f && $0 == "EOF" {exit} f' \
    "$repo/tests/agent-identity.sh" >"$root/bin/$t"
  [ -s "$root/bin/$t" ] || { echo "FAIL could not take the $t stub from tests/agent-identity.sh"; exit 1; }
  chmod +x "$root/bin/$t"
done
put() { mkdir -p "$(dirname "$1")"; printf '%s' "$2" >"$1"; }
cat >"$IDENT" <<'CFG'
login=bot-agent
email=1+bot-agent@users.noreply.github.com
ssh_key=~/.ssh/agent_key
gh_config_dir=~/.config/gh-agent
repos=acme/app
codex_ssh_key=~/.ssh/codex_key
CFG
chmod 600 "$IDENT"
for k in agent_key codex_key; do
  put "$H/.ssh/$k" "FAKE PRIVATE KEY"; chmod 600 "$H/.ssh/$k"; put "$H/.ssh/$k.pub" "ssh-ed25519 AAAAFAKE bot-agent"
done
st="$H/stub"
put "$st/ssh.out" "Hi bot-agent! You've successfully authenticated, but GitHub does not provide shell access."; put "$st/ssh.rc" 1
put "$st/gh-agent/auth_status.out" $'github.com\n  \xe2\x9c\x93 Logged in to github.com account bot-agent (keyring)\n  - Active account: true'
put "$st/gh-agent/user.out" "bot-agent"
put "$st/gh-agent/repo.acme__app.out" '{"permissions":{"admin":false,"maintain":false,"push":true,"pull":true}}'
put "$st/gh-agent/rulesets.acme__app.out" "[]"
put "$st/gh-agent/invitations.out" "[]"
put "$st/gh-operator/user.out" "owner-person"
put "$st/ssh.default.out" "Hi owner-person! You've successfully authenticated, but GitHub does not provide shell access."; put "$st/ssh.default.rc" 1

# --- the person's own settings, before anything is installed ------------------------
guard="$repo/.agents/claude-guard/guard.json"
shared_rule=$(jq -r '.permissions.deny[0]' "$guard")   # the person already had this one: it stays theirs
mine_rule='Bash(my-own-rule *)'
jq -n --arg a "$shared_rule" --arg b "$mine_rule" '{permissions: {deny: [$a, $b]}, env: {MY_VAR: "kept"}, theme: "dark"}' >"$CFG/settings.json"

# --- install everything with the real installers -------------------------------------
setup="$root/setup.log"
sbx bash "$repo/sync-personal-skills.sh" >"$setup" 2>&1 || { echo "FAIL bridge install"; tail "$setup"; exit 1; }
sbx bash "$repo/scripts/apply-claude-guard.sh" >>"$setup" 2>&1 || { echo "FAIL claude guard install"; tail "$setup"; exit 1; }
sbx bash "$repo/scripts/apply-codex-guard.sh" >>"$setup" 2>&1 || { echo "FAIL codex guard install"; tail "$setup"; exit 1; }
: >>"$CX/config.toml"
for a in "" --codex; do
  sbx bash "$repo/scripts/apply-agent-identity.sh" ${a:+"$a"} >>"$setup" 2>&1 </dev/null ||
    { echo "FAIL identity install ${a:-claude}"; tail "$setup"; exit 1; }
done
# A foreign link, a wrong-target link where a Skill link belongs, and a real file.
mkdir -p "$H/elsewhere/foreign" "$H/elsewhere/other-skill"
ln -s "$H/elsewhere/foreign" "$H/.claude/skills/foreign"
skill=$(ls "$H/.claude/skills" | grep -v '^foreign$' | head -1)
rm "$H/.claude/skills/$skill"; ln -s "$H/elsewhere/other-skill" "$H/.claude/skills/$skill"
ln -s "$H/elsewhere/foreign" "$CX/skills/foreign-codex"
mine_after=$(jq -r '.permissions.deny | index("'"$mine_rule"'")' "$CFG/settings.json")
[ "$mine_after" != null ] || { echo "FAIL fixture: the person's rule is not in the settings"; exit 1; }
n_skills=$(find "$repo/.agents/skills" -mindepth 1 -maxdepth 2 -name SKILL.md -type f | wc -l | tr -d ' ')

# snapshot: everything in the sandbox, links by target and files by content, without
# following ~/.Jarvis into the checkout.
snapshot() { (cd "$root" && find home claude-cfg | sort | while IFS= read -r f; do
  if [ -L "$f" ]; then printf '%s -> %s\n' "$f" "$(readlink "$f")"
  elif [ -f "$f" ]; then printf '%s %s\n' "$f" "$(shasum -a 256 <"$f" | cut -d' ' -f1)"
  else printf '%s dir\n' "$f"; fi; done); }
repo_state() { git -C "$repo" status --porcelain; git -C "$repo" rev-parse HEAD; }

q() { jq -e "$1" "$CFG/settings.json" >/dev/null; }
installed=$(snapshot)
repo_before=$(repo_state)
cp "$CFG/settings.json" "$root/settings.installed"
expect "fixture: installed (guard entries, identity env, links)" bash -c "
  jq -e '.permissions.deny | length > 2' '$root/settings.installed' >/dev/null &&
  jq -e '.env.JARVIS_AGENT_IDENTITY != null' '$root/settings.installed' >/dev/null &&
  [ -e '$CFG/claude-guard.applied.json' ] && [ -e '$CFG/hooks/claude-guard.py' ] && [ -e '$CX/agent-identity.applied.json' ] &&
  [ -L '$H/.agents' ] && [ -L '$H/.claude/CLAUDE.md' ] && [ -L '$CX/AGENTS.md' ]"

# --- dry run (the default) -----------------------------------------------------------------------
log="$root/dry.log"
sbx bash "$uninstall" >"$log" 2>&1; rc=$?
expect "dry run: exit 0" test "$rc" = 0
expect "dry run: the sandbox is byte-identical afterwards" test "$(snapshot)" = "$installed"
expect "dry run: it names the settings edit, the hooks, a skill link, ~/.agents and the identity runs" bash -c "
  grep -q 'would edit  $CFG/settings.json' '$log' && grep -q 'would remove  $CFG/hooks/claude-guard.py' '$log' &&
  grep -q 'would remove  $CFG/hooks/jarvis-session-notes.py' '$log' && grep -q 'would remove  $H/.agents' '$log' &&
  grep -q 'would remove  $H/.claude/CLAUDE.md' '$log' && grep -q 'would remove  $CX/AGENTS.md' '$log' &&
  grep -q 'would run  bash .*apply-agent-identity.sh --unapply  ' '$log' && grep -q 'would run  bash .*apply-agent-identity.sh --unapply --codex' '$log'"
expect "dry run: it says what it would not touch" bash -c "
  grep -q 'left     $H/.claude/skills/foreign' '$log' && grep -q 'left     $H/.claude/skills/$skill' '$log' &&
  grep -q 'left     $CFG/settings.json.guard-backup' '$log'"
expect "dry run: both identity backups, the Claude settings one and the Codex config.toml one, are named" bash -c "
  grep -q 'copying it to $CFG/settings.json.agent-identity-backup first' '$log' &&
  grep -q 'copying it to $CX/config.toml.agent-identity-backup first' '$log'"
expect "dry run: it lists the backup path and what the identity --unapply will change" bash -c "
  grep -q 'previous copy would go to $CFG/settings.json.uninstall-backup' '$log' &&
  grep -q 'takes the env keys .*JARVIS_AGENT_IDENTITY' '$log' && grep -q 'agent-identity.gitconfig' '$log'"
sbx bash "$uninstall" --dry-run >"$root/dry2.log" 2>&1
expect "--dry-run is the same as no flag" test "$(grep -c '^would' "$log")" = "$(grep -c '^would' "$root/dry2.log")"
expect "dry run: the checkout is untouched" test "$(repo_state)" = "$repo_before"

# --- usage ---------------------------------------------------------------------------------------
sbx bash "$uninstall" --bogus >"$root/usage.log" 2>&1; rc=$?
expect "an unknown flag exits 2 and changes nothing" bash -c "[ $rc = 2 ] && [ \"\$(cat '$CFG/settings.json')\" = \"\$(cat '$root/settings.installed')\" ]"

# --- the real run --------------------------------------------------------------------------------
log="$root/remove.log"
sbx bash "$uninstall" --remove >"$log" 2>&1; rc=$?
expect "remove: exit 0" test "$rc" = 0
expect "remove: no guard deny rule is left except the person's own two" q "(.permissions.deny | sort) == ([\"$shared_rule\", \"$mine_rule\"] | sort)"
expect "remove: the person's rule, env and other keys remain" q '.env.MY_VAR == "kept" and .theme == "dark"'
expect "remove: guard hooks, auto-mode rules and ask rules are gone" q '(.hooks // {}) == {} and (.autoMode // {}) == {} and ((.permissions.ask // []) | length) == 0'
expect "remove: identity env is gone" q '(.env | keys) == ["MY_VAR"]'
expect "remove: the guard record and the three copied hooks are gone" bash -c "
  [ ! -e '$CFG/claude-guard.applied.json' ] && [ ! -e '$CFG/hooks/claude-guard.py' ] &&
  [ ! -e '$CFG/hooks/jarvis-session-notes.py' ] && [ ! -e '$CFG/hooks/jarvis-shell-syntax.py' ]"
expect "remove: the identity records are gone (both runtimes)" bash -c "
  [ ! -e '$CFG/agent-identity.applied.json' ] && [ ! -e '$CX/agent-identity.applied.json' ]"
expect "remove: bridge links into the checkout are gone" bash -c "
  [ ! -e '$H/.agents' ] && [ ! -L '$H/.agents' ] && [ ! -L '$H/.claude/CLAUDE.md' ] && [ ! -L '$CX/AGENTS.md' ] &&
  [ \"\$(find '$H/.claude/skills' -maxdepth 1 -type l | wc -l | tr -d ' ')\" = 2 ] &&
  [ \"\$(find '$CX/skills' -maxdepth 1 -type l | wc -l | tr -d ' ')\" = 1 ]"
expect "remove: the foreign links and the wrong-target link remain, pointing where they did" bash -c "
  [ \"\$(readlink '$H/.claude/skills/foreign')\" = '$H/elsewhere/foreign' ] &&
  [ \"\$(readlink '$H/.claude/skills/$skill')\" = '$H/elsewhere/other-skill' ] &&
  [ \"\$(readlink '$CX/skills/foreign-codex')\" = '$H/elsewhere/foreign' ]"
expect "remove: the backups are kept and reported" bash -c "
  [ -e '$CFG/settings.json.guard-backup' ] && grep -q 'left     $CFG/settings.json.guard-backup' '$log'"
expect "remove: the backup holds the settings as they were before the edit" cmp -s "$CFG/settings.json.uninstall-backup" "$root/settings.installed"
expect "remove: the disableBypassPermissionsMode notice is printed" grep -q "^left     $CFG/settings.json permissions.disableBypassPermissionsMode" "$log"
expect "remove: the identity backup is not listed as kept (step 3 overwrites it)" bash -c "! grep -q 'agent-identity-backup  (backup kept' '$log'"
expect "remove: the new backup is reported as left" grep -q "^left     $CFG/settings.json.uninstall-backup" "$log"
expect "remove: the Codex guard, which the issue leaves out, is untouched" bash -c "[ -e '$CX/hooks/jarvis-guard.py' ] && [ -e '$CX/hooks.json' ]"
expect "remove: the checkout is untouched (status, HEAD)" test "$(repo_state)" = "$repo_before"
expect "remove: ~/.Jarvis itself is still the link to the checkout" test "$(readlink "$H/.Jarvis")" = "$repo"
expect "remove: the real home was never named in the output" bash -c "! grep -qF '$real_home/.claude' '$log' || [ '$real_home' = '$H' ]"

# --- twice: nothing left to do, still exit 0 --------------------------------------------------
after=$(snapshot)
log="$root/again.log"
sbx bash "$uninstall" --remove >"$log" 2>&1; rc=$?
expect "second run: exit 0 and nothing changes" bash -c "[ $rc = 0 ]"
expect "second run: the sandbox is unchanged" test "$(snapshot)" = "$after"

# --- doctor, if present: the machine is simply not set up, not broken ------------------------
if [ -f "$repo/scripts/doctor.sh" ]; then
  log="$root/doctor.log"
  sbx bash "$repo/scripts/doctor.sh" >"$log" 2>&1; rc=$?
  expect "doctor after uninstall: exit 0 and the not-installed line, no PROBLEM" bash -c "
    [ $rc = 0 ] && grep -q '^doctor: Jarvis is not installed on this machine' '$log' && ! grep -q '^PROBLEM' '$log'"
fi

# --- cases that need a sandbox of their own ---------------------------------------------------
REAL_JQ=$(command -v jq)
fsum() { shasum -a 256 <"$1" | cut -d' ' -f1; }
mrun() { log="$root/$MN.$((++MI)).log"; sbx bash "$uninstall" "$@" >"$log" 2>&1; rc=$?; }
logg() { grep -q -- "$1" "$log"; }
# mini <name> [nobridge]: the guard (and, unless told not to, the bridge) installed in a fresh sandbox.
mini() {
  MN=$1; MI=0
  H="$root/$1/home"; CFG="$root/$1/cfg"; CX="$H/.codex"; IDENT="$H/no-identity"
  mkdir -p "$H" "$CFG" "$CX"; ln -s "$repo" "$H/.Jarvis"
  [ "${2:-}" = nobridge ] || sbx bash "$repo/sync-personal-skills.sh" >"$root/$1.setup" 2>&1 || echo "FAIL mini $1: bridge"
  sbx bash "$repo/scripts/apply-claude-guard.sh" >>"$root/$1.setup" 2>&1 || echo "FAIL mini $1: guard"
}
hooks_all() { [ -e "$CFG/hooks/claude-guard.py" ] && [ -e "$CFG/hooks/jarvis-session-notes.py" ] && [ -e "$CFG/hooks/jarvis-shell-syntax.py" ]; }
guard_whole() { # <settings sha before>: settings, record and the three hooks as they were
  [ "$(fsum "$CFG/settings.json")" = "$1" ] && [ -e "$CFG/claude-guard.applied.json" ] && hooks_all; }
other="Bash(my-own-rule *)"

# B1: nothing of the guard is removed when the record, the settings or the backup path is wrong.
mini b1a; before=$(fsum "$CFG/settings.json"); printf 'not json' >"$CFG/claude-guard.applied.json"
mrun --remove
{ [ "$rc" = 1 ] && logg '^PROBLEM  .*cannot be read as a guard record' && guard_whole "$before" &&
    logg "^left     $CFG/hooks/claude-guard.py" && logg "^left     $CFG/claude-guard.applied.json" && logg "^left     $CFG/settings.json  (guard left whole"; } && ok "B1 unreadable record: exit 1, PROBLEM, everything left and reported" || bad "B1 unreadable record" "$log"
mini b1b; before=$(fsum "$CFG/settings.json"); rm -f "$CFG/claude-guard.applied.json"
mrun --remove
{ [ "$rc" = 1 ] && logg "^PROBLEM  no $CFG/claude-guard.applied.json, but the guard's hooks or settings entries are here" &&
  [ "$(fsum "$CFG/settings.json")" = "$before" ] && hooks_all && logg "^left     $CFG/hooks/jarvis-shell-syntax.py" && logg "^left     $CFG/settings.json  (guard left whole"; } &&
  ok "B1 missing record: exit 1, PROBLEM, settings and hooks left" || bad "B1 missing record" "$log"
mini b1c; printf 'x{' >"$CFG/settings.json"; before=$(fsum "$CFG/settings.json")
mrun --remove
{ [ "$rc" = 1 ] && logg "^PROBLEM  $CFG/settings.json is not a JSON object" && guard_whole "$before" &&
  logg "^left     $CFG/settings.json  (guard left whole"; } &&
  ok "B1 settings not JSON: exit 1, PROBLEM, record and hooks left" || bad "B1 settings not JSON" "$log"
mini b1d; mrun --remove
{ [ "$rc" = 0 ] && [ ! -e "$CFG/claude-guard.applied.json" ] && [ ! -e "$CFG/hooks/claude-guard.py" ]; } &&
  ok "B1 control: a sound guard is removed, exit 0" || bad "B1 control" "$log"
mrun --remove
{ [ "$rc" = 0 ] && logg "^no $CFG/claude-guard.applied.json: the guard was not applied"; } &&
  ok "B1 control: a second run finds nothing and exits 0" || bad "B1 second run" "$log"

# SF1: the record is validated before it is used.
mini sf1; jq --arg a "Bash(x)" '.permissions.allow = [$a]' "$CFG/settings.json" >"$root/sf1.s" && cp "$root/sf1.s" "$CFG/settings.json"
before=$(fsum "$CFG/settings.json"); cp "$CFG/claude-guard.applied.json" "$root/sf1.rec"
i=0
for mut in '.owned["permissions.allow"] = ["Bash(x)"]' '.owned = ["permissions.deny"]' '.owned["permissions.deny"] = "x"' '.owned = null'; do
  i=$((i + 1)); jq "$mut" "$root/sf1.rec" >"$CFG/claude-guard.applied.json"
  mrun --remove
  { [ "$rc" = 1 ] && logg '^PROBLEM  .*cannot be read as a guard record' && guard_whole "$before" && grep -q 'Bash(x)' "$CFG/settings.json"; } &&
    ok "SF1 edited record ($i): exit 1, PROBLEM, settings and hooks untouched" || bad "SF1 edited record ($i): $mut" "$log"
done

# S3: one occurrence per owned entry goes; the person's identical one stays.
mini s3; rm -f "$CFG/hooks/"*.py
jq -n --arg x "Bash(dup *)" '{permissions: {deny: [$x, $x, "Bash(other)"]}}' >"$CFG/settings.json"
jq -n --arg x "Bash(dup *)" '{version: 2, owned: {"permissions.deny": [$x]}}' >"$CFG/claude-guard.applied.json"
mrun --remove
{ [ "$rc" = 0 ] && jq -e '.permissions.deny == ["Bash(dup *)", "Bash(other)"]' "$CFG/settings.json" >/dev/null; } &&
  ok "S3 the same rule twice: one occurrence removed, the person's stays" || bad "S3 duplicate rule" "$log"

# S5/S7: an existing backup path, a link or a file, is neither written nor written through.
for kind in link file; do
  mini "s5$kind"; before=$(fsum "$CFG/settings.json")
  echo canary >"$root/canary.$kind"
  if [ "$kind" = link ]; then ln -s "$root/canary.$kind" "$CFG/settings.json.uninstall-backup"; else cp "$root/canary.$kind" "$CFG/settings.json.uninstall-backup"; fi
  mrun --remove
  { [ "$rc" = 1 ] && logg "^PROBLEM  $CFG/settings.json.uninstall-backup already exists" && [ "$(cat "$root/canary.$kind")" = canary ] &&
    [ "$(cat "$CFG/settings.json.uninstall-backup")" = canary ] && guard_whole "$before"; } &&
    ok "S5/S7 backup path is a $kind: exit 1, PROBLEM, canary unchanged, guard left" || bad "S5/S7 backup $kind" "$log"
done
mrun
{ [ "$rc" = 1 ] && logg "^PROBLEM  $CFG/settings.json.uninstall-backup already exists"; } &&
  ok "S5/S7 the dry run reports the taken backup path too" || bad "S5/S7 dry run" "$log"

# S6 and B1: a hook is removed only when identical to the installer's copy and no settings entry still names it.
mini s6; echo '# mine' >>"$CFG/hooks/claude-guard.py"
jq --arg c "python3 $CFG/hooks/jarvis-session-notes.py --mine" '.hooks.UserPromptSubmit += [{hooks: [{type: "command", command: $c}]}]' \
  "$CFG/settings.json" >"$root/s6.s" && cp "$root/s6.s" "$CFG/settings.json"
mrun --remove
{ [ "$rc" = 0 ] && [ -e "$CFG/hooks/claude-guard.py" ] && [ -e "$CFG/hooks/jarvis-session-notes.py" ] && [ ! -e "$CFG/hooks/jarvis-shell-syntax.py" ] &&
  logg "^left     $CFG/hooks/claude-guard.py  (not byte-identical" && logg "^left     $CFG/hooks/jarvis-session-notes.py  (an entry in .* still names it" &&
  grep -q -- '--mine' "$CFG/settings.json"; } &&
  ok "S6/B1 an edited hook and a hook the person's entry names stay; the third goes" || bad "S6/B1 hooks" "$log"

# S10: a skills directory that is itself a link.
mini s10 nobridge; mkdir -p "$H/.claude" "$H/realskills"; ln -s "$H/realskills" "$H/.claude/skills"
skill=$(find "$repo/.agents/skills" -mindepth 1 -maxdepth 2 -name SKILL.md | head -1 | xargs dirname)
ln -s "$skill" "$H/realskills/mine-linked"; ln -s "$H/elsewhere" "$H/realskills/foreign"
mrun --remove
{ [ "$rc" = 0 ] && [ ! -L "$H/realskills/mine-linked" ] && [ -L "$H/realskills/foreign" ] && [ -L "$H/.claude/skills" ]; } &&
  ok "S10 skills directory is a link: its Jarvis links go, the foreign one and the directory link stay" || bad "S10" "$log"

# Legacy record: before "owned" existed, the record was a copy of guard.json, and all of it counts as the guard's.
mini legacy; cp "$guard" "$CFG/claude-guard.applied.json"
jq --arg r "$other" '.permissions.deny += [$r]' "$CFG/settings.json" >"$root/legacy.s" && cp "$root/legacy.s" "$CFG/settings.json"
mrun --remove
{ [ "$rc" = 0 ] && jq -e --arg r "$other" '.permissions.deny == [$r] and (.hooks // {}) == {} and (.autoMode // {}) == {}' "$CFG/settings.json" >/dev/null &&
  [ ! -e "$CFG/claude-guard.applied.json" ] && [ ! -e "$CFG/hooks/claude-guard.py" ]; } &&
  ok "legacy record (a copy of guard.json, no owned): the whole guard goes, the person's rule stays" || bad "legacy record" "$log"

# U5b: a backup path that is a dangling link is not written through either.
mini u5b; before=$(fsum "$CFG/settings.json"); ln -s "$root/u5b.target" "$CFG/settings.json.uninstall-backup"
mrun --remove
{ [ "$rc" = 1 ] && logg "^PROBLEM  $CFG/settings.json.uninstall-backup already exists" && [ ! -e "$root/u5b.target" ] && guard_whole "$before"; } &&
  ok "S5/S7 backup path is a dangling link: exit 1, PROBLEM, nothing created through it, guard left" || bad "S5/S7 dangling backup" "$log"

# U18: a hook that is a link, even to an identical copy, is left.
mini u18; cp "$repo/.agents/claude-guard/bash-guard.py" "$root/u18.copy"; rm "$CFG/hooks/claude-guard.py"; ln -s "$root/u18.copy" "$CFG/hooks/claude-guard.py"
mrun --remove
{ [ "$rc" = 0 ] && [ -L "$CFG/hooks/claude-guard.py" ] && [ ! -e "$CFG/hooks/jarvis-session-notes.py" ] &&
  logg "^left     $CFG/hooks/claude-guard.py  (not byte-identical" && logg 'delete it by hand' && logg 'doctor.sh reports the machine as installed'; } &&
  ok "S6 a hook that is a link is left, and the line says to delete it by hand" || bad "S6 hook link" "$log"

# Concurrent edit: settings.json is saved between the read and the replace. A jq on PATH makes the change at the
# one call that writes the new settings (a lone "jq ."), so the script itself is run as it is.
mini conc; mkdir -p "$root/conc-bin"
printf '#!/bin/sh\nif [ "$#" = 1 ] && [ "$1" = . ]; then printf %%s "{\\"saved\\":\\"meanwhile\\"}" >"$CONC_FILE"; fi\nexec "%s" "$@"\n' "$REAL_JQ" >"$root/conc-bin/jq"
chmod +x "$root/conc-bin/jq"
log="$root/conc.log"; sbx env PATH="$root/conc-bin:$PATH" CONC_FILE="$CFG/settings.json" bash "$uninstall" --remove >"$log" 2>&1; rc=$?
{ [ "$rc" = 1 ] && logg "^PROBLEM  $CFG/settings.json changed while this ran" && [ "$(cat "$CFG/settings.json")" = '{"saved":"meanwhile"}' ] &&
  [ -e "$CFG/claude-guard.applied.json" ] && hooks_all && [ ! -e "$CFG/settings.json.uninstall-backup" ] &&
  [ "$(find "$CFG" -maxdepth 1 -name 'settings.json.*' ! -name '*backup' | wc -l | tr -d ' ')" = 0 ] &&
  logg "^left     $CFG/settings.json  (guard left whole"; } &&
  ok "concurrent edit: exit 1, PROBLEM, their change kept, no temporary file, guard left" || bad "concurrent edit" "$log"

# Item 1: ~/.agents stays while a link that is kept still goes through it.
mini keep1; ln -s ../../.agents/skills/retired-skill "$H/.claude/skills/retired"
mrun --remove
{ [ "$rc" = 1 ] && [ -L "$H/.agents" ] && [ -L "$H/.claude/skills/retired" ] && logg "^left     $H/.agents" && logg "^PROBLEM  $H/.agents is kept" &&
  [ ! -L "$H/.claude/CLAUDE.md" ]; } &&
  ok "~/.agents stays, exit 1, when a kept dangling link still goes through it" || bad "keep ~/.agents (dangling)" "$log"
mini keep2; ln -s ../../.agents/AGENTS.md "$H/.claude/skills/rules-link"
mrun --remove
{ [ "$rc" = 1 ] && [ -L "$H/.agents" ] && [ -L "$H/.claude/skills/rules-link" ] && logg "^PROBLEM  $H/.agents is kept"; } &&
  ok "~/.agents stays, exit 1, when a kept link into the checkout outside skills/ still goes through it" || bad "keep ~/.agents (outside)" "$log"

# S13: a skills directory that cannot be scanned.
mini s13
if [ "$(id -u)" = 0 ]; then echo "skip S13: running as root, a mode-000 directory is still readable"
else
  n=$(find "$H/.claude/skills" -type l | wc -l | tr -d ' '); chmod 000 "$H/.claude/skills"
  mrun --remove; chmod 755 "$H/.claude/skills"
  { [ "$rc" = 1 ] && logg "^PROBLEM  $H/.claude/skills cannot be scanned" && [ "$(find "$H/.claude/skills" -type l | wc -l | tr -d ' ')" = "$n" ] &&
    [ -L "$H/.agents" ] && logg "^left     $H/.agents"; } &&
    ok "S13 unreadable skills directory: exit 1, PROBLEM, its links and ~/.agents left" || bad "S13" "$log"
  mrun --remove
  { [ "$rc" = 0 ] && [ "$(find "$H/.claude/skills" -type l | wc -l | tr -d ' ')" = 0 ] && [ ! -L "$H/.agents" ]; } &&
    ok "S13 after chmod 755 a second run removes the links and ~/.agents" || bad "S13 second run" "$log"
fi

# S14 and SF2: what is not ours is reported as left and kept.
mini misc; : >"$H/.claude/skills/afile"; mkdir "$H/.claude/skills/adir"
ln -s "$H/elsewhere/missing" "$H/.claude/skills/dangling"
rm "$H/.claude/CLAUDE.md"; echo mine >"$H/.claude/CLAUDE.md"
rm "$H/.agents"; mkdir "$H/.agents"
echo '{}' >"$CFG/agent-identity.require.json"
mrun --remove
{ [ "$rc" = 0 ] && [ -f "$H/.claude/skills/afile" ] && [ -d "$H/.claude/skills/adir" ] && [ -L "$H/.claude/skills/dangling" ] &&
  [ "$(cat "$H/.claude/CLAUDE.md")" = mine ] && [ -d "$H/.agents" ] &&
  logg "^left     $H/.claude/skills/afile  (not a link" && logg "^left     $H/.claude/skills/adir  (not a link" &&
  logg "^left     $H/.claude/skills/dangling  (dangling link" && logg "^left     $H/.claude/CLAUDE.md  (not a link" &&
  logg "^left     $H/.agents  (not a link"; } &&
  ok "S14/SF2 a file, a directory, a dangling link, a real CLAUDE.md and a real ~/.agents are reported and kept" || bad "S14/SF2" "$log"
{ logg '^NOTE     the identity switch is on' && logg -- '--unrequire'; } &&
  ok "SF2 the --unrequire NOTE is printed when the switch record exists" || bad "SF2 NOTE" "$log"

# --- agy instructions link (~/.gemini/config/AGENTS.md) ----------------------
mini agy-own
mkdir -p "$H/.gemini/config"
: >"$H/.gemini/GEMINI.md"
ln -s ../../.agents/AGENTS.md "$H/.gemini/config/AGENTS.md"
mrun --dry-run
{ [ "$rc" = 0 ] && [ -L "$H/.gemini/config/AGENTS.md" ] && logg "^would remove  $H/.gemini/config/AGENTS\.md"; } &&
  ok "agy dry-run: reports would remove ~/.gemini/config/AGENTS.md without removing it" || bad "agy dry-run" "$log"
mrun --remove
{ [ "$rc" = 0 ] && [ ! -e "$H/.gemini/config/AGENTS.md" ] && [ ! -L "$H/.gemini/config/AGENTS.md" ] &&
  [ -f "$H/.gemini/GEMINI.md" ] && [ ! -L "$H/.gemini/GEMINI.md" ] && [ ! -s "$H/.gemini/GEMINI.md" ] &&
  logg "^removed  $H/.gemini/config/AGENTS\.md"; } &&
  ok "agy remove: removes Jarvis link ~/.gemini/config/AGENTS.md and leaves ~/.gemini/GEMINI.md untouched" || bad "agy remove" "$log"

mini agy-foreign
mkdir -p "$H/.gemini/config" "$H/elsewhere"
printf 'mine\n' >"$H/.gemini/config/AGENTS.md"
mrun --remove
{ [ "$rc" = 0 ] && [ -f "$H/.gemini/config/AGENTS.md" ] && [ "$(cat "$H/.gemini/config/AGENTS.md")" = mine ] &&
  logg "^left     $H/.gemini/config/AGENTS\.md  (not a link"; } &&
  ok "agy foreign real file: reported as left and kept" || bad "agy foreign real file" "$log"

mini agy-extlink
mkdir -p "$H/.gemini/config" "$H/elsewhere"
printf 'other\n' >"$H/elsewhere/AGENTS.md"
ln -s "$H/elsewhere/AGENTS.md" "$H/.gemini/config/AGENTS.md"
mrun --remove
{ [ "$rc" = 0 ] && [ -L "$H/.gemini/config/AGENTS.md" ] &&
  [ "$(readlink "$H/.gemini/config/AGENTS.md")" = "$H/elsewhere/AGENTS.md" ] &&
  logg "^left     $H/.gemini/config/AGENTS\.md  (points at"; } &&
  ok "agy foreign symlink: reported as left and kept" || bad "agy foreign symlink" "$log"

# --- agy guard (~/.gemini/config/hooks.json, hooks/jarvis-guard.py) -----------
mini agy-guard-own
mkdir -p "$H/.gemini/config"
cat >"$H/.gemini/config/hooks.json" <<'EOF'
{
  "herdr": {"PreInvocation": [{"command": "echo herdr", "timeout": 10, "type": "command"}]},
  "orca-status": {"PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": "echo orca", "timeout": 10}]}]}
}
EOF
sbx bash "$repo/scripts/apply-agy-guard.sh" >>"$setup" 2>&1 || { echo "FAIL agy guard install"; exit 1; }
mrun --dry-run
{ [ "$rc" = 0 ] && [ -f "$H/.gemini/config/hooks/jarvis-guard.py" ] &&
  jq -e '."jarvis-guard" != null' "$H/.gemini/config/hooks.json" >/dev/null &&
  logg "^would edit  $H/.gemini/config/hooks\.json" &&
  logg "^would remove  $H/.gemini/config/hooks/jarvis-guard\.py"; } &&
  ok "agy guard dry-run: reports would edit hooks.json and would remove jarvis-guard.py without changing them" || bad "agy guard dry-run" "$log"
mrun --remove
{ [ "$rc" = 0 ] && [ ! -e "$H/.gemini/config/hooks/jarvis-guard.py" ] &&
  jq -e '."jarvis-guard" == null and .herdr != null and ."orca-status" != null' "$H/.gemini/config/hooks.json" >/dev/null &&
  logg "^edited   $H/.gemini/config/hooks\.json" &&
  logg "^removed  $H/.gemini/config/hooks/jarvis-guard\.py" &&
  logg "^left     $H/.gemini/config/hooks\.json\.guard-backup" &&
  logg "^left     $H/.gemini/config/hooks\.json\.uninstall-backup"; } &&
  ok "agy guard remove: takes out jarvis-guard and jarvis-guard.py, keeps herdr/orca-status and backups" || bad "agy guard remove" "$log"

mini agy-guard-edited
mkdir -p "$H/.gemini/config"
sbx bash "$repo/scripts/apply-agy-guard.sh" >>"$setup" 2>&1
echo "# edited" >>"$H/.gemini/config/hooks/jarvis-guard.py"
mrun --remove
{ [ "$rc" = 0 ] && [ -f "$H/.gemini/config/hooks/jarvis-guard.py" ] &&
  jq -e '."jarvis-guard" == null' "$H/.gemini/config/hooks.json" >/dev/null &&
  logg "^left     $H/.gemini/config/hooks/jarvis-guard\.py  (not byte-identical"; } &&
  ok "agy guard edited hook: reported as left and kept" || bad "agy guard edited hook" "$log"

echo
if [ "$fails" = 0 ]; then echo "uninstall: all passed"; else echo "uninstall: $fails FAILED"; exit 1; fi
