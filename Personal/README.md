# Personal

Machine-level (not per-project) AI agent configuration. Everything here applies
to every project on a machine, which is exactly why it needs version control:
until 2026-09-07 these 30 skills lived only in `~/.agents/` with no history, no
backup, and no way to tell what had changed.

## Layout

```
Personal/
  agents/
    skills/<name>/SKILL.md     canonical skill content
    .skill-lock.json           what the skills CLI installed, and from where
  sync-personal-skills.sh      rebuilds the symlink bridges; idempotent
```

`agents/` is the real content. Everything outside this repo is a symlink into
it, so there is exactly one copy of every skill.

## The symlink chain

```
~/.agents                 -> Jarvis/Personal/agents
~/.claude/skills/<name>   -> ../../.agents/skills/<name>
```

Two hops, and the second one matters: `~/.claude/skills/<name>` resolves
`../../` to `~/`, so it goes through `~/.agents` rather than pointing at this
repo directly. That is deliberate — `~/.agents` is the stable address, so this
repo can be cloned anywhere as long as that one symlink points at it.

## There is nothing to sync

`~/.agents` is a symlink, not a copy. `~/.agents/skills/foo/SKILL.md` and
`Personal/agents/skills/foo/SKILL.md` are the same inode — one file with two
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
~/Jarvis/Personal/sync-personal-skills.sh
```

The script creates `~/.agents` if it is missing, links every skill into
`~/.claude/skills/`, then verifies its own work: every skill has a live link,
no link dangles, every skill has a `SKILL.md`. It exits non-zero if any check
fails. Re-run it after adding or removing a skill.

## Why the script exists

The bridge used to be hand-made. By 2026-09-07, ten of the thirty skills had no
symlink at all — `find-skills`, `grill-me`, `grill-with-docs`, `handoff`,
`improve-codebase-architecture`, `prototype`, `setup-matt-pocock-skills`,
`tdd`, `teach`, `triage`. They were installed, they were on disk, and Claude
Code could not see any of them. Nothing reported a problem.

That is the failure mode to design against: a bridge that silently half-exists.
Hence a rebuild that is safe to re-run, plus checks that fail loudly rather
than a script that prints "done".

## Open question: Codex

`~/.codex/skills/` exists and uses the same `<name>/SKILL.md` layout, but
**none of these skills reach Codex** — the script does not bridge it, and
nothing else does either.

Verified: the directory holds only Codex's own skills, under `.system/`
(`review-agent`, `skill-creator`, `plugin-creator`, `skill-installer`,
`openai-docs`) and `codex-primary-runtime/` (`spreadsheets`, `slides`). There
are no symlinks into `~/.agents`.

**Not** verified, and worth checking before bridging:

1. Whether Codex actually loads user skills placed in `~/.codex/skills/`.
   `.system/` carries a `.codex-system-skills.marker`, which implies unmarked
   directories are user territory — but that is an inference.
2. Whether `.system/skill-installer` treats that directory as its own and
   would remove hand-placed symlinks.

There is also a cleaner route than symlinks. Skills installed by the current
`npx skills` CLI carry an `agents/openai.yaml` descriptor for Codex; **none of
the 30 skills here have one**, and the lock file is named `.skill-lock.json`
rather than the current `skills-lock.json`, so this set was installed by an
older version. Re-installing with the current CLI may produce the Codex
descriptors directly. `npx skills experimental_sync` ("Sync skills from
node_modules into agent directories", plural) looks relevant.

## Not in this repo

- `~/.claude/skills/*` — generated symlinks, rebuilt by the script.
- `~/.claude/settings.json`, `~/.codex/config.toml` — machine settings that may
  contain tokens or paths; deliberately left out for now, worth revisiting.
- `~/.claude/skills-backup-2026-08-04/` — a manual backup from before this repo
  existed. Git is the backup now; it can be deleted once you are satisfied
  nothing in it is missing here.
