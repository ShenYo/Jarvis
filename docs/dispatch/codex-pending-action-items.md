# Codex: pending verification items

> **中文摘要**：這份清單列出 Jarvis 裡只有 Codex 自己才能驗證或驗收的項目，給 Codex 在新的 session 裡讀取並逐項實測。每一項都寫了目的、步驟、預期結果和完成條件。
>
> 結果寫進 [`codex.md`](./codex.md)，並回頭更新這份清單的狀態，再開 PR，由 owner 以 ShenYo Approve。Friday 的項目在 Friday 自己的清單，見文末。

You are Codex, on the owner's machine, in `~/.Jarvis`. Each item below is
something only Codex can check, because it depends on how Codex itself loads,
runs or isolates things. Claude Code verified the rest from outside. Work
through the items that are not blocked. Measure each one with a real command
and quote its output. A result you could not measure is `UNVERIFIED` with the
reason; never infer one. Read [`codex.md`](./codex.md) first, and
[`policy.md`](./policy.md) for the report contract.

## How to work

1. Start from an up-to-date `main` on a new branch, `docs/codex-verify-<YYYYMMDD-HHMM>`.
2. Record each result in [`codex.md`](./codex.md), under a section
   `## Verification (<YYYYMMDD-HHMM>, codex-cli <version>)`. Give each item one row:
   the command, the observed output, and PASS, FAIL or UNVERIFIED. Follow the
   style of the existing "Agent identity" section.
3. Update this file. Set the item's **Status** to the result, with the date
   and your `codex --version`. When an item passes, move it to [Done](#done). If a result contradicts a document, for example
   [`../agent-identity.md`](../agent-identity.md) or
   [`../architecture.md`](../architecture.md), correct that document in the same
   PR and say so.
4. Commit following [`../git.md`](../git.md), push, and open one pull request
   for the whole run. Then add the PR's link to each Status you set, in a
   second commit on the same branch. Ask the owner to **Approve as ShenYo**
   before it merges.
5. A step marked **owner** needs the owner to type something in the Codex TUI
   or in an external terminal. Ask for it, wait, and record what they paste.

Stop and report instead of working around anything the guard refuses.

## Items

### C4. With the switch on, a live Codex session behaves as designed

- **Why:** The agent-identity switch has been on since 2026-11-02, and so has the
  `--codex --require-identity` argument in `~/.codex/hooks.json`. Its decisions
  were tested by feeding the hook directly, never inside a running Codex.
- **Steps:**
  1. Run `bash ~/.Jarvis/scripts/apply-codex-guard.sh --trust`. It should
     print `trust: OK`.
  2. Run `bash ~/.Jarvis/scripts/apply-agent-identity.sh --check --codex`. It
     should print `agent-identity switch: Claude Code on, Codex on` and
     `state: applied`.
  3. Run `GH_TOKEN=x gh issue create --repo ShenYo/Jarvis --title probe --body probe`.
     It must be denied by the hook, with "overrides the agent's identity". The
     token is fake, so even a guard that failed would leave `gh` unable to
     authenticate and nothing would be created. That is also why an
     authentication error from `gh` does **not** count as a pass: only the
     hook's refusal does.
  4. A read, `gh pr list --repo ShenYo/Jarvis --limit 1`, is allowed.
  5. The pull request you open for this run is the normal-write case. Its
     author must be `agent-claude-code`, and its commit author `Codex`.
- **Done when:** all five hold.
- **Status:** FAIL (2026-11-04, codex-cli 0.166.0); fake-token probe reached `gh` without hook refusal and then hit a sandbox connection error. Cause and fresh-session behavior are unverified; no retry. Normal-write identity passed on [PR #65](https://github.com/ShenYo/Jarvis/pull/65); the live guard result remains FAIL. See [verification](./codex.md#verification-20261104-2324-codex-cli-01660).

### C5. Arming auto-merge from Codex

- **Blocked by:** [#56](https://github.com/ShenYo/Jarvis/issues/56). Wait until
  its pull request has merged and the owner has applied the GitHub settings in
  [`../git.md`](../git.md).
- **Why:** Once #56 lands, [`../git.md`](../git.md) makes arming auto-merge with
  `gh pr merge <n> --auto -R owner/repo` the agent's own call, but only where the
  base branch requires the code owner's approval. The guard checks that before
  it allows the command. The owner's Approve still decides the merge. Until #56
  lands the guard denies the command, which is why this item is blocked. The
  Codex mode has its own `gh` login and its own deadline.
- **Steps:**
  1. On the pull request of this run, run
     `gh pr merge <n> --auto --squash -R ShenYo/Jarvis` as a single command.
  2. Confirm that the PR does not merge before the owner approves it, and that
     it merges by itself after the approval.
- **Done when:** both hold, and `gh pr merge <n> -R ShenYo/Jarvis` without
  `--auto` is denied.
- **Status:** blocked.

## Done

### C1. Codex loads Jarvis Skills from `~/.codex/skills`

- **Why:** The bridge links each Skill into `${CODEX_HOME:-~/.codex}/skills/<name>`.
  Only the links were checked; whether the Codex runtime loads Skills from
  there was not ("Codex Skill Phase B" is UNVERIFIED in the README status, and
  [`../architecture.md`](../architecture.md) says the runtime loader is unverified).
- **Steps:**
  1. **Owner:** in the Codex TUI, open Codex's own listing of available Skills,
     if it has one, and paste it to you. Your own description of the Skills you
     know of is not evidence that the runtime loaded them.
  2. Pick one Jarvis Skill that is not built into Codex, for example
     `writing-for-agents` or `grilling`. Give a small task that should trigger
     it. Record the runtime's own signal that it was activated, such as the
     Skill's name in the transcript or tool log, and the `SKILL.md` path it
     read.
  3. Resolve the link in a way that works on macOS and honours `CODEX_HOME`:
     `python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "${CODEX_HOME:-$HOME/.codex}/skills/<that name>"`.
- **Done when:** Codex's own listing or activation signal names the Skill, and
  its path resolves to `~/.Jarvis/.agents/skills/<name>`. If Codex lists Skills
  and this one is missing, mark the item FAIL with the listing. If Codex offers
  no observable listing or signal, mark it UNVERIFIED and say so.
- **Status:** PASS (2026-11-04, codex-cli 0.166.0); see [verification](./codex.md#verification-20261104-2324-codex-cli-01660). Runtime API confirms separate repo/user discovery scopes in this worktree and only user scope outside it; symlink bridge preserved. Precedence and full Skill Phase B are unverified. [PR #65](https://github.com/ShenYo/Jarvis/pull/65).

### C2. The GitHub and SSH identity of commands typed with `!`

- **Why:** On 2026-11-02, `!` commands kept `JARVIS_AGENT_IDENTITY`,
  `GIT_CONFIG_GLOBAL` and the Git author `Codex`. Which GitHub account and
  which SSH key they actually use was not measured.
- **Steps (owner):** in this Codex TUI, the owner types:
  1. `!gh api user -q .login`
  2. `!sh -c '$GIT_SSH_COMMAND -T git@github.com'`
- **Done when:** the first prints `agent-claude-code`, and the second answers
  `Hi agent-claude-code!` using Codex's own key (`id_ed25519_agent_codex_<host>`
  in `GIT_SSH_COMMAND`). Update the sentence in
  [`../agent-identity.md`](../agent-identity.md) that calls this unverified.
- **Status:** PASS (2026-11-04, codex-cli 0.166.0); API identity returned `agent-claude-code` twice and SSH authenticated as `agent-claude-code`. The offered key path was not separately printed; see [verification](./codex.md#verification-20261104-2324-codex-cli-01660). [PR #65](https://github.com/ShenYo/Jarvis/pull/65).

### C3. What can replace the identity policy

- **Why:** The identity is a `[shell_environment_policy] set` block in
  `~/.codex/config.toml`. Three things could override it, and none was
  researched:
  - a `.codex/config.toml` nested below a project root;
  - managed configuration (`/etc/codex/managed_config.toml`, or an MDM profile);
  - the order in which `include_only` and `set` apply. If `include_only`
    applies after `set`, it would drop `GIT_CONFIG_GLOBAL` and `GH_CONFIG_DIR`.
- **Steps:**
  1. Find the answer in Codex's official documentation, or in its source for
     your installed version. Cite the URL, or the file and commit.
  2. Where it is safe, confirm `include_only` by measurement, without editing
     any config file. Run
     `codex exec -c 'shell_environment_policy.include_only=["PATH","HOME"]' "Run: env | grep -E '^(GIT_CONFIG_GLOBAL|GH_CONFIG_DIR|JARVIS_AGENT_IDENTITY)='" </dev/null`
     and record whether the three variables survive.
  3. Do not create or trust a new project to test nested configs. Trusting one
     writes to the owner's `config.toml`. Report what the source says instead.
- **Done when:** each of the three has a cited answer, and the `include_only`
  case also has a measurement. If anything can drop the identity, propose the
  check that `apply-agent-identity.sh --check --codex` should add, and record it
  as a follow-up issue rather than code.
- **Status:** PASS (2026-11-04, codex-cli 0.166.0); see [verification](./codex.md#verification-20261104-2324-codex-cli-01660). Modern managed-requirements interaction remains NOT FOUND; follow-up [#64](https://github.com/ShenYo/Jarvis/issues/64). [PR #65](https://github.com/ShenYo/Jarvis/pull/65).

See the dated results in [`codex.md`](./codex.md#verification-20261104-2324-codex-cli-01660).

## Friday

Friday's own Codex items, about the shared guard's hooks in consumer projects,
are in Friday's list:
[`ShenYo/Friday: docs/codex-pending-action-items.md`](https://github.com/ShenYo/Friday/blob/main/docs/codex-pending-action-items.md).
