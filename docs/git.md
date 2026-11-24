# Git in Jarvis

The rules for Git work in this repository, and the defaults for a repository
that has no Git guideline of its own. A repository with its own Git guideline
follows that guideline, not this one. They are in
[`docs/git-guideline/`](./git-guideline/):

- [`git-commit.md`](./git-guideline/git-commit.md): the commit format the hooks enforce.
- [`safety-boundary.md`](./git-guideline/safety-boundary.md): whose call each operation is, the operations never an agent's, arming auto-merge, applying the ruleset and settings, and the limits.

Jarvis has no `pr-evidence.md`: it has no rule on what a pull request body or its evidence must hold beyond [the review loop](./dispatch/review-loop.md).
