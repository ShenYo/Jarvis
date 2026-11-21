#!/usr/bin/env bash
# Set up this machine in the staged order of docs/setup-new-machine.md: every scriptable step of stages 1 and 2,
# and a clear stop at each step only a person can do.
#
#   stage 1  instructions and Skills   Git hooks path, the bridge (sync-personal-skills.sh)
#   stage 2  the guard                 apply-claude-guard.sh, apply-codex-guard.sh
#   stage 3  agent identity            never done here: optional, and it needs a person (see the guide)
#
# Run it from the checkout, which must be ~/.Jarvis (the one command a person types first is the
# clone in step 2 of the guide). Run it again after each stop: it is idempotent, so a step already
# done is reported `ok` and changes nothing.
#
# It never installs a system package, never trusts a hook for Codex, and never signs in anywhere.
# A step only a person can do stops the run with what to do, where, how to know it worked, and the
# command to resume. It does not run apply-agent-identity.sh and does not ask for the machine account.
#
# Usage: bootstrap.sh [--check]
#   (none)   run the stages in order; stop at the first person-only step
#   --check  change nothing: run scripts/doctor.sh and print exactly what it prints, with its exit status
#   Exit: 0 stages 1 and 2 are done; 3 stopped at a person-only step (do it, then run again);
#         1 a step failed or the checkout is not ~/.Jarvis; 2 usage or internal error.
set -uo pipefail

usage() { sed -n '/^# Usage:/,/2 usage or internal error/s/^# \{0,1\}//p' "$0"; }

check=0
case "${1-}" in
  "") ;;
  --check) check=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P) || exit 2
[ -f "$here/scripts/doctor.sh" ] || { echo "bootstrap: $here/scripts/doctor.sh is missing" >&2; exit 2; }

# Read-only: doctor's own output and exit status, nothing added.
if [ "$check" = 1 ]; then
  exec bash "$here/scripts/doctor.sh"
fi

# The command that resumes: shell-quoted, and carrying the two homes when they were set for this run.
resume="bash $(printf '%q' "$here/scripts/bootstrap.sh")"
[ -z "${CODEX_HOME:-}" ] || resume="CODEX_HOME=$(printf '%q' "$CODEX_HOME") $resume"
[ -z "${CLAUDE_CONFIG_DIR:-}" ] || resume="CLAUDE_CONFIG_DIR=$(printf '%q' "$CLAUDE_CONFIG_DIR") $resume"
claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
codex_home="${CODEX_HOME:-$HOME/.codex}"

say() { printf '%s\n' "$*"; }
ok() { printf 'ok    %s\n' "$*"; }
did() { printf 'done  %s\n' "$*"; }
fail() { printf 'bootstrap: %s\n' "$*" >&2; exit 1; }

# stop <title> <what> <where> <how to know it worked>: a step only a person can do.
stop() {
  say ""
  say "STOP  a person has to do this step: $1"
  say "      what:   $2"
  say "      where:  $3"
  say "      worked: $4"
  say "      resume: $resume"
  exit 3
}

# run_quiet <label> <command...>: run a step script; sets $out to what it printed, and shows all of
# it on failure.
run_quiet() {
  local label=$1 rc
  shift
  out=$("$@" 2>&1 </dev/null); rc=$?
  if [ "$rc" != 0 ]; then
    printf '%s\n' "$out" >&2
    fail "$label failed (exit $rc); fix what it reports, then run $resume again"
  fi
}

# show_warnings: the warning lines of the last step, which its summary line would hide.
show_warnings() { printf '%s\n' "$out" | grep -i 'warn' | sed 's/^/      /' || true; }

say "bootstrap: staged setup of this machine (stage 3, the agent identity, is optional and not done here)"

# ---- the checkout ----------------------------------------------------------------------------
# The bridge and the guard scripts locate everything through ~/.Jarvis, so a checkout anywhere else
# would be linked half-way. Cloning is the person's first command (step 2 of the guide).
want=$(cd "$HOME/.Jarvis" 2>/dev/null && pwd -P) || want=""
[ "$want" = "$here" ] || fail "this checkout is $here, but the setup needs it at $HOME/.Jarvis (resolved: ${want:-absent}); clone Jarvis there (step 2 of docs/setup-new-machine.md) and run its scripts/bootstrap.sh"

# ---- stage 1: instructions and Skills --------------------------------------------------------
say ""
say "== stage 1: instructions and Skills"

# Claude Code is a program only a person can install; the script never installs one.
[ -d "$claude_home" ] ||
  stop "install Claude Code and start it once" \
    "install Claude Code, then start it once so that it creates $claude_home" \
    "your own terminal; this script installs no program" \
    "$claude_home exists"
ok "Claude Code home exists ($claude_home)"

# An existing ~/.claude/CLAUDE.md is the bridge's CONFLICT: a real file, or a live link that does not
# lead to the Jarvis rules (the rule of link_rules in sync-personal-skills.sh, which is the reference).
# It is found before anything is written, so the stop changes nothing.
rules="$HOME/.Jarvis/.agents/AGENTS.md"
claude_md="$HOME/.claude/CLAUDE.md"
leads_to_rules() {
  local dest
  dest=$(cd -P "$(dirname "$1")" 2>/dev/null && cd -P "$(dirname "$(readlink "$1")")" 2>/dev/null && pwd -P) || return 1
  [ "$dest/$(basename "$(readlink "$1")")" = "$(cd -P "$(dirname "$rules")" && pwd -P)/AGENTS.md" ]
}
if [ -f "$rules" ]; then
  conflict=""
  if [ -L "$claude_md" ]; then
    if [ -e "$claude_md" ] && ! leads_to_rules "$claude_md"; then conflict="a link to $(readlink "$claude_md"), not to $rules"; fi
  elif [ -e "$claude_md" ]; then
    conflict="a real file"
  fi
  [ -z "$conflict" ] ||
    stop "decide what the existing $claude_md keeps" \
      "$claude_md is $conflict, so the bridge will not replace it. Move what it should keep into $rules, move $claude_md away, then resume. Nothing has been changed." \
      "your own terminal and editor" \
      "$claude_md is gone, and the resumed run links it to $rules"
fi

hp=$(git -C "$here" config --local --get core.hooksPath 2>/dev/null || true)
if [ "$hp" = .githooks ]; then
  ok "Git hooks are on (core.hooksPath = .githooks)"
elif [ -z "$hp" ]; then
  git -C "$here" config --local core.hooksPath .githooks || fail "could not set core.hooksPath"
  did "Git hooks turned on (core.hooksPath = .githooks)"
else
  say "note  core.hooksPath is '$hp', not .githooks; left as it is (see docs/git-hooks.md)"
fi

if bash "$here/sync-personal-skills.sh" --check >/dev/null 2>&1; then
  ok "Skills are bridged"
else
  run_quiet "Skills bridge" bash "$here/sync-personal-skills.sh"
  did "Skills bridge: $(printf '%s\n' "$out" | grep . | tail -1)"
fi
[ -d "$codex_home" ] || say "note  Codex is not set up ($codex_home absent): skipped. Install and start Codex, then run this again."

# ---- stage 2: the guard ----------------------------------------------------------------------
say ""
say "== stage 2: the guard"

# jq and python3 are system packages: this script does not install them.
missing="" worked=""
if ! command -v jq >/dev/null 2>&1; then
  missing="jq"; worked="command -v jq succeeds"
fi
if ! command -v python3 >/dev/null 2>&1; then
  missing="${missing:+$missing, }python3 (3.11 or newer)"; worked="${worked:+$worked, and }command -v python3 succeeds"
fi
if [ -d "$codex_home" ] && ! python3 -c 'import tomllib' >/dev/null 2>&1; then
  case "$missing" in
    *python3*) worked="${worked%command -v python3 succeeds}python3 -c 'import tomllib' succeeds" ;;
    *) missing="${missing:+$missing, }python3 3.11 or newer (Codex's trust is read with tomllib)"
       worked="${worked:+$worked, and }python3 -c 'import tomllib' succeeds" ;;
  esac
fi
[ -z "$missing" ] ||
  stop "install what the guard needs: $missing" \
    "install $missing with your system's package manager" \
    "your own terminal; this script installs no system package" \
    "$worked"

if bash "$here/scripts/apply-claude-guard.sh" --check >/dev/null 2>&1; then
  ok "Claude Code guard is installed"
else
  run_quiet "Claude Code guard" bash "$here/scripts/apply-claude-guard.sh"
  did "Claude Code guard: applied"
  show_warnings
  say "      it is active in the next Claude Code session"
fi

if [ -d "$codex_home" ]; then
  codex_guard="$here/scripts/apply-codex-guard.sh"
  if check_out=$(bash "$codex_guard" --check 2>&1 </dev/null); then
    ok "Codex guard is installed and Codex trusts it"
  else
    # Only the trust is open when the files already carry the guard: then there is nothing to apply.
    if ! printf '%s\n' "$check_out" | grep -q 'already carry the guard'; then
      run_quiet "Codex guard" bash "$codex_guard"
      did "Codex guard: applied"
      show_warnings
    fi
    if trust_out=$(bash "$codex_guard" --trust 2>&1 </dev/null); then
      ok "Codex trusts the guard"
    else
      state=$(printf '%s\n' "$trust_out" | sed -n 's/^apply-codex-guard: trust: \([A-Z-]*\) - .*/\1/p' | head -1)
      reason=$(printf '%s\n' "$trust_out" | sed -n 's/^apply-codex-guard: trust: [A-Z-]* - //p' | head -1)
      fix=$(printf '%s\n' "$trust_out" | sed -n 's/^apply-codex-guard: fix: //p' | head -1)
      [ -n "$state" ] || fail "could not read Codex's trust state from $codex_guard --trust; run it by hand: $trust_out"
      worked="bash $(printf '%q' "$codex_guard") --trust prints 'trust: OK - Codex trusts the Jarvis guard entry'"
      case "$state" in
        UNTRUSTED|NOT-INSTALLED)
          stop "trust the guard in Codex" \
            "$fix ($reason; trust is by hash: do it again after any change to the hook)" \
            "inside Codex; this script only reads the trust, it never writes it" \
            "$worked" ;;
        *)
          stop "make the Jarvis guard runnable in Codex ($state)" \
            "$fix ($reason)" \
            "your own terminal and Codex's config under $codex_home; this script never writes the trust or the switches" \
            "$worked" ;;
      esac
    fi
  fi
fi

# ---- done ------------------------------------------------------------------------------------
say ""
say "bootstrap: stages 1 and 2 are done."
say "Optional, and only a person can do them: /auto-mode-setup in Claude Code (step 4 of the guide), and"
say "stage 3, the agent identity (steps 5 and 6): skip it unless you want agents to have a GitHub account of their own."
say "Next: $resume --check   (read-only: the same report as scripts/doctor.sh)"
exit 0
