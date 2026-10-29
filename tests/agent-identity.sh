#!/usr/bin/env bash
# Tests for scripts/apply-agent-identity.sh, each in its own sandbox: a HOME, a
# CLAUDE_CONFIG_DIR and a throwaway Git repository holding the config file, with
# `ssh`, `gh` and `ssh-keygen` replaced by stubs on PATH whose answers each case
# sets. The real ~/.claude, ~/.codex, ~/.ssh, ~/.config/gh and keychain are never
# read or written, and nothing reaches GitHub.
#
# Sandboxes are left under the printed directory rather than removed: the guard
# this repository installs refuses recursive deletion, and a test that has to
# step around its own subject is not testing it.
#
# APPLY_AGENT_IDENTITY (test-only, read by this file, not by the script) points
# the suite at another copy of the script, e.g. an absent one to show the cases
# fail before the code exists.
set -uo pipefail

# Hermetic: this suite may run inside an agent session, whose environment carries the
# applied identity (GIT_CONFIG_COUNT/KEY_n/VALUE_n, GIT_SSH_COMMAND, GIT_AUTHOR_*, GH_CONFIG_DIR,
# JARVIS_AGENT_IDENTITY...). None of it may reach the script or the git it runs; each case sets
# its own.
for v in $(compgen -e | grep -E '^(GIT_CONFIG_|GIT_AUTHOR_|GIT_COMMITTER_)'); do unset "$v"; done
unset GIT_SSH_COMMAND GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GH_CONFIG_DIR GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN \
  GITHUB_ENTERPRISE_TOKEN GH_HOST JARVIS_AGENT_IDENTITY JARVIS_REQUIRE_AGENT_IDENTITY CODEX_HOME CLAUDE_CONFIG_DIR XDG_CONFIG_HOME

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
apply="${APPLY_AGENT_IDENTITY:-$repo/scripts/apply-agent-identity.sh}"
orig_path=$PATH
root=$(mktemp -d "${TMPDIR:-/tmp}/agent-identity-test.XXXXXX")
echo "sandboxes: $root"

# Every run of the script under test gets a session of its own: no controlling terminal, so a git
# that wants to prompt cannot sit waiting on /dev/tty, and a time limit, so a hang is a failure
# (TEST_RUN_TIMEOUT seconds, exit 124). macOS has no setsid binary; python's os.setsid does it.
# (the interpreter itself, not a pyenv shim, which would put its own bin directory on PATH)
det_py=$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null || true)
cat >"$root/detach.py" <<'PY'
import os, signal, subprocess, sys
limit, cmd = int(sys.argv[1]), sys.argv[2:]
proc = subprocess.Popen(cmd, preexec_fn=os.setsid)
try:
    rc = proc.wait(timeout=limit)
except subprocess.TimeoutExpired:
    os.killpg(proc.pid, signal.SIGKILL)
    proc.wait()
    rc = 124
sys.exit(rc)
PY
DET=()
[ -z "$det_py" ] || DET=("$det_py" -I "$root/detach.py" "${TEST_RUN_TIMEOUT:-300}")
# The sandboxes sit inside a work tree of their own, with a credential helper in it, as when TMPDIR is
# inside a repository; the ceiling keeps the script's git from walking up into it.
git init -q "$root"; git -C "$root" config credential.helper store
export GIT_CEILING_DIRECTORIES="$root"

fails=0
n=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); if [ -n "${TEST_VERBOSE:-}" ] && [ -f "$dir/out" ]; then sed "s/^/    | /" "$dir/out"; fi; }
check() { # name, then a command that must succeed
  local name=$1; shift
  if "$@"; then ok "$name"; else fail "$name"; fi
}

# --- stubs ---------------------------------------------------------------------
mkdir -p "$root/bin"
cat >"$root/bin/ssh" <<'EOF'
#!/usr/bin/env bash
echo "ssh $*" >>"$STUB_DIR/calls.log"
case " $* " in *" -G "*)
  # ssh -G: the identity files ssh would offer. A user config is read unless -F says otherwise.
  f=""; cfgf=""; prev=""
  for a in "$@"; do
    [ "$prev" = -i ] && echo "identityfile $a"
    [ "$prev" = -F ] && cfgf=$a
    prev=$a
  done
  [ -z "$cfgf" ] && [ -f "$HOME/.ssh/config" ] && sed -n 's/^[[:space:]]*[Ii]dentity[Ff]ile[[:space:]]*/identityfile /p' "$HOME/.ssh/config"
  [ -f "$STUB_DIR/ssh.G.extra" ] && cat "$STUB_DIR/ssh.G.extra"
  exit 0 ;;
esac
case " $* " in *" -i "*) ;; *)
  # no -i: the operator's own ssh, with their normal config and agent
  [ -f "$STUB_DIR/ssh.default.out" ] && cat "$STUB_DIR/ssh.default.out"
  rc=255; [ -f "$STUB_DIR/ssh.default.rc" ] && rc=$(cat "$STUB_DIR/ssh.default.rc")
  exit "$rc" ;;
esac
case " $* " in *" IdentitiesOnly=yes "*) ;; *) echo "stub ssh: IdentitiesOnly=yes missing" >&2; exit 97 ;; esac
case " $* " in *" BatchMode=yes "*) ;; *) echo "stub ssh: BatchMode=yes missing" >&2; exit 97 ;; esac
case " $* " in *" git@github.com "*) ;; *) echo "stub ssh: unexpected target: $*" >&2; exit 97 ;; esac
# an answer for one key, named by its file name: ssh.<key>.out / ssh.<key>.rc
kf=""; prev=""
for a in "$@"; do [ "$prev" = -i ] && kf=$a; prev=$a; done
kb=$(basename "$kf")
if [ -f "$STUB_DIR/ssh.$kb.out" ]; then
  cat "$STUB_DIR/ssh.$kb.out"
  rc=1; [ -f "$STUB_DIR/ssh.$kb.rc" ] && rc=$(cat "$STUB_DIR/ssh.$kb.rc")
  exit "$rc"
fi
[ -f "$STUB_DIR/ssh.out" ] && cat "$STUB_DIR/ssh.out"
rc=1; [ -f "$STUB_DIR/ssh.rc" ] && rc=$(cat "$STUB_DIR/ssh.rc")
exit "$rc"
EOF
cat >"$root/bin/gh" <<'EOF'
#!/usr/bin/env bash
d=$STUB_DIR
echo "gh GH_CONFIG_DIR=${GH_CONFIG_DIR-<unset>} $*" >>"$d/calls.log"
for v in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; do
  if [ -n "${!v:-}" ]; then echo "TOKEN-LEAK $v" >>"$d/calls.log"; echo "stub gh: $v in the environment" >&2; exit 98; fi
done
# A case may make "someone" save the settings file while the script runs.
[ -f "$d/touch_settings" ] && printf ' ' >>"$STUB_SETTINGS"
who=agent; [ -n "${GH_CONFIG_DIR:-}" ] || who=operator
a="$d/gh-$who"
# a config dir with answers of its own (a second account) is answered from gh-by-dir/<name>
[ -z "${GH_CONFIG_DIR:-}" ] || [ ! -d "$d/gh-by-dir/$(basename "$GH_CONFIG_DIR")" ] || a="$d/gh-by-dir/$(basename "$GH_CONFIG_DIR")"
emit() {
  local f="$a/$1" rc=0
  if [ ! -f "$f.out" ] && [ ! -f "$f.err" ] && [ ! -f "$f.rc" ]; then echo "stub gh: no answer prepared for $who $*" >&2; exit 97; fi
  [ -f "$f.err" ] && cat "$f.err" >&2
  [ -f "$f.out" ] && cat "$f.out"
  [ -f "$f.rc" ] && rc=$(cat "$f.rc")
  exit "$rc"
}
case "$1 $2" in
  "auth status") emit auth_status ;;
  "api user") emit user ;;
esac
case "$*" in "api user/memberships/orgs/"*) emit "membership.${2##*/}" ;; esac
if [ "$1" = api ]; then
  ep=$2
  case $ep in
    user/repository_invitations) emit invitations ;;
    repos/*/*/rulesets/*) emit "ruleset.${ep##*/}" ;;
    repos/*/*/rulesets) p=${ep#repos/}; p=${p%/rulesets}; emit "rulesets.${p//\//__}" ;;
    repos/*) p=${ep#repos/}; emit "repo.${p//\//__}" ;;
  esac
fi
echo "stub gh: unexpected call: $*" >&2
exit 97
EOF
cat >"$root/bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
echo "ssh-keygen $*" >>"$STUB_DIR/calls.log"
f=""; while [ "$#" -gt 0 ]; do [ "$1" = -f ] && f=$2; shift; done
if [ -e "$f" ] || [ -e "$f.pub" ]; then echo "OVERWRITE $f" >>"$STUB_DIR/calls.log"; exit 1; fi
echo "FAKE PRIVATE KEY" >"$f"; chmod 600 "$f"
echo "ssh-ed25519 AAAAFAKEKEY generated-by-stub" >"$f.pub"
EOF
chmod +x "$root/bin/ssh" "$root/bin/gh" "$root/bin/ssh-keygen"

# --- sandboxes -------------------------------------------------------------------
put() { mkdir -p "$(dirname "$1")"; printf '%s' "$2" >"$1"; }
base_settings='{"model":"opus","permissions":{"allow":["Bash(ls)"]},"hooks":{"Stop":[]},"env":{"FOO":"bar"}}'
repo_ok='{"permissions":{"admin":false,"maintain":false,"push":true,"pull":true}}'
ssh_hi="Hi bot-agent! You've successfully authenticated, but GitHub does not provide shell access."
auth_ok=$'github.com\n  \xe2\x9c\x93 Logged in to github.com account bot-agent (keyring)\n  - Active account: true'

sandbox() { # a machine where every check passes
  n=$((n + 1))
  dir="$root/$n"; home="$dir/home"; jar="$dir/jarvis"; cfgdir="$jar/config-local"; cfg="$cfgdir/agent-identity"
  stub="$dir/stub"; key="$home/.ssh/agent_key"; settings="$home/.claude/settings.json"
  record="$home/.claude/agent-identity.applied.json"; ghdir="$home/.config/gh-agent"
  codex="$home/.codex"; toml="$codex/config.toml"; cg="$codex/agent-identity.gitconfig"; crec="$codex/agent-identity.applied.json"
  ckey="$home/.ssh/codex_key"
  mkdir -p "$home/.claude" "$home/.ssh" "$cfgdir" "$stub/gh-agent" "$stub/gh-operator"
  chmod 700 "$cfgdir" "$home/.ssh"
  git init -q "$jar"
  printf 'config-local/\n' >"$jar/.gitignore"
  cat >"$cfg" <<'EOF'
# agent identity
login=bot-agent
email=1+bot-agent@users.noreply.github.com
ssh_key=~/.ssh/agent_key
gh_config_dir=~/.config/gh-agent
repos=acme/app
EOF
  chmod 600 "$cfg"
  put "$key" "FAKE PRIVATE KEY"; chmod 600 "$key"
  put "$key.pub" "ssh-ed25519 AAAAFAKE bot-agent"
  put "$settings" "$base_settings"; chmod 600 "$settings"
  put "$stub/ssh.out" "$ssh_hi"; put "$stub/ssh.rc" 1
  put "$stub/gh-agent/auth_status.out" "$auth_ok"
  put "$stub/gh-agent/user.out" "bot-agent"
  put "$stub/gh-agent/repo.acme__app.out" "$repo_ok"
  put "$stub/gh-agent/rulesets.acme__app.out" "[]"
  put "$stub/gh-agent/invitations.out" "[]"
  put "$stub/gh-operator/user.out" "owner-person"
  put "$stub/ssh.default.out" "Hi owner-person! You've successfully authenticated, but GitHub does not provide shell access."; put "$stub/ssh.default.rc" 1
  XENV=""
}
base_env() {
  env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN -u GH_HOST -u GH_CONFIG_DIR \
    -u XDG_CONFIG_HOME -u GIT_DIR -u GIT_WORK_TREE \
    HOME="$home" CLAUDE_CONFIG_DIR="$home/.claude" CODEX_HOME="$codex" JARVIS_AGENT_IDENTITY_FILE="$cfg" STUB_DIR="$stub" \
    STUB_SETTINGS="$settings" GIT_CONFIG_NOSYSTEM=1 PATH="${TEST_PATH:-$root/bin:$PATH}" $XENV "$@"
}
run() { (cd "$dir" && base_env ${DET[@]+"${DET[@]}"} bash "$apply" "$@" </dev/null) >"$dir/out" 2>&1; }
has()  { grep -qF -- "$1" "$dir/out"; }
hasl() { grep -qxF -- "$1" "$dir/out"; }
hasn() { ! grep -qF -- "$1" "$dir/out"; }
calls() { cat "$stub/calls.log" 2>/dev/null; }
snapshot() { # every file a run could write, except the test's own
  (cd "$dir" && find home jarvis -name .git -prune -o \( -type f -o -type l \) -print | sort |
    while read -r f; do printf '%s ' "$f"; cksum <"$f"; done)
}
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
cfg_append() { printf '%s\n' "$1" >>"$cfg"; }   # becomes line 7
cfg_set() { # replace the file by the given text
  printf '%s\n' "$1" >"$cfg"; chmod 600 "$cfg"
}
jqs() { jq -S "$@"; }
jx() { jq -e "$@" >/dev/null; }
sx() { jq -e "$1" "$settings" >/dev/null; }

# =================================================================================
echo "== all passing"
sandbox
snapshot >"$dir/snap.before"
run --check; rc=$?
snapshot >"$dir/snap.after"
check "pass: exit 0" test "$rc" = 0
check "pass: no MISSING or WRONG line" bash -c "! grep -Eq '^(MISSING|WRONG)  ' '$dir/out'"
check "pass: every line has the documented shape" bash -c "! grep -Ev '^(OK|WARN|SKIP|MISSING|WRONG)  |^  fix: |^       |^Next: |^apply-agent-identity: ' '$dir/out' | grep -q ."
check "pass: SSH answer verified" has "OK  SSH: GitHub answers \"Hi bot-agent!\" for $key"
check "pass: gh login verified" has "OK  gh: GH_CONFIG_DIR=$ghdir is logged in as bot-agent"
check "pass: operator differs" has "OK  the operator's own gh login (owner-person) differs from login=bot-agent"
check "pass: repo push" has "OK  repo acme/app: bot-agent can push"
check "pass: Next line" hasl "Next: run without --check to apply"
check "pass: --check writes nothing" cmp -s "$dir/snap.before" "$dir/snap.after"
check "pass: ssh used the key, IdentitiesOnly" bash -c "grep -q 'ssh -T -F /dev/null -i $key -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new' '$stub/calls.log'"
check "pass: the agent's gh runs in its own config dir" bash -c "grep -q 'gh GH_CONFIG_DIR=$ghdir auth status' '$stub/calls.log'"
check "pass: the operator's gh runs in the default config dir" bash -c "grep -q 'gh GH_CONFIG_DIR=<unset> api user' '$stub/calls.log'"

echo "== usage"
sandbox
run --bogus; rc=$?
check "usage: unknown flag exits 2" test "$rc" = 2
run --check --unapply; rc=$?
check "usage: two flags exit 2" test "$rc" = 2
run ""; rc=$?
check "usage: an empty argument exits 2" test "$rc" = 2
run --help; rc=$?
check "usage: --help exits 0 and prints Usage" bash -c "test $rc = 0 && grep -q '^Usage:' '$dir/out'"

# =================================================================================
echo "== step 1: the config file"
sandbox
rm "$cfg"
snapshot >"$dir/snap.before"
run --check; rc=$?
snapshot >"$dir/snap.after"
check "no file: exit 1" test "$rc" = 1
check "no file: MISSING line with the full path" has "MISSING  config file $cfg does not exist"
check "no file: fix offers --setup" has "  fix: bash $apply --setup"
check "no file: the template is printed" bash -c "grep -q 'login=my-agent-account' '$dir/out' && grep -q 'gh_config_dir=~/.config/gh-agent' '$dir/out' && grep -q \"mkdir -p -m 700 $cfgdir\" '$dir/out'"
check "no file: dependent checks are skipped, not guessed" has "SKIP  SSH key, gh login and repository access (need the config file)"
check "no file: Next names step 1" hasl "Next: step 1 of 6 — create the config file — bash $apply --setup"
check "no file: nothing written" cmp -s "$dir/snap.before" "$dir/snap.after"
check "no file: neither ssh nor gh was run" bash -c "! grep -q . '$stub/calls.log' 2>/dev/null || ! grep -Eq '^(ssh|gh GH_CONFIG_DIR=$ghdir) ' '$stub/calls.log'"
# the default path, without the test override
(cd "$dir" && base_env ${DET[@]+"${DET[@]}"} env -u JARVIS_AGENT_IDENTITY_FILE bash "$apply" --check </dev/null) >"$dir/out" 2>&1
check "no file: the default path is under ~/.Jarvis/config-local" has "MISSING  config file $home/.Jarvis/config-local/agent-identity does not exist"

sandbox
git -C "$jar" add -f config-local/agent-identity
run --check; rc=$?
check "tracked: exit 1" test "$rc" = 1
check "tracked: WRONG, public repository" bash -c "grep -q '^WRONG  $cfg is tracked by Git' '$dir/out'"
check "tracked: exact fix" has "  fix: git -C $cfgdir rm --cached -- agent-identity"
check "tracked: Next names step 1" bash -c "grep -q '^Next: step 1 of 6 — create the config file — git -C $cfgdir rm --cached' '$dir/out'"

sandbox
rm "$jar/.gitignore"
run --check; rc=$?
top=$(cd "$jar" && pwd -P)
check "unignored: exit 1" test "$rc" = 1
check "unignored: WRONG" bash -c "grep -q '^WRONG  $cfg is not ignored by Git' '$dir/out'"
check "unignored: exact fix, an anchored line for the info/exclude file" bash -c "grep -qF \"  fix: printf '%s\\n' /config-local/agent-identity >> $top/.git/info/exclude\" '$dir/out'"
printf '%s\n' /config-local/agent-identity >>"$top/.git/info/exclude"
run --check; rc=$?
check "unignored: applying the fix line makes it pass" test "$rc" = 0

sandbox
chmod 664 "$cfg"
run --check; rc=$?
check "perm: group-writable file is WRONG" has "WRONG  config file mode is 664: group- or world-writable"
check "perm: exact fix" has "  fix: chmod go-w $cfg"
check "perm: exit 1" test "$rc" = 1
sandbox
chmod 777 "$cfgdir"
run --check; rc=$?
check "perm: world-writable directory is WRONG" has "WRONG  directory $cfgdir mode is 777: group- or world-writable"
check "perm: directory fix" has "  fix: chmod go-w $cfgdir"

# --- malformed lines: each reported with its line number
badline() { # name, line to append (line 7), expected text, expected fix text
  sandbox
  printf '%s\n' "$2" >>"$cfg"
  case ${5-} in raw) printf '%b' "$2" >"$dir/line"; head -n 6 "$cfg" >"$dir/cfg6"; { cat "$dir/cfg6"; printf '%b\n' "$2"; } >"$cfg" ;; esac
  run --check; rc=$?
  check "line: $1: exit 1" test "$rc" = 1
  check "line: $1: reported with its line number" has "WRONG  config line 7: $3"
  local fixtxt=${4//@CFG@/$cfg}
  check "line: $1: fix names the line and the file" has "  fix: edit line 7 of $cfg: $fixtxt"
  check "line: $1: Next names step 1" bash -c "grep -q '^Next: step 1 of 6 — create the config file — edit line 7 of $cfg' '$dir/out'"
}
badline "unknown key" 'colour=red' 'unknown key "colour"' 'use one of: login email ssh_key gh_config_dir repos author_name codex_ssh_key codex_author_name codex_login codex_email codex_gh_config_dir'
badline "duplicate key" 'login=other' 'duplicate key "login" (first on line 2)' 'delete one of the two lines'
badline "empty value" 'author_name=' 'author_name has an empty value' 'give author_name a value, or delete the line'
badline "quotes" 'author_name="Bot"' 'author_name has quotes around its value' 'remove the quotes; values are taken literally'
badline "single quotes" "author_name='Bot'" 'author_name has quotes around its value' 'remove the quotes; values are taken literally'
badline "trailing space" 'author_name=Bot ' 'author_name has trailing whitespace' 'remove the trailing spaces'
badline "leading value space" 'author_name= Bot' 'author_name has whitespace before its value' 'remove the space after ='
badline "spaces around =" 'author_name = Bot' 'key "author_name " has characters other than a-z and _ (no spaces around =)' 'write it as key=value with no spaces, using one of: login email ssh_key gh_config_dir repos author_name codex_ssh_key codex_author_name codex_login codex_email codex_gh_config_dir'
badline "CRLF" 'author_name=Bot\r' 'ends with a carriage return (CRLF line ending)' "save the file with LF line endings (tr -d '\\r' <@CFG@ >@CFG@.new && chmod 600 @CFG@.new && mv @CFG@.new @CFG@)" raw
badline "indented line" '  author_name=Bot' 'starts with whitespace' 'remove the leading whitespace (comments start with # in column 1)'
badline "whitespace-only line" '   ' 'contains only whitespace' 'make it an empty line or delete it'
badline "not key=value" 'author_name' 'is not key=value, a # comment or blank' 'write it as key=value, or start it with #'
badline "inline comment" 'author_name=Bot # who' 'author_name has an inline comment' 'put the comment on its own line'

sandbox
{ head -n 5 "$cfg"; } >"$dir/c5"; cp "$dir/c5" "$cfg"
run --check; rc=$?
check "missing key: repos is required" has "MISSING  config key repos (required) is not in $cfg"
check "missing key: exit 1 and Next step 1" bash -c "test $rc = 1 && grep -q '^Next: step 1 of 6' '$dir/out'"

sandbox
cfg_set $'# only a comment\n\n'
run --check; rc=$?
check "empty config: every required key reported" bash -c "test $rc = 1 && grep -c '^MISSING  config key' '$dir/out' | grep -q 5"

# --- values
badvalue() { # name, key line number, replacement line, expected text
  sandbox
  awk -v n="$2" -v r="$3" 'NR==n {print r; next} {print}' "$cfg" >"$dir/c" && cp "$dir/c" "$cfg"
  run --check; rc=$?
  check "value: $1: exit 1" test "$rc" = 1
  check "value: $1: reported" bash -c "grep -qF 'WRONG  config line $2: $4' '$dir/out'"
}
badvalue "login with underscore" 2 'login=bad_login' 'login=bad_login not a GitHub login'
badvalue "login with double hyphen" 2 'login=a--b' 'login=a--b not a GitHub login'
sandbox
awk 'NR==2 {print "login=bad_login"; next} {print}' "$cfg" >"$dir/c" && cp "$dir/c" "$cfg"
run --check
check "value: a bad login skips the checks that use it" bash -c "grep -q '^SKIP  SSH key and GitHub' '$dir/out' && grep -q '^SKIP  gh login' '$dir/out' && ! grep -q '^ssh' '$stub/calls.log'"
badvalue "email without a domain" 3 'email=nope' 'email=nope does not look like an email address'
badvalue "relative key path" 4 'ssh_key=keys/x' 'ssh_key=keys/x must be an absolute path or start with ~/'
badvalue "variable in a path" 4 'ssh_key=$HOME/.ssh/k' 'ssh_key=$HOME/.ssh/k no variables or substitutions'
badvalue "path with a space" 4 'ssh_key=~/my keys/k' 'ssh_key=~/my keys/k the expanded path'
badvalue "gh dir is the operator's default" 5 'gh_config_dir=~/.config/gh' 'gh_config_dir=~/.config/gh is the default gh config dir'
badvalue "repos without a slash" 6 'repos=acme' 'repos=acme "acme" is not owner/repo'
badvalue "repos with a trailing comma" 6 'repos=acme/app,' 'repos=acme/app, must be owner/repo'

# =================================================================================
echo "== step 2: the key"
sandbox
rm "$key" "$key.pub"
run --check; rc=$?
check "no key: MISSING" has "MISSING  SSH key file $key does not exist"
check "no key: exact fix" has "  fix: ssh-keygen -t ed25519 -N '' -C bot-agent -f $key   (or: bash $apply --setup)"
check "no key: GitHub's answer is skipped, ssh is not run" bash -c "has() { grep -qF -- \"\$1\" '$dir/out'; }; has 'SKIP  GitHub' && ! grep -q '^ssh -T -F /dev/null' '$stub/calls.log'"
check "no key: Next names step 2" hasl "Next: step 2 of 6 — generate this machine's SSH key — ssh-keygen -t ed25519 -N '' -C bot-agent -f $key   (or: bash $apply --setup)"
check "no key: exit 1" test "$rc" = 1
sandbox
chmod 644 "$key"
run --check; rc=$?
check "key mode: 644 is WRONG" has "WRONG  SSH key $key has mode 644; it must be 600 or stricter, or ssh refuses it"
check "key mode: exact fix" has "  fix: chmod 600 $key"
sandbox
chmod 400 "$key"
run --check; rc=$?
check "key mode: 400 is accepted" test "$rc" = 0
sandbox
rm "$key.pub"
run --check; rc=$?
check "no .pub: MISSING" has "MISSING  public key $key.pub does not exist"
check "no .pub: exact fix" has "  fix: ssh-keygen -y -f $key >$key.pub"
check "no .pub: Next names step 2" bash -c "grep -q '^Next: step 2 of 6' '$dir/out'"

echo "== step 3: the key on the machine account"
sandbox
put "$stub/ssh.out" "git@github.com: Permission denied (publickey)."; put "$stub/ssh.rc" 255
run --check; rc=$?
check "denied: MISSING, not network" has "MISSING  SSH: GitHub rejected $key (Permission denied): its public key is not on the account bot-agent"
check "denied: exact fix" has "  fix: sign in to GitHub as bot-agent, open https://github.com/settings/ssh/new and paste the contents of $key.pub"
check "denied: Next names step 3" hasl "Next: step 3 of 6 — add the key's .pub to the machine account on GitHub — sign in to GitHub as bot-agent, open https://github.com/settings/ssh/new and paste the contents of $key.pub"
check "denied: not reported as a network failure" hasn "network"
sandbox
put "$stub/ssh.out" "Hi owner-person! You've successfully authenticated, but GitHub does not provide shell access."
run --check; rc=$?
check "other login: WRONG names both logins" has "WRONG  SSH: $key authenticates as owner-person, but the config says login=bot-agent"
check "other login: exit 1" test "$rc" = 1
sandbox
put "$stub/ssh.out" "ssh: Could not resolve hostname github.com: nodename nor servname provided, or not known"; put "$stub/ssh.rc" 255
run --check; rc=$?
check "ssh network: MISSING, says network" has "MISSING  SSH: could not reach github.com (network), so the key was not verified"
check "ssh network: not reported as an auth failure" hasn "rejected"
sandbox
put "$stub/ssh.out" "Host key verification failed."; put "$stub/ssh.rc" 255
run --check
check "host key: WRONG with the ssh-keygen -R fix" bash -c "grep -q '^WRONG  SSH: host key verification failed' '$dir/out' && grep -q '  fix: ssh-keygen -R github.com' '$dir/out'"
sandbox
put "$stub/ssh.out" "Hi Bot-Agent! You've successfully authenticated, but GitHub does not provide shell access."
run --check; rc=$?
check "login case: GitHub logins compare case-insensitively" test "$rc" = 0

echo "== step 4: gh"
sandbox
put "$stub/gh-agent/auth_status.out" "You are not logged into any GitHub hosts. To log in, run: gh auth login"; put "$stub/gh-agent/auth_status.rc" 1
run --check; rc=$?
check "gh not logged in: MISSING" has "MISSING  gh: not logged in to github.com in $ghdir"
check "gh not logged in: exact fix" has "  fix: GH_CONFIG_DIR=$ghdir gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key --web   (sign in as bot-agent, not as yourself)"
check "gh not logged in: Next names step 4" hasl "Next: step 4 of 6 — log gh in as the machine account — GH_CONFIG_DIR=$ghdir gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key --web   (sign in as bot-agent, not as yourself)"
check "gh not logged in: repository access skipped" has "SKIP  repository access (needs the gh login of the machine account first)"
sandbox
put "$stub/gh-agent/user.out" "someone-else"
run --check; rc=$?
check "gh wrong account: WRONG names both" has "WRONG  gh: $ghdir is logged in as someone-else, but the config says login=bot-agent"
check "gh wrong account: exit 1" test "$rc" = 1
sandbox
put "$stub/gh-agent/auth_status.out" "error connecting to api.github.com"; put "$stub/gh-agent/auth_status.rc" 1
run --check
check "gh network: MISSING, says network" has "MISSING  gh: could not reach github.com (network), so the login in $ghdir was not verified"
check "gh network: not reported as logged out" hasn "not logged in"
sandbox
put "$stub/gh-agent/auth_status.out" $'X Failed to log in to github.com account bot-agent (keyring)\n - The token in keyring is invalid.'; put "$stub/gh-agent/auth_status.rc" 1
run --check
check "gh bad token: WRONG with a re-login fix" bash -c "grep -q '^WRONG  gh: the login in $ghdir does not work' '$dir/out' && grep -q 'fix: GH_CONFIG_DIR=$ghdir gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key --web' '$dir/out'"
sandbox
put "$stub/gh-agent/auth_status.out" $'github.com\n  \xe2\x9c\x93 Logged in to github.com account bot-agent (keyring)\n  - Active account: true\n\n  \xe2\x9c\x93 Logged in to github.com account other (keyring)\n  - Active account: false'
run --check; rc=$?
check "gh two accounts: WARN, still passes" bash -c "test $rc = 0 && grep -q '^WARN  gh: $ghdir holds 2 github.com accounts' '$dir/out'"

echo "== tokens that would override the login"
sandbox
XENV="GH_TOKEN=ghp_notreal"
run --check; rc=$?
check "token in process: WRONG" has "WRONG  GH_TOKEN is set in this process; it would override the agent's gh login with whoever owns that token"
check "token in process: exact fix" has "  fix: unset GH_TOKEN   (and remove the line that exports it from your shell profile, for example ~/.zshrc or ~/.bash_profile)"
check "token in process: exit 1" test "$rc" = 1
check "token in process: Next names step 4" bash -c "grep -q '^Next: step 4 of 6 — log gh in as the machine account — unset GH_TOKEN' '$dir/out'"
check "token in process: no gh call carried the token" bash -c "grep -q 'gh GH_CONFIG_DIR' '$stub/calls.log' && ! grep -q TOKEN-LEAK '$stub/calls.log'"
sandbox
put "$settings" '{"env":{"GITHUB_TOKEN":"x"}}'
run --check; rc=$?
check "token in settings env: WRONG" has "WRONG  GITHUB_TOKEN is set in the env of $settings; it would override the agent's gh login"
check "token in settings env: exact fix" has "  fix: remove \"GITHUB_TOKEN\" from the env block of $settings"
sandbox
XENV="GH_ENTERPRISE_TOKEN=x"
run --check
check "enterprise token in process: WRONG" has "WRONG  GH_ENTERPRISE_TOKEN is set in this process"
sandbox
XENV="GH_TOKEN="
run --check; rc=$?
check "empty token variable is not a token" test "$rc" = 0

echo "== the operator's own login"
sandbox
put "$stub/gh-operator/user.out" "bot-agent"
run --check; rc=$?
check "operator equals agent: WRONG" has "WRONG  login=bot-agent is the operator's own gh login: the agent would be the owner again and could not be reviewed by them"
check "operator equals agent: exit 1, Next names step 1" bash -c "test $rc = 1 && grep -q '^Next: step 1 of 6' '$dir/out'"
sandbox
rm "$stub/gh-operator/user.out"; put "$stub/gh-operator/user.err" "To get started with GitHub CLI, please run:  gh auth login"; put "$stub/gh-operator/user.rc" 1
run --check; rc=$?
check "operator not logged in: WARN, not WRONG" bash -c "test $rc = 0 && grep -q '^WARN  the operator.s own gh is not logged in' '$dir/out'"
sandbox
rm "$stub/gh-operator/user.out"; put "$stub/gh-operator/user.err" "error connecting to api.github.com"; put "$stub/gh-operator/user.rc" 1
run --check; rc=$?
check "operator network failure: WARN names the network" bash -c "test $rc = 0 && grep -q '^WARN  could not reach github.com to read the operator' '$dir/out'"

# =================================================================================
echo "== step 5: access to each repository (three ways to lack it, and a wrong role)"
sandbox
put "$stub/gh-agent/repo.acme__app.out" '{"permissions":{"admin":false,"push":false,"pull":true}}'
run --check; rc=$?
check "no push, no invitation: MISSING" has "MISSING  repo acme/app: bot-agent has no access and no pending invitation"
check "no push, no invitation: exact fix" has "  fix: as the owner of acme/app, invite bot-agent with Write: https://github.com/acme/app/settings/access (for an organization repository pick the Write role; for a personal one, a collaborator gets write by default)"
check "no push, no invitation: Next names step 5" bash -c "grep -q '^Next: step 5 of 6 — make the machine account a Write collaborator on the repository — as the owner of acme/app, invite bot-agent with Write' '$dir/out'"
sandbox
rm "$stub/gh-agent/repo.acme__app.out"; put "$stub/gh-agent/repo.acme__app.err" "gh: Not Found (HTTP 404)"; put "$stub/gh-agent/repo.acme__app.rc" 1
run --check; rc=$?
check "404, no invitation: the same not-invited answer" bash -c "test $rc = 1 && grep -q '^MISSING  repo acme/app: bot-agent has no access and no pending invitation' '$dir/out'"
check "404, no invitation: the invitations were looked up" bash -c "grep -q 'gh GH_CONFIG_DIR=$ghdir api user/repository_invitations' '$stub/calls.log'"
sandbox
rm "$stub/gh-agent/repo.acme__app.out"; put "$stub/gh-agent/repo.acme__app.err" "gh: Not Found (HTTP 404)"; put "$stub/gh-agent/repo.acme__app.rc" 1
put "$stub/gh-agent/invitations.out" '[{"id":7,"repository":{"full_name":"Acme/App"}},{"id":8,"repository":{"full_name":"acme/other"}}]'
run --check; rc=$?
check "invited, not accepted: MISSING, says pending" has "MISSING  repo acme/app: the invitation for bot-agent is pending, not accepted"
check "invited, not accepted: exact fix" has "  fix: as bot-agent, accept the invitation at https://github.com/acme/app/invitations (or github.com/notifications)"
check "invited, not accepted: Next names step 5 with the accept line" hasl "Next: step 5 of 6 — make the machine account a Write collaborator on the repository — as bot-agent, accept the invitation at https://github.com/acme/app/invitations (or github.com/notifications)"
check "invited, not accepted: not the not-invited wording" hasn "no pending invitation"
sandbox
put "$stub/gh-agent/repo.acme__app.out" '{"permissions":{"admin":false,"push":false,"pull":true}}'
put "$stub/gh-agent/invitations.out" '[{"id":7,"repository":{"full_name":"acme/app"}}]'
run --check
check "public repo, invitation pending: still the pending wording" has "MISSING  repo acme/app: the invitation for bot-agent is pending, not accepted"
sandbox
put "$stub/gh-agent/invitations.out" '[{"id":8,"repository":{"full_name":"acme/other"}}]'
put "$stub/gh-agent/repo.acme__app.out" '{"permissions":{"admin":false,"push":false,"pull":true}}'
run --check
check "an invitation to another repository does not count" has "MISSING  repo acme/app: bot-agent has no access and no pending invitation"
sandbox
put "$stub/gh-agent/repo.acme__app.out" '{"permissions":{"admin":true,"maintain":true,"push":true,"pull":true}}'
run --check; rc=$?
check "admin role: WRONG, blocks the apply" bash -c "test $rc = 1 && grep -q '^WRONG  repo acme/app: bot-agent holds the admin role; it must be Write' '$dir/out'"
check "admin role: exact fix" has "  fix: lower bot-agent to the Write role at https://github.com/acme/app/settings/access"
sandbox
put "$stub/gh-agent/repo.acme__app.out" '{"permissions":{"admin":false,"maintain":true,"push":true,"pull":true}}'
run --check; rc=$?
check "maintain role: WRONG, blocks the apply" bash -c "test $rc = 1 && grep -q '^WRONG  repo acme/app: bot-agent holds the maintain role; it must be Write' '$dir/out'"
sandbox
rm "$stub/gh-agent/repo.acme__app.out"; put "$stub/gh-agent/repo.acme__app.err" "dial tcp: lookup api.github.com: no such host"; put "$stub/gh-agent/repo.acme__app.rc" 1
run --check
check "repo network failure: MISSING says network, not 'no access'" bash -c "grep -q '^MISSING  repo acme/app: could not reach github.com (network)' '$dir/out' && ! grep -q 'no access' '$dir/out'"
sandbox
put "$stub/gh-agent/rulesets.acme__app.out" '[{"id":5,"name":"main","enforcement":"active"},{"id":6,"name":"old","enforcement":"disabled"}]'
put "$stub/gh-agent/ruleset.5.out" '{"name":"main","current_user_can_bypass":"always"}'
run --check; rc=$?
check "ruleset bypass: WRONG" has "WRONG  repo acme/app: bot-agent can bypass the ruleset \"main\" (always)"
check "ruleset bypass: fix names the ruleset" has "  fix: remove the role bot-agent holds from the bypass list of \"main\" at https://github.com/acme/app/rules/5, or lower the account to Write"
check "ruleset bypass: disabled rulesets are not fetched" bash -c "! grep -q 'rulesets/6' '$stub/calls.log'"
sandbox
put "$stub/gh-agent/rulesets.acme__app.out" '[{"id":5,"name":"main","enforcement":"active"}]'
put "$stub/gh-agent/ruleset.5.out" '{"name":"main","current_user_can_bypass":"never"}'
run --check; rc=$?
check "ruleset without bypass: passes" test "$rc" = 0
sandbox
put "$stub/gh-agent/rulesets.acme__app.out" '[{"id":5,"name":"main","enforcement":"active"}]'
put "$stub/gh-agent/ruleset.5.out" '{"name":"main"}'
run --check; rc=$?
check "ruleset bypass unknown: WARN" bash -c "test $rc = 0 && grep -q '^WARN  repo acme/app: cannot tell whether bot-agent can bypass' '$dir/out'"
sandbox
rm "$stub/gh-agent/rulesets.acme__app.out"; put "$stub/gh-agent/rulesets.acme__app.err" "gh: Must have admin rights to Repository. (HTTP 403)"; put "$stub/gh-agent/rulesets.acme__app.rc" 1
run --check; rc=$?
check "rulesets unreadable: WARN" bash -c "test $rc = 0 && grep -q '^WARN  repo acme/app: its rulesets are not readable' '$dir/out'"
sandbox
cfg_set $'login=bot-agent\nemail=1+bot-agent@users.noreply.github.com\nssh_key=~/.ssh/agent_key\ngh_config_dir=~/.config/gh-agent\nrepos=acme/app,acme/two'
put "$stub/gh-agent/repo.acme__two.out" '{"permissions":{"push":false}}'
run --check; rc=$?
check "two repos: both reported, one failing" bash -c "test $rc = 1 && grep -q '^OK  repo acme/app: bot-agent can push' '$dir/out' && grep -q '^MISSING  repo acme/two: bot-agent has no access' '$dir/out'"

echo "== the next step is the earliest failing one"
sandbox
rm "$key" "$key.pub"
put "$stub/gh-agent/auth_status.out" "You are not logged into any GitHub hosts."; put "$stub/gh-agent/auth_status.rc" 1
put "$settings" '{"env":{"GIT_AUTHOR_EMAIL":"foreign@example.com"}}'
run --check; rc=$?
check "earliest: key (2) beats gh (4) and settings (6)" bash -c "test $rc = 1 && grep -c '^Next:' '$dir/out' | grep -q '^1$' && grep -q '^Next: step 2 of 6' '$dir/out'"
sandbox
put "$settings" '{"env":{"GIT_AUTHOR_EMAIL":"foreign@example.com"}}'
run --check
check "step 6 alone: Next names the settings conflict" bash -c "grep -q '^Next: step 6 of 6 — apply the identity to the Claude Code settings — if the agent identity should win' '$dir/out'"

# =================================================================================
echo "== step 6: settings.json"
sandbox
rm "$settings"
run --check; rc=$?
check "no settings: MISSING" has "MISSING  $settings does not exist"
check "no settings: exact fix" has "  fix: mkdir -p $home/.claude && printf '{}\\n' >$settings"
sandbox
printf '{ "model": ' >"$settings"; cp "$settings" "$dir/before"
run; rc=$?
check "invalid settings: WRONG, exit 1" bash -c "test $rc = 1 && grep -q '^WRONG  $settings is not a readable JSON object' '$dir/out'"
check "invalid settings: file untouched, no record" bash -c "cmp -s '$settings' '$dir/before' && test ! -e '$record' && test ! -e '$settings.agent-identity-backup'"
sandbox
put "$record" '[1]'
run --check
check "invalid record: WRONG" has "WRONG  $record is not a JSON object with an env object"
sandbox
put "$settings" '{"env":["x"]}'
run --check
check "env not an object: WRONG" has "WRONG  the env of $settings is not an object"

sandbox
put "$settings" '{"model":"opus","env":{"GIT_AUTHOR_EMAIL":"foreign@example.com","FOO":"bar"}}'
cp "$settings" "$dir/before"; snapshot >"$dir/snap.before"
run; rc=$?
snapshot >"$dir/snap.after"
check "conflict: exit 1" test "$rc" = 1
check "conflict: reported as CONFLICT with both values" has "WRONG  CONFLICT: env.GIT_AUTHOR_EMAIL in $settings is \"foreign@example.com\", which this script did not write; it would write \"1+bot-agent@users.noreply.github.com\""
check "conflict: exact fix" has "  fix: if the agent identity should win, delete \"GIT_AUTHOR_EMAIL\" from the env block of $settings and re-run; otherwise change the config to match"
check "conflict: nothing written, not even the other keys" cmp -s "$dir/snap.before" "$dir/snap.after"
check "conflict: says nothing was written" has "apply-agent-identity: nothing was written"

# --- a real run
sandbox
cp "$settings" "$dir/orig"
run; rc=$?
check "apply: exit 0" test "$rc" = 0
check "apply: GIT_AUTHOR_NAME" sx '.env.GIT_AUTHOR_NAME == "Claude Code" and .env.GIT_COMMITTER_NAME == "Claude Code"'
check "apply: GIT_AUTHOR_EMAIL and GIT_COMMITTER_EMAIL" sx '.env.GIT_AUTHOR_EMAIL == "1+bot-agent@users.noreply.github.com" and .env.GIT_COMMITTER_EMAIL == .env.GIT_AUTHOR_EMAIL'
check "apply: GIT_SSH_COMMAND names the expanded key, IdentitiesOnly" sx ".env.GIT_SSH_COMMAND == \"ssh -F /dev/null -i $key -o IdentitiesOnly=yes\""
check "apply: GH_CONFIG_DIR expanded" sx ".env.GH_CONFIG_DIR == \"$ghdir\""
check "apply: the guard's marker" sx '.env.JARVIS_AGENT_IDENTITY == "bot-agent"'
check "apply: every other key preserved (jq -S)" bash -c "jq -e '.env.JARVIS_AGENT_IDENTITY' '$settings' >/dev/null && diff <(jq -S 'del(.env.GIT_AUTHOR_NAME,.env.GIT_COMMITTER_NAME,.env.GIT_AUTHOR_EMAIL,.env.GIT_COMMITTER_EMAIL,.env.GIT_SSH_COMMAND,.env.GH_CONFIG_DIR,.env.JARVIS_AGENT_IDENTITY,.env.GIT_CONFIG_COUNT,.env.GIT_CONFIG_KEY_0,.env.GIT_CONFIG_VALUE_0,.env.GIT_CONFIG_KEY_1,.env.GIT_CONFIG_VALUE_1)' '$settings') <(jq -S . '$dir/orig')"
check "apply: the person's own env key survives" sx '.env.FOO == "bar"'
check "apply: record lists the twelve keys with their values" bash -c "jq -e '.version == 1 and (.env | keys | length) == 12 and .env.JARVIS_AGENT_IDENTITY == \"bot-agent\" and .env_created == false' '$record' >/dev/null"
check "apply: backup is the previous settings" cmp -s "$settings.agent-identity-backup" "$dir/orig"
check "apply: the guard's own backup name is not used" test ! -e "$settings.guard-backup"
check "apply: mode kept" bash -c "jq -e '.env.JARVIS_AGENT_IDENTITY' '$settings' >/dev/null && test \"\$(stat -c %a '$settings' 2>/dev/null || stat -f %Lp '$settings')\" = 600"
check "apply: record is private" test "$(mode "$record")" = 600
check "apply: says a new session picks it up" has "start a new Claude Code session"
check "apply: says the switch is not touched" has "JARVIS_REQUIRE_AGENT_IDENTITY switch is not touched"
check "apply: the switch is not written" bash -c "! grep -q JARVIS_REQUIRE_AGENT_IDENTITY '$settings'"
check "apply: no temporary file left" bash -c "test -e '$record' && test \$(ls '$home/.claude' | grep -c '\\.[A-Za-z0-9]\\{6\\}\$') = 0"

# git is forced onto SSH: an HTTPS remote must not reach the operator's credential helper
check "apply: forced-SSH git config keys written" sx '.env.GIT_CONFIG_COUNT == "2" and .env.GIT_CONFIG_KEY_0 == "url.git@github.com:.insteadOf" and .env.GIT_CONFIG_VALUE_0 == "https://github.com/" and .env.GIT_CONFIG_KEY_1 == "credential.helper" and .env.GIT_CONFIG_VALUE_1 == ""'
git init -q "$dir/clone"; git -C "$dir/clone" remote add origin https://github.com/o/r.git
printf '[credential]\n\thelper = "!f() { echo called >>%s/helper.log; }; f"\n' "$home" >"$home/.gitconfig"
gitenv=(); while IFS= read -r kv; do gitenv+=("$kv"); done < <(jq -r '.env | to_entries[] | "\(.key)=\(.value)"' "$settings")
gcmd() { # with or without the applied env, no system config, sandbox HOME
  if [ "$1" = with ]; then shift; env GIT_CONFIG_NOSYSTEM=1 HOME="$home" "${gitenv[@]}" "$@"
  else shift; env GIT_CONFIG_NOSYSTEM=1 HOME="$home" "$@"; fi
}
check "git: without the env the HTTPS remote is left as it is" test "$(gcmd without git -C "$dir/clone" ls-remote --get-url origin)" = "https://github.com/o/r.git"
check "git: with the env it resolves to SSH" test "$(gcmd with git -C "$dir/clone" ls-remote --get-url origin)" = "git@github.com:o/r.git"
check "git: with the env a push URL resolves to SSH too" test "$(gcmd with git -C "$dir/clone" remote get-url --push origin)" = "git@github.com:o/r.git"
check "git: with the env the last credential.helper is the empty reset" test "$(gcmd with git config --get-all credential.helper | tail -n 1)" = ""
rm -f "$home/helper.log"
printf 'protocol=https\nhost=github.com\n\n' | gcmd without env GIT_TERMINAL_PROMPT=0 git credential fill >/dev/null 2>&1
check "git: without the env the operator's credential helper is asked" test -f "$home/helper.log"
rm -f "$home/helper.log"
printf 'protocol=https\nhost=github.com\n\n' | gcmd with env GIT_TERMINAL_PROMPT=0 git credential fill >/dev/null 2>&1
check "git: with the env the credential helper is never asked" test ! -e "$home/helper.log"
rm -f "$home/.gitconfig"

cp "$settings" "$dir/after1"; cp "$record" "$dir/rec1"; cp "$settings.agent-identity-backup" "$dir/bak1"
run; rc=$?
check "idempotent: exit 0" test "$rc" = 0
check "idempotent: says already applied" has "already carries the agent identity"
check "idempotent: settings, record and backup unchanged" bash -c "cmp -s '$settings' '$dir/after1' && cmp -s '$record' '$dir/rec1' && cmp -s '$settings.agent-identity-backup' '$dir/bak1'"
run --check; rc=$?
check "check after apply: exit 0" test "$rc" = 0
check "check after apply: Next says it is applied" bash -c "grep -q '^Next: nothing — the identity is already applied' '$dir/out'"

# an edit to the config updates the keys this script owns
cfg_set $'login=bot-agent\nemail=2+bot-agent@users.noreply.github.com\nssh_key=~/.ssh/agent_key\ngh_config_dir=~/.config/gh-agent\nrepos=acme/app'
run; rc=$?
check "update: the script's own key follows the config" bash -c "test $rc = 0 && jq -e '.env.GIT_AUTHOR_EMAIL == \"2+bot-agent@users.noreply.github.com\"' '$settings' >/dev/null"
# someone changes a key the script wrote: reported, not overwritten
jq '.env.GIT_AUTHOR_NAME = "Somebody"' "$settings" >"$dir/t" && cp "$dir/t" "$settings"
run --check; rc=$?
check "changed since: reported as CONFLICT" bash -c "test $rc = 1 && grep -q 'CONFLICT: env.GIT_AUTHOR_NAME in $settings is \"Somebody\", but this script wrote \"Claude Code\" and someone changed it since' '$dir/out'"
run;
check "changed since: a real run does not overwrite it" sx '.env.GIT_AUTHOR_NAME == "Somebody"'

# a failing check writes nothing
sandbox
put "$stub/ssh.out" "git@github.com: Permission denied (publickey)."
snapshot >"$dir/snap.before"
run; rc=$?
snapshot >"$dir/snap.after"
check "no write on failure: exit 1" test "$rc" = 1
check "no write on failure: nothing changed" cmp -s "$dir/snap.before" "$dir/snap.after"
check "no write on failure: says so" has "apply-agent-identity: nothing was written"

# values someone already had, equal to ours, are not claimed
sandbox
put "$settings" '{"env":{"JARVIS_AGENT_IDENTITY":"bot-agent","FOO":"bar"}}'
run; rc=$?
check "equal value: accepted" test "$rc" = 0
check "equal value: not recorded as the script's own" bash -c "jq -e '(.env | has(\"JARVIS_AGENT_IDENTITY\") | not) and (.env | length) == 11' '$record' >/dev/null"
run --unapply; rc=$?
check "equal value: unapply leaves the person's key" bash -c "test $rc = 0 && jq -e '.env.JARVIS_AGENT_IDENTITY == \"bot-agent\" and .env.FOO == \"bar\" and (.env | length) == 2' '$settings' >/dev/null"

# git config in the settings env that the forced-SSH config would collide with
sandbox
put "$settings" '{"env":{"GIT_CONFIG_COUNT":"1","GIT_CONFIG_KEY_0":"core.editor","GIT_CONFIG_VALUE_0":"vim"}}'
cp "$settings" "$dir/before"
run; rc=$?
check "git config conflict: a foreign GIT_CONFIG_COUNT and KEY_0 are CONFLICTs, nothing renumbered" bash -c "test $rc = 1 && grep -q 'CONFLICT: env.GIT_CONFIG_COUNT in $settings is \"1\"' '$dir/out' && grep -q 'CONFLICT: env.GIT_CONFIG_KEY_0 in $settings is \"core.editor\"' '$dir/out' && cmp -s '$settings' '$dir/before' && test ! -e '$record'"
sandbox
put "$settings" '{"env":{"GIT_CONFIG_KEY_2":"x.y","GIT_CONFIG_PARAMETERS":"'"'"'credential.helper=store'"'"'"}}'
run --check; rc=$?
check "git config conflict: KEY_2 and GIT_CONFIG_PARAMETERS would undo the forced SSH" bash -c "test $rc = 1 && grep -q 'CONFLICT: env.GIT_CONFIG_KEY_2 in' '$dir/out' && grep -q 'CONFLICT: env.GIT_CONFIG_PARAMETERS in' '$dir/out' && grep -qF 'fix: delete \"GIT_CONFIG_KEY_2\" from the env block of $settings' '$dir/out'"
sandbox
put "$settings" '{"env":{"GIT_CONFIG_COUNT":"2","GIT_CONFIG_KEY_0":"url.git@github.com:.insteadOf","GIT_CONFIG_VALUE_0":"https://github.com/"}}'
run; rc=$?
check "git config: values equal to ours are accepted, the missing ones added" bash -c "test $rc = 0 && jq -e '.env.GIT_CONFIG_KEY_1 == \"credential.helper\"' '$settings' >/dev/null"

# a link keeps being a link
sandbox
mkdir -p "$dir/dotfiles"; mv "$settings" "$dir/dotfiles/settings.json"; ln -s "$dir/dotfiles/settings.json" "$settings"
run; rc=$?
check "link: exit 0" test "$rc" = 0
check "link: still a link, and written through" bash -c "test -L '$settings' && test -f '$dir/dotfiles/settings.json.agent-identity-backup'"
check "link: the target carries the identity" bash -c "jq -e '.env.JARVIS_AGENT_IDENTITY == \"bot-agent\"' '$dir/dotfiles/settings.json' >/dev/null"
check "link: the backup sits beside the target" test -f "$dir/dotfiles/settings.json.agent-identity-backup"

# settings saved while the script ran
sandbox
: >"$stub/touch_settings"
cp "$settings" "$dir/orig"
run; rc=$?
check "concurrent change: exit 2" test "$rc" = 2
check "concurrent change: refuses to write" has "changed while this ran; nothing was written, run it again"
check "concurrent change: no record, no backup, no temp file" bash -c "test ! -e '$record' && test ! -e '$settings.agent-identity-backup' && test \$(ls '$home/.claude' | wc -l) -eq 1"
check "concurrent change: the other writer's change is intact" bash -c "jq -e '.env | has(\"JARVIS_AGENT_IDENTITY\") | not' '$settings' >/dev/null"

# =================================================================================
echo "== --unapply"
sandbox
run; run --unapply; rc=$?
check "unapply: exit 0" test "$rc" = 0
check "unapply: settings back to the original under jq -S" bash -c "test -f '$settings.agent-identity-backup' && diff <(jq -S . '$settings') <(printf '%s' '$base_settings' | jq -S .)"
check "unapply: the record is gone" test ! -e "$record"
check "unapply: backup written" test -f "$settings.agent-identity-backup"
check "unapply: says what it removed" has "removed 12 key(s) from the env of $settings"
run --unapply; rc=$?
check "unapply: a second time has nothing to do" bash -c "test $rc = 0 && grep -q 'nothing to remove' '$dir/out'"

sandbox
put "$settings" '{"model":"opus"}'
cp "$settings" "$dir/orig"
run; run --unapply
check "unapply: an env block the script created goes with it" bash -c "test -f '$settings.agent-identity-backup' && diff <(jq -S . '$settings') <(jq -S . '$dir/orig')"
sandbox
put "$settings" '{"model":"opus","env":{}}'
cp "$settings" "$dir/orig"
run; run --unapply
check "unapply: an env block that was already there stays" bash -c "test -f '$settings.agent-identity-backup' && diff <(jq -S . '$settings') <(jq -S . '$dir/orig')"

sandbox
run
jq '.env.GH_CONFIG_DIR = "/somewhere/else"' "$settings" >"$dir/t" && cp "$dir/t" "$settings"
snapshot >"$dir/snap.before"
run --unapply; rc=$?
snapshot >"$dir/snap.after"
check "unapply conflict: exit 1" test "$rc" = 1
check "unapply conflict: reported" has "CONFLICT: env.GH_CONFIG_DIR in $settings is \"/somewhere/else\", but this script wrote"
check "unapply conflict: all or nothing, settings and record untouched" cmp -s "$dir/snap.before" "$dir/snap.after"

sandbox
rm "$record" 2>/dev/null
run --unapply; rc=$?
check "unapply without a record: exit 0, nothing to remove" bash -c "test $rc = 0 && grep -q '^OK  no record at $record: nothing to remove' '$dir/out'"
sandbox
run
printf '{ "x": ' >"$settings"
run --unapply; rc=$?
check "unapply on invalid settings: WRONG, exit 1" bash -c "test $rc = 1 && grep -q '^WRONG  $settings is not a readable JSON object' '$dir/out' && test -e '$record'"

# =================================================================================
echo "== --setup"
sandbox
rm "$cfg"
snapshot >"$dir/snap.before"
run --setup; rc=$?
snapshot >"$dir/snap.after"
check "setup without a terminal: exit 2" test "$rc" = 2
check "setup without a terminal: clear message" has "--setup is interactive and needs a terminal, but stdin is not one"
check "setup without a terminal: nothing created" cmp -s "$dir/snap.before" "$dir/snap.after"

# The prompts are driven by sourcing the script (it runs main only when executed)
# and feeding lines on stdin; nothing in a real run can do that.
setup_run() { # input file
  (cd "$dir" && base_env ${DET[@]+"${DET[@]}"} bash -c 'source "$1"; trap cleanup EXIT; init; setup_steps' _ "$apply" <"$1") >"$dir/out" 2>&1
}
host=$(hostname -s 2>/dev/null || hostname); host=$(printf '%s' "$host" | tr -c 'A-Za-z0-9_\n-' '_')

sandbox
rm "$cfg" "$key" "$key.pub"
put "$stub/ssh.out" "git@github.com: Permission denied (publickey)."; put "$stub/ssh.rc" 255
put "$stub/gh-agent/auth_status.out" "You are not logged into any GitHub hosts."; put "$stub/gh-agent/auth_status.rc" 1
cp "$settings" "$dir/settings.before"
cat >"$dir/input" <<EOF
bad_login
bot_agent
bot-agent
nope
1+bot-agent@users.noreply.github.com

~/.config/gh
~/.config/gh-agent
acme
acme/app

y
y


EOF
setup_run "$dir/input"; rc=$?
check "setup: exit 1 (steps still open)" test "$rc" = 1
check "setup: a bad login is refused and asked again" bash -c "test \$(grep -c 'not a GitHub login' '$dir/out') = 2"
check "setup: a bad email is refused" has "does not look like an email address"
check "setup: the operator's gh dir is refused" has "is the default gh config dir"
check "setup: a bad repos value is refused" has "\"acme\" is not owner/repo"
check "setup: the config file is created with mode 600" bash -c "test \$(stat -c %a '$cfg' 2>/dev/null || stat -f %Lp '$cfg') = 600 && grep -qx 'login=bot-agent' '$cfg' && grep -qx 'repos=acme/app' '$cfg' && grep -qx 'ssh_key=~/.ssh/id_ed25519_agent_claude_$host' '$cfg' && grep -qx 'gh_config_dir=~/.config/gh-agent' '$cfg' && grep -qx 'author_name=Claude Code' '$cfg'"
check "setup: the config directory is private" test "$(mode "$cfgdir")" = 700
dkey="$home/.ssh/id_ed25519_agent_claude_$host"
check "setup: the key is generated by ssh-keygen -t ed25519 with an empty passphrase" bash -c "grep -q \"^ssh-keygen -t ed25519 -N  -C bot-agent@$host -f $dkey\$\" '$stub/calls.log' && test -f '$dkey' && test -f '$dkey.pub'"
check "setup: shows the .pub and where to add it" bash -c "grep -q 'AAAAFAKEKEY' '$dir/out' && grep -q 'Settings -> SSH and GPG keys -> New SSH key' '$dir/out' && grep -q 'Sign in to GitHub as bot-agent' '$dir/out'"
check "setup: prints the gh auth login command for the agent's config dir" has "    GH_CONFIG_DIR=$ghdir gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key --web"
check "setup: ends with the full check and a Next line" bash -c "grep -q '== The full check' '$dir/out' && grep -q '^Next: step 3 of 6' '$dir/out'"
check "setup: never writes settings.json" bash -c "cmp -s '$settings' '$dir/settings.before' && test ! -e '$record' && test ! -e '$settings.agent-identity-backup'"
check "setup: never ran the operator's gh" bash -c "! grep -q 'gh GH_CONFIG_DIR=<unset> auth' '$stub/calls.log'"

# an existing key is never overwritten or modified
sandbox
put "$key" "PRECIOUS KEY"; chmod 600 "$key"
put "$key.pub" "ssh-ed25519 AAAAPRECIOUS owner"
cksum <"$key" >"$dir/key.sum"; cksum <"$key.pub" >"$dir/pub.sum"
ls -l "$key" >"$dir/key.ls"
: >"$dir/input"
setup_run "$dir/input"; rc=$?
check "setup, key exists: left byte-identical" bash -c "cmp -s <(cksum <'$key') '$dir/key.sum' && cmp -s <(cksum <'$key.pub') '$dir/pub.sum' && cmp -s <(ls -l '$key') '$dir/key.ls'"
check "setup, key exists: ssh-keygen was not run" bash -c "! grep -q '^ssh-keygen' '$stub/calls.log'"
check "setup, key exists: says it left the key alone" has "the key file already exists: left untouched, never overwritten."
sandbox
rm "$key"
put "$key.pub" "ssh-ed25519 AAAAPRECIOUS owner"
: >"$dir/input"
setup_run "$dir/input"
check "setup, only a .pub exists: refuses to generate over it" bash -c "grep -q 'ssh-keygen would overwrite that .pub' '$dir/out' && ! grep -q '^ssh-keygen' '$stub/calls.log'"
sandbox
rm "$key" "$key.pub"
printf 'n\n' >"$dir/input"
setup_run "$dir/input"
check "setup, key generation declined: no key made" bash -c "grep -q 'skipped: no key was generated' '$dir/out' && ! grep -q '^ssh-keygen' '$stub/calls.log' && test ! -e '$key'"

# safe to rerun: everything done, nothing asked
sandbox
snapshot >"$dir/snap.before"
: >"$dir/input"
setup_run "$dir/input"; rc=$?
snapshot >"$dir/snap.after"
check "setup rerun: exit 0, all done" test "$rc" = 0
check "setup rerun: says what it skipped" bash -c "grep -q 'already exists: left as it is' '$dir/out' && grep -q 'left untouched' '$dir/out' && grep -q 'nothing to add' '$dir/out' && grep -q 'nothing to do' '$dir/out' && grep -q 'Step 5 of 5' '$dir/out'"
check "setup rerun: changes no file" cmp -s "$dir/snap.before" "$dir/snap.after"
check "setup rerun: Next line" hasl "Next: run without --check to apply"
sandbox
rm "$cfg"
: >"$dir/input"
setup_run "$dir/input"; rc=$?
check "setup: input ending early stops with exit 2 and creates nothing" bash -c "test $rc = 2 && grep -q 'input ended' '$dir/out' && test ! -e '$cfg'"
sandbox
rm "$cfg"
printf 'bot-agent\na@b.co\n\n\nacme/app\n\nn\n' >"$dir/input"
setup_run "$dir/input"
check "setup: declining the file creates nothing" bash -c "grep -q 'skipped: no file was created' '$dir/out' && test ! -e '$cfg'"
sandbox
rm "$cfg"; : >"$cfg"; chmod 600 "$cfg"; rm "$cfg"; cfg_set $'login=bot-agent\nemail=nope'
: >"$dir/input"
setup_run "$dir/input"; rc=$?
check "setup: an existing but broken config file is reported, not rewritten" bash -c "grep -q 'WRONG  config line 2' '$dir/out' && grep -q '^email=nope\$' '$cfg'"

# step 5 in setup: pending invitation
sandbox
rm "$stub/gh-agent/repo.acme__app.out"; put "$stub/gh-agent/repo.acme__app.err" "gh: Not Found (HTTP 404)"; put "$stub/gh-agent/repo.acme__app.rc" 1
put "$stub/gh-agent/invitations.out" '[{"id":7,"repository":{"full_name":"acme/app"}}]'
printf '\n' >"$dir/input"
setup_run "$dir/input"; rc=$?
check "setup step 5: pending invitation, with the accept line" bash -c "grep -q 'Step 5 of 5' '$dir/out' && grep -qF 'fix: as bot-agent, accept the invitation at https://github.com/acme/app/invitations (or github.com/notifications)' '$dir/out' && test $rc = 1"
sandbox
put "$stub/gh-agent/repo.acme__app.out" '{"permissions":{"push":false}}'
printf '\n' >"$dir/input"
setup_run "$dir/input"
check "setup step 5: not invited, with the invite line" bash -c "grep -qF 'fix: as the owner of acme/app, invite bot-agent with Write: https://github.com/acme/app/settings/access' '$dir/out'"

# With a real pseudo-terminal the TTY gate passes and the flow runs end to end.
if command -v python3 >/dev/null; then
  sandbox
  (cd "$dir" && base_env python3 -I - "$apply" --setup <<'PY'
import os, pty, sys
import signal
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash"] + sys.argv[1:])
signal.signal(signal.SIGALRM, lambda *a: (os.kill(pid, signal.SIGKILL), os._exit(124)))
signal.alarm(300)
out = b""
while True:
    try:
        d = os.read(fd, 4096)
    except OSError:
        break
    if not d:
        break
    out += d
_, st = os.waitpid(pid, 0)
sys.stdout.buffer.write(out)
sys.exit(os.WEXITSTATUS(st))
PY
  ) >"$dir/out" 2>&1; rc=$?
  check "setup on a pseudo-terminal: runs, skips what is done, exits 0" bash -c "test $rc = 0 && grep -q 'Step 5 of 5' '$dir/out' && grep -q 'Next: run without --check to apply' '$dir/out'"
fi

# =================================================================================
# =================================================================================
echo "== the machine account must not be the owner's account in disguise"
# The reproduced case: a new machine, so the operator's own gh is not logged in and
# that comparison can only warn; login is the owner's account and holds admin.
sandbox
rm "$stub/gh-operator/user.out"; put "$stub/gh-operator/user.err" "To get started with GitHub CLI, please run:  gh auth login"; put "$stub/gh-operator/user.rc" 1
put "$stub/gh-agent/repo.acme__app.out" '{"owner":{"login":"Bot-Agent","type":"User"},"permissions":{"admin":true,"maintain":true,"push":true,"pull":true}}'
snapshot >"$dir/snap.before"
run; rc=$?
snapshot >"$dir/snap.after"
check "owner is login: exit 1 although the operator comparison could only warn" test "$rc" = 1
check "owner is login: WRONG names the repo and the account" has "WRONG  repo acme/app: bot-agent owns it, so the agent would be the owner and could approve its own work"
check "owner is login: exact fix" has "  fix: use a separate machine account as login= in $cfg; bot-agent must not be the owner of acme/app"
check "owner is login: the operator comparison is still only a WARN" bash -c "grep -q '^WARN  the operator.s own gh is not logged in' '$dir/out'"
check "owner is login: a real run writes nothing" cmp -s "$dir/snap.before" "$dir/snap.after"
check "owner is login: Next names step 5" bash -c "grep -q '^Next: step 5 of 6' '$dir/out'"
sandbox
rm "$stub/gh-operator/user.out"; put "$stub/gh-operator/user.err" "To get started with GitHub CLI, please run:  gh auth login"; put "$stub/gh-operator/user.rc" 1
put "$stub/gh-agent/repo.acme__app.out" '{"owner":{"login":"someone","type":"User"},"permissions":{"admin":true,"push":true}}'
snapshot >"$dir/snap.before"
run; rc=$?
snapshot >"$dir/snap.after"
check "admin, operator not logged in: exit 1 and nothing written" bash -c "test $rc = 1" 
check "admin, operator not logged in: WRONG, not WARN" has "WRONG  repo acme/app: bot-agent holds the admin role; it must be Write"
check "admin, operator not logged in: nothing written" cmp -s "$dir/snap.before" "$dir/snap.after"
sandbox
put "$stub/gh-agent/repo.acme__app.out" '{"owner":{"login":"acme","type":"Organization"},"permissions":{"admin":false,"push":true}}'
put "$stub/gh-agent/membership.acme.out" '{"state":"active","role":"admin"}'
run; rc=$?
check "organization owner: WRONG" bash -c "test $rc = 1 && grep -q '^WRONG  repo acme/app: bot-agent is an owner of the organization acme' '$dir/out'"
check "organization owner: exact fix" has "  fix: make bot-agent a plain member (https://github.com/orgs/acme/people) or use a separate machine account"
sandbox
put "$stub/gh-agent/repo.acme__app.out" '{"owner":{"login":"acme","type":"Organization"},"permissions":{"admin":false,"push":true}}'
put "$stub/gh-agent/membership.acme.out" '{"state":"active","role":"member"}'
run; rc=$?
check "organization member: passes" test "$rc" = 0
sandbox
put "$stub/gh-agent/repo.acme__app.out" '{"owner":{"login":"acme","type":"Organization"},"permissions":{"admin":false,"push":true}}'
run; rc=$?
check "organization membership unreadable: not guessed, the other checks decide" test "$rc" = 0

echo "== the environment the agent inherits, not only the settings"
sandbox
XENV="GH_HOST=ghe.example.com"
run --check; rc=$?
check "process GH_HOST: WRONG" bash -c "test $rc = 1 && grep -q '^WRONG  GH_HOST is set in this process; it would send gh to another host' '$dir/out'"
check "process GH_HOST: fix names the shell profile" bash -c "grep -q '  fix: unset GH_HOST   (and remove the line that exports it from your shell profile' '$dir/out'"
sandbox
XENV="GIT_CONFIG_PARAMETERS=x.y=z"
run --check; rc=$?
check "process GIT_CONFIG_PARAMETERS: WRONG" bash -c "test $rc = 1 && grep -q '^WRONG  GIT_CONFIG_PARAMETERS is set in this process; it would override the agent.s git config' '$dir/out'"
sandbox
XENV="GH_CONFIG_DIR=/elsewhere/gh"
run --check; rc=$?
check "process GH_CONFIG_DIR of another login: WRONG" bash -c "test $rc = 1 && grep -q '^WRONG  GH_CONFIG_DIR is set in this process; it points gh at another login' '$dir/out'"
sandbox
XENV="GH_CONFIG_DIR=$ghdir"
run --check; rc=$?
check "process GH_CONFIG_DIR equal to the agent's own (an applied session): accepted" test "$rc" = 0
sandbox
put "$settings" '{"env":{"GH_HOST":"ghe.example.com"}}'
run --check
check "settings GH_HOST: WRONG" has "WRONG  GH_HOST is set in the env of $settings; it would override the agent's gh login"

echo "== git under the agent's env: HTTPS GitHub remotes become SSH, whatever ~/.gitconfig says"
sandbox
run --check; rc=$?
check "git urls: the pass case shows the rewrite for fetch and push" has "OK  git: https://github.com/acme/app.git fetches and pushes as git@github.com:acme/app.git under the agent's env"
sandbox
printf '[url "ssh://other.example/"]\n\tinsteadOf = https://github.com/acme/\n' >"$home/.gitconfig"
run --check; rc=$?
check "foreign insteadOf that wins: exit 1, WRONG with both URLs" bash -c "test $rc = 1 && grep -q '^WRONG  git: https://github.com/acme/app.git becomes ssh://other.example/app.git (fetch)' '$dir/out'"
check "foreign insteadOf that wins: the offending config line is shown" bash -c "grep -q 'file:$home/.gitconfig.*url.ssh://other.example/.insteadof' '$dir/out'"
check "foreign insteadOf that wins: Next names step 6" bash -c "grep -q '^Next: step 6 of 6 — apply the identity to the Claude Code settings — remove or change the url rewrite that wins' '$dir/out'"
sandbox
printf '[url "https://evil.example/"]\n\tpushInsteadOf = https://github.com/\n' >"$home/.gitconfig"
run --check; rc=$?
check "foreign pushInsteadOf: WRONG, the push URL is the one shown" bash -c "test $rc = 1 && grep -q '(fetch) and https://evil.example/acme/app.git (push)' '$dir/out' && grep -q 'url.https://evil.example/.pushinsteadof' '$dir/out'"
sandbox
printf '[url "ssh://x.example/"]\n\tinsteadOf = https://example.org/\n' >"$home/.gitconfig"
run --check; rc=$?
check "an unrelated url rewrite is left alone" test "$rc" = 0

echo "== ssh ignores ~/.ssh/config, so it cannot add the operator's key"
sandbox
printf 'Host github.com\n  IdentityFile /elsewhere/operator_key\n' >"$home/.ssh/config"
run --check; rc=$?
check "ssh config with another IdentityFile: the check passes because -F /dev/null is used" test "$rc" = 0
check "ssh config with another IdentityFile: ssh -G was run with -F /dev/null" bash -c "grep -q 'ssh -G -F /dev/null -i $key -o IdentitiesOnly=yes github.com' '$stub/calls.log'"
check "ssh config with another IdentityFile: only the agent key is offered" has "OK  ssh offers only the agent key $key under the command git will run"
sandbox
put "$stub/ssh.G.extra" "identityfile /elsewhere/operator_key"
run --check; rc=$?
check "another identity file still offered: WRONG" bash -c "test $rc = 1 && grep -q '^WRONG  ssh would offer identity files other than the agent key $key: ' '$dir/out'"
real_ssh=$(PATH="$orig_path" command -v ssh || true)
if [ -n "$real_ssh" ]; then
  sandbox
  printf 'Host github.com\n  IdentityFile /elsewhere/operator_key\n' >"$home/.ssh/config"
  # (ssh takes the home directory from the passwd entry, not $HOME, so the sandbox config is named with -F)
  with_cfg=$("$real_ssh" -G -F "$home/.ssh/config" -i "$key" -o IdentitiesOnly=yes github.com 2>/dev/null | awk 'tolower($1)=="identityfile"{print $2}' | tr '\n' ' ')
  without_cfg=$("$real_ssh" -G -F /dev/null -i "$key" -o IdentitiesOnly=yes github.com 2>/dev/null | awk 'tolower($1)=="identityfile"{print $2}' | tr '\n' ' ')
  check "real ssh -G: a user config adds the operator's key" bash -c "case '$with_cfg' in *operator_key*) true;; *) false;; esac"
  check "real ssh -G with -F /dev/null: the agent key alone" test "$without_cfg" = "$key "
fi

echo "== the operator's own SSH identity (covers an org Write account when the operator's gh is logged out)"
sandbox
run --check
check "operator ssh: a different account is fine" has "OK  the operator's own SSH identity (owner-person) differs from login=bot-agent"
check "operator ssh: asked with no -i and the normal config" bash -c "grep -qx 'ssh -T -o BatchMode=yes -o ConnectTimeout=15 git@github.com' '$stub/calls.log'"
sandbox
put "$stub/ssh.default.out" "Hi bot-agent! You've successfully authenticated, but GitHub does not provide shell access."
rm "$stub/gh-operator/user.out"; put "$stub/gh-operator/user.err" "To get started with GitHub CLI, please run:  gh auth login"; put "$stub/gh-operator/user.rc" 1
snapshot >"$dir/snap.before"
run; rc=$?
snapshot >"$dir/snap.after"
check "operator ssh is the agent, operator gh logged out: exit 1" test "$rc" = 1
check "operator ssh is the agent: WRONG naming the answer" has "WRONG  login=bot-agent is the account the operator's own SSH key authenticates as (ssh git@github.com answers \"Hi bot-agent!\"): the agent would be the owner again"
check "operator ssh is the agent: exact fix" has "  fix: create a separate machine account on GitHub and set login= (and its key and gh login) to that account in $cfg"
check "operator ssh is the agent: a real run writes nothing" cmp -s "$dir/snap.before" "$dir/snap.after"
sandbox
put "$stub/ssh.default.out" "git@github.com: Permission denied (publickey)."; put "$stub/ssh.default.rc" 255
run --check; rc=$?
check "operator ssh refused: no conclusion, not an error" bash -c "test $rc = 0 && grep -q '^SKIP  the operator.s own SSH identity could not be read (no key offered or refused)' '$dir/out'"
sandbox
put "$stub/ssh.default.out" "ssh: Could not resolve hostname github.com: nodename nor servname provided, or not known"; put "$stub/ssh.default.rc" 255
run --check; rc=$?
check "operator ssh unreachable: no conclusion, not an error" bash -c "test $rc = 0 && grep -q '^SKIP  the operator.s own SSH identity could not be read (network)' '$dir/out'"

echo "== git: the SSH form must stay SSH too"
sandbox
run --check
check "ssh form: the pass case shows both forms" bash -c "grep -q '^OK  git: https://github.com/acme/app.git fetches and pushes as git@github.com:acme/app.git' '$dir/out' && grep -q '^OK  git: git@github.com:acme/app.git fetches and pushes as git@github.com:acme/app.git' '$dir/out'"
sandbox
printf '[url "https://github.com/"]\n\tinsteadOf = git@github.com:\n' >"$home/.gitconfig"
run --check; rc=$?
check "global insteadOf turning SSH into HTTPS: WRONG" bash -c "test $rc = 1 && grep -q '^WRONG  git: git@github.com:acme/app.git becomes https://github.com/acme/app.git (fetch) and https://github.com/acme/app.git (push)' '$dir/out'"
check "global insteadOf turning SSH into HTTPS: the offending line" bash -c "grep -q 'file:$home/.gitconfig.*url.https://github.com/.insteadof' '$dir/out'"
sandbox
printf '[url "https://github.com/"]\n\tpushInsteadOf = git@github.com:\n' >"$home/.gitconfig"
run --check; rc=$?
check "global pushInsteadOf turning SSH into HTTPS for push: WRONG" bash -c "test $rc = 1 && grep -q '^WRONG  git: git@github.com:acme/app.git becomes git@github.com:acme/app.git (fetch) and https://github.com/acme/app.git (push)' '$dir/out' && grep -q 'url.https://github.com/.pushinsteadof' '$dir/out'"

echo "== setup without gh installed"
mkdir -p "$root/bin-nogh"
for tool in bash git jq sed tr cat cut grep wc awk head tail mkdir rm mv cp mktemp stat dirname basename readlink cksum env ls chmod hostname sort find uname date ln touch id python3 perl tee printf test; do
  p=$(PATH="$orig_path" command -v "$tool" 2>/dev/null) && [ -x "$p" ] && ln -sf "$p" "$root/bin-nogh/$tool"
done
ln -sf "$root/bin/ssh" "$root/bin-nogh/ssh"; ln -sf "$root/bin/ssh-keygen" "$root/bin-nogh/ssh-keygen"
sandbox
: >"$dir/input"
TEST_PATH="$root/bin-nogh" setup_run "$dir/input"; rc=$?
check "setup without gh: no unbound-variable crash" hasn "unbound variable"
check "setup without gh: says how to install gh" has "gh is not installed. Install it (brew install gh, or see https://cli.github.com), then re-run --setup."
check "setup without gh: continues to the full check" bash -c "grep -q '== The full check' '$dir/out' && grep -q '^MISSING  gh is not installed' '$dir/out'"
check "setup without gh: exit 1 (gh still missing)" test "$rc" = 1

echo "== smaller things"
sandbox
run --check
check "no warnings: no '(0 warning(s))'" bash -c "grep -q '^apply-agent-identity: all checks passed\$' '$dir/out'"
sandbox
put "$stub/gh-agent/auth_status.out" $'github.com\n  \xe2\x9c\x93 Logged in to github.com account bot-agent (keyring)\n\n  \xe2\x9c\x93 Logged in to github.com account other (keyring)'
run --check
check "one warning: counted" has "apply-agent-identity: all checks passed (1 warning(s))"
sandbox
put "$stub/ssh.out" "ssh: Could not resolve hostname github.com: nodename nor servname provided, or not known"; put "$stub/ssh.rc" 255
run --check
check "ssh network failure: Next says reach github.com, not step 3" hasl "Next: reach github.com (steps 3 to 5 need it) — check the network or proxy, then re-run: ssh -T -F /dev/null -i $key -o IdentitiesOnly=yes git@github.com"
sandbox
put "$stub/gh-agent/auth_status.out" "error connecting to api.github.com"; put "$stub/gh-agent/auth_status.rc" 1
run --check
check "gh network failure: Next says reach github.com" hasl "Next: reach github.com (steps 3 to 5 need it) — check the network or proxy, then re-run this check"
sandbox
rm "$stub/gh-agent/repo.acme__app.out"; put "$stub/gh-agent/repo.acme__app.err" "dial tcp: lookup api.github.com: no such host"; put "$stub/gh-agent/repo.acme__app.rc" 1
run --check
check "repo network failure: Next says reach github.com" hasl "Next: reach github.com (steps 3 to 5 need it) — check the network or proxy, then re-run this check"
sandbox
rm "$key"
put "$stub/ssh.out" "ssh: Could not resolve hostname github.com"; put "$stub/ssh.rc" 255
run --check
check "a missing key (step 2) still comes before a network failure" bash -c "grep -q '^Next: step 2 of 6' '$dir/out'"
sandbox
printf 'author_name=Bot\r\n' >>"$cfg"
run --check
fixcmd=$(sed -n 's/^  fix: edit line 7 of [^:]*: save the file with LF line endings (\(.*\))$/\1/p' "$dir/out")
bash -c "$fixcmd"
check "CRLF fix: removes the CR and keeps mode 600" bash -c "test \$(stat -c %a '$cfg' 2>/dev/null || stat -f %Lp '$cfg') = 600 && ! grep -q \$'\\r' '$cfg' && test ! -e '$cfg.new'"
run --check; rc=$?
check "CRLF fix: the file then passes" test "$rc" = 0
check "docs: the login command is explained once in the script" bash -c "grep -c 'setup-git' '$repo/scripts/apply-agent-identity.sh' | grep -q '^1\$'"

# =================================================================================
echo "== --codex: the same account, Codex's own key, a policy block in config.toml"
tpy=""
for p in $(type -ap python3 python3.14 python3.13 python3.12 python3.11 2>/dev/null); do
  if "$p" -I -c 'import tomllib' 2>/dev/null; then tpy=$p; break; fi
done
check "codex: a python3 with tomllib (3.11+) is on PATH for these cases" test -n "$tpy"
toml_orig=$'model = "gpt-5"\n\n[projects."/nonexistent/trusted"]\ntrust_level = "trusted"\n'
csandbox() { # a machine where every --codex check passes
  sandbox
  put "$toml" "$toml_orig"
  cfg_append 'codex_ssh_key=~/.ssh/codex_key'
  put "$ckey" "FAKE CODEX KEY"; chmod 600 "$ckey"
  put "$ckey.pub" "ssh-ed25519 AAAAFAKECODEX bot-agent"
}
crun() { run --codex "$@"; }
expect_cg() {
  printf '# Written by apply-agent-identity.sh --codex: the global Git config of commands Codex runs. Change it through that script.\n[include]\n\tpath = %s\n\tpath = %s\n[credential]\n\thelper =\n[url "git@github.com:"]\n\tinsteadOf = https://github.com/\n' \
    "$home/.config/git/config" "$home/.gitconfig"
}
expect_set() { # author name
  printf 'set = { GIT_AUTHOR_NAME = "%s", GIT_COMMITTER_NAME = "%s", GIT_AUTHOR_EMAIL = "1+bot-agent@users.noreply.github.com", GIT_COMMITTER_EMAIL = "1+bot-agent@users.noreply.github.com", GIT_SSH_COMMAND = "ssh -F /dev/null -i %s -o IdentitiesOnly=yes", GIT_CONFIG_GLOBAL = "%s", GH_CONFIG_DIR = "%s", JARVIS_AGENT_IDENTITY = "bot-agent", GH_TOKEN = "", GITHUB_TOKEN = "", GH_ENTERPRISE_TOKEN = "", GITHUB_ENTERPRISE_TOKEN = "", GH_HOST = "", GIT_TERMINAL_PROMPT = "0", GIT_ASKPASS = "/usr/bin/false", SSH_ASKPASS = "/usr/bin/false" }' \
    "${1:-Codex}" "${1:-Codex}" "$ckey" "$cg" "$ghdir"
}
expect_block() {
  printf '%s\n[shell_environment_policy]\n%s\n%s\n' "# >>> jarvis agent-identity: written by apply-agent-identity.sh --codex; change it through that script" "$(expect_set "${1:-Codex}")" "# <<< jarvis agent-identity"
}
table_set() { "$tpy" -I -c 'import sys,tomllib,json; c=tomllib.load(open(sys.argv[1],"rb")); print(json.dumps(c["shell_environment_policy"]["set"],sort_keys=True,separators=(",",":"),ensure_ascii=False))' "$1"; }
prefix_ok() { "$tpy" -I -c 'import sys; sys.exit(0 if open(sys.argv[1],"rb").read().startswith(open(sys.argv[2],"rb").read()) else 1)' "$1" "$2"; }
export -f prefix_ok; export tpy
sha_of() { "$tpy" -I -c 'import sys,hashlib; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

# --- the checks
csandbox
snapshot >"$dir/snap.before"
crun --check; rc=$?
snapshot >"$dir/snap.after"
check "codex pass: exit 0" test "$rc" = 0
check "codex pass: no MISSING or WRONG line" bash -c "! grep -Eq '^(MISSING|WRONG)  ' '$dir/out'"
check "codex pass: every line has the documented shape" bash -c "! grep -Ev '^(OK|WARN|SKIP|MISSING|WRONG)  |^  fix: |^       |^Next: |^apply-agent-identity: ' '$dir/out' | grep -q ."
check "codex pass: the config values name Codex as the author" has "author_name=Codex"
check "codex pass: SSH answer verified for Codex's own key" has "OK  SSH: GitHub answers \"Hi bot-agent!\" for $ckey"
check "codex pass: ssh -G offers only Codex's key" has "OK  ssh offers only the agent key $ckey under the command git will run"
check "codex pass: the Claude key is never probed" bash -c "! grep -q -- '-i $key ' '$stub/calls.log'"
check "codex pass: one OK line for the tokens, from the policy" has "OK  the policy this script writes blanks GH_TOKEN, GITHUB_TOKEN, GH_ENTERPRISE_TOKEN, GITHUB_ENTERPRISE_TOKEN and GH_HOST for every command Codex runs"
check "codex pass: config.toml parses and has no policy" bash -c "grep -q '^OK  $toml parses as TOML' '$dir/out' && grep -q '^OK  $toml has no shell_environment_policy: the block can be appended' '$dir/out'"
check "codex pass: git resolution under Codex's env, fetch and push, both forms" bash -c "grep -q '^OK  git: https://github.com/acme/app.git fetches and pushes as git@github.com:acme/app.git under Codex.s env' '$dir/out' && grep -q '^OK  git: git@github.com:acme/app.git fetches and pushes as git@github.com:acme/app.git under Codex.s env' '$dir/out'"
check "codex pass: the last credential.helper is the empty reset" has "OK  git: the last credential.helper under Codex's env is the empty reset, so the operator's helper is never asked"
check "codex pass: Next line" hasl "Next: run without --check to apply"
check "codex pass: --check writes nothing" cmp -s "$dir/snap.before" "$dir/snap.after"
check "codex pass: no Claude settings message" hasn "$settings"
csandbox
rm "$settings"
XENV="GH_TOKEN=ghp_notreal GIT_CONFIG_PARAMETERS='core.abbrev=9'"
crun --check; rc=$?
check "codex: Claude's settings and this process's tokens are irrelevant" test "$rc" = 0

echo "== --codex: usage"
csandbox
for args in "--codex --codex" "--codex --check --unapply" "--check --codex --setup" "--codex --bogus"; do
  # shellcheck disable=SC2086
  run $args; rc=$?
  check "codex usage: '$args' exits 2" test "$rc" = 2
done
run --check --codex; rc=$?
check "codex usage: --check --codex (either order) works" test "$rc" = 0
run --codex --help; rc=$?
check "codex usage: --help prints the --codex line" bash -c "test $rc = 0 && grep -q '^Usage: apply-agent-identity.sh \\[--codex\\] \\[--check | --setup | --unapply\\]' '$dir/out'"

echo "== --codex: step 1, the two new config keys"
sandbox
crun --check; rc=$?
check "no codex_ssh_key: exit 1" test "$rc" = 1
check "no codex_ssh_key: MISSING" has "MISSING  config key codex_ssh_key (required for --codex) is not in $cfg"
check "no codex_ssh_key: the fix is the exact line to append" has "  fix: append Codex's key to $cfg: printf '%s\\n' 'codex_ssh_key=~/.ssh/id_ed25519_agent_codex_$host' >>$cfg   (or: bash $apply --setup --codex)"
check "no codex_ssh_key: Next names step 1" hasl "Next: step 1 of 6 — create the config file — append Codex's key to $cfg: printf '%s\\n' 'codex_ssh_key=~/.ssh/id_ed25519_agent_codex_$host' >>$cfg   (or: bash $apply --setup --codex)"
check "no codex_ssh_key: the SSH check is skipped, not guessed" has "SKIP  SSH key and GitHub's answer to it (need a valid login and codex_ssh_key in the config)"
run --check; rc=$?
check "no codex_ssh_key: Claude mode does not need it" test "$rc" = 0
crun --check
fixline=$(sed -n "s/^  fix: append Codex's key to [^:]*: \\(printf .*\\)   (or: .*)\$/\\1/p" "$dir/out" | head -n 1)
bash -c "$fixline"
check "no codex_ssh_key: running the fix line appends exactly that line" bash -c "tail -n 1 '$cfg' | grep -qx 'codex_ssh_key=~/.ssh/id_ed25519_agent_codex_$host'"
sandbox
cfg_append 'codex_ssh_key=~/.ssh/agent_key'
crun --check; rc=$?
check "same key: exit 1" test "$rc" = 1
check "same key: WRONG naming both lines" has "WRONG  config line 7: codex_ssh_key=~/.ssh/agent_key is the same key as ssh_key=~/.ssh/agent_key (line 4); Codex's key must be its own, so it can be revoked alone"
check "same key: exact fix" has "  fix: edit line 7 of $cfg: give codex_ssh_key another path, for example ~/.ssh/id_ed25519_agent_codex_$host"
check "same key: Next names step 1" bash -c "grep -q '^Next: step 1 of 6 — create the config file — edit line 7 of $cfg: give codex_ssh_key another path' '$dir/out'"
run --check; rc=$?
check "same key: Claude mode ignores the codex keys" test "$rc" = 0
sandbox
ln -s "$key" "$home/.ssh/alias_key"
cfg_append 'codex_ssh_key=~/.ssh/alias_key'
crun --check
check "same key through a link: still the same key" has "is the same key as ssh_key"
sandbox
cfg_append 'codex_ssh_key=keys/x'
run --check; rc=$?
check "codex_ssh_key syntax is checked in Claude mode too" bash -c "test $rc = 1 && grep -qF 'WRONG  config line 7: codex_ssh_key=keys/x must be an absolute path or start with ~/' '$dir/out'"
sandbox
cfg_append 'codex_ssh_key=~/.ssh/a'; cfg_append 'codex_ssh_key=~/.ssh/b'
run --check
check "codex_ssh_key duplicate: reported with the first line" has "WRONG  config line 8: duplicate key \"codex_ssh_key\" (first on line 7)"
sandbox
cfg_append 'codex_author_name='
run --check
check "codex_author_name empty: reported" has "WRONG  config line 7: codex_author_name has an empty value"
sandbox
cfg_append 'codex_author_name="Bot"'
run --check
check "codex_author_name quotes: reported" has "WRONG  config line 7: codex_author_name has quotes around its value"
csandbox
cfg_append 'codex_author_name=Co<dex'
crun --check; rc=$?
check "codex_author_name with <: WRONG" bash -c "test $rc = 1 && grep -qF 'WRONG  config line 8: codex_author_name=Co<dex must not contain control characters, < or >' '$dir/out'"

echo "== --codex: step 2 and 3, Codex's key"
csandbox
rm "$ckey" "$ckey.pub"
crun --check; rc=$?
check "codex key missing: MISSING" has "MISSING  SSH key file $ckey does not exist"
check "codex key missing: exact fix names --setup --codex" has "  fix: ssh-keygen -t ed25519 -N '' -C bot-agent -f $ckey   (or: bash $apply --setup --codex)"
check "codex key missing: Next names step 2" bash -c "grep -q '^Next: step 2 of 6' '$dir/out'"
csandbox
chmod 644 "$ckey"
crun --check
check "codex key mode: WRONG with the chmod fix" bash -c "grep -qF 'WRONG  SSH key $ckey has mode 644' '$dir/out' && grep -qxF '  fix: chmod 600 $ckey' '$dir/out'"
csandbox
put "$stub/ssh.codex_key.out" "Hi owner-person! You've successfully authenticated, but GitHub does not provide shell access."
crun --check; rc=$?
check "codex key answers for another login: exit 1" test "$rc" = 1
check "codex key answers for another login: WRONG names both" has "WRONG  SSH: $ckey authenticates as owner-person, but the config says login=bot-agent"
check "codex key answers for another login: exact fix" has "  fix: register $ckey.pub on the account bot-agent at https://github.com/settings/ssh/new (signed in as bot-agent) and remove it from owner-person; also check ~/.ssh/config for another IdentityFile for github.com"
check "codex key answers for another login: Next names step 3" bash -c "grep -q '^Next: step 3 of 6' '$dir/out'"
csandbox
put "$stub/ssh.codex_key.out" "git@github.com: Permission denied (publickey)."; put "$stub/ssh.codex_key.rc" 255
crun --check
check "codex key not on the account: MISSING with the .pub fix" bash -c "grep -qF 'MISSING  SSH: GitHub rejected $ckey (Permission denied)' '$dir/out' && grep -qxF '  fix: sign in to GitHub as bot-agent, open https://github.com/settings/ssh/new and paste the contents of $ckey.pub' '$dir/out'"
csandbox
put "$stub/ssh.G.extra" "identityfile /elsewhere/operator_key"
crun --check
check "codex key: another identity file still offered is WRONG" has "WRONG  ssh would offer identity files other than the agent key $ckey: "

echo "== --codex: step 6, config.toml and git"
csandbox
rm "$toml"
crun --check; rc=$?
check "no config.toml: MISSING" has "MISSING  $toml does not exist"
check "no config.toml: exact fix" has "  fix: mkdir -p $codex && : >>$toml"
check "no config.toml: Next names step 6 of the Codex config" bash -c "test $rc = 1 && grep -q '^Next: step 6 of 6 — apply the identity to the Codex config — mkdir -p' '$dir/out'"
csandbox
mkdir -p "$dir/bin-nopy"
ln -sf "$root/bin/ssh" "$dir/bin-nopy/ssh"; ln -sf "$root/bin/gh" "$dir/bin-nopy/gh"; ln -sf "$root/bin/ssh-keygen" "$dir/bin-nopy/ssh-keygen"
for tool in bash git jq sed tr cat cut grep wc awk head tail mkdir rm mv cp mktemp stat dirname basename readlink cksum env ls chmod hostname sort find uname date ln touch id perl tee printf test od; do
  p=$(PATH="$orig_path" command -v "$tool" 2>/dev/null) && [ -x "$p" ] && ln -sf "$p" "$dir/bin-nopy/$tool"
done
TEST_PATH="$dir/bin-nopy" crun --check; rc=$?
check "no tomllib python: exit 1, MISSING, never a crash" bash -c "test $rc = 1 && grep -qF 'MISSING  no python3 with tomllib on PATH, so $toml cannot be parsed (it needs Python 3.11+)' '$dir/out' && ! grep -qi 'traceback\\|unbound' '$dir/out'"
check "no tomllib python: exact fix" has "  fix: install Python 3.11+"
check "no tomllib python: Next names step 6" hasl "Next: step 6 of 6 — apply the identity to the Codex config — install Python 3.11+"
# a python3 that exists but has no tomllib is skipped the same way
cat >"$dir/bin-nopy/python3" <<'EOF'
#!/bin/sh
case "$*" in *tomllib*) exit 1 ;; *) exit 0 ;; esac
EOF
chmod +x "$dir/bin-nopy/python3"
TEST_PATH="$dir/bin-nopy" crun --check; rc=$?
check "a python3 without tomllib: the same MISSING" bash -c "test $rc = 1 && grep -qF 'MISSING  no python3 with tomllib on PATH' '$dir/out'"

csandbox
put "$toml" $'model = \n'
cp "$toml" "$dir/toml.before"
crun --check; rc=$?
check "unparsable config.toml: exit 1, WRONG with the parser's message" bash -c "test $rc = 1 && grep -q '^WRONG  $toml does not parse as TOML: .' '$dir/out'"
check "unparsable config.toml: exact fix" has "  fix: repair $toml by hand (Codex cannot read it either); nothing was changed"
crun; rc=$?
check "unparsable config.toml: a real run writes nothing" bash -c "test $rc = 1 && cmp -s '$toml' '$dir/toml.before' && test ! -e '$cg' && test ! -e '$crec'"

csandbox
put "$toml" $'model = "x"\n[shell_environment_policy]\ninherit = "core"\n'
cp "$toml" "$dir/toml.before"; snapshot >"$dir/snap.before"
crun; rc=$?
snapshot >"$dir/snap.after"
check "foreign policy: exit 1" test "$rc" = 1
check "foreign policy: CONFLICT naming what is there" has "WRONG  CONFLICT: $toml already sets shell_environment_policy ({\"inherit\": \"core\"}), which this script did not write; it is never overwritten"
check "foreign policy: exact fix" has "  fix: merge by hand or remove it, then re-run: this script needs shell_environment_policy.set to carry the agent identity's variables (the README's Agent identity section lists them)"
check "foreign policy: never overwritten, nothing written" cmp -s "$dir/snap.before" "$dir/snap.after"
check "foreign policy: Next names step 6" bash -c "grep -q '^Next: step 6 of 6 — apply the identity to the Codex config — merge by hand' '$dir/out'"
csandbox
put "$toml" $'[shell_environment_policy]\nset = { FOO = "1" }\n'
crun --check; rc=$?
check "partial foreign policy (only a set): still a CONFLICT" bash -c "test $rc = 1 && grep -qF 'WRONG  CONFLICT: $toml already sets shell_environment_policy ({\"set\": {\"FOO\": \"1\"}})' '$dir/out'"
csandbox
put "$toml" $'shell_environment_policy.inherit = "all"\n'
crun --check; rc=$?
check "dotted-key foreign policy: a CONFLICT too" bash -c "test $rc = 1 && grep -qF 'WRONG  CONFLICT: $toml already sets shell_environment_policy' '$dir/out'"
csandbox
put "$toml" $'# >>> jarvis agent-identity: written by apply-agent-identity.sh --codex; change it through that script\nmodel = "x"\n'
crun --check; rc=$?
check "marker without a record: CONFLICT, remove by hand" bash -c "test $rc = 1 && grep -qF 'WRONG  CONFLICT: $toml holds a jarvis agent-identity block, but there is no record of this script writing it at $crec' '$dir/out'"

csandbox
put "$toml" $'[profiles.work]\nmodel = "x"\n\n[profiles.work.shell_environment_policy]\ninherit = "core"\n'
crun --check; rc=$?
check "profile policy: exit 1 and WRONG naming the profile" bash -c "test $rc = 1 && grep -qF 'WRONG  profile \"work\" in $toml sets shell_environment_policy; Codex would use it instead of the agent identity' '$dir/out'"
check "profile policy: exact fix" has "  fix: remove [profiles.work.shell_environment_policy] from $toml (this script does not merge policies)"
csandbox
put "$toml" $'[profiles.other]\nshell_environment_policy = { inherit = "none" }\n[profiles.fine]\nmodel = "y"\n'
crun --check
check "profile policy as an inline table: found; a profile without one is not named" bash -c "grep -qF 'WRONG  profile \"other\"' '$dir/out' && ! grep -qF 'profile \"fine\"' '$dir/out'"

csandbox
mkdir -p "$dir/proj/.codex" "$dir/proj2/.codex" "$dir/proj3/.codex"
put "$dir/proj/.codex/config.toml" $'[shell_environment_policy]\ninherit = "core"\n'
put "$dir/proj2/.codex/config.toml" $'[shell_environment_policy]\ninherit = "core"\n'
put "$dir/proj3/.codex/config.toml" $'model = "z"\n'
put "$toml" "[projects.\"$dir/proj\"]
trust_level = \"trusted\"

[projects.\"$dir/proj2\"]
trust_level = \"untrusted\"

[projects.\"$dir/proj3\"]
trust_level = \"trusted\"
"
crun --check; rc=$?
check "trusted project policy: exit 1 and WRONG naming the file" bash -c "test $rc = 1 && grep -qF 'WRONG  the trusted project config $dir/proj/.codex/config.toml sets shell_environment_policy; Codex would apply it over the agent identity' '$dir/out'"
check "trusted project policy: exact fix" has "  fix: remove shell_environment_policy from $dir/proj/.codex/config.toml, or stop trusting that project in $toml"
check "trusted project policy: an untrusted project and a trusted one without a policy are not named" bash -c "! grep -q 'proj2' '$dir/out' && ! grep -q 'proj3' '$dir/out'"
csandbox
mkdir -p "$dir/proj/.codex"
put "$dir/proj/.codex/config.toml" $'model = '
put "$toml" "[projects.\"$dir/proj\"]
trust_level = \"trusted\"
"
crun --check; rc=$?
check "trusted project config that does not parse: WARN, not guessed" bash -c "test $rc = 0 && grep -q '^WARN  the trusted project config $dir/proj/.codex/config.toml does not parse' '$dir/out'"

csandbox
printf '[url "https://github.com/"]\n\tpushInsteadOf = git@github.com:\n' >"$home/.gitconfig"
crun --check; rc=$?
check "operator pushInsteadOf back to HTTPS: exit 1, WRONG naming both URLs" bash -c "test $rc = 1 && grep -qF 'WRONG  git: git@github.com:acme/app.git becomes git@github.com:acme/app.git (fetch) and https://github.com/acme/app.git (push) under Codex' '$dir/out'"
check "operator pushInsteadOf back to HTTPS: the rule is named, from the operator's file via the include" bash -c "grep -q 'file:$home/.gitconfig.*url.https://github.com/.pushinsteadof' '$dir/out'"
check "operator pushInsteadOf back to HTTPS: Next names step 6" bash -c "grep -q '^Next: step 6 of 6 — apply the identity to the Codex config — remove or change the url rewrite that wins' '$dir/out'"
csandbox
printf '[url "ssh://other.example/"]\n\tinsteadOf = https://github.com/acme/\n' >"$home/.gitconfig"
crun --check; rc=$?
check "operator insteadOf to another host: WRONG under Codex's env" bash -c "test $rc = 1 && grep -qF 'WRONG  git: https://github.com/acme/app.git becomes ssh://other.example/app.git (fetch)' '$dir/out'"
csandbox
GIT_CFG_OP="$home/.config/git/config"; mkdir -p "$(dirname "$GIT_CFG_OP")"
printf '[url "https://github.com/"]\n\tpushInsteadOf = git@github.com:\n' >"$GIT_CFG_OP"
crun --check; rc=$?
check "operator rule in the XDG git config is found through the include too" bash -c "test $rc = 1 && grep -q 'file:$GIT_CFG_OP.*pushinsteadof' '$dir/out'"
csandbox
printf '[credential]\n\thelper = osxkeychain\n' >"$home/.gitconfig"
crun --check; rc=$?
check "operator credential helper: fine, the reset comes after it" test "$rc" = 0

echo "== --codex: a real run"
csandbox
cp "$toml" "$dir/toml.orig"
printf '[credential]\n\thelper = "!f() { echo called >>%s/helper.log; }; f"\n' "$home" >"$home/.gitconfig"
cp "$settings" "$dir/settings.orig"
crun; rc=$?
check "apply: exit 0" test "$rc" = 0
{ cat "$dir/toml.orig"; printf '\n'; expect_block; } >"$dir/toml.expected"
check "apply: config.toml is the original, a blank line and the block, byte for byte" cmp -s "$toml" "$dir/toml.expected"
check "apply: the rest of the file is byte-identical (the original is its prefix)" bash -c "prefix_ok '$toml' '$dir/toml.orig'"
check "apply: backup is the previous config.toml" cmp -s "$toml.agent-identity-backup" "$dir/toml.orig"
expect_cg >"$dir/cg.expected"
check "apply: gitconfig content" cmp -s "$cg" "$dir/cg.expected"
check "apply: gitconfig mode 600" test "$(mode "$cg")" = 600
check "apply: record mode 600" test "$(mode "$crec")" = 600
check "apply: record holds the set map, the gitconfig and its sha256" jx --arg cg "$cg" --arg sha "$(sha_of "$cg")" '.version == 1 and .set.JARVIS_AGENT_IDENTITY == "bot-agent" and .set.GH_TOKEN == "" and .gitconfig == $cg and .gitconfig_sha256 == $sha and .prefix == "\n"' "$crec"
expect_block >"$dir/block.expected"; jq -j .block "$crec" >"$dir/rec.block"
check "apply: the recorded block is the one in the file, exactly" cmp -s "$dir/rec.block" "$dir/block.expected"
check "apply: tomllib reads back the table the record holds" bash -c "test \"\$($tpy -I -c 'import sys,tomllib,json; print(json.dumps(tomllib.load(open(sys.argv[1],\"rb\"))[\"shell_environment_policy\"][\"set\"],sort_keys=True,separators=(\",\",\":\")))' '$toml')\" = \"\$(jq -cS .set '$crec')\""
check "apply: the existing tables are still there" bash -c "$tpy -I -c 'import sys,tomllib; c=tomllib.load(open(sys.argv[1],\"rb\")); assert c[\"model\"]==\"gpt-5\" and c[\"projects\"][\"/nonexistent/trusted\"][\"trust_level\"]==\"trusted\"' '$toml'"
check "apply: Claude's settings and record are not touched" bash -c "cmp -s '$settings' '$dir/settings.orig' && test ! -e '$record'"
check "apply: says to restart Codex" has "restart Codex"
check "apply: says the switch is not touched" has "JARVIS_REQUIRE_AGENT_IDENTITY switch is not touched"
check "apply: no temporary file left" bash -c "test \$(ls -A '$codex' | grep -c '\\.[A-Za-z0-9]\\{6\\}\$') = 0"
# real git under the written gitconfig
git init -q "$dir/clone"; git -C "$dir/clone" remote add origin https://github.com/o/r.git
cenv=(); while IFS= read -r kv; do cenv+=("$kv"); done < <(table_set "$toml" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
ccmd() { env GIT_CONFIG_NOSYSTEM=1 HOME="$home" "${cenv[@]}" "$@"; }
check "apply: the policy carries GIT_CONFIG_GLOBAL, and no GIT_CONFIG_COUNT" jx --arg cg "$cg" '.set.GIT_CONFIG_GLOBAL == $cg and (.set | has("GIT_CONFIG_COUNT") | not)' "$crec"
check "git under the written gitconfig: the HTTPS remote resolves to SSH" test "$(ccmd git -C "$dir/clone" ls-remote --get-url origin)" = "git@github.com:o/r.git"
check "git under the written gitconfig: its push URL too" test "$(ccmd git -C "$dir/clone" remote get-url --push origin)" = "git@github.com:o/r.git"
git -C "$dir/clone" remote set-url origin git@github.com:o/r.git
check "git under the written gitconfig: the SSH form stays SSH, fetch and push" test "$(ccmd git -C "$dir/clone" ls-remote --get-url origin)" = "git@github.com:o/r.git" -a "$(ccmd git -C "$dir/clone" remote get-url --push origin)" = "git@github.com:o/r.git"
check "git under the written gitconfig: the last credential.helper is empty" test "$(ccmd git config --get-all credential.helper | tail -n 1)" = ""
check "git under the written gitconfig: the operator's helper is listed before it (the include works)" bash -c "env GIT_CONFIG_NOSYSTEM=1 HOME='$home' GIT_CONFIG_GLOBAL='$cg' git config --get-all credential.helper | grep -q called"
rm -f "$home/helper.log"
printf 'protocol=https\nhost=github.com\n\n' | ccmd env GIT_TERMINAL_PROMPT=0 git credential fill >/dev/null 2>&1
check "git under the written gitconfig: the operator's credential helper is never asked" test ! -e "$home/helper.log"
printf 'protocol=https\nhost=github.com\n\n' | env GIT_CONFIG_NOSYSTEM=1 HOME="$home" GIT_TERMINAL_PROMPT=0 git credential fill >/dev/null 2>&1
check "git without the gitconfig: it is asked (the control)" test -f "$home/helper.log"
rm -f "$home/.gitconfig"

cp "$toml" "$dir/toml.after1"; cp "$crec" "$dir/rec1"; cp "$cg" "$dir/cg1"; cp "$toml.agent-identity-backup" "$dir/bak1"
crun; rc=$?
check "codex idempotent: exit 0" test "$rc" = 0
check "codex idempotent: says already applied" has "already carries the agent identity"
check "codex idempotent: config, record, gitconfig and backup unchanged" bash -c "cmp -s '$toml' '$dir/toml.after1' && cmp -s '$crec' '$dir/rec1' && cmp -s '$cg' '$dir/cg1' && cmp -s '$toml.agent-identity-backup' '$dir/bak1'"
crun --check; rc=$?
check "codex check after apply: exit 0" test "$rc" = 0
check "codex check after apply: the block and table verified" bash -c "grep -q '^OK  the block in $toml is what this script wrote, and shell_environment_policy equals the record' '$dir/out' && grep -q '^OK  $cg is what this script wrote (sha256 matches the record)' '$dir/out'"
check "codex check after apply: Next says applied" bash -c "grep -q '^Next: nothing — the identity is already applied; a new Codex session uses it' '$dir/out'"
check "codex check after apply: the policy table is not reported as foreign" hasn "CONFLICT"

# the record is what the guard reads
check "codex apply: the record is where the Codex guard looks" test -f "$codex/agent-identity.applied.json"

# a block edited after apply
cp "$toml" "$dir/toml.good"
sed 's/GIT_AUTHOR_NAME = "Codex"/GIT_AUTHOR_NAME = "Mallory"/' "$dir/toml.good" >"$toml"
snapshot >"$dir/snap.before"
crun --check; rc=$?
crun; rc2=$?
snapshot >"$dir/snap.after"
check "edited block: --check exits 1" test "$rc" = 1
check "edited block: WRONG, edited since" has "WRONG  the jarvis agent-identity block in $toml is not what this script wrote (edited since)"
check "edited block: exact fix" has "  fix: restore it: jq -j .block $crec shows the exact text; or remove the block by hand and delete $crec, then re-run"
check "edited block: a real run exits 1" test "$rc2" = 1
check "edited block: a real run writes nothing" cmp -s "$dir/snap.before" "$dir/snap.after"
cp "$dir/toml.good" "$toml"
printf 'extra = 1\n' >>"$toml"
crun --check; rc=$?
check "key appended after the end marker: exit 1" test "$rc" = 1
check "key appended after the end marker: WRONG" has "WRONG  a key follows the block's end marker in $toml (\"extra = 1\"), so it belongs to our shell_environment_policy table"
cp "$dir/toml.good" "$toml"
printf '\n[other]\nextra = 1\n' >>"$toml"
crun --check; rc=$?
check "a table after the end marker is fine" test "$rc" = 0
cp "$dir/toml.good" "$toml"
sed 's/^\[shell_environment_policy\]$/[shell_environment_policy]\ninherit = "all"/' "$dir/toml.good" >"$toml"
crun --check; rc=$?
check "a key added inside the block: WRONG (edited)" bash -c "test $rc = 1 && grep -q '^WRONG  the jarvis agent-identity block in $toml is not what this script wrote' '$dir/out'"
cp "$dir/toml.good" "$toml"
printf '# changed\n' >>"$cg"
crun --check; rc=$?
check "gitconfig edited after apply: CONFLICT" bash -c "test $rc = 1 && grep -qF 'WRONG  CONFLICT: $cg was changed since this script wrote it (sha256 differs from the record)' '$dir/out'"
cp "$dir/cg1" "$cg"
crun --check; rc=$?
check "restoring the files makes it pass again" test "$rc" = 0
rm "$cg"
crun --check; rc=$?
check "gitconfig removed after apply: --check exits 1" test "$rc" = 1
check "gitconfig removed after apply: MISSING, naming the consequence" has "MISSING  $cg is missing although the record exists: the policy's GIT_CONFIG_GLOBAL points at nothing, and git would fall back to the operator's credential helper and HTTPS"
check "gitconfig removed after apply: fix is the --codex run" has "  fix: bash $apply --codex"
check "gitconfig removed after apply: Next names step 6" hasl "Next: step 6 of 6 — apply the identity to the Codex config — bash $apply --codex"
snapshot >"$dir/snap.before"; crun --check >/dev/null; snapshot >"$dir/snap.after"
check "gitconfig removed after apply: --check writes nothing" cmp -s "$dir/snap.before" "$dir/snap.after"
crun; rc=$?
check "gitconfig removed after apply: the run restores it" bash -c "test $rc = 0 && cmp -s '$cg' '$dir/cg1' && cmp -s '$toml' '$dir/toml.good'"
check "gitconfig removed after apply: a plain run that will write says OK" bash -c "grep -q '^OK  $cg is not there: a real run writes it again' '$dir/out'"
check "gitconfig restored: mode 600" test "$(mode "$cg")" = 600
# the block removed by hand, the record kept: a run appends it again
cp "$dir/toml.orig" "$toml"
crun --check; rc=$?
check "block removed by hand: --check exits 1" test "$rc" = 1
check "block removed by hand: MISSING, Codex runs without the identity" has "MISSING  the record at $crec lists a block that is no longer in $toml, so Codex runs without the agent identity"
check "block removed by hand: fix is the --codex run, step 6" hasl "Next: step 6 of 6 — apply the identity to the Codex config — bash $apply --codex"
crun; rc=$?
check "block removed by hand: the run puts it back" bash -c "test $rc = 0 && cmp -s '$toml' '$dir/toml.good'"

# an edit to the config updates the block in place
cfg_set $'login=bot-agent\nemail=2+bot-agent@users.noreply.github.com\nssh_key=~/.ssh/agent_key\ngh_config_dir=~/.config/gh-agent\nrepos=acme/app\ncodex_ssh_key=~/.ssh/codex_key'
printf '[other]\nkeep = 1\n' >>"$toml"
cp "$toml" "$dir/toml.pre"
crun; rc=$?
check "update: the block follows the config" bash -c "test $rc = 0 && grep -qF 'GIT_AUTHOR_EMAIL = \"2+bot-agent@users.noreply.github.com\"' '$toml' && jq -e '.set.GIT_AUTHOR_EMAIL == \"2+bot-agent@users.noreply.github.com\"' '$crec' >/dev/null"
check "update: everything outside the block is untouched" bash -c "diff <(grep -v -e GIT_AUTHOR_EMAIL '$dir/toml.pre') <(grep -v -e GIT_AUTHOR_EMAIL '$toml')"
check "update: still exactly one block" bash -c "test \$(grep -c '^# >>> jarvis agent-identity' '$toml') = 1"
check "update: the backup is the file before the update" cmp -s "$toml.agent-identity-backup" "$dir/toml.pre"

# --unapply --codex
csandbox
cp "$toml" "$dir/toml.orig"
crun; crun --unapply; rc=$?
check "codex unapply: exit 0" test "$rc" = 0
check "codex unapply: config.toml is byte-identical to before the apply" cmp -s "$toml" "$dir/toml.orig"
check "codex unapply: gitconfig and record are gone" bash -c "test ! -e '$cg' && test ! -e '$crec'"
check "codex unapply: says what it removed" bash -c "grep -q 'removed the block from $toml' '$dir/out' && grep -q 'removed $cg' '$dir/out' && grep -q 'removed $crec' '$dir/out'"
check "codex unapply: a backup was written" test -f "$toml.agent-identity-backup"
crun --unapply; rc=$?
check "codex unapply: a second time has nothing to do" bash -c "test $rc = 0 && grep -q 'nothing to remove' '$dir/out'"
for variant in "no trailing newline" "empty file" "crlf file" "no blank line needed"; do
  csandbox
  case $variant in
    "no trailing newline") put "$toml" 'model = "x"' ;;
    "empty file") put "$toml" '' ;;
    "crlf file") put "$toml" $'model = "x"\r\n' ;;
    "no blank line needed") put "$toml" $'model = "x"\n\n' ;;
  esac
  cp "$toml" "$dir/toml.orig"
  crun; rc=$?
  check "codex apply, $variant: exit 0 and the original is the prefix" bash -c "test $rc = 0 && prefix_ok '$toml' '$dir/toml.orig' && $tpy -I -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],\"rb\"))' '$toml'"
  crun --unapply
  check "codex unapply, $variant: byte-identical to before" cmp -s "$toml" "$dir/toml.orig"
done
csandbox
crun
cp "$toml" "$dir/toml.mid"
printf '[mine]\nx = 1\n' >>"$toml"
crun --unapply; rc=$?
check "codex unapply: a table added after the block stays, the block goes" bash -c "test $rc = 0 && ! grep -q 'jarvis agent-identity' '$toml' && grep -q '^\\[mine\\]' '$toml' && grep -q 'model = ' '$toml'"
csandbox
crun
sed 's/GH_HOST = ""/GH_HOST = "evil.example"/' "$toml" >"$dir/t" && cp "$dir/t" "$toml"
snapshot >"$dir/snap.before"
crun --unapply; rc=$?
snapshot >"$dir/snap.after"
check "codex unapply, block edited: exit 1, refuses and explains" bash -c "test $rc = 1 && grep -qF 'WRONG  the jarvis agent-identity block in $toml is not byte-identical to what this script wrote (edited, or more than one)' '$dir/out'"
check "codex unapply, block edited: exact fix" has "  fix: restore it (jq -j .block $crec shows the exact text) or remove the block by hand and delete $crec; nothing was changed"
check "codex unapply, block edited: nothing was changed" cmp -s "$dir/snap.before" "$dir/snap.after"
csandbox
crun
printf 'extra = 1\n' >>"$toml"
snapshot >"$dir/snap.before"
crun --unapply; rc=$?
snapshot >"$dir/snap.after"
check "codex unapply, a key after the end marker: refuses" bash -c "test $rc = 1 && grep -q 'removing the block would move it into another table' '$dir/out'"
check "codex unapply, a key after the end marker: nothing changed" cmp -s "$dir/snap.before" "$dir/snap.after"
csandbox
crun
printf '# mine\n' >>"$cg"
crun --unapply; rc=$?
check "codex unapply, gitconfig edited: the block goes, the gitconfig stays with a WARN" bash -c "test $rc = 0 && test -f '$cg' && ! grep -q 'jarvis agent-identity' '$toml' && grep -q '^WARN  $cg was changed since this script wrote it, so it was left in place' '$dir/out' && test ! -e '$crec'"
csandbox
put "$crec" '{"x":'
crun --unapply; rc=$?
check "codex unapply, a bad record: WRONG, exit 1" bash -c "test $rc = 1 && grep -q '^WRONG  $crec is not a record this script wrote' '$dir/out' && test -e '$crec'"

echo "== --codex: links, escapes, concurrency"
csandbox
mkdir -p "$dir/dotfiles"; mv "$toml" "$dir/dotfiles/config.toml"; ln -s "$dir/dotfiles/config.toml" "$toml"
cp "$dir/dotfiles/config.toml" "$dir/toml.orig"
crun; rc=$?
check "codex link: exit 0, still a link, written through" bash -c "test $rc = 0 && test -L '$toml' && grep -q 'jarvis agent-identity' '$dir/dotfiles/config.toml'"
check "codex link: the backup sits beside the target" bash -c "cmp -s '$dir/dotfiles/config.toml.agent-identity-backup' '$dir/toml.orig'"
crun --unapply
check "codex link: unapply restores the target and keeps the link" bash -c "test -L '$toml' && cmp -s '$dir/dotfiles/config.toml' '$dir/toml.orig'"

csandbox
cfg_append 'codex_author_name=Co"d\ex'
crun; rc=$?
check "codex author with a quote and a backslash: applied" test "$rc" = 0
check "codex author with a quote and a backslash: TOML-escaped in the file" grep -qF 'GIT_AUTHOR_NAME = "Co\"d\\ex"' "$toml"
check "codex author: tomllib reads back the same name" bash -c "test \"\$($tpy -I -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],\"rb\"))[\"shell_environment_policy\"][\"set\"][\"GIT_AUTHOR_NAME\"])' '$toml')\" = 'Co\"d\\ex'"
csandbox
cfg_append 'codex_author_name=Cödex 日本'
crun; rc=$?
check "codex author with non-ASCII characters: tomllib reads it back" bash -c "test $rc = 0 && test \"\$($tpy -I -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],\"rb\"))[\"shell_environment_policy\"][\"set\"][\"GIT_COMMITTER_NAME\"])' '$toml')\" = 'Cödex 日本'"

csandbox
: >"$stub/touch_settings"
cp "$toml" "$dir/toml.orig"
XENV="STUB_SETTINGS=$toml"
crun; rc=$?
check "codex concurrent change: exit 2" test "$rc" = 2
check "codex concurrent change: refuses to write" has "changed while this ran; nothing was written, run it again"
check "codex concurrent change: no record, no gitconfig, no backup" bash -c "test ! -e '$crec' && test ! -e '$cg' && test ! -e '$toml.agent-identity-backup'"
check "codex concurrent change: the other writer's change is intact (a space was added)" bash -c "! cmp -s '$toml' '$dir/toml.orig' && ! grep -q 'jarvis agent-identity' '$toml'"

csandbox
printf 'stale\n' >"$cg"
crun --check; rc=$?
check "gitconfig exists with no record: CONFLICT" bash -c "test $rc = 1 && grep -qF 'WRONG  CONFLICT: $cg exists, but there is no record of this script writing it' '$dir/out'"
csandbox
put "$stub/ssh.codex_key.out" "git@github.com: Permission denied (publickey)."; put "$stub/ssh.codex_key.rc" 255
snapshot >"$dir/snap.before"
crun; rc=$?
snapshot >"$dir/snap.after"
check "no codex write on failure: exit 1" test "$rc" = 1
check "no codex write on failure: nothing changed" cmp -s "$dir/snap.before" "$dir/snap.after"
check "no codex write on failure: says so" has "apply-agent-identity: nothing was written"

echo "== --codex: a separate GitHub account for Codex"
cfg_sep() { # codex_login codex_email codex_gh_config_dir (an empty argument leaves that line out)
  [ -z "${1-}" ] || cfg_append "codex_login=$1"
  [ -z "${2-}" ] || cfg_append "codex_email=$2"
  [ -z "${3-}" ] || cfg_append "codex_gh_config_dir=$3"
}
sepsandbox() { # every check passes for a second account, codex-bot, with its own key and gh dir
  csandbox
  cfg_sep codex-bot '2+codex-bot@users.noreply.github.com' '~/.config/gh-codex'   # lines 8 to 10 (7 is codex_ssh_key)
  cghdir="$home/.config/gh-codex"; cs="$stub/gh-by-dir/gh-codex"
  mkdir -p "$cs"
  put "$stub/ssh.codex_key.out" "Hi codex-bot! You've successfully authenticated, but GitHub does not provide shell access."
  put "$cs/auth_status.out" $'github.com\n  \xe2\x9c\x93 Logged in to github.com account codex-bot (keyring)\n  - Active account: true'
  put "$cs/user.out" "codex-bot"
  put "$cs/repo.acme__app.out" "$repo_ok"
  put "$cs/rulesets.acme__app.out" "[]"
  put "$cs/invitations.out" "[]"
}
sepsandbox
snapshot >"$dir/snap.before"
crun --check; rc=$?
snapshot >"$dir/snap.after"
check "separate account: all checks pass, exit 0" test "$rc" = 0
check "separate account: the config line says so" has "OK  config values valid: codex_login=codex-bot (line 8) (Codex's own account), 1 repo(s), author_name=Codex"
check "separate account: SSH answer for Codex's key is judged against codex_login" has "OK  SSH: GitHub answers \"Hi codex-bot!\" for $ckey"
check "separate account: gh login in Codex's own dir" has "OK  gh: GH_CONFIG_DIR=$cghdir is logged in as codex-bot"
check "separate account: repo access is checked for codex-bot" has "OK  repo acme/app: codex-bot can push"
check "separate account: the operator comparison uses codex-bot" has "OK  the operator's own gh login (owner-person) differs from codex_login=codex-bot (line 8)"
check "separate account: the Claude gh dir is never asked" bash -c "! grep -q 'GH_CONFIG_DIR=$ghdir' '$stub/calls.log'"
check "separate account: --check writes nothing" cmp -s "$dir/snap.before" "$dir/snap.after"
crun; rc=$?
check "separate account: a real run exits 0" test "$rc" = 0
check "separate account: the set map carries Codex's email, gh dir and marker" jx --arg d "$cghdir" '.set.GIT_AUTHOR_EMAIL == "2+codex-bot@users.noreply.github.com" and .set.GIT_COMMITTER_EMAIL == "2+codex-bot@users.noreply.github.com" and .set.GH_CONFIG_DIR == $d and .set.JARVIS_AGENT_IDENTITY == "codex-bot" and .set.GIT_AUTHOR_NAME == "Codex"' "$crec"
check "separate account: and the block in config.toml says the same" bash -c "grep -qF 'GH_CONFIG_DIR = \"$cghdir\", JARVIS_AGENT_IDENTITY = \"codex-bot\"' '$toml' && grep -qF 'GIT_AUTHOR_EMAIL = \"2+codex-bot@users.noreply.github.com\"' '$toml'"
run --check; rc=$?
check "separate account: Claude mode ignores the three keys and still checks login" bash -c "test $rc = 0 && grep -q 'OK  gh: GH_CONFIG_DIR=$ghdir is logged in as bot-agent' '$dir/out'"

sepsandbox
put "$cs/auth_status.out" "You are not logged into any GitHub hosts."; put "$cs/auth_status.rc" 1
crun --check; rc=$?
check "separate account, gh not logged in: MISSING for Codex's dir" has "MISSING  gh: not logged in to github.com in $cghdir"
check "separate account, gh not logged in: fix signs in as codex-bot" has "  fix: GH_CONFIG_DIR=$cghdir gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key --web   (sign in as codex-bot, not as yourself)"
sepsandbox
rm "$cs/repo.acme__app.out"; put "$cs/repo.acme__app.err" "gh: Not Found (HTTP 404)"; put "$cs/repo.acme__app.rc" 1
put "$cs/invitations.out" '[{"id":7,"repository":{"full_name":"acme/app"}}]'
crun --check
check "separate account, invitation pending for codex-bot: MISSING with its accept line" has "  fix: as codex-bot, accept the invitation at https://github.com/acme/app/invitations (or github.com/notifications)"
sepsandbox
put "$cs/repo.acme__app.out" '{"permissions":{"admin":true,"maintain":true,"push":true,"pull":true}}'
crun --check
check "separate account, admin role: WRONG names codex-bot" has "WRONG  repo acme/app: codex-bot holds the admin role; it must be Write"
sepsandbox
put "$stub/gh-operator/user.out" "codex-bot"
crun --check
check "separate account, codex-bot is the operator's own login: WRONG" has "WRONG  codex_login=codex-bot (line 8) is the operator's own gh login"
sepsandbox
put "$stub/ssh.codex_key.out" "Hi bot-agent! You've successfully authenticated, but GitHub does not provide shell access."
crun --check
check "separate account, Codex's key answers as the Claude account: WRONG" has "WRONG  SSH: $ckey authenticates as bot-agent, but the config says codex_login=codex-bot (line 8)"

csandbox
cfg_sep codex-bot '' '~/.config/gh-codex'
crun --check; rc=$?
check "separate account without codex_email: MISSING" bash -c "test $rc = 1 && grep -qF 'MISSING  config key codex_email (required when codex_login differs from login) is not in $cfg' '$dir/out'"
check "separate account without codex_email: exact fix" has "  fix: append it to $cfg: printf '%s\\n' 'codex_email=<the verified email of codex-bot>' >>$cfg   (edit the value)"
check "separate account without codex_email: Next names step 1" bash -c "grep -q '^Next: step 1 of 6 — create the config file — append it to $cfg' '$dir/out'"
csandbox
cfg_sep codex-bot '2+codex-bot@users.noreply.github.com' ''
crun --check; rc=$?
check "separate account without codex_gh_config_dir: MISSING" bash -c "test $rc = 1 && grep -qF 'MISSING  config key codex_gh_config_dir (required when codex_login differs from login) is not in $cfg' '$dir/out'"
check "separate account without codex_gh_config_dir: exact fix" has "  fix: append it to $cfg: printf '%s\\n' 'codex_gh_config_dir=~/.config/gh-agent-codex' >>$cfg"
csandbox
cfg_sep codex-bot '2+codex-bot@users.noreply.github.com' '~/.config/gh-agent'
crun --check; rc=$?
check "codex gh dir equal to gh_config_dir: WRONG" bash -c "test $rc = 1 && grep -qF 'WRONG  config line 10: codex_gh_config_dir=~/.config/gh-agent is the same gh config dir as gh_config_dir (line 5); one gh config dir cannot be logged in as two accounts' '$dir/out'"
check "codex gh dir equal to gh_config_dir: exact fix" has "  fix: edit line 10 of $cfg: give codex_gh_config_dir its own path, for example ~/.config/gh-agent-codex"
csandbox
cfg_sep codex-bot '2+codex-bot@users.noreply.github.com' '~/.config/gh'
crun --check
check "codex gh dir is the operator's default: refused by the same validator" has "WRONG  config line 10: codex_gh_config_dir=~/.config/gh is the default gh config dir"
sandbox
cfg_sep bad_login 'nope' '~/.config/gh'
run --check; rc=$?
check "codex_login, codex_email and codex_gh_config_dir are validated in Claude mode too" bash -c "test $rc = 1 && grep -qF 'WRONG  config line 7: codex_login=bad_login not a GitHub login' '$dir/out' && grep -qF 'WRONG  config line 8: codex_email=nope does not look like an email address' '$dir/out' && grep -qF 'WRONG  config line 9: codex_gh_config_dir=~/.config/gh is the default gh config dir' '$dir/out'"

csandbox
cfg_sep Bot-Agent '3+other@users.noreply.github.com' '~/.config/gh-other'
crun --check; rc=$?
check "codex_login equal to login (any case): treated as not set, exit 0" test "$rc" = 0
check "codex_login equal to login: an OK line says Codex shares the account" has "OK  codex_login=Bot-Agent is the same account as login: Codex shares it, and codex_email and codex_gh_config_dir are ignored"
check "codex_login equal to login: the shared gh dir and login are used" has "OK  gh: GH_CONFIG_DIR=$ghdir is logged in as bot-agent"
crun; rc=$?
check "codex_login equal to login: the set map has the shared values" jx --arg d "$ghdir" '.set.GH_CONFIG_DIR == $d and .set.JARVIS_AGENT_IDENTITY == "bot-agent" and .set.GIT_AUTHOR_EMAIL == "1+bot-agent@users.noreply.github.com"' "$crec"
csandbox
cfg_sep '' '3+other@users.noreply.github.com' ''
snapshot >"$dir/snap.before"
crun; rc=$?
snapshot >"$dir/snap.after"
check "codex_email without codex_login: WRONG, exit 1" test "$rc" = 1
check "codex_email without codex_login: names the key and says it is not set" has "WRONG  config line 8: codex_email is set, but codex_login is not set, so it is unclear which account Codex acts as"
check "codex_email without codex_login: exact fix" has "  fix: set codex_login to the second account's login, or delete line 8 of $cfg"
check "codex_email without codex_login: Next names step 1" bash -c "grep -q '^Next: step 1 of 6 — create the config file — set codex_login to the second account' '$dir/out'"
check "codex_email without codex_login: nothing is written" cmp -s "$dir/snap.before" "$dir/snap.after"
csandbox
cfg_sep '' '' '~/.config/gh-codex'
crun --check
check "codex_gh_config_dir without codex_login: WRONG too" has "WRONG  config line 8: codex_gh_config_dir is set, but codex_login is not set, so it is unclear which account Codex acts as"
run --check; rc=$?
check "codex_email without codex_login: Claude mode does not care" test "$rc" = 0
csandbox
cfg_sep bad_login '3+other@users.noreply.github.com' ''
crun --check
check "invalid codex_login with codex_email: the message says invalid, not not set" has "WRONG  config line 9: codex_email is set, but codex_login is invalid, so it is unclear which account Codex acts as"
check "invalid codex_login with codex_email: the invalid login is reported too" has "WRONG  config line 8: codex_login=bad_login not a GitHub login"
sepsandbox
cfg_set "$(sed 's/^codex_email=.*$/codex_email=1+BOT-agent@users.noreply.github.com/' "$cfg")"
crun --check; rc=$?
check "codex_email equal to email (any case): WRONG, exit 1" test "$rc" = 1
check "codex_email equal to email: names both keys and lines" has "WRONG  config line 9: codex_email=1+BOT-agent@users.noreply.github.com is the same email as email (line 3); commits are attributed by email, so two accounts need two"
check "codex_email equal to email: exact fix" has "  fix: edit line 9 of $cfg: set codex_email to the verified email of codex-bot"

echo "== --codex: a half-applied or stale state never reads as OK"
csandbox
crun; crun --check; rc=$?
check "fresh apply passes --check" test "$rc" = 0
rm "$cg"
crun --check; rc=$?
check "stale: gitconfig missing with a block and a record: exit 1" test "$rc" = 1
check "stale: gitconfig missing is MISSING, never OK" bash -c "grep -q '^MISSING  $cg is missing' '$dir/out' && ! grep -q '^OK  $cg' '$dir/out'"

echo "== --codex: the policy fails closed over HTTPS"
csandbox
crun; rc=$?
check "askpass: the record carries GIT_TERMINAL_PROMPT, GIT_ASKPASS and SSH_ASKPASS" jx '.set.GIT_TERMINAL_PROMPT == "0" and .set.GIT_ASKPASS == "/usr/bin/false" and .set.SSH_ASKPASS == "/usr/bin/false"' "$crec"
check "askpass: and so does the block, in this order after GH_HOST" grep -qF 'GH_HOST = "", GIT_TERMINAL_PROMPT = "0", GIT_ASKPASS = "/usr/bin/false", SSH_ASKPASS = "/usr/bin/false" }' "$toml"
check "askpass: tomllib reads the three back" bash -c "test \"\$($tpy -I -c 'import sys,tomllib; s=tomllib.load(open(sys.argv[1],\"rb\"))[\"shell_environment_policy\"][\"set\"]; print(s[\"GIT_TERMINAL_PROMPT\"], s[\"GIT_ASKPASS\"], s[\"SSH_ASKPASS\"])' '$toml')\" = '0 /usr/bin/false /usr/bin/false'"
csandbox
printf '[credential]\n\thelper = "!f() { echo username=u; echo password=p; }; f"\n' >"$home/.gitconfig"
crun --check; rc=$?
check "askpass: with an operator helper that would answer, the check passes because the reset comes after it" test "$rc" = 0
check "askpass: and says asking for HTTPS credentials fails without a prompt" has "OK  git: under Codex's env asking for HTTPS credentials for github.com fails without a prompt, so Codex cannot push over HTTPS"
# a git that answers credential fill: the check must say so (kills a check that never asks)
csandbox
mkdir -p "$dir/shim"; real_git=$(PATH="$orig_path" command -v git)
cat >"$dir/shim/git" <<EOF
#!/bin/sh
case " \$* " in *" credential fill "*) cat >/dev/null; printf 'username=u\npassword=p\n'; exit 0 ;; esac
exec "$real_git" "\$@"
EOF
chmod +x "$dir/shim/git"
TEST_PATH="$dir/shim:$root/bin:$PATH" crun --check; rc=$?
check "askpass: credential fill that succeeds is WRONG" bash -c "test $rc = 1 && grep -qF 'WRONG  git: under Codex'\"'\"'s env asking for HTTPS credentials for github.com succeeds' '$dir/out'"

echo "== --codex: mutants that must not survive"
# a last credential.helper that is not empty fails the check (a git that appends one)
csandbox
mkdir -p "$dir/shim"; real_git=$(PATH="$orig_path" command -v git)
cat >"$dir/shim/git" <<EOF
#!/bin/sh
case " \$* " in *" config --get-all credential.helper "*) "$real_git" "\$@"; echo '!evil'; exit 0 ;; esac
exec "$real_git" "\$@"
EOF
chmod +x "$dir/shim/git"
TEST_PATH="$dir/shim:$root/bin:$PATH" crun --check; rc=$?
check "last helper not empty: exit 1" test "$rc" = 1
check "last helper not empty: WRONG naming it" has "WRONG  git: the last credential.helper under Codex's env is \"!evil\", not the empty reset, so a helper (the operator's) could answer for github.com"
# an exported GIT_CONFIG_COUNT with a rule that would turn SSH into HTTPS must not change the result
csandbox
XENV="GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.https://github.com/.insteadOf GIT_CONFIG_VALUE_0=git@github.com:"
crun --check; rc=$?
check "exported GIT_CONFIG_COUNT with an insteadOf: the Codex check ignores it (Codex strips it)" test "$rc" = 0
# the written files are mode 600 even when mktemp makes world-readable ones
csandbox
mkdir -p "$dir/shim"; real_mktemp=$(PATH="$orig_path" command -v mktemp)
cat >"$dir/shim/mktemp" <<EOF
#!/bin/sh
case " \$* " in *" -d "*) exec "$real_mktemp" "\$@" ;; esac
p=\$("$real_mktemp" "\$@") || exit 1
chmod 644 "\$p"
printf '%s\n' "\$p"
EOF
chmod +x "$dir/shim/mktemp"
TEST_PATH="$dir/shim:$root/bin:$PATH" crun; rc=$?
check "mktemp makes 644 files: the apply succeeds" test "$rc" = 0
check "mktemp makes 644 files: the gitconfig is still mode 600" test "$(mode "$cg")" = 600
check "mktemp makes 644 files: and so is the record" test "$(mode "$crec")" = 600

echo "== --codex: a trusted project's own git config is read after ours"
trusted_toml() { # path...
  local t="$toml_orig" pth
  for pth in "$@"; do t="$t"$'\n'"[projects.\"$pth\"]"$'\n''trust_level = "trusted"'$'\n'; done
  put "$toml" "$t"
}
mkrepo() { git init -q "$1"; }
csandbox
mkrepo "$dir/proj"
trusted_toml "$dir/proj"
crun --check; rc=$?
check "trusted project, clean repo: passes with an OK line for it" bash -c "test $rc = 0 && grep -qF 'OK  git: in the trusted project $dir/proj, both forms of each configured repository resolve to SSH, its remotes use SSH, the last credential.helper is the empty reset, and asking for HTTPS credentials fails' '$dir/out'"
csandbox
mkrepo "$dir/proj"; git -C "$dir/proj" config credential.helper store
trusted_toml "$dir/proj"
crun --check; rc=$?
check "trusted project with its own credential.helper: exit 1" test "$rc" = 1
check "trusted project with its own credential.helper: WRONG naming the repo and the helper" has "WRONG  git: in the trusted project $dir/proj, the last credential.helper under Codex's env is \"store\", not the empty reset: the repository's own config (or an includeIf) adds a helper after the agent identity's gitconfig"
check "trusted project with its own credential.helper: the origin is shown" bash -c "grep -q 'file:.*config.*store' '$dir/out'"
check "trusted project with its own credential.helper: Next names step 6" bash -c "grep -q '^Next: step 6 of 6 — apply the identity to the Codex config — remove that credential.helper' '$dir/out'"
csandbox
mkrepo "$dir/proj"; git -C "$dir/proj" config 'url.https://github.com/.pushInsteadOf' 'git@github.com:'
trusted_toml "$dir/proj"
crun --check; rc=$?
check "trusted project with a pushInsteadOf back to HTTPS: WRONG naming repo and rule" bash -c "test $rc = 1 && grep -qF 'WRONG  git: in the trusted project $dir/proj, git@github.com:acme/app.git becomes git@github.com:acme/app.git (fetch) and https://github.com/acme/app.git (push) under Codex' '$dir/out' && grep -q 'file:.*url.https://github.com/.pushinsteadof' '$dir/out'"
csandbox
mkrepo "$dir/proj"
printf '[credential]\n\thelper = cache\n' >"$dir/extra.cfg"
git -C "$dir/proj" config include.path "$dir/extra.cfg"
trusted_toml "$dir/proj"
crun --check; rc=$?
check "trusted project that includes a config with a helper: WRONG" bash -c "test $rc = 1 && grep -qF 'in the trusted project $dir/proj, the last credential.helper under Codex' '$dir/out' && grep -q 'file:.*extra.cfg.*cache' '$dir/out'"
csandbox
mkrepo "$dir/proj"; git -C "$dir/proj" config credential.helper store
mkdir -p "$dir/plain"
trusted_toml "$dir/plain"
printf '\n[projects."%s"]\ntrust_level = "untrusted"\n' "$dir/proj" >>"$toml"
crun --check; rc=$?
check "an untrusted project and a trusted plain directory are not checked" test "$rc" = 0
csandbox
mkrepo "$dir/cwdrepo"; git -C "$dir/cwdrepo" config credential.helper store
(cd "$dir/cwdrepo" && base_env ${DET[@]+"${DET[@]}"} bash "$apply" --codex --check </dev/null) >"$dir/out" 2>&1; rc=$?
check "the script's own git checks do not read the repository it is run from" test "$rc" = 0

echo "== --codex: a trusted project's profile with a policy"
csandbox
mkdir -p "$dir/proj/.codex"
put "$dir/proj/.codex/config.toml" $'profile = "w"\n\n[profiles.w.shell_environment_policy]\ninherit = "core"\n\n[profiles.other.shell_environment_policy]\ninherit = "none"\n'
trusted_toml "$dir/proj"
crun --check; rc=$?
check "trusted project profile with a policy: exit 1" test "$rc" = 1
check "trusted project selecting a profile with a policy: WRONG, says it selects it" has "WRONG  the trusted project config $dir/proj/.codex/config.toml defines profile \"w\" with a shell_environment_policy, and selects it with profile = \"w\"; Codex would use it instead of the agent identity's in that project"
check "trusted project profile not selected: still WRONG" has "WRONG  the trusted project config $dir/proj/.codex/config.toml defines profile \"other\" with a shell_environment_policy; Codex would use it instead of the agent identity's in that project"
check "trusted project profile: exact fix" has "  fix: remove [profiles.w.shell_environment_policy] from $dir/proj/.codex/config.toml, or stop trusting that project in $toml"

echo "== --setup --codex"
csandbox
snapshot >"$dir/snap.before"
run --setup --codex; rc=$?
snapshot >"$dir/snap.after"
check "setup --codex without a terminal: exit 2" test "$rc" = 2
check "setup --codex without a terminal: clear message with the command" has "--setup is interactive and needs a terminal, but stdin is not one. Run it yourself: bash $apply --setup --codex"
check "setup --codex without a terminal: nothing created" cmp -s "$dir/snap.before" "$dir/snap.after"

csetup_run() { # input file
  (cd "$dir" && base_env ${DET[@]+"${DET[@]}"} bash -c 'source "$1"; trap cleanup EXIT; target=codex; init; setup_steps' _ "$apply" <"$1") >"$dir/out" 2>&1
}
sandbox
put "$toml" "$toml_orig"
rm "$key.pub" 2>/dev/null; put "$key.pub" "ssh-ed25519 AAAAFAKE bot-agent"
cp "$cfg" "$dir/cfg.before"; cp "$toml" "$dir/toml.before"
dkey="$home/.ssh/id_ed25519_agent_codex_$host"
put "$stub/ssh.id_ed25519_agent_codex_$host.out" "git@github.com: Permission denied (publickey)."; put "$stub/ssh.id_ed25519_agent_codex_$host.rc" 255
printf 'y\ny\n\n\n\n' >"$dir/input"
csetup_run "$dir/input"; rc=$?
check "setup --codex: offers the two lines and appends them" bash -c "grep -q 'has no codex_ssh_key. These lines would be appended' '$dir/out' && tail -n 2 '$cfg' | head -n 1 | grep -qx 'codex_ssh_key=~/.ssh/id_ed25519_agent_codex_$host' && tail -n 1 '$cfg' | grep -qx 'codex_author_name=Codex'"
check "setup --codex: every existing line of the config is byte-identical" bash -c "prefix_ok '$cfg' '$dir/cfg.before'"
check "setup --codex: the key is generated for Codex with its own comment" bash -c "grep -q \"^ssh-keygen -t ed25519 -N  -C bot-agent@$host-codex -f $dkey\$\" '$stub/calls.log' && test -f '$dkey' && test -f '$dkey.pub'"
check "setup --codex: the Claude key is not touched" bash -c "grep -q 'FAKE PRIVATE KEY' '$key' && ! grep -q -- '-f $key' '$stub/calls.log'"
check "setup --codex: shows the .pub and where to add it" bash -c "grep -q 'AAAAFAKEKEY' '$dir/out' && grep -q 'Sign in to GitHub as bot-agent' '$dir/out'"
check "setup --codex: the shared gh login is said to be done, not asked again" has "$ghdir is already logged in as bot-agent (the login is shared with Claude Code): nothing to do."
check "setup --codex: ends with the full check and a Next line" bash -c "grep -q '== The full check' '$dir/out' && grep -q '^Next: ' '$dir/out'"
check "setup --codex: never writes config.toml or the record" bash -c "cmp -s '$toml' '$dir/toml.before' && test ! -e '$crec' && test ! -e '$cg'"
check "setup --codex: the full check was the Codex one" has "OK  the policy this script writes blanks GH_TOKEN"
# rerun: nothing more to append, nothing to generate
printf '\n\n\n' >"$dir/input"
cp "$cfg" "$dir/cfg.mid"
csetup_run "$dir/input"
check "setup --codex rerun: the existing codex_ssh_key is left as it is" bash -c "grep -q 'already has codex_ssh_key (line 7): left as it is' '$dir/out' && cmp -s '$cfg' '$dir/cfg.mid' && grep -q 'the key file already exists: left untouched, never overwritten' '$dir/out'"

sandbox
printf 'n\n' >"$dir/input"
cp "$cfg" "$dir/cfg.before"
csetup_run "$dir/input"
check "setup --codex: declining the append changes nothing" bash -c "grep -q 'skipped: nothing was appended' '$dir/out' && cmp -s '$cfg' '$dir/cfg.before'"
sandbox
rm "$cfg"
: >"$dir/input"
csetup_run "$dir/input"; rc=$?
check "setup --codex: no config file yet: tells the user to run --setup first, exit 1" bash -c "test $rc = 1 && grep -q 'bash $apply --setup' '$dir/out' && test ! -e '$cfg'"
sandbox
printf 'login=bot-agent\nemail=1+bot-agent@users.noreply.github.com\nssh_key=~/.ssh/agent_key\ngh_config_dir=~/.config/gh-agent\nrepos=acme/app' >"$cfg"; chmod 600 "$cfg"
cp "$cfg" "$dir/cfg.before"
printf 'y\nn\n\n\n\n' >"$dir/input"
csetup_run "$dir/input"
check "setup --codex: a config without a final newline gets one before the appended lines, nothing else changed" bash -c "prefix_ok '$cfg' '$dir/cfg.before' && sed -n '5p' '$cfg' | grep -qx 'repos=acme/app' && sed -n '6p' '$cfg' | grep -q '^codex_ssh_key='"
sandbox
cp "$cfg" "$dir/cfg.before"
(cd "$dir" && base_env ${DET[@]+"${DET[@]}"} bash -c 'source "$1"; trap cleanup EXIT; confirm() { printf "colour=1\n" >>"$JARVIS_AGENT_IDENTITY_FILE"; return 0; }; target=codex; init; setup_steps' _ "$apply" </dev/null) >"$dir/out" 2>&1; rc=$?
check "setup --codex: a config that changed since it was read is not appended to" bash -c "test $rc = 2 && grep -q 'changed since it was read; nothing was written' '$dir/out' && ! grep -q codex_ssh_key '$cfg' && grep -q colour=1 '$cfg'"
sandbox
cfg_append 'codex_ssh_key=~/.ssh/agent_key'
printf '\n\n\n' >"$dir/input"
csetup_run "$dir/input"; rc=$?
check "setup --codex: a codex_ssh_key equal to ssh_key goes to the full check, which says why" bash -c "test $rc = 1 && grep -q 'is the same key as ssh_key' '$dir/out' && grep -q '^Next: step 1 of 6' '$dir/out'"
if command -v python3 >/dev/null; then
  csandbox
  (cd "$dir" && base_env python3 -I - "$apply" --setup --codex <<'PY'
import os, pty, sys
import signal
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash"] + sys.argv[1:])
signal.signal(signal.SIGALRM, lambda *a: (os.kill(pid, signal.SIGKILL), os._exit(124)))
signal.alarm(300)
out = b""
while True:
    try:
        d = os.read(fd, 4096)
    except OSError:
        break
    if not d:
        break
    out += d
_, st = os.waitpid(pid, 0)
sys.stdout.buffer.write(out)
sys.exit(os.WEXITSTATUS(st))
PY
  ) >"$dir/out" 2>&1; rc=$?
  check "setup --codex on a pseudo-terminal: runs end to end, exits 0 when all is in place" bash -c "test $rc = 0 && grep -q 'Step 5 of 5' '$dir/out' && grep -q 'Next: run without --check to apply' '$dir/out'"
fi

echo "== --codex: more of a trusted project's own git config"
csandbox
mkrepo "$dir/proj"; git -C "$dir/proj" config 'credential.https://github.com.helper' '!f() { echo username=u; echo password=p; }; f'
trusted_toml "$dir/proj"
crun --check; rc=$?
check "URL-specific helper in a trusted project: exit 1" test "$rc" = 1
check "URL-specific helper: git credential fill there succeeds, which is WRONG" has "WRONG  git: in the trusted project $dir/proj, asking for HTTPS credentials for github.com succeeds under Codex's env, so a push over HTTPS would use someone's account (a credential.<url>.helper in the repository's config, for one)"
check "URL-specific helper: the origin is shown" bash -c "grep -q 'file:.*credential.https://github.com.helper' '$dir/out'"
check "URL-specific helper: the plain helper list alone would have missed it" bash -c "! grep -q 'the last credential.helper under Codex.s env is \"[^\"]' '$dir/out'"
csandbox
mkrepo "$dir/proj"; git -C "$dir/proj" remote add origin https://github.com/acme/app.git
git -C "$dir/proj" remote add elsewhere ssh://other.example/x.git
trusted_toml "$dir/proj"
crun --check; rc=$?
check "trusted project whose github remote resolves to SSH, and a non-github remote: passes" test "$rc" = 0
git -C "$dir/proj" config remote.origin.pushurl 'https://ShenYo@github.com/acme/app.git'
crun --check; rc=$?
check "trusted project remote with an HTTPS pushurl: exit 1" test "$rc" = 1
check "trusted project remote with an HTTPS pushurl: WRONG naming remote, fetch and push URL" has "WRONG  git: in the trusted project $dir/proj, the remote origin fetches from git@github.com:acme/app.git and pushes to https://ShenYo@github.com/acme/app.git under Codex's env, but a github.com remote must use git@github.com: for both"
check "trusted project remote with an HTTPS pushurl: the origin of the rule is shown" bash -c "grep -q 'file:.*remote.origin.pushurl' '$dir/out'"
csandbox
mkrepo "$dir/proj"; git -C "$dir/proj" config 'url.https://github.com/.pushInsteadOf' 'https://github.com/'
trusted_toml "$dir/proj"
crun --check; rc=$?
check "project pushInsteadOf beside the SSH insteadOf: the push rule wins, so push stays HTTPS (WRONG)" bash -c "test $rc = 1 && grep -qF 'WRONG  git: in the trusted project $dir/proj, https://github.com/acme/app.git becomes git@github.com:acme/app.git (fetch) and https://github.com/acme/app.git (push) under Codex' '$dir/out'"
csandbox
mkrepo "$dir/proj"
git -C "$dir/proj" config 'url.ssh://other.example/acme/.insteadOf' 'https://github.com/acme/'
git -C "$dir/proj" config 'url.git@github.com:acme/.pushInsteadOf' 'https://github.com/acme/'
trusted_toml "$dir/proj"
crun --check; rc=$?
check "fetch wrong but push right: still WRONG, showing both" bash -c "test $rc = 1 && grep -qF 'WRONG  git: in the trusted project $dir/proj, https://github.com/acme/app.git becomes ssh://other.example/acme/app.git (fetch) and git@github.com:acme/app.git (push) under Codex' '$dir/out'"
csandbox
mkrepo "$dir/proj"; git -C "$dir/proj" config 'url.ssh://h/a b/.pushInsteadOf' 'https://github.com/'
trusted_toml "$dir/proj"
crun --check; rc=$?
check "a url rule whose base has a space in it is read whole" bash -c "test $rc = 1 && grep -qF 'and ssh://h/a b/acme/app.git (push) under Codex' '$dir/out'"

echo "== --codex: a plain run that cannot write says so, not OK"
csandbox
crun; rm "$cg"
put "$stub/ssh.codex_key.out" "git@github.com: Permission denied (publickey)."; put "$stub/ssh.codex_key.rc" 255
crun; rc=$?
check "plain run, gitconfig missing and another check failing: exit 1" test "$rc" = 1
check "plain run, gitconfig missing and another check failing: MISSING, and nothing is written" bash -c "grep -q '^MISSING  $cg is missing although the record exists, and this run writes nothing' '$dir/out' && test ! -e '$cg'"
check "plain run, gitconfig missing and another check failing: no OK line promising a write" bash -c "! grep -q 'a real run writes it again' '$dir/out'"
csandbox
crun; put "$toml" "$toml_orig"
put "$stub/ssh.codex_key.out" "git@github.com: Permission denied (publickey)."; put "$stub/ssh.codex_key.rc" 255
crun; rc=$?
check "plain run, block gone and another check failing: MISSING, no OK line promising a write" bash -c "test $rc = 1 && grep -q '^MISSING  the record at $crec lists a block that is no longer in $toml, and this run writes nothing' '$dir/out' && ! grep -q 'a real run appends it again' '$dir/out'"
csandbox
crun; rm "$cg"
crun; rc=$?
check "plain run, gitconfig missing and everything else fine: writes it, and said so with OK" bash -c "test $rc = 0 && test -f '$cg'"

echo "== --codex: the fix text names codex_login in a separate account"
sepsandbox
put "$stub/gh-operator/user.out" "codex-bot"
crun --check
check "separate account, operator's own gh login: the fix says codex_login=" has "  fix: create a separate machine account on GitHub and set codex_login= (and its key and gh login) to that account in $cfg"
sepsandbox
put "$stub/ssh.default.out" "Hi codex-bot! You've successfully authenticated, but GitHub does not provide shell access."
crun --check
check "separate account, operator's own SSH identity: the fix says codex_login=" bash -c "grep -qF '  fix: create a separate machine account on GitHub and set codex_login= (and its key and gh login) to that account in $cfg; if codex-bot is in fact' '$dir/out'"
sepsandbox
put "$cs/repo.acme__app.out" '{"owner":{"login":"codex-bot","type":"User"},"permissions":{"admin":false,"push":true}}'
crun --check
check "separate account, codex-bot owns the repository: the fix says codex_login=" has "  fix: use a separate machine account as codex_login= in $cfg; codex-bot must not be the owner of acme/app"

echo "== --setup --codex: its final check is a check, not an apply"
csandbox
crun; rm "$cg"
: >"$dir/input"
csetup_run "$dir/input"
check "setup --codex: a missing gitconfig is MISSING in its full check" has "MISSING  $cg is missing although the record exists"

echo "== no account is named in the script"
check "the script names no account of its own" bash -c "! grep -n -i 'shenyo' '$repo/scripts/apply-agent-identity.sh' | grep -q ."

echo
if [ "$fails" -gt 0 ]; then echo "$fails failure(s)"; exit 1; fi
echo "all passed"
