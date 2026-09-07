#!/bin/bash
# Rebuild the symlink bridges that let AI tools discover the skills in
# agents/skills/. Idempotent — run it any time, especially after
# adding or removing a skill.
#
# Layout:
#   ~/Jarvis/agents/skills/<name>/   canonical content (this repo)
#   ~/.agents                     -> Jarvis/agents
#   ~/.claude/skills/<name>                -> ../../.agents/skills/<name>
#
# Why a script: the bridge was previously hand-made, and by 2026-09-07 ten of
# the thirty skills had no symlink at all, so Claude Code could not see them.
# Nothing detected that. A rebuild that can be re-run makes the drift fixable
# and the check below makes it visible.
set -euo pipefail

CANONICAL="$HOME/Jarvis/agents/skills"
CLAUDE_DIR="$HOME/.claude/skills"

# Codex also reads <name>/SKILL.md, from ~/.codex/skills/. It is NOT bridged
# here: ~/.codex/skills/.system carries a .codex-system-skills.marker and ships
# with a skill-installer, so that directory looks owned by Codex itself. Verify
# that Codex loads hand-placed user skills before adding a bridge — see the
# README.
CODEX_DIR="$HOME/.codex/skills"

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

mkdir -p "$CLAUDE_DIR"

created=0
for dir in "$CANONICAL"/*/; do
  name=$(basename "$dir")
  link="$CLAUDE_DIR/$name"
  # -e is false for a dangling symlink, so a broken link gets replaced too.
  if [ ! -e "$link" ]; then
    ln -sfn "../../.agents/skills/$name" "$link"
    echo "linked   $name"
    created=$((created + 1))
  fi
done

echo ""
echo "Claude Code: $created new link(s); $(find "$CLAUDE_DIR" -maxdepth 1 -mindepth 1 | wc -l | tr -d ' ') total"

# --- Check, don't just report success ---

fail=0

# Every canonical skill must be reachable.
while IFS= read -r name; do
  if [ ! -e "$CLAUDE_DIR/$name" ]; then
    echo "MISSING  $name has no link in $CLAUDE_DIR" >&2
    fail=1
  fi
done < <(find "$CANONICAL" -maxdepth 1 -mindepth 1 -type d -exec basename {} \;)

# No link may dangle, including ones this script did not create.
for link in "$CLAUDE_DIR"/*; do
  [ -e "$link" ] && continue
  echo "DANGLING $(basename "$link") -> $(readlink "$link")" >&2
  fail=1
done

# A skill without SKILL.md is invisible to the tools even when linked.
while IFS= read -r dir; do
  [ -f "$dir/SKILL.md" ] || { echo "NO SKILL.md  $(basename "$dir")" >&2; fail=1; }
done < <(find "$CANONICAL" -maxdepth 1 -mindepth 1 -type d)

if [ -d "$CODEX_DIR" ]; then
  echo "note: $CODEX_DIR exists but is not bridged — see README before changing that."
fi

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "checks FAILED — see above." >&2
  exit 1
fi

echo "checks passed: every skill has a live link, every link resolves, every skill has SKILL.md."
