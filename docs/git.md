# Git in Jarvis

The rules for Git work in this repository, and the defaults for a repository
that has no Git guideline of its own. The three hooks in
[`.githooks/`](../.githooks) enforce the mechanical part and point here when
they refuse something. The [Claude Code guard](../README.md#claude-code-guard)
enforces the operation boundaries for Claude Code sessions on this machine.

A repository with its own Git guideline follows that guideline, not this
document.

## Commits

- **One task per commit.** Do not combine changes from different requests,
  even when they are small and sit in the same working tree. Stage the files
  for this task by name, never with a blanket `git add -A` across a mixed tree.
  If the tree cannot be separated, stop and say so.
- **Check for secrets before staging and before pushing.** Read the staged
  diff. A credential, token, private key, password, connection string with
  embedded credentials, or personal identifier stops the commit. Report the
  file and the kind of value, never the value. A secret that was already
  pushed is compromised: say so, and leave rotation and history to the owner.
- **The message**, which `commit-msg` checks:
  - The subject is Conventional Commits: `type(scope): summary`, with a type
    from `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `build`, `ci`,
    `perf`, `style`. The scope is optional.
  - The summary is imperative (`add`, not `added`), has no trailing period,
    and aims for 50 characters. 72 is the hard cap, counted in characters.
  - The summary names the change. A leading `misc`, `cleanup`, `updates`,
    `wip` and the like is refused, because a commit that needs such a word
    usually covers more than one task.
  - A change of 40 lines or more needs a body, after a blank line, that says
    why the change exists. The diff already shows what changed.
- `pre-commit` refuses staged additions that match known credential formats,
  and files of the kinds that usually hold them. It is a net under reading the
  diff, not a replacement for it.

## Whose call an operation is

| Operation | Whose call |
| --- | --- |
| Reading history, diffs, PRs and CI | The agent's, whenever relevant |
| Committing; pushing a non-default branch; opening a pull request | The agent's, under the commit rules above |
| Merging, enabling auto-merge, closing or reopening a pull request | A person's. They name the PR in their own message. |
| Pushing directly to the default branch | A person's. `pre-push` refuses it. |
| Approving a pull request that contains the agent's own work | Nobody's. Only an independent reviewer approves. |
| Changing branch protection, rulesets or repository settings | A person's |
| Pushing a tag; publishing, editing or uploading to a GitHub Release | A person's. They name the tag and the commit in their own message. |
| Force push, `reset --hard`, rewriting pushed history | **Never the agent's**, even when asked |
| Discarding uncommitted work: `git clean`, `stash drop`/`clear`, `worktree remove`, `restore`/`checkout --` | **Never the agent's**, even when asked |
| Deleting a branch, tag, ref or GitHub Release, locally or on the remote | **Never the agent's**, even when asked. `pre-push` refuses remote deletion. |
| Deleting files: `rm -r`, `find -delete`, `git rm` | **Never the agent's**, even when asked |
| Removing or rewriting a remote; GitHub API `DELETE`; deleting a repository | **Never the agent's**, even when asked |

For a "never" operation, the agent states the exact command and its target,
and the person runs it.

Skipping the hooks is never the agent's either: `--no-verify` in any
abbreviation, `commit -n`, a one-off `-c core.hooksPath`, or unsetting it.

## Limits

`core.hooksPath` is per-clone configuration that a clone does not carry, so a
fresh clone runs no hook until it is set again:

```sh
git config core.hooksPath .githooks
```

The hooks and the guard catch the ordinary spelling of a mistake. They are not
a security boundary against someone using the same credentials on purpose.
The server-side ruleset is the part that holds when they are skipped.
