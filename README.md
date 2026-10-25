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
| **Jarvis** | This machine's canonical personal Skills, bridge script, and personal Skill provenance; the personal instructions linked as `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`; the [Claude Code guard](#claude-code-guard) it copies into `~/.claude/settings.json` | A project's `.agents/`, project policy, or any other personal setting |
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

## Status (2026-10-25)

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
- **Claude Code guard.** The [guard](#claude-code-guard) refuses the
  permanently prohibited Git and file operations and asks at the human-review
  checkpoints, including before a push that may carry a tag.
- **Git hooks and CI.** The three [local hooks](#local-git-hooks) run in this
  clone. The [`CI`](.github/workflows/ci.yml) workflow runs on every pull
  request, and its four checks (the tests on Linux and macOS, the Skills
  check, and the secret scan) are required on `main`.

Pending:

- The guard for Codex, which cannot ask the way Claude Code does: the plan is
  recorded in [a comment on ShenYo/Jarvis#15](https://github.com/ShenYo/Jarvis/issues/15#issuecomment-6393273492).
- Agent identity, so that an agent acts under its own identity rather than
  ShenYo's: [ShenYo/Jarvis#13](https://github.com/ShenYo/Jarvis/issues/13),
  with one issue per agent: Claude Code
  [#14](https://github.com/ShenYo/Jarvis/issues/14), Codex
  [#15](https://github.com/ShenYo/Jarvis/issues/15) and agy
  [#16](https://github.com/ShenYo/Jarvis/issues/16).
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

## Architecture and layout

```
AGENTS.md                    rules for an agent working in this repository
CLAUDE.md                    a pointer that imports AGENTS.md
.agents/                     reached as ~/.agents
  AGENTS.md                  personal instructions for every project
  skills/<name>/SKILL.md     canonical skill content
  .skill-lock.json           what the skills CLI installed, and from where
sync-personal-skills.sh      ensures the Claude bridge directory and
                             missing/dangling canonical-name links; idempotent
```

[`AGENTS.md`](./AGENTS.md) is where an agent is told what it may not touch
here: most Skills are vendored and belong to an upstream CLI, two of them
replace a project's own guards if run in the wrong place, and the Git hooks
are this repository's own. It keeps only the working rules specific to this
repository. The general ones, how any agent should work, are in the personal
instructions, so they apply in every session, not only here. The Git rules
are [`docs/git.md`](./docs/git.md).

**Two files are called `AGENTS.md`, and they have different scopes.** The one
at the root is for an agent working *in this repository*. The one in
`.agents/` is for *every project*: [`.agents/AGENTS.md`](./.agents/AGENTS.md)
holds personal rules, such as replying in the user's language, and the bridge
links it as `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`, which Claude Code
and Codex load in every session wherever it starts. It exists
because a rule that lived only in project memory did not reach a session
started anywhere else
([history](./docs/history.md#personal-instructions-for-every-project)). Reference it reaches only for some tasks
lives in its own file, behind a pointer: the dispatch policy, prompt templates
and Codex adapter are in [`docs/dispatch/`](./docs/dispatch/policy.md).
Keep that file short, because it is loaded on every turn of every session, and
keep a rule about one repository in that repository instead.

The directory is `.agents/`, not `agents/`, to match the `~/.agents` name it is
reached through. The bridge migrates a `~/.agents` still pointing at the old
`.Jarvis/agents`, and only that exact target.

Rolling back past the rename needs the reverse step first, because an older
bridge expects `~/.agents` to name `.Jarvis/agents` and refuses anything else:

```sh
git -C ~/.Jarvis checkout <older revision>
ln -sfn .Jarvis/agents ~/.agents
~/.Jarvis/sync-personal-skills.sh
```

Every skill link resolves through `~/.agents`, so they recover with it. The
older bridge does not manage `~/.claude/CLAUDE.md` and leaves the link alone,
dangling. Remove it, or restore whatever was there before.

`.agents/` is the real content. Everything outside this repo is a symlink into
it, so there is exactly one copy of every skill.

`~/.agents` **must be a symlink to `~/.Jarvis/.agents`**. It is the stable
address through which the Claude and Codex bridge links resolve.

A skill is a directory containing `SKILL.md` — not merely a directory. Skills
may be grouped one level deep under a container that has no `SKILL.md` of its
own; the container is not linked, the skills inside it are. The link name comes
from each skill's `name:` frontmatter, which is what the tools match on, so
`.agents/skills/git/commit/` with `name: git-commit` links as
`~/.claude/skills/git-commit`. Nothing here is nested today; the support exists
because a consumer project groups its git skills that way
([history](./docs/history.md#skills-grouped-under-a-container)).

## The symlink chain

```
~/.agents                 -> .Jarvis/.agents
~/.claude/skills/<name>   -> ../../.agents/skills/<name>
${CODEX_HOME:-$HOME/.codex}/skills/<name>
                           -> ../../.agents/skills/<name>
~/.claude/CLAUDE.md       -> ../.agents/AGENTS.md
${CODEX_HOME:-$HOME/.codex}/AGENTS.md
                           -> ../.agents/AGENTS.md
```

Two hops, and the second one matters: `~/.claude/skills/<name>` resolves
`../../` to `~/`, so it goes through `~/.agents` rather than pointing at this
repo directly. That is deliberate — `~/.agents` is the stable address, while
the bridge script requires this repository to be cloned at `~/.Jarvis`.

The `../../` above is the count for a bridge directory two levels below `~`,
which is where both defaults sit. The script computes the count rather than
assuming it, so a `CODEX_HOME` at any other depth gets the right number of
hops, and one outside `$HOME` gets an absolute path through `~/.agents`
instead ([history](./docs/history.md#a-deeper-codex-home)).

## There is nothing to sync

`~/.agents` is a symlink, not a copy. `~/.agents/skills/foo/SKILL.md` and
`~/.Jarvis/.agents/skills/foo/SKILL.md` are the same inode — one file with two
names. Editing through either path edits the same bytes, and `git status` in
this repo sees it immediately. The two cannot drift, because there is only one
of them.

This is why the repo is cloned at `~/.Jarvis` with `~/.agents` pointing into it,
rather than keeping a same-shaped copy in both places. Two real directories
would need syncing and would drift; one directory with two names cannot.

The single way this breaks is if something **replaces** the `~/.agents` symlink
with a real directory — then two copies do exist, edits land in whichever one
the tool opened, and nothing announces it.
[`sync-personal-skills.sh`](./sync-personal-skills.sh) refuses to
run in that case and tells you to diff the two before choosing, rather than
quietly linking on top of the wrong one.

## Setting up a new machine

> **繁中摘要**：Jarvis 是個人可選層。先確認 Git、Bash 與遠端存取權，且
> `~/.Jarvis` 不存在；clone 後只執行 bridge 與唯讀確認。此流程不安裝 Claude／
> Codex、不設定憑證，也不讓新專案依賴 Jarvis。

Prerequisites are Git, Bash, and access to the configured Jarvis remote. Choose
this canonical destination only when `~/.Jarvis` does not already exist; never
clone over an existing checkout. Inspect and reconcile an existing checkout
under its own Git history instead.

```sh
(
  set -eu
  if [ -e "$HOME/.Jarvis" ] || [ -L "$HOME/.Jarvis" ]; then
    echo '~/.Jarvis already exists or is a dangling link; inspect it instead of overwriting it.' >&2
    exit 1
  fi
  git clone git@github.com:ShenYo/Jarvis.git "$HOME/.Jarvis"
  "$HOME/.Jarvis/sync-personal-skills.sh"
)
```

Every Skill is tracked in this repository, so the clone and the bridge are the
whole setup: nothing is fetched at run time to make a Skill available, and the
Skills CLI is not needed to run one. It is needed to install or update a
CLI-managed Skill afterwards — see [CLI-managed and locally maintained
content](#cli-managed-and-locally-maintained-content) — and by one Skill's own
workflow: [`find-skills`](./.agents/skills/find-skills/) searches for Skills
that are *not* installed, so it reaches the network, and its search step runs
`npx skills find`. A clone-only machine can run every other Skill here; that
one will stop at its first step.

The bridge command neither installs a runtime nor creates credentials. It is
safe to omit Jarvis entirely for a project: personal Skills remain optional.
After the bridge, use the read-only checks in [Verify](#verify) to confirm the
canonical symlink and any already-installed Claude/Codex bridge directories.

A new project takes its baseline from wherever that baseline is maintained,
following that source's own adoption guide. Do not copy Jarvis Skills into a
project: they are personal, and a project must work on a machine without
them.

The script also links `~/.claude/CLAUDE.md` to the personal instructions in
`.agents/AGENTS.md`. It creates that link when it is missing and replaces it when
it dangles. It refuses, and changes nothing, when `~/.claude/CLAUDE.md` is a real
file, because that file holds instructions someone wrote, or a live link
elsewhere, because that link was put there on purpose. To adopt the link on a
machine that already has a `~/.claude/CLAUDE.md`, move what it should keep into
`.agents/AGENTS.md`, remove it, and run the script again.

When Codex is installed, `${CODEX_HOME:-$HOME/.codex}/AGENTS.md` gets the same
link and the same refusals, so both tools read one file and there is no copy to
keep in step. Codex reads `AGENTS.override.md` in its home instead of
`AGENTS.md` when that file is not empty, so the script fails while one exists.

The script creates `~/.agents` if it is missing, ensures the Claude bridge
directory exists, and creates or replaces a canonical-name entry only when it
is missing or dangling. It bridges Codex when
`${CODEX_HOME:-$HOME/.codex}` exists, creating `skills/` under it if needed, because a
fresh Codex install has the home but not yet that subdirectory
([history](./docs/history.md#codex-bridge-decided-by-its-home)). An absent Codex home is skipped rather than
treated as an error. It checks that each canonical skill has an existing entry under its declared name in every bridged tool, reports
dangling non-reserved entries, and rejects a top-level canonical directory that
is neither a Skill nor a grouping directory. A live canonical-name entry that
points at the wrong target is left unchanged and is not detected. It exits
non-zero if these checks fail. Re-run it after adding or removing a skill.

## Daily maintenance

### Add

Add a directory containing `SKILL.md` under `.agents/skills/` (or one level
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
[`.agents/.skill-lock.json`](./.agents/.skill-lock.json) for its source and verify that the named upstream
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

Running [`~/.Jarvis/sync-personal-skills.sh`](./sync-personal-skills.sh) is the normal bridge check. For a
read-only inspection, use:

```sh
test -L ~/.agents && test "$(cd -P ~/.agents && pwd)" = "$(cd -P ~/.Jarvis/.agents && pwd)"
find ~/.Jarvis/.agents/skills -mindepth 1 -maxdepth 2 -type f -name SKILL.md | sort
find ~/.claude/skills -maxdepth 1 -type l -print | sort
CODEX_SKILLS="${CODEX_HOME:-$HOME/.codex}/skills"
[ ! -d "$CODEX_SKILLS" ] || find "$CODEX_SKILLS" -maxdepth 1 -type l -print | sort
```

### Recover a `~/.agents` conflict

Stop if the script says `~/.agents` is a real directory or resolves elsewhere.
Compare it with the canonical directory first and decide which copy is current:

```sh
diff -ru ~/.agents ~/.Jarvis/.agents
```

After that comparison, preserve the conflicting directory under a dated backup
name, recreate the required symlink, and rerun the bridge script. Replacing it
without a backup can discard uncommitted Skills.

```sh
mv ~/.agents "$HOME/.agents.conflict-$(date +%Y%m%d-%H%M%S)"
ln -s .Jarvis/.agents ~/.agents
~/.Jarvis/sync-personal-skills.sh
```

## CLI-managed and locally maintained content

[`.agents/.skill-lock.json`](./.agents/.skill-lock.json) records Skills installed by the Skills CLI, including
their source, path, hash, and timestamps. Treat those as third-party/
CLI-managed: do not casually patch their contents or rewrite the lock to make
an installation look different. A missing lock entry means the CLI did not
record that Skill; it does not make a canonical Skill invalid.

Every Skill here is CLI-managed. What is locally maintained is the bridge
script, the personal instructions, the Claude Code guard, the Git hooks and
their rules, and this README. The settings files themselves are not part of
this repository, because `~/.claude/settings.json` and `~/.codex/config.toml`
may contain local paths or secrets. The guard is merged into
`~/.claude/settings.json` by its apply script, and nothing else in that file
comes from here.

Matt Pocock and other CLI-managed vendor Skills are updated only through their
owning CLI after reviewing the named upstream source. Do not patch their
vendored files to implement project setup or policy. When an optional external
tracker is available, its project output is defined by that project's contract:
resolve the Git root first, then use
`docs/temp/matt-pocock/<feature>/<unique-suffix>/`. If the optional capability,
repository root, or valid feature is unavailable, stop that optional workflow
rather than writing an alternative personal or vendor location.

## Local Git hooks

`core.hooksPath` points at [`.githooks/`](.githooks), so this clone runs three
commit-time and push-time checks. They are a guard against mistakes, not a
server-side control: `core.hooksPath` is per-clone configuration that is never
cloned, so a fresh clone of this repository runs none of them until someone
sets it again. When a hook refuses, it points at [`docs/git.md`](./docs/git.md),
which holds this repository's Git rules.

| Hook | Refuses |
| --- | --- |
| [`pre-commit`](.githooks/pre-commit) | A staged diff whose added lines look like a credential, key, token, password or connection string. It names the rule and the file, never the matched value. |
| [`commit-msg`](.githooks/commit-msg) | A subject that is not Conventional Commits, and a larger change with no body saying why it exists. |
| [`pre-push`](.githooks/pre-push) | Deleting a remote ref, rewriting history (a force-push), and pushing directly to the default branch. It decides from the refs being pushed, not from the command text. |

### Owned here

The three hooks are this repository's own: Jarvis and Friday do not depend on
each other, in either direction
([history](./docs/history.md#git-hooks-maintained-here)). Nothing compares these files with
Friday's, and a fix made to Friday's hooks reaches this repository only if
someone ports it deliberately.

What keeps them honest is a behaviour test rather than a comparison.
[`tests/githooks.sh`](./tests/githooks.sh) runs each hook in a scratch
repository and checks what it refuses and what it accepts. The
[`CI`](.github/workflows/ci.yml) workflow runs it on every pull request, together with a check that each hook is still executable, because
git skips a hook that is not and lets the commit through.

```sh
bash ~/.Jarvis/tests/githooks.sh
```

### Why the push rules live here as well as on GitHub

A ruleset on `main` is active: it refuses deletion and non-fast-forward pushes
and requires a pull request, with no bypass actors
([history](./docs/history.md#push-rules-on-github-as-well)).

`pre-push` stays, for two reasons. It refuses at the moment of the push rather
than after a round trip, so an agent gets the reason instead of a rejected
ref. And it protects this clone even against a remote that has no rules —
a fork, a mirror, or a ruleset someone later relaxes. The server rule is the
one that cannot be skipped; the hook is the one that explains itself.

Either way the hook protects this clone only, which is why the three operations
it refuses are also written down as permanently agent-prohibited rather than
relying on the hook to be present.

### If a hook refuses something it should not

Do not reach for `--no-verify`; the [Claude Code guard](#claude-code-guard) refuses that flag.
A rule that is wrong should be fixed in the hook, with the reason recorded, or
the specific line marked with `secret-scan:allow` and justified where it
appears. That marker is per-line on purpose: there is no file-level or
directory-level opt-out.

## Claude Code guard

> **繁中摘要**：個人的 Claude Code 防護規則放在
> `.agents/claude-guard/guard.json`，由 `scripts/apply-claude-guard.sh`
> 用複製的方式合併進 `~/.claude/settings.json`，並安裝一支解析指令的
> PreToolUse hook；兩者都不靠 link，所以沒有 Jarvis 的機器上 session 仍有防護。使用者自己寫的規則會保留；guard 退役的規則會在
> 下次套用時移除。

[`guard.json`](./.agents/claude-guard/guard.json) holds the rules every Claude
Code session on this machine runs under, whichever repository it starts in:

| Block | What it does |
| --- | --- |
| `permissions.deny` | Refuses the permanently prohibited operations: force push, `reset --hard`, `clean`, discarding uncommitted work, deleting branches, tags and refs, recursive deletion, `git rm`, rewriting a remote, GitHub `DELETE`, and skipping hooks. Matched before anything else, in every mode. |
| `permissions.ask` | Prompts for the human-review checkpoints: merging, closing or reopening a pull request, approving one, `gh repo edit`, and pushing to `main` or `master`. |
| `autoMode.hard_deny`, `soft_deny` | The same rules for the auto-mode classifier, in prose, so spellings a pattern cannot see (`bash -c`, `git -C`, a script) are judged too. Both keep the built-in rules through `"$defaults"`. |
| `hooks.PreToolUse` | Runs [`bash-guard.py`](./.agents/claude-guard/bash-guard.py) on every Bash call. It parses the command rather than matching its text, so it sees through `git -C <dir>`, `-c` options, a path such as `/usr/bin/git`, `bash -c` and `eval`, `$(...)`, a heredoc fed to a shell, `env`, `xargs` and `timeout`, flag clusters such as `-an` and `-vrf`, and git aliases. It denies the same operations and asks at the same checkpoints, including a bare `git push` from the default branch, and it also asks before a push that may carry a tag (`--tags`, `--follow-tags`, `push.followTags`, or a refspec naming a tag), because a release tag is a checkpoint too. It fails closed: if it cannot start, the Bash call is blocked. |
| `disableBypassPermissionsMode` | Turns bypass mode off; in bypass mode no ask rule would prompt. |

Apply it, or check whether the settings already carry it:

```sh
~/.Jarvis/scripts/apply-claude-guard.sh          # merge, keeping a .guard-backup
~/.Jarvis/scripts/apply-claude-guard.sh --check  # exit 1 when it would change something
```

The script copies the rules into the settings file, and the hook to
`~/.claude/hooks/claude-guard.py`, rather than linking either here, so a
session keeps its guard on a machine where this repository is missing. It
keeps every rule the person wrote, including one that equals a guard rule,
and records in `~/.claude/claude-guard.applied.json` only the entries it
added itself. That record is how a rule removed from `guard.json`, or a whole
list the guard stops managing, leaves the settings on the next run. A
settings file that is not valid JSON is refused and left as it is, and so is
one that changes while the script runs.

For a push, the hook works out where it goes the way git would: the
`--repo` option, `pushRemote` and `pushDefault`, `pushurl`, `push.default`
and configured push refspecs, and the remote's own default branch. A push to
a repository in a scratch directory on this machine skips the checkpoint.
When the hook cannot tell where a push goes, because the directory, the
branch or the configuration is unknown, it asks.

What this does not do. The hook reads the command it is given, not a script
that command runs, and not a command a program builds at run time; in auto
mode the classifier is the layer for those, and it is not deterministic. It
reads `python -c`, `node -e` and similar code only for directory-tree deletion
and for strings that are themselves git, gh or rm commands. `git rm` is
refused outright, including `--cached`; to take a file back out of the index,
use `git restore --staged <path>`.

The tests run in sandboxes and never touch the real `~/.claude`. The first
covers the merge; the second is the hook's probe corpus, including every
spelling an independent review found getting past the text rules:

```sh
bash ~/.Jarvis/tests/claude-guard.sh
bash ~/.Jarvis/tests/bash-guard.sh
```

## Bridge status and limitations

[`sync-personal-skills.sh`](./sync-personal-skills.sh) is safely repeatable and
checks canonical-name presence and dangling entries rather than merely printing
success, because a hand-maintained bridge once left installed Skills on disk
yet invisible to Claude Code
([history](./docs/history.md#hand-maintained-bridge)). It ensures canonical names have existing
entries in each bridged tool and reports dangling non-reserved entries. It does not validate or
repair a live canonical-name entry that points at the wrong target, nor does it
prove Git-operation enforcement or each runtime's native skill-loader behavior.

Claude Code receives links in `~/.claude/skills/`. Codex receives links in
`${CODEX_HOME:-$HOME/.codex}/skills`; `.system` and `codex-primary-runtime`
remain tool-owned and the script skips them. Codex's installer documentation
and a Python listing tool support the destination and symlink convention, but
the compiled Codex runtime loader remains unverified.

Jarvis makes no claim about Claude's or Codex's runtime precedence between
personal, project, and built-in Skills. An owner's preference for a same-name
personal Skill is an ownership policy, not evidence of runtime precedence. A
live link is filesystem evidence, not proof that a particular prompt will load
a particular Skill.

What was observed natively on one Claude Code version, in a consumer
repository and a disposable fixture, is in
[history](./docs/history.md#claude-code-bridge-and-same-name-skills). It is what was seen, not
a precedence rule: the bridge reached a session rooted in another repository,
and on a same-name collision only one provider's Skill was listed, the
personal one over a project Skill and over a marketplace plugin. So a name can
have more than one provider here, and the losing Skill is invisible rather than
lower-priority. If a project needs its own version of a name that exists here,
rename one of them.

Gemini has no bridge created by this script. Its discovery and runtime behavior
are pending/unknown here; this README makes no Gemini enforcement claim.

## Two CLI behaviours to know

Avoid `npx skills add -y`: its non-interactive fan-out can create unrelated
agent directories in `$HOME`. Let it prompt or select only the intended agents.

Avoid a blanket `npx skills update -g`: upstream can remove Skills that are
still locally installed
([history](./docs/history.md#upstream-removed-installed-skills)). Use
`npx skills update -g <name>` only after checking that specific upstream Skill,
then review the diff. The existing global lock filename is
[`.agents/.skill-lock.json`](./.agents/.skill-lock.json); `skills-lock.json` is project scope. Missing
`agents/openai.yaml` descriptors are not, by themselves, a reason to reinstall.

## Troubleshooting

```sh
# Confirm the required canonical symlink and its resolved destination.
ls -ld ~/.agents ~/.Jarvis/.agents
readlink ~/.agents

# Ensure bridge directories and missing/dangling canonical-name links; report
# dangling non-reserved entries.
~/.Jarvis/sync-personal-skills.sh

# Show dangling bridge links without changing them.
find ~/.claude/skills -maxdepth 1 -type l ! -exec test -e {} \; -print
CODEX_SKILLS="${CODEX_HOME:-$HOME/.codex}/skills"
[ ! -d "$CODEX_SKILLS" ] || find "$CODEX_SKILLS" -maxdepth 1 -type l ! -exec test -e {} \; -print

# Show canonical names that determine bridge entry names.
find ~/.Jarvis/.agents/skills -mindepth 1 -maxdepth 2 -name SKILL.md -type f \
  -exec sed -n 's/^name:[[:space:]]*//p' {} \; | sort

# Inspect CLI provenance when jq is available.
jq -r '.skills | to_entries[] | "\(.key)\t\(.value.source)\t\(.value.skillPath)"' \
  ~/.Jarvis/.agents/.skill-lock.json | sort
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
