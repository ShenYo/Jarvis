# Jarvis

Machine-level (not per-project) AI agent configuration. Everything here applies
to every project on a machine, which is exactly why it needs version control:
until 2026-09-07 these 30 skills lived only in `~/.agents/` with no history, no
backup, and no way to tell what had changed.

Project-level agent configuration is deliberately **not** here. A project's
`.agents/` has to live inside the project repo: a clone must carry its own
rules, CI checks out only the project, and collaborators cannot be asked to
depend on one person's home directory. Anything portable enough to be shared
between projects belongs in a separate library repo that projects vendor a copy
from — not in this one.

## Layout

```
agents/
  skills/<name>/SKILL.md     canonical skill content
  .skill-lock.json           what the skills CLI installed, and from where
sync-personal-skills.sh      rebuilds the symlink bridges; idempotent
```

`agents/` is the real content. Everything outside this repo is a symlink into
it, so there is exactly one copy of every skill.

## The symlink chain

```
~/.agents                 -> Jarvis/agents
~/.claude/skills/<name>   -> ../../.agents/skills/<name>
~/.codex/skills/<name>    -> ../../.agents/skills/<name>
```

Two hops, and the second one matters: `~/.claude/skills/<name>` resolves
`../../` to `~/`, so it goes through `~/.agents` rather than pointing at this
repo directly. That is deliberate — `~/.agents` is the stable address, so this
repo can be cloned anywhere as long as that one symlink points at it.

## There is nothing to sync

`~/.agents` is a symlink, not a copy. `~/.agents/skills/foo/SKILL.md` and
`~/Jarvis/agents/skills/foo/SKILL.md` are the same inode — one file with two
names. Editing through either path edits the same bytes, and `git status` in
this repo sees it immediately. The two cannot drift, because there is only one
of them.

This is why the repo is cloned at `~/Jarvis` with `~/.agents` pointing into it,
rather than keeping a same-shaped copy in both places. Two real directories
would need syncing and would drift; one directory with two names cannot.

The single way this breaks is if something **replaces** the `~/.agents` symlink
with a real directory — then two copies do exist, edits land in whichever one
the tool opened, and nothing announces it. `sync-personal-skills.sh` refuses to
run in that case and tells you to diff the two before choosing, rather than
quietly linking on top of the wrong one.

## Setting up a new machine

```sh
git clone git@github.com:ShenYo/Jarvis.git ~/Jarvis
~/Jarvis/sync-personal-skills.sh
```

The script creates `~/.agents` if it is missing, links every skill into
`~/.claude/skills/` and, when Codex is installed, `~/.codex/skills/` — then
verifies its own work: every skill has a live link in every bridged tool, no
link dangles, every skill has a `SKILL.md`. It exits non-zero if any check
fails. Re-run it after adding or removing a skill.

A tool that is not installed is skipped rather than treated as an error, so the
same script works on a machine with only one of them.

## Why the script exists

The bridge used to be hand-made. By 2026-09-07, ten of the thirty skills had no
symlink at all — `find-skills`, `grill-me`, `grill-with-docs`, `handoff`,
`improve-codebase-architecture`, `prototype`, `setup-matt-pocock-skills`,
`tdd`, `teach`, `triage`. They were installed, they were on disk, and Claude
Code could not see any of them. Nothing reported a problem.

That is the failure mode to design against: a bridge that silently half-exists.
Hence a rebuild that is safe to re-run, plus checks that fail loudly rather
than a script that prints "done".

## Codex

Bridged, using the same symlinks as Claude Code. Verified from Codex's own
tooling rather than guessed:

- Its `skill-installer` skill states it installs "into `$CODEX_HOME/skills`",
  so that directory is where user skills belong.
- Its `list-skills.py` decides what is already installed with
  `os.path.isdir()`, which **follows symlinks**, and matches on directory name
  with no marker required.

`.system` (Codex's built-ins, marked by `.codex-system-skills.marker`) and
`codex-primary-runtime` are left alone: the script skips them when linking and
exempts them from its dangling check, so it never reports on or touches
anything Codex installed itself.

Still unverified: Codex's **runtime** skill loader is a compiled binary, not
that Python script, so strictly speaking only its tooling is confirmed to
follow symlinks. Open a Codex session and check the skills appear; if they do
not, the fallback is Codex's own installer, which can pull from a private repo
(`install-skill-from-github.py --repo ShenYo/Jarvis --path agents/skills/<name>`)
— at the cost of making real copies, which reintroduces the drift this layout
avoids.

## Do not run a blanket `npx skills update -g`

Two reasons, both measured on 2026-09-07:

**It would create about 50 directories in `$HOME`.** The CLI fans a skill out
to every agent it knows — 55 of them, `.adal` through `.zencoder`. Only three
of those exist on this machine today.

**13 of the 29 skills from `mattpocock/skills` are no longer in that repo.**
`caveman`, `design-an-interface`, `diagnose`, `edit-article`, `obsidian-vault`,
`qa`, `request-refactor-plan`, `review`, `to-issues`, `to-prd`,
`ubiquitous-language`, `write-a-skill`, `zoom-out`. Upstream has 37 skills and
has pruned these since this set was installed on 2026-06-16 — four of them were
already under `skills/deprecated/` at install time. Several are in active use.
Updating risks losing them, and this repo is the only copy that remains.

Update named skills individually (`npx skills update <name>`) after checking
that one still exists upstream, rather than updating the lot.

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
- `~/.claude/skills-backup-2026-08-04/` — a manual backup from before this repo
  existed. Git is the backup now; it can be deleted once you are satisfied
  nothing in it is missing here.
