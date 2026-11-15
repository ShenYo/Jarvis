# Setting up a new machine

**English** · [繁體中文](./setup-new-machine.zh-TW.md)

> **中文摘要**：這份指南分三個階段帶你在一台全新的機器上完成 Jarvis：stage 1 指示與 Skills，
> stage 2 guard，stage 3 identity（選用，最後做，可以完全略過 machine account）。
> 內容依序是：安裝前置工具、clone 到
> `~/.Jarvis` 並啟用 Git hooks、執行 bridge、套用 Claude Code 與 Codex 的 guard、設定 agent
> identity（Claude Code 與 Codex 各一次），可選擇打開 `--require` 開關，最後逐項驗證。clone 與
> bridge 本身不安裝 runtime、不建立憑證，也不讓新專案依賴 Jarvis；憑證只出現在 agent identity 那幾步。

Follow this from the top on a machine that has never had Jarvis. Each step ends
with a check, so you know it worked before you go on. Run every command in a
normal terminal, not with `!` inside Claude Code or Codex (see
[Pitfalls](#8-pitfalls-already-learned)). The reference for each part is in
[Architecture](./architecture.md), [Guard](./guard.md) and
[Agent identity](./agent-identity.md).

Adoption has three stages. Do them in order, and stop after any of them:

- **Stage 1, instructions and Skills:** clone and bridge (steps 2 and 3). This
  gives you the Skills and the personal instructions. It installs no runtime
  and creates no credential.
- **Stage 2, the guard:** step 4. It refuses destructive Git and file
  operations in every project on the machine.
- **Stage 3, identity (optional, last):** steps 5 and 6. This gives agents a
  GitHub account of their own. You can skip the machine account entirely:
  stages 1 and 2 install and work without it. What you give up is on pull
  requests: the review loop posts its comments as the machine account and,
  without one, posts nothing
  ([review-loop.md](./dispatch/review-loop.md#never-as-the-owner)), and the
  agents' pull requests are your own, which you cannot approve yourself
  ([fork checklist](./fork-checklist.md#5-what-a-fork-does-not-get)).

If you forked Jarvis rather than cloning the owner's copy, read the
[fork checklist](./fork-checklist.md) first.

## 1. Prerequisites

Prerequisites are Git, Bash, and access to the configured Jarvis remote. Choose
this canonical destination only when `~/.Jarvis` does not already exist; never
clone over an existing checkout. Inspect and reconcile an existing checkout
under its own Git history instead.

The clone and the bridge need nothing more. The rest of this guide does, so
install what the stages you plan to do need before you start:

- `git`, to clone and to run the repository's hooks.
- `gh`, the GitHub CLI, to log in as the machine account. Needed only for
  stage 3; skip it if you skip the machine account.
- `jq`, which the guard scripts and the agent-identity script require.
- `python3` 3.11 or newer. The guard hook runs under it, and Codex's trust in
  the hook is read from `~/.codex/config.toml` with `tomllib`, which only
  Python 3.11+ has.
- `ssh` and `ssh-keygen` (OpenSSH), to make and test the agent's keys. They
  are usually installed already.
- Claude Code, installed and started once, so that `~/.claude` exists.
- The Codex CLI, installed and started once. The bridge links Codex only when
  its home (`~/.codex`, or `$CODEX_HOME`) exists.
- Optional: Node.js, for `npx skills`. It is needed only to install or update a
  CLI-managed Skill later.

Check them:

```sh
for c in git gh jq python3 ssh ssh-keygen claude codex; do
  command -v "$c" >/dev/null && echo "ok       $c" || echo "MISSING  $c"
done
python3 -c 'import tomllib' && echo "ok       python3 has tomllib"
```

Every line should start with `ok`, with two exceptions: `jq` and `python3` may
be missing if you stop after stage 1, and `gh`, `ssh` and `ssh-keygen` if you
stop before stage 3.

## 2. Clone Jarvis

Stage 1.

Clone into `~/.Jarvis`. The path is fixed: the bridge script requires this
repository to be cloned there. The block refuses to run over an existing
`~/.Jarvis`.

```sh
(
  set -eu
  if [ -e "$HOME/.Jarvis" ] || [ -L "$HOME/.Jarvis" ]; then
    echo '~/.Jarvis already exists or is a dangling link; inspect it instead of overwriting it.' >&2
    exit 1
  fi
  git clone https://github.com/ShenYo/Jarvis.git "$HOME/.Jarvis"
)
```

Then turn on the repository's Git hooks. `core.hooksPath` is per-clone
configuration, so a fresh clone runs none of the hooks until you set it
([Local Git hooks](./git-hooks.md)):

```sh
git -C ~/.Jarvis config core.hooksPath .githooks
```

Check: `git -C ~/.Jarvis config --get core.hooksPath` prints `.githooks`.

## 3. Bridge the Skills

Stage 1.

Run the bridge script. It is safe to repeat, and you re-run it whenever a Skill
is added or removed:

```sh
~/.Jarvis/sync-personal-skills.sh
```

Check: it ends with a line that starts `checks passed:` and exits 0.

Every Skill is tracked in this repository, so the clone and the bridge are the
whole setup: nothing is fetched at run time to make a Skill available, and the
Skills CLI is not needed to run one. It is needed to install or update a
CLI-managed Skill afterwards — see [CLI-managed and locally maintained
content](./architecture.md#cli-managed-and-locally-maintained-content) — and by one Skill's own
workflow: [`find-skills`](../.agents/skills/find-skills/) searches for Skills
that are *not* installed, so it reaches the network, and its search step runs
`npx skills find`. A clone-only machine can run every other Skill here; that
one will stop at its first step.

The bridge command neither installs a runtime nor creates credentials. It is
safe to omit Jarvis entirely for a project: personal Skills remain optional.
After the bridge, use the read-only checks in [Verify](./maintenance.md#verify) to confirm the
canonical symlink and any already-installed Claude/Codex bridge directories.

A new project takes its baseline from wherever that baseline is maintained,
following that source's own adoption guide. Do not copy Jarvis Skills into a
project: they are personal, and a project must work on a machine without
them.

The script also links `~/.claude/CLAUDE.md` to the personal instructions in
`.agents/AGENTS.md`. It creates that link when it is missing and replaces it when
it dangles. It refuses, and changes nothing, when `~/.claude/CLAUDE.md` is a real
file, because that file holds instructions someone wrote, or a live link
elsewhere, because that link was put there on purpose. To adopt the link on a
machine that already has a `~/.claude/CLAUDE.md`, move what it should keep into
`.agents/AGENTS.md`, remove it, and run the script again.

When Codex is installed, `${CODEX_HOME:-$HOME/.codex}/AGENTS.md` gets the same
link and the same refusals, so both tools read one file and there is no copy to
keep in step. Codex reads `AGENTS.override.md` in its home instead of
`AGENTS.md` when that file is not empty, so the script fails while one exists.

The script creates `~/.agents` if it is missing, ensures the Claude bridge
directory exists, and creates or replaces a canonical-name entry only when it
is missing or dangling. It bridges Codex when
`${CODEX_HOME:-$HOME/.codex}` exists, creating `skills/` under it if needed, because a
fresh Codex install has the home but not yet that subdirectory
([history](./history.md#codex-bridge-decided-by-its-home)). An absent Codex home is skipped rather than
treated as an error. It checks that each canonical skill has an existing entry under its declared name in every bridged tool, reports
dangling non-reserved entries, and rejects a top-level canonical directory that
is neither a Skill nor a grouping directory. A live canonical-name entry that
does not resolve to its canonical directory is reported as a `CONFLICT`
(entry, where it points, what was expected) and left unchanged, never
overwritten. It exits non-zero if these checks fail. Re-run it after adding or removing a skill.

## 4. Apply the guards

Stage 2.

Apply the guards: `bash ~/.Jarvis/scripts/apply-claude-guard.sh` and
`bash ~/.Jarvis/scripts/apply-codex-guard.sh`.

```sh
bash ~/.Jarvis/scripts/apply-claude-guard.sh
bash ~/.Jarvis/scripts/apply-codex-guard.sh
```

Each script copies its files into `~/.claude` or `~/.codex` (`$CODEX_HOME` if
set) and keeps a `.guard-backup` of what it replaced. The Claude Code guard is
active in the next session. What the guards refuse is in [Guard](./guard.md).

Codex runs its hook only after you trust it. Start Codex, open `/hooks`, and
trust the Jarvis guard. Trust is by hash, so do it again after any change to the
hook or its entry. The script never writes that trust; it only reads it:

```sh
bash ~/.Jarvis/scripts/apply-codex-guard.sh --trust
```

Check: both scripts exit 0 with `--check`, and `--trust` prints
`trust: OK - Codex trusts the Jarvis guard entry` and exits 0.

Optional: tell Claude Code's auto-mode classifier which repositories this
machine trusts. Run `/auto-mode-setup` in Claude Code from inside the Jarvis
checkout (`~/.Jarvis`); run from the home directory, it describes a directory
with no remotes. It first asks whether to add to the existing environment list
or replace it: choose add, because replacing discards the repositories added
by hand and the `"$defaults"` entry. It then offers two optional scans; accept
the one that reads the repositories under your home directory to have the
others drafted, or add them by hand afterwards. The draft is accepted or
discarded as a whole: accept it and prune it afterwards. Then read everything the draft wrote, not only the environment
list:

```sh
jq '.autoMode' ~/.claude/settings.json
```

In `environment`, keep only repositories you own or push to, because each one
becomes a trusted destination; remove any entry you do not recognise, such as a
trusted-services entry with no source, and keep `"$defaults"`, which stands
for the built-in entries (add it as the first entry if it is missing and you
want them). If the draft added `allow` entries, remove any that overlap the guard's
Human-Review Checkpoint rule (merging, auto-merge, closing or reopening a pull
request, pushing to the default branch, repository settings): an `allow` entry
is an exception to the guard's `soft_deny` rules, and `--check` does not see
it. Edit the list in `/permissions` › Auto mode or in
`~/.claude/settings.json`, and confirm what is in effect with
`claude auto-mode config`. If the draft added rules to `soft_deny` or
`hard_deny`, run `apply-claude-guard.sh` again so that its `--check` exits 0.

Re-run or edit it when the set of repositories changes. The setting is per
machine and per person: it names that machine's repositories and trusted
services, so do not copy it from another machine. It is not stored in
`guard.json`, and `apply-claude-guard.sh` neither writes nor overwrites it.

## 5. Set up the agent identity

Stage 3, optional.

To let agents act on GitHub as an account of their own, set up the [agent
identity](./agent-identity.md) after the guards, in this order:

### The machine account

The machine account already exists and has been invited to each repository
with the Write role. If it has not, or this is the first machine, do
[Creating the machine account](./agent-identity.md#creating-the-machine-account)
first. The account is shared by every machine; each machine has its own SSH key.

### Claude Code

On this machine, run `bash ~/.Jarvis/scripts/apply-agent-identity.sh --setup`.
It creates the config file and this machine's key, shows the public key to
add (signed in as the machine account: Settings, SSH and GPG keys, New SSH
key), and prints the command that logs `gh` in as the machine account.

`--setup` is interactive and refuses to run without a terminal, so run it in a
real terminal, not with `!`:

```sh
bash ~/.Jarvis/scripts/apply-agent-identity.sh --setup
```

It asks for the machine account's login and verified email (the
`12345+name@users.noreply.github.com` form), a private key path (default
`~/.ssh/id_ed25519_agent_claude_<hostname>`), a `gh` config directory (default
`~/.config/gh-agent`, which must not be your own), the repositories the agent
works in (`owner/repo`, comma-separated) and the commit author name (default
`Claude Code`). It shows the config file it would create, `~/.Jarvis/config-local/agent-identity`,
and asks before writing it. It generates the key with `ssh-keygen` only when the
key file does not exist.

When it prints the public key, add it to the machine account: sign in to GitHub
as the machine account, not as yourself (a private window is safest), then
Settings, SSH and GPG keys, New SSH key
(<https://github.com/settings/ssh/new>). Paste the key, save, and press Enter in
the script.

The script then prints the exact command that logs `gh` in as the machine
account, with your own `gh` config directory in place of the one shown. Run it
in another terminal and sign in as the machine account in the browser:

```sh
GH_CONFIG_DIR=~/.config/gh-agent gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key --web
```

`--git-protocol ssh` and `--skip-ssh-key` keep `gh` from rewriting your own
`~/.gitconfig` or uploading a key. Press Enter in the script again; it finishes
with the full check. Then check as often as you need to:

```sh
bash ~/.Jarvis/scripts/apply-agent-identity.sh --check
```

Run `--check` until the `Next:` line says `Next: run without --check to apply`.
Every line is `OK`, `MISSING`, `WRONG`, `WARN` or `SKIP`, and each one that is
not `OK` has a `fix:` line. The last line is then `apply-agent-identity: all checks passed`
and the exit status is 0. A `WARN` is allowed.

Run `bash ~/.Jarvis/scripts/apply-agent-identity.sh` to write the identity,
then start a new Claude Code session.

```sh
bash ~/.Jarvis/scripts/apply-agent-identity.sh
```

Check: `--check` now prints `apply-agent-identity: state: applied`.

### Codex

Codex gets the same machine account with its own SSH key, so that key can be
revoked alone. The config file must already exist, so do Claude Code first.
`--setup --codex` skips the `gh` login, which Codex shares:

```sh
bash ~/.Jarvis/scripts/apply-agent-identity.sh --setup --codex   # appends the keys to the config file after asking, generates Codex's key
# add the printed .pub to the machine account on GitHub
bash ~/.Jarvis/scripts/apply-agent-identity.sh --check --codex
bash ~/.Jarvis/scripts/apply-agent-identity.sh --codex           # writes the three files
# then restart Codex: a running session keeps the old environment
```

`--setup --codex` asks before it appends `codex_ssh_key` and
`codex_author_name` to the config file, and generates Codex's key. Add its
`.pub` to the machine account the same way as above, signed in as the machine
account. `--check --codex` also reports `UNTRUSTED` until Codex trusts the guard
hook (see [step 4](#4-apply-the-guards)). The plain `--codex` run writes
`~/.codex/agent-identity.gitconfig`, one block in `~/.codex/config.toml` and a
record beside them. Restart Codex afterwards: a running session keeps the old
environment.

Check: `bash ~/.Jarvis/scripts/apply-agent-identity.sh --check --codex` prints
`apply-agent-identity: state: applied`.

## 6. Optional: turn the agent-identity switch on

Stage 3, optional.

With the switch on, the guard refuses every GitHub write from a runtime whose
identity is not applied, in Claude Code and Codex together. It is off until you
turn it on. What it does is in
[Turning the switch on](./guard.md#turning-the-switch-on). Do it only after step
5 is done for both runtimes, Codex trusts the guard hook, and both `--check`
runs are clean:

```sh
bash ~/.Jarvis/scripts/apply-agent-identity.sh --require
```

`--require` changes the Codex hook's command, so Codex skips the guard until you
open `/hooks` in Codex and trust it again. Check with
`bash ~/.Jarvis/scripts/apply-codex-guard.sh --trust`.

To roll back, run `bash ~/.Jarvis/scripts/apply-agent-identity.sh --unrequire`.
It turns the switch off for both, and Codex needs the same `/hooks` trust
again.

## 7. Verify the whole machine

Run one command: `bash ~/.Jarvis/scripts/doctor.sh`. It runs the checks below
except the `core.hooksPath` row, repairs nothing, prints one line per check
(`ok`, `PROBLEM`, `skipped`, `UNVERIFIED`, or `ERROR` when a check could not
run) with the fix command for each problem, and exits 0 when there is no
problem. A `skipped` identity line is correct if you did not do step 5 (the
identity is optional: no config file, no switch and no applied record), and so
is a `skipped` Codex line without Codex. An identity line is `ok` only when its
`state:` is `applied`. `UNVERIFIED` does not fail the run, so read each such
line. The `live-callback` line is always `UNVERIFIED`: no check proves that a
running session calls the hook (see
[Turning the switch on](./guard.md#turning-the-switch-on)). It changes no file
of yours, with one exception: the identity check's SSH probe may add
`github.com` to `~/.ssh/known_hosts` the first time it connects.

The table lists the checks one by one, for when you want a single check alone.
"OK" is what each should show, and every one exits 0. The last column says which
stage a row belongs to; skip the rows of a stage you did not do.

| Command | OK looks like | Stage |
| --- | --- | --- |
| `~/.Jarvis/sync-personal-skills.sh` | the last line starts `checks passed:` | 1 |
| `git -C ~/.Jarvis config --get core.hooksPath` | `.githooks` | 1 |
| `bash ~/.Jarvis/scripts/apply-claude-guard.sh --check` | `already carry the guard` | 2 |
| `bash ~/.Jarvis/scripts/apply-codex-guard.sh --check` | `already carry the guard`, then `trust: OK - Codex trusts the Jarvis guard entry` | 2 |
| `bash ~/.Jarvis/scripts/apply-agent-identity.sh --check` | `state: applied`, `Next: nothing — the identity is already applied; a new Claude Code session uses it`, `all checks passed` | 3 only |
| `bash ~/.Jarvis/scripts/apply-agent-identity.sh --check --codex` | `state: applied`, `Next: nothing — the identity is already applied; a new Codex session uses it`, `all checks passed` | 3 only |

After step 6, both identity checks also show an `OK` line for the
`agent-identity switch`, with Claude Code and Codex both `on`.

## 8. Pitfalls already learned

- **`!` commands run as the agent.** A command you type with `!` in Claude Code
  runs with the agent identity, and so does one in Codex (the variables that
  were tested). To act as yourself, for example to approve a pull request or to
  commit under your own name, use an external terminal. What was verified is in
  [What a run writes](./agent-identity.md#what-a-run-writes) and
  [Codex](./agent-identity.md#codex).
- **Sign out of the machine account in the browser when you are done.** You
  signed in as it to add the keys and to log `gh` in. A browser still signed in
  as it makes the next thing you do on GitHub happen as the machine account.
- **`--setup` needs a real terminal.** It reads your answers, so it fails under
  `!` and when its input is piped.
- **Keep the agent's key off the default paths** (`~/.ssh/id_ed25519` and the
  like) and out of `ssh-agent`, or a plain `ssh` presents it too (see
  [Known limits](./agent-identity.md#known-limits)).
- **Restart after each change.** Start a new Claude Code session after the
  identity is applied, restart Codex after `--codex`, and trust the Codex hook
  again in `/hooks` after `--require` or `--unrequire`.
