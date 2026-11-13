# Maintenance

> **中文摘要**：這份文件是日常維護手冊：新增、更新、移除與驗證 Skill，修復 `~/.agents` 衝突，
> 使用 Skills CLI 時要避開的兩個行為，以及 bridge 出問題時的疑難排解指令。

Adding, updating, removing and verifying Skills, the two behaviours of the Skills CLI to avoid, and what to run when the bridge misbehaves. Why the layout is what it is: [Architecture](./architecture.md).

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
[`.agents/.skill-lock.json`](../.agents/.skill-lock.json) for its source and verify that the named upstream
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

Running [`~/.Jarvis/sync-personal-skills.sh`](../sync-personal-skills.sh) is the normal bridge check. For a
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

## Two CLI behaviours to know

Avoid `npx skills add -y`: its non-interactive fan-out can create unrelated
agent directories in `$HOME`. Let it prompt or select only the intended agents.

Avoid a blanket `npx skills update -g`: upstream can remove Skills that are
still locally installed
([history](./history.md#upstream-removed-installed-skills)). Use
`npx skills update -g <name>` only after checking that specific upstream Skill,
then review the diff. That command cannot move an entry whose `ref` is a commit SHA: it fetches the
pinned commit, finds nothing newer and reports "up to date" (seen with `skills`
1.8.1 on 2026-11-13, for the two `stablyai/orca` Skills). For such an entry,
re-add the named Skills from their source, `npx skills add <source> -g --skill
<name>`, and check afterwards which agent directories it wrote to: run from
inside an agent session it installs without asking. The existing global lock filename is
[`.agents/.skill-lock.json`](../.agents/.skill-lock.json); `skills-lock.json` is project scope. Missing
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
