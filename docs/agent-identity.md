# Agent identity

> **中文摘要**：這份文件是 agent identity 的參考資料：為什麼要給 agent 自己的 GitHub 帳號、設定檔的
> 格式、六項檢查、真正執行時寫入什麼、Codex 的機制、已知限制，以及 Codex 使用獨立帳號的做法。
> 一步一步的設定在 `setup-new-machine.md`，guard 的開關在 `guard.md`。

The reference for the agent identity: why it exists, the config file, the checks, what a real run writes, how Codex gets the same identity, and what is not checked. The steps to set it up on a machine are in [Setting up a new machine](./setup-new-machine.md); the guard's switch that makes it mandatory is in [Guard](./guard.md#the-agent-identity-switch).

## Creating the machine account

On GitHub, once for all machines, create or reuse the one machine account. Signed in as the owner of each repository, invite it as a collaborator with the Write role (an organization repository asks for the role; on a personal one a collaborator gets write by default), then accept the invitation signed in as the machine account.

## Why an agent identity

On this machine agents act on GitHub as the owner, so the owner cannot approve
the pull requests an agent opens, and "an agent never approves its own work" is
only an instruction. An agent identity gives agents a machine account of their
own: their commits and pull requests come from it, and the owner reviews them as
a different person.

## The config file

[`apply-agent-identity.sh`](../scripts/apply-agent-identity.sh) checks that a
machine is set up for it, and only when every check passes writes the identity
into the `env` of `~/.claude/settings.json`. The identity is kept in a local
file, never in this repository, which is public:
`~/.Jarvis/config-local/agent-identity`. The path is fixed, so every worktree
reads the same file. It must be untracked and ignored by Git, and the check
refuses it otherwise. It is parsed, never sourced: one `key=value` per line,
`#` comments and blank lines, and an unknown key, a duplicate, an empty value,
quotes, trailing spaces or CRLF are each reported with their line number.

```ini
login=my-agent-account
email=12345+my-agent-account@users.noreply.github.com
ssh_key=~/.ssh/id_ed25519_agent_claude_<hostname>
gh_config_dir=~/.config/gh-agent
repos=owner/repo
# author_name=Claude Code
```

`login` is the machine account, `email` its verified email (commits are
attributed by it), `ssh_key` this machine's private key for it, `gh_config_dir`
the `GH_CONFIG_DIR` the agent's `gh` uses, which must not be your own, and
`repos` the repositories it works in.

## The checks

Every check prints one line, `OK`, `MISSING`, `WRONG` or `WARN` (or `SKIP`, for a
check that cannot run until an earlier one passes), and for anything that is
not `OK` an exact `fix:` line. All of them run, so one run shows
everything, and the last line, `Next: step N of 6 — …`, names the earliest step
still failing, so rerunning `--check` always tells you the single next thing to
do. The checks follow the order a new machine is set up in:

1. the config file exists, is private and is valid;
2. this machine's SSH key exists;
3. its public key is on the machine account, so GitHub answers `Hi <login>!`;
4. `gh` is logged in as that account, with no `GH_TOKEN` in the way;
5. the account can push to each repository: not invited, invited but not
   accepted, and accepted with a role above Write are three different fixes;
6. the settings can take the identity without overwriting anything.

```sh
bash ~/.Jarvis/scripts/apply-agent-identity.sh --setup    # a new machine: create the file and the key, guided
bash ~/.Jarvis/scripts/apply-agent-identity.sh --check    # run every check, write nothing
bash ~/.Jarvis/scripts/apply-agent-identity.sh            # check, and write only if all pass
bash ~/.Jarvis/scripts/apply-agent-identity.sh --unapply  # remove exactly what a run wrote
bash ~/.Jarvis/tests/agent-identity.sh
```

## What a run writes

`--setup` is interactive. After asking, it creates the config file from values
it validates as you type them, and generates the key with `ssh-keygen` only when
the key file does not exist: an existing key is never overwritten or modified.
It prints the public key and where to add it, prints the `gh auth login` command
for the agent's config directory, and finishes with the full check. It never
writes `settings.json`, and it never touches your own `gh` login or keys.

A real run merges `GIT_AUTHOR_NAME`, `GIT_COMMITTER_NAME`, `GIT_AUTHOR_EMAIL`,
`GIT_COMMITTER_EMAIL`, `GIT_SSH_COMMAND`, `GH_CONFIG_DIR`,
`JARVIS_AGENT_IDENTITY` and the `GIT_CONFIG_*` pairs below into `env`, keeps a backup, and records what it wrote in
`~/.claude/agent-identity.applied.json`. A key that someone else set to a
different value is reported as a conflict and is not overwritten, and a
settings file that changes while the script runs is not written. A running Claude Code session
may pick the new environment up at once (on this machine one did), and a new one
does. The agent's git is also forced onto SSH
(`GIT_CONFIG_COUNT` and the `url.git@github.com:.insteadOf` and
`credential.helper` pairs), because an HTTPS remote ignores `GIT_SSH_COMMAND` and
would push with the credentials in the operator's keychain, as the wrong account.
Commands you type yourself with `!` in Claude Code also run with this identity
(verified on 2026-11-02 in #14: `!` printed the author `Claude Code` and the login
`agent-claude-code`); use an external terminal to act as yourself. Codex's `!` is
noted in the Codex part below.

## Known limits

Known limits, not checked: `git -c include.path=…`, a token embedded in a push
URL, `GIT_ASKPASS` and `SSH_ASKPASS`, and an `ssh_config` `ProxyCommand` or
port 443 setup that the check then fails, because `-F /dev/null` ignores it.
One wrong-account case is not caught: `login=` set to the operator's own
account on an organization repository where it only has Write, on a machine
with neither the operator's `gh` login nor an operator SSH key, after the key
and the `gh` login were made in a browser signed in as the operator. Use a
separate machine account, and sign in as it in a private window. And keep the
agent's key off the default paths (`~/.ssh/id_ed25519` and the like) and out of
`ssh-agent`: otherwise a plain `ssh` presents it too, and the operator check
reports the agent's own login as the operator's.

## Codex

**Codex.** `--codex` gives Codex the same identity: the same account, its own SSH key
(so that key can be revoked alone) and the author name `Codex`. The mechanism is
different, because Codex strips `GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_n`,
`GIT_CONFIG_VALUE_n` and `GIT_CONFIG_PARAMETERS` from the commands it runs, so the
forced-SSH git config above cannot travel that way. What does reach every command is
`[shell_environment_policy] set` in `~/.codex/config.toml` (`$CODEX_HOME` if set), and
it carries `GIT_CONFIG_GLOBAL`: a gitconfig of ours, `agent-identity.gitconfig`, that
includes your own global config, empties `credential.helper` after it, and rewrites
`https://github.com/` to SSH. The same `set` carries the author and committer name and email, `GIT_SSH_COMMAND`,
`GH_CONFIG_DIR` and `JARVIS_AGENT_IDENTITY` as the Claude Code environment does, and blanks `GH_TOKEN`, `GITHUB_TOKEN`,
`GH_ENTERPRISE_TOKEN`, `GITHUB_ENTERPRISE_TOKEN` and `GH_HOST`, because Codex hands
its whole environment on. A real `--codex` run, once every check passes, writes that
gitconfig (mode 600), appends one delimited block to `config.toml` (the rest of the
file stays byte-identical, and the previous copy is `config.toml.agent-identity-backup`),
and records both in `agent-identity.applied.json` beside them. A
`shell_environment_policy` that this script did not write, in `config.toml`, in a
profile, or in the `.codex/config.toml` of a project you trust, is reported and never
overwritten. Reading `config.toml` needs a `python3` with `tomllib` (Python 3.11+) on
`PATH`. `--unapply --codex` removes the block only if it is byte-identical to the
record. The Codex guard cannot see that policy (a Codex hook gets Codex's own
environment, not its commands'), so it takes the record's presence as "the identity is
applied" and then refuses the same overrides as the Claude Code guard does ([the agent-identity switch](./guard.md#the-agent-identity-switch)); it does not compare its own
environment with anything. A `JARVIS_AGENT_IDENTITY` marker inherited from a Claude
Code session counts for nothing there: the record is the only thing that makes the
identity applied under Codex.

`--check --codex` also reports a state that is only partly there as `MISSING`: a record
with no `agent-identity.gitconfig` (the policy's `GIT_CONFIG_GLOBAL` would point at
nothing, and git would fall back to your own credentials over HTTPS), or a record whose
block is gone from `config.toml`. The fix is the plain `--codex` run. The Codex guard
likewise trusts the record only while its block is in `config.toml` exactly once and the
gitconfig still has the recorded sha256, and refuses GitHub writes until `--check --codex`
is clean again. The same `set` carries `GIT_TERMINAL_PROMPT` as `0`, and `GIT_ASKPASS` and
`SSH_ASKPASS` as `/usr/bin/false`, so an HTTPS push that slips through fails instead of
asking for a password.

Codex strips `GIT_CONFIG_COUNT`, so a repository's own `.git/config`, or an `includeIf`, is
read after our gitconfig and can add a credential helper, or a `pushInsteadOf` back to
HTTPS. `--check --codex` runs the URL, last-helper, remote and `git credential fill`
checks inside every project that `config.toml` trusts and that is a Git work tree, and
reports the rule and the file it comes from. Other clones are not checked. To check one
by hand, from inside it, run
`printf 'protocol=https\nhost=github.com\n\n' | env -u GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL=~/.codex/agent-identity.gitconfig GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false git credential fill`:
it must fail (a URL-specific `credential.<url>.helper` shows up only here, not in the
helper list), and with the same `env`, `git remote get-url --all` and `git remote get-url --push --all`
for each remote must print every github.com URL (judged by its host, in any case) as SSH with the
user `git`: `git@github.com:…`, `ssh://git@github.com/…` or `ssh://git@github.com:22/…`. Another
user or port, or `https://` or `http://`, fails, and a remote whose URLs cannot be read fails too. Not checked
either: a nested `.codex/` directory below a project root and managed configuration
(`/etc/codex/managed_config.toml`, or an MDM profile), neither of which has been verified
to matter here, and `codex -c` or `--profile` on the command line, which are your own
overrides.

Two more config keys, used only by `--codex`: `codex_ssh_key`, required, Codex's own
private key, which must not be `ssh_key`; and `codex_author_name`, optional, default
`Codex`. Claude Code ignores them. The commands for a new machine are in [Setting up a new machine](./setup-new-machine.md#codex).

Verified 2026-11-02 with codex-cli 0.166.0: approved escalated commands retained
all four identity variables; commands entered with `!` retained the two tested
variables and Git author `Codex`. GitHub API identity and SSH identity for `!`
commands remain unverified. Use an external terminal for personal commits; owner
identity was confirmed there. See [Codex identity verification](./dispatch/codex.md#agent-identity-verified-2026-11-02-codex-cli-01660).

## A separate Codex account

Codex can use a separate GitHub account instead of sharing this one. Add `codex_login`,
`codex_email` and `codex_gh_config_dir` to the config file by hand (`--setup --codex`
never adds them), log `gh` in as that account in its own directory, and invite it to
every repository. With `codex_login` different from `login`, the other two are
required and the `gh` directory must differ from `gh_config_dir`; every `--codex`
check, and what is written, then use that account. `codex_login` equal to `login`
means the same as not set. A `codex_email` or `codex_gh_config_dir` without `codex_login` is an
error, and `codex_email` must differ from `email`.
