# Session notes

> **中文摘要**：context 越大，每次 request 讀 cache 的成本越高；離開超過 cache 的存活時間再回來，還要把整段 context 重寫一次。所以在自然段落壓縮比較划算，但壓縮會丟掉細節。
>
> `session-notes` skill 會在壓縮前把 session 的工作狀態寫進專案的 `docs/temp/session-notes/<session id>.md`，每次都改寫同一個檔案。Claude Code 的兩個 hook 讓這件事半自動：context 超過 300k 時提醒 agent 在段落點更新筆記並建議 `/compact`，壓縮後再提醒 agent 先讀筆記。

Compacting a long session saves tokens, but the summary drops detail. The
[`session-notes`](../.agents/skills/session-notes/SKILL.md) Skill keeps that
detail in one file per session, and two Claude Code hooks tell the agent when to
update it and when to read it back.

## Why compact at a boundary

Every request reads the whole context from the prompt cache. A cache read is
cheap per token, but its cost grows with the context. A context left idle longer
than the cache's lifetime (one hour for Claude Code) is written again in full,
at twice the input price. Past about 300k tokens, compacting at a natural
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

## Codex

Codex has no such hooks here. Invoke the Skill by hand before compacting. It
finds the session id in `$CODEX_THREAD_ID`.
