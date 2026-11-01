# Codex adapter

> **中文摘要**：Codex 派工與協作：Commander 用 `gpt-6.1-sol`，Worker 用 `gpt-6-luna`。
> 2026-11-02 實測 `!` 的兩個 identity 變數與 Git author Codex；
> `!` 的 GitHub API／SSH identity 未測。外部終端機仍使用 owner 身分；
> owner 的 PR Approve 仍待確認。

This adapter makes [`policy.md`](./policy.md) executable in Codex. The policy
owns the roles, the brief, the report contract and escalation; this file only
says which Codex model and tool carries each.

## Role routing

| Role | Codex model | Responsibility | Effort |
| --- | --- | --- | --- |
| Commander | `gpt-6.1-sol` | Root analysis, planning, architecture, integration, user communication | high; xhigh for genuine escalation |
| Implementer | `gpt-6-luna` | Features, fixes, refactors and tests | medium; high for cross-file invariants |
| Worker | `gpt-6-luna` | Search, exact mechanical edits, deterministic fresh checks | low; medium for bounded edits or checks |

These are the owner's choice. Verified 2026-10-25 on this machine
(codex-cli 0.164.0, ChatGPT sign-in): each answered a
`codex exec -m <model>` run, and `~/.codex/models_cache.json` lists both. On
codex-cli 0.153.4 both were refused for a ChatGPT account, so an older CLI is
the first thing to check when an alias errors.

The Commander is the interactive session, so its model is the `model` in
`~/.codex/config.toml`, not this table; keep the two the same. Use only the
aliases in this table; another alias needs the same check before it goes in.

## Native collaboration

`gpt-6.1-sol` reported these from its tool definitions on 2026-10-25:

- Children are started with `collaboration.spawn_agent`, which takes
  `task_name` and `message`, and optionally `fork_turns`, `model` and
  `reasoning_effort`. `collaboration.send_message`,
  `collaboration.followup_task`, `collaboration.wait_agent`,
  `collaboration.interrupt_agent` and `collaboration.list_agents` talk to
  them.
- `fork_turns` is `"all"` (the default) or `"none"`. `"all"` inherits the
  parent's model and effort and takes no override, so a child on another
  model or effort needs `"none"` and a self-contained brief. The tool accepts
  an override only on explicit instructions from the user, an applicable
  `AGENTS.md` or a Skill; this table is that instruction.
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

## Agent identity (verified 2026-11-02, codex-cli 0.166.0)

Prerequisites: PR #49 was merged at `2026-11-01T16:15:32Z`. This branch
started from the freshly fetched `origin/main` at `b65110e`. Commands ran in
the Jarvis worktree; network checks were repeated outside the sandbox after
the sandbox could not resolve GitHub. Outputs below preserve literal observations
except where marked redacted: owner's home prefix is `<HOME>`, the SSH key
basename is `<CODEX_SSH_KEY>`, and the owner's personal email is
`<OWNER_EMAIL>`. The machine-account noreply email remains as public account
identity evidence.

| Check | Command | Observed result | Status |
| --- | --- | --- | --- |
| 1. SSH key | `sh -c '$GIT_SSH_COMMAND -T git@github.com'` | Sandbox: DNS failure; outside sandbox: authenticated as `agent-claude-code` (outputs below). | PASS outside sandbox; sandbox network check failed |
| 2. Commit identity | `git var GIT_AUTHOR_IDENT` and `git var GIT_COMMITTER_IDENT` | Both returned `Codex <349695790+agent-claude-code@users.noreply.github.com> 1793550586 +0800`. | PASS |
| 3. API identity | `gh api user -q .login` | Sandbox: connection error; outside sandbox: `agent-claude-code`. | PASS outside sandbox; sandbox network check failed |
| 4. Git resolution | `git ls-remote --get-url https://github.com/ShenYo/Jarvis.git` and `git config --show-origin --get-all credential.helper` | SSH URL and final empty helper from the agent config (outputs below). | PASS |
| 5. Escalation | `env \| grep -E '^(JARVIS_AGENT_IDENTITY\|GIT_CONFIG_GLOBAL\|GH_CONFIG_DIR\|GIT_SSH_COMMAND)='` inside and outside the sandbox | All four variables were identical (output below). | PASS |
| 6. Guard | `GH_TOKEN=x gh issue create --repo ShenYo/Jarvis --title probe --body probe` | PreToolUse denied the identity override before execution (message below). | PASS |
| 7. Owner's `!` command | `!env \| grep -E '^(JARVIS_AGENT_IDENTITY\|GIT_CONFIG_GLOBAL)='` | Owner supplied both tested variables (output below); Git author was `Codex`. `GH_CONFIG_DIR`, `GIT_SSH_COMMAND`, GitHub API identity and SSH identity were not tested for `!` commands. | PASS for tested variables and Git author only |
| 8. Owner's external terminal | `git -C ~/.Jarvis var GIT_AUTHOR_IDENT` | Owner supplied an external-terminal screenshot showing `ShenYo` (output below). | PASS |
| 9. Optional source lookup | Not run. | Nested config loading and `include_only` / `set` ordering were not researched in this verification. | UNVERIFIED; optional |

### Captured output

Check 1, sandbox (exit 255):

```text
ssh: Could not resolve hostname github.com: -65563
```

Check 1, outside sandbox:

```text
Hi agent-claude-code! You've successfully authenticated, but GitHub does not provide shell access.
```

Check 3, sandbox (exit 1):

```text
error connecting to api.github.com
check your internet connection or https://githubstatus.com
```

Check 3, outside sandbox:

```text
agent-claude-code
```

Check 4, URL followed by helpers (`\t` renders a literal tab; the last line
has an empty helper value):

```text
git@github.com:ShenYo/Jarvis.git
file:/Library/Developer/CommandLineTools/usr/share/git-core/gitconfig\tosxkeychain
file:<HOME>/.codex/agent-identity.gitconfig\t
```

Check 5, identical inside and outside the sandbox:

```text
GH_CONFIG_DIR=<HOME>/.config/gh-agent
GIT_CONFIG_GLOBAL=<HOME>/.codex/agent-identity.gitconfig
GIT_SSH_COMMAND=ssh -F /dev/null -i <HOME>/.ssh/<CODEX_SSH_KEY> -o IdentitiesOnly=yes
JARVIS_AGENT_IDENTITY=agent-claude-code
```

Check 6, tool rejection (the command did not execute):

```text
Command blocked by PreToolUse hook: Codex guard: gh issue create writes to GitHub; the command overrides the agent's identity (sets GH_TOKEN). The command would not act as the agent's own account. Do not retry it or work around it: remove the override, or tell the user.. Command: GH_TOKEN=x gh issue create --repo ShenYo/Jarvis --title probe --body probe
```

Check 7, owner's user shell command (exit 0):

```text
GIT_CONFIG_GLOBAL=<HOME>/.codex/agent-identity.gitconfig
JARVIS_AGENT_IDENTITY=agent-claude-code
```

The `!` check established only those two variables and Git author `Codex`; it
did not test `GH_CONFIG_DIR`, `GIT_SSH_COMMAND`, GitHub API identity, or SSH
identity.

Check 8, initial command reported as `user_shell_command` (exit 0), which
did not establish the identity of a terminal outside Codex:

```text
Codex <349695790+agent-claude-code@users.noreply.github.com> 1793550623 +0800
```

The owner then supplied an external-terminal screenshot on 2026-11-02 and
explicitly confirmed where it ran. The same command returned:

```text
ShenYo <<OWNER_EMAIL>> 1793550761 +0800
```

Check 10: [PR #51](https://github.com/ShenYo/Jarvis/pull/51) was created by
`agent-claude-code`. `gh pr view 51 --repo ShenYo/Jarvis --json author,commits,reviews`
confirmed that author and commit `bffd4c29aebf93ce454e6e2e8fb4ef0c72fd9c98`
with author `Codex` and the machine-account email. A direct commit API lookup
also confirmed committer `Codex`. These identity checks passed and were
recorded on issue #15. The owner must Approve the PR before
merging; until that happens, the approval acceptance item remains unverified.
