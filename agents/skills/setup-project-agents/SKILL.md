---
name: setup-project-agents
description: Safely preview, install, and verify a pinned Friday shared baseline in a blank Git repository; excludes consumer overlays, conflicts, and personal Skills.
---

# Set Up Project Agents

Use Friday's reviewed installer to adopt its shared baseline in a blank Git
repository. This Skill does not reconcile an existing consumer overlay, resolve
conflicts, or install personal or vendor Skills.

## Required inputs and preflight

Require both inputs in this form before doing anything:

```text
target=<repository root>
friday=<Friday clone>
```

Canonicalize both paths. Stop unless all of these are true:

- `target` is a repository root with a `.git` **directory**.
- `friday` is a different directory, a clean Git worktree, and contains a
  regular `install.sh` file and regular `payload` directory.
- Record Friday's full `git rev-parse HEAD`, plus the target branch, HEAD, and
  status. A dirty Friday checkout is not a pin; stop for the user to clean or
  select the intended checkout.

## Preview before authorization

Run only:

```sh
bash "$friday/install.sh" --check "$target"
```

Record the Friday SHA and the complete `NEW`/`IDENTICAL` result. Any
`CONFLICT` or nonzero exit stops this workflow: inspect and reconcile the
target in a reviewed project change, then preview again. Do not modify either
repository to make the preview pass.

## Install only with a new explicit authorization

Preview does not authorize installation. Before the write, obtain a **new,
explicit user authorization** that names the canonical `target` and the exact
Friday SHA recorded above. Do not infer this from invoking the Skill, a prior
approval, or a branch name.

After that authorization, run only:

```sh
bash "$friday/install.sh" "$target"
bash "$friday/install.sh" --check "$target"
(cd "$target" && bash .agents/hooks/check-collaborative-git.sh)
git -C "$target" status --short
git -C "$target" diff --check
```

The second preview must report the payload as `IDENTICAL`; report the checker
result and target diff/status exactly as observed.

## Boundaries and handoff

Never copy, link, chmod, patch, force, commit, revert, push, or otherwise
modify Friday, its payload, vendor Skills, or lock files for this workflow.
Friday's installer is the sole writer. Do not invent an adoption-record path:
record the pinned SHA and provenance in the target project's reviewed adoption
change using that project's established convention. Rollback belongs to the
target Git history through a reviewed revert or restoration of the selected
pin.
