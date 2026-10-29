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

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
apply="${APPLY_AGENT_IDENTITY:-$repo/scripts/apply-agent-identity.sh}"
orig_path=$PATH
root=$(mktemp -d "${TMPDIR:-/tmp}/agent-identity-test.XXXXXX")
echo "sandboxes: $root"

fails=0
n=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
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
    HOME="$home" CLAUDE_CONFIG_DIR="$home/.claude" JARVIS_AGENT_IDENTITY_FILE="$cfg" STUB_DIR="$stub" \
    STUB_SETTINGS="$settings" GIT_CONFIG_NOSYSTEM=1 PATH="${TEST_PATH:-$root/bin:$PATH}" $XENV "$@"
}
run() { (cd "$dir" && base_env bash "$apply" "$@" </dev/null) >"$dir/out" 2>&1; }
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
(cd "$dir" && base_env env -u JARVIS_AGENT_IDENTITY_FILE bash "$apply" --check </dev/null) >"$dir/out" 2>&1
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
badline "unknown key" 'colour=red' 'unknown key "colour"' 'use one of: login email ssh_key gh_config_dir repos author_name'
badline "duplicate key" 'login=other' 'duplicate key "login" (first on line 2)' 'delete one of the two lines'
badline "empty value" 'author_name=' 'author_name has an empty value' 'give author_name a value, or delete the line'
badline "quotes" 'author_name="Bot"' 'author_name has quotes around its value' 'remove the quotes; values are taken literally'
badline "single quotes" "author_name='Bot'" 'author_name has quotes around its value' 'remove the quotes; values are taken literally'
badline "trailing space" 'author_name=Bot ' 'author_name has trailing whitespace' 'remove the trailing spaces'
badline "leading value space" 'author_name= Bot' 'author_name has whitespace before its value' 'remove the space after ='
badline "spaces around =" 'author_name = Bot' 'key "author_name " has characters other than a-z and _ (no spaces around =)' 'write it as key=value with no spaces, using one of: login email ssh_key gh_config_dir repos author_name'
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
  (cd "$dir" && base_env bash -c 'source "$1"; trap cleanup EXIT; init; setup_steps' _ "$apply" <"$1") >"$dir/out" 2>&1
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
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash"] + sys.argv[1:])
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

echo "== no account is named in the script"
check "the script names no account of its own" bash -c "! grep -n -i 'shenyo' '$repo/scripts/apply-agent-identity.sh' | grep -q ."

echo
if [ "$fails" -gt 0 ]; then echo "$fails failure(s)"; exit 1; fi
echo "all passed"
