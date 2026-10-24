# Agent Instructions

This repository is the machine-level home for personal AI-agent Skills. It is
**personal scope**: a catalog plus the symlink bridge that makes it visible to
Claude Code and Codex, the personal instructions linked as
`~/.claude/CLAUDE.md`, and the Claude Code guard that
`scripts/apply-claude-guard.sh` copies into `~/.claude/settings.json`. Read
this before changing anything here.

Nothing in this repository is a dependency of any project. A consumer project
must build, test, and pass CI on a machine that has no copy of it.

## Most of this repository is not ours to edit

35 of the 36 Skills under `.agents/skills/` are installed by a CLI from an
upstream repository, recorded in
[`.agents/.skill-lock.json`](./.agents/.skill-lock.json) with the upstream tree
hash. As of 2026-10-24 every one of them is byte-identical to the tree recorded
at install time; keep it that way.

- **Do not patch a vendored Skill**, not to fix a bug, not to add a project
  rule, not to adjust a prompt. The edit is invisible to the CLI, survives
  until the next update silently reverts it, and the lock will still claim the
  upstream hash.
- Install and update through the owning CLI, after reading the named upstream
  source. Then run
  [`sync-personal-skills.sh`](./sync-personal-skills.sh) -- the CLI writes the
  canonical copy and the lock entry but not the bridge, so a Skill it installs
  stays invisible until the bridge runs.
- [`.agents/skills/setup-project-agents/`](./.agents/skills/setup-project-agents/)
  is the one locally authored Skill. It is ours.

## Two vendored Skills conflict with the Friday baseline

Both are upstream's and stay as they are. Neither may be run in a repository
that has adopted the [Friday](https://github.com/ShenYo/Friday) baseline --
pet_care and Finance today, identifiable by a `.friday-lock.json` at the root.

**`setup-pre-commit`** runs `npx husky init`, which overwrites
`core.hooksPath`:

```
before:            .agents/githooks
after husky init:  .husky/_
```

Friday's secret scan, commit-message check, and push rules then stop running,
with no warning and no sign in a commit that succeeds. The reverse order is
safe: `install.sh` refuses a repository that already sets `core.hooksPath`.

**`git-guardrails-claude-code`** writes the same place as Friday's guard
(`.claude/settings.json`, `PreToolUse`, `matcher: "Bash"`). Hook sources merge
and a block is a veto no source can lift, so nothing breaks -- but it sets no
`onFailure`, so it fails *open* where Friday's guard fails closed, and it
blocks `git push` unconditionally, which contradicts the rule that pushing a
non-default branch is the agent's own call.

## The Git hooks here are copies

`.githooks/` holds three hooks that are byte-identical to Friday's payload.
Editing one here is drift, and
[`.github/workflows/hooks-drift.yml`](.github/workflows/hooks-drift.yml) will
say so. A rule that needs changing is changed in Friday and carried over with
`friday-propagate`. See [the README](./README.md#hooksjson).

Do not reach for `--no-verify`; the guard refuses that flag.

## Working rules

These are this repository's own, stated here rather than linked. Basic
discipline should not be something this repository borrows -- and unlike the
Git rules below, it does not move when a hook changes.

1. **Scope.** Make only the changes the request needs. Report what you noticed
   rather than fixing it unasked: in a repository that is mostly vendored
   content, an unasked fix is usually an edit to someone else's file.
2. **Understand first.** Read the file, and the lock entry or upstream source
   behind it, before changing it. Where two readings of a request would produce
   materially different work, say so instead of choosing silently.
3. **Small and reversible.** Prefer the smallest change that meets the request,
   in the conventions already here. No speculative abstraction, no unrelated
   cleanup riding along.
4. **Verify, and say what you ran.** A claim about behaviour needs a command
   and its output. State what passed, what you could not check, and why --
   `UNVERIFIED` is an acceptable answer and a guess is not.
5. **Scratch files go under `docs/temp/<purpose>/`**, which `.gitignore`
   ignores. Never stage one, and never reach for a blanket `git add -A` across
   a mixed tree to find out what is there.

Two more that are specific to this repository:

6. Both READMEs are checked for parity by
   [`scripts/check-readme-parity.py`](./scripts/check-readme-parity.py). An
   edit to one needs the matching edit to the other.
7. Never write to `~/.Jarvis` from inside a consumer project's workflow. This
   repository is optional for every project; a project that writes here has
   made it mandatory.

### Why the Git rules are not in that list

They come with the hooks. `.githooks/` holds byte-identical copies of Friday's,
so the rules those hooks enforce are Friday's text, and they change when the
hooks change. Pointing at the source is the honest thing to do -- a copy here
would be a fourth place to keep in step, and the three that already exist went
out of step once.

- [safety-boundary.md](https://github.com/ShenYo/Friday/blob/main/payload/.agents/docs/git-guideline/safety-boundary.md)
  -- which Git and GitHub operations are the agent's own call, which are
  reserved for a person, and which are prohibited outright even when you are
  explicitly asked to perform them
- [git-commit.md](https://github.com/ShenYo/Friday/blob/main/payload/.agents/docs/git-guideline/git-commit.md)
  -- the commit message format `commit-msg` enforces

Read them before a Git operation here. They are the authority on it; nothing in
this file overrides them.
