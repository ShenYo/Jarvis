# Jarvis

Machine-level (not per-project) AI agent configuration. Everything here applies
to every project on a machine, which is exactly why it needs version control:
until 2026-09-07 these skills lived only in `~/.agents/` with no history, no
backup, and no way to tell what had changed.

## Current inventory and layers

The current checkout has 34 canonical `SKILL.md` files, 34 Claude bridge links,
34 Codex bridge links, and 33 lock entries. `setup-project-agents` is the one
canonical skill without a lock entry. Recount rather than treating this prose
as a cache:

```sh
find ~/.Jarvis/agents/skills -mindepth 1 -maxdepth 2 -name SKILL.md -type f | wc -l
find ~/.claude/skills -maxdepth 1 -type l | wc -l
find ~/.codex/skills -maxdepth 1 -type l | wc -l
jq '.skills | length' ~/.Jarvis/agents/.skill-lock.json
comm -23 \
  <(find ~/.Jarvis/agents/skills -mindepth 1 -maxdepth 2 -name SKILL.md -type f \
    -exec sed -n 's/^name:[[:space:]]*//p' {} \; | sort) \
  <(jq -r '.skills | keys[]' ~/.Jarvis/agents/.skill-lock.json | sort)
```

The layers have different owners and update paths:

- **Jarvis** is the personal canonical content at `~/.Jarvis/agents`, reached
  through the stable `~/.agents` symlink.
- **Friday** is a shared, blank-repository baseline; it supplies a reviewed
  payload, not this machine's personal skill catalog.
- A **consumer** owns its project `.agents/` seeds, overlays, and optional
  integration extension. It must remain reproducible without `~/.Jarvis`.

## Layout

```
agents/
  skills/<name>/SKILL.md     canonical skill content
  .skill-lock.json           what the skills CLI installed, and from where
sync-personal-skills.sh      rebuilds the symlink bridges; idempotent
```

`agents/` is the real content. Everything outside this repo is a symlink into
it, so there is exactly one copy of every skill.

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
~/.codex/skills/<name>    -> ../../.agents/skills/<name>
```

Two hops, and the second one matters: `~/.claude/skills/<name>` resolves
`../../` to `~/`, so it goes through `~/.agents` rather than pointing at this
repo directly. That is deliberate — `~/.agents` is the stable address, so this
repo can be cloned anywhere as long as that one symlink points at it.

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

The script creates `~/.agents` if it is missing, links every skill into
`~/.claude/skills/` and, when Codex is installed, `~/.codex/skills/` — then
verifies its own work: every skill has a live link in every bridged tool, no
link dangles, every skill has a `SKILL.md`. It exits non-zero if any check
fails. Re-run it after adding or removing a skill.

A tool that is not installed is skipped rather than treated as an error, so the
same script works on a machine with only one of them.

## Project baseline adoption

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

## Why the script exists

The bridge used to be hand-made. By 2026-09-07, ten of the thirty skills then
installed had no
symlink at all — `find-skills`, `grill-me`, `grill-with-docs`, `handoff`,
`improve-codebase-architecture`, `prototype`, `setup-matt-pocock-skills`,
`tdd`, `teach`, `triage`. They were installed, they were on disk, and Claude
Code could not see any of them. Nothing reported a problem.

That is the failure mode to design against: a bridge that silently half-exists.
Hence a rebuild that is safe to re-run, plus checks that fail loudly rather
than a script that prints "done".

## Bridge status

`sync-personal-skills.sh` creates and verifies the 34 current symlink entries
for Claude Code and Codex. This proves bridge topology and non-dangling links,
not Git-operation enforcement or each runtime's skill-loader behavior.

Claude Code receives links in `~/.claude/skills/`. Codex receives links in
`$CODEX_HOME/skills` (normally `~/.codex/skills/`); `.system` and
`codex-primary-runtime` remain tool-owned and the script skips them. Codex's
installer documentation and a Python listing tool support the destination and
symlink convention, but the compiled Codex runtime loader remains unverified.

Gemini has no bridge created by this script. Its discovery and runtime behavior
are pending/unknown here; this README makes no Gemini enforcement claim.

## Two CLI behaviours to know

**`add -y` fans out to every agent the CLI knows.** There are 55 of them,
`.adal` through `.zencoder`, and `-y` accepts them all — which creates about 50
directories in `$HOME`, only three of which correspond to anything installed
here. Let it prompt, or pass `-a`, so it targets the agents in the lock's
`lastSelectedAgents`. `update -g` does **not** do this: verified against a
scratch HOME on 2026-09-07, it created nothing but `.npm` and left the existing
symlinks intact.

**A blanket update silently drops skills upstream has deleted.** On 2026-09-07
this set was 29 skills from `mattpocock/skills`, and 13 of them were no longer
in that repo — upstream had pruned them since the 2026-06-16 install, four
having already been under `skills/deprecated/` at the time. An update would
have removed them with no warning.

Those 13 were removed deliberately instead, by owner decision the same day:
`caveman`, `design-an-interface`, `diagnose`, `edit-article`, `obsidian-vault`,
`qa`, `request-refactor-plan`, `review`, `to-issues`, `to-prd`,
`ubiquitous-language`, `write-a-skill`, `zoom-out`. They are recoverable from
this repo's history at `3b78d38` — which is the reason to version-control
before pruning, not after.

The remaining 16 were recorded as identical to then-current upstream in that
2026-09-07 audit; this is historical evidence, not the current inventory.
Update named skills (`npx skills update -g <name>`) only after checking each
still exists upstream, rather than updating the lot.

For the record, two things are **not** wrong with this setup, contrary to first
impressions: `agents/.skill-lock.json` is the current CLI's global-scope
filename (`skills-lock.json` is the *project*-scope name, which is why
pet_care's differs), and the missing `agents/openai.yaml` descriptors are
upstream files added after 2026-06-16 rather than something a reinstall must
generate. Neither is a reason to re-run the installer, and neither affects
Codex, which is not one of the CLI's 55 targets.

## Not in this repo

- Project-level `.agents/` — see the note at the top; it stays in its project.
- `~/.claude/skills/*` and `~/.codex/skills/*` — generated symlinks, rebuilt
  by the script.
- `~/.claude/settings.json`, `~/.codex/config.toml` — machine settings that may
  contain tokens or paths; deliberately left out for now, worth revisiting.
- `~/.claude/skills-backup-2026-08-04/` — a manual backup from before this
  repo existed, deleted on 2026-09-07 after all nine of its skills were
  verified byte-identical to the tracked copies. Git is the backup now.
