# Uninstalling Jarvis

> **中文摘要**：`scripts/uninstall.sh` 是三個安裝腳本的反向操作：預設 dry run，只列出會動的路徑與原因；
> 加 `--remove` 才真的做。它只移除紀錄檔說 Jarvis 加進去的東西（guard 條目、複製的 hook、指向 checkout
> 的連結、已套用的 identity），不碰 checkout、備份檔、指向別處的連結，以及你自己寫的規則。
> checkout、machine account、GitHub 上的 SSH key 與 Codex guard 需要你自己手動處理。

A person trying Jarvis, or a fork, can leave with one command. Deletion is the
person's act: an agent writes and tests the script, and you run it, after
reading what the dry run lists.

```bash
bash ~/.Jarvis/scripts/uninstall.sh            # the same as --dry-run: prints every path it would change, and why
bash ~/.Jarvis/scripts/uninstall.sh --dry-run  # the flag spelled out
bash ~/.Jarvis/scripts/uninstall.sh --remove   # does it
```

If you turned the agent-identity switch on, turn it off first
(`bash ~/.Jarvis/scripts/apply-agent-identity.sh --unrequire`): `--unapply` leaves
it on, so every GitHub write stays refused. The script says so when it sees the
switch's record.

## What each installer adds, and what the script removes

| Installer | Adds | `uninstall.sh --remove` |
| --- | --- | --- |
| `scripts/apply-claude-guard.sh` | The guard's rules in `$CLAUDE_CONFIG_DIR/settings.json` (default `~/.claude`); the record `claude-guard.applied.json`; `settings.json.guard-backup`; the hooks `claude-guard.py`, `jarvis-session-notes.py`, `jarvis-shell-syntax.py` in `hooks/` | Takes out the entries the record lists, one occurrence of each (a rule you wrote stays, even one equal to a guard rule), after copying the file to `settings.json.uninstall-backup`. Just before it replaces `settings.json` it checks that nobody saved the file since it was read, as the installer does; if they did, it writes nothing, reports a PROBLEM and exits 1. Then it removes the record and each hook that is byte-identical to the copy this checkout installs and that no settings entry still names. A hook you edited, or that is a link, is left: delete it by hand if you want it gone, and `doctor.sh` reports the machine as installed until you do. Keeps `permissions.disableBypassPermissionsMode`, which the record does not track, and says so. A record from before ownership was tracked (no `owned`) counts the whole guard as owned. If the record is missing or unreadable, `settings.json` is not JSON, or `settings.json.uninstall-backup` already exists, it removes none of the guard, reports each piece as `left`, and exits 1 |
| `sync-personal-skills.sh` | `~/.agents`; `~/.claude/skills/<name>`; `~/.claude/CLAUDE.md`; when Codex is installed, `$CODEX_HOME/skills/<name>` and `$CODEX_HOME/AGENTS.md` (default `~/.codex`) | Removes each of these only when it is a link that resolves into the Jarvis checkout, and `~/.agents` last. A link that points elsewhere, dangles, or a real file or directory (in `skills/` too) is reported as `left` and not touched. If a skills directory cannot be scanned, or a link that is kept still goes through `~/.agents`, `~/.agents` stays too (reported as `left`, exit 1): removing it would leave those links dangling. Fix the cause and run the script again. The `skills` directories stay |
| `scripts/apply-agent-identity.sh` | The identity's `env` keys in `settings.json` and its record (and, with `--codex`, a block in `config.toml`, a gitconfig and a record) | Runs `--unapply` for Claude Code, and `--unapply --codex`, only where `agent-identity.applied.json` exists. `--unapply` copies `settings.json` to `settings.json.agent-identity-backup` and, when it removes the block, `$CODEX_HOME/config.toml` to `config.toml.agent-identity-backup`, replacing any copy there. The dry run names both paths |
| `scripts/apply-codex-guard.sh` | `$CODEX_HOME/hooks/jarvis-guard.py` and an entry in `$CODEX_HOME/hooks.json` | Nothing: it has no inverse. See below |

The bridge is always under `~/.claude`, as `sync-personal-skills.sh` makes it;
only the guard and the identity follow `CLAUDE_CONFIG_DIR`. The script reads the
same variables as the installers and writes nothing outside the paths above. It
removes named files and links, never a directory tree, and never anything inside
the Jarvis checkout.

## What you remove by hand

- **The Codex guard:** delete `$CODEX_HOME/hooks/jarvis-guard.py`, and the Jarvis entry
  (the group whose command names `hooks/jarvis-guard.py`) from `$CODEX_HOME/hooks.json`,
  and its `[hooks.state."…"]` trust entry from `$CODEX_HOME/config.toml`.
- **The backups** the installers and the script left, which it reports as `left` and never
  deletes: `settings.json.guard-backup` and `settings.json.uninstall-backup`. The two
  `agent-identity-backup` files (`settings.json` and `$CODEX_HOME/config.toml`) are written by
  the identity step's `--unapply`, which replaces any earlier copy, so they are not listed;
  delete them yourself when you no longer need them.
- **The checkout:** `~/.Jarvis`. After the script exits 0, nothing links into it.
- **The machine account and its keys:** the account, its SSH keys on GitHub
  (Settings, SSH and GPG keys), its collaborator access to your repositories, and
  the key files and `gh` login directory on disk
  ([agent identity](./agent-identity.md)). The script touches none of them.
- **An edited hook:** a hook in `hooks/` that is not byte-identical to the installer's copy. Until you delete it, `doctor.sh` judges the machine as installed.
- **Anything it reports as `left`:** a link that points elsewhere was not made by
  Jarvis, or was moved on purpose.

Afterwards `bash ~/.Jarvis/scripts/doctor.sh` prints `Jarvis is not installed on this machine` and exits 0. With any record, hook copy, switch or link still there (a Codex guard left on purpose shows as a note), it judges as it always does. A skills CLI's own real `~/.agents` and the links into it are not Jarvis's and do not count.

Before you run `--remove`, check the dry run's list. Each `would remove` line is
one file or link; nothing is recursive.
