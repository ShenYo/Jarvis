#!/bin/bash
# Rebuild the symlink bridges that let AI tools discover the skills in
# agents/skills/. Idempotent — run it any time, especially after adding or
# removing a skill.
#
# Layout:
#   ~/Jarvis/agents/skills/<name>/  canonical content (this repo)
#   ~/.agents                    -> Jarvis/agents
#   ~/.claude/skills/<name>      -> ../../.agents/skills/<name>
#   ~/.codex/skills/<name>       -> ../../.agents/skills/<name>
#
# Why a script: the bridge was previously hand-made, and by 2026-09-07 ten of
# the thirty skills had no symlink at all, so Claude Code could not see them.
# Nothing detected that. A rebuild that can be re-run makes the drift fixable,
# and the checks below make it visible.
set -euo pipefail

CANONICAL="$HOME/Jarvis/agents/skills"

if [ ! -d "$CANONICAL" ]; then
  echo "error: $CANONICAL not found — is this repo cloned at ~/Jarvis?" >&2
  exit 1
fi

# ~/.agents is the path every other symlink resolves through, and it has to stay
# a symlink into this repo. There is normally no syncing to do — ~/.agents and
# Jarvis/agents are the same bytes, same inode, so they cannot drift. The one
# way this layout breaks is if something replaces that symlink with a real
# directory: then two copies of every skill exist, edits land in whichever one
# the tool happened to open, and nothing says so. Check for it loudly.
AGENTS_LINK="$HOME/.agents"
CANONICAL_PARENT=$(cd "$CANONICAL/.." && pwd -P)

if [ -L "$AGENTS_LINK" ]; then
  resolved=$(cd -P "$AGENTS_LINK" 2>/dev/null && pwd -P) || resolved=""
  if [ "$resolved" != "$CANONICAL_PARENT" ]; then
    echo "error: ~/.agents resolves to ${resolved:-a missing target}," >&2
    echo "       but this repo's content is at $CANONICAL_PARENT." >&2
    echo "       Point it here, or clone this repo where it already points." >&2
    exit 1
  fi
elif [ -d "$AGENTS_LINK" ]; then
  echo "error: ~/.agents is a real directory, not a symlink into this repo." >&2
  echo "       A second copy of the skills exists and the two will drift." >&2
  echo "       Diff it against $CANONICAL_PARENT, keep whichever is current," >&2
  echo "       then replace ~/.agents with the symlink." >&2
  exit 1
elif [ -e "$AGENTS_LINK" ]; then
  echo "error: ~/.agents exists but is neither a symlink nor a directory." >&2
  exit 1
else
  ln -s Jarvis/agents "$AGENTS_LINK"
  echo "created  ~/.agents -> Jarvis/agents"
fi

fail=0

# bridge <target dir> <label> [names to leave alone...]
#
# Reserved names are directories the tool owns. They are skipped when linking
# and exempt from the dangling check, so this script never reports on or
# touches something another tool installed.
bridge() {
  local target="$1" label="$2"
  shift 2
  local reserved=" $* "

  mkdir -p "$target"

  local created=0 name link
  for dir in "$CANONICAL"/*/; do
    name=$(basename "$dir")
    link="$target/$name"
    # -e is false for a dangling symlink, so a broken link is replaced too.
    if [ ! -e "$link" ]; then
      ln -sfn "../../.agents/skills/$name" "$link"
      echo "linked   $label: $name"
      created=$((created + 1))
    fi
  done

  local total
  total=$(find "$target" -maxdepth 1 -mindepth 1 | wc -l | tr -d ' ')
  echo "$label: $created new link(s); $total entries"

  # Every canonical skill must be reachable.
  while IFS= read -r name; do
    if [ ! -e "$target/$name" ]; then
      echo "MISSING  $label: $name has no link in $target" >&2
      fail=1
    fi
  done < <(find "$CANONICAL" -maxdepth 1 -mindepth 1 -type d -exec basename {} \;)

  # No link may dangle, including ones this script did not create.
  for link in "$target"/*; do
    [ -e "$link" ] && continue
    name=$(basename "$link")
    case "$reserved" in *" $name "*) continue ;; esac
    echo "DANGLING $label: $name -> $(readlink "$link")" >&2
    fail=1
  done
}

bridge "$HOME/.claude/skills" "Claude Code"

# Codex reads user skills from $CODEX_HOME/skills. Its own skill-installer says
# so ("Install Codex skills into $CODEX_HOME/skills"), and its list-skills.py
# counts a directory as installed with os.path.isdir, which follows symlinks —
# so the same bridge applies. Its built-ins live in .system (marked by
# .codex-system-skills.marker) and codex-primary-runtime; leave both alone.
#
# Only bridged when Codex is actually installed, so this stays a no-op on a
# machine that does not have it.
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}/skills"
if [ -d "$CODEX_DIR" ]; then
  echo ""
  bridge "$CODEX_DIR" "Codex" ".system" "codex-primary-runtime"
else
  echo ""
  echo "Codex: not installed ($CODEX_DIR absent) — skipped."
fi

# A skill without SKILL.md is invisible to every tool, linked or not.
echo ""
while IFS= read -r dir; do
  [ -f "$dir/SKILL.md" ] || { echo "NO SKILL.md  $(basename "$dir")" >&2; fail=1; }
done < <(find "$CANONICAL" -maxdepth 1 -mindepth 1 -type d)

if [ "$fail" -ne 0 ]; then
  echo "checks FAILED — see above." >&2
  exit 1
fi

echo "checks passed: every skill is linked into every installed tool, no link dangles, every skill has SKILL.md."
