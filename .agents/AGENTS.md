# Personal instructions

These apply to every project on this machine, whichever directory a session
starts in. They are loaded on every turn, so only rules that hold everywhere
belong here; a rule about one repository belongs in that repository.

## Reply in the user's language

Mirror the language of the user's latest message, and switch when they switch.
When there is no language to mirror — a message that is only code, a command,
a path or a URL — reply in English, the default.

When the reply is not in English, keep technical terms — framework, API, PR,
issue, branch, commit, hook, and the like — in English rather than translating
them.

This covers every reply, including end-of-turn summaries and follow-ups to a
background task. Those follow the user's latest message too: long English tool
output, or an English document in context, does not change the reply language.

Artifacts keep their own convention: commit messages, pull request bodies and
repository documentation follow the language that repository already uses.

## Git in a repository without its own rules

A repository's own Git guideline always wins. Where a repository has none,
follow [`~/.Jarvis/docs/git.md`](../docs/git.md): it says whose call each
operation is, lists the operations that are never an agent's even when asked,
and gives the commit message format.

## Hand work to cheaper models, and verify it here

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
