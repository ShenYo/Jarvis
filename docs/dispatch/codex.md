# Codex adapter

> **中文摘要**：Codex 派工時的 model 對應與協作工具用法。Commander 用
> `gpt-6.1-sol`，Implementer 與 Worker 用 `gpt-6-luna`；2026-10-25 這兩個在
> 本機帳號（ChatGPT 登入）仍被拒絕，開放前派工會失敗。子代理直接在共享
> workspace 改各自指定的檔案，範圍不可重疊。

This adapter makes [`policy.md`](./policy.md) executable in Codex. The policy
owns the roles, the brief, the report contract and escalation; this file only
says which Codex model and tool carries each.

## Role routing

| Role | Codex model | Responsibility | Effort |
| --- | --- | --- | --- |
| Commander | `gpt-6.1-sol` | Root analysis, planning, architecture, integration, user communication | high; xhigh for genuine escalation |
| Implementer | `gpt-6-luna` | Features, fixes, refactors and tests | medium; high for cross-file invariants |
| Worker | `gpt-6-luna` | Search, exact mechanical edits, deterministic fresh checks | low; medium for bounded edits or checks |

These are the owner's choice, and both are in OpenAI's Codex model list. **On
2026-10-25 neither ran on this machine** (codex-cli 0.153.4, ChatGPT sign-in):
both were refused with "not supported when using Codex with a ChatGPT
account", and `~/.codex/models_cache.json` listed only `gpt-6-astra` and the
`gpt-5.6-*` models. Until they run, a dispatch that names them fails. When the
cache lists them, run `codex exec -m <model> "Reply with exactly: OK"` once
for each and delete this paragraph.

The Commander is the interactive session, so its model is the `model` in
`~/.codex/config.toml`, not this table. On 2026-10-25 that was `gpt-5.6-sol`,
and it stays there until `gpt-6.1-sol` runs: setting an unsupported model
there would stop every interactive session from starting.

## Native collaboration

`gpt-6-astra` reported these from its tool definitions on 2026-10-25, twice:

- Children are started with `collaboration.spawn_agent`, which takes
  `task_name`, `message`, `model`, `reasoning_effort` and `fork_turns`.
- A `model` or `reasoning_effort` override needs `fork_turns` set to `"none"`
  (for a self-contained brief) or a positive count of turns; its default,
  `"all"`, does not allow one. Use the smallest count that carries the context
  needed.
- Four agents may be active at once, the root included, so the Commander runs
  at most three children.

Root and children share one working directory. A child edits its named
original files directly, and every agent sees the change at once. A
discovered overlap means stop and report it: never race a concurrent edit,
copy an implementation, or make a worktree by default.

## Dispatch and integration

1. The Commander splits the task into independent file scopes and assigns
   each to an Implementer or a Worker.
2. Implementers implement. Workers search, apply a proved mechanical pattern,
   or check a finished result.
3. Children report under the policy's contract. The Commander integrates the
   shared-workspace diff and reports to the user.
4. Where fresh verification is required, use a Worker for deterministic checks
   and an Implementer for behavioural or implementation review.

Children may run scoped checks and edit their assigned files. Committing,
pushing, opening pull requests, deleting files and changing external state
follow the repository's own Git rules, or
[`~/.Jarvis/docs/git.md`](../git.md) where it has none.

## CLI fallback

Without native collaboration, keep the interactive session as Commander and
use bounded headless runs:

```sh
codex exec -m gpt-6-luna --sandbox workspace-write \
  "Implement only the named files and acceptance criteria in this invocation."
codex exec --ephemeral -m gpt-6-luna \
  "Read and verify only the named acceptance criteria in this invocation."
```

Give `--sandbox workspace-write` only to a child that must edit files. The
fallback keeps exclusive file ownership, the brief, the report contract and
fresh-verifier selection.
