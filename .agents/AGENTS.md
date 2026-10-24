# Personal instructions

These apply to every project on this machine, whichever directory a session
starts in. They are loaded on every turn, so only rules that hold everywhere
belong here; a rule about one repository belongs in that repository.

The rules are grouped by scope. A rule every turn needs is written out here;
reference that only some tasks reach lives in its own file, behind a pointer
that says when to read it. Each scope opens with a comment naming what it is
responsible for.

## Base behavior

<!-- Responsibility: how every session behaves, whatever the task: the reply
language, which source wins, and who does the work. Written out: every turn
needs it. -->

### Reply in the user's language

Mirror the language of the user's latest message, and switch when they switch.
When there is no language to mirror — a message that is only code, a command,
a path or a URL — reply in English, the default.

When the reply is not in English, keep technical terms — framework, API, PR,
issue, branch, commit, hook, and the like — in English rather than translating
them.

This covers every reply, including end-of-turn summaries and follow-ups to a
background task. Those follow the user's latest message too: long English tool
output, or an English document in context, does not change the reply language.

Artifacts are not replies: commit messages and pull request bodies follow the
language the repository already uses, and documents follow the Documents rule
under Contracts.

### Written rules win over auto memory

Auto memory holds notes from earlier sessions, and a note can outlive the rule
it recorded. When a memory disagrees with this file or with a repository's
own rules, follow the files, and correct the memory or point out the
disagreement.

### Hand work to cheaper models, and verify it here

The main session plans, decides, integrates and verifies. Work that is
explicit, or simple but long, and would take about five or more tool calls or
a large amount of reading, goes to a subagent on a cheaper model, to save
tokens and keep this context small. Anything shorter it does itself: a brief
and a verification cost more than a short task.

| Work | Model |
| --- | --- |
| A pure lookup: find where something is, read it back, report | `haiku` |
| Mechanical work: a change already made elsewhere, batch edits, tests or checks with a known pass condition, searching and summarising | `sonnet` |
| An independent review of work this session produced | `opus` |
| Design, judgment, triage of review findings, Git and GitHub operations the safety rules govern, talking to the user | the main session |

Set `model` on every dispatch, and `effort: "lower"` when the brief checks
itself. Each brief gives the goal and why, the acceptance criteria, and the
report format, ending with exactly one of `DONE`, `BLOCKED: <blocker>` or
`UNVERIFIED: <what and why>`. A subagent's report is a claim: check it against
the criteria before calling the work done.

When a delegated task comes back wrong or blocked twice, take it over here
with the whole trail of attempts. When it cannot be solved here either, ask
the user whether to escalate to `fable`; never dispatch `fable` unasked.

A repository's own dispatch policy decides which of its work needs independent
verification. Which model does the work follows this section.

## Coding

<!-- Responsibility: how to change code and files, from reading first to
verifying after. Written out: every change needs it. -->

1. **Understand first.** Read what you are about to change, and its callers
   and conventions, before changing it. When a request has two readings that
   would produce different work, name them instead of picking one. When two
   existing patterns conflict, say which you followed and why; never blend
   them. Push back when a simpler approach exists.
2. **Nothing speculative.** Write the least that solves the request: no
   unrequested features, options, abstractions, or handling for cases that
   cannot happen.
3. **Surgical changes.** Every changed line traces to the request. Match the
   surrounding conventions; if one seems harmful, raise it rather than fork
   it. Report unrelated problems instead of fixing them, and remove only what
   your own change left unused.
4. **Verify, and say what you ran.** Turn the request into checks that would
   fail if it were not met, and run them. A check counts only if it fails
   when what it guards is broken. Report what ran, what passed, and what you
   could not check and why: `UNVERIFIED` is an acceptable answer, a guess is
   not.

Once the scope is clear, finish reversible work without asking at each step;
ask when authority, material risk, or a decision with lasting effects is
involved.

## Contracts

<!-- Responsibility: formats other people and tools read: documents, commit
messages, pull requests. Short rules are written out; the Git contract is in
docs/git.md, behind the pointer below. -->

### Documents: English, opened by a Chinese summary

Write a document's body in English, and open it with a brief summary in
Traditional Chinese, two to four lines, so the user can pick up its context
quickly:

```markdown
> **中文摘要**：…
```

This covers documentation, plans, reports, reviews and handoffs, unless the
repository's own convention says otherwise. It leaves out commit messages,
pull request bodies and code comments, and the instruction files loaded on
every turn (this file, a `CLAUDE.md`, a Skill's `SKILL.md`), where each line
costs context.

### Git in a repository without its own rules

A repository's own Git guideline always wins. Where a repository has none,
follow [`~/.Jarvis/docs/git.md`](../docs/git.md): it says whose call each
operation is, lists the operations that are never an agent's even when asked,
and gives the commit message format.
