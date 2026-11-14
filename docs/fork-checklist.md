# Forking Jarvis

> **中文摘要**：這份清單給 fork Jarvis 的人：clone 到 `~/.Jarvis`、把 CODEOWNERS 換成自己、
> 逐一檢視 `.agents/AGENTS.md` 裡標為 PERSONAL 與 MIXED 的段落、判斷哪些 owner 的名字是歷史紀錄
> 可以留著，並說明 fork 不會得到 owner 的 machine account 與 GitHub 設定。fork 是一次性的快照，
> 不保證 upstream 日後能乾淨地 merge 進來。

Jarvis is built for one person's machine, and the repository reads that way. A
fork is a one-time snapshot: nothing here promises that upstream will merge
cleanly into it later. This page lists what a fork has to change, what it can
leave, and what it does not get.

Adoption has three stages, each optional after the one before
([setup guide](./setup-new-machine.md)):

- **Stage 1, instructions and Skills:** clone and bridge. You can stop here.
- **Stage 2, the guard:** refuses destructive Git and file operations. Skip it
  if you do not want it.
- **Stage 3, identity:** a GitHub account of your own for the agents. Optional,
  and last.

## 1. Clone to `~/.Jarvis`

The path is fixed: `sync-personal-skills.sh` sets
`CANONICAL="$HOME/.Jarvis/.agents/skills"`. Clone your fork to `~/.Jarvis`, not
to another directory, and replace the upstream URL in the clone command of the
[setup guide](./setup-new-machine.md#2-clone-jarvis) with your fork's.

## 2. Replace the owner in CODEOWNERS

[`.github/CODEOWNERS`](../.github/CODEOWNERS) holds one rule, `* @ShenYo`.
Replace the login with yours. Until you do, the code-owner rule cannot be
satisfied in your fork, and the guard refuses to arm auto-merge (see
[Arming auto-merge](./git.md#arming-auto-merge) in `docs/git.md`: it requires a
CODEOWNERS file that GitHub reports no errors for).

The file is only half of it. A fork does not inherit repository settings. The
authority is the list headed "The owner applies these settings" in
[`docs/git.md`](./git.md); recreate it in your own repository. The ruleset on
`main` upstream has three rules, and that list spells out only the first:

- `pull_request`: one approval, code-owner review, approval of the most recent
  push, stale approvals dismissed on push, and required review-thread
  resolution;
- required status checks `tests (ubuntu-latest)`, `tests (macos-latest)`,
  `skills` and `gitleaks`;
- `deletion` and `non_fast_forward`.

The repository settings that list names are `allow_auto_merge`,
`delete_branch_on_merge` and a bypass actor for the admin role.

Enable GitHub Actions on your fork, or the required checks never report and
nothing can merge.

The ruleset is not yet a file in this repository; that is tracked in
[ShenYo/Jarvis#56](https://github.com/ShenYo/Jarvis/issues/56).

## 3. Review the marked sections of `.agents/AGENTS.md`

[`.agents/AGENTS.md`](../.agents/AGENTS.md) is linked as `~/.claude/CLAUDE.md`,
so a fork would otherwise load the owner's taste as its own rules. Five sections
carry a one-line marker. List them:

```sh
grep -n '<!-- \(PERSONAL\|MIXED\):' ~/.Jarvis/.agents/AGENTS.md
```

- `PERSONAL` is the owner's preference: reply language, the Traditional Chinese
  summary on documents, and the model table. Replace each with your own.
- `MIXED` is a generic method written in the owner's style: the deletion
  section and the Git pointer section. Keep what fits and review the rest.

Sections without a marker are generic. If you change a rule that
[`docs/git.md`](./git.md) or a hook also states, change them together.

## 4. Owner references: change the live ones, leave the history

The owner's login appears in many files. Run `git grep -n ShenYo` and sort the
hits. None is in `scripts/` or `.githooks/`.

Live references, which a fork must change or its agents keep acting on
upstream:

- [`.github/CODEOWNERS`](../.github/CODEOWNERS), section 2.
- The clone URL in the [setup guide](./setup-new-machine.md#2-clone-jarvis)
  and in the Quick start of the [README](../README.md#quick-start).
- [`docs/dispatch/review-loop.md`](./dispatch/review-loop.md), where the owner
  "approves as **ShenYo** in a browser signed in as ShenYo", and which links
  upstream's issues. Every pull request an agent opens is told to follow it.
- The upstream Releases link in
  [`docs/keep-machine-current.md`](./keep-machine-current.md), which checks
  your tag against upstream's.
- [`docs/git.md`](./git.md), which names the owner in its CODEOWNERS
  setting.

History, which records what happened upstream and can stay:
[`docs/history.md`](./history.md), the changelog, the Codex evidence under
`docs/dispatch/` and `tests/`. The `LICENSE` holds the upstream copyright line.

## 5. What a fork does not get

- **The owner's machine account.** It is a GitHub account that only the owner
  controls. The [agent identity](./agent-identity.md) is optional and is the
  last adoption stage; if you want it, create your own machine account
  ([how](./agent-identity.md#creating-the-machine-account)). Stages 1 and 2
  install and work without one, but the pull request review loop posts its
  comments as the machine account: before it posts, it checks `gh api user`
  against `$JARVIS_AGENT_IDENTITY`, and when they differ or the check fails it
  stops, posts nothing, and tells the owner
  ([review-loop.md](./dispatch/review-loop.md#never-as-the-owner)). Without a
  machine account the loop therefore posts nothing on an agent-opened pull
  request. A standing fallback is tracked in
  [ShenYo/Jarvis#91](https://github.com/ShenYo/Jarvis/issues/91).
- **The owner's GitHub settings:** the ruleset and the required checks
  on `main`. Recreate what you want (section 2).
- **Support promises.** See the audience and support statement in the
  [README](../README.md).
