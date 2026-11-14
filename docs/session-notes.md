# Session notes

> **中文摘要**：context 越大，每次 request 讀 cache 的成本越高；離開超過 cache 的存活時間再回來，還要把整段 context 重寫一次。所以在自然段落壓縮比較划算，但壓縮會丟掉細節。
>
> `session-notes` skill 會在壓縮前把 session 的工作狀態寫進專案的 `docs/temp/session-notes/<session id>.md`，每次都改寫同一個檔案。Claude Code 的兩個 hook 讓這件事半自動：context 超過 300k 時提醒 agent 在段落點更新筆記並建議 `/compact`，壓縮後再提醒 agent 先讀筆記。
>
> 筆記只給同一個 session 在壓縮後讀，不是新 session 的入口；跨 session 的接手另寫以 task 命名的 handoff，放在 `docs/temp/handoff/<task>.md`，複製所需內容而不連結筆記，決策與待辦則留在 GitHub issue 與 PR。

Compacting a long session saves tokens, but the summary drops detail. The
[`session-notes`](../.agents/skills/session-notes/SKILL.md) Skill keeps that
detail in one file per session, and two Claude Code hooks tell the agent when to
update it and when to read it back.

## Why compact at a boundary

Every request reads the whole context from the prompt cache. A cache read is
cheap per token, but its cost grows with the context. A context left idle longer
than the cache's lifetime is written again in full, at more than the input
price: 1.25 times it for a five-minute cache and twice it for a one-hour cache,
the lifetime Claude Code sessions here run with. Past about 300k tokens, compacting at a natural
boundary costs less than carrying on.

Mid-task, a compaction costs more than it saves: the agent has to read files and
query state again. The boundary is the moment when the work is committed and
pushed, no agent or background task is running, and nothing is half-done. A
long pause is the best boundary: compact before stepping away for more than an
hour.

## The notes file

The Skill writes `docs/temp/session-notes/<session id>.md`, in the repository
the session started in. Every run revises that file into the current state:
goal, standing instructions, decisions, state, open items, lessons, and a log of
what finished. It links issues, pull requests and documents rather than copying
them.

The Skill writes only where Git ignores the path. Jarvis ignores `docs/temp/`.
In a repository that does not, the Skill writes nothing and says so; whether to
ignore `docs/temp/` is that repository's decision.

## The hooks

[`apply-claude-guard.sh`](../scripts/apply-claude-guard.sh) installs
[`session-notes.py`](../.agents/claude-guard/session-notes.py) as
`~/.claude/hooks/jarvis-session-notes.py`, along with the guard, and registers
it for two events:

| Event | What the agent is told |
| --- | --- |
| `UserPromptSubmit`, once the context passes 300k tokens | How large the context is, and how old the notes are. At the next boundary it updates the notes and suggests `/compact`. Mid-task, it carries on. |
| `SessionStart` after a compaction | Where the notes are, so it reads them before continuing. |

The hook reads the context size from the end of the session's transcript. It
only advises: on any error it says nothing, and the prompt goes through.

Only the owner can run `/compact`. Auto-compact does not run the Skill; it fires
near the auto-compact window, long after the hint.

## Notes and handoffs

A handoff and the session notes are different documents for different readers:

| | Session notes | Handoff |
| --- | --- | --- |
| Bound to | One session (the session id is the file name) | One task, across sessions and agents |
| Reader | The same session after a compaction | A new session or agent |
| Lifetime | Useful only within the session | Until the task is done |

The notes are never the entry point for a new session. They stay in
`docs/temp/session-notes/<session id>.md`, where the Skill and the hooks expect
them. Handing a session's notes to a new session, still named by session id,
mixes the two: the reader gets a session's working state, not the task's.

Any cross-session continuation gets a handoff named by task, at
`docs/temp/handoff/<task>.md` in the repository the task belongs to. It draws
on the notes but copies what it needs instead of linking them, so it survives
the notes being deleted, and a link by absolute path would carry the home
directory's name and work only on this machine. This location overrides the
[handoff Skill](../.agents/skills/handoff/SKILL.md)'s default of the OS
temporary directory, which a reboot may clear, and copying from the notes
overrides that Skill's advice to reference other artifacts by path. A Friday
consumer keeps its own per-worktree convention.

Where exactly it goes, and when to ask first:

- **The main worktree.** The file sits under the root of the repository's main
  worktree, so a session in any worktree of that repository finds the same
  file. That root is what
  `git rev-parse --path-format=absolute --git-common-dir` prints, without its
  trailing `/.git`. If the write there is refused, as a sandbox may do from a
  linked worktree, ask the user. The file is not in Git: a handoff for another
  clone or another machine is sent there, it does not travel with a push.
- **Only where Git ignores it.** Run
  `git -C <main root> check-ignore -q docs/temp/handoff/<task>.md` first; the
  path is read from that root, not from the directory you are in. If the path
  is not ignored, or the task belongs to no repository, ask the user where the
  handoff goes: an untracked file with a session's working state is one broad
  `git add` away from a commit.
- **A plain task name.** `<task>` is a short name of lowercase letters, digits
  and hyphens that you choose, never a path and never text taken as it came
  from an issue or a message.
- **One file per task.** A session that continues the task reads the existing
  handoff first and revises it. It does not write a second file, and it does
  not replace one it has not read.

Durable state, meaning decisions, open items and blockers, goes to GitHub
issues and pull requests, where every session and agent can read it. The
handoff summarises that state and points there; it does not become its only
home.

## Codex

Codex has no such hooks here. Invoke the Skill by hand before compacting. It
finds the session id in `$CODEX_THREAD_ID`.
