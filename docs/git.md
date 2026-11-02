# Git in Jarvis

The rules for Git work in this repository, and the defaults for a repository
that has no Git guideline of its own. The three hooks in
[`.githooks/`](../.githooks) enforce the mechanical part and point here when
they refuse something. The [Claude Code guard](./guard.md#claude-code-guard)
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
| Merging, closing or reopening a pull request | A person's. They name the PR in their own message. |
| Arming auto-merge (`gh pr merge <n> --auto`) | The agent's, but only where the base branch's rules require the code owner's approval: at least one approval, code-owner review, stale approvals dismissed on push, and last-push approval. The guard checks this at the moment of use, for a single `gh pr merge <n> --auto -R owner/repo` command ([Arming auto-merge](#arming-auto-merge)). The owner's Approve still decides the merge. |
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

## Arming auto-merge

GitHub merges a pull request armed with `gh pr merge <n> --auto` once its
requirements are met. That is safe to leave to an agent only when the owner's
approval is one of them; with no approval required, or no ruleset at all, the
pull request merges as soon as the checks pass. So the
[guard](../README.md#claude-code-guard) lets an agent arm auto-merge only after
it has asked GitHub, with the agent's own login, about the pull request's base
branch, and found all of:

- a `pull_request` rule (`repos/{owner}/{repo}/rules/branches/{base}`) with
  `required_approving_review_count` of at least one, `require_code_owner_review`,
  `dismiss_stale_reviews_on_push` and `require_last_push_approval` on;
- that rule's ruleset (`repos/{owner}/{repo}/rulesets/{id}`) says
  `current_user_can_bypass` is `never` for the agent's login, so the rule binds
  the agent (`exempt`, anything else, a missing field or an error is a refusal);
- a CODEOWNERS file on the base branch (`.github/CODEOWNERS`, `CODEOWNERS` or
  `docs/CODEOWNERS`) that `codeowners/errors` reports no errors for, because
  without one `require_code_owner_review` asks nobody.

It refuses on any error, timeout, unreadable answer or missing piece. The refusal
names what failed. Until the pull request that adds `.github/CODEOWNERS` has
merged, `--auto` stays refused on a repository, which is the intended order.

**The form is exact.** The accepted forms are the whole command, nothing around
it:

- `gh pr merge <n> --auto -R owner/repo`, with at most one of `--squash`,
  `--merge` or `--rebase`;
- `gh pr merge <n> --disable-auto`, with `-R owner/repo` if wanted (it reduces
  what merges, so it asks GitHub nothing).

`<n>` is a pull request number, or a `https://github.com/<owner>/<repo>/pull/<n>`
URL in place of both `<n>` and `-R`. `--auto` always names its repository: `-R`
beats `GH_REPO`, `GIT_DIR`, `gh repo set-default` and the remotes, so the
guard cannot be pointed at one repository while `gh` acts on another, and it
refuses while `GH_REPO` or `GH_HOST` is set. The command is refused, as a merge
checkpoint, if it has anything else: another command (`;`, `&&`, `||`, a pipe, a
subshell or substitution), an assignment, a wrapper (`env`, `xargs`, `command`,
`find -exec`), a path to `gh`, a function or alias, quoting, or any other flag.
A direct merge, `--admin`, `--delete-branch` and the GraphQL merge mutations
stay a person's too.

Retargeting a pull request (`gh pr edit --base`/`-B`, a `gh api` write to
`pulls/{n}` with a `base` field, or the GraphQL `updatePullRequest` with
`baseRefName`) is a merge checkpoint as well: GitHub keeps auto-merge enabled for
a writer, so it would follow the pull request to a branch whose rules the guard
never checked.

The owner applies these settings, from their own terminal with their own login,
not from an agent session:

- On the default branch's ruleset, the `pull_request` rule with the four fields above.
- [`.github/CODEOWNERS`](../.github/CODEOWNERS) with `* @ShenYo`, so the code-owner
  review that counts is the owner's, not that of an App that approves.
- `allow_auto_merge` on, or there is nothing to arm, and `delete_branch_on_merge`
  on, since the agent never passes `--delete-branch`.
- A bypass actor for the repository admin role, in `pull_request` mode, so the
  owner can still merge by hand. The agent's own account must never be one, and
  the guard checks that through `current_user_can_bypass`. With the identity
  switch off, the agent's `gh` may be the owner's admin login; the check then
  refuses, which is correct.

## Limits

`core.hooksPath` is per-clone configuration that a clone does not carry, so a
fresh clone runs no hook until it is set again:

```sh
git config core.hooksPath .githooks
```

The hooks and the guard catch the ordinary spelling of a mistake. They are not
a security boundary against someone using the same credentials on purpose.
The server-side ruleset is the part that holds when they are skipped.
