#!/usr/bin/env bash
# One command that shows whether this machine's agent setup is intact.
#
# It runs, read-only, the checks that otherwise have to be remembered one by one,
# and prints one result line per check, then a summary and the next command:
#
#   bridge          sync-personal-skills.sh --check   every Skill linked, none wrong-target
#   skill-lock      scripts/check-skill-lock.sh       vendored Skills match their lock
#   claude-guard    apply-claude-guard.sh --check     the installed guard is the repo's
#   codex-guard     apply-codex-guard.sh --check      same for Codex, and Codex trusts it
#   identity        apply-agent-identity.sh --check   optional; includes SSH and gh (network)
#   identity-codex  apply-agent-identity.sh --check --codex
#   live-callback   always UNVERIFIED: no static check proves a running session calls the hook
#
# Result words, one at the start of each line so they can be grepped:
#   ok          the check passed
#   PROBLEM     the check failed; the line after it names the fix
#   skipped     not applicable here (Codex not installed, identity not configured: optional)
#   UNVERIFIED  could not be established by a static check
# Only PROBLEM makes the exit status 1.
#
# It writes nothing and repairs nothing. It honours the environment of the scripts
# it runs (HOME, CODEX_HOME, CLAUDE_CONFIG_DIR, JARVIS_AGENT_IDENTITY_FILE).
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
identity_file="${JARVIS_AGENT_IDENTITY_FILE:-$HOME/.Jarvis/config-local/agent-identity}"

n_ok=0 n_problem=0 n_skipped=0 n_unverified=0
first_fix=""

result() { # <word> <name> <text>
  printf '%-11s %-15s %s\n' "$1" "$2" "$3"
  case $1 in
    ok) n_ok=$((n_ok + 1)) ;;
    PROBLEM) n_problem=$((n_problem + 1)) ;;
    skipped) n_skipped=$((n_skipped + 1)) ;;
    UNVERIFIED) n_unverified=$((n_unverified + 1)) ;;
  esac
}

problem() { # <name> <text> <fix command> <captured output>
  local line count=0
  result PROBLEM "$1" "$2"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case $line in "OK  "*|*"already carry the guard"*|*"switch is "*) continue ;; esac   # what passed is not the news
    count=$((count + 1))
    [ "$count" -le 6 ] || { printf '%-11s %-15s %s\n' "" "" "  | ..."; break; }
    printf '%-11s %-15s %s\n' "" "" "  | $line"
  done <<<"$4"
  printf '%-11s %-15s %s\n' "" "" "fix: $3"
  [ -n "$first_fix" ] || first_fix=$3
}

# check <name> <ok text> <fix command> <command...>: run it, capture its output.
check() {
  local name=$1 okmsg=$2 fix=$3 out rc
  shift 3
  out=$("$@" 2>&1 </dev/null); rc=$?
  last_out=$out last_rc=$rc
  if [ "$rc" = 0 ]; then
    result ok "$name" "$okmsg"
  else
    problem "$name" "exit $rc" "$fix" "$out"
  fi
}

echo "doctor: checking the agent setup of this machine (reads only, changes nothing)"

check bridge "every Skill is linked into every installed tool, none points at the wrong target" \
  "bash $here/sync-personal-skills.sh   (an entry reported CONFLICT must be moved away first)" \
  bash "$here/sync-personal-skills.sh" --check

check skill-lock "every Skill matches its lock entry or is maintained here" \
  "restore the Skill from git or update it through its CLI, never patch it (see AGENTS.md)" \
  bash "$here/scripts/check-skill-lock.sh"

check claude-guard "the installed guard is the repository's" \
  "bash $here/scripts/apply-claude-guard.sh" \
  bash "$here/scripts/apply-claude-guard.sh" --check

if [ -d "$codex_home" ]; then
  out=$(bash "$here/scripts/apply-codex-guard.sh" --check 2>&1 </dev/null); rc=$?
  if [ "$rc" = 0 ]; then
    result ok codex-guard "the installed guard is the repository's and Codex trusts it"
  elif [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q 'trust: UNVERIFIABLE' \
       && ! printf '%s\n' "$out" | grep -Eq 'differs from|trust: (UNTRUSTED|DISABLED|NOT-INSTALLED)'; then
    result UNVERIFIED codex-guard "the guard is installed, but whether Codex trusts it could not be read: $(printf '%s\n' "$out" | sed -n 's/.*trust: UNVERIFIABLE - //p' | head -1)"
  else
    if ! printf '%s\n' "$out" | grep -q 'differs from' && printf '%s\n' "$out" | grep -Eq 'trust: (UNTRUSTED|DISABLED)'; then
      fix="open /hooks in Codex and trust (or enable) the Jarvis guard; the installed guard itself is current"
    else
      fix="bash $here/scripts/apply-codex-guard.sh   (then open /hooks in Codex and trust the guard)"
    fi
    problem codex-guard "exit $rc" "$fix" "$out"
  fi
else
  result skipped codex-guard "Codex is not set up ($codex_home does not exist)"
fi

if [ -f "$identity_file" ]; then
  check identity "the agent identity is configured, applied and reachable" \
    "bash $here/scripts/apply-agent-identity.sh --check   (its fix: and Next: lines say what to do)" \
    bash "$here/scripts/apply-agent-identity.sh" --check
  if [ -d "$codex_home" ]; then
    check identity-codex "the Codex agent identity is configured, applied and trusted" \
      "bash $here/scripts/apply-agent-identity.sh --check --codex   (its fix: and Next: lines say what to do)" \
      bash "$here/scripts/apply-agent-identity.sh" --check --codex
  else
    result skipped identity-codex "Codex is not set up ($codex_home does not exist)"
  fi
else
  result skipped identity "not configured (optional): $identity_file does not exist"
  result skipped identity-codex "not configured (optional)"
fi

result UNVERIFIED live-callback \
  "a passing static check does not prove a running session calls the hook; see docs/guard.md, section \"Turning the switch on\" (#turning-the-switch-on)"

if [ "$n_problem" -gt 0 ]; then
  echo "doctor: $n_problem problem(s), $n_ok ok, $n_skipped skipped, $n_unverified UNVERIFIED. Next: $first_fix"
  exit 1
fi
echo "doctor: no problem found ($n_ok ok, $n_skipped skipped, $n_unverified UNVERIFIED). Next: in a new session, confirm the guard refuses a probe command; see docs/guard.md#turning-the-switch-on"
exit 0
