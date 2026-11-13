# Guard

> **中文摘要**：這份文件說明 Jarvis 的 guard：Claude Code 版（`guard.json` 的規則加上解析指令的
> PreToolUse hook）、Codex 版（同一支 hook，但 Codex 不能詢問，所以關卡一律拒絕），以及 agent-identity
> 開關（打開後，沒有套用 identity 的 runtime 一律不能寫入 GitHub）。agent identity 本身見
> `agent-identity.md`。

The guard is one set of rules that refuses destructive Git and file operations in every project on this machine, in two forms: one for Claude Code and one for Codex. A third part, the agent-identity switch, makes the [agent identity](./agent-identity.md) mandatory for GitHub writes. To install them, follow [Setting up a new machine](./setup-new-machine.md).

## Claude Code guard

> **繁中摘要**：個人的 Claude Code 防護規則放在
> `.agents/claude-guard/guard.json`，由 `scripts/apply-claude-guard.sh`
> 用複製的方式合併進 `~/.claude/settings.json`，並安裝一支解析指令的
> PreToolUse hook；兩者都不靠 link，所以沒有 Jarvis 的機器上 session 仍有防護。使用者自己寫的規則會保留；guard 退役的規則會在
> 下次套用時移除。

[`guard.json`](../.agents/claude-guard/guard.json) holds the rules every Claude
Code session on this machine runs under, whichever repository it starts in:

| Block | What it does |
| --- | --- |
| `permissions.deny` | Refuses the permanently prohibited operations: force push, `reset --hard`, `clean`, discarding uncommitted work, deleting branches, tags and refs, recursive deletion, `git rm`, rewriting a remote, GitHub `DELETE`, and skipping hooks. Matched before anything else, in every mode. |
| `permissions.ask` | Prompts for the human-review checkpoints: merging, closing or reopening a pull request, approving one, `gh repo edit`, and pushing to `main` or `master`. |
| `autoMode.hard_deny`, `soft_deny` | The same rules for the auto-mode classifier, in prose, so spellings a pattern cannot see (`bash -c`, `git -C`, a script) are judged too. Both keep the built-in rules through `"$defaults"`. |
| `hooks.PreToolUse` | Runs [`bash-guard.py`](../.agents/claude-guard/bash-guard.py) on every Bash call. It parses the command rather than matching its text, so it sees through `git -C <dir>`, `-c` options, a path such as `/usr/bin/git`, `bash -c` and `eval`, `$(...)`, a heredoc fed to a shell, `env`, `xargs` and `timeout`, flag clusters such as `-an` and `-vrf`, and git aliases. It denies the same operations and asks at the same checkpoints, including a bare `git push` from the default branch, and it also asks before a push that may carry a tag (`--tags`, `--follow-tags`, `push.followTags`, or a refspec naming a tag), and before publishing a release (`gh release create`, `edit` or `upload`, or the same through `gh api`), because a release tag and a release are checkpoints too. It fails closed: if it cannot start, the Bash call is blocked. |
| `hooks.UserPromptSubmit`, `hooks.SessionStart` | Run [`session-notes.py`](../.agents/claude-guard/session-notes.py), which is not a guard: it tells the agent when to save its [session notes](./session-notes.md) and, after a compaction, where they are. It only advises, and never blocks. |
| `hooks.PostToolUse` | Runs [`shell-syntax.py`](../.agents/claude-guard/shell-syntax.py) after every Edit and Write. When the file is a shell script (`.sh`, `.bash`, or a `#!` line that runs `sh` or `bash`, such as a Git hook) and `bash -n` cannot parse it, the agent sees bash's message at once, rather than in a review round. It uses `/bin/bash` where there is one, which on macOS is bash 3.2, so syntax only a newer bash accepts is caught there. For a script with a `shopt -s extglob` at the start of a line it runs `bash -O extglob -n`, since `bash -n` runs nothing and would otherwise reject that script's own patterns. Like `session-notes.py`, it only advises: the edit has already happened, and any error in the hook is silent. It does not see a script changed through Bash (`sed -i`, a heredoc). |
| `disableBypassPermissionsMode` | Turns bypass mode off; in bypass mode no ask rule would prompt. |

Apply it, or check whether the settings already carry it:

```sh
~/.Jarvis/scripts/apply-claude-guard.sh          # merge, keeping a .guard-backup
~/.Jarvis/scripts/apply-claude-guard.sh --check  # exit 1 when it would change something
```

The script copies the rules into the settings file, and the hooks to
`~/.claude/hooks/` (`claude-guard.py`, `jarvis-session-notes.py` and
`jarvis-shell-syntax.py`), rather
than linking them here, so a
session keeps its guard on a machine where this repository is missing. It
keeps every rule the person wrote, including one that equals a guard rule,
and records in `~/.claude/claude-guard.applied.json` only the entries it
added itself. That record is how a rule removed from `guard.json`, or a whole
list the guard stops managing, leaves the settings on the next run. A
settings file that is not valid JSON is refused and left as it is, and so is
one that changes while the script runs.

For a push, the hook works out where it goes the way git would: the
`--repo` option, `pushRemote` and `pushDefault`, `pushurl`, `push.default`
and configured push refspecs, and the remote's own default branch. A push to
a repository in a scratch directory on this machine skips the checkpoint.
When the hook cannot tell where a push goes, because the directory, the
branch or the configuration is unknown, it asks.

One merge is not a checkpoint: `gh pr merge <n> --auto -R owner/repo` (or a pull request URL),
alone or with `--squash`, `--merge` or `--rebase`, and `gh pr merge <n> --disable-auto`, each as the
whole command with nothing around it. The hook leaves `--disable-auto` alone. For `--auto` it
first asks GitHub, with the agent's own login, whether the base branch's rules require the code
owner's approval (at least one approval, code-owner review, stale approvals dismissed on push,
last-push approval), whether the rule's ruleset is active and the agent's login cannot bypass it,
and whether the branch's CODEOWNERS file is a single `*` rule naming only the owner, without
errors. It refuses while a token variable such as `GH_TOKEN` is set, since the merge would inherit it.
If not, if the answer does not come, or if the command is anything
but that single command, it asks as for any merge. Retargeting a pull request with `gh pr edit
--base` or the API asks too, because an armed auto-merge would follow it. The `gh api` checks read
the request the way `gh` does: attached short options (`-fbase=dev`), `--input` bodies decoded as
JSON (one that is not JSON asks), and percent-encoded paths. The owner's settings
for this are in [`docs/git.md`](./git.md).

What this does not do. The hook reads the command it is given, not a script
that command runs, and not a command a program builds at run time; in auto
mode the classifier is the layer for those, and it is not deterministic. It
reads `python -c`, `node -e` and similar code only for directory-tree deletion
and for strings that are themselves git, gh or rm commands. `git rm` is
refused outright, including `--cached`; to take a file back out of the index,
use `git restore --staged <path>`.

The tests run in sandboxes and never touch the real `~/.claude`. The first
covers the merge; the second is the hook's probe corpus, including every
spelling an independent review found getting past the text rules; the third
covers the shell-syntax hook:

```sh
bash ~/.Jarvis/tests/claude-guard.sh
bash ~/.Jarvis/tests/bash-guard.sh
bash ~/.Jarvis/tests/shell-syntax.sh
```

## Codex

[`apply-codex-guard.sh`](../scripts/apply-codex-guard.sh) gives Codex sessions
the same protection through a user-level `PreToolUse` hook: it copies
`bash-guard.py` to `${CODEX_HOME:-~/.codex}/hooks/jarvis-guard.py` and merges
one group for the Bash tool into `hooks.json`, leaving every other entry (Orca
keeps its own there) exactly as it is. The hook denies the same prohibited
operations. Codex cannot ask: it parses an `ask` answer and runs the command
anyway. So at a human-review checkpoint the hook answers `deny`, with a reason
telling the agent to state the exact command and let the user run it, or to do
it in a runtime that can ask. In Codex a checkpoint is therefore a refusal, not
a prompt.

```sh
bash ~/.Jarvis/scripts/apply-codex-guard.sh          # copy the hook, merge hooks.json, keep a .guard-backup
bash ~/.Jarvis/scripts/apply-codex-guard.sh --check  # exit 1 when it would change something
```

Codex runs the hook only after you trust it in `/hooks`, and trust is by hash,
so trust it again after every change to the hook or its entry. `--check` also
reads `~/.codex/config.toml` and reports `UNTRUSTED` (no matching `trusted_hash`)
or `DISABLED` (`enabled = false`) with exit 1, because until then Codex skips the
hook; it never writes that trust, which is yours to give. Reading it needs a
`python3` with `tomllib` (Python 3.11+), and without one `--check` fails and says
so. `--require-identity` and `--no-require-identity` set the agent-identity
switch (see [Turning the switch on](#turning-the-switch-on)); a re-run with
neither keeps the switch as the installed hook has it.

What this does not do. Codex fails open: a hook that exits non-zero or overruns
its timeout is marked failed and the command runs. In Codex mode the guard
turns its own errors, including input it cannot parse, into a `deny` and exits
0, keeps its git lookups well inside the 10-second timeout, and answers
`deny` from a watchdog at 8 seconds if it has not finished by then. A hook Codex
cannot start at all, for instance because the interpreter is missing, still
lets commands through. The measurements are in
[history](./history.md#codex-hook-outcomes). The tests run in a sandbox
`CODEX_HOME` and never touch the real `~/.codex`:

```sh
bash ~/.Jarvis/tests/codex-guard.sh
```

## The agent-identity switch

The switch belongs to the [agent identity](./agent-identity.md), which gives agents a GitHub account of their own. The guard side of it is below: the switch, what the guard refuses once an identity is applied, and how to turn the switch on.

The guard has a switch for this, and it is off. With
`JARVIS_REQUIRE_AGENT_IDENTITY=1` in the environment and `JARVIS_AGENT_IDENTITY`
empty, [`bash-guard.py`](../.agents/claude-guard/bash-guard.py) refuses every
GitHub write: a push to a shared remote, every `gh` subcommand except the known
read-only forms (`view`, `list`, `status`, `diff`, `checks`, `search`,
`browse --no-browser`, `auth status`, `--help`), and a `gh api` request that is
not a `GET` or a GraphQL query. A plain run never sets the switch; `--require`
does, for Claude Code and Codex together, once this machine passes `--check` (see
[Turning the switch on](#turning-the-switch-on)). In Codex the switch is an argument
of the hook's command, not the environment.

Once the identity is applied (the marker is set), the guard also refuses a
GitHub write that would not act as the agent, whether or not the switch is on:
when the hook's own environment carries `GH_TOKEN`, `GITHUB_TOKEN`,
`GH_ENTERPRISE_TOKEN`, `GH_HOST` or `GIT_CONFIG_PARAMETERS`, or when the command
sets, unsets or `env -u`'s one of those, `GH_CONFIG_DIR`, `GIT_SSH_COMMAND` or
`GIT_CONFIG_*`, or passes `git -c` for `credential.*`, `url.*`, `core.sshCommand`
or `http.*`. That covers environment the check cannot see, such as the `env` of a
project's own `.claude/settings.json`, which is read at run time. The check
itself also refuses a login that is the owner's account, owns a repository, or
holds admin or maintain on one, or is the account the operator's own SSH key
authenticates as; confirms with real `git` that an HTTPS GitHub remote becomes
SSH for fetch and push, and that an SSH one stays SSH, and reports the
`~/.gitconfig` url rewrite that gets in the way if not; and runs `ssh` with
`-F /dev/null`, so `~/.ssh/config` cannot add the operator's key. With the
marker set the hook also compares its own `GH_CONFIG_DIR`, `GIT_SSH_COMMAND` and
`GIT_CONFIG_*` values with what was applied (`~/.claude/agent-identity.applied.json`),
refuses `env -i` before a GitHub write, and refuses every GitHub write if that
record is missing.

### Turning the switch on

The switch is off until you turn it on, and a plain run, `--setup` and `--unapply`
never change it. Apply the identity on both sides first (the plain run, and `--codex`),
trust the installed Codex hook in `/hooks`, and make sure `--check` and `--check --codex`
are clean:

```sh
bash ~/.Jarvis/scripts/apply-agent-identity.sh --require     # on, for Claude Code and Codex together
bash ~/.Jarvis/scripts/apply-agent-identity.sh --unrequire   # off, for both
```

`--require` first runs every check for Claude Code and for Codex, requires the identity to
be applied on both sides (with the switch on and no identity, every GitHub write is refused,
including the running session's), and checks that Codex trusts the hook that is installed
now; one failure writes nothing and names the check that failed (a `WARN` is allowed). Then it writes `JARVIS_REQUIRE_AGENT_IDENTITY=1`
into the `env` of `~/.claude/settings.json`, with a backup, a record of its own
(`~/.claude/agent-identity.require.json`, apart from the identity's) and the same
conflict and concurrent-change rules, and runs `apply-codex-guard.sh --require-identity`,
which adds `--require-identity` to the hook's command. If that second step fails, the
first is rolled back. `--unrequire` is the reverse, needs no checks, and prints the
same messages. `--unapply` leaves the switch where it is and says so: with it on,
a runtime without an identity refuses GitHub writes, which is the safe way round. The
Claude Code guard treats the switch as on while `~/.claude/agent-identity.require.json`
says so, even if a project's own `settings.json` blanks the variable; only `--unrequire`
removes that record. The record is looked up in `$CLAUDE_CONFIG_DIR` and in `~/.claude`, so a
project cannot redirect the lookup, and a record that exists but cannot be read counts as on.
A value `"1"` that you set in `settings.json` by hand is recorded too, marked `"owned": false`;
`--unrequire` removes that record and leaves your value.

**Codex must be told to trust the guard again.** A Codex hook does not see the
environment, so the switch is the hook's own argument, and Codex mode reads nothing
else: not the environment variable, and not the `JARVIS_AGENT_IDENTITY` marker. Changing
the argument changes the hook's hash, and Codex skips a hook whose hash it has not been
shown, so after `--require` and after `--unrequire` the whole Codex guard is off until you
open `/hooks` in Codex and trust it. `--check --codex` reports `UNTRUSTED` until you do.

With the switch on, the guard is designed to refuse GitHub writes from a runtime
whose identity is not applied or whose record fails, while allowing reads. That
requires the running session to deliver the hook callback; a passing static
identity or trust check does not prove live enforcement.

A live Codex check on 2026-11-04 confirmed the trust and identity checks, and a
normal read command exited successfully. In that continuing session, a fake-token
`gh issue create` probe reached `gh` without a PreToolUse refusal, then failed
with a sandbox connection error; no issue was created and the probe was not
retried. The cause remains unknown. A separate fresh CLI run captured a
router-level PreToolUse refusal before the tool ran. These differing session
results do not establish why the continuing session missed the refusal, and a
successful static trust or identity check alone does not assure live hook
delivery. The normal-write identity check passed on [PR #65](https://github.com/ShenYo/Jarvis/pull/65). See [Codex
verification](./dispatch/codex.md#verification-20261104-2324-codex-cli-01660).

The refusal says what to do:

```text
Codex guard: gh pr create writes to GitHub; GitHub writes need this machine's agent
identity, and it has none (...). The agent-identity switch (--require-identity in the
Codex hook's command) caused this refusal. Fix: run `bash ~/.Jarvis/scripts/apply-agent-identity.sh
--check --codex` and do what it lists (on a new machine start with `... --setup --codex`).
Roll back: `bash ~/.Jarvis/scripts/apply-agent-identity.sh --unrequire` turns the switch
off for Claude Code and Codex.
```
