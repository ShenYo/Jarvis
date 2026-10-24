# Dispatch policy

> **中文摘要**：派工的完整規則。三個 role（Commander、Implementer、Worker）、
> brief 三要素、回報格式、檔案所有權與升降級。personal instructions 的
> 「Hand work to cheaper models」是短版且優先；哪些工作需要獨立驗證由各
> repository 自己決定，不在這裡。

The short rule is in the personal instructions, under Base behavior: "Hand
work to cheaper models, and verify it here". It decides when to dispatch and,
for Claude Code, which model does what. This file adds what a dispatch needs
beyond it. Where the two disagree, the personal instructions win.

A repository's own rules decide which of its work needs independent
verification. This file decides only how that work is handed out and checked.

## Roles

| Role | Owns | Does not own |
| --- | --- | --- |
| Commander | Task framing, decisions, dependency order, integration, user communication | Bulk execution, or certifying its own work |
| Implementer | Bounded feature, fix, refactor, review or synthesis work | Task-wide policy, or edits that overlap another assignee's |
| Worker | Search, exact mechanical work, focused checks, read-back verification | Ambiguous design decisions, or broad implementation |

The Commander is the main session. In Claude Code, the rows of the personal
instructions' model table carry the other roles: a Worker is the lookup row or
the mechanical row, an Implementer is the mechanical row when the change is
already specified and the main session when it still needs design, and a fresh
verifier is the independent-review row. In Codex, [`codex.md`](./codex.md)
names the models. A tool with no separate execution facility keeps the
role boundaries by using a bounded, fresh execution context.

## The brief

Every dispatch carries all three:

1. **Goal and why**: one to three sentences, with the motivation the assignee
   needs for small decisions nobody anticipated.
2. **Acceptance criteria**: observable statements the assignee must
   demonstrate in its report.
3. **Report format**: maximum length, required structure, and the report
   contract below.

Start from the task-shaped briefs in
[`prompt-templates.md`](./prompt-templates.md).

## Report contract

Paste this into every brief:

- Return conclusions and `file:line` references; omit process narration and
  file dumps.
- When an authorized task needs an artifact over about 30 lines, put it in its
  proper file and return the path; report length never authorizes a write.
- End with exactly one of: `DONE`; `BLOCKED:` followed by the exact blocker;
  or `UNVERIFIED:` followed by what could not be checked and why.

## Workspace ownership

Before dispatch, give each writer its exact editable paths and its read-only
context paths. Parallel work is allowed only when editable paths do not
overlap. Assignees edit the named originals in the shared workspace, never a
parallel copy or an isolated version unless the task asks for one. An assignee
that finds an ownership overlap stops and reports `BLOCKED` instead of
editing. The Commander integrates the results.

## Escalation and de-escalation

- A subtask comes back wrong or `BLOCKED` once: send it again with the failure
  evidence, to an Implementer if a Worker had it.
- It comes back wrong or `BLOCKED` a second time: the Commander takes it over,
  with the complete trail of attempts, errors and diffs, and re-derives the
  approach rather than retrying it. Two rejected verifications, a
  specification that keeps moving, or a high-risk decision bring the work back
  to the Commander the same way.
- The Commander cannot solve it either: ask the user. In Claude Code, the
  question is whether to escalate to `fable`; never dispatch `fable` unasked.
- Once a hard case yields an exact pattern, hand the repetition back to a
  Worker; a solved pattern does not need a costlier role.

A repository's own rules may add escalation triggers or stop-and-ask
conditions; follow them as well.

## Fresh verification

Work is never certified by the context that produced it. When a repository's
rules require independent verification, dispatch a fresh verifier that did not
write the work. It receives the acceptance criteria and the diff, not the
author's narrative, and it reports actual command output; an applicable check
it did not run is `UNVERIFIED`.
