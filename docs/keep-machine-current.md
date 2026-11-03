# Keeping a machine current

**English** · [繁體中文](./keep-machine-current.zh-TW.md)

> **中文摘要**：Jarvis 更新之後，讓每一台已經導入的機器跟上最新狀態。先找出符合你狀況的情境，再照該情境的步驟做，每一步都附有檢查方式。
>
> guard 是複製進去的，不是 symlink，所以每次更新都要重跑 apply 腳本。Codex 只在 hook 定義改變時才需要重新信任。這台機器的身分設定檔 `config-local` 不會被更新動到。

Use this on a machine that already went through
[Setting up a new machine](./setup-new-machine.md). Find the situation that
matches, and follow its steps. Run every command in a normal terminal, not with
`!` inside Claude Code or Codex.

Some of what Jarvis installs is a link and follows `~/.Jarvis` by itself: the
personal instructions and every Skill. The rest is copied in, and stays as it
was until you re-run its script: the Claude Code and Codex guards. The agent
identity's config file, `~/.Jarvis/config-local/agent-identity`, belongs to
this machine. No update touches it.

## Which situation are you in?

| Situation | Go to |
| --- | --- |
| Jarvis's `main` has moved: a pull request merged, or a release was cut | [A. Routine update](#a-routine-update) |
| The release notes name a step for this machine | [B. A release asks for a step](#b-a-release-asks-for-a-step) |
| `--check` or `--trust` reports a problem after an update | [C. A check fails after an update](#c-a-check-fails-after-an-update) |
| A Skill was added or removed | [D. A Skill was added or removed](#d-a-skill-was-added-or-removed) |
| You are not sure whether this machine is current | [E. Is this machine current?](#e-is-this-machine-current) |

## A. Routine update

Do this on each machine after Jarvis's `main` moves. Every step is safe to
repeat.

1. Update the clone:

   ```sh
   git -C ~/.Jarvis switch main
   git -C ~/.Jarvis pull --ff-only
   ```

   Check: `git -C ~/.Jarvis status -sb` shows `## main...origin/main` with
   nothing ahead or behind. If `pull --ff-only` refuses, this clone has local
   commits or edits. Look at them before you do anything else.
2. Re-run the bridge:

   ```sh
   ~/.Jarvis/sync-personal-skills.sh
   ```

   Check: the last line starts `checks passed:`.
3. Re-run both guard scripts. They copy the current guard in, and keep the
   agent-identity switch as it is:

   ```sh
   bash ~/.Jarvis/scripts/apply-claude-guard.sh
   bash ~/.Jarvis/scripts/apply-codex-guard.sh
   ```

   Check: the last line of the Codex run is
   `trust: OK - Codex trusts the Jarvis guard entry …`. If it says
   `UNTRUSTED` or `DISABLED`, the hook's definition changed: go to
   [C](#c-a-check-fails-after-an-update).
4. Check the agent identity, for both runtimes:

   ```sh
   bash ~/.Jarvis/scripts/apply-agent-identity.sh --check
   bash ~/.Jarvis/scripts/apply-agent-identity.sh --check --codex
   ```

   Check: both print `state: applied`. If the switch is on, both also print
   `agent-identity switch: Claude Code on, Codex on`.
5. Start a new Claude Code session, and restart Codex, so both load the new
   guard.
6. Read what changed. Open [`CHANGELOG.md`](../CHANGELOG.md) and read every
   entry newer than the version this machine was on. If any entry says what to
   do on this machine, go to [B](#b-a-release-asks-for-a-step).

## B. A release asks for a step

Each MINOR or MAJOR entry in [`CHANGELOG.md`](../CHANGELOG.md) ends with what
the owner must do on this machine. Do steps 1–4 of [A](#a-routine-update)
first, then the entry's own steps, in release order, oldest first. Typical
ones:

- **Re-run an apply script.** This is already covered by A.
- **Trust the Codex hook again in `/hooks`.** It is needed only when the hook's
  definition changed. `bash ~/.Jarvis/scripts/apply-codex-guard.sh --trust`
  tells you whether it changed.
- **Turn something on.** For example `--require`. Follow the linked document,
  such as [Turning the switch on](./guard.md#turning-the-switch-on).

Check: run steps 3 and 4 of A again. Every check is clean.

## C. A check fails after an update

| What you see | What to do |
| --- | --- |
| `trust: UNTRUSTED` or `DISABLED` from `apply-codex-guard.sh` | Open Codex, run `/hooks`, select **Codex guard: checking the command**, and trust it, or enable it for `DISABLED`. Then `bash ~/.Jarvis/scripts/apply-codex-guard.sh --trust` prints `trust: OK`. Until then Codex skips the guard. |
| `MISSING`, `WRONG` or `CONFLICT` from `apply-agent-identity.sh --check` | Do what its `fix:` line says, and follow its `Next:` line. Then run `--check` again. Details are in [Agent identity](./agent-identity.md). |
| `state: ready`, not `applied` | The identity needs writing again, for example after a new key was added. Run `bash ~/.Jarvis/scripts/apply-agent-identity.sh`, or the same with `--codex`. |
| `sync-personal-skills.sh` exits non-zero | Read its message. [Maintenance](./maintenance.md) has the recovery steps, among them [Recover a `~/.agents` conflict](./maintenance.md#recover-a-agents-conflict). |
| The guard refuses every GitHub write after the update | The switch is on and this runtime's identity is not applied. Fix the identity using the check output above. To turn the switch off meanwhile, run `bash ~/.Jarvis/scripts/apply-agent-identity.sh --unrequire`. |

## D. A Skill was added or removed

Skills are links. A change to a Skill's own content reaches every machine with
`git pull` alone. Adding or removing a Skill changes the set of links, so run
steps 1 and 2 of [A](#a-routine-update): `git pull --ff-only`, then
`sync-personal-skills.sh`. Then start a new session so the runtimes see the
new set.

Check: the bridge prints `checks passed:`. The new Skill exists as
`~/.claude/skills/<name>`, and as `~/.codex/skills/<name>` when Codex is
installed. A removed one is gone from both.

## E. Is this machine current?

```sh
git -C ~/.Jarvis fetch -q && git -C ~/.Jarvis status -sb | head -1
git -C ~/.Jarvis describe --tags --abbrev=0
bash ~/.Jarvis/scripts/apply-claude-guard.sh --check
bash ~/.Jarvis/scripts/apply-codex-guard.sh --check
```

This machine is current when all four hold:

- the first line shows no `behind`;
- the tag is the newest on [Releases](https://github.com/ShenYo/Jarvis/releases);
- both `--check` runs exit 0.

Otherwise do [A](#a-routine-update).
