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

echo
if [ "$fails" = 0 ]; then echo "uninstall: all passed"; else echo "uninstall: $fails FAILED"; exit 1; fi
