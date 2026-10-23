# Agent Instructions

This repository is the machine-level home for personal AI-agent Skills. It is
**personal scope**: a catalog plus the symlink bridge that makes it visible to
Claude Code and Codex. Read this before changing anything here.

Nothing in this repository is a dependency of any project. A consumer project
must build, test, and pass CI on a machine that has no copy of it.

## Most of this repository is not ours to edit

35 of the 36 Skills under `agents/skills/` are installed by a CLI from an
upstream repository, recorded in
[`agents/.skill-lock.json`](./agents/.skill-lock.json) with the upstream tree
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
- [`agents/skills/setup-project-agents/`](./agents/skills/setup-project-agents/)
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

The hooks enforce rules whose text lives in Friday, which is public. Read them
there:

- [agent-rules.md](https://github.com/ShenYo/Friday/blob/main/payload/.agents/docs/agent-rules.md)
  -- scope, understand first, small reversible changes, verify the outcome
- [git-guideline/safety-boundary.md](https://github.com/ShenYo/Friday/blob/main/payload/.agents/docs/git-guideline/safety-boundary.md)
  -- which Git and GitHub operations are the agent's own call and which are
  reserved for a human
- [git-guideline/git-commit.md](https://github.com/ShenYo/Friday/blob/main/payload/.agents/docs/git-guideline/git-commit.md)
  -- commit message shape
- [scratch-files.md](https://github.com/ShenYo/Friday/blob/main/payload/.agents/docs/scratch-files.md)
  -- temporary artifacts belong under an ignored `docs/temp/<purpose>/` and are
  never staged

Linked rather than copied on purpose. A copy here would be a fourth place to
keep in step, and the three that already exist went out of step once.

Two additions specific to this repository:

- Both READMEs are checked for parity by
  [`scripts/check-readme-parity.py`](./scripts/check-readme-parity.py). An edit
  to one needs the matching edit to the other.
- Never write to `~/.Jarvis` from inside a consumer project's workflow. This
  repository is optional for every project; a project that writes here has made
  it mandatory.
