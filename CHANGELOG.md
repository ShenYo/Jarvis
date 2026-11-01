# Changelog

> **中文摘要**：這是 Jarvis 的 release note。每個 release 的 pull request 把條目加在
> `## Unreleased` 下並改名為版本號，所以條目會經過審查；它也是 annotated tag 的訊息，
> 並由 tag 發佈成 GitHub Release。MINOR 與 MAJOR 要寫清楚改了什麼、為什麼，以及
> 在這台機器上必須做什麼。v1.0.0 是第一個 release。

Jarvis tags releases as `vMAJOR.MINOR.PATCH`. How a version is chosen, and how a
release is cut, is in the README's [Releases](./README.md#releases) section.

How an entry is written:

- The pull request that makes a release adds its entry under `## Unreleased`
  and renames that heading to the version and date, so the entry is reviewed
  with the change. The same text is the annotated tag's message and the GitHub
  Release's notes.
- A PATCH entry (documentation only) may be one line.
- A MINOR or MAJOR entry says what changed, why, and what the owner must do on
  this machine afterwards: for example re-run an apply script, or trust the
  Codex hook again in `/hooks`. A release that needs nothing says so.
- Nothing here is a dependency of any project, so no entry has an upgrade path
  for a consumer.

## Unreleased

A MINOR release: the agent identity reaches Codex, and the tests no longer depend on the session they run in.

- **Codex identity.** `scripts/apply-agent-identity.sh --codex` (with `--check`,
  `--setup`, `--unapply`) gives Codex the same machine account with its own SSH
  key (`codex_ssh_key`, which must differ from `ssh_key`, so it can be revoked
  alone) and the author name `Codex` (`codex_author_name`). Codex strips
  `GIT_CONFIG_COUNT`/`KEY_n`/`VALUE_n` and `GIT_CONFIG_PARAMETERS` from its
  commands, so the forced-SSH git config travels differently: a block appended to
  `~/.codex/config.toml` sets `[shell_environment_policy] set` with
  `GIT_CONFIG_GLOBAL` pointing at `~/.codex/agent-identity.gitconfig` (it includes
  the owner's global config, empties `credential.helper`, rewrites
  `https://github.com/` to SSH) and blanks the token variables and `GH_HOST`.
  Nothing else in `config.toml` changes; a `shell_environment_policy` of the
  owner's, in the file, a profile or a trusted project, is a reported conflict,
  never overwritten. Reading it needs a `python3` with `tomllib` (3.11+). The record
  is `~/.codex/agent-identity.applied.json`. The same `set` carries
  `GIT_TERMINAL_PROMPT=0` and `GIT_ASKPASS`/`SSH_ASKPASS=/usr/bin/false`, so an HTTPS
  push that slips past fails instead of prompting. `--check --codex` reports a partly
  applied state (a record without the gitconfig, or a block gone from `config.toml`)
  as `MISSING`, and checks the URL rules, the last credential helper, the repository's own remotes and
  `git credential fill` inside every project `config.toml` trusts, since a repository's own
  config is read after ours. A plain run that cannot write (another check fails) no longer
  prints "a real run writes it again" as OK.
- **Codex guard.** Under `--codex` the guard takes that record's presence as "the
  identity is applied" (a Codex hook cannot see the policy's environment), refuses
  the same overrides as under Claude Code, skips the hook-environment comparison, and
  refuses GitHub writes if the record is unreadable, or if what it lists is gone (its
  block is not in `config.toml` exactly once, or the gitconfig is missing or has another
  sha256). With no record, its answers are byte-identical to before over the whole probe
  corpus.
- **Optional separate Codex account.** `codex_login`, `codex_email` and
  `codex_gh_config_dir` (typed by hand; `--setup` never adds them) make Codex a second
  GitHub account, with its own `gh` login directory and repository invitations; messages
  then name `codex_login` and its line. Not set, or `codex_login` equal to `login`: Codex
  shares the account. `codex_email` or `codex_gh_config_dir` without `codex_login`, or a
  `codex_email` equal to `email`, is an error.
- **Tests are hermetic.** The suites strip the applied identity's variables from the
  environment before setting their own, so they pass inside an agent session as
  well as in CI (two cases of `tests/agent-identity.sh` failed in a session before).
- **What the owner does on this machine:** nothing is required. To give Codex the
  identity, follow the README's [Agent identity](./README.md#agent-identity), Codex part:
  `bash ~/.Jarvis/scripts/apply-agent-identity.sh --setup --codex`, add the printed
  `.pub` to the machine account, then `--check --codex`, the plain `--codex` run, and
  restart Codex. Re-run `bash ~/.Jarvis/scripts/apply-codex-guard.sh` to install the
  updated hook and trust it again in `/hooks`. Commands Codex runs outside its sandbox
  after an approval, and commands typed with `!` in the Codex TUI, are not yet verified
  to receive the policy.

## v1.1.0 (2026-10-29)

A MINOR release: new scripts run, and the guard hook gains a switch that is off.

- **Agent identity.** [`scripts/apply-agent-identity.sh`](./scripts/apply-agent-identity.sh)
  gives agents a GitHub machine account of their own, so the owner can approve
  the pull requests an agent opens (until now agents acted as the owner, and
  "an agent never approves its own work" was only an instruction). The identity
  lives in a local, Git-ignored file, `~/.Jarvis/config-local/agent-identity`;
  nothing in the repository names an account. `--check` runs every check (the
  file and its place in Git, the SSH key and GitHub's answer to it, the
  machine account's `gh` login, tokens that would override it, the operator's
  own login, access to each repository, and conflicts in
  `~/.claude/settings.json`), prints an exact fix for each failure, and ends
  with the next step to take. A real run writes the identity into the `env` of
  `~/.claude/settings.json` only when every check passes; `--setup` guides a new
  machine through the first four steps; `--unapply` rolls a run back. The agent's git is forced onto SSH too (`GIT_CONFIG_*` env: `url.git@github.com:.insteadOf`
  and an empty `credential.helper`), so an HTTPS remote cannot push with the owner's
  keychain credentials. It writes
  `~/.claude/agent-identity.applied.json` and a `.agent-identity-backup`.
- **Guard switch, off.** With `JARVIS_REQUIRE_AGENT_IDENTITY=1` and an empty
  `JARVIS_AGENT_IDENTITY`, `bash-guard.py` (Claude Code and Codex) refuses
  GitHub writes with a reason naming `--check`. Nothing sets the switch. With
  it unset and no marker the hook answers as before over its whole probe
  corpus; the one difference is stricter parsing of `env` flag clusters, so
  `env -iu VAR rm -rf …` and `env -S'…'` forms of a prohibited command are now
  refused too, where the old parser let them through. With the
  switch on, every `gh` subcommand that is not a known read-only form is refused. With the
  marker set, a GitHub write is refused while a token, `GH_HOST`, `GIT_CONFIG_*` or a
  `git -c credential.*` override would make it act as someone else.
- **What the owner does on this machine:** nothing is required for the guard.
  To adopt the identity, follow the README's [Agent identity](./README.md#agent-identity):
  run `bash ~/.Jarvis/scripts/apply-agent-identity.sh --setup`, then `--check`, then the
  plain run, and start a new Claude Code session. Re-run
  `bash ~/.Jarvis/scripts/apply-claude-guard.sh` and
  `bash ~/.Jarvis/scripts/apply-codex-guard.sh` to install the updated hook, and
  trust the Codex hook again in `/hooks`. Turn the switch on only after
  `--check` passes here.

## v1.0.0 (2026-10-26)

The first release. It marks what Jarvis is on this machine today; nothing
before it was versioned. How it got here is in
[`docs/history.md`](./docs/history.md#progress-2026-10-23-to-2026-10-25).

What the owner does on this machine to be at this release: run
`bash ~/.Jarvis/sync-personal-skills.sh`, `bash ~/.Jarvis/scripts/apply-claude-guard.sh`
and `bash ~/.Jarvis/scripts/apply-codex-guard.sh`, then trust the Codex hook in
`/hooks`. Each apply script has a `--check` mode that exits 1 when it would
change something.

- **Personal instructions.** [`.agents/AGENTS.md`](./.agents/AGENTS.md) is
  linked as `~/.claude/CLAUDE.md` for Claude Code and as `~/.codex/AGENTS.md`
  for Codex, so both load it in every session. It is grouped by scope: *Base
  behavior*, *Coding* and *Contracts*.
- **Dispatch docs.** [`docs/dispatch/`](./docs/dispatch/policy.md) holds the
  dispatch policy, the prompt templates and the Codex adapter.
- **Claude Code guard.** [`guard.json`](./.agents/claude-guard/guard.json) and
  the [`bash-guard.py`](./.agents/claude-guard/bash-guard.py) hook refuse the
  permanently prohibited Git and file operations, and ask at the human-review
  checkpoints, including before a push that may carry a tag and before
  publishing a GitHub Release (`gh release create`, `edit` or `upload`). The
  hook fails closed. It takes effect only after
  [`apply-claude-guard.sh`](./scripts/apply-claude-guard.sh) copies it into
  `~/.claude/settings.json` and `~/.claude/hooks/`.
- **Codex guard.** [`apply-codex-guard.sh`](./scripts/apply-codex-guard.sh)
  installs the same hook for Codex as a user-level `PreToolUse` hook. Codex
  cannot ask, so a checkpoint is a refusal there. The hook runs only after it
  is trusted in `/hooks`, and trust is by hash, so it needs trusting again
  after every change to the hook or its entry.
- **Skill bridge.** [`sync-personal-skills.sh`](./sync-personal-skills.sh)
  links every canonical Skill under `~/.Jarvis/.agents/skills/` into Claude
  Code's and Codex's Skill directories, and reports dangling entries. Every
  Skill is installed by the `skills` CLI and recorded in
  [`.agents/.skill-lock.json`](./.agents/.skill-lock.json).
- **Git hooks and CI.** Three hooks in [`.githooks/`](./.githooks) refuse a
  credential in a staged diff, a malformed commit message, and a push that
  deletes a remote ref, rewrites history or goes to the default branch. The
  [`CI`](./.github/workflows/ci.yml) workflow runs on every pull request, and
  its four checks (the tests on Linux and macOS, the Skills check and the
  secret scan) are required on `main`. [`docs/git.md`](./docs/git.md) holds the
  Git rules.
