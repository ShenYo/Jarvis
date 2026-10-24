# Dispatch prompt templates

> **中文摘要**：五種任務型態（搜尋、實作、重構、研究、審查）的 brief 範本，
> 都內建三要素：目標與動機、驗收條件、回報格式。read-only 路徑與 review
> 檢查項目由各 repository 自己提供，填進對應的 slot。

Rules for use:

- Fill every `<slot>`. An unfilled slot means the brief is not ready.
- Choose the model and effort from the personal instructions' table in Claude
  Code, or from [`codex.md`](./codex.md) in Codex.
- Every brief ends with the closing block below.
- Paths are absolute or repository-relative, and real: check them before
  sending.
- Every brief that writes files also carries the read-only block.
- Make acceptance criteria constrain the work, not the data. For a code task,
  say what the code must do, not what production data must contain. For
  documentation, configuration or an authorized data correction, say what the
  intended content is and where its source of truth lives.

The closing block, appended to every brief:

```text
Report: conclusions + file:line only; when authorized, artifacts >30 lines go
to their proper file and return the path; report length never authorizes a
write. End with exactly one of DONE / BLOCKED: <the exact blocker> /
UNVERIFIED: <what wasn't checked, and why>.
```

The read-only block, appended to every brief that writes files:

```text
Read-only: <the repository's read-only paths: data, fixtures, specs, docs,
agent instructions>, except <paths this task may write, or "none">.
If a criterion seems to need an edit to a read-only path, the criterion is not
authorized: stop and report the scope conflict. Never change a production
fact, fixture, spec or page copy to make a check pass; an authorized fixture
update still tests the intended behaviour. Add no lint or type-check
suppression the task did not ask for. Read-only Git and GitHub inspection is
allowed; committing, pushing and changing GitHub follow the repository's Git
rules.
```

A criterion that constrains data invites the assignee to change the data. The
fix keeps the intent and moves the constraint onto the code:

```text
BAD:  All three order statuses appear in the order list.
GOOD: The order list renders each of the three order statuses correctly when
      given an order in that state (assert per status, with a fixture built in
      the test). The order data file is unchanged in the diff.
```

## 1. Search: Worker

```text
Question: <one specific question>
Why: <the decision this answer feeds>
Scope: <directories to search, and breadth: quick | medium | very thorough>
Acceptance criteria:
- Every claim cites file:line.
- Says "not found" when it is not found; no guessing.
<closing block>
```

## 2. Implementation: Implementer

```text
Goal and why: <what to build, and the requirement it serves>
Context to read first (only these): <specs, glossary, design docs>
Constraints: <the repository's rules that apply>; add tests for the stated
behaviour; use the glossary's terms.
Editable paths: <exact files or directories this assignee owns>
<read-only block>
Acceptance criteria:
- <observable behaviour, one line each>
- Tests exist and pass; paste the output of <test command>.
<closing block>
```

## 3. Refactor: Implementer

```text
Goal and why: <what structure changes and what it enables; behaviour must not
change>
Baseline: run <test/build command> before touching anything and paste the
output. If it fails at baseline, stop and report BLOCKED.
Scope: <exact files or directories>. Out of scope: <adjacent temptations>.
<read-only block>
Acceptance criteria:
- The same command passes afterwards; output pasted.
- The diff changes no behaviour: no new strings, endpoints or branches.
- Each commit-sized step is green on its own.
<closing block>
```

## 4. Research: Worker for facts, Implementer for synthesis

```text
Question: <the decision this research must inform>
Sources: <official docs first; allowed domains if it matters>
Acceptance criteria:
- Each fact is labelled CONFIRMED (with URL) or NOT FOUND, never inferred from
  memory.
- A recommendation section, kept apart from the facts, closes the report.
Max report length: <e.g. 40 lines>
<closing block>
```

## 5. Review: a fresh verifier, never the author

```text
Review target: <branch, diff or files>
You did not write this. Judge it only against the criteria below; the author's
narrative is not evidence.
Criteria:
- The original task's acceptance criteria: <paste them>
- The personal instructions' Coding rules: surgical changes, nothing
  speculative.
- Scope: unrelated changes are absent.
- <the repository's own review checks>
- Suppressions: grep the diff for lint and type-check suppressions; each one
  the task did not ask for is a blocking finding.
For each finding: file:line, severity, a one-sentence defect, and a concrete
failure scenario. End with a verdict: APPROVE, or NEEDS WORK with the blocking
items.
<closing block>
```
