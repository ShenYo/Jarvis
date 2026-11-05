# Architecture

> **中文摘要**：這份文件說明 Jarvis 的結構：`.agents/` 是唯一的 canonical copy，`~/.agents`
> 與 Claude Code／Codex 的 bridge 都是 symlink，所以沒有東西需要同步；也說明哪些內容由 CLI
> 管理、哪些由這裡自己維護，以及 bridge 能驗證與不能驗證的範圍。

How the repository is laid out, how the symlinks reach the tools, which content belongs to a CLI, and what the bridge does and does not prove. To install it, follow [Setting up a new machine](./setup-new-machine.md); to change it day to day, [Maintenance](./maintenance.md).

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

[`AGENTS.md`](../AGENTS.md) is where an agent is told what it may not touch
here: most Skills are vendored and belong to an upstream CLI, two of them
replace a project's own guards if run in the wrong place, and the Git hooks
are this repository's own. It keeps only the working rules specific to this
repository. The general ones, how any agent should work, are in the personal
instructions, so they apply in every session, not only here. The Git rules
are [`docs/git.md`](./git.md).

**Two files are called `AGENTS.md`, and they have different scopes.** The one
at the root is for an agent working *in this repository*. The one in
`.agents/` is for *every project*: [`.agents/AGENTS.md`](../.agents/AGENTS.md)
holds personal rules, such as replying in the user's language, and the bridge
links it as `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`, which Claude Code
and Codex load in every session wherever it starts. It exists
because a rule that lived only in project memory did not reach a session
started anywhere else
([history](./history.md#personal-instructions-for-every-project)). Reference it reaches only for some tasks
lives in its own file, behind a pointer: the dispatch policy, prompt templates
and Codex adapter are in [`docs/dispatch/`](./dispatch/policy.md).
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
([history](./history.md#skills-grouped-under-a-container)).

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
instead ([history](./history.md#a-deeper-codex-home)).

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
[`sync-personal-skills.sh`](../sync-personal-skills.sh) refuses to
run in that case and tells you to diff the two before choosing, rather than
quietly linking on top of the wrong one.

## CLI-managed and locally maintained content

[`.agents/.skill-lock.json`](../.agents/.skill-lock.json) records Skills installed by the Skills CLI, including
their source, path, hash, and timestamps. Treat those as third-party/
CLI-managed: do not casually patch their contents or rewrite the lock to make
an installation look different. A missing lock entry means the CLI did not
record that Skill; it does not make a canonical Skill invalid.

Every Skill here is CLI-managed. What is locally maintained is the bridge
script, the personal instructions, the Claude Code guard, the Git hooks and
their rules, and the README and these documents. The settings files themselves are not part of
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

## Bridge status and limitations

[`sync-personal-skills.sh`](../sync-personal-skills.sh) is safely repeatable and
checks canonical-name presence and dangling entries rather than merely printing
success, because a hand-maintained bridge once left installed Skills on disk
yet invisible to Claude Code
([history](./history.md#hand-maintained-bridge)). It ensures canonical names have existing
entries in each bridged tool and reports dangling non-reserved entries. It does not validate or
repair a live canonical-name entry that points at the wrong target, nor does it
prove Git-operation enforcement or each runtime's native skill-loader behavior.

Claude Code receives links in `~/.claude/skills/`. Codex receives links in
`${CODEX_HOME:-$HOME/.codex}/skills`; `.system` and `codex-primary-runtime`
remain tool-owned and the script skips them. Codex's installer documentation
and a Python listing tool support the destination and symlink convention. On
2026-11-04 one native `/skills` listing showed the Jarvis Writing for Agents
Skill twice, and a session read its linked `SKILL.md`; this confirms runtime
discovery for that sample. The app-server `skills/list` API showed separate worktree
`repo` and canonical `user` entries here, and only `user` entries outside Jarvis.
The duplicate menu entries are discovery scopes; the symlink bridge is preserved. This
does not verify precedence among personal, project and built-in Skills or the
full Skill Phase B.

Jarvis makes no claim about Claude's or Codex's runtime precedence between
personal, project, and built-in Skills. An owner's preference for a same-name
personal Skill is an ownership policy, not evidence of runtime precedence. A
live link is filesystem evidence, not proof that a particular prompt will load
a particular Skill.

What was observed natively on one Claude Code version, in a consumer
repository and a disposable fixture, is in
[history](./history.md#claude-code-bridge-and-same-name-skills). It is what was seen, not
a precedence rule: the bridge reached a session rooted in another repository,
and on a same-name collision only one provider's Skill was listed, the
personal one over a project Skill and over a marketplace plugin. So a name can
have more than one provider here, and the losing Skill is invisible rather than
lower-priority. If a project needs its own version of a name that exists here,
rename one of them.

Gemini has no bridge created by this script. Its discovery and runtime behavior
are pending/unknown here; these documents make no Gemini enforcement claim.
