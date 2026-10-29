#!/usr/bin/env bash
# Give agents their own GitHub account on this machine: check it, then write it
# into the Claude Code environment.
#
# On this machine agents act on GitHub as the owner, so the owner cannot approve
# the pull requests an agent opens. A machine account fixes that, but only if
# every piece is right: the account, its SSH key, its gh login, its access to the
# repositories, and an environment that does not quietly fall back to someone
# else's login. This script checks each piece, says exactly what is missing, and
# writes ~/.claude/settings.json only when every check passes.
#
# The identity lives in a local file, never in this repository (Jarvis is
# public, and the file holds an email address and key paths):
#
#   ~/.Jarvis/config-local/agent-identity
#
# The path is fixed and absolute, so any worktree reads the same file.
# JARVIS_AGENT_IDENTITY_FILE overrides it for the tests only; nothing else sets
# it. The format is key=value lines, # comments and blank lines; it is parsed,
# never sourced. Unknown keys, duplicates, empty values, quotes, stray
# whitespace and CRLF are each reported with their line number.
#
#   login          required  the machine account's GitHub login
#   email          required  its verified email (commits are attributed by it)
#   ssh_key        required  this machine's private key for that account (~ ok)
#   gh_config_dir  required  the GH_CONFIG_DIR the agent's gh uses (~ ok)
#   repos          required  comma-separated owner/repo list the agent works in
#   author_name    optional  commit author name, default "Claude Code"
#   codex_ssh_key  --codex   Codex's own private key for the same account (~ ok);
#                            a second key, so it can be revoked alone
#   codex_author_name optional  commit author name under Codex, default "Codex"
#   codex_login, codex_email, codex_gh_config_dir
#                  optional  a separate GitHub account for Codex (--codex only). None
#                            set: Codex uses login, email and gh_config_dir. codex_login
#                            different from login: then codex_email and
#                            codex_gh_config_dir are required, and the gh dir must be
#                            another one than gh_config_dir. codex_login equal to login
#                            is the same as not set. --setup never adds these keys.
#
# The checks follow the order a new machine is set up in, and the last line
# names the earliest step still failing:
#   1 create the config file   2 generate this machine's key
#   3 add the key's .pub to the machine account on GitHub
#   4 log gh in as the machine account (GH_CONFIG_DIR=<dir> gh auth login)
#   5 make the account a Write collaborator on each repository   6 apply
#
# A real run merges these keys into the env of ~/.claude/settings.json:
# GIT_AUTHOR_NAME, GIT_COMMITTER_NAME, GIT_AUTHOR_EMAIL, GIT_COMMITTER_EMAIL,
# GIT_SSH_COMMAND, GH_CONFIG_DIR and JARVIS_AGENT_IDENTITY (the marker the
# Claude guard reads). The keys it wrote are recorded, with their values, in
# ~/.claude/agent-identity.applied.json. A key someone else set to a different
# value is a CONFLICT: reported, never overwritten. Settings are written through
# links, after a backup (settings.json.agent-identity-backup), and not at all if
# the file changed while the script ran. A new Claude Code session picks the
# environment up; a running one keeps the old.
#
# --setup walks a new machine through steps 1 to 4. It is interactive, does
# only safe local things after asking, and never writes settings.json.
#
# --codex does the same for Codex, with the same account and its own key. Codex
# strips GIT_CONFIG_COUNT/KEY_n/VALUE_n and GIT_CONFIG_PARAMETERS from the
# commands it runs, so the forced-SSH git config cannot travel that way. What
# does reach every command is [shell_environment_policy] set in
# $CODEX_HOME/config.toml (default ~/.codex), and that carries GIT_CONFIG_GLOBAL:
# a gitconfig of ours that includes the operator's, resets credential.helper and
# rewrites https://github.com/ to SSH. A real --codex run writes, only when every
# check passes: $CODEX_HOME/agent-identity.gitconfig (mode 600), a delimited block
# appended to config.toml (the rest of the file stays byte-identical, a backup is
# config.toml.agent-identity-backup), and $CODEX_HOME/agent-identity.applied.json
# (the set map, the gitconfig and its sha256, the exact block). That record is also
# how the Codex guard knows the identity is applied: a Codex hook does not see
# `set`. A shell_environment_policy this script did not write is a CONFLICT,
# reported and never overwritten. Reading config.toml needs a python3 with tomllib
# (Python 3.11+) on PATH. A new Codex session picks the policy up; a running one
# keeps the old.
#
# Usage: apply-agent-identity.sh [--codex] [--check | --setup | --unapply]
#   (none)     run every check; when all pass, write the identity into settings
#   --check    run every check and write nothing
#   --setup    guided setup of steps 1-4 on a new machine (needs a terminal)
#   --unapply  remove exactly what a real run recorded, and the record
#   --codex    the same, for Codex instead of Claude Code
#   Exit: 0 all checks pass; 1 something to fix (nothing written); 2 usage or
#   internal error.
set -uo pipefail

target=claude   # or codex, with --codex
run_mode=apply  # apply | check: a --check also says an applied state that is stale or partial

usage() { sed -n '/^# Usage:/,/2 usage or internal error/s/^# \{0,1\}//p' "$0"; }

die() { printf 'apply-agent-identity: %s\n' "$*" >&2; exit 2; }

tmpfiles=""
tmpdirs=""
mktmp() { # template -> path, removed on exit
  local t
  t=$(mktemp "$1") || die "cannot create a temporary file for $1"
  tmpfiles="$tmpfiles
$t"
  printf '%s' "$t"
}
cleanup() {
  local f
  while IFS= read -r f; do [ -z "$f" ] || rm -f "$f"; done <<<"$tmpfiles"
  while IFS= read -r f; do [ -z "$f" ] || rm -rf "$f"; done <<<"$tmpdirs"
  return 0
}

# --- output --------------------------------------------------------------------

problems=0 warns=0 next_step=0 next_cmd="" next_net=0 cur_step=1 last_bad=0

step() { cur_step=$1; }
say() { # OK | MISSING | WRONG | WARN | SKIP, then the text
  printf '%s  %s\n' "$1" "$2"
  last_bad=0
  case $1 in
    MISSING|WRONG) problems=$((problems + 1)); last_bad=1 ;;
    WARN) warns=$((warns + 1)) ;;
  esac
}
fix() { # text [net]; its first line is what "Next:" shows if this is the earliest failing step
  local first=1 line
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then printf '  fix: %s\n' "$line"; first=0; else printf '       %s\n' "$line"; fi
  done <<<"$1"
  if [ "$last_bad" = 1 ] && { [ "$next_step" = 0 ] || [ "$cur_step" -lt "$next_step" ]; }; then
    next_step=$cur_step
    next_cmd=${1%%$'\n'*}
    next_net=0
    [ "${2-}" != net ] || next_net=1   # a failure to reach github.com, not a step to do
  fi
}
step_name() {
  case $1 in
    1) echo "create the config file" ;;
    2) echo "generate this machine's SSH key" ;;
    3) echo "add the key's .pub to the machine account on GitHub" ;;
    4) echo "log gh in as the machine account" ;;
    5) echo "make the machine account a Write collaborator on the repository" ;;
    6) if [ "${target:-claude}" = codex ]; then echo "apply the identity to the Codex config"; else echo "apply the identity to the Claude Code settings"; fi ;;
  esac
}
print_next() { # all_ok_message
  if [ "$next_step" != 0 ] && [ "$next_net" = 1 ]; then
    printf 'Next: reach github.com (steps 3 to 5 need it) — %s\n' "$next_cmd"
  elif [ "$next_step" != 0 ]; then
    printf 'Next: step %s of 6 — %s — %s\n' "$next_step" "$(step_name "$next_step")" "$next_cmd"
  else
    printf 'Next: %s\n' "$1"
  fi
}

# --- small helpers ---------------------------------------------------------------

lc() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
q() { # quote a path for a command line only when it needs it
  case $1 in
    *[!A-Za-z0-9_./~+=:@%,-]*|"") shq "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}
first_line() { printf '%s' "$1" | sed -n '1p' | cut -c1-200; }
expand_path() { # ~ and ~/x only
  case $1 in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s' "$HOME/${1#"~/"}" ;;
    *) printf '%s' "$1" ;;
  esac
}
mode_of() { stat -L -c %a "$1" 2>/dev/null || stat -L -f %Lp "$1" 2>/dev/null; }
gitc() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git "$@"; }
norm_dir() { (cd -P "$1" 2>/dev/null && pwd -P) || printf '%s' "${1%/}"; }
op_gh_dir() { printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/gh"; }
is_network() {
  printf '%s' "$1" | grep -Eiq 'could not resolve|name or service not known|nodename nor servname|connection (timed out|refused|reset|closed)|timed out|network is unreachable|no route to host|no such host|dial tcp|error connecting to|i/o timeout|tls handshake|temporary failure|kex_exchange_identification|unable to connect|proxyconnect'
}
TOKEN_VARS="GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN"

# The command that logs gh in as the machine account. --git-protocol ssh and
# --skip-ssh-key keep gh from running setup-git, which rewrites the operator's own
# ~/.gitconfig credential helper, and from generating or uploading an SSH key;
# --web signs in as the account in a browser.
gh_login_cmd() { printf 'GH_CONFIG_DIR=%s gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key --web' "$(q "$1")"; }

# gh as the agent (its own config dir, no token that would override the login)
gh_agent() {
  env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN -u GH_HOST \
    GH_CONFIG_DIR="$cfg_gh" GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1 \
    gh "$@" </dev/null 2>&1
}
# gh as the operator: the default config dir, no tokens
gh_operator() {
  env -u GH_CONFIG_DIR -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN -u GH_HOST \
    GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1 \
    gh "$@" </dev/null 2>&1
}

# --- value validators: print the problem and return 1 ----------------------------

validate_login() {
  local re='^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$'
  if [[ $1 =~ $re ]] && [ "${#1}" -le 39 ]; then return 0; fi
  echo "not a GitHub login (1-39 letters, digits and single hyphens, no leading or trailing hyphen)"
  return 1
}
validate_email() {
  local re='^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$'
  if [[ $1 =~ $re ]]; then return 0; fi
  echo "does not look like an email address (name@host.tld)"
  return 1
}
validate_path() { # after ~ expansion: absolute, and only characters safe in a command line
  local p
  p=$(expand_path "$1")
  case $1 in *'$'*|*'`'*) echo "no variables or substitutions: write an absolute path or start with ~/"; return 1 ;; esac
  case $p in /*) ;; *) echo "must be an absolute path or start with ~/ (got \"$1\")"; return 1 ;; esac
  case $p in *[!A-Za-z0-9_./+@:=,%-]*) echo "the expanded path \"$p\" has a character outside A-Z a-z 0-9 _ . / + @ : = , % -, which would break GIT_SSH_COMMAND"; return 1 ;; esac
  return 0
}
validate_gh_dir() {
  validate_path "$1" || return 1
  local p
  p=$(expand_path "$1")
  if [ "$(norm_dir "$p")" = "$(norm_dir "$(op_gh_dir)")" ]; then
    echo "is the default gh config dir $(op_gh_dir), which holds the owner's login; pick another, e.g. ~/.config/gh-agent"
    return 1
  fi
  return 0
}
validate_repos() {
  local re='^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$' r list
  case $1 in ""|,*|*,|*,,*) echo "must be owner/repo[,owner/repo...] with no empty item"; return 1 ;; esac
  list=$(printf '%s' "$1" | tr ',' '\n')
  while IFS= read -r r; do
    if ! [[ $r =~ $re ]]; then echo "\"$r\" is not owner/repo"; return 1; fi
  done <<<"$list"
  return 0
}
validate_author() {
  case $1 in *[[:cntrl:]]*|*'<'*|*'>'*) echo "must not contain control characters, < or >"; return 1 ;; esac
  return 0
}

# --- the config file -----------------------------------------------------------------

CFG_KEYS="login email ssh_key gh_config_dir repos author_name codex_ssh_key codex_author_name codex_login codex_email codex_gh_config_dir"
cfg_bad=0

bad_line() { # line, what, fix
  say WRONG "config line $1: $2"
  fix "edit line $1 of $cfg_file: $3"
  cfg_bad=$((cfg_bad + 1))
}

parse_config() {
  local k n=0 line key value allowed
  for k in $CFG_KEYS; do
    printf -v "cfg_$k" '%s' ""
    printf -v "line_$k" '%s' 0
    printf -v "rej_$k" '%s' 0
    printf -v "valid_$k" '%s' 0
  done
  cfg_bad=0
  if [ "$(wc -c <"$cfg_file" | tr -d ' ')" != "$(tr -d '\000' <"$cfg_file" | wc -c | tr -d ' ')" ]; then
    say WRONG "config file contains a NUL byte"
    fix "re-create $cfg_file as plain text (see the template with: bash $self --check)"
    cfg_bad=$((cfg_bad + 1))
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if [ "$n" = 1 ]; then
      case $line in $'\357\273\277'*) bad_line 1 "starts with a byte-order mark" "save the file as UTF-8 without a BOM"; continue ;; esac
    fi
    case $line in
      *$'\r') bad_line "$n" "ends with a carriage return (CRLF line ending)" "save the file with LF line endings (tr -d '\\r' <$(q "$cfg_file") >$(q "$cfg_file").new && chmod 600 $(q "$cfg_file").new && mv $(q "$cfg_file").new $(q "$cfg_file"))"; continue ;;
      "") continue ;;
      "#"*) continue ;;
    esac
    if [ -z "${line//[[:space:]]/}" ]; then
      bad_line "$n" "contains only whitespace" "make it an empty line or delete it"; continue
    fi
    case $line in
      [[:space:]]*) bad_line "$n" "starts with whitespace" "remove the leading whitespace (comments start with # in column 1)"; continue ;;
      *=*) ;;
      *) bad_line "$n" "is not key=value, a # comment or blank" "write it as key=value, or start it with #"; continue ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case $key in
      ""|*[!a-z_]*) bad_line "$n" "key \"$key\" has characters other than a-z and _ (no spaces around =)" "write it as key=value with no spaces, using one of: $CFG_KEYS"; continue ;;
    esac
    case " $CFG_KEYS " in
      *" $key "*) ;;
      *) bad_line "$n" "unknown key \"$key\"" "use one of: $CFG_KEYS"; continue ;;
    esac
    allowed=line_$key
    if [ "${!allowed}" != 0 ]; then
      bad_line "$n" "duplicate key \"$key\" (first on line ${!allowed})" "delete one of the two lines"
      printf -v "rej_$key" '%s' 1
      continue
    fi
    printf -v "line_$key" '%s' "$n"
    if [ -z "$value" ]; then
      bad_line "$n" "$key has an empty value" "give $key a value, or delete the line"; printf -v "rej_$key" '%s' 1; continue
    fi
    case $value in
      [[:space:]]*) bad_line "$n" "$key has whitespace before its value" "remove the space after ="; printf -v "rej_$key" '%s' 1; continue ;;
      *[[:space:]]) bad_line "$n" "$key has trailing whitespace" "remove the trailing spaces"; printf -v "rej_$key" '%s' 1; continue ;;
      \"*|*\"|\'*|*\') bad_line "$n" "$key has quotes around its value" "remove the quotes; values are taken literally"; printf -v "rej_$key" '%s' 1; continue ;;
      *[[:cntrl:]]*) bad_line "$n" "$key has a control character in its value" "retype the value"; printf -v "rej_$key" '%s' 1; continue ;;
      *" #"*) bad_line "$n" "$key has an inline comment" "put the comment on its own line"; printf -v "rej_$key" '%s' 1; continue ;;
    esac
    printf -v "cfg_$key" '%s' "$value"
  done <"$cfg_file"
  [ -n "$cfg_author_name" ] || cfg_author_name="Claude Code"
  [ -n "$cfg_codex_author_name" ] || cfg_codex_author_name="Codex"
}

chk_value() { # key validator
  local k=$1 vfn=$2 v ln rj err
  v=cfg_$k; v=${!v}; ln=line_$k; ln=${!ln}; rj=rej_$k; rj=${!rj}
  [ "$ln" != 0 ] && [ "$rj" = 0 ] || return 0
  if err=$("$vfn" "$v"); then
    printf -v "valid_$k" '%s' 1
  else
    say WRONG "config line $ln: $k=$v $err"
    fix "edit line $ln of $cfg_file: $k $err"
  fi
}

load_config() { # parse and validate; prints the problems
  local k v ln
  parse_config
  for k in login email ssh_key gh_config_dir repos; do
    ln=line_$k
    if [ "${!ln}" = 0 ]; then
      say MISSING "config key $k (required) is not in $cfg_file"
      fix "add a line to $cfg_file: $k=<value> (template: bash $self --check on a machine without the file prints one)"
    fi
  done
  chk_value login validate_login
  chk_value email validate_email
  chk_value ssh_key validate_path
  chk_value gh_config_dir validate_gh_dir
  chk_value repos validate_repos
  if [ "$line_author_name" != 0 ]; then chk_value author_name validate_author; else valid_author_name=1; fi
  [ "$valid_author_name" = 1 ] || cfg_author_name="Claude Code"
  if [ "$line_codex_author_name" != 0 ]; then chk_value codex_author_name validate_author; else valid_codex_author_name=1; fi
  [ "$valid_codex_author_name" = 1 ] || cfg_codex_author_name="Codex"
  # Codex's own key: only --codex needs it, and then it must be another key than ssh_key,
  # so it can be revoked alone. Claude mode only checks the syntax of a line that is there.
  if [ "$line_codex_ssh_key" != 0 ]; then chk_value codex_ssh_key validate_path; fi
  [ "$line_codex_login" = 0 ] || chk_value codex_login validate_login
  [ "$line_codex_email" = 0 ] || chk_value codex_email validate_email
  [ "$line_codex_gh_config_dir" = 0 ] || chk_value codex_gh_config_dir validate_gh_dir
  codex_effective
  if [ "$target" = codex ]; then
    if [ "$line_codex_ssh_key" = 0 ]; then
      say MISSING "config key codex_ssh_key (required for --codex) is not in $cfg_file"
      fix "append Codex's key to $cfg_file: printf '%s\\n' $(shq "codex_ssh_key=~/.ssh/id_ed25519_agent_codex_$(host_tag)") >>$(q "$cfg_file")   (or: bash $self --setup --codex)"
    elif [ "$valid_codex_ssh_key" = 1 ] && [ "$valid_ssh_key" = 1 ] && same_file "$(expand_path "$cfg_codex_ssh_key")" "$(expand_path "$cfg_ssh_key")"; then
      valid_codex_ssh_key=0
      say WRONG "config line $line_codex_ssh_key: codex_ssh_key=$cfg_codex_ssh_key is the same key as ssh_key=$cfg_ssh_key (line $line_ssh_key); Codex's key must be its own, so it can be revoked alone"
      fix "edit line $line_codex_ssh_key of $cfg_file: give codex_ssh_key another path, for example ~/.ssh/id_ed25519_agent_codex_$(host_tag)"
    fi
  else
    [ "$line_codex_ssh_key" != 0 ] || valid_codex_ssh_key=1
  fi
  key_path=""; cfg_gh=""; ckey_path=""
  [ "$valid_ssh_key" = 1 ] && key_path=$(expand_path "$cfg_ssh_key")
  [ "$valid_codex_ssh_key" = 1 ] && ckey_path=$(expand_path "$cfg_codex_ssh_key")
  [ "$valid_gh_config_dir" = 1 ] && cfg_gh=$(expand_path "$cfg_gh_config_dir")
  cfg_ready=0
  if [ "$cfg_bad" = 0 ] && [ "$valid_login" = 1 ] && [ "$valid_email" = 1 ] && [ "$valid_ssh_key" = 1 ] \
    && [ "$valid_gh_config_dir" = 1 ] && [ "$valid_repos" = 1 ] && [ "$valid_author_name" = 1 ] \
    && [ "$valid_codex_author_name" = 1 ] && [ "$valid_codex_ssh_key" = 1 ]; then
    cfg_ready=1
  fi
  return 0
}

print_template() {
  local dir
  dir=$(dirname "$cfg_file")
  fix "bash $self --setup
or create the file by hand:
mkdir -p -m 700 $(q "$dir") && cat >$(q "$cfg_file") <<'EOF'
# Agent identity for this machine. Read by apply-agent-identity.sh; never committed.
# One key=value per line, no quotes, no spaces around \"=\".
login=my-agent-account
email=12345+my-agent-account@users.noreply.github.com
ssh_key=~/.ssh/id_ed25519_agent_claude_$(host_tag)
gh_config_dir=~/.config/gh-agent
repos=owner/repo
# author_name=Claude Code
EOF
chmod 600 $(q "$cfg_file")
then replace every value with this machine's real ones; the directory must be
ignored by Git (a rule for config-local/ in .gitignore, or in .git/info/exclude)"
}
# Under --codex, which account Codex acts as. By default the same as Claude Code's (login,
# email, gh_config_dir). With codex_login set to another login it is a separate account:
# codex_email and codex_gh_config_dir are then required, and the effective values replace
# login, email and gh_config_dir for every check and for what is written. codex_login equal to
# login is the same as not set.
codex_effective() {
  codex_separate=0
  [ "$target" = codex ] || return 0
  local k
  if [ "$line_codex_login" = 0 ] || [ "$valid_codex_login" != 1 ]; then
    # codex_email or codex_gh_config_dir without a usable codex_login: a half-written second
    # account. Ignoring it would run Codex as the shared account while the file says otherwise.
    local why="is not set"
    [ "$line_codex_login" = 0 ] || why="is invalid"
    for k in codex_email codex_gh_config_dir; do
      local ln=line_$k
      if [ "${!ln}" != 0 ]; then
        say WRONG "config line ${!ln}: $k is set, but codex_login $why, so it is unclear which account Codex acts as"
        fix "set codex_login to the second account's login, or delete line ${!ln} of $cfg_file"
      fi
    done
    return 0
  fi
  if [ "$valid_login" = 1 ] && [ "$(lc "$cfg_codex_login")" = "$(lc "$cfg_login")" ]; then
    say OK "codex_login=$cfg_codex_login is the same account as login: Codex shares it, and codex_email and codex_gh_config_dir are ignored"
    return 0
  fi
  codex_separate=1
  if [ "$line_codex_email" = 0 ]; then
    say MISSING "config key codex_email (required when codex_login differs from login) is not in $cfg_file"
    fix "append it to $cfg_file: printf '%s\\n' $(shq "codex_email=<the verified email of $cfg_codex_login>") >>$(q "$cfg_file")   (edit the value)"
  fi
  if [ "$valid_codex_email" = 1 ] && [ "$valid_email" = 1 ] && [ "$(lc "$cfg_codex_email")" = "$(lc "$cfg_email")" ]; then
    valid_codex_email=0
    say WRONG "config line $line_codex_email: codex_email=$cfg_codex_email is the same email as email (line $line_email); commits are attributed by email, so two accounts need two"
    fix "edit line $line_codex_email of $cfg_file: set codex_email to the verified email of $cfg_codex_login"
  fi
  if [ "$line_codex_gh_config_dir" = 0 ]; then
    say MISSING "config key codex_gh_config_dir (required when codex_login differs from login) is not in $cfg_file"
    fix "append it to $cfg_file: printf '%s\\n' 'codex_gh_config_dir=~/.config/gh-agent-codex' >>$(q "$cfg_file")"
  elif [ "$valid_codex_gh_config_dir" = 1 ] && [ "$valid_gh_config_dir" = 1 ] \
    && [ "$(norm_dir "$(expand_path "$cfg_codex_gh_config_dir")")" = "$(norm_dir "$(expand_path "$cfg_gh_config_dir")")" ]; then
    valid_codex_gh_config_dir=0
    say WRONG "config line $line_codex_gh_config_dir: codex_gh_config_dir=$cfg_codex_gh_config_dir is the same gh config dir as gh_config_dir (line $line_gh_config_dir); one gh config dir cannot be logged in as two accounts"
    fix "edit line $line_codex_gh_config_dir of $cfg_file: give codex_gh_config_dir its own path, for example ~/.config/gh-agent-codex"
  fi
  cfg_login=$cfg_codex_login; valid_login=1
  cfg_email=$cfg_codex_email; valid_email=$valid_codex_email
  cfg_gh_config_dir=$cfg_codex_gh_config_dir; valid_gh_config_dir=$valid_codex_gh_config_dir
}
# How a message names the login being checked: login=<x> normally, codex_login=<x> and its line
# when Codex has an account of its own.
lref() { if [ "${codex_separate:-0}" = 1 ]; then printf 'codex_login=%s (line %s)' "$cfg_login" "$line_codex_login"; else printf 'login=%s' "$cfg_login"; fi; }
lkey() { if [ "${codex_separate:-0}" = 1 ]; then printf 'codex_login'; else printf 'login'; fi; }
cfg_author() { if [ "$target" = codex ]; then printf '%s' "$cfg_codex_author_name"; else printf '%s' "$cfg_author_name"; fi; }
same_file() { # two expanded paths: equal as text, or the same file on disk
  [ "$1" = "$2" ] && return 0
  [ -e "$1" ] && [ -e "$2" ] && [ "$1" -ef "$2" ]
}
host_tag() { (hostname -s 2>/dev/null || hostname 2>/dev/null || echo host) | head -n 1 | tr -c 'A-Za-z0-9_\n-' '_'; }

# --- the file's place in Git ------------------------------------------------------------

leak_check() { # path
  local p=$1 dir base inside top prefix rel ex rc
  dir=$(dirname "$p"); base=$(basename "$p")
  inside=$(gitc -C "$dir" rev-parse --is-inside-work-tree 2>&1)
  case $inside in
    true) ;;
    false) say OK "$p is inside a .git directory, not in a work tree"; return ;;
    *"not a git repository"*) say OK "$p is not inside a Git repository, so Git cannot publish it"; return ;;
    *) say WRONG "could not ask Git about $p: $(first_line "$inside")"
       fix "resolve that Git error (for example git config --global --add safe.directory $dir), then re-run"
       return ;;
  esac
  top=$(gitc -C "$dir" rev-parse --show-toplevel)
  gitc -C "$dir" ls-files --error-unmatch -- "$base" >/dev/null 2>&1; rc=$?
  if [ "$rc" = 0 ]; then
    say WRONG "$p is tracked by Git ($top), and this repository is public: the email would be published"
    fix "git -C $(q "$dir") rm --cached -- $(q "$base")   (if it was ever pushed, the email is already in the history)"
    return
  fi
  gitc -C "$dir" check-ignore -q -- "$base" >/dev/null 2>&1; rc=$?
  if [ "$rc" = 0 ]; then
    say OK "$p is untracked and ignored by Git ($top)"
  elif [ "$rc" = 1 ]; then
    prefix=$(gitc -C "$dir" rev-parse --show-prefix)
    rel="/$prefix$base"
    ex=$(gitc -C "$dir" rev-parse --path-format=absolute --git-path info/exclude 2>/dev/null) || ex=""
    if [ -z "$ex" ]; then
      ex=$(gitc -C "$dir" rev-parse --git-path info/exclude)
      case $ex in /*) ;; *) ex="$top/.git/info/exclude" ;; esac
    fi
    say WRONG "$p is not ignored by Git ($top): git status would offer it for commit, and this repository is public"
    fix "printf '%s\\n' $(q "$rel") >> $(q "$ex")   (or add the same line to .gitignore and commit that)"
  else
    say WRONG "git check-ignore failed for $p"
    fix "run: git -C $(q "$dir") check-ignore -v -- $(q "$base")"
  fi
}

resolve_links() { # path -> end of the chain of links
  local p=$1 hops=0 t
  while [ -L "$p" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 40 ] || die "$p: too many levels of links"
    t=$(readlink "$p")
    case $t in /*) ;; *) t="$(dirname "$p")/$t" ;; esac
    p=$t
  done
  printf '%s' "$p"
}

chk_config_file() {
  step 1
  have_cfg=0; cfg_ready=0
  if [ ! -e "$cfg_file" ]; then
    say MISSING "config file $cfg_file does not exist"
    print_template
    return
  fi
  if [ ! -f "$cfg_file" ] || [ ! -r "$cfg_file" ]; then
    say WRONG "config file $cfg_file is not a readable regular file"
    fix "chmod u+r $(q "$cfg_file")   (or replace it with a plain file)"
    return
  fi
  have_cfg=1
  say OK "config file exists: $cfg_file"
  # 2: it must not reach Git
  local real
  real=$(resolve_links "$cfg_file")
  leak_check "$cfg_file"
  if [ "$real" != "$cfg_file" ]; then leak_check "$real"; fi
  # 3: nobody else may edit it or the directory that holds it
  local m d
  m=$(mode_of "$cfg_file")
  if [ -n "$m" ] && [ $((8#$m & 022)) -ne 0 ]; then
    say WRONG "config file mode is $m: group- or world-writable, so someone else could change which account the agent uses"
    fix "chmod go-w $(q "$cfg_file")"
  else
    say OK "config file mode is ${m:-unknown}, not group- or world-writable"
  fi
  d=$(dirname "$cfg_file")
  m=$(mode_of "$d")
  if [ -n "$m" ] && [ $((8#$m & 022)) -ne 0 ]; then
    say WRONG "directory $d mode is $m: group- or world-writable"
    fix "chmod go-w $(q "$d")"
  else
    say OK "directory $d mode is ${m:-unknown}, not group- or world-writable"
  fi
  # 4: keys and values
  load_config
  if [ "$cfg_bad" = 0 ] && [ "$cfg_ready" = 1 ]; then
    say OK "config values valid: $(lref)$([ "$codex_separate" = 1 ] && echo " (Codex's own account)"), $(printf '%s\n' "$cfg_repos" | tr ',' '\n' | wc -l | tr -d ' ') repo(s), author_name=$(cfg_author)"
  fi
}

# --- ssh and gh probes ---------------------------------------------------------------------

probe_ssh() { # key
  local re='Hi ([A-Za-z0-9-]+)!'
  ssh_who=""
  ssh_out=$(ssh -T -F /dev/null -i "$1" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=15 git@github.com </dev/null 2>&1)
  if [[ $ssh_out =~ $re ]]; then ssh_who=${BASH_REMATCH[1]}; ssh_state=hi
  elif is_network "$ssh_out"; then ssh_state=net
  elif printf '%s' "$ssh_out" | grep -Eiq 'host key verification failed|remote host identification has changed'; then ssh_state=hostkey
  elif printf '%s' "$ssh_out" | grep -Fiq 'permission denied'; then ssh_state=denied
  else ssh_state=other
  fi
}

probe_gh() { # sets gh_state: ok | none | net | bad, gh_who, gh_out, gh_accounts
  local rc who
  gh_who=""; gh_accounts=0
  gh_out=$(gh_agent auth status --hostname github.com); rc=$?
  if [ "$rc" != 0 ]; then
    if is_network "$gh_out"; then gh_state=net
    elif printf '%s' "$gh_out" | grep -Eiq 'not logged in|no.*hosts|not logged into'; then gh_state=none
    else gh_state=bad
    fi
    return
  fi
  gh_accounts=$(printf '%s\n' "$gh_out" | grep -Eic 'Logged in to github\.com (as|account)')
  who=$(gh_agent api user -q .login --hostname github.com); rc=$?
  if [ "$rc" != 0 ]; then
    gh_out=$who
    if is_network "$who"; then gh_state=net; else gh_state=bad; fi
    return
  fi
  gh_who=$(printf '%s' "$who" | tr -d ' \r\n')
  gh_state=ok
}

chk_ssh() {
  local key pub keyok=1 m kvalid=$valid_ssh_key kname=ssh_key hint="--setup"
  key=$key_path
  if [ "$target" = codex ]; then kvalid=$valid_codex_ssh_key; kname=codex_ssh_key; key=$ckey_path; hint="--setup --codex"; fi
  if [ "$kvalid" != 1 ] || [ "$valid_login" != 1 ]; then
    say SKIP "SSH key and GitHub's answer to it (need a valid login and $kname in the config)"; return
  fi
  pub=$key.pub
  step 2
  if ! command -v ssh >/dev/null; then
    say MISSING "ssh is not installed"; fix "install an OpenSSH client"; return
  fi
  if [ ! -f "$key" ]; then
    say MISSING "SSH key file $key does not exist"
    fix "ssh-keygen -t ed25519 -N '' -C $(q "$cfg_login") -f $(q "$key")   (or: bash $self $hint)"
    keyok=0
  else
    m=$(mode_of "$key")
    if [ -n "$m" ] && [ $((8#$m & 077)) -ne 0 ]; then
      say WRONG "SSH key $key has mode $m; it must be 600 or stricter, or ssh refuses it"
      fix "chmod 600 $(q "$key")"
      keyok=0
    else
      say OK "SSH key $key exists, mode ${m:-unknown}"
    fi
    if [ -f "$pub" ]; then
      say OK "public key $pub exists"
    else
      say MISSING "public key $pub does not exist"
      fix "ssh-keygen -y -f $(q "$key") >$(q "$pub")"
    fi
  fi
  # ~/.ssh/config must not be able to add the operator's key: the command git runs
  # (GIT_SSH_COMMAND) ignores it with -F /dev/null; confirm with ssh -G that the
  # agent key is the only identity file it would offer.
  if [ "$keyok" = 1 ]; then
    local gout ids nids
    gout=$(ssh -G -F /dev/null -i "$key" -o IdentitiesOnly=yes github.com 2>/dev/null </dev/null)
    ids=$(printf '%s\n' "$gout" | awk 'tolower($1) == "identityfile" {print $2}')
    nids=$(printf '%s\n' "$ids" | grep -c .)
    if [ "$nids" = 0 ]; then
      say WARN "ssh -G printed no identity file, so which keys ssh would offer was not verified"
      fix "run: ssh -G -F /dev/null -i $(q "$key") -o IdentitiesOnly=yes github.com | grep -i identityfile"
    elif [ "$nids" != 1 ] || [ "$ids" != "$key" ]; then
      say WRONG "ssh would offer identity files other than the agent key $key: $(printf '%s' "$ids" | tr '\n' ' ')"
      fix "run: ssh -G -F /dev/null -i $(q "$key") -o IdentitiesOnly=yes github.com | grep -i identityfile   (only the agent key may be listed)"
    else
      say OK "ssh offers only the agent key $key under the command git will run"
    fi
  fi
  step 3
  if [ "$keyok" = 0 ]; then
    say SKIP "GitHub's answer to the SSH key (needs a usable key file)"; return
  fi
  probe_ssh "$key"
  case $ssh_state in
    hi)
      if [ "$(lc "$ssh_who")" = "$(lc "$cfg_login")" ]; then
        say OK "SSH: GitHub answers \"Hi $ssh_who!\" for $key"
      else
        say WRONG "SSH: $key authenticates as $ssh_who, but the config says $(lref)"
        fix "register $(q "$pub") on the account $cfg_login at https://github.com/settings/ssh/new (signed in as $cfg_login) and remove it from $ssh_who; also check ~/.ssh/config for another IdentityFile for github.com"
      fi ;;
    net)
      say MISSING "SSH: could not reach github.com (network), so the key was not verified"
      fix "check the network or proxy, then re-run: ssh -T -F /dev/null -i $(q "$key") -o IdentitiesOnly=yes git@github.com" net ;;
    hostkey)
      say WRONG "SSH: host key verification failed for github.com"
      fix "ssh-keygen -R github.com   (then compare the new fingerprint with GitHub's published ones)" ;;
    denied)
      say MISSING "SSH: GitHub rejected $key (Permission denied): its public key is not on the account $cfg_login"
      fix "sign in to GitHub as $cfg_login, open https://github.com/settings/ssh/new and paste the contents of $(q "$pub")" ;;
    *)
      say WRONG "SSH: unexpected answer from github.com: $(first_line "$ssh_out")"
      fix "run: ssh -vT -F /dev/null -i $(q "$key") -o IdentitiesOnly=yes git@github.com" ;;
  esac
}

chk_gh() {
  step 4
  gh_ok=0
  if [ "$valid_gh_config_dir" != 1 ] || [ "$valid_login" != 1 ]; then
    say SKIP "gh login (needs a valid login and gh_config_dir in the config)"; return
  fi
  if ! command -v gh >/dev/null; then
    say MISSING "gh is not installed"; fix "brew install gh   (or see https://cli.github.com)"; return
  fi
  probe_gh
  local dirq
  dirq=$(q "$cfg_gh")
  case $gh_state in
    none)
      say MISSING "gh: not logged in to github.com in $cfg_gh"
      fix "$(gh_login_cmd "$cfg_gh")   (sign in as $cfg_login, not as yourself)" ;;
    net)
      say MISSING "gh: could not reach github.com (network), so the login in $cfg_gh was not verified"
      fix "check the network or proxy, then re-run this check" net ;;
    bad)
      say WRONG "gh: the login in $cfg_gh does not work: $(first_line "$gh_out")"
      fix "$(gh_login_cmd "$cfg_gh")   (sign in as $cfg_login)" ;;
    ok)
      if [ "$(lc "$gh_who")" != "$(lc "$cfg_login")" ]; then
        say WRONG "gh: $cfg_gh is logged in as $gh_who, but the config says $(lref)"
        fix "GH_CONFIG_DIR=$dirq gh auth logout --hostname github.com && $(gh_login_cmd "$cfg_gh")   (sign in as $cfg_login)"
      else
        say OK "gh: GH_CONFIG_DIR=$cfg_gh is logged in as $gh_who"
        gh_ok=1
        if [ "$gh_accounts" -gt 1 ]; then
          say WARN "gh: $cfg_gh holds $gh_accounts github.com accounts; only the active one ($gh_who) is used"
          fix "GH_CONFIG_DIR=$dirq gh auth logout --hostname github.com --user <the other account>"
        fi
      fi ;;
  esac
}

chk_tokens() {
  step 4
  if [ "$target" = codex ]; then
    # Codex passes its whole environment on, tokens included, but the policy blanks these
    # for every command it runs, and gh treats an empty token or host as unset. This
    # process's own environment is not what Codex's commands get.
    say OK "the policy this script writes blanks GH_TOKEN, GITHUB_TOKEN, GH_ENTERPRISE_TOKEN, GITHUB_ENTERPRISE_TOKEN and GH_HOST for every command Codex runs, so none of them can override the agent's gh login"
    return
  fi
  local v val found=0 why
  # The process this script runs in: anything exported here by a shell profile is in
  # the agent's environment too, unless the settings env overrides it.
  for v in $TOKEN_VARS GH_HOST GIT_CONFIG_PARAMETERS GH_CONFIG_DIR; do
    val=${!v:-}
    [ -n "$val" ] || continue
    case $v in
      GH_CONFIG_DIR) [ -n "${cfg_gh:-}" ] && [ "$val" != "$cfg_gh" ] || continue
        why="it points gh at another login than the agent's $cfg_gh" ;;
      GH_HOST) why="it would send gh to another host" ;;
      GIT_CONFIG_PARAMETERS) why="it would override the agent's git config (the forced-SSH url rewrite and credential helper)" ;;
      *) why="it would override the agent's gh login with whoever owns that token" ;;
    esac
    found=1
    say WRONG "$v is set in this process; $why"
    fix "unset $v   (and remove the line that exports it from your shell profile, for example ~/.zshrc or ~/.bash_profile)"
  done
  for v in $TOKEN_VARS GH_HOST; do
    if [ "$settings_state" = ok ] && [ "$(jq -r --arg v "$v" '(.env // {}) | if type == "object" then has($v) else false end' <<<"$settings_text")" = true ]; then
      found=1
      say WRONG "$v is set in the env of $settings; it would override the agent's gh login"
      fix "remove \"$v\" from the env block of $settings"
    fi
  done
  if [ "$found" = 0 ]; then
    say OK "no GH_TOKEN, GITHUB_TOKEN, GH_ENTERPRISE_TOKEN, GH_HOST, GIT_CONFIG_PARAMETERS or foreign GH_CONFIG_DIR in this process or in the env of $settings"
  fi
}

chk_operator() {
  step 1
  if [ "$valid_login" != 1 ]; then return; fi
  if ! command -v gh >/dev/null; then return; fi
  local who rc
  who=$(gh_operator api user -q .login --hostname github.com); rc=$?
  if [ "$rc" != 0 ]; then
    if is_network "$who"; then
      say WARN "could not reach github.com to read the operator's own gh login (network), so it was not compared with $(lref)"
    else
      say WARN "the operator's own gh is not logged in (default config dir), so it was not compared with $(lref)"
    fi
    return
  fi
  who=$(printf '%s' "$who" | tr -d ' \r\n')
  if [ "$(lc "$who")" = "$(lc "$cfg_login")" ]; then
    say WRONG "$(lref) is the operator's own gh login: the agent would be the owner again and could not be reviewed by them"
    fix "create a separate machine account on GitHub and set $(lkey)= (and its key and gh login) to that account in $cfg_file"
  else
    say OK "the operator's own gh login ($who) differs from $(lref)"
  fi
}

# The operator's own SSH identity, the way a plain `ssh git@github.com` presents it (no
# -i, the normal config and agent). It covers what the operator's gh login cannot when
# that is logged out, which is usual on a new machine. No answer, or a refusal, proves
# nothing either way and is not an error.
chk_operator_ssh() {
  step 1
  if [ "$valid_login" != 1 ] || ! command -v ssh >/dev/null; then return; fi
  local out re='Hi ([A-Za-z0-9-]+)!' who=""
  out=$(ssh -T -o BatchMode=yes -o ConnectTimeout=15 git@github.com </dev/null 2>&1)
  if [[ $out =~ $re ]]; then who=${BASH_REMATCH[1]}; fi
  if [ -z "$who" ]; then
    say SKIP "the operator's own SSH identity could not be read ($(is_network "$out" && echo "network" || echo "no key offered or refused")), so it was not compared with $(lref)"
  elif [ "$(lc "$who")" = "$(lc "$cfg_login")" ]; then
    say WRONG "$(lref) is the account the operator's own SSH key authenticates as (ssh git@github.com answers \"Hi $who!\"): the agent would be the owner again"
    fix "create a separate machine account on GitHub and set $(lkey)= (and its key and gh login) to that account in $cfg_file; if $who is in fact the agent's account, its key is on a default path or in ssh-agent, so plain ssh offers it too: move it off ~/.ssh/id_* and run ssh-add -d on it"
  else
    say OK "the operator's own SSH identity ($who) differs from $(lref)"
  fi
}

# What the machine account's relationship to one repository is, in the three ways it
# can fail: no access and no invitation, an invitation not yet accepted, or accepted
# with a role above Write. Sets repo_state (ok | invited | none | net | err),
# repo_json and repo_msg.
probe_repo() { # owner/repo
  local r=$1 out rc inv push=false
  repo_json=""; repo_msg=""
  out=$(gh_agent api "repos/$r"); rc=$?
  if [ "$rc" = 0 ]; then
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$out"; then
      repo_state=err; repo_msg="GitHub's answer was not JSON: $(first_line "$out")"; return
    fi
    repo_json=$out
    push=$(jq -r '.permissions.push // false' <<<"$out")
    if [ "$push" = true ]; then repo_state=ok; return; fi
  elif is_network "$out"; then
    repo_state=net; return
  elif ! printf '%s' "$out" | grep -Eiq 'HTTP 404|not found'; then
    repo_state=err; repo_msg=$(first_line "$out"); return
  fi
  # No push access: is there an invitation waiting?
  inv=$(gh_agent api user/repository_invitations); rc=$?
  if [ "$rc" = 0 ] && jq -e --arg r "$(lc "$r")" 'type == "array" and any(.[]; (.repository.full_name // "" | ascii_downcase) == $r)' >/dev/null 2>&1 <<<"$inv"; then
    repo_state=invited
  else
    repo_state=none
  fi
}

chk_repos() {
  step 5
  local r out rc admin maintain list id rs name byp n_active owner mem
  if [ "$valid_repos" != 1 ]; then say SKIP "repository access (needs valid repos in the config)"; return; fi
  if [ "$gh_ok" != 1 ]; then say SKIP "repository access (needs the gh login of the machine account first)"; return; fi
  list=$(printf '%s' "$cfg_repos" | tr ',' '\n')
  while IFS= read -r r; do
    probe_repo "$r"
    case $repo_state in
      net)
        say MISSING "repo $r: could not reach github.com (network), so access was not verified"
        fix "check the network or proxy, then re-run this check" net
        continue ;;
      err)
        say WRONG "repo $r: reading it as $cfg_login failed: $repo_msg"
        fix "run: GH_CONFIG_DIR=$(q "$cfg_gh") gh api repos/$r"
        continue ;;
      invited)
        say MISSING "repo $r: the invitation for $cfg_login is pending, not accepted"
        fix "as $cfg_login, accept the invitation at https://github.com/$r/invitations (or github.com/notifications)"
        continue ;;
      none)
        say MISSING "repo $r: $cfg_login has no access and no pending invitation"
        fix "as the owner of $r, invite $cfg_login with Write: https://github.com/$r/settings/access (for an organization repository pick the Write role; for a personal one, a collaborator gets write by default)"
        continue ;;
    esac
    say OK "repo $r: $cfg_login can push"
    # The machine account must not be the owner's account in disguise: the repository's
    # owner, an organization owner, or a collaborator above Write can approve and merge
    # their own work, which is what the separate account is for.
    owner=$(jq -r '.owner.login // ""' <<<"$repo_json")
    if [ "$(lc "$owner")" = "$(lc "$cfg_login")" ]; then
      say WRONG "repo $r: $cfg_login owns it, so the agent would be the owner and could approve its own work"
      fix "use a separate machine account as $(lkey)= in $cfg_file; $cfg_login must not be the owner of $r"
    elif [ "$(jq -r '.owner.type // ""' <<<"$repo_json")" = Organization ]; then
      mem=$(gh_agent api "user/memberships/orgs/$owner") && \
        [ "$(jq -r '.role // ""' 2>/dev/null <<<"$mem")" = admin ] && {
          say WRONG "repo $r: $cfg_login is an owner of the organization $owner, so it could approve its own work"
          fix "make $cfg_login a plain member (https://github.com/orgs/$owner/people) or use a separate machine account"
        }
    fi
    admin=$(jq -r '.permissions.admin // false' <<<"$repo_json")
    maintain=$(jq -r '.permissions.maintain // false' <<<"$repo_json")
    if [ "$admin" = true ] || [ "$maintain" = true ]; then
      say WRONG "repo $r: $cfg_login holds the $([ "$admin" = true ] && echo admin || echo maintain) role; it must be Write, because a higher role can bypass branch protection and approve its own work"
      fix "lower $cfg_login to the Write role at https://github.com/$r/settings/access"
    fi
    rs=$(gh_agent api "repos/$r/rulesets"); rc=$?
    if [ "$rc" != 0 ] || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$rs"; then
      say WARN "repo $r: its rulesets are not readable ($(first_line "$rs")), so bypass was not checked"
      fix "check by hand: https://github.com/$r/rules, and make sure $cfg_login is not in any bypass list"
      continue
    fi
    n_active=0
    for id in $(jq -r '.[] | select(.enforcement != "disabled") | .id' <<<"$rs"); do
      n_active=$((n_active + 1))
      out=$(gh_agent api "repos/$r/rulesets/$id")
      name=$(jq -r '.name // "unnamed"' 2>/dev/null <<<"$out")
      byp=$(jq -r '.current_user_can_bypass // "unknown"' 2>/dev/null <<<"$out")
      case $byp in
        never) ;;
        always|exempt|pull_requests_only)
          say WRONG "repo $r: $cfg_login can bypass the ruleset \"$name\" ($byp)"
          fix "remove the role $cfg_login holds from the bypass list of \"$name\" at https://github.com/$r/rules/$id, or lower the account to Write" ;;
        *)
          say WARN "repo $r: cannot tell whether $cfg_login can bypass the ruleset \"$name\""
          fix "check by hand: https://github.com/$r/rules/$id" ;;
      esac
    done
    if [ "$n_active" = 0 ]; then
      say OK "repo $r: no active rulesets to bypass"
    fi
  done <<<"$list"
}

# --- settings.json -------------------------------------------------------------------------

snapshot_settings() {
  settings_state=ok; settings_text='{}'; settings_sum=absent
  rec_state=absent; rec_json='{}'
  if [ -e "$settings" ]; then
    local snap
    snap=$(mktmp "${TMPDIR:-/tmp}/apply-agent-identity.XXXXXX")
    if cp "$settings" "$snap" 2>/dev/null; then
      settings_sum=$(cksum <"$snap")
      settings_text=$(cat "$snap")
      jq -e 'type == "object"' >/dev/null 2>&1 <<<"$settings_text" || settings_state=bad
    else
      settings_state=bad; settings_text='{}'
    fi
  else
    settings_state=absent
  fi
  if [ -e "$record" ]; then
    rec_json=$(cat "$record" 2>/dev/null)
    if jq -e 'type == "object" and ((.env // {}) | type == "object")' >/dev/null 2>&1 <<<"$rec_json"; then rec_state=ok
    else rec_state=bad; rec_json='{}'; fi
  fi
}

build_want() {
  want=$(jq -n --arg name "$cfg_author_name" --arg email "$cfg_email" --arg key "$key_path" \
    --arg gh "$cfg_gh" --arg login "$cfg_login" '{
      GIT_AUTHOR_NAME: $name, GIT_COMMITTER_NAME: $name,
      GIT_AUTHOR_EMAIL: $email, GIT_COMMITTER_EMAIL: $email,
      GIT_SSH_COMMAND: ("ssh -F /dev/null -i " + $key + " -o IdentitiesOnly=yes"),
      GH_CONFIG_DIR: $gh, JARVIS_AGENT_IDENTITY: $login,
      GIT_CONFIG_COUNT: "2",
      GIT_CONFIG_KEY_0: "url.git@github.com:.insteadOf", GIT_CONFIG_VALUE_0: "https://github.com/",
      GIT_CONFIG_KEY_1: "credential.helper", GIT_CONFIG_VALUE_1: ""}')
}

chk_settings() {
  step 6
  conflicts=0
  case $settings_state in
    absent)
      say MISSING "$settings does not exist"
      fix "mkdir -p $(q "$(dirname "$settings")") && printf '{}\\n' >$(q "$settings")"
      return ;;
    bad)
      say WRONG "$settings is not a readable JSON object"
      fix "repair $(q "$settings") by hand (jq . $(q "$settings") shows the error); nothing was changed"
      return ;;
  esac
  if [ "$rec_state" = bad ]; then
    say WRONG "$record is not a JSON object with an env object"
    fix "inspect $(q "$record"); if its keys are not in $(q "$settings") you can delete it, then re-run"
    return
  fi
  if ! jq -e '(.env // {}) | type == "object"' >/dev/null 2>&1 <<<"$settings_text"; then
    say WRONG "the env of $settings is not an object"
    fix "make env in $(q "$settings") a JSON object, by hand"
    return
  fi
  say OK "$settings is a JSON object"
  if [ "$cfg_ready" != 1 ]; then
    say SKIP "the env keys this script would write (need a valid config)"; return
  fi
  build_want
  local lines k status cur recv n_write=0 n_same=0
  lines=$(jq -r --argjson want "$want" --argjson rec "$rec_json" '
    (.env // {}) as $env | ($rec.env // {}) as $re | ($want | keys[]) as $k |
    if ($env | has($k) | not) then "add\t" + $k
    elif $env[$k] == $want[$k] then "same\t" + $k
    elif ($re | has($k)) and $env[$k] == $re[$k] then "update\t" + $k
    elif ($re | has($k)) then "changed\t" + $k
    else "conflict\t" + $k end' <<<"$settings_text")
  while IFS=$'\t' read -r status k; do
    [ -n "$k" ] || continue
    case $status in
      add|update) n_write=$((n_write + 1)) ;;
      same) n_same=$((n_same + 1)) ;;
      conflict|changed)
        conflicts=$((conflicts + 1))
        cur=$(jq -c --arg k "$k" '.env[$k]' <<<"$settings_text")
        if [ "$status" = conflict ]; then
          say WRONG "CONFLICT: env.$k in $settings is $cur, which this script did not write; it would write $(jq -c --arg k "$k" '.[$k]' <<<"$want")"
          fix "if the agent identity should win, delete \"$k\" from the env block of $(q "$settings") and re-run; otherwise change the config to match"
        else
          recv=$(jq -c --arg k "$k" '.env[$k]' <<<"$rec_json")
          say WRONG "CONFLICT: env.$k in $settings is $cur, but this script wrote $recv and someone changed it since"
          fix "restore the value or delete \"$k\" from the env block of $(q "$settings"), then re-run"
        fi ;;
    esac
  done <<<"$lines"
  # Git config the settings env carries that would collide with, or undo, the forced-SSH
  # config above: a counted GIT_CONFIG_KEY_n/VALUE_n beyond ours, or GIT_CONFIG_PARAMETERS.
  local extras
  extras=$(jq -r --argjson want "$want" '(.env // {}) | keys[]
    | select(test("^GIT_CONFIG_(PARAMETERS|COUNT|KEY_[0-9]+|VALUE_[0-9]+)$"))
    | select(. as $k | $want | has($k) | not)' <<<"$settings_text")
  for k in $extras; do
    conflicts=$((conflicts + 1))
    cur=$(jq -c --arg k "$k" '.env[$k]' <<<"$settings_text")
    say WRONG "CONFLICT: env.$k in $settings is $cur; it would collide with or undo the git config this script writes to force the agent's git onto SSH (GIT_CONFIG_COUNT and the KEY_0/1, VALUE_0/1 pairs)"
    fix "delete \"$k\" from the env block of $(q "$settings") (this script does not renumber someone else's git config), then re-run"
  done
  if [ "$conflicts" = 0 ]; then
    say OK "env of $settings: $n_write key(s) to write, $n_same already in place"
  fi
  plan_n_write=$n_write
}

# Under the env a run would write, what does git do with an HTTPS GitHub remote of each
# configured repository? It must become git@github.com:<repo>.git for fetch and push,
# whatever the operator's own ~/.gitconfig says about url rewrites. No network.
chk_git_urls() {
  step 6
  if [ "$cfg_ready" != 1 ]; then say SKIP "the agent's git rewriting HTTPS GitHub remotes to SSH (needs a valid config)"; return; fi
  build_want
  local gitenv=() kv r list tmp fetch push want_url origins
  while IFS= read -r kv; do gitenv+=("$kv"); done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' <<<"$want")
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/apply-agent-identity-git.XXXXXX") || die "cannot create a temporary directory"
  tmpdirs="$tmpdirs
$tmp"
  gitc init -q --bare "$tmp/r.git" 2>/dev/null || { say WRONG "git could not create a scratch repository in $tmp"; fix "check that git works and $tmp is writable"; return; }
  gitc -C "$tmp/r.git" remote add origin https://github.com/placeholder/placeholder.git 2>/dev/null
  list=$(printf '%s' "$cfg_repos" | tr ',' '\n')
  while IFS= read -r r; do
    local form
    for form in "https://github.com/$r.git" "git@github.com:$r.git"; do
      gitc -C "$tmp/r.git" remote set-url origin "$form" 2>/dev/null
      fetch=$(env -u GIT_CONFIG_PARAMETERS "${gitenv[@]}" env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$tmp/r.git" remote get-url origin 2>&1)
      push=$(env -u GIT_CONFIG_PARAMETERS "${gitenv[@]}" env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$tmp/r.git" remote get-url --push origin 2>&1)
      want_url="git@github.com:$r.git"
      if [ "$fetch" = "$want_url" ] && [ "$push" = "$want_url" ]; then
        say OK "git: $form fetches and pushes as $want_url under the agent's env"
      else
        origins=$(gitc -C "$tmp/r.git" config --show-origin --get-regexp '^url\..*' 2>/dev/null | head -n 8)
        say WRONG "git: $form becomes $fetch (fetch) and $push (push) under the agent's env, not $want_url, so the agent could push over HTTPS as another account"
        fix "remove or change the url rewrite that wins, so it no longer touches https://github.com/ or git@github.com: (file, then key and value)
${origins:-no url.* line is set in any git config file; check includeIf and .git/config of the repository}"
      fi
    done
  done <<<"$list"
}

plan_settings() { # needs want, settings_text, rec_json
  local created
  merged=$(jq --argjson want "$want" '.env = ((.env // {}) + $want)' <<<"$settings_text")
  if [ "$rec_state" = ok ] && [ -e "$record" ]; then
    created=$(jq '.env_created // false' <<<"$rec_json")
  else
    created=$(jq 'has("env") | not' <<<"$settings_text")
  fi
  new_record=$(jq -n --argjson want "$want" --argjson rec "$rec_json" --argjson cur "$settings_text" --argjson created "$created" '
    ($cur.env // {}) as $env |
    {version: 1,
     env: ($want | to_entries
           | map(. as $e | select(($env | has($e.key) | not) or ($env[$e.key] != $e.value) or (($rec.env // {}) | has($e.key))))
           | from_entries),
     env_created: $created}')
  settings_same=0
  [ "$(jq -S . <<<"$settings_text")" = "$(jq -S . <<<"$merged")" ] && settings_same=1
  record_same=0
  if [ -e "$record" ]; then
    [ "$(jq -S . <<<"$new_record")" = "$(jq -S . "$record" 2>/dev/null)" ] && record_same=1
  elif [ "$(jq '.env | length' <<<"$new_record")" = 0 ]; then
    record_same=1
  fi
}

write_json() { # file, content: through a temporary file, mode of the old file kept
  local f=$1 content=$2 tmp
  mkdir -p "$(dirname "$f")"
  tmp=$(mktemp "$f.XXXXXX") || die "cannot create a temporary file beside $f"
  tmpfiles="$tmpfiles
$tmp"
  if [ -e "$f" ]; then cp -p "$f" "$tmp"; fi
  jq . <<<"$content" >"$tmp"
  WROTE_TMP=$tmp
}

changed_since_read() {
  local now
  if [ -e "$settings" ]; then now=$(cksum <"$settings"); else now=absent; fi
  [ "$now" != "$settings_sum" ]
}

do_apply() {
  plan_settings
  if [ "$settings_same" = 1 ] && [ "$record_same" = 1 ]; then
    echo "apply-agent-identity: $settings already carries the agent identity"
    return 0
  fi
  local rec_tmp="" set_tmp=""
  if [ "$settings_same" = 0 ]; then
    write_json "$settings" "$merged"; set_tmp=$WROTE_TMP
    # Someone may have saved the file since it was read; writing now would drop their change.
    if changed_since_read; then
      rm -f "$set_tmp"
      die "$settings changed while this ran; nothing was written, run it again"
    fi
  fi
  if [ "$record_same" = 0 ]; then
    write_json "$record" "$new_record"; rec_tmp=$WROTE_TMP
  fi
  # The record goes in first: if the run stops between the two, the next one still
  # knows which keys were meant to be this script's.
  if [ -n "$rec_tmp" ]; then mv "$rec_tmp" "$record"; fi
  if [ -n "$set_tmp" ]; then
    if [ -e "$settings" ]; then cp -p "$settings" "$settings.agent-identity-backup"; fi
    mv "$set_tmp" "$settings"
    echo "apply-agent-identity: wrote $settings (previous copy: $settings.agent-identity-backup) and $record"
  else
    echo "apply-agent-identity: $settings already carried the keys; wrote $record"
  fi
  echo "apply-agent-identity: start a new Claude Code session to pick the environment up; a running one keeps the old."
  echo "apply-agent-identity: the guard's JARVIS_REQUIRE_AGENT_IDENTITY switch is not touched; this script never sets it."
}

do_unapply() {
  snapshot_settings
  step 6
  if [ ! -e "$record" ]; then
    say OK "no record at $record: nothing to remove"
    return 0
  fi
  if [ "$rec_state" = bad ]; then
    say WRONG "$record is not a JSON object with an env object"
    fix "inspect $(q "$record") by hand; nothing was changed"
    return 1
  fi
  case $settings_state in
    bad) say WRONG "$settings is not a readable JSON object"; fix "repair $(q "$settings") by hand; nothing was changed"; return 1 ;;
  esac
  if ! jq -e '(.env // {}) | type == "object"' >/dev/null 2>&1 <<<"$settings_text"; then
    say WRONG "the env of $settings is not an object"; fix "make it an object by hand; nothing was changed"; return 1
  fi
  local lines status k cur recv conflicts=0 removed=0
  lines=$(jq -r --argjson rec "$rec_json" '
    (.env // {}) as $env | ($rec.env // {} | keys[]) as $k |
    if ($env | has($k) | not) then "absent\t" + $k
    elif $env[$k] == $rec.env[$k] then "remove\t" + $k
    else "changed\t" + $k end' <<<"$settings_text")
  while IFS=$'\t' read -r status k; do
    [ -n "$k" ] || continue
    case $status in
      remove) removed=$((removed + 1)) ;;
      absent) ;;
      changed)
        conflicts=$((conflicts + 1))
        cur=$(jq -c --arg k "$k" '.env[$k]' <<<"$settings_text")
        recv=$(jq -c --arg k "$k" '.env[$k]' <<<"$rec_json")
        say WRONG "CONFLICT: env.$k in $settings is $cur, but this script wrote $recv and someone changed it since"
        fix "restore the value or delete \"$k\" from the env block of $(q "$settings") by hand, then re-run --unapply" ;;
    esac
  done <<<"$lines"
  if [ "$conflicts" -gt 0 ]; then
    echo "apply-agent-identity: nothing was removed; settle the $conflicts conflict(s) above first"
    return 1
  fi
  local out set_tmp
  out=$(jq --argjson rec "$rec_json" '
    reduce (($rec.env // {}) | keys[]) as $k (.; if (.env // null) == null then . else del(.env[$k]) end)
    | if ($rec.env_created // false) and ((.env // null) == {}) then del(.env) else . end' <<<"$settings_text")
  if [ "$removed" -gt 0 ] || [ "$(jq -S . <<<"$out")" != "$(jq -S . <<<"$settings_text")" ]; then
    write_json "$settings" "$out"; set_tmp=$WROTE_TMP
    if changed_since_read; then
      rm -f "$set_tmp"
      die "$settings changed while this ran; nothing was written, run it again"
    fi
    if [ -e "$settings" ]; then cp -p "$settings" "$settings.agent-identity-backup"; fi
    mv "$set_tmp" "$settings"
    echo "apply-agent-identity: removed $removed key(s) from the env of $settings (previous copy: $settings.agent-identity-backup)"
  else
    echo "apply-agent-identity: none of the recorded keys is in $settings"
  fi
  rm -f "$record"
  echo "apply-agent-identity: removed $record; a new Claude Code session drops the identity"
  return 0
}

# --- --codex: the policy block in config.toml, its gitconfig and its record -----------------------------

CODEX_START='# >>> jarvis agent-identity: written by apply-agent-identity.sh --codex; change it through that script'
CODEX_END='# <<< jarvis agent-identity'
TAB=$'\t'

# The byte-exact work on config.toml, in Python because bash cannot hold every byte and
# only Python 3.11+ has a TOML parser. Run as `python3 -I -c "$CODEX_PY" <op> args`; only
# `inspect` needs tomllib. Prints tab-separated findings, never a traceback.
IFS= read -r -d '' CODEX_PY <<'PY' || true
import hashlib, json, os, sys

START = "# >>> jarvis agent-identity:"


def read(path):
    with open(path, "rb") as fh:
        return fh.read()


def flat(text):
    return str(text).replace("\n", " ").replace("\t", " ")[:300]


def sha256(path):
    print(hashlib.sha256(read(path)).hexdigest())


def edit(config, out, old, new, prefix):
    # old "-": append prefix + new. new "-": remove old (and the prefix before it).
    # Both: replace old by new. Exit 3 unless old occurs exactly once.
    data = read(config)
    pre = prefix.encode("utf-8")
    if old == "-":
        data = data + pre + read(new)
    else:
        old_b = read(old)
        if data.count(old_b) != 1:
            sys.exit(3)
        i = data.index(old_b)
        if new == "-":
            cut = len(pre) if pre and data[:i].endswith(pre) else 0
            data = data[:i - cut] + data[i + len(old_b):]
        else:
            data = data[:i] + read(new) + data[i + len(old_b):]
    with open(out, "wb") as fh:
        fh.write(data)


def inspect(config, expected, block):
    data = read(config)
    text = data.decode("utf-8", "replace")
    print("MARKERS\t%d" % sum(1 for line in text.split("\n") if line.startswith(START)))
    if block != "-":
        b = read(block)
        print("BLOCK\t%d" % data.count(b))
        if data.count(b) == 1:
            rest = data[data.index(b) + len(b):].decode("utf-8", "replace").split("\n")
            for line in rest:
                t = line.strip()
                if t == "" or t.startswith("#"):
                    continue
                if t.startswith("["):
                    break
                print("TRAILING\t" + flat(t))
                break
    try:
        import tomllib
    except ImportError:
        print("NO_TOMLLIB")
        return
    try:
        conf = tomllib.loads(data.decode("utf-8"))
    except Exception as exc:
        print("PARSE_ERR\t" + flat(exc))
        return
    pol = conf.get("shell_environment_policy")
    if pol is None:
        print("POLICY\tabsent\t")
    elif expected != "-" and pol == {"set": json.loads(expected)}:
        print("POLICY\tequal\t")
    else:
        print("POLICY\tdiffers\t" + flat(json.dumps(pol, sort_keys=True)))
    profiles = conf.get("profiles")
    if isinstance(profiles, dict):
        for name in sorted(profiles):
            if isinstance(profiles[name], dict) and "shell_environment_policy" in profiles[name]:
                print("PROFILE\t" + flat(name))
    projects = conf.get("projects")
    if isinstance(projects, dict):
        for path in sorted(projects):
            if not (isinstance(projects[path], dict) and projects[path].get("trust_level") == "trusted"):
                continue
            print("TRUSTED\t" + flat(path))
            pc = os.path.join(path, ".codex", "config.toml")
            if not os.path.isfile(pc):
                continue
            try:
                sub = tomllib.loads(read(pc).decode("utf-8"))
            except Exception as exc:
                print("PROJECT_ERR\t%s\t%s" % (flat(pc), flat(exc)))
                continue
            if "shell_environment_policy" in sub:
                print("PROJECT\t%s\t%s" % (flat(pc), flat(json.dumps(sub["shell_environment_policy"], sort_keys=True))))
            sub_profiles = sub.get("profiles")
            if isinstance(sub_profiles, dict):
                for name in sorted(sub_profiles):
                    if isinstance(sub_profiles[name], dict) and "shell_environment_policy" in sub_profiles[name]:
                        print("PROJECT_PROFILE\t%s\t%d %s" % (flat(pc), 1 if sub.get("profile") == name else 0, flat(name)))


def main():
    op, args = sys.argv[1], sys.argv[2:]
    {"sha256": sha256, "edit": edit, "inspect": inspect}[op](*args)


main()
PY

pyrun() { local py=$1; shift; "$py" -I -c "$CODEX_PY" "$@"; }

# The python3 on PATH that has tomllib (3.11+), and any python3 at all. Sets py_toml, py_any.
find_python() {
  local p
  py_toml=""; py_any=""
  while IFS= read -r p; do
    [ -x "$p" ] || continue
    "$p" -I -c 'import sys' >/dev/null 2>&1 || continue
    [ -n "$py_any" ] || py_any=$p
    if "$p" -I -c 'import tomllib' >/dev/null 2>&1; then py_toml=$p; return 0; fi
  done < <(type -ap python3 python3.14 python3.13 python3.12 python3.11 2>/dev/null)
  return 0
}

gitcfg_value() { # a value for a gitconfig line, quoted only when it needs it
  case $1 in
    ""|*[!A-Za-z0-9_./+@:%,=~-]*) printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')" ;;
    *) printf '%s' "$1" ;;
  esac
}

# What a --codex run would write, from the config: cset (the env Codex gives every command,
# as JSON), cblock (the text appended to config.toml), cg_content (the gitconfig), both
# ending in a newline.
build_codex_want() {
  local xdg inner
  cset=$(jq -n --arg name "$cfg_codex_author_name" --arg email "$cfg_email" --arg key "$ckey_path" \
    --arg gh "$cfg_gh" --arg login "$cfg_login" --arg gc "$cg_file" '{
      GIT_AUTHOR_NAME: $name, GIT_COMMITTER_NAME: $name,
      GIT_AUTHOR_EMAIL: $email, GIT_COMMITTER_EMAIL: $email,
      GIT_SSH_COMMAND: ("ssh -F /dev/null -i " + $key + " -o IdentitiesOnly=yes"),
      GIT_CONFIG_GLOBAL: $gc, GH_CONFIG_DIR: $gh, JARVIS_AGENT_IDENTITY: $login,
      GH_TOKEN: "", GITHUB_TOKEN: "", GH_ENTERPRISE_TOKEN: "", GITHUB_ENTERPRISE_TOKEN: "", GH_HOST: "",
      GIT_TERMINAL_PROMPT: "0", GIT_ASKPASS: "/usr/bin/false", SSH_ASKPASS: "/usr/bin/false"}')
  inner=$(jq -r 'to_entries | map("\(.key) = \(.value | tojson)") | join(", ")' <<<"$cset")
  cblock=$(printf '%s\n[shell_environment_policy]\nset = { %s }\n%s\n' "$CODEX_START" "$inner" "$CODEX_END"; printf x)
  cblock=${cblock%x}
  xdg="${XDG_CONFIG_HOME:-$HOME/.config}/git/config"
  cg_content=$(printf '%s\n[include]\n\tpath = %s\n\tpath = %s\n[credential]\n\thelper =\n[url "git@github.com:"]\n\tinsteadOf = https://github.com/\n' \
    "# Written by apply-agent-identity.sh --codex: the global Git config of commands Codex runs. Change it through that script." \
    "$(gitcfg_value "$xdg")" "$(gitcfg_value "$HOME/.gitconfig")"; printf x)
  cg_content=${cg_content%x}
}

# Scratch files for a run: the gitconfig that would be written, the block, the old block.
codex_scratch() {
  [ -n "${codex_tmp:-}" ] && return 0
  codex_tmp=$(mktemp -d "${TMPDIR:-/tmp}/apply-agent-identity-codex.XXXXXX") || die "cannot create a temporary directory"
  tmpdirs="$tmpdirs
$codex_tmp"
}

codex_record_ok() { # JSON text -> 0 when it is a usable record
  jq -e 'type == "object" and (.set | type) == "object" and (.gitconfig | type) == "string"
    and (.gitconfig_sha256 | type) == "string" and (.block | type) == "string" and (.prefix | type) == "string"' >/dev/null 2>&1 <<<"$1"
}

snapshot_codex() {
  crec_state=absent; crec_json='{}'; crec_block=""; crec_prefix=""
  if [ -e "$cg_record" ] || [ -L "$cg_record" ]; then
    crec_json=$(cat "$cg_record" 2>/dev/null)
    if codex_record_ok "$crec_json"; then
      crec_state=ok
      # command substitution drops trailing newlines, which the block and the prefix end in
      crec_block=$(jq -j '.block' <<<"$crec_json"; printf x); crec_block=${crec_block%x}
      crec_prefix=$(jq -j '.prefix' <<<"$crec_json"; printf x); crec_prefix=${crec_prefix%x}
    else
      crec_state=bad; crec_json='{}'
    fi
  fi
}

chk_codex_config() {
  step 6
  cplan_cfg=none; cplan_git=none; cplan_rec=none; codex_pending=0
  codex_trusted=(); codex_def_ok=(); codex_def_miss=()
  snapshot_codex
  if [ ! -e "$codex_cfg" ]; then
    say MISSING "$codex_cfg does not exist"
    fix "mkdir -p $(q "$(dirname "$codex_cfg")") && : >>$(q "$codex_cfg")"
    return
  fi
  if [ ! -f "$codex_cfg" ] || [ ! -r "$codex_cfg" ]; then
    say WRONG "$codex_cfg is not a readable regular file"
    fix "chmod u+r $(q "$codex_cfg")   (or replace it with a plain file)"
    return
  fi
  find_python
  if [ -z "$py_toml" ]; then
    say MISSING "no python3 with tomllib on PATH, so $codex_cfg cannot be parsed (it needs Python 3.11+)"
    fix "install Python 3.11+"
    return
  fi
  codex_scratch
  local exp="-" blockf="-" out kind a b
  codex_trusted=()
  if [ "$crec_state" = ok ]; then
    exp=$(jq -c '.set' <<<"$crec_json")
    blockf="$codex_tmp/recorded.block"
    printf '%s' "$crec_block" >"$blockf"
  fi
  out=$(pyrun "$py_toml" inspect "$codex_cfg" "$exp" "$blockf" 2>&1) || out="PARSE_ERR${TAB}python failed: $(first_line "$out")"
  local i_markers=0 i_block=0 i_trailing="" i_policy=absent i_desc="" i_parse="" profiles=() projects=() perrs=() pprofiles=()
  codex_trusted=()
  while IFS=$'\t' read -r kind a b; do
    case $kind in
      MARKERS) i_markers=$a ;;
      BLOCK) i_block=$a ;;
      TRAILING) i_trailing=$a ;;
      PARSE_ERR) i_parse=$a ;;
      POLICY) i_policy=$a; i_desc=$b ;;
      PROFILE) profiles+=("$a") ;;
      PROJECT) projects+=("$a$TAB$b") ;;
      PROJECT_PROFILE) pprofiles+=("$a$TAB$b") ;;
      TRUSTED) codex_trusted+=("$a") ;;
      PROJECT_ERR) perrs+=("$a$TAB$b") ;;
    esac
  done <<<"$out"
  local bad_before=$problems
  if [ -n "$i_parse" ]; then
    say WRONG "$codex_cfg does not parse as TOML: $i_parse"
    fix "repair $(q "$codex_cfg") by hand (Codex cannot read it either); nothing was changed"
    return
  fi
  say OK "$codex_cfg parses as TOML"
  for a in ${profiles[@]+"${profiles[@]}"}; do
    say WRONG "profile \"$a\" in $codex_cfg sets shell_environment_policy; Codex would use it instead of the agent identity's whenever that profile is chosen"
    fix "remove [profiles.$a.shell_environment_policy] from $(q "$codex_cfg") (this script does not merge policies)"
  done
  for a in ${projects[@]+"${projects[@]}"}; do
    kind=${a%%"$TAB"*}
    say WRONG "the trusted project config $kind sets shell_environment_policy; Codex would apply it over the agent identity's in that project"
    fix "remove shell_environment_policy from $(q "$kind"), or stop trusting that project in $(q "$codex_cfg")"
  done
  for a in ${pprofiles[@]+"${pprofiles[@]}"}; do
    kind=${a%%"$TAB"*}; b=${a#*"$TAB"}
    say WRONG "the trusted project config $kind defines profile \"${b#* }\" with a shell_environment_policy$([ "${b%% *}" = 1 ] && echo ", and selects it with profile = \"${b#* }\""); Codex would use it instead of the agent identity's in that project"
    fix "remove [profiles.${b#* }.shell_environment_policy] from $(q "$kind"), or stop trusting that project in $(q "$codex_cfg")"
  done
  for a in ${perrs[@]+"${perrs[@]}"}; do
    say WARN "the trusted project config ${a%%"$TAB"*} does not parse (${a#*"$TAB"}), so whether it sets shell_environment_policy was not checked"
    fix "repair $(q "${a%%"$TAB"*}") by hand"
  done
  if [ "$crec_state" = bad ]; then
    say WRONG "$cg_record is not a record this script wrote (a JSON object with set, gitconfig, gitconfig_sha256, block and prefix)"
    fix "inspect $(q "$cg_record"); if its block is not in $(q "$codex_cfg") you can delete it, then re-run"
    return
  fi
  # the block and the table
  local cfg_state=append    # append | same | pending-none
  if [ "$crec_state" = absent ]; then
    if [ "$i_markers" != 0 ]; then
      say WRONG "CONFLICT: $codex_cfg holds a jarvis agent-identity block, but there is no record of this script writing it at $cg_record"
      fix "remove that block from $(q "$codex_cfg") by hand (from the '# >>> jarvis agent-identity' line to the '# <<<' line), then re-run"
    elif [ "$i_policy" != absent ]; then
      say WRONG "CONFLICT: $codex_cfg already sets shell_environment_policy ($i_desc), which this script did not write; it is never overwritten"
      fix "merge by hand or remove it, then re-run: this script needs shell_environment_policy.set to carry the agent identity's variables (the README's Agent identity section lists them)"
    else
      say OK "$codex_cfg has no shell_environment_policy: the block can be appended"
    fi
  else
    if [ "$i_markers" = 0 ] && [ "$i_policy" = absent ]; then
      codex_pending=1
      if [ "$run_mode" = check ]; then
        say MISSING "the record at $cg_record lists a block that is no longer in $codex_cfg, so Codex runs without the agent identity"
        fix "bash $self --codex"
      else
        codex_def_ok+=("the record lists a block that is not in $codex_cfg: a real run appends it again")
        codex_def_miss+=("the record at $cg_record lists a block that is no longer in $codex_cfg, and this run writes nothing because of the problems above, so Codex runs without the agent identity")
      fi
    elif [ "$i_markers" = 0 ]; then
      say WRONG "CONFLICT: $codex_cfg sets shell_environment_policy ($i_desc), which this script did not write; the record at $cg_record lists a block that is no longer in the file"
      fix "remove that table from $(q "$codex_cfg") (or delete the record if the identity is no longer wanted), then re-run"
    elif [ "$i_markers" != 1 ]; then
      say WRONG "$codex_cfg holds $i_markers jarvis agent-identity blocks; this script wrote one"
      fix "remove all but the one the record describes: jq -j .block $(q "$cg_record")"
    elif [ "$i_block" != 1 ]; then
      say WRONG "the jarvis agent-identity block in $codex_cfg is not what this script wrote (edited since)"
      fix "restore it: jq -j .block $(q "$cg_record") shows the exact text; or remove the block by hand and delete $(q "$cg_record"), then re-run"
    elif [ -n "$i_trailing" ]; then
      say WRONG "a key follows the block's end marker in $codex_cfg (\"$i_trailing\"), so it belongs to our shell_environment_policy table"
      fix "move that line above the '# >>> jarvis agent-identity' line, or under its own [table], in $(q "$codex_cfg")"
    elif [ "$i_policy" != equal ]; then
      say WRONG "shell_environment_policy in $codex_cfg is not what this script wrote: $i_desc"
      fix "restore the block: jq -j .block $(q "$cg_record") shows the exact text"
    else
      say OK "the block in $codex_cfg is what this script wrote, and shell_environment_policy equals the record"
      cfg_state=same
    fi
  fi
  # the gitconfig
  if [ "$crec_state" = ok ]; then
    local recg recsha
    recg=$(jq -r '.gitconfig' <<<"$crec_json"); recsha=$(jq -r '.gitconfig_sha256' <<<"$crec_json")
    if [ "$recg" != "$cg_file" ]; then
      say WRONG "the record names the gitconfig $recg, but this run would use $cg_file (CODEX_HOME differs)"
      fix "run it with the same CODEX_HOME as the apply, or --unapply --codex there first"
    elif [ -e "$cg_file" ] || [ -L "$cg_file" ]; then
      if [ "$(pyrun "$py_toml" sha256 "$cg_file" 2>/dev/null)" = "$recsha" ]; then
        say OK "$cg_file is what this script wrote (sha256 matches the record)"
      else
        say WRONG "CONFLICT: $cg_file was changed since this script wrote it (sha256 differs from the record)"
        fix "restore it, or move it away and re-run; this script does not overwrite a gitconfig it did not write"
      fi
    elif [ "$run_mode" = check ]; then
      say MISSING "$cg_file is missing although the record exists: the policy's GIT_CONFIG_GLOBAL points at nothing, and git would fall back to the operator's credential helper and HTTPS"
      fix "bash $self --codex"
    else
      codex_def_ok+=("$cg_file is not there: a real run writes it again")
      codex_def_miss+=("$cg_file is missing although the record exists, and this run writes nothing because of the problems above, so the policy's GIT_CONFIG_GLOBAL points at nothing")
    fi
  elif [ -e "$cg_file" ] || [ -L "$cg_file" ]; then
    say WRONG "CONFLICT: $cg_file exists, but there is no record of this script writing it"
    fix "move it away if it is a stale copy, then re-run"
  fi
  if [ "$cfg_ready" != 1 ]; then
    say SKIP "the block and the gitconfig this script would write (need a valid config)"; return
  fi
  [ "$problems" = "$bad_before" ] || return 0
  # what a run would change
  build_codex_want
  printf '%s' "$cg_content" >"$codex_tmp/want.gitconfig"
  cwant_sha=$(pyrun "$py_toml" sha256 "$codex_tmp/want.gitconfig")
  printf '%s' "$cblock" >"$codex_tmp/want.block"
  local k
  if [ -s "$codex_cfg" ] && [ "$(tail -c 1 "$codex_cfg" | od -An -tx1 | tr -d ' \n')" != 0a ]; then k=$'\n\n'
  elif [ -s "$codex_cfg" ]; then k=$'\n'
  else k=""; fi
  if [ "$crec_state" = ok ]; then cprefix=$crec_prefix; else cprefix=$k; fi
  if [ "$cfg_state" = same ]; then
    [ "$crec_block" = "$cblock" ] || cplan_cfg=replace
  else
    cplan_cfg=append
    [ "$crec_state" = ok ] && cprefix=$k
  fi
  cplan_git=write
  if [ -f "$cg_file" ] && [ "$(pyrun "$py_toml" sha256 "$cg_file")" = "$cwant_sha" ]; then cplan_git=none; fi
  cnew_record=$(jq -n --argjson set "$cset" --arg gc "$cg_file" --arg sha "$cwant_sha" --arg block "$cblock" \
    --arg prefix "$cprefix" --arg cfg "$codex_cfg" \
    '{version: 1, set: $set, gitconfig: $gc, gitconfig_sha256: $sha, block: $block, prefix: $prefix, config: $cfg}')
  if [ "$crec_state" = ok ] && [ "$(jq -S . <<<"$cnew_record")" = "$(jq -S . <<<"$crec_json")" ]; then cplan_rec=none; else cplan_rec=write; fi
  local n=0
  [ "$cplan_cfg" = none ] || n=$((n + 1))
  [ "$cplan_git" = none ] || n=$((n + 1))
  [ "$cplan_rec" = none ] || n=$((n + 1))
  say OK "Codex config: $n file(s) to write ($cplan_cfg config.toml block, $cplan_git gitconfig, $cplan_rec record), the rest already in place"
}

# "A real run writes it again" is only true when every other check passes; if one does not, the
# plain run writes nothing and the state stays as it is, so it is reported as MISSING instead.
flush_codex_deferred() {
  local i=0 others=$problems
  step 6
  while [ "$i" -lt "${#codex_def_ok[@]}" ]; do
    if [ "$others" = 0 ]; then
      say OK "${codex_def_ok[$i]}"
    else
      say MISSING "${codex_def_miss[$i]}"
      fix "bash $self --codex"
    fi
    i=$((i + 1))
  done
  codex_def_ok=(); codex_def_miss=()
}

# Under the env Codex would give a command (GIT_CONFIG_GLOBAL and GIT_SSH_COMMAND from the
# policy, and no GIT_CONFIG_COUNT, which Codex strips), what does git do with each
# configured repository's HTTPS and SSH remotes, and what is the last credential.helper?
chk_codex_git() {
  step 6
  if [ "$cfg_ready" != 1 ]; then say SKIP "the agent's git under Codex's env (needs a valid config)"; return; fi
  codex_scratch
  build_codex_want
  printf '%s' "$cg_content" >"$codex_tmp/git.gitconfig"
  local gitenv=("GIT_CONFIG_GLOBAL=$codex_tmp/git.gitconfig") kv
  while IFS= read -r kv; do gitenv+=("$kv"); done < <(jq -r 'to_entries[] | select(.key | IN("GIT_SSH_COMMAND", "GIT_TERMINAL_PROMPT", "GIT_ASKPASS", "SSH_ASKPASS")) | "\(.key)=\(.value)"' <<<"$cset")
  agent_git() { env -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT "${gitenv[@]}" env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git "$@"; }
  local r list fetch push want_url origins form helper
  gitc init -q --bare "$codex_tmp/r.git" 2>/dev/null || { say WRONG "git could not create a scratch repository in $codex_tmp"; fix "check that git works and $codex_tmp is writable"; return; }
  gitc -C "$codex_tmp/r.git" remote add origin https://github.com/placeholder/placeholder.git 2>/dev/null
  list=$(printf '%s' "$cfg_repos" | tr ',' '\n')
  while IFS= read -r r; do
    for form in "https://github.com/$r.git" "git@github.com:$r.git"; do
      gitc -C "$codex_tmp/r.git" remote set-url origin "$form" 2>/dev/null
      fetch=$(agent_git -C "$codex_tmp/r.git" remote get-url origin 2>&1)
      push=$(agent_git -C "$codex_tmp/r.git" remote get-url --push origin 2>&1)
      want_url="git@github.com:$r.git"
      if [ "$fetch" = "$want_url" ] && [ "$push" = "$want_url" ]; then
        say OK "git: $form fetches and pushes as $want_url under Codex's env"
      else
        origins=$(agent_git -C "$codex_tmp/r.git" config --show-origin --get-regexp '^url\..*' 2>/dev/null | head -n 8)
        say WRONG "git: $form becomes $fetch (fetch) and $push (push) under Codex's env, not $want_url, so Codex could push over HTTPS as another account"
        fix "remove or change the url rewrite that wins (for example a pushInsteadOf back to HTTPS in your ~/.gitconfig), so it no longer touches https://github.com/ or git@github.com: (file, then key and value)
${origins:-no url.* line is set in any git config file; check includeIf and .git/config of the repository}"
      fi
    done
  done <<<"$list"
  helper=$(agent_git -C "$codex_tmp/r.git" config --get-all credential.helper 2>/dev/null | tail -n 1)
  if [ "$(agent_git -C "$codex_tmp/r.git" config --get-all credential.helper 2>/dev/null | grep -c '')" = 0 ] || [ -n "$helper" ]; then
    origins=$(agent_git -C "$codex_tmp/r.git" config --show-origin --get-all credential.helper 2>/dev/null | head -n 8)
    say WRONG "git: the last credential.helper under Codex's env is \"$helper\", not the empty reset, so a helper (the operator's) could answer for github.com"
    fix "find what sets it after the agent identity's gitconfig and remove it:
${origins:-no credential.helper line is set}"
  else
    say OK "git: the last credential.helper under Codex's env is the empty reset, so the operator's helper is never asked"
  fi
  # With no helper left and no prompt, asking for github.com credentials over HTTPS must fail.
  if printf 'protocol=https\nhost=github.com\n\n' | agent_git -C "$codex_tmp/r.git" credential fill >/dev/null 2>&1; then
    say WRONG "git: under Codex's env asking for HTTPS credentials for github.com succeeds, so a push over HTTPS would use someone's account"
    fix "find the credential helper or askpass that answers: run it under the policy's env (GIT_CONFIG_GLOBAL=$(q "$cg_file") GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false git credential fill) and look at git config --show-origin --get-all credential.helper"
  else
    say OK "git: under Codex's env asking for HTTPS credentials for github.com fails without a prompt, so Codex cannot push over HTTPS"
  fi
  # A repository's own config, or an includeIf, is read after the agent identity's gitconfig and
  # Codex cannot override it (it strips GIT_CONFIG_COUNT). Check the projects it trusts.
  local pdir
  for pdir in ${codex_trusted[@]+"${codex_trusted[@]}"}; do
    [ -d "$pdir" ] || continue
    [ "$(gitc -C "$pdir" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || continue
    chk_codex_project_git "$pdir"
  done
}

# The push URL git derives for a remote whose url is <form>, from the url.*.pushInsteadOf and
# url.*.insteadOf rules the repository sees under the agent's env: the longest matching
# pushInsteadOf prefix, else the longest insteadOf one, else the form itself. (git remote get-url
# --push needs a remote that is in a config file, and cannot be given one on the command line.)
codex_push_url() { # repo form
  local p=$1 form=$2 line key val base best_push="" best_len=-1 best_f="" best_flen=-1
  # -z: "key<newline>value" ends in NUL, so a subsection name with a space in it stays whole
  while IFS= read -r -d '' line; do
    case $line in
      *$'\n'*) key=${line%%$'\n'*}; val=${line#*$'\n'} ;;
      *) key=$line; val="" ;;
    esac
    case $key in
      url.*.pushinsteadof) base=${key#url.}; base=${base%.pushinsteadof}
        case $form in "$val"*) [ "${#val}" -gt "$best_len" ] && { best_len=${#val}; best_push="$base${form#"$val"}"; } ;; esac ;;
      url.*.insteadof) base=${key#url.}; base=${base%.insteadof}
        case $form in "$val"*) [ "${#val}" -gt "$best_flen" ] && { best_flen=${#val}; best_f="$base${form#"$val"}"; } ;; esac ;;
    esac
  done < <(agent_git -C "$p" config -z --get-regexp '^url\..*\.(pushinsteadof|insteadof)$' 2>/dev/null)
  if [ "$best_len" -ge 0 ]; then printf '%s' "$best_push"
  elif [ "$best_flen" -ge 0 ]; then printf '%s' "$best_f"
  else printf '%s' "$form"; fi
}

# The same resolution and last-helper checks, inside one trusted project's repository.
chk_codex_project_git() { # path
  local p=$1 r list form fetch push want_url origins helper n bad=0
  list=$(printf '%s' "$cfg_repos" | tr ',' '\n')
  while IFS= read -r r; do
    for form in "https://github.com/$r.git" "git@github.com:$r.git"; do
      want_url="git@github.com:$r.git"
      fetch=$(agent_git -C "$p" ls-remote --get-url "$form" 2>&1)
      push=$(codex_push_url "$p" "$form")
      if [ "$fetch" != "$want_url" ] || [ "$push" != "$want_url" ]; then
        bad=1
        origins=$(agent_git -C "$p" config --show-origin --get-regexp '^url\..*' 2>/dev/null | head -n 8)
        say WRONG "git: in the trusted project $p, $form becomes $fetch (fetch) and $push (push) under Codex's env, not $want_url: the repository's own config (or an includeIf) is read after the agent identity's gitconfig and Codex cannot override it"
        fix "remove or change the url rewrite that wins in that repository (file, then key and value):
${origins:-no url.* line is set in any git config file; check includeIf}"
      fi
    done
  done <<<"$list"
  n=$(agent_git -C "$p" config --get-all credential.helper 2>/dev/null | grep -c '')
  helper=$(agent_git -C "$p" config --get-all credential.helper 2>/dev/null | tail -n 1)
  if [ "$n" = 0 ] || [ -n "$helper" ]; then
    bad=1
    origins=$(agent_git -C "$p" config --show-origin --get-all credential.helper 2>/dev/null | head -n 8)
    say WRONG "git: in the trusted project $p, the last credential.helper under Codex's env is \"$helper\", not the empty reset: the repository's own config (or an includeIf) adds a helper after the agent identity's gitconfig"
    fix "remove that credential.helper from the repository's config (file, then key and value):
${origins:-no credential.helper line is set}"
  fi
  # The repository's own remotes, as git resolves them (a pushurl is not rewritten by pushInsteadOf).
  local name f u
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    f=$(agent_git -C "$p" remote get-url "$name" 2>&1)
    u=$(agent_git -C "$p" remote get-url --push "$name" 2>&1)
    case "$f $u" in *[Gg][Ii][Tt][Hh][Uu][Bb].[Cc][Oo][Mm]*) ;; *) continue ;; esac
    case $f in git@github.com:*) case $u in git@github.com:*) continue ;; esac ;; esac
    bad=1
    origins=$(agent_git -C "$p" config --show-origin --get-regexp "^(remote\\.$name\\.(url|pushurl)|url\\..*)" 2>/dev/null | head -n 8)
    say WRONG "git: in the trusted project $p, the remote $name fetches from $f and pushes to $u under Codex's env, but a github.com remote must use git@github.com: for both"
    fix "change the remote's url or pushurl, or the rule that rewrites it, in that repository (file, then key and value):
${origins:-no remote or url.* line was found}"
  done < <(agent_git -C "$p" remote 2>/dev/null)
  # What the helper list above cannot show: a URL-specific helper such as credential.https://github.com.helper.
  if printf 'protocol=https\nhost=github.com\n\n' | agent_git -C "$p" credential fill >/dev/null 2>&1; then
    bad=1
    origins=$(agent_git -C "$p" config --show-origin --get-regexp '^credential\.' 2>/dev/null | head -n 8)
    say WRONG "git: in the trusted project $p, asking for HTTPS credentials for github.com succeeds under Codex's env, so a push over HTTPS would use someone's account (a credential.<url>.helper in the repository's config, for one)"
    fix "remove the credential helper that answers from that repository's config (file, then key and value):
${origins:-no credential.* line was found; run git credential fill there under the policy env}"
  fi
  if [ "$bad" = 0 ]; then
    say OK "git: in the trusted project $p, both forms of each configured repository resolve to SSH, its remotes use SSH, the last credential.helper is the empty reset, and asking for HTTPS credentials fails"
  fi
}

sum_of() { if [ -e "$1" ]; then cksum <"$1"; else echo absent; fi; }
changed_since_read_codex() { [ "$(sum_of "$codex_cfg")" != "$ccfg_sum" ]; }

do_apply_codex() {
  if [ "$cplan_cfg" = none ] && [ "$cplan_git" = none ] && [ "$cplan_rec" = none ]; then
    echo "apply-agent-identity: $codex_cfg already carries the agent identity"
    return 0
  fi
  local tmp_rec="" tmp_git="" tmp_cfg="" old new
  if [ "$cplan_cfg" != none ]; then
    tmp_cfg=$(mktemp "$codex_cfg.XXXXXX") || die "cannot create a temporary file beside $codex_cfg"
    tmpfiles="$tmpfiles
$tmp_cfg"
    cp -p "$codex_cfg" "$tmp_cfg"
    old="-"
    if [ "$cplan_cfg" = replace ]; then old="$codex_tmp/recorded.block"; fi
    pyrun "$py_toml" edit "$codex_cfg" "$tmp_cfg" "$old" "$codex_tmp/want.block" "$cprefix" || die "could not prepare the new $codex_cfg; nothing was written"
    # Someone may have saved the file since it was read; writing now would drop their change.
    if changed_since_read_codex; then
      die "$codex_cfg changed while this ran; nothing was written, run it again"
    fi
  fi
  if [ "$cplan_rec" != none ]; then
    mkdir -p "$codex_home"
    tmp_rec=$(mktemp "$cg_record.XXXXXX") || die "cannot create a temporary file beside $cg_record"
    tmpfiles="$tmpfiles
$tmp_rec"
    jq . <<<"$cnew_record" >"$tmp_rec"
    chmod 600 "$tmp_rec"
  fi
  if [ "$cplan_git" != none ]; then
    mkdir -p "$codex_home"
    tmp_git=$(mktemp "$cg_file.XXXXXX") || die "cannot create a temporary file beside $cg_file"
    tmpfiles="$tmpfiles
$tmp_git"
    printf '%s' "$cg_content" >"$tmp_git"
    chmod 600 "$tmp_git"
  fi
  # The record goes in first, then the gitconfig, and config.toml last: it is what makes
  # Codex use them, and a run that stops earlier leaves nothing half-applied.
  if [ -n "$tmp_rec" ]; then mv "$tmp_rec" "$cg_record"; fi
  if [ -n "$tmp_git" ]; then mv "$tmp_git" "$cg_file"; fi
  if [ -n "$tmp_cfg" ]; then
    cp -p "$codex_cfg" "$codex_cfg.agent-identity-backup"
    mv "$tmp_cfg" "$codex_cfg"
    echo "apply-agent-identity: wrote the block to $codex_cfg (previous copy: $codex_cfg.agent-identity-backup), $cg_file and $cg_record"
  else
    echo "apply-agent-identity: $codex_cfg already carried the block; wrote $cg_file and $cg_record as needed"
  fi
  echo "apply-agent-identity: restart Codex to pick the policy up; a running session keeps the old environment."
  echo "apply-agent-identity: the guard's JARVIS_REQUIRE_AGENT_IDENTITY switch is not touched; this script never sets it."
}

do_unapply_codex() {
  step 6
  ccfg_sum=$(sum_of "$codex_cfg")
  snapshot_codex
  if [ "$crec_state" = absent ]; then
    say OK "no record at $cg_record: nothing to remove"
    return 0
  fi
  if [ "$crec_state" = bad ]; then
    say WRONG "$cg_record is not a record this script wrote"
    fix "inspect $(q "$cg_record") by hand; nothing was changed"
    return 1
  fi
  find_python
  local py=${py_toml:-$py_any}
  if [ -z "$py" ]; then
    say MISSING "no python3 on PATH, which removing the block from $codex_cfg needs"
    fix "install Python 3"
    return 1
  fi
  codex_scratch
  local blockf="$codex_tmp/recorded.block" out kind a b markers=0 nblock=0 trailing="" tmp_cfg="" recg recsha
  printf '%s' "$crec_block" >"$blockf"
  recg=$(jq -r '.gitconfig' <<<"$crec_json"); recsha=$(jq -r '.gitconfig_sha256' <<<"$crec_json")
  if [ -f "$codex_cfg" ]; then
    out=$(pyrun "$py" inspect "$codex_cfg" "-" "$blockf" 2>&1)
    while IFS=$'\t' read -r kind a b; do
      case $kind in MARKERS) markers=$a ;; BLOCK) nblock=$a ;; TRAILING) trailing=$a ;; esac
    done <<<"$out"
  fi
  if [ "$markers" != 0 ] && { [ "$nblock" != 1 ] || [ "$markers" != 1 ]; }; then
    say WRONG "the jarvis agent-identity block in $codex_cfg is not byte-identical to what this script wrote (edited, or more than one)"
    fix "restore it (jq -j .block $(q "$cg_record") shows the exact text) or remove the block by hand and delete $(q "$cg_record"); nothing was changed"
    return 1
  fi
  if [ "$markers" = 1 ] && [ -n "$trailing" ]; then
    say WRONG "a key follows the block's end marker in $codex_cfg (\"$trailing\"); removing the block would move it into another table"
    fix "move that line out from under the block, then re-run --unapply --codex; nothing was changed"
    return 1
  fi
  if [ "$markers" = 1 ]; then
    tmp_cfg=$(mktemp "$codex_cfg.XXXXXX") || die "cannot create a temporary file beside $codex_cfg"
    tmpfiles="$tmpfiles
$tmp_cfg"
    cp -p "$codex_cfg" "$tmp_cfg"
    pyrun "$py" edit "$codex_cfg" "$tmp_cfg" "$blockf" "-" "$crec_prefix" || die "could not prepare the new $codex_cfg; nothing was written"
    if changed_since_read_codex; then
      die "$codex_cfg changed while this ran; nothing was written, run it again"
    fi
    cp -p "$codex_cfg" "$codex_cfg.agent-identity-backup"
    mv "$tmp_cfg" "$codex_cfg"
    echo "apply-agent-identity: removed the block from $codex_cfg (previous copy: $codex_cfg.agent-identity-backup)"
  else
    echo "apply-agent-identity: the block is not in $codex_cfg"
  fi
  if [ -e "$recg" ] || [ -L "$recg" ]; then
    if [ -f "$recg" ] && [ "$(pyrun "$py" sha256 "$recg")" = "$recsha" ]; then
      rm -f "$recg"
      echo "apply-agent-identity: removed $recg"
    else
      say WARN "$recg was changed since this script wrote it, so it was left in place; nothing refers to it any more"
      fix "delete it by hand if you do not need it: rm -- $(q "$recg")"
    fi
  fi
  rm -f "$cg_record"
  echo "apply-agent-identity: removed $cg_record; a new Codex session drops the identity"
  return 0
}

# --- the checks, in the order a new machine is set up ----------------------------------------------

run_checks() {
  problems=0 warns=0 next_step=0 next_cmd="" next_net=0 last_bad=0
  gh_ok=0; plan_n_write=0
  valid_login=0 valid_ssh_key=0 valid_gh_config_dir=0 valid_repos=0 cfg_ready=0
  if [ "$target" = codex ]; then ccfg_sum=$(sum_of "$codex_cfg"); else snapshot_settings; fi
  chk_config_file
  if [ "$have_cfg" = 1 ]; then
    chk_ssh
    chk_gh
  else
    step 2
    say SKIP "SSH key, gh login and repository access (need the config file)"
  fi
  chk_tokens
  chk_operator
  chk_operator_ssh
  if [ "$have_cfg" = 1 ]; then chk_repos; fi
  if [ "$target" = codex ]; then
    chk_codex_config
    chk_codex_git
    flush_codex_deferred
  else
    chk_settings
    chk_git_urls
  fi
}

finish_checks() { # prints Next and the summary
  local ready_msg="run without --check to apply"
  if [ "$problems" = 0 ] && [ "$target" = codex ]; then
    if [ "$cplan_cfg" = none ] && [ "$cplan_git" = none ] && [ "$cplan_rec" = none ]; then
      ready_msg="nothing — the identity is already applied; a new Codex session uses it"
    fi
  elif [ "$problems" = 0 ]; then
    plan_settings 2>/dev/null
    if [ "${settings_same:-0}" = 1 ] && [ "${record_same:-0}" = 1 ]; then
      ready_msg="nothing — the identity is already applied; a new Claude Code session uses it"
    fi
  fi
  print_next "$ready_msg"
}

# --- --setup: the guided path for a new machine --------------------------------------------------------

abort_input() { echo; die "input ended; stopped here. Nothing further was done. Re-run --setup to continue."; }
ask() { # prompt, validator, [default] -> ASK
  local ans err
  while :; do
    printf '%s%s: ' "$1" "${3:+ [$3]}"
    IFS= read -r ans || abort_input
    [ -n "$ans" ] || ans=${3:-}
    if [ -z "$ans" ]; then echo "  a value is required"; continue; fi
    if err=$("$2" "$ans"); then ASK=$ans; return 0; fi
    echo "  $err"
  done
}
confirm() { # question -> 0 for yes
  local ans
  printf '%s [y/N] ' "$1"
  IFS= read -r ans || abort_input
  case $ans in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}
pause() { # message
  local ans
  printf '%s ' "$1"
  IFS= read -r ans || abort_input
  [ -t 0 ] || echo
}

validate_codex_key() { # a path for Codex's key: valid, and not the Claude key
  validate_path "$1" || return 1
  if same_file "$(expand_path "$1")" "$(expand_path "$cfg_ssh_key")"; then
    echo "is the same key as ssh_key=$cfg_ssh_key; Codex's key must be its own, so it can be revoked alone"
    return 1
  fi
  return 0
}

# --setup --codex, step 1: the config file exists already (Claude Code was set up first); add
# Codex's key to it after asking, changing none of its lines.
setup_codex_config() {
  local host add="" now tmp
  host=$(host_tag)
  if [ ! -e "$cfg_file" ]; then
    echo "  does not exist. Codex uses the same account as Claude Code, so create the file first:"
    echo "    bash $self --setup"
    echo "  then re-run: bash $self --setup --codex"
    return 1
  fi
  if [ ! -f "$cfg_file" ] || [ ! -r "$cfg_file" ]; then
    echo "  $cfg_file is not a readable regular file; fix that first (the check below says how)."
    return 0
  fi
  parse_config >/dev/null
  if [ "$line_codex_ssh_key" != 0 ]; then
    echo "  already has codex_ssh_key (line $line_codex_ssh_key): left as it is (edit it by hand to change a value)."
    return 0
  fi
  add="codex_ssh_key=~/.ssh/id_ed25519_agent_codex_$host"
  if [ "$line_codex_author_name" = 0 ]; then add="$add
codex_author_name=Codex"; fi
  echo "  $cfg_file has no codex_ssh_key. These lines would be appended; every existing line stays as it is:"
  printf '%s\n' "$add" | sed 's/^/    /'
  if ! confirm "  append them?"; then
    echo "  skipped: nothing was appended."
    return 0
  fi
  now=$(cksum <"$cfg_file")
  [ "$now" = "$setup_cfg_sum" ] || die "$cfg_file changed since it was read; nothing was written, run --setup --codex again"
  tmp=$(mktemp "$cfg_file.XXXXXX") || die "cannot create a temporary file beside $cfg_file"
  tmpfiles="$tmpfiles
$tmp"
  cp -p "$cfg_file" "$tmp"
  { if [ -s "$cfg_file" ] && [ "$(tail -c 1 "$cfg_file" | od -An -tx1 | tr -d ' \n')" != 0a ]; then printf '\n'; fi
    printf '%s\n' "$add"; } >>"$tmp"
  [ "$(cksum <"$cfg_file")" = "$setup_cfg_sum" ] || die "$cfg_file changed while this ran; nothing was written, run --setup --codex again"
  mv "$tmp" "$cfg_file"
  echo "  appended to $cfg_file"
  return 0
}

setup_steps() {
  gh_state=none; gh_who=""; gh_ok=0
  local host dir ans_login ans_email ans_key ans_gh ans_repos ans_author comment pub body skey
  host=$(host_tag)
  setup_cfg_sum=absent
  [ ! -f "$cfg_file" ] || setup_cfg_sum=$(cksum <"$cfg_file")
  echo "Agent identity setup for this machine$([ "$target" = codex ] && echo ", for Codex")."
  if [ "$target" = codex ]; then
    echo "It adds Codex's own SSH key to the config file and creates it after asking, and tells you what to do on GitHub."
    echo "It never writes $codex_cfg and never touches your own gh login or keys."
  else
    echo "It creates the config file and this machine's SSH key after asking, and tells you what to do on GitHub."
    echo "It never writes $settings and never touches your own gh login or keys."
  fi
  echo
  echo "== Step 1 of 5: the config file ($cfg_file)"
  if [ "$target" = codex ]; then
    setup_codex_config || return 1
  elif [ -e "$cfg_file" ]; then
    echo "  already exists: left as it is (edit it by hand to change a value)."
  else
    ask "  machine account login" validate_login; ans_login=$ASK
    ask "  its verified email" validate_email; ans_email=$ASK
    ask "  private key path" validate_path "~/.ssh/id_ed25519_agent_claude_$host"; ans_key=$ASK
    ask "  gh config dir for the agent" validate_gh_dir "~/.config/gh-agent"; ans_gh=$ASK
    ask "  repositories (owner/repo, comma-separated)" validate_repos; ans_repos=$ASK
    ask "  commit author name" validate_author "Claude Code"; ans_author=$ASK
    body="# Agent identity for this machine. Read by apply-agent-identity.sh; never committed.
login=$ans_login
email=$ans_email
ssh_key=$ans_key
gh_config_dir=$ans_gh
repos=$ans_repos
author_name=$ans_author"
    echo
    echo "  $cfg_file would contain:"
    printf '%s\n' "$body" | sed 's/^/    /'
    if confirm "  create the directory and this file (mode 600)?"; then
      dir=$(dirname "$cfg_file")
      mkdir -p -m 700 "$dir" || die "cannot create $dir"
      ( set -C; umask 077; printf '%s\n' "$body" >"$cfg_file" ) || die "cannot create $cfg_file (it may have appeared meanwhile); nothing overwritten"
      echo "  created $cfg_file"
    else
      echo "  skipped: no file was created."
    fi
  fi
  if [ ! -f "$cfg_file" ]; then
    echo; echo "Without the config file the rest cannot continue. Re-run --setup when ready."
    return 0
  fi
  parse_config >/dev/null
  chk_value login validate_login >/dev/null; chk_value ssh_key validate_path >/dev/null
  chk_value gh_config_dir validate_gh_dir >/dev/null; chk_value repos validate_repos >/dev/null
  if [ "$target" = codex ]; then
    if [ "$line_codex_ssh_key" != 0 ]; then
      chk_value codex_ssh_key validate_codex_key >/dev/null
    fi
    chk_value email validate_email >/dev/null
    [ "$line_codex_login" = 0 ] || chk_value codex_login validate_login >/dev/null
    [ "$line_codex_email" = 0 ] || chk_value codex_email validate_email >/dev/null
    [ "$line_codex_gh_config_dir" = 0 ] || chk_value codex_gh_config_dir validate_gh_dir >/dev/null
    codex_effective >/dev/null
  fi
  if [ "$valid_login" != 1 ] || [ "$valid_ssh_key" != 1 ] || [ "$valid_gh_config_dir" != 1 ] \
    || { [ "$target" = codex ] && [ "$valid_email" != 1 ]; } \
    || { [ "$target" = codex ] && [ "$valid_codex_ssh_key" != 1 ]; }; then
    echo; echo "The config file has problems that need editing by hand; the check below lists them."
    echo
    run_checks; print_next "run without --check to apply"
    [ "$problems" = 0 ]; return
  fi
  key_path=$(expand_path "$cfg_ssh_key"); cfg_gh=$(expand_path "$cfg_gh_config_dir")
  skey=$key_path
  [ "$target" != codex ] || { ckey_path=$(expand_path "$cfg_codex_ssh_key"); skey=$ckey_path; }
  pub=$skey.pub

  echo
  echo "== Step 2 of 5: $([ "$target" = codex ] && echo "Codex's own" || echo "this machine's") SSH key ($skey)"
  if [ -e "$skey" ] || [ -L "$skey" ]; then
    echo "  the key file already exists: left untouched, never overwritten."
  elif [ -e "$pub" ] || [ -L "$pub" ]; then
    echo "  $pub exists but $skey does not. Not generating: ssh-keygen would overwrite that .pub."
    echo "  Move $pub away, or point $([ "$target" = codex ] && echo codex_ssh_key || echo ssh_key) at the matching private key, then re-run."
  else
    comment="$cfg_login@$host"
    [ "$target" != codex ] || comment="$cfg_login@$host-codex"
    echo "  will run: ssh-keygen -t ed25519 -N '' -C $comment -f $skey"
    echo "  (no passphrase: the agent runs unattended; the key is mode 600 and works for one account only)"
    if confirm "  generate it?"; then
      mkdir -p -m 700 "$(dirname "$skey")" || die "cannot create $(dirname "$skey")"
      ssh-keygen -t ed25519 -N '' -C "$comment" -f "$skey" >/dev/null || die "ssh-keygen failed; nothing else was changed"
      echo "  generated $skey and $pub"
    else
      echo "  skipped: no key was generated."
    fi
  fi

  echo
  echo "== Step 3 of 5: the key on the machine account's GitHub profile"
  if [ -f "$skey" ] && command -v ssh >/dev/null; then
    probe_ssh "$skey"
    if [ "$ssh_state" = hi ] && [ "$(lc "$ssh_who")" = "$(lc "$cfg_login")" ]; then
      echo "  GitHub already answers \"Hi $ssh_who!\" for this key: nothing to add."
    elif [ -f "$pub" ]; then
      echo "  Sign in to GitHub as $cfg_login (not as yourself), then:"
      echo "    Settings -> SSH and GPG keys -> New SSH key (https://github.com/settings/ssh/new)"
      echo "  Paste this public key:"
      sed 's/^/    /' "$pub"
      pause "  Press Enter when it is added."
    else
      echo "  $pub is missing; create it with: ssh-keygen -y -f $(q "$skey") >$(q "$pub")"
    fi
  else
    echo "  no key file yet: nothing to add."
  fi

  echo
  echo "== Step 4 of 5: gh logged in as the machine account"
  if command -v gh >/dev/null; then
    probe_gh
    if [ "$gh_state" = ok ] && [ "$(lc "$gh_who")" = "$(lc "$cfg_login")" ]; then
      echo "  $cfg_gh is already logged in as $gh_who$([ "$target" = codex ] && echo " (the login is shared with Claude Code)"): nothing to do."
    else
      echo "  Run this in another terminal and sign in as $cfg_login, not as yourself:"
      echo "    $(gh_login_cmd "$cfg_gh")"
      pause "  Press Enter when it is done."
    fi
  else
    echo "  gh is not installed. Install it (brew install gh, or see https://cli.github.com), then re-run --setup."
    echo "  Continuing to the full check, which lists everything still open."
  fi

  echo
  echo "== Step 5 of 5: the machine account on each repository"
  if [ "$gh_state" = ok ] && [ "$(lc "$gh_who")" = "$(lc "$cfg_login")" ] && [ "$valid_repos" = 1 ]; then
    gh_ok=1; problems=0; next_step=0
    chk_repos
    if [ "$problems" -gt 0 ]; then
      echo "  Do what the fix line says (invite the account as Write, or accept the invitation as $cfg_login)."
      pause "  Press Enter when done; the full check below will look again."
    fi
  else
    echo "  skipped: needs the gh login above first, and valid repos in the config."
  fi

  echo
  echo "== The full check"
  run_mode=check
  run_checks
  print_next "run without --check to apply"
  [ "$problems" = 0 ]
}

setup_main() {
  if [ ! -t 0 ]; then
    die "--setup is interactive and needs a terminal, but stdin is not one. Run it yourself: bash $self --setup$([ "$target" = codex ] && echo " --codex")"
  fi
  setup_steps
}

# --- main ---------------------------------------------------------------------------------------------------

init() {
  command -v jq >/dev/null || die "jq is required"
  command -v git >/dev/null || die "git is required"
  [ -n "${HOME:-}" ] || die "HOME is not set"
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  cfg_file="${JARVIS_AGENT_IDENTITY_FILE:-$HOME/.Jarvis/config-local/agent-identity}"
  claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  settings=$(resolve_links "$claude_home/settings.json")
  record="$claude_home/agent-identity.applied.json"
  codex_home="${CODEX_HOME:-$HOME/.codex}"
  codex_cfg=$(resolve_links "$codex_home/config.toml")
  cg_file="$codex_home/agent-identity.gitconfig"
  cg_record="$codex_home/agent-identity.applied.json"
}

main() {
  local mode=apply have_mode=0 have_codex=0 a
  for a in "$@"; do
    case $a in
      --codex) [ "$have_codex" = 0 ] || { usage >&2; exit 2; }; have_codex=1; target=codex ;;
      --check|--setup|--unapply|-h|--help)
        [ "$have_mode" = 0 ] || { usage >&2; exit 2; }
        have_mode=1
        case $a in
          --check) mode=check ;;
          --setup) mode=setup ;;
          --unapply) mode=unapply ;;
          *) usage; exit 0 ;;
        esac ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  trap cleanup EXIT
  init
  run_mode=$mode
  case $mode in
    unapply) if [ "$target" = codex ]; then do_unapply_codex; else do_unapply; fi; exit $? ;;
    setup) setup_main; exit $? ;;
  esac
  run_checks
  finish_checks
  if [ "$problems" -gt 0 ]; then
    echo "apply-agent-identity: $problems problem(s) to fix"
    [ "$mode" = check ] || echo "apply-agent-identity: nothing was written"
    exit 1
  fi
  if [ "$mode" = check ]; then
    if [ "$warns" -gt 0 ]; then
      echo "apply-agent-identity: all checks passed ($warns warning(s))"
    else
      echo "apply-agent-identity: all checks passed"
    fi
    exit 0
  fi
  if [ "$target" = codex ]; then do_apply_codex; else do_apply; fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
