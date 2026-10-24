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

Every Skill under `.agents/skills/` is installed by a CLI from an upstream
repository, recorded in
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

## Two vendored Skills replace a project's own guards

Both are upstream's and stay as they are. Before running either in a project,
look at what that project already has.

**`setup-pre-commit`** runs `npx husky init`, which sets `core.hooksPath` to
`.husky/_`. In a project whose `core.hooksPath` already points at its own hooks
(`git config --get core.hooksPath`), those hooks then stop running: the secret
scan, the message check and the push rules, with no warning and no sign in a
commit that succeeds. Do not run it there.

**`git-guardrails-claude-code`** writes a `PreToolUse` hook with
`matcher: "Bash"` into the project's `.claude/settings.json`. Hook sources
merge, and a block is a veto no source can lift, so it breaks nothing outright.
But it sets no `onFailure`, so it fails *open*, and it blocks `git push`
unconditionally, which contradicts the rule that pushing a non-default branch
is the agent's own call. On this machine the
[Claude Code guard](./README.md#claude-code-guard) already covers what it
offers. Run it only where a project wants its own copy of that guard.

## The Git hooks are this repository's own

`.githooks/` holds three hooks maintained here, independently of Friday's. To
change a rule, change the hook and [`docs/git.md`](docs/git.md) in the same
commit, and add a case to [`tests/githooks.sh`](tests/githooks.sh). Done when
that case fails against the old hook and `bash tests/githooks.sh` reports
`all … passed`.

Do not reach for `--no-verify`; the Claude Code guard refuses that flag.

## Working rules

The general rules for how to work -- understand first, nothing speculative,
surgical changes, verify and say what you ran -- are the personal
instructions, [`.agents/AGENTS.md`](./.agents/AGENTS.md), which every session
already loads. These four are this repository's own:

1. **Scratch files go under `docs/temp/<purpose>/`**, which `.gitignore`
   ignores. Never stage one, and never reach for a blanket `git add -A` across
   a mixed tree to find out what is there.
2. Both READMEs are checked for parity by
   [`scripts/check-readme-parity.py`](./scripts/check-readme-parity.py). An
   edit to one needs the matching edit to the other.
3. Never write to `~/.Jarvis` from inside a consumer project's workflow. This
   repository is optional for every project; a project that writes here has
   made it mandatory.
4. `.agents/AGENTS.md` is grouped by scope -- base behavior, coding,
   contracts -- and each scope opens with a comment naming what it is
   responsible for. A new rule goes under its scope. Write it out only when
   every turn needs it; reference that only some tasks reach goes in its own
   file under `docs/`, with a pointer that says when to read it. Codex does
   not expand `@` imports, so a rule behind one never reaches Codex.

### Git

Read [`docs/git.md`](docs/git.md) before a Git operation here. It sets out:

- which operations are the agent's own call
- which are reserved for a person
- which are prohibited even when explicitly asked
- the commit format the hooks enforce

It is the authority on Git in this repository.
