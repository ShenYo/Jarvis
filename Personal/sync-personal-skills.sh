#!/bin/bash
# Rebuild the symlink bridges that let AI tools discover the skills in
# Personal/agents/skills/. Idempotent — run it any time, especially after
# adding or removing a skill.
#
# Layout:
#   ~/Jarvis/Personal/agents/skills/<name>/   canonical content (this repo)
#   ~/.agents                              -> Jarvis/Personal/agents
#   ~/.claude/skills/<name>                -> ../../.agents/skills/<name>
#
# Why a script: the bridge was previously hand-made, and by 2026-09-07 ten of
# the thirty skills had no symlink at all, so Claude Code could not see them.
# Nothing detected that. A rebuild that can be re-run makes the drift fixable
# and the check below makes it visible.
set -euo pipefail

CANONICAL="$HOME/Jarvis/Personal/agents/skills"
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

# ~/.agents is the path every existing symlink resolves through, so it has to
# point here before anything else will work.
if [ ! -e "$HOME/.agents" ]; then
  ln -s Jarvis/Personal/agents "$HOME/.agents"
  echo "created  ~/.agents -> Jarvis/Personal/agents"
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
