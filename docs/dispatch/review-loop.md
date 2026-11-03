# Review loop: a fresh reviewer before the owner's final check

> **中文摘要**：coding agent 開出 PR 之後，先派一個沒參與實作的 fresh reviewer agent 做初步 review，結果以機器帳號留成 PR comment，不能 Approve。coding agent 逐條處理意見，最多來回 3 輪。雙方有共識後，coding agent 留言「可以進行 final check」並通知 owner；如果 3 輪後仍有分歧，就列出分歧交給 owner 決定。最後由 owner 以 ShenYo 做 final check 並 Approve。

This loop runs after an agent opens a pull request and before the owner is asked
to review it. It applies in every repository, Claude Code and Codex alike. The
design is in [ShenYo/Jarvis#58](https://github.com/ShenYo/Jarvis/issues/58).

The owner's Approve stays the decision. The reviewer's job is to make sure that,
by the time the owner looks, the obvious problems are already found and either
fixed or argued.

## When it runs

Run it on every pull request an agent opens. Two kinds of PR are exempt:

- **A release PR** that only renames `## Unreleased` to a version.
- **A PR the owner asks to skip.** The owner names the PR.

Size the review to what the PR changes:

| The PR changes | The review includes |
| --- | --- |
| Code that runs: a guard, a hook, a script | Run the tests. Write mutants of the new code and report the ones that survive. Reproduce each risky scenario in a sandbox. |
| Only documentation | Every command and flag checked against its source. Every link and anchor resolved. Both language versions in parity where the repository has pairs. Nothing lost from moved text. |
| Configuration or rules | Check the change against the repository's own rules (`AGENTS.md`, `docs/git.md` or the payload's safety boundary), and check every rule that change touches. |

## Who reviews

The reviewer must be a fresh agent that did not write the change and is not
given the author's reasoning, beyond the PR description and the issue.

- **A PR opened from Claude Code:** dispatch an `opus` subagent with the review
  brief in [`prompt-templates.md`](./prompt-templates.md#5-review-a-fresh-verifier-never-the-author).
- **A PR opened from Codex:** spawn a fresh Codex subagent
  ([`codex.md`](./codex.md)), or ask the owner to have Claude Code review it.

The reviewer works read-only. It runs tests and probes only in sandboxes,
restores every mutation, and leaves no process running.

## How it reports

The reviewer never approves and never requests changes. The PR author and the
reviewer act through the same machine account, and the owner's Approve is the
only one that counts. The coding agent posts the reviewer's result as **one PR
comment** per round:

```markdown
**Reviewer: fresh <runtime and model> (did not write this change)**: round <n> of 3

Verdict: APPROVE | NEEDS WORK

| Severity | Where | Scenario → wrong outcome | Fix |
| --- | --- | --- | --- |
| blocking / should-fix / nit | `path:line` | … | … |

Surviving mutants: …
Not checked: … (why)
```

## How the coding agent responds

For every finding, before the next round, reply in the PR with one of these:

- **Fixed in `<commit>`**, with what changed and the test that now fails
  without it.
- **Not taking this**, with the reason.

Push the fixes, and then run the next round. Hand the next reviewer the
findings and replies of the previous round, so it checks that each one is
closed, rather than starting over.

Comments from other bots, such as Sourcery, go through the same treatment:
reply to each, then resolve the thread.

## How it ends

Consensus is a round with no blocking or should-fix finding left open. Each
remaining nit is either fixed or explicitly declined. The coding agent then
posts:

```markdown
**Ready for the owner's final check**

- Rounds: <n>. Fixed: <list>. Declined, with the reasons in the threads: <list>.
- Open disagreements: none | <list>.
- Not verified, and why: <list>.
```

It then tells the owner the PR is ready for their review.

**If round 3 still leaves a blocking or should-fix finding open,** stop the loop.
Post the same comment, with the disagreements listed, and give the decision to
the owner. Do not run a fourth round unasked.

## What the owner does

The owner reads the "Ready" comment and the PR, then approves as **ShenYo** in a
browser signed in as ShenYo. Where auto-merge is enforced (#56), that approval
merges the PR. Everywhere else, the owner also merges.
