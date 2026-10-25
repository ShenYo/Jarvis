# History

> **中文摘要**：這份文件收納 Jarvis README 不再放的內容：有日期或事件背景的決定與事故、
> 在特定條件下量到的觀察、以及 2026-10-23 到 2026-10-25 合併的工作。README 只說現在的
> 狀態與規則；每條規則後面若有來歷，會連到這裡對應的標題。搬過來的文字只調整時態，
> 並補上原本缺少的日期。

This file holds what the [README](../README.md) used to carry alongside the
present: decisions and incidents with their dates, measurements with the
conditions they were taken under, and the work merged between 2026-10-23 and
2026-10-25. The README says what is true now and why; where a rule has a
story, the README links to its heading here.

Entries are moved, not rewritten. A statement that is no longer true is kept
as what was true then, with its date. Dates are the owner's local time, UTC+8.

## Decisions and incidents

Newest first. Each entry says when, what happened, and what changed as a
result. Pull request links point at
[ShenYo/Jarvis](https://github.com/ShenYo/Jarvis/pulls).

### Personal instructions for every project

2026-10-24. Before the personal instructions existed, the language rule lived
only in two projects' auto memory, so a session started anywhere else replied
in English. [`.agents/AGENTS.md`](../.agents/AGENTS.md) now holds the personal
rules, and the bridge links it as `~/.claude/CLAUDE.md`
([#19](https://github.com/ShenYo/Jarvis/pull/19)) and as
`~/.codex/AGENTS.md` ([#32](https://github.com/ShenYo/Jarvis/pull/32)), which
Claude Code and Codex load in every session wherever it starts. The same
change renamed `agents/` to `.agents/`, to match the `~/.agents` name it is
reached through; the bridge migrates a `~/.agents` still pointing at the old
`.Jarvis/agents`, and only that exact target.

### Git hooks maintained here

2026-10-24. The three hooks began as copies of the hooks
[Friday](https://github.com/ShenYo/Friday) ships to projects, and since
2026-10-24 they are maintained here on their own: Jarvis and Friday do not
depend on each other, in either direction. Before then a mirror check kept the
copies byte-identical to Friday's
([#8](https://github.com/ShenYo/Jarvis/pull/8)). The change
([#23](https://github.com/ShenYo/Jarvis/pull/23)) dropped the comparison and
made the behaviour test, [`tests/githooks.sh`](../tests/githooks.sh), the
check that keeps the hooks honest. Friday dropped its mirrors the same day
([Friday#33](https://github.com/ShenYo/Friday/pull/33)).

### No Friday adoption wrapper

2026-10-24. Until this date the README summary said that Jarvis also provided
a safe-adoption wrapper for the Friday baseline. That wrapper was
`setup-project-agents`, Jarvis's one Friday-specific Skill, and
[#24](https://github.com/ShenYo/Jarvis/pull/24) removed it; Friday now
describes the install an agent runs
([Friday#34](https://github.com/ShenYo/Friday/pull/34)) and no longer names
Jarvis ([Friday#35](https://github.com/ShenYo/Friday/pull/35)). The statement
is no longer true, and the README no longer makes it.

### Push rules on GitHub as well

2026-10-24. The push rules used to live in the `pre-push` hook instead of on
GitHub: rulesets need a paid plan for a private repository, and this one was
private on the free plan. It is public now, so a ruleset on `main` is active;
it refuses deletion and non-fast-forward pushes and requires a pull request,
with no bypass actors. The hook stayed, for the two reasons the README gives.
The date is when the README first said so
([#10](https://github.com/ShenYo/Jarvis/pull/10)); when the repository became
public is not recorded here.

### A deeper Codex home

2026-10-24. The bridge script assumed that a bridge directory sits two levels
below `~`. Assuming two left every Codex link dangling for a deeper
`CODEX_HOME`. The script now computes the number of hops, and a `CODEX_HOME`
outside `$HOME` gets an absolute path through `~/.agents` instead (commit
[8be0a8a](https://github.com/ShenYo/Jarvis/commit/8be0a8a)).

### Codex bridge decided by its home

2026-10-24. The bridge used to decide whether Codex was installed by testing
for `${CODEX_HOME:-$HOME/.codex}/skills`. A fresh Codex install has the home
but has never created that subdirectory, so testing for the subdirectory
instead left Codex with no Skills at all while reporting it as not installed.
The script now tests for the home and creates `skills/` under it
([#9](https://github.com/ShenYo/Jarvis/pull/9)).

### Skills grouped under a container

2026-09-08. The bridge supports Skills grouped one level deep under a
container directory that has no `SKILL.md` of its own, because pet_care groups
its four git skills that way. A script that assumed one directory per skill
both linked the unloadable container and hid the real skills inside. The link
name comes from each skill's `name:` frontmatter, so
`.agents/skills/git/commit/` with `name: git-commit` links as
`~/.claude/skills/git-commit`. Nothing in this repository is nested (commit
[4efc6ef](https://github.com/ShenYo/Jarvis/commit/4efc6ef)).

### Hand-maintained bridge

2026-09-07. The bridge was hand-maintained before 2026-09-07, and installed
Skills could be present on disk yet invisible to Claude Code. That incident is
why the bridge is safely repeatable and checks canonical-name presence and
dangling entries rather than merely printing success.

### Upstream removed installed Skills

2026-09-07. A 2026-09-07 audit found that upstream had removed Skills that
were still locally installed. A blanket `npx skills update -g` could therefore
silently remove local installations; the README now tells the reader to update
one named Skill at a time, after checking that specific upstream Skill, and to
review the diff.

### Manual backup deleted

2026-09-07. `~/.claude/skills-backup-2026-08-04/` was a manual backup from
before this repository existed. It was deleted on 2026-09-07 after all nine of
its skills were verified byte-identical to the tracked copies. Git is the
backup now.

## Measured observations

Each is what was seen, under the conditions stated, and nothing more. Recount
or re-run before relying on one.

### Inventory and unreachable Skills

**Inventory observation, 2026-10-24:** this checkout has 35 canonical
`SKILL.md` files, 35 Claude bridge links, 35 Codex bridge links, and 35 lock
entries. Every canonical Skill is CLI-managed and reachable from both tools.

`orca-cli` and `orchestration` were briefly unreachable: the `skills` CLI
writes the canonical copy and the lock entry but does not create the bridge,
so a Skill it installs stays invisible to Claude Code and Codex until
`sync-personal-skills.sh` runs. That is the normal order of operations, not a
fault -- install with the CLI, then bridge.

A `synced` entry also sat in the Claude bridge directory. It is a real
directory rather than a symlink, so it belongs to another tool and the bridge
script deliberately leaves it alone.

These are observations, not enduring facts; recount rather than treating this
file as a cache.

### Claude Code bridge and same-name Skills

Three things were observed natively on **Claude Code 2.1.306** (2026-10-22),
in a consumer repository and a disposable fixture. They do not turn the
README's statement that Jarvis makes no precedence claim into a precedence
rule; they are what was seen. The third was recovered into this repository by
[#18](https://github.com/ShenYo/Jarvis/pull/18), and `setup-project-agents`,
named in the first and third, was removed afterwards
([#24](https://github.com/ShenYo/Jarvis/pull/24)).

- **The bridge reaches a consumer-repo session.** A session rooted in another
  repository reported `code-review`, `tdd`, `research`, `writing-for-agents`
  and `setup-project-agents` as available, resolving through
  `~/.claude/skills/<name>` into `~/.agents/skills` with `~/.agents` →
  `.Jarvis/.agents`. So the centralization here does reach a working session,
  not just the filesystem.
- **On a same-name collision, the personal Skill was the one present, and the
  project copy was not listed at all.** A fixture carried a project skill at
  `.claude/skills/research/` alongside this repository's personal `research`.
  A session with every tool disallowed — so the answer could only come from
  loaded context — reported **exactly one** skill named `research` and quoted
  the personal description verbatim. A control in the same fixture, a project
  skill with no personal counterpart, *was* listed, which is what makes the
  collision result meaningful rather than a discovery failure.

  The practical consequence: the losing Skill is **invisible**, not merely
  lower-priority, so a session cannot be asked to use the other one. If a
  project needs its own version of a name that exists here, rename one of
  them.

  One name, one fixture, one version, two scopes. Nothing is claimed about
  project-vs-plugin or Codex.
- **A personal Skill also won over a marketplace plugin of the same name, and
  the plugin kept the name when the bridge was gone.** `code-review` exists
  both here, as a Skill, and in the official marketplace as a plugin command
  (`~/.claude/plugins/marketplaces/claude-plugins-official/plugins/code-review/commands/code-review.md`).
  With the bridge in place, a session rooted in a consumer repository quoted
  *this* repository's description for `code-review`. With `~/.agents` and
  `~/.claude/skills` temporarily moved aside, the name stayed available —
  served by the marketplace copy — while `tdd`, `research`,
  `writing-for-agents` and `setup-project-agents` all became unavailable.

  Both directions are reported as observed. The practical point is not a
  precedence rule but that **a name can have more than one provider here**, so
  "the Skill is available" does not by itself mean the one in this repository
  is the one that loaded.

## Progress, 2026-10-23 to 2026-10-25

What merged in [ShenYo/Jarvis](https://github.com/ShenYo/Jarvis) in these
three days, by theme. Each number links to its pull request.

- **Claude Code guard.** The guard went under version control, gained a
  hook that parses Bash commands and fails closed, stopped reading anything
  but regular files, lost a deny rule that Claude Code read as a literal
  prefix, and now asks before a push that may carry a tag.
  [#21](https://github.com/ShenYo/Jarvis/pull/21),
  [#22](https://github.com/ShenYo/Jarvis/pull/22),
  [#25](https://github.com/ShenYo/Jarvis/pull/25),
  [#28](https://github.com/ShenYo/Jarvis/pull/28),
  [#38](https://github.com/ShenYo/Jarvis/pull/38).
- **Git hooks and CI.** The hooks took Friday's seven new token formats and
  its pre-push bootstrap fix, were then kept byte-identical to Friday's, and
  were finally made this repository's own; CI now runs every check on each
  pull request from one workflow.
  [#6](https://github.com/ShenYo/Jarvis/pull/6),
  [#7](https://github.com/ShenYo/Jarvis/pull/7),
  [#8](https://github.com/ShenYo/Jarvis/pull/8),
  [#23](https://github.com/ShenYo/Jarvis/pull/23),
  [#26](https://github.com/ShenYo/Jarvis/pull/26).
- **Personal instructions.** The basic rules became Jarvis's own, the
  personal rules moved to `.agents/AGENTS.md` and were linked for Claude Code
  and then Codex, grouped by scope, with rules for handing work to cheaper
  models, for document language, for written rules over auto memory and for
  writing mid-task decisions where they live.
  [#12](https://github.com/ShenYo/Jarvis/pull/12),
  [#19](https://github.com/ShenYo/Jarvis/pull/19),
  [#27](https://github.com/ShenYo/Jarvis/pull/27),
  [#29](https://github.com/ShenYo/Jarvis/pull/29),
  [#30](https://github.com/ShenYo/Jarvis/pull/30),
  [#31](https://github.com/ShenYo/Jarvis/pull/31),
  [#32](https://github.com/ShenYo/Jarvis/pull/32),
  [#33](https://github.com/ShenYo/Jarvis/pull/33),
  [#35](https://github.com/ShenYo/Jarvis/pull/35).
- **Dispatch docs and agent instructions.** One personal copy of the dispatch
  docs, updated so the GPT-6 Codex models run on codex-cli 0.164.0; the root
  `AGENTS.md` says what it is for and what an agent may not touch.
  [#11](https://github.com/ShenYo/Jarvis/pull/11),
  [#34](https://github.com/ShenYo/Jarvis/pull/34),
  [#36](https://github.com/ShenYo/Jarvis/pull/36),
  [#37](https://github.com/ShenYo/Jarvis/pull/37).
- **Bridge and Skills.** Codex installation is decided by its home; the
  Friday-specific Skill was dropped; the plugin-versus-personal observation
  was recovered; the managed core was synced to Friday twice before the two
  stopped depending on each other, and the hooks record was renamed for the
  hooks with two stale claims corrected.
  [#9](https://github.com/ShenYo/Jarvis/pull/9),
  [#10](https://github.com/ShenYo/Jarvis/pull/10),
  [#17](https://github.com/ShenYo/Jarvis/pull/17),
  [#18](https://github.com/ShenYo/Jarvis/pull/18),
  [#20](https://github.com/ShenYo/Jarvis/pull/20),
  [#24](https://github.com/ShenYo/Jarvis/pull/24).
- **Friday and its consumers, for context.** Friday dropped the hook mirrors
  and stopped naming Jarvis, and cut tagged payload releases; pet_care and
  money-pit-nephew then synced their managed core to Friday v1.0.0.
  [Friday#33](https://github.com/ShenYo/Friday/pull/33),
  [Friday#35](https://github.com/ShenYo/Friday/pull/35),
  [Friday#42](https://github.com/ShenYo/Friday/pull/42),
  [pet_care#73](https://github.com/dameiwoha/pet_care/pull/73),
  [money-pit-nephew#37](https://github.com/Miko-Sam-chon/money-pit-nephew/pull/37).

Still open: the agent machine account
([Jarvis#13](https://github.com/ShenYo/Jarvis/issues/13), with one issue per
agent: Claude Code [#14](https://github.com/ShenYo/Jarvis/issues/14), Codex
[#15](https://github.com/ShenYo/Jarvis/issues/15) and agy
[#16](https://github.com/ShenYo/Jarvis/issues/16)).
