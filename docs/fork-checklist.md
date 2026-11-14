# Forking Jarvis

> **中文摘要**：這份清單給 fork Jarvis 的人：clone 到 `~/.Jarvis`、把 CODEOWNERS 換成自己、
> 逐一檢視 `.agents/AGENTS.md` 裡標為 PERSONAL 與 MIXED 的段落、判斷哪些 owner 的名字是歷史紀錄
> 可以留著，並說明 fork 不會得到 owner 的 machine account 與 GitHub 設定。fork 是一次性的快照，
> 不保證 upstream 日後能乾淨地 merge 進來。

Jarvis is built for one person's machine, and the repository reads that way. A
fork is a one-time snapshot: nothing here promises that upstream will merge
cleanly into it later. This page lists what a fork has to change, what it can
leave, and what it does not get. For what each adoption stage adds, see the
[setup guide](./setup-new-machine.md).

## 1. Clone to `~/.Jarvis`

The path is fixed: `sync-personal-skills.sh` sets
`CANONICAL="$HOME/.Jarvis/.agents/skills"`. Clone your fork to `~/.Jarvis`, not
to another directory, and replace the upstream URL in the clone command of the
[setup guide](./setup-new-machine.md#2-clone-jarvis) with your fork's.

## 2. Replace the owner in CODEOWNERS

[`.github/CODEOWNERS`](../.github/CODEOWNERS) holds one rule, `* @ShenYo`.
Replace the login with yours. Without that, every pull request in your fork asks
for a review from an account you do not control.

The file is only half of it. In the upstream repository, a ruleset on `main`
requires one code-owner approval, approval of the most recent push, and
dismisses stale approvals when new commits arrive. A fork does not inherit
repository settings, so recreate that ruleset in your own repository's settings
if you want the same protection. The ruleset is not yet a file in this
repository; that is tracked in
[ShenYo/Jarvis#56](https://github.com/ShenYo/Jarvis/issues/56). The rule the
guard checks before arming auto-merge is described in [Git](./git.md).

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

## 4. Leave the history alone

The owner's login appears in many files, almost all of them history:
[`docs/history.md`](./history.md), the dispatch docs and the tests. None is in
`scripts/` or `.githooks/`. They record what happened in the upstream
repository and are not instructions to you; leave them. The places that do
matter are the CODEOWNERS rule above and the clone URL in the setup guide.

## 5. What a fork does not get

- **The owner's machine account.** It is a GitHub account that only the owner
  controls. The [agent identity](./agent-identity.md) is optional and is the
  last adoption stage; if you want it, create your own machine account
  ([how](./agent-identity.md#creating-the-machine-account)).
- **The owner's GitHub settings:** the ruleset and the required checks
  on `main`. Recreate what you want (section 2).
- **Support promises.** See the audience and support statement in the
  [README](../README.md).
