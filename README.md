# Jarvis

**English** · [繁體中文](./README.zh-TW.md)

> **繁中摘要**：Jarvis 是這台機器的個人 AI agent Skills 版本庫。它讓
> `~/.Jarvis/.agents` 成為唯一 canonical copy，透過 `~/.agents` 與 Claude
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
| **Jarvis** | This machine's canonical personal Skills, bridge script, and personal Skill provenance; the personal instructions linked as `~/.claude/CLAUDE.md`; the [Claude Code guard](#claude-code-guard) it copies into `~/.claude/settings.json` | A project's `.agents/`, project policy, or any other personal setting |
| **Friday** | A reviewed shared baseline that a consumer may pin and adopt | This machine's personal catalog or a consumer's conflict resolution |
| **Consumer project** | Its `.agents/` seed, overlays, integrations, tests, and recorded Friday provenance | Jarvis's personal Skills or Friday's vendor payload |

A consumer project must build, test, and pass CI on a machine that has no
personal layer at all -- a CI runner or another person's laptop has no copy of
this repository. So whatever a project requires belongs in that project or in
the Friday baseline it adopted, never here. Jarvis can help an agent work on a
project; it must not become a hidden project dependency.

This constrains consumer projects, not Jarvis. Jarvis is expected to be present
on this machine, and an agent working here may rely on it.

## Current operating context

> **繁中摘要**：個人 Skills 是可選輔助，專案必需成果必須由專案自身的
> 文件、測試或自動化承載；Matt Pocock 等 vendor Skill 維持原廠更新路徑。相同
> 名稱的個人 Skill 優先只屬 owner policy，不能當作任何 runtime 的載入保證。

Jarvis remains the personal, optional layer; a project-required outcome must
live in project-controlled documentation, tests, or automation.
[TDD](./.agents/skills/tdd/), [Wayfinder](./.agents/skills/wayfinder/), and
comparable personal helpers may assist work, but their absence
must not block a consumer project.

Matt Pocock and other CLI-managed vendor Skills are updated only through their
owning CLI after reviewing the named upstream source. Do not patch their
vendored files to implement project setup or policy. When an optional external
tracker is available, its project output is defined by that project's contract:
resolve the Git root first, then use
`docs/temp/matt-pocock/<feature>/<unique-suffix>/`. If the optional capability,
repository root, or valid feature is unavailable, stop that optional workflow
rather than writing an alternative personal or vendor location.

An owner's preference for a same-name personal Skill is an ownership policy,
not evidence of runtime precedence. Jarvis makes no precedence claim beyond
the bridge limits below. Codex Skill Phase B as a whole remains **UNVERIFIED**;
do not infer completion from individual probes or bridge entries.

## Current inventory

**Inventory observation, 2026-10-22:** this checkout has 36 canonical
`SKILL.md` files, 36 Claude bridge links, 36 Codex bridge links, and 35 lock
entries. Every canonical Skill is reachable from both tools.

`orca-cli` and `orchestration` were briefly unreachable: the `skills` CLI
writes the canonical copy and the lock entry but does not create the bridge,
so a Skill it installs stays invisible to Claude Code and Codex until
[`sync-personal-skills.sh`](./sync-personal-skills.sh) runs. That is the
normal order of operations, not a fault -- install with the CLI, then bridge.

A `synced` entry also sits in the Claude bridge directory. It is a real
directory rather than a symlink, so it belongs to another tool and the bridge
script deliberately leaves it alone. [`setup-project-agents`](./.agents/skills/setup-project-agents/) is
the canonical Skill without a lock entry.
These are observations, not enduring facts; recount rather than treating this
README as a cache:

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
conflict with the Friday baseline, and the hooks are copies. Its working rules
are **this repository's own**, written there rather than borrowed, because
basic discipline should not depend on another repository. The exception is the
Git rules, which come with the hooks: those are byte-identical copies of
Friday's, so the rules they enforce are Friday's text and change when the hooks
change.

**Two files are called `AGENTS.md`, and they have different scopes.** The one
at the root is for an agent working *in this repository*. The one in
`.agents/` is for *every project*: [`.agents/AGENTS.md`](./.agents/AGENTS.md)
holds personal rules, such as replying in the user's language, and the bridge
links it as `~/.claude/CLAUDE.md`, which Claude Code loads in every session
wherever it starts. Before it existed, the language rule lived only in two
projects' auto memory, so a session started anywhere else replied in English.
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
because pet_care groups its four git skills that way, and a script that assumed
one directory per skill both linked the unloadable container and hid the real
skills inside.

## The symlink chain

```
~/.agents                 -> .Jarvis/.agents
~/.claude/skills/<name>   -> ../../.agents/skills/<name>
${CODEX_HOME:-$HOME/.codex}/skills/<name>
                           -> ../../.agents/skills/<name>
~/.claude/CLAUDE.md       -> ../.agents/AGENTS.md
```

Two hops, and the second one matters: `~/.claude/skills/<name>` resolves
`../../` to `~/`, so it goes through `~/.agents` rather than pointing at this
repo directly. That is deliberate — `~/.agents` is the stable address, while
the bridge script requires this repository to be cloned at `~/.Jarvis`.

The `../../` above is the count for a bridge directory two levels below `~`,
which is where both defaults sit. The script computes the count rather than
assuming it, so a `CODEX_HOME` at any other depth gets the right number of
hops, and one outside `$HOME` gets an absolute path through `~/.agents`
instead. Assuming two used to leave every Codex link dangling for a deeper
`CODEX_HOME`.

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

For a new project, bootstrap the portable baseline from a separately reviewed,
clean Friday checkout; do not copy Jarvis Skills into the project. The optional
[`setup-project-agents`](./.agents/skills/setup-project-agents/) Skill under
`~/.agents` is a convenience wrapper for a
blank-project Friday adoption, not a prerequisite for this manual workflow or
for any consumer project.

The script also links `~/.claude/CLAUDE.md` to the personal instructions in
`.agents/AGENTS.md`. It creates that link when it is missing and replaces it when
it dangles. It refuses, and changes nothing, when `~/.claude/CLAUDE.md` is a real
file, because that file holds instructions someone wrote, or a live link
elsewhere, because that link was put there on purpose. To adopt the link on a
machine that already has a `~/.claude/CLAUDE.md`, move what it should keep into
`.agents/AGENTS.md`, remove it, and run the script again.

The script creates `~/.agents` if it is missing, ensures the Claude bridge
directory exists, and creates or replaces a canonical-name entry only when it
is missing or dangling. It bridges Codex when
`${CODEX_HOME:-$HOME/.codex}` exists, creating `skills/` under it if needed: a
fresh Codex install has the home but has never created that subdirectory, so
testing for the subdirectory instead left Codex with no Skills at all while
reporting it as not installed. An absent Codex home is skipped rather than
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

## Friday adoption wrapper

[`setup-matt-pocock-skills`](./.agents/skills/setup-matt-pocock-skills/) is
third-party/CLI-managed. **Do not modify it for
project setup.** Use the locally maintained
[`setup-project-agents`](./.agents/skills/setup-project-agents/) wrapper
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

[`.agents/.skill-lock.json`](./.agents/.skill-lock.json) records Skills installed by the Skills CLI, including
their source, path, hash, and timestamps. Treat those as third-party/
CLI-managed: do not casually patch their contents or rewrite the lock to make
an installation look different. A missing lock entry means the CLI did not
record that Skill; it does not make a canonical Skill invalid.

Jarvis's bridge script, this README, and
[`setup-project-agents`](./.agents/skills/setup-project-agents/) are locally
maintained. Personal settings are intentionally excluded:
`~/.claude/settings.json` and `~/.codex/config.toml` may contain local paths
or secrets and are not part of this repository.

## Local Git hooks

`core.hooksPath` points at [`.githooks/`](.githooks), so this clone runs three
commit-time and push-time checks. They are a guard against mistakes, not a
server-side control: `core.hooksPath` is per-clone configuration that is never
cloned, so a fresh clone of this repository runs none of them until someone
sets it again.

| Hook | Refuses |
| --- | --- |
| [`pre-commit`](.githooks/pre-commit) | A staged diff whose added lines look like a credential, key, token, password or connection string. It names the rule and the file, never the matched value. |
| [`commit-msg`](.githooks/commit-msg) | A subject that is not Conventional Commits, and a larger change with no body saying why it exists. |
| [`pre-push`](.githooks/pre-push) | Deleting a remote ref, rewriting history (a force-push), and pushing directly to the default branch. It decides from the refs being pushed, not from the command text. |

All three are copies of files this platform's sibling repository ships to its
consumers, at `payload/.agents/githooks/` in
[Friday](https://github.com/ShenYo/Friday). This repository is not a Friday
payload consumer — its `.agents/` holds personal Skills, not Friday's payload
— so `install.sh` cannot wire it
and the hooks are copied instead. Each is now **byte-identical** to its payload
counterpart, including `pre-push`: the hooks resolve the guideline path at run
time rather than hard-coding it, which is what removed the last intended
difference. So

```sh
for h in pre-commit commit-msg pre-push; do
  diff ~/.Friday/payload/.agents/githooks/$h .githooks/$h
done
```

should print nothing at all, and anything it does print is drift.

### `hooks.json`

The three hooks above are copies, so something has to notice when one drifts.
`hooks.json` records the sha256 of each, in the layout `sha256sum -c` reads,
and [`.github/workflows/hooks-drift.yml`](.github/workflows/hooks-drift.yml)
checks them on change and once a day. No Friday checkout and no cross-repository
token: the record is self-contained.

**This repository is not a Friday consumer, and the two are not bound
together.** Friday's payload is nineteen files; this repository takes **three
of them** — the hooks above — and nothing else: none of Friday's `.agents/`
payload or documentation, no `.claude/settings.json`. The `.agents/` here is
this repository's own, holding the personal Skills and instructions. Its own
[`AGENTS.md`](./AGENTS.md) is locally written and states its own working rules;
it links Friday only for the rules those three hooks enforce, which are
Friday's by construction. Friday depends on this repository for nothing in
return. The two are maintained separately and serve different
audiences: this one is personal scope, Friday is project scope.

That is why the file carries no `friday-` prefix. It is named for the only
thing it is — a record of the hooks this repository keeps. A *consumer* carries
`.friday-lock.json` instead; the two never appear together, and `friday-lock`
refuses a repository holding both.

It exists because the alternative failed. When Friday's `pre-push` changed, the
copy here was missed — along with the copy in Friday itself — and nothing
reported either. Keeping mirrors in step was a manual step, and manual steps
get skipped.

A drift here is repaired with a copy, or, if Friday's payload is what moved,
carried properly:

```sh
bash ~/.Friday/bin/friday-propagate ~/.Jarvis
```

### Why the push rules live here as well as on GitHub

They used to live here *instead*: rulesets need a paid plan for a private
repository, and this one was private on the free plan. It is public now, so a
ruleset on `main` is active — it refuses deletion and non-fast-forward pushes
and requires a pull request, with no bypass actors.

`pre-push` stays, for two reasons. It refuses at the moment of the push rather
than after a round trip, so an agent gets the reason instead of a rejected
ref. And it protects this clone even against a remote that has no rules —
a fork, a mirror, or a ruleset someone later relaxes. The server rule is the
one that cannot be skipped; the hook is the one that explains itself.

Either way the hook protects this clone only, which is why the three operations
it refuses are also written down as permanently agent-prohibited rather than
relying on the hook to be present.

### If a hook refuses something it should not

Do not reach for `--no-verify`; the collaborative Git guard refuses that flag.
A rule that is wrong should be fixed in the hook, with the reason recorded, or
the specific line marked with `secret-scan:allow` and justified where it
appears. That marker is per-line on purpose: there is no file-level or
directory-level opt-out.

## Claude Code guard

> **繁中摘要**：個人的 Claude Code 防護規則放在
> `.agents/claude-guard/guard.json`，由 `scripts/apply-claude-guard.sh`
> 用複製的方式合併進 `~/.claude/settings.json`，不靠 link，所以沒有 Jarvis
> 的機器上 session 仍有防護。使用者自己寫的規則會保留；guard 退役的規則會在
> 下次套用時移除。

[`guard.json`](./.agents/claude-guard/guard.json) holds the rules every Claude
Code session on this machine runs under, whichever repository it starts in:

| Block | What it does |
| --- | --- |
| `permissions.deny` | Refuses the permanently prohibited operations: force push, `reset --hard`, `clean`, discarding uncommitted work, deleting branches, tags and refs, recursive deletion, `git rm`, rewriting a remote, GitHub `DELETE`, and skipping hooks. Matched before anything else, in every mode. |
| `permissions.ask` | Prompts for the human-review checkpoints: merging, closing or reopening a pull request, approving one, `gh repo edit`, and pushing to `main` or `master`. |
| `autoMode.hard_deny`, `soft_deny` | The same rules for the auto-mode classifier, in prose, so spellings a pattern cannot see (`bash -c`, `git -C`, a script) are judged too. Both keep the built-in rules through `"$defaults"`. |
| `disableBypassPermissionsMode` | Turns bypass mode off; in bypass mode no ask rule would prompt. |

Apply it, or check whether the settings already carry it:

```sh
~/.Jarvis/scripts/apply-claude-guard.sh          # merge, keeping a .guard-backup
~/.Jarvis/scripts/apply-claude-guard.sh --check  # exit 1 when it would change something
```

The script copies the rules into the settings file rather than linking it
here, so a session keeps its guard on a machine where this repository is
missing. It keeps every rule the person wrote, including one that equals a
guard rule, and records in `~/.claude/claude-guard.applied.json` only the
entries it added itself. That record is how a rule removed from `guard.json`,
or a whole list the guard stops managing, leaves the settings on the next run.
A settings file that is not valid JSON is refused and left as it is, and so
is one that changes while the script runs.

What this does not do. A deny rule matches the command text, so `bash -c`,
`git -C <dir>` and a script reach a prohibited operation without matching it;
in auto mode the classifier is the layer that catches those, and it is not
deterministic. The built-in auto-mode allow rule for pushes outranks
`soft_deny`, so a bare `git push` from `main` is caught by a `pre-push` hook
where one is installed, and by nothing otherwise. `git rm` is refused
outright, including `--cached`; to take a file back out of the index, use
`git restore --staged <path>`.

The tests run each case in a sandbox `CLAUDE_CONFIG_DIR`:

```sh
bash ~/.Jarvis/tests/claude-guard.sh
```

## Historical context

The bridge was hand-maintained before 2026-09-07, and installed Skills could be
present on disk yet invisible to Claude Code. That incident is why the bridge
is safely repeatable and checks canonical-name presence and dangling entries
rather than merely printing success.

## Bridge status and limitations

[`sync-personal-skills.sh`](./sync-personal-skills.sh) ensures canonical names have existing entries in each
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

Three things were observed natively on **Claude Code 2.1.306** (2026-10-22), in
a consumer repository and a disposable fixture. They do not turn the paragraph
above into a precedence rule; they are what was seen.

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

Gemini has no bridge created by this script. Its discovery and runtime behavior
are pending/unknown here; this README makes no Gemini enforcement claim.

## Two CLI behaviours to know

Avoid `npx skills add -y`: its non-interactive fan-out can create unrelated
agent directories in `$HOME`. Let it prompt or select only the intended agents.

Avoid a blanket `npx skills update -g`: a 2026-09-07 audit found that upstream
had removed Skills that were still locally installed. Use
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
- `~/.claude/skills-backup-2026-08-04/` — a manual backup from before this
  repo existed, deleted on 2026-09-07 after all nine of its skills were
  verified byte-identical to the tracked copies. Git is the backup now.
