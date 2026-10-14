# Jarvis

> **繁中摘要**：Jarvis 是這台機器的個人 AI agent Skills 版本庫。它讓
> `~/.Jarvis/agents` 成為唯一 canonical copy，透過 `~/.agents` 與 Claude
> Code／Codex 的 symlink 共用；它也提供 Friday 基線的安全採用 wrapper。專案
> 本身必須不依賴 Jarvis 仍可重現。

Jarvis is the version-controlled, machine-level home for one canonical copy of
personal AI-agent Skills.

## What it solves

Jarvis addresses four related scenarios:

- **Personal Skills versioning:** machine-wide Skills have history, review,
  and recovery rather than living only in an untracked home-directory folder.
- **New-machine bootstrap:** one clone and one bridge command restore the
  canonical layout for supported local tools.
- **Claude/Codex bridge checks:** the script ensures the Claude bridge
  directory exists and creates or replaces missing or dangling canonical-name
  links; other dangling non-reserved bridge entries fail visibly.
- **Friday adoption:** a local wrapper previews and, with fresh explicit
  authorization, adopts a pinned Friday baseline into a blank project.

## Scope and ownership

| Layer | Owns | Does not own |
| --- | --- | --- |
| **Jarvis** | This machine's canonical personal Skills, bridge script, and personal Skill provenance | A project's `.agents/`, project policy, or personal settings |
| **Friday** | A reviewed shared baseline that a consumer may pin and adopt | This machine's personal catalog or a consumer's conflict resolution |
| **Consumer project** | Its `.agents/` seed, overlays, integrations, tests, and recorded Friday provenance | Jarvis's personal Skills or Friday's vendor payload |

A project must remain reproducible without `~/.Jarvis`. Jarvis can help an
agent work on a project, but it must not become a hidden project dependency.

## Current inventory

**Inventory observation, 2026-10-13:** this checkout has 34 canonical
`SKILL.md` files, 34 Claude bridge links, 34 Codex bridge links, and 33 lock
entries. `setup-project-agents` is the canonical Skill without a lock entry.
These are observations, not enduring facts; recount rather than treating this
README as a cache:

```sh
find ~/.Jarvis/agents/skills -mindepth 1 -maxdepth 2 -name SKILL.md -type f | wc -l
find ~/.claude/skills -maxdepth 1 -type l | wc -l
find "${CODEX_HOME:-$HOME/.codex}/skills" -maxdepth 1 -type l | wc -l
jq '.skills | length' ~/.Jarvis/agents/.skill-lock.json
comm -23 \
  <(find ~/.Jarvis/agents/skills -mindepth 1 -maxdepth 2 -name SKILL.md -type f \
    -exec sed -n 's/^name:[[:space:]]*//p' {} \; | sort) \
  <(jq -r '.skills | keys[]' ~/.Jarvis/agents/.skill-lock.json | sort)
```

## Architecture and layout

```
agents/
  skills/<name>/SKILL.md     canonical skill content
  .skill-lock.json           what the skills CLI installed, and from where
sync-personal-skills.sh      ensures the Claude bridge directory and
                             missing/dangling canonical-name links; idempotent
```

`agents/` is the real content. Everything outside this repo is a symlink into
it, so there is exactly one copy of every skill.

`~/.agents` **must be a symlink to `~/.Jarvis/agents`**. It is the stable
address through which the Claude and Codex bridge links resolve.

A skill is a directory containing `SKILL.md` — not merely a directory. Skills
may be grouped one level deep under a container that has no `SKILL.md` of its
own; the container is not linked, the skills inside it are. The link name comes
from each skill's `name:` frontmatter, which is what the tools match on, so
`agents/skills/git/commit/` with `name: git-commit` links as
`~/.claude/skills/git-commit`. Nothing here is nested today; the support exists
because pet_care groups its four git skills that way, and a script that assumed
one directory per skill both linked the unloadable container and hid the real
skills inside.

## The symlink chain

```
~/.agents                 -> .Jarvis/agents
~/.claude/skills/<name>   -> ../../.agents/skills/<name>
${CODEX_HOME:-$HOME/.codex}/skills/<name>
                           -> ../../.agents/skills/<name>
```

Two hops, and the second one matters: `~/.claude/skills/<name>` resolves
`../../` to `~/`, so it goes through `~/.agents` rather than pointing at this
repo directly. That is deliberate — `~/.agents` is the stable address, while
the bridge script requires this repository to be cloned at `~/.Jarvis`.

## There is nothing to sync

`~/.agents` is a symlink, not a copy. `~/.agents/skills/foo/SKILL.md` and
`~/.Jarvis/agents/skills/foo/SKILL.md` are the same inode — one file with two
names. Editing through either path edits the same bytes, and `git status` in
this repo sees it immediately. The two cannot drift, because there is only one
of them.

This is why the repo is cloned at `~/.Jarvis` with `~/.agents` pointing into it,
rather than keeping a same-shaped copy in both places. Two real directories
would need syncing and would drift; one directory with two names cannot.

The single way this breaks is if something **replaces** the `~/.agents` symlink
with a real directory — then two copies do exist, edits land in whichever one
the tool opened, and nothing announces it. `sync-personal-skills.sh` refuses to
run in that case and tells you to diff the two before choosing, rather than
quietly linking on top of the wrong one.

## Setting up a new machine

```sh
git clone git@github.com:ShenYo/Jarvis.git ~/.Jarvis
~/.Jarvis/sync-personal-skills.sh
```

The script creates `~/.agents` if it is missing, ensures the Claude bridge
directory exists, and creates or replaces a canonical-name entry only when it
is missing or dangling. It bridges Codex only when
`${CODEX_HOME:-$HOME/.codex}/skills` already exists; an absent Codex directory
is skipped rather than treated as an error. It checks that each canonical skill
has an existing entry under its declared name in every bridged tool, reports
dangling non-reserved entries, and rejects a top-level canonical directory that
is neither a Skill nor a grouping directory. A live canonical-name entry that
points at the wrong target is left unchanged and is not detected. It exits
non-zero if these checks fail. Re-run it after adding or removing a skill.

## Daily maintenance

### Add

Add a directory containing `SKILL.md` under `agents/skills/` (or one level
below a grouping directory). Give it a unique `name:` frontmatter field when
the bridge name should differ from the directory name, then run the bridge
script and review:

```sh
~/.Jarvis/sync-personal-skills.sh
git -C ~/.Jarvis diff --check
git -C ~/.Jarvis status --short
```

### Update

For locally maintained content, edit the tracked files, review the diff, and
run the bridge script. For a CLI-managed Skill, inspect
`agents/.skill-lock.json` for its source and verify that the named upstream
Skill still exists before using its owning CLI to update that named Skill.

Do not use a blanket `npx skills update -g` as routine maintenance. Upstream
can delete Skills, and a broad update can silently remove local installations.
Named, reviewed updates preserve the decision about what leaves this repository.

### Remove

Remove a canonical Skill through a reviewed Git change. Then inspect for its
now-dangling bridge links, remove only those exact links, and rerun the bridge
script. The script reports dangling non-reserved entries, but replaces a
dangling entry at a canonical skill name; it does not guess which live-looking
tool entries are safe to delete.

```sh
find ~/.claude/skills -maxdepth 1 -type l ! -exec test -e {} \; -print
CODEX_SKILLS="${CODEX_HOME:-$HOME/.codex}/skills"
[ ! -d "$CODEX_SKILLS" ] || find "$CODEX_SKILLS" -maxdepth 1 -type l ! -exec test -e {} \; -print
```

### Verify

Running `~/.Jarvis/sync-personal-skills.sh` is the normal bridge check. For a
read-only inspection, use:

```sh
test -L ~/.agents && test "$(cd -P ~/.agents && pwd)" = "$(cd -P ~/.Jarvis/agents && pwd)"
find ~/.Jarvis/agents/skills -mindepth 1 -maxdepth 2 -type f -name SKILL.md | sort
find ~/.claude/skills -maxdepth 1 -type l -print | sort
CODEX_SKILLS="${CODEX_HOME:-$HOME/.codex}/skills"
[ ! -d "$CODEX_SKILLS" ] || find "$CODEX_SKILLS" -maxdepth 1 -type l -print | sort
```

### Recover a `~/.agents` conflict

Stop if the script says `~/.agents` is a real directory or resolves elsewhere.
Compare it with the canonical directory first and decide which copy is current:

```sh
diff -ru ~/.agents ~/.Jarvis/agents
```

After that comparison, preserve the conflicting directory under a dated backup
name, recreate the required symlink, and rerun the bridge script. Replacing it
without a backup can discard uncommitted Skills.

```sh
mv ~/.agents "$HOME/.agents.conflict-$(date +%Y%m%d-%H%M%S)"
ln -s .Jarvis/agents ~/.agents
~/.Jarvis/sync-personal-skills.sh
```

## Friday adoption wrapper

`setup-matt-pocock-skills` is third-party/CLI-managed. **Do not modify it for
project setup.** Use the locally maintained `setup-project-agents` wrapper
instead. It is deliberately narrow: it adopts Friday's shared baseline, not
personal Skills, consumer overlays, or conflicts.

Use `$setup-project-agents` only to preview and adopt a pinned Friday baseline
in a blank Git repository:

```text
$setup-project-agents target=/absolute/path/to/repository friday=/absolute/path/to/Friday
```

Both paths are required. The skill canonicalizes them, requires `target` to be
a Git repository root and `friday` to be a different clean Git worktree with
regular `install.sh` and `payload` paths, then records Friday's full SHA and
the target Git state. Its only pre-authorization action is:

```sh
bash "$friday/install.sh" --check "$target"
```

Record the reviewed Friday SHA as the pin. Any conflict or failed preview stops
the workflow for reconciliation in the consumer; neither this wrapper nor
Friday is an update engine. Installation needs a fresh explicit authorization
that names both the canonical target and that exact pinned SHA. Only then does
the skill run Friday's installer, preview again, run the consumer checker, and
report the target status and diff check.

Do not manually copy baseline files, modify Friday or its vendor payload, or
change a lock file for this workflow. The skill creates no commit or push; the
consumer records the pinned provenance and any atomic adoption commit under
its own reviewed convention.

## CLI-managed and locally maintained content

`agents/.skill-lock.json` records Skills installed by the Skills CLI, including
their source, path, hash, and timestamps. Treat those as third-party/
CLI-managed: do not casually patch their contents or rewrite the lock to make
an installation look different. A missing lock entry means the CLI did not
record that Skill; it does not make a canonical Skill invalid.

Jarvis's bridge script, this README, and `setup-project-agents` are locally
maintained. Personal settings are intentionally excluded:
`~/.claude/settings.json` and `~/.codex/config.toml` may contain local paths
or secrets and are not part of this repository.

## Historical context

The bridge was hand-maintained before 2026-09-07, and installed Skills could be
present on disk yet invisible to Claude Code. That incident is why the bridge
is safely repeatable and checks canonical-name presence and dangling entries
rather than merely printing success.

## Bridge status and limitations

`sync-personal-skills.sh` ensures canonical names have existing entries in each
bridged tool and reports dangling non-reserved entries. It does not validate or
repair a live canonical-name entry that points at the wrong target, nor does it
prove Git-operation enforcement or each runtime's native skill-loader behavior.

Claude Code receives links in `~/.claude/skills/`. Codex receives links in
`${CODEX_HOME:-$HOME/.codex}/skills`; `.system` and `codex-primary-runtime`
remain tool-owned and the script skips them. Codex's installer documentation
and a Python listing tool support the destination and symlink convention, but
the compiled Codex runtime loader remains unverified.

Jarvis makes no claim about Claude's or Codex's runtime precedence between
personal, project, and built-in Skills. A live link is filesystem evidence, not
proof that a particular prompt will load a particular Skill.

Gemini has no bridge created by this script. Its discovery and runtime behavior
are pending/unknown here; this README makes no Gemini enforcement claim.

## Two CLI behaviours to know

Avoid `npx skills add -y`: its non-interactive fan-out can create unrelated
agent directories in `$HOME`. Let it prompt or select only the intended agents.

Avoid a blanket `npx skills update -g`: a 2026-09-07 audit found that upstream
had removed Skills that were still locally installed. Use
`npx skills update -g <name>` only after checking that specific upstream Skill,
then review the diff. The existing global lock filename is
`agents/.skill-lock.json`; `skills-lock.json` is project scope. Missing
`agents/openai.yaml` descriptors are not, by themselves, a reason to reinstall.

## Troubleshooting

```sh
# Confirm the required canonical symlink and its resolved destination.
ls -ld ~/.agents ~/.Jarvis/agents
readlink ~/.agents

# Ensure bridge directories and missing/dangling canonical-name links; report
# dangling non-reserved entries.
~/.Jarvis/sync-personal-skills.sh

# Show dangling bridge links without changing them.
find ~/.claude/skills -maxdepth 1 -type l ! -exec test -e {} \; -print
CODEX_SKILLS="${CODEX_HOME:-$HOME/.codex}/skills"
[ ! -d "$CODEX_SKILLS" ] || find "$CODEX_SKILLS" -maxdepth 1 -type l ! -exec test -e {} \; -print

# Show canonical names that determine bridge entry names.
find ~/.Jarvis/agents/skills -mindepth 1 -maxdepth 2 -name SKILL.md -type f \
  -exec sed -n 's/^name:[[:space:]]*//p' {} \; | sort

# Inspect CLI provenance when jq is available.
jq -r '.skills | to_entries[] | "\(.key)\t\(.value.source)\t\(.value.skillPath)"' \
  ~/.Jarvis/agents/.skill-lock.json | sort
```

Do not solve a bridge failure by making a second real copy of `~/.agents`,
copying every Skill manually into a tool directory, or changing a project to
depend on Jarvis. Repair the one canonical copy and rerun the script.

## Not in this repo

- Project-level `.agents/` — see the note at the top; it stays in its project.
- `~/.claude/skills/*` and the configured Codex skills directory (by default
  `~/.codex/skills/*`) — generated bridge entries; the script creates or
  replaces canonical-name entries only when they are missing or dangling.
- `~/.claude/settings.json`, `~/.codex/config.toml` — machine settings that may
  contain tokens or paths; deliberately left out for now, worth revisiting.
- `~/.claude/skills-backup-2026-08-04/` — a manual backup from before this
  repo existed, deleted on 2026-09-07 after all nine of its skills were
  verified byte-identical to the tracked copies. Git is the backup now.
