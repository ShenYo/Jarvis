# Jarvis

**English** · [繁體中文](./README.zh-TW.md)

> **繁中摘要**：Jarvis 是這台機器的個人 AI agent Skills 版本庫。它讓
> `~/.Jarvis/.agents` 成為唯一 canonical copy，透過 `~/.agents` 與 Claude
> Code／Codex 的 symlink 共用；它也保管個人指示與 Claude Code guard。專案
> 本身必須不依賴 Jarvis 仍可重現。歷史與觀察記錄在 `docs/history.md`。

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
- **Claude Code guard:** one versioned set of rules, copied into
  `~/.claude/settings.json`, refuses destructive Git and file operations in
  every project on this machine.

## Scope and ownership

| Layer | Owns | Does not own |
| --- | --- | --- |
| **Jarvis** | This machine's canonical personal Skills, bridge script, and personal Skill provenance; the personal instructions linked as `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`; the [Claude Code guard](./docs/guard.md#claude-code-guard) it copies into `~/.claude/settings.json` | A project's `.agents/`, project policy, or any other personal setting |
| **Friday** | A reviewed shared baseline that a consumer may pin and adopt | This machine's personal catalog or a consumer's conflict resolution |
| **Consumer project** | Its `.agents/` seed, overlays, integrations, tests, and recorded Friday provenance | Jarvis's personal Skills or Friday's vendor payload |

A consumer project must build, test, and pass CI on a machine that has no
personal layer at all -- a CI runner or another person's laptop has no copy of
this repository. So whatever a project requires belongs in that project or in
the Friday baseline it adopted, never here. Jarvis can help an agent work on a
project; it must not become a hidden project dependency. Personal helpers such
as [TDD](./.agents/skills/tdd/) or [Wayfinder](./.agents/skills/wayfinder/) may
assist, but a project-required outcome lives in that project's own
documentation, tests or automation, and a missing helper must not block it.

This constrains consumer projects, not Jarvis. Jarvis is expected to be present
on this machine, and an agent working here may rely on it.

## Status (2026-11-02)

In place:

- **Personal instructions.** [`.agents/AGENTS.md`](./.agents/AGENTS.md) is
  linked as `~/.claude/CLAUDE.md` for Claude Code and as `~/.codex/AGENTS.md`
  for Codex, so both load it in every session. It is grouped by scope: *Base
  behavior* (reply language, written rules over auto memory, handing work to
  cheaper models), *Coding* (understand first, nothing speculative, surgical
  changes, verify, write decisions where they live) and *Contracts*
  (documents in English with a Chinese summary, Git in a repository without
  its own rules).
- **Dispatch docs.** [`docs/dispatch/`](./docs/dispatch/policy.md) holds the
  policy, the prompt templates and the Codex adapter. Codex runs
  `gpt-6.1-sol` as Commander and `gpt-6-luna` as Implementer and Worker,
  verified 2026-10-25 on codex-cli 0.164.0.
- **Claude Code guard.** The [guard](./docs/guard.md#claude-code-guard) refuses the
  permanently prohibited Git and file operations and asks at the human-review
  checkpoints, including before a push that may carry a tag.
- **Codex guard.** The same guard runs as a user-level Codex hook, refusing
  where Claude Code would ask, because Codex cannot ask ([Codex](./docs/guard.md#codex)).
- **Git hooks and CI.** The three [local hooks](./docs/git-hooks.md) run in this
  clone. The [`CI`](.github/workflows/ci.yml) workflow runs on every pull
  request, and its four checks (the tests on Linux and macOS, the Skills
  check, and the secret scan) are required on `main`.
- **Releases.** Jarvis is versioned from v1.0.0, the first tag; each release's
  notes are in [`CHANGELOG.md`](./CHANGELOG.md) (see [Releases](./docs/releases.md)).
- **Agent identity.** Claude Code and Codex act on GitHub as a machine account
  of their own, set up per machine, and the guard can refuse a runtime whose
  identity is not applied (v1.2.0, [#13](https://github.com/ShenYo/Jarvis/issues/13)).
  See [Agent identity](./docs/agent-identity.md).

Pending:

- Agent identity for agy: [#16](https://github.com/ShenYo/Jarvis/issues/16).
- Codex Skill Phase B as a whole remains **UNVERIFIED**; do not infer
  completion from individual probes or bridge entries.

What happened on the way, with dates, and the measurements behind some rules,
are in [`docs/history.md`](./docs/history.md).

## Current inventory

This checkout has 35 canonical `SKILL.md` files, 35 Claude bridge links, 35
Codex bridge links, and 35 lock entries. Every canonical Skill is CLI-managed
and reachable from both tools.

The `skills` CLI writes the canonical copy and the lock entry but does not
create the bridge, so a Skill it installs stays invisible to Claude Code and
Codex until [`sync-personal-skills.sh`](./sync-personal-skills.sh) runs:
install with the CLI, then bridge
([history](./docs/history.md#inventory-and-unreachable-skills)). A real directory rather than
a symlink in the Claude bridge directory belongs to another tool, and the
bridge script deliberately leaves it alone.

These numbers are a count, not a cache; recount rather than trusting them:

```sh
find ~/.Jarvis/.agents/skills -mindepth 1 -maxdepth 2 -name SKILL.md -type f | wc -l
find ~/.claude/skills -maxdepth 1 -type l | wc -l
find "${CODEX_HOME:-$HOME/.codex}/skills" -maxdepth 1 -type l | wc -l
jq '.skills | length' ~/.Jarvis/.agents/.skill-lock.json
comm -23 \
  <(find ~/.Jarvis/.agents/skills -mindepth 1 -maxdepth 2 -name SKILL.md -type f \
    -exec sed -n 's/^name:[[:space:]]*//p' {} \; | sort) \
  <(jq -r '.skills | keys[]' ~/.Jarvis/.agents/.skill-lock.json | sort)
```

## Quick start

On a machine that has Git and access to the Jarvis remote, and no `~/.Jarvis` yet:

```sh
git clone git@github.com:ShenYo/Jarvis.git ~/.Jarvis
git -C ~/.Jarvis config core.hooksPath .githooks
~/.Jarvis/sync-personal-skills.sh
```

That is the whole bridge: one canonical copy under `~/.Jarvis/.agents`, linked
into Claude Code and Codex. The guards and the agent identity come next;
[Setting up a new machine](./docs/setup-new-machine.md) walks through every
step in order, with a check after each.

## Documents

| Document | Read it when |
| --- | --- |
| [Setting up a new machine](./docs/setup-new-machine.md) | You are installing Jarvis on a machine for the first time: every step in order, with its check. |
| [Architecture](./docs/architecture.md) | You want to know how the layout and the symlink chain work, what is CLI-managed, and what the bridge does not prove. |
| [Guard](./docs/guard.md) | You want to know what the Claude Code and Codex guards refuse, or to turn the agent-identity switch on. |
| [Agent identity](./docs/agent-identity.md) | You need the reference for the agent's GitHub account: creating it, the config file, the checks, Codex and the known limits. |
| [Maintenance](./docs/maintenance.md) | You are adding, updating, removing or verifying a Skill, or the bridge misbehaves. |
| [Local Git hooks](./docs/git-hooks.md) | A hook refused something, or you are changing one. |
| [Releases](./docs/releases.md) | You are choosing a version or cutting a release. |
| [Git rules](./docs/git.md) | You are about to run a Git operation here. |
| [History](./docs/history.md) | You want the story and the measurements behind a rule. |
| [Dispatch policy](./docs/dispatch/policy.md) | You are handing work to another model. |
| [Changelog](./CHANGELOG.md) | You want to know what changed in a release and what to do on this machine. |

The setup guide comes in English and in [Traditional Chinese](./docs/setup-new-machine.zh-TW.md);
every other document is in English, with a Chinese summary at the top.

## Not in this repo

- Project-level `.agents/` — see the note at the top; it stays in its project.
- `~/.claude/skills/*` and the configured Codex skills directory (by default
  `~/.codex/skills/*`) — generated bridge entries; the script creates or
  replaces canonical-name entries only when they are missing or dangling.
- `~/.claude/settings.json`, `~/.codex/config.toml` — machine settings that may
  contain tokens or paths; deliberately left out for now, worth revisiting.
