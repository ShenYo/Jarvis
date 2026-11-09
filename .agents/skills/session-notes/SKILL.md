---
name: session-notes
description: Save this session's working state to its notes file in the project's docs/temp, revising the same file each run, so a compaction keeps what matters. Use when the session-notes hook reports a large context and the work is at a boundary, or when the user is about to compact or step away.
---

# Session notes

Compaction keeps a summary and drops the rest. This skill writes what the
summary would lose into one notes file per session, which outlives every
compaction. Each run revises that file to the current state; it never starts a
second one.

## 1. Find the file

The file is `docs/temp/session-notes/<session id>.md`, under the root that
`git rev-parse --show-toplevel` prints in the directory the session started in.
The session id is `${CLAUDE_SESSION_ID}`. Where that still reads as a
placeholder, as in Codex, it is the shell's `$CODEX_THREAD_ID`. If neither gives
an id, write nothing and tell the user.

Run `git check-ignore -q <path>` from that root. If the path is not ignored, or
the session is not in a repository, write nothing and tell the user: whether
`docs/temp/` is ignored is the repository's decision.

Done when you have the path and Git ignores it.

## 2. Read what is there

If the file exists, read all of it. You are revising it, not appending to it.

## 3. Write the current state

```markdown
# Session notes: <topic in a few words>

> **中文摘要**：<two to four lines: what this session is doing and where it stands>

Updated <date and time>, session `<session id>`.

## Goal
## Standing instructions
## Decisions
## State
## Open
## Learned
## Done
```

| Section | Holds |
| --- | --- |
| Goal | What the user is after, and the current intent, in their words where the wording matters. |
| Standing instructions | Rules the user gave in this session that no file records, verbatim. A rule a file records gets a link instead. |
| Decisions | Each decision, why, and where it is recorded (issue, PR, document), or "only here". |
| State | Branches and worktrees, open pull requests, running agents and background tasks, what is mid-flight, and the exact next step. |
| Open | Pending work and questions waiting on the user, each with its owner. |
| Learned | What would be expensive to find again: gotchas, approaches that failed and why, facts verified, with the command that verified them. |
| Done | One line per finished item, with its link. |

How to revise:

- Link issues, pull requests, commits and documents rather than copying them.
  The notes carry what lives nowhere else.
- State and Open describe now. Rewrite them, and move what finished to Done.
- A decision, standing instruction or lesson stays until it stops holding.
- Leave out secrets and tokens.

Done when everything in progress in the conversation is in State or Open with
its next step, every decision the session made is in Decisions, and nothing in
State or Open has finished.

## 4. Hand over

Tell the user the path, and suggest they run `/compact` now: only they can.

After a compaction, when you need a detail the summary lacks, read this file
before looking for it anywhere else.
