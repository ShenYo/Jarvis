# Review loop: a fresh reviewer before the owner's final check

> **中文摘要**：coding agent 開出 PR，或 owner 要求 review 時，先派一個沒參與實作、也沒繼承作者對話的 fresh reviewer agent 做初步 review。結果以機器帳號留成 PR comment，從不 Approve，也絕不以 owner 的帳號張貼。
>
> coding agent 逐條回應，最多來回 3 輪。之後留言交給 owner 做 final check，有未解決的分歧就一併列出。這套流程是最低要求：repository 自己的規則可以再多要求，但不能取消它。
>
> 機器帳號停權期間：fresh review 改在開 PR 前做，結果只留在對話裡，不貼到 GitHub、不啟用 auto-merge；外部 reviewer（如 Sourcery）的 comment 可以用 owner 帳號逐則回覆。

This loop runs when an agent opens a pull request, and when the owner asks an
agent to review one ("review #N"). It applies in every repository, in Claude
Code and in Codex. The design is in
[ShenYo/Jarvis#58](https://github.com/ShenYo/Jarvis/issues/58).

It is a floor. A repository's own rules may ask for more review, for example
an independent review before the PR opens, but they cannot remove this one.

The owner's approval stays the decision. Only the owner approves, as the code
owner. The reviewer's job is to make sure that, by the time the owner looks,
the obvious problems are already found and either fixed or argued.

## While the machine account is suspended

The machine account (`agent-claude-code`, [#13](https://github.com/ShenYo/Jarvis/issues/13)) is
suspended by GitHub, so nothing in this loop can be posted as it. Until it is restored:

- The fresh reviewer still runs, before the pull request is opened rather than after.
- Its findings and the coding agent's answers stay in the conversation with the owner. Do not post
  them to GitHub: under the owner's account they would read as the owner's own review.
- An external reviewer's comments (a bot such as Sourcery) may be answered as the owner, one reply
  per comment, saying what was changed or why not. That is a reply, not a review.
- Do not arm auto-merge; the owner merges.

When the account is restored, remove this section and run the loop as written below.

## Never as the owner

Every comment in this loop is posted through the machine account, never the
owner's. Before you post anything, run `gh api user -q .login`. If it prints
anything but the machine account's login, which is `$JARVIS_AGENT_IDENTITY` in
the agent's environment (for example `agent-claude-code`), or if it fails (a Codex sandbox has no
network, for example), stop. Post nothing, and tell the owner. Comments posted under the
owner's account would be indistinguishable from the owner's own words.

## When it runs

Run it for every pull request an agent opens, and whenever the owner asks for
a review. When the owner asks, the session dispatches a fresh reviewer, even for
a PR it did not write; it does not review the PR itself. Two kinds of PR are exempt:

- **A release PR** that only renames `## Unreleased` to a version.
- **A PR the owner asks to skip.** The owner names the PR.

Size the review to what the PR changes:

| The PR changes | The review includes |
| --- | --- |
| Code that runs: a guard, a hook, a script | Run the tests. Write mutants of the new code and report the ones that survive. Reproduce each risky scenario in a sandbox. |
| Only documentation | Every command and flag checked against its source. Every link and anchor resolved. Both language versions in parity where the repository has pairs. Nothing lost from moved text. |
| Configuration or rules | The change checked against every rule it touches. |

Whatever the row, check the PR against the repository's own rules: its
`AGENTS.md` and `docs/git.md`, and in a Friday consumer also the rules Friday
installs (`.agents/docs/`, among them the Git safety boundary).

## Who reviews

The reviewer must be a fresh agent. It must not have written the change, and it
must not inherit the author's conversation.

- **A PR opened from Claude Code:** dispatch an `opus` subagent that is not a
  fork, with the review brief in
  [`prompt-templates.md`](./prompt-templates.md#5-review-a-fresh-verifier-never-the-author).
- **A PR opened from Codex:** spawn a subagent with `fork_turns: "none"` and a
  self-contained brief, or run `codex exec --ephemeral`, using the model
  [`codex.md`](./codex.md) names for review. You can also ask the owner to have
  Claude Code review it.

In round 1 the reviewer gets the PR, its description and the issue, and nothing
of the author's reasoning. From round 2 on it also gets the previous round's
findings and the author's replies, as claims to check, not as evidence.

The reviewer never writes to the shared working tree. It runs tests, mutants
and probes in a throwaway copy that the brief names, for example a
`git archive` of the PR's head commit. It restores nothing because it changed
nothing, and leaves no process running.

## How it reports

The reviewer never approves and never requests changes. That holds even where a
repository's own rules would let a reviewing agent approve, because only the
owner's approval counts here. The coding agent posts the reviewer's report
**verbatim**, as one PR comment per round, through the machine account. It
puts its own replies in a separate comment, never under the reviewer's label.
The report looks like this:

```markdown
**Reviewer: fresh <runtime and model> (did not write this change)**: round <n> of 3

Verdict: NO OPEN FINDINGS | NEEDS WORK

| Severity | Where | Scenario → wrong outcome | Fix |
| --- | --- | --- | --- |
| blocking / should-fix / nit | `path:line` | … | … |

Surviving mutants: … (code changes only)
Not checked: … (why)
```

## How the coding agent responds

For every finding, before the next round, reply in the PR with one of these:

- **Fixed in `<commit>`**, with what changed, and the test or check that now
  fails without the fix.
- **Not taking this**, with the reason.

Push the fixes, then run the next round, giving the reviewer what
[Who reviews](#who-reviews) says.

Findings from other review bots, such as Sourcery, go through the same
treatment. Answer each finding in a review thread.

Then resolve the thread yourself, whether it was fixed or declined with a
reason. That covers threads opened by a reviewer agent or a bot. A thread the
owner opened is the owner's to resolve: answer it, and leave it. Leave any other
thread open only when it needs the owner's decision, and then mention the
owner in it (`@<owner>`) and say what has to be decided. The owner reads an open
thread as "this needs me".

## How it ends

Consensus is a round with no blocking or should-fix finding left open. Each
remaining nit is either fixed or explicitly declined.

Before posting, list the PR's review threads again, after your last push, since
a bot may have commented in the meantime:

```sh
gh api graphql -f query='query{repository(owner:"<owner>",name:"<repo>"){pullRequest(number:<pr>){reviewThreads(first:100){pageInfo{hasNextPage endCursor} nodes{isResolved path comments(first:1){nodes{author{login} url body}}}}}}}'
```

Every thread must be resolved except the owner's own and those left open for
the owner's decision. If `hasNextPage` is true, repeat it with
`reviewThreads(first:100,after:"<endCursor>")` until it is false. A ruleset
that requires conversation resolution blocks the merge, and an armed auto-merge
with it, until every thread is resolved. The coding agent then posts:

```markdown
**Ready for the owner's final check**

- Rounds: <n>. Fixed: <list>. Declined, with the reasons in the threads: <list>.
- Open disagreements: none | <list>. A disagreement from a review thread is also
  listed below; one from the reviewer's round comment links that comment.
- Threads left open for the owner, the owner's own included: none | <comment urls>.
- Not verified, and why: <list>.
```

Then, where the repository's own Git rules allow it, or
[`docs/git.md`](../git.md) where the repository has none, the coding agent arms
auto-merge with `gh pr merge <n> --auto --squash -R <owner/repo>`. That is only
where the base branch requires the code owner's approval; the guard verifies
it. In a Friday consumer, whose installed safety boundary keeps enabling
auto-merge a person's checkpoint, it never does.
It arms it even when a thread is left open for the owner: the merge then waits
until the owner resolves that thread, which the owner does when deciding.
Finally the coding agent tells the owner that the PR is ready for their review.

**If round 3 still leaves a blocking or should-fix finding open,** stop the loop.
Post the same comment with the disagreements listed, and give the decision to
the owner. Do not arm auto-merge, and do not run a fourth round unasked.

## What the owner does

The owner reads the "Ready" comment and the PR, then approves as **ShenYo** in a
browser signed in as ShenYo.

- If the coding agent armed auto-merge, the approval merges the PR once its
  checks pass ([ShenYo/Jarvis#56](https://github.com/ShenYo/Jarvis/issues/56)).
- Otherwise, the owner merges too.
