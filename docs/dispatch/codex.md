# Codex adapter

> **中文摘要**：Codex 派工與協作：Commander 用 `gpt-6.1-sol`，Worker 用 `gpt-6-luna`。
> 2026-11-04 已確認 `!` 的 GitHub API／SSH 為 agent 身分；外部終端機仍使用 owner 身分。
> owner 已在 #53 以 ShenYo Approve agent 的 PR；本次另記錄 config 風險與 live guard 未攔截的結果。
> 尚待驗證的項目見 [`codex-pending-action-items.md`](./codex-pending-action-items.md)。

This adapter makes [`policy.md`](./policy.md) executable in Codex. The policy
owns the roles, the brief, the report contract and escalation; this file only
says which Codex model and tool carries each. What only Codex can still verify is
listed in [`codex-pending-action-items.md`](./codex-pending-action-items.md).

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
recorded on issue #15. The owner's Approve was confirmed later, on #53: ShenYo APPROVED
(2026-11-01T20:01:49Z) a pull request authored by `agent-claude-code`, and #15 is
closed.

## Verification (20261104-2324, codex-cli 0.166.0)

| Item | Command / evidence | Observed output | Status |
| --- | --- | --- | --- |
| C1. Skill discovery | Owner's `/skills` listing screenshot; root read `~/.codex/skills/writing-for-agents/SKILL.md`; `python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "${CODEX_HOME:-$HOME/.codex}/skills/writing-for-agents"` | Listing showed “Writing for Agents [Skill] Write documents agents consume” twice. Root announced and read the Skill; its path resolved to `~/.Jarvis/.agents/skills/writing-for-agents`. Runtime listing shows separate repo and user entries; the symlink bridge is preserved (details below). | PASS for this sample only; precedence and full Skill Phase B remain unverified |
| C2. `!` GitHub and SSH identity | Owner ran `!gh api user -q .login` twice and `sh -c '$GIT_SSH_COMMAND -T git@github.com'` | API returned `agent-claude-code` twice (exit 0). SSH returned `Hi agent-claude-code! You've successfully authenticated, but GitHub does not provide shell access.` (exit 1, expected SSH test result). The dedicated `GIT_SSH_COMMAND` policy is configured; the offered key path was not separately printed. | PASS for account identity; no separate key-offer trace |
| C3. Identity policy overrides | Codex 0.166.0 source at [loader/mod.rs](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/config/src/loader/mod.rs#L123-L135), [managed config loader](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/config/src/loader/mod.rs#L425-L482), [managed requirements](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/config/src/loader/managed_requirements.rs#L80-L120), [shell_environment.rs](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/protocol/src/shell_environment.rs#L153-L163); runtime `codex exec -c 'shell_environment_policy.include_only=["PATH","HOME"]' "Run: env \| grep -E '^(GIT_CONFIG_GLOBAL\|GH_CONFIG_DIR\|JARVIS_AGENT_IDENTITY)='" </dev/null` | Source says discovered nested trusted project config loads; legacy file and MDM managed config can override the full config layer. `include_only` filters after `set`. Child shell: exit 1, no output; all three identity variables absent. CLI exit 0. Source inspection is not runtime measurement. Modern managed-requirements interaction with this policy: NOT FOUND. Follow-up: [issue #64](https://github.com/ShenYo/Jarvis/issues/64). | PASS for the three required checks; modern managed-requirements interaction remains NOT FOUND |
| C4. Live guard behavior | `bash ~/.Jarvis/scripts/apply-codex-guard.sh --trust`; `bash ~/.Jarvis/scripts/apply-agent-identity.sh --check --codex`; fake-token `gh issue create` probe; `gh pr list --limit 1` | Trust: `trust: OK`. Identity check exit 0: `agent-identity switch: Claude Code on, Codex on`; `state: applied`; two warnings because private-repository ruleset API checks returned 403. Probe exit 1 reached `gh`, which returned `error connecting to api.github.com` / `check your internet connection or https://githubstatus.com`; no hook refusal and no issue created. No retry. Read command exit 0, no output. Normal-write [PR #65](https://github.com/ShenYo/Jarvis/pull/65) author `agent-claude-code`, commit author `Codex` verified through the GitHub API. | FAIL: probe was not hook-denied; cause not established. Fresh-session behavior remains unverified |

C4 command details:

```sh
GH_TOKEN=x gh issue create --repo ShenYo/Jarvis --title probe --body probe
gh pr list --repo ShenYo/Jarvis --limit 1
```

### Skill duplicate investigation

Codex's app-server `skills/list` API (`forceReload: true`) confirmed that the
same four writing Skills each have separate `repo` and `user` entries in this
Jarvis worktree:

| Sample Skill | Repo source | User source |
| --- | --- | --- |
| `writing-for-agents` | `<WORKTREE>/.agents/skills/writing-for-agents/SKILL.md` | `<HOME>/.Jarvis/.agents/skills/writing-for-agents/SKILL.md` |

From this worktree, four sampled Skills produced eight entries and zero runtime
errors. From `/private/tmp`, outside Jarvis, the same API returned only the four
`user` entries, with zero runtime errors. This isolates the displayed duplicate
to project and personal discovery scopes, not two copies under the Codex home.
It does not establish which wins on activation.

Bridge verification confirmed all 35 Codex symlinks resolve to their original
canonical personal targets. Canonical Skills, Codex-owned directories, and the
bridge script remain unchanged; no vendored Skill was edited. The canonical
personal tree remains the source of truth.

C4 normal-write evidence: `gh pr view 65 --repo ShenYo/Jarvis --json author,commits`
returned author login `agent-claude-code` and commit
`96ccdfe87dc40f7a84881c1bb71d46931f7ff4df` author `Codex`, with the
machine-account noreply email. This passes the normal-write subcheck; it does not
change the failed live guard probe result.
