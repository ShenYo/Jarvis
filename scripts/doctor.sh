#!/usr/bin/env bash
# One command that shows whether this machine's agent setup is intact.
#
# It runs the checks that otherwise have to be remembered one by one, and prints
# one result line per check, then a summary and the next command:
#
#   bridge          sync-personal-skills.sh --check   every Skill linked, none wrong-target
#   skill-lock      scripts/check-skill-lock.sh       vendored Skills match their lock, committed
#                   and in the working tree (git status of .agents/skills is empty)
#   claude-guard    apply-claude-guard.sh --check     the installed guard is the repo's
#   codex-guard     apply-codex-guard.sh --check      same for Codex, and Codex trusts it
#   identity        apply-agent-identity.sh --check   optional; includes SSH and gh (network);
#                   only "state: applied" is ok
#   identity-codex  apply-agent-identity.sh --check --codex
#   live-callback   always UNVERIFIED: no static check proves a running session calls the hook
# It does not run the `core.hooksPath` check of the setup guide.
#
# Result words, one at the start of each line so they can be grepped:
#   ok          the check passed
#   PROBLEM     the check failed; the lines after it name the fix
#   skipped     not applicable here (Codex not installed; identity not configured: optional)
#   UNVERIFIED  could not be established by a static check, or passed with a warning
#   ERROR       the check itself could not run (it exited 2); doctor then exits 2
# Only PROBLEM makes the exit status 1. UNVERIFIED does not: read those lines.
#
# It repairs nothing and writes no file of its own. One exception it cannot
# remove: the identity check's SSH probe uses StrictHostKeyChecking=accept-new,
# so on first contact OpenSSH adds github.com to ~/.ssh/known_hosts. It honours
# the environment of the scripts it runs (HOME, CODEX_HOME, CLAUDE_CONFIG_DIR,
# JARVIS_AGENT_IDENTITY_FILE).
#
# Usage: doctor.sh
#   Exit: 0 no problem; 1 at least one PROBLEM; 2 usage or internal error.
set -uo pipefail

usage() { sed -n '/^# Usage:/,/2 usage or internal error/s/^# \{0,1\}//p' "$0"; }

case "${1-}" in
  "") ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 2
for f in sync-personal-skills.sh scripts/check-skill-lock.sh scripts/apply-claude-guard.sh \
         scripts/apply-codex-guard.sh scripts/apply-agent-identity.sh; do
  [ -f "$here/$f" ] || { echo "doctor: $here/$f is missing" >&2; exit 2; }
done

codex_home="${CODEX_HOME:-$HOME/.codex}"
claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
identity_file="${JARVIS_AGENT_IDENTITY_FILE:-$HOME/.Jarvis/config-local/agent-identity}"

n_ok=0 n_problem=0 n_skipped=0 n_unverified=0 n_error=0
first_fix="" first_error=""
out="" rc=0 checkfix=""

result() { # <word> <name> <text>
  printf '%-11s %-15s %s\n' "$1" "$2" "$3"
  case $1 in
    ok) n_ok=$((n_ok + 1)) ;;
    PROBLEM) n_problem=$((n_problem + 1)) ;;
    skipped) n_skipped=$((n_skipped + 1)) ;;
    UNVERIFIED) n_unverified=$((n_unverified + 1)) ;;
    ERROR) n_error=$((n_error + 1)) ;;
  esac
}

# detail <captured output> <grep -E pattern or empty>: indented excerpt. Control
# characters are removed first, C0 and the C1 range (U+0080-U+009F as UTF-8): output
# can carry a Skill's name, which is not trusted not to move the cursor or rewrite
# the screen.
detail() {
  local line count=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case $line in "OK  "*|*"already carry the guard"*|*"switch is "*) continue ;; esac   # what passed is not the news
    if [ -n "${2-}" ]; then printf '%s\n' "$line" | grep -Eq "$2" || continue; fi
    count=$((count + 1))
    [ "$count" -le 6 ] || { printf '%-11s %-15s %s\n' "" "" "  | ..."; break; }
    printf '%-11s %-15s %s\n' "" "" "  | $line"
  done <<<"$(printf '%s\n' "$1" | LC_ALL=C tr -d '\000-\010\013-\037\177' |
             LC_ALL=C sed "s/$(printf '\302')[$(printf '\200')-$(printf '\237')]//g")"
}

problem() { # <name> <text> <fix command> <captured output> [<grep -E pattern for the excerpt>]
  result PROBLEM "$1" "$2"
  detail "$4" "${5-}"
  printf '%-11s %-15s %s\n' "" "" "fix: $3"
  [ -n "$first_fix" ] || first_fix=$3
}

failed_to_run() { # <name> <captured output>
  result ERROR "$1" "could not run (exit $rc); this is an error of the check, not a finding about the machine"
  detail "$2"
  [ -n "$first_error" ] || first_error=$1
}

warn_pattern='^WARN  |: WARN:'

# A trust that could not be read, and nothing else wrong: no python3 with tomllib, or a hook entry key
# the hash formula does not know. A config.toml that does not parse is not in this set, because its
# message names neither of the two: that is a fault.
unverifiable_only() { # <captured output>
  printf '%s\n' "$1" | grep -q 'UNVERIFIABLE' &&
  printf '%s\n' "$1" | grep -q 'needs a python3 with tomllib\|hash formula does not know' &&
  ! printf '%s\n' "$1" | grep -q 'apply-codex-guard: .*differs from\|trust: UNTRUSTED\|trust: DISABLED\|trust: NOT-INSTALLED'
}

# judge <name> <ok text> <fix> <kind>: classify $out and $rc of the check just run.
#   kind guard    the Codex guard: UNVERIFIED when trust is unverifiable and nothing else is wrong
#   kind identity the identity checks: only "state: applied" is ok
#   kind plain    everything else
judge() {
  local name=$1 okmsg=$2 fix=$3 kind=$4 state warns
  if [ "$rc" = 2 ]; then failed_to_run "$name" "$out"; return; fi
  if [ "$rc" = 0 ]; then
    state=$(printf '%s\n' "$out" | sed -n 's/^apply-agent-identity: state: //p' | head -1)
    warns=$(printf '%s\n' "$out" | grep -E "$warn_pattern")
    if [ "$kind" = identity ] && [ "$state" != applied ]; then
      problem "$name" "every check passes, but the identity is not applied (state: ${state:-unknown})" "$fix" "$out"
    elif printf '%s\n' "$warns" | grep -q '^WARN  agent-identity switch:'; then
      # Definite: the switch is on in one runtime and not the other, or a record outlives its setting. Not a gap in
      # what could be checked, so it is a finding. Other warnings say something was not checked (rulesets,
      # network): UNVERIFIED, and so is any warning whose text is not known here.
      problem "$name" "the agent-identity switch is inconsistent" "$checkfix" "$out" '^WARN  agent-identity switch:'
    elif [ -n "$warns" ]; then
      result UNVERIFIED "$name" "passes, with $(printf '%s\n' "$warns" | grep -c .) warning(s); first: $(printf '%s\n' "$warns" | head -1 |
        sed 's/^WARN  //; s/^[^:]*: WARN: //' | LC_ALL=C tr -d '\000-\037\177' | cut -c1-110)"
      detail "$out" "$warn_pattern"
    else
      result ok "$name" "$okmsg"
    fi
    return
  fi
  if [ "$kind" != plain ] && [ "$rc" = 1 ] && unverifiable_only "$out"; then
    if [ "$kind" = guard ]; then
      result UNVERIFIED "$name" "whether Codex trusts the guard could not be read; the rest passes"
      detail "$out" 'UNVERIFIABLE'
      return
    fi
    # identity-codex: the only failing lines are about tomllib, and the Codex identity was applied before (its
    # record exists). Without the record, the identity was never applied: that is a finding, not a gap.
    if [ -e "$codex_home/agent-identity.applied.json" ] &&
       [ "$(printf '%s\n' "$out" | grep -c '^\(WRONG\|MISSING\)  ')" = \
         "$(printf '%s\n' "$out" | grep '^\(WRONG\|MISSING\)  ' | grep -c 'tomllib')" ]; then
      result UNVERIFIED "$name" "$codex_home/config.toml could not be parsed (no python3 with tomllib), so the Codex identity in it went unchecked"
      detail "$out" 'tomllib'
      return
    fi
    if [ ! -e "$codex_home/agent-identity.applied.json" ]; then
      why="Codex's trust of the guard could not be read"
      ! printf '%s\n' "$out" | grep -q 'tomllib' || why="config.toml cannot be parsed here: no python3 with tomllib"
      problem "$name" "the Codex identity is not applied (and $why)" \
        "bash $here/scripts/apply-agent-identity.sh --codex" "$out"
      return
    fi
  fi
  if [ "$name" = codex-guard ] && ! printf '%s\n' "$out" | grep -q 'apply-codex-guard: .*differs from' &&
     printf '%s\n' "$out" | grep -q 'trust: \(UNTRUSTED\|DISABLED\)'; then
    fix="open /hooks in Codex and trust (or enable) the Jarvis guard; the installed guard itself is current"
  fi
  [ "$kind" != identity ] || fix=$checkfix   # a failing identity check: what to do is in its own fix: lines
  problem "$name" "exit $rc" "$fix" "$out"
}

# check <name> <ok text> <fix> <kind> <command...>
check() {
  local name=$1 okmsg=$2 fix=$3 kind=$4
  shift 4
  out=$("$@" 2>&1 </dev/null); rc=$?
  judge "$name" "$okmsg" "$fix" "$kind"
}

echo "doctor: checking the agent setup of this machine (changes nothing; see the header for one SSH exception)"

check bridge "every Skill is linked into every installed tool, none points at the wrong target" \
  "bash $here/sync-personal-skills.sh   (an entry reported CONFLICT must be moved away first)" plain \
  bash "$here/sync-personal-skills.sh" --check

# The lock check reads HEAD; agents read the working tree, so a patched or untracked file in a Skill is a
# finding too. GIT_OPTIONAL_LOCKS=0 keeps git status from refreshing (writing) the index.
out=$(bash "$here/scripts/check-skill-lock.sh" 2>&1 </dev/null); rc=$?
if [ "$rc" = 0 ]; then
  # Skills the lock check exempts as maintained here (it names them in `maintained=`) have no lock to differ from.
  excl=()
  for m in $(sed -n 's/^maintained="\(.*\)"$/\1/p' "$here/scripts/check-skill-lock.sh"); do
    excl=(${excl[@]+"${excl[@]}"} ":(exclude).agents/skills/$m")
  done
  dirty=$(GIT_OPTIONAL_LOCKS=0 git -C "$here" status --porcelain -- .agents/skills ${excl[@]+"${excl[@]}"} 2>&1 </dev/null); grc=$?
  if [ "$grc" != 0 ]; then
    rc=$grc; failed_to_run skill-lock "$dirty"
  elif [ -n "$dirty" ]; then
    rc=1
    problem skill-lock "a Skill in the working tree differs from what is committed (and locked)" \
      "git -C $here status --short -- .agents/skills; restore it from git or update it through its CLI, never patch it (see AGENTS.md)" "$dirty"
  else
    result ok skill-lock "every Skill matches its lock entry or is maintained here, committed and in the working tree"
  fi
else
  judge skill-lock "" "restore the Skill from git or update it through its CLI, never patch it (see AGENTS.md)" plain
fi

check claude-guard "the installed guard is the repository's" \
  "bash $here/scripts/apply-claude-guard.sh" plain \
  bash "$here/scripts/apply-claude-guard.sh" --check

if [ -d "$codex_home" ]; then
  check codex-guard "the installed guard is the repository's and Codex trusts it" \
    "bash $here/scripts/apply-codex-guard.sh   (then open /hooks in Codex and trust the guard)" guard \
    bash "$here/scripts/apply-codex-guard.sh" --check
else
  result skipped codex-guard "Codex is not set up ($codex_home does not exist)"
fi

# The identity is optional only when nothing of it exists: no config file, no switch, no applied record.
# A switch or a record without the file is a machine that refuses, or has kept, GitHub writes: the
# check runs and says so. A path that exists but is not a regular file is left to the check to report.
claude_evidence=0 codex_evidence=0 shared_evidence=0
{ [ -e "$identity_file" ] || [ -L "$identity_file" ]; } && shared_evidence=1
[ "${JARVIS_REQUIRE_AGENT_IDENTITY:-}" = 1 ] && shared_evidence=1
jq -e '.env.JARVIS_REQUIRE_AGENT_IDENTITY == "1"' "$claude_home/settings.json" >/dev/null 2>&1 && shared_evidence=1
# The require record is looked up where apply-agent-identity.sh (claude_switch_state) looks: in the Claude config
# directory and in ~/.claude. A record that cannot be read counts as on there, so any record counts here.
for rec in "$claude_home/agent-identity.require.json" "$HOME/.claude/agent-identity.require.json"; do
  { [ -e "$rec" ] || [ -L "$rec" ]; } && shared_evidence=1
done
# Codex's switch is an argument of its hook command: --require-identity after --codex (as codex_switch_state reads it).
if [ -e "$codex_home/hooks.json" ] && [ "$(jq -r '
    def own_h: (.command? // "") | contains("/hooks/jarvis-guard.py");
    [(.hooks.PreToolUse // [])[] | .hooks[]? | select(own_h)] | first
    | if . == null then "none"
      elif ((.command // "") | [splits("[ \t]+")] as $w | ($w | index("--codex")) as $i
            | $i != null and (($w[$i + 1:]) | index("--require-identity") != null)) then "on"
      else "off" end' "$codex_home/hooks.json" 2>/dev/null)" = on ]; then
  shared_evidence=1
fi
{ [ -e "$claude_home/agent-identity.applied.json" ] || [ -L "$claude_home/agent-identity.applied.json" ]; } && claude_evidence=1
{ [ -e "$codex_home/agent-identity.applied.json" ] || [ -L "$codex_home/agent-identity.applied.json" ]; } && codex_evidence=1

if [ "$shared_evidence" = 1 ] || [ "$claude_evidence" = 1 ]; then
  checkfix="bash $here/scripts/apply-agent-identity.sh --check   (its fix: and Next: lines say what to do)"
  check identity "the agent identity is configured, applied and reachable" \
    "bash $here/scripts/apply-agent-identity.sh" identity \
    bash "$here/scripts/apply-agent-identity.sh" --check
else
  result skipped identity "not configured (optional): no config file ($identity_file), no switch, no applied record"
fi
if [ "$shared_evidence" = 1 ] || [ "$codex_evidence" = 1 ]; then
  if [ -d "$codex_home" ]; then
    checkfix="bash $here/scripts/apply-agent-identity.sh --check --codex   (its fix: and Next: lines say what to do)"
    check identity-codex "the Codex agent identity is configured, applied and trusted" \
      "bash $here/scripts/apply-agent-identity.sh --codex" identity \
      bash "$here/scripts/apply-agent-identity.sh" --check --codex
  else
    result skipped identity-codex "Codex is not set up ($codex_home does not exist)"
  fi
else
  result skipped identity-codex "not configured (optional)"
fi

result UNVERIFIED live-callback \
  "a passing static check does not prove a running session calls the hook; see docs/guard.md, section \"Turning the switch on\" (#turning-the-switch-on)"

if [ "$n_error" -gt 0 ]; then
  echo "doctor: could not run $n_error check(s) (first: $first_error); $n_problem problem(s), $n_ok ok. Next: fix what stopped it, then run doctor again (usually jq missing, or a settings file that is not JSON)"
  exit 2
fi
if [ "$n_problem" -gt 0 ]; then
  echo "doctor: $n_problem problem(s), $n_ok ok, $n_skipped skipped, $n_unverified UNVERIFIED. Next: $first_fix"
  exit 1
fi
echo "doctor: no problem found ($n_ok ok, $n_skipped skipped, $n_unverified UNVERIFIED). Next: read each UNVERIFIED line; in a new session, confirm the guard refuses a probe command; see docs/guard.md#turning-the-switch-on"
exit 0
