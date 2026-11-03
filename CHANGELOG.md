# Changelog

> **中文摘要**：這是 Jarvis 的 release note。每個 release 的 pull request 把條目加在
> `## Unreleased` 下並改名為版本號，所以條目會經過審查；它也是 annotated tag 的訊息，
> 並由 tag 發佈成 GitHub Release。MINOR 與 MAJOR 要寫清楚改了什麼、為什麼，以及
> 在這台機器上必須做什麼。v1.0.0 是第一個 release。

Jarvis tags releases as `vMAJOR.MINOR.PATCH`. How a version is chosen, and how a
release is cut, is in [Releases](./docs/releases.md).

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

A PATCH release: documentation only.

- **What only Codex can verify** is listed in
  [`docs/dispatch/codex-pending-action-items.md`](./docs/dispatch/codex-pending-action-items.md),
  for Codex to read and work through: whether Codex loads Jarvis Skills, the GitHub
  and SSH identity of `!` commands, what can replace the identity policy, the switch in
  a live session, and (after #56) arming auto-merge. `docs/dispatch/codex.md` points at it
  and records that the owner's Approve was confirmed on #53.
- **Keeping a machine current** has its own guide, in English and Traditional Chinese:
  [`docs/keep-machine-current.md`](./docs/keep-machine-current.md). It lists the situations (a routine
  update, a release that asks for a step, a check that fails afterwards, a Skill added or
  removed, and how to tell whether a machine is current) and the steps for each. Both READMEs
  link it, and CI checks the pair for parity.

## v1.2.1 (2026-11-02)

A PATCH release: documentation only ([#59](https://github.com/ShenYo/Jarvis/issues/59)). Nothing to do on this machine.

- **The README is split into documents.** `README.md` and `README.zh-TW.md` keep
  the introduction, scope, status, a quick start and a table of documents. The
  rest moved to [`docs/`](./docs/): the step-by-step
  [setup guide](./docs/setup-new-machine.md) (also in
  [Traditional Chinese](./docs/setup-new-machine.zh-TW.md)), and, in English
  only, [architecture](./docs/architecture.md), [guard](./docs/guard.md),
  [agent identity](./docs/agent-identity.md), [maintenance](./docs/maintenance.md),
  [local Git hooks](./docs/git-hooks.md) and [releases](./docs/releases.md).
  The setup guide is new in one respect: it takes a machine that has never had
  Jarvis through the prerequisites, the clone, the bridge, both guards and the
  agent identity for Claude Code and Codex, with a check after each step. A
  link to an old README section, such as `README.md#agent-identity`, now lands
  on the README with no such heading; the entries below that predate this
  change are left as they were.
- **The parity check covers the setup guide.** `scripts/check-readme-parity.py`
  also compares `docs/setup-new-machine.md` with its Traditional Chinese
  version, and CI runs it for both pairs.
- **Two messages name the new place.** The fix line `apply-agent-identity.sh`
  prints for a foreign `shell_environment_policy`, and the test that pins it,
  now point at `docs/agent-identity.md` instead of the README.

## v1.2.0 (2026-11-02)

A MINOR release (v1.2.0): the agent identity reaches Codex, the guard's agent-identity switch can be turned on for both runtimes and back off, and the tests no longer depend on the session they run in.

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
  sha256). With no record and no marker, its answers are byte-identical to before over the
  whole probe corpus (see the next entry for what changed with a marker).
- **The agent-identity switch can be turned on (#52).** The guard refuses every GitHub write
  from a runtime whose identity is not applied when its switch is on; until now nothing
  could set it for Codex, so it stayed off. It is still off by default. Under Claude Code
  it is `JARVIS_REQUIRE_AGENT_IDENTITY=1` in the environment, as before. Under Codex it is
  the hook's own argument `--require-identity`, because a Codex hook does not see the
  environment; Codex mode now ignores the environment variable, and it also ignores the
  `JARVIS_AGENT_IDENTITY` marker: "applied" means only that the Codex record exists and
  passes its checks. That is a deliberate change: a marker inherited from a Claude Code
  session used to count in Codex, and Codex strips `GIT_CONFIG_COUNT`, so an HTTPS push
  could use the owner's keychain. A refusal under the switch now names the switch as the
  cause, the fix (`apply-agent-identity.sh --check` or `--check --codex`, and `--setup`
  on a new machine) and the rollback (`--unrequire`). With the switch off and no marker,
  Claude-mode answers are byte-identical to before. In Claude mode the switch also counts as
  on while a `agent-identity.require.json` record says so, looked up in both
  `$CLAUDE_CONFIG_DIR` and `~/.claude` (a project cannot redirect the lookup), so a project's
  own `settings.json` env cannot blank it. A record that exists but cannot be read, or is not a
  record, counts as on too (the guard fails closed), and the refusal names the record's path.
- **`apply-agent-identity.sh --require` / `--unrequire`.** `--require` runs every Claude Code
  check, every Codex check and the trust check of the installed Codex hook, and requires the
  identity to be applied on both sides: a switch on with no identity would lock out every
  GitHub write, the running session's included. It reads that from the fixed
  `state: applied|ready|problems` line `--check` now prints. Any failure writes nothing and
  names the failing check; the plain run (`bash …/apply-agent-identity.sh`, `--codex`) is the
  fix for an identity not yet applied. Then it writes `JARVIS_REQUIRE_AGENT_IDENTITY=1` into
  the `env` of `~/.claude/settings.json` (backup, its own record
  `~/.claude/agent-identity.require.json`, the identity's conflict and concurrent-change
  rules) and runs `apply-codex-guard.sh --require-identity`; if that fails, the settings change
  is rolled back. An interrupt (INT, TERM) rolls back whatever this run changed, decided from
  the state of the files, against what they were before the run, so a record-only switch (a
  valid record and no value in `settings.json`) is put back too. A value `"1"` already in
  `settings.json` by hand is not touched, but `--require` records it with `"owned": false`, so
  the guard keeps the switch on if a project blanks the variable; `--unrequire` removes that
  record and leaves the value, and says so. `--unrequire` removes the value only when the
  record lists it and is owned; a record that does not list a value present in `settings.json`
  is a CONFLICT. Every write and rename is checked: if `settings.json` cannot be replaced the
  record stays, Codex is not touched and the exit is non-zero; a record changed by someone else
  since it was read is a conflict, as for `settings.json`. `--unrequire` is the reverse and
  needs no checks. Both refuse, with a fix, when `hooks.json` cannot be parsed. `--unapply`
  leaves the switch and says so, so the machine fails closed. `--check` states the switch for
  each side, counts a stale or unreadable require record, and the process environment
  (`JARVIS_REQUIRE_AGENT_IDENTITY=1`), as on, with a warning and the fix for a stale record,
  warns when one side is on and the other off, and under `--codex` checks that Codex trusts
  the installed hook. A running Claude Code session may pick up a changed
  `settings.json` env at once, and the messages say so.
- **`apply-codex-guard.sh`.** New `--require-identity` and `--no-require-identity`; with
  neither, the installed hook's switch state is kept, so re-running after a Jarvis update
  never turns it off (a first install starts off). `--check` (and the new `--trust`) read
  `[hooks.state."<hooks.json>:pre_tool_use:<g>:<h>"]` in `config.toml` and report
  `UNTRUSTED` or `DISABLED` with exit 1, because Codex skips a hook it has not been shown;
  they need a `python3` with `tomllib` (3.11+) and fail closed without one. The hash formula
  (sha256 of the compact, key-sorted JSON of the event, matcher and handler) matched all 11
  handlers of the owner's real `hooks.json` and `config.toml` on 2026-11-02. The script never
  writes the trust. The check follows Codex 0.166: it hashes `additionalContextLimit`,
  drops null-valued keys, and answers `UNVERIFIABLE` (naming the key) for any handler key it
  does not know; the key is `$CODEX_HOME/hooks.json` made canonical (links, trailing slash),
  or `$HOME/.codex/hooks.json` as written when `CODEX_HOME` is unset; `[features] hooks =
  false` (or the legacy `codex_hooks = false`) is reported as `DISABLED`. A first install
  while Claude Code's switch is on (through its `settings.json`, the process environment or
  a require record) warns that Codex's starts off. The switch is `--require-identity` as a
  whole argument after `--codex`, wherever it stands, for the status, `--unrequire`, a
  re-run and the guard alike.
- **Optional separate Codex account.** `codex_login`, `codex_email` and
  `codex_gh_config_dir` (typed by hand; `--setup` never adds them) make Codex a second
  GitHub account, with its own `gh` login directory and repository invitations; messages
  then name `codex_login` and its line. Not set, or `codex_login` equal to `login`: Codex
  shares the account. `codex_email` or `codex_gh_config_dir` without `codex_login`, or a
  `codex_email` equal to `email`, is an error.
- **Tests are hermetic.** The suites strip the applied identity's variables from the
  environment before setting their own, so they pass inside an agent session as
  well as in CI (two cases of `tests/agent-identity.sh` failed in a session before).
- **Codex remote check (PATCH-level fixes, #50).** For a trusted project's remotes,
  `--check --codex` now reads every fetch and push URL (`remote get-url --all`, and
  `--push --all`), so a second pushurl over HTTPS is no longer hidden behind the first,
  and the WRONG line names each failing URL. It also accepts `ssh://git@github.com/…`
  and a host in any case (`git@GitHub.com:…`), which use the same key. A URL counts as
  GitHub's by its parsed host, not by containing `github.com` (so
  `https://gitlab.com/x/github.com.git` is skipped); it passes only as SSH with the user
  `git` (`git@github.com:…`, `ssh://git@github.com/…`, `ssh://git@github.com:22/…`), so
  another user, another port or HTTPS is WRONG; and a remote whose URLs cannot be read is
  WRONG, not skipped. The pseudo-terminal
  `--setup --codex` test gives up after 20 s instead of 300 s. `tests/bash-guard.sh` points
  the hook's `~/.claude` and `~/.codex` fallbacks at empty directories, so on a machine
  where the Codex identity is applied its two switch-on cases no longer read the real record.
- **What the owner does on this machine:** nothing is required. To give Codex the
  identity, follow the README's [Agent identity](./README.md#agent-identity), Codex part:
  `bash ~/.Jarvis/scripts/apply-agent-identity.sh --setup --codex`, add the printed
  `.pub` to the machine account, then `--check --codex`, the plain `--codex` run, and
  restart Codex. Re-run `bash ~/.Jarvis/scripts/apply-codex-guard.sh` to install the
  updated hook and trust it again in `/hooks`. Commands Codex runs outside its sandbox
  after an approval, and commands typed with `!` in the Codex TUI, are not yet verified
  to receive the policy. To turn the agent-identity switch on, once `--check` and
  `--check --codex` are clean and Codex trusts the installed hook:
  `bash ~/.Jarvis/scripts/apply-agent-identity.sh --require`, then open `/hooks` in Codex
  and trust the Jarvis guard again (its command gained `--require-identity`, so Codex skips
  it until you do; `--check --codex` reports `UNTRUSTED` meanwhile), and start a new Claude
  Code session. To turn it off: `--unrequire` and the same re-trust. Re-running
  `apply-codex-guard.sh` keeps the switch as it is. Commands typed with `!` in Claude Code
  also run with the agent identity (verified 2026-11-02 in #14).

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
