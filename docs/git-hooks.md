# Local Git hooks

> **中文摘要**：這份文件說明這個 repository 的三道本機 Git hook：`pre-commit`、`commit-msg`、
> `pre-push` 各拒絕什麼、為什麼由這裡自己維護、為什麼 push 規則在 GitHub 上也有一份，以及 hook
> 擋了不該擋的東西時怎麼辦。`core.hooksPath` 是 per-clone 設定，新 clone 要自己設定。

`core.hooksPath` points at [`.githooks/`](../.githooks), so this clone runs three
commit-time and push-time checks. They are a guard against mistakes, not a
server-side control: `core.hooksPath` is per-clone configuration that is never
cloned, so a fresh clone of this repository runs none of them until someone
sets it again. When a hook refuses, it points at [`docs/git.md`](./git.md),
which holds this repository's Git rules.

| Hook | Refuses |
| --- | --- |
| [`pre-commit`](../.githooks/pre-commit) | A staged diff whose added lines look like a credential, key, token, password or connection string. It names the rule and the file, never the matched value. |
| [`commit-msg`](../.githooks/commit-msg) | A subject that is not Conventional Commits, and a larger change with no body saying why it exists. |
| [`pre-push`](../.githooks/pre-push) | Deleting a remote ref, rewriting history (a force-push), and pushing directly to the default branch. It decides from the refs being pushed, not from the command text. |

## Owned here

The three hooks are this repository's own: Jarvis and Friday do not depend on
each other, in either direction
([history](./history.md#git-hooks-maintained-here)). Nothing compares these files with
Friday's, and a fix made to Friday's hooks reaches this repository only if
someone ports it deliberately.

What keeps them honest is a behaviour test rather than a comparison.
[`tests/githooks.sh`](../tests/githooks.sh) runs each hook in a scratch
repository and checks what it refuses and what it accepts. The
[`CI`](../.github/workflows/ci.yml) workflow runs it on every pull request, together with a check that each hook is still executable, because
git skips a hook that is not and lets the commit through.

```sh
bash ~/.Jarvis/tests/githooks.sh
```

## Why the push rules live here as well as on GitHub

A ruleset on `main` is active: it refuses deletion and non-fast-forward pushes
and requires a pull request, with no bypass actors
([history](./history.md#push-rules-on-github-as-well)).

`pre-push` stays, for two reasons. It refuses at the moment of the push rather
than after a round trip, so an agent gets the reason instead of a rejected
ref. And it protects this clone even against a remote that has no rules —
a fork, a mirror, or a ruleset someone later relaxes. The server rule is the
one that cannot be skipped; the hook is the one that explains itself.

Either way the hook protects this clone only, which is why the three operations
it refuses are also written down as permanently agent-prohibited rather than
relying on the hook to be present.

## If a hook refuses something it should not

Do not reach for `--no-verify`; the [Claude Code guard](./guard.md#claude-code-guard) refuses that flag.
A rule that is wrong should be fixed in the hook, with the reason recorded, or
the specific line marked with `secret-scan:allow` and justified where it
appears. That marker is per-line on purpose: there is no file-level or
directory-level opt-out.
