# Git commits

How a commit is made in this repository: the format the hooks enforce. Where
the agent's calls end and a person's begin is in
[`safety-boundary.md`](./safety-boundary.md). The three hooks in
[`.githooks/`](../../.githooks) enforce the mechanical part and point here
when they refuse something.

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
