#!/bin/bash
# Rebuild the symlink bridges that let AI tools discover the skills in
# agents/skills/. Idempotent — run it any time, especially after adding or
# removing a skill.
#
# Layout:
#   ~/.Jarvis/agents/skills/<name>/  canonical content (this repo)
#   ~/.agents                     -> .Jarvis/agents
#   ~/.claude/skills/<name>      -> ../../.agents/skills/<name>
#   ~/.codex/skills/<name>       -> ../../.agents/skills/<name>
#
# Skills may also be grouped one level deep — .agents/skills/git/commit/ links
# as ~/.claude/skills/git-commit, from that skill's own `name:` field.
#
# Why a script: the bridge was previously hand-made, and by 2026-09-07 ten of
# the thirty skills had no symlink at all, so Claude Code could not see them.
# Nothing detected that. A rebuild that can be re-run makes the drift fixable,
# and the checks below make it visible.
set -euo pipefail

CANONICAL="$HOME/.Jarvis/agents/skills"

if [ ! -d "$CANONICAL" ]; then
  echo "error: $CANONICAL not found — is this repo cloned at ~/.Jarvis?" >&2
  exit 1
fi

# ~/.agents is the path every other symlink resolves through, and it has to stay
# a symlink into this repo. There is normally no syncing to do — ~/.agents and
# .Jarvis/agents are the same bytes, same inode, so they cannot drift. The one
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
  ln -s .Jarvis/agents "$AGENTS_LINK"
  echo "created  ~/.agents -> .Jarvis/agents"
fi

fail=0

# What counts as a skill: a directory containing SKILL.md — not merely a
# directory. Some skills are grouped under a container that holds no SKILL.md
# of its own (pet_care keeps four under .agents/skills/git/), and treating
# every directory as a skill both links the container, which no tool can load,
# and hides the real skills inside it. Depth 2 covers one level of grouping.
#
# The link name comes from the skill's own `name:` frontmatter, because that is
# what the tools match on; git/commit declares `name: git-commit`. Falling back
# to the directory name keeps a skill that omits the field working.
#
# Emits "<relative path>\t<link name>" per skill.
skills() {
  local dir rel name
  while IFS= read -r dir; do
    rel=${dir#"$CANONICAL"/}
    name=$(sed -n 's/^name:[[:space:]]*//p' "$dir/SKILL.md" | head -1 | tr -d '\r')
    [ -n "$name" ] || name=$(basename "$dir")
    printf '%s\t%s\n' "$rel" "$name"
  done < <(find "$CANONICAL" -mindepth 1 -maxdepth 2 -type d \
             -exec test -f '{}/SKILL.md' \; -print | sort)
}

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

  local created=0 rel name link
  while IFS=$'\t' read -r rel name; do
    link="$target/$name"
    # -e is false for a dangling symlink, so a broken link is replaced too.
    if [ ! -e "$link" ]; then
      ln -sfn "../../.agents/skills/$rel" "$link"
      echo "linked   $label: $name"
      created=$((created + 1))
    fi
  done < <(skills)

  local total
  total=$(find "$target" -maxdepth 1 -mindepth 1 | wc -l | tr -d ' ')
  echo "$label: $created new link(s); $total entries"

  # Every canonical skill must be reachable.
  while IFS=$'\t' read -r rel name; do
    if [ ! -e "$target/$name" ]; then
      echo "MISSING  $label: $name ($rel) has no link in $target" >&2
      fail=1
    fi
  done < <(skills)

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

# A top-level directory that neither is a skill nor groups any is dead weight —
# most likely a skill whose SKILL.md is missing, which no tool would report.
echo ""
while IFS= read -r dir; do
  [ -f "$dir/SKILL.md" ] && continue
  if find "$dir" -mindepth 2 -maxdepth 2 -name SKILL.md | grep -q .; then
    echo "note: $(basename "$dir")/ groups skills and is correctly not linked itself."
    continue
  fi
  echo "NO SKILL.md  $(basename "$dir") is neither a skill nor a group" >&2
  fail=1
done < <(find "$CANONICAL" -maxdepth 1 -mindepth 1 -type d | sort)

if [ "$fail" -ne 0 ]; then
  echo "checks FAILED — see above." >&2
  exit 1
fi

echo "checks passed: every skill is linked into every installed tool under its declared name, no link dangles, and no directory is a skill with its SKILL.md missing."
