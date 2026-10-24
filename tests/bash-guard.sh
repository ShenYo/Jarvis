#!/usr/bin/env bash
# Probe corpus for .agents/claude-guard/bash-guard.py.
#
# Each case feeds the hook the JSON a PreToolUse event carries and compares its
# answer: deny, ask, or allow (the hook said nothing, so the normal permission
# flow decides). The deny cases include every spelling an independent review
# found getting past the text-matching permission rules; the allow cases are
# ordinary work the hook must not get in the way of.
#
# Sandboxes are left in place; see tests/claude-guard.sh for why.
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
hook="${BASH_GUARD:-$repo/.agents/claude-guard/bash-guard.py}"
py=$(command -v /usr/bin/python3 || command -v python3)
root=$(mktemp -d "${TMPDIR:-/tmp}/bash-guard-test.XXXXXX")

# A repository on a feature branch, and one on main, for the push cases.
git_init() {
  git init -q -b main "$1"
  git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
}
feat="$root/feat"; onmain="$root/onmain"
git_init "$feat"; git -C "$feat" switch -q -c feat/x
git_init "$onmain"
git init -q --bare "$root/local.git"
git_init "$root/sandbox"; git -C "$root/sandbox" remote add origin "$root/local.git"
git -C "$onmain" remote add origin git@github.com:example/shared.git
git -C "$feat" config alias.nuke '!git branch -D "$@"'
git -C "$feat" config alias.yolo 'push --force'
git -C "$feat" config alias.st 'status'
for k in 1 2 3 4 5 6 7 8 9; do git -C "$feat" config "alias.a$k" "a$((k + 1))"; done
git -C "$feat" config alias.a10 'branch -D'

# Bare pushes that reach the default branch through configuration.
shared=git@github.com:example/shared.git
for name in matching upstream pushref pushremote pushurl fileurl develop nested; do
  git_init "$root/$name"
  git -C "$root/$name" remote add origin "$shared"
done
git -C "$root/matching" switch -q -c feat/m
git -C "$root/matching" config push.default matching
git -C "$root/upstream" switch -q -c feat/u
git -C "$root/upstream" config push.default upstream
git -C "$root/upstream" config branch.feat/u.remote origin
git -C "$root/upstream" config branch.feat/u.merge refs/heads/main
git -C "$root/pushref" switch -q -c feat/p
git -C "$root/pushref" config remote.origin.push 'HEAD:refs/heads/main'
git -C "$root/pushremote" remote add scratch "$root/local.git"
git -C "$root/pushremote" config branch.main.remote scratch
git -C "$root/pushremote" config branch.main.pushRemote origin
git -C "$root/pushurl" remote set-url origin "$root/local.git"
git -C "$root/pushurl" config remote.origin.pushurl "$shared"
git -C "$root/fileurl" remote set-url origin file:///nonexistent/shared.git
git -C "$root/develop" update-ref refs/remotes/origin/develop HEAD
git -C "$root/develop" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
git -C "$root/nested" update-ref refs/remotes/origin/release/v2 HEAD
git -C "$root/nested" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/release/v2
cat >"$root/sandbox/q.json" <<'EOF'
{"query": "mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }"}
EOF

fails=0
total=0
probe() { # expected, command, [cwd]
  local want=$1 cmd=$2 dir=${3:-$feat} got
  got=$(jq -n --arg c "$cmd" --arg d "$dir" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' |
    "$py" -I "$hook" | jq -r '.hookSpecificOutput.permissionDecision // empty')
  got=${got:-allow}
  total=$((total + 1))
  if [ "$got" = "$want" ]; then
    printf 'ok   %-5s %s\n' "$want" "${cmd//$'\n'/⏎}"
  else
    printf 'FAIL want %s got %s: %s\n' "$want" "$got" "${cmd//$'\n'/⏎}"
    fails=$((fails + 1))
  fi
}

echo "== spellings that got past the text rules"
probe deny 'git commit -an -m wip'
probe deny 'git -C . branch -D t1'
probe deny 'bash -c "git branch -D t3"'
probe deny 'rm -vrf junkdir'
probe deny 'git checkout HEAD -- file.txt'
probe deny '/usr/bin/git branch -D t2'
probe deny 'git -C . reset --hard HEAD'
probe deny 'eval "git clean -fdx"'
probe deny 'GIT_CONFIG_PARAMETERS="'"'"'core.hooksPath=/dev/null'"'"'" git commit -m x'
probe deny '/opt/homebrew/bin/gh pr merge 12 --delete-branch'
probe deny 'git update-ref -d refs/heads/x'
probe deny 'git restore .'
probe deny 'python3 -c "import shutil; shutil.rmtree(\"build\")"'
probe deny 'git commit --no-veri -m x'
probe deny 'git push --force-with-lease origin feat/x'

echo "== the prohibitions, in other wrappers"
probe deny 'sh -lc "git push -f origin feat/x"'
probe deny 'echo $(git branch -d old)'
probe deny 'x=`git stash drop`'
probe deny 'cd /tmp && git -C "$OLDPWD" worktree remove ../wt'
probe deny 'env FOO=1 git tag -d v1'
probe deny 'timeout 30 git push origin :feat/x'
probe deny 'ls | xargs rm -rf'
probe deny 'find . -name "*.tmp" -delete'
probe deny 'find . -type d -exec rm -r {} +'
probe deny 'git push origin +feat/x'
probe deny 'git push --mirror backup'
probe deny 'git push origin --delete feat/x'
probe deny 'git -c core.hookspath=/dev/null commit -m x'
probe deny 'git config core.hooksPath /dev/null'
probe deny 'git config --unset core.hooksPath'
probe deny 'git config unset core.hooksPath'
probe deny 'git config --global core.hooksPath ""'
probe deny 'git remote set-url origin git@example.invalid:x/y.git'
probe deny 'git config remote.origin.url https://example.invalid/x.git'
probe deny 'git switch --discard-changes main'
probe deny 'git checkout -f main'
probe deny 'git reset --keep HEAD~1'
probe deny 'git rm --cached secrets.env'
probe deny 'git reflog expire --expire=now --all'
probe deny 'git filter-branch --tree-filter true HEAD'
probe deny 'git nuke feat/x'
probe deny 'git yolo origin feat/x'
probe deny 'HUSKY=0 git commit -m x'
probe deny 'export GIT_CONFIG_KEY_0=core.hooksPath'
probe deny 'trap '"'"'rm -rf "$tmp"'"'"' EXIT'
probe deny 'node -e "require(\"child_process\").execSync(\"git push --force\")"'
probe deny 'python3 -c "import subprocess; subprocess.run([\"git\", \"branch\", \"-D\", \"x\"])"'
probe deny 'gh repo delete ShenYo/x --yes'
probe deny 'gh release delete v1'
probe deny 'gh api -X DELETE repos/o/r/git/refs/heads/x'
probe deny 'gh api --method=delete repos/o/r/git/refs/heads/x'
probe deny 'gh api graphql -f query="mutation { deleteRef(input: {refId: \"x\"}) { clientMutationId } }"'
probe deny "$(printf 'bash <<'"'"'EOF'"'"'\ngit branch -D x\nEOF')"
probe deny "$(printf 'python3 - <<EOF\nimport shutil\nshutil.rmtree("x")\nEOF')"
probe deny 'for b in a c; do git branch -D "$b"; done'
probe deny 'if true; then rm -r x; fi'

echo "== spellings a review of the hook found"
probe deny 'git -c alias.zap="branch -D" zap x'
probe deny 'git a1 x'
probe deny 'sudo --user root git branch -D x'
probe deny 'sudo -u root -- git branch -D x'
probe deny 'exec -a label git branch -D x'
probe deny 'nice --adjustment 5 git branch -D x'
probe deny 'nice --adjustment=5 git push -f origin x'
probe deny 'timeout --signal=KILL 5 git push -f origin x'
probe deny 'xargs -n1 -I{} git branch -D {}'
probe deny 'env -S "HUSKY=0 git commit -m x"'
probe deny 'env -i - git branch -D x'
probe deny '2>/dev/null git branch -D x'
probe deny "\$'git' branch -D x"
probe deny "\$'\\x67it' branch -D x"
probe deny "trap -- 'git branch -D x' EXIT"
probe deny "$(printf 'cat <<%sEOF%s | bash\ngit branch -D x\nEOF' "'" "'")"
probe deny 'echo "git push --force origin x" | sh'
probe deny "printf 'git clean -fdx\\n' | bash"
probe deny "$(printf 'cat <<EOF | python3\nimport shutil; shutil.rmtree("x")\nEOF')"
probe deny 'bash -o pipefail -c "git branch -D stale"'
probe deny 'bash -O extglob -c "rm -rf x"'
probe deny 'git config --remove-section core'
probe deny 'git config --rename-section remote.origin remote.old'
probe deny 'git push --repo origin +feat/x'
probe deny 'gh api graphql -f query="mutation { deleteIssue(input: {issueId: \"x\"}) { clientMutationId } }"'
probe deny "$(printf 'gh api graphql --input - <<%sEOF%s\n{"query": "mutation { deleteRef(input: {refId: \\"x\\"}) { clientMutationId } }"}\nEOF' "'" "'")"

echo "== checkpoints a review of the hook found"
probe ask 'git config --edit'
probe ask 'git push --repo=origin main' "$onmain"
probe ask 'git push' "$root/matching"
probe ask 'git push' "$root/upstream"
probe ask 'git push' "$root/pushref"
probe ask 'git push' "$root/pushremote"
probe ask 'git push origin main' "$root/pushurl"
probe ask 'git push' "$root/fileurl"
probe ask 'git push origin develop' "$root/develop"
probe ask 'git push origin release/v2' "$root/nested"
probe ask "cd $onmain && cd $feat && cd - && git push"
probe ask "(cd $feat); git push" "$onmain"
probe ask "pushd $onmain && git push"
probe ask 'gh api graphql --input q.json' "$root/sandbox"
probe ask 'gh api graphql --input missing.json' "$root/sandbox"
probe ask 'gh api -X PATCH repos/o/r/git/refs/heads/main -f sha=abc'

echo "== human-review checkpoints"
probe ask 'gh pr merge 12 --squash --match-head-commit abc'
probe ask 'gh -R ShenYo/Jarvis pr merge 12'
probe ask 'gh pr close 12'
probe ask 'gh pr review 12 --approve'
probe ask 'gh pr review 12 -a -b ok'
probe ask 'gh api -X PUT repos/o/r/pulls/12/merge'
probe ask 'gh api repos/o/r/pulls/12/reviews -f event=APPROVE'
probe ask 'gh api graphql -f query="mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }"'
probe ask 'gh api -X PATCH repos/o/r -f visibility=public'
probe ask 'gh api -X PUT repos/o/r/branches/main/protection --input p.json'
probe ask 'gh repo edit --visibility public'
probe ask 'gh pr comment 12 --body "/merge"'
probe ask 'git push origin main'
probe ask 'git push origin HEAD:main'
probe ask 'git push origin feat/x:refs/heads/master'
probe ask 'git push' "$onmain"
probe ask 'git push -u origin HEAD' "$onmain"
probe ask 'git config core.hooksPath payload/.agents/githooks'

echo "== ordinary work that must pass"
probe allow 'git status --short'
probe allow 'git commit -m "docs: mention grep -n usage"'
probe allow 'git commit -m "docs: explain why --no-verify is refused"'
probe allow "$(printf 'git commit -F - <<'"'"'EOF'"'"'\nfix: refuse git push --force and rm -rf\n\nBody mentions git branch -D too.\nEOF')"
probe allow "$(printf 'git commit -m "$(cat <<'"'"'EOF'"'"'\nfeat: x\n\ngit reset --hard is refused\nEOF\n)"')"
probe allow 'git commit -m -n'
probe allow 'git push -u origin feat/x'
probe allow 'git push'
probe allow 'git push origin domain'
probe allow 'git push origin feat/main-menu'
probe allow 'git push --dry-run origin feat/x'
probe allow 'git push --dry-run origin HEAD:main' "$onmain"
probe allow 'git push -n origin main' "$onmain"
probe allow 'git push -u origin main' "$root/sandbox"
probe allow 'git push' "$root/sandbox"
probe deny 'git push --force origin main' "$root/sandbox"
probe allow 'git checkout -b feat/y'
probe allow 'git switch -c feat/z'
probe allow 'git restore --staged secrets.env'
probe allow 'git restore -S a b'
probe allow 'git clean -n'
probe allow 'git clean -nd'
probe allow 'git stash'
probe allow 'git stash pop'
probe allow 'git branch -vv'
probe allow 'git branch --show-current'
probe allow 'git tag -l'
probe allow 'git config --get core.hooksPath'
probe allow 'git config core.hooksPath'
probe allow 'git log --oneline --grep "reset --hard"'
probe allow 'git st'
probe allow 'git worktree add ../wt -b feat/w'
probe allow 'git rebase -i main'
probe allow 'rm -f a.txt'
probe allow 'rm -- -r'
probe allow 'grep -rn "rm -rf" .'
probe allow 'echo "git push --force is refused"'
probe allow 'find . -name "*.md" -print'
probe allow 'gh pr view 12 --json state'
probe allow 'gh pr create --title x --body "Merging is the owner'"'"'s"'
probe allow 'gh pr comment 12 --body "please merge when ready"'
probe allow 'gh api repos/o/r/pulls/12/merge'
probe allow 'gh api repos/o/r/rulesets'
probe allow 'gh api graphql -f query="query { viewer { login } }"'
probe allow 'gh api -X POST repos/o/r/pulls/12/comments/1/replies -f body=thanks'
probe allow 'python3 -c "import json; print(json.dumps({\"git\": 1}))"'
probe allow 'ls -la ~/.claude'
probe allow 'git config get core.hooksPath'
probe allow "$(printf 'python3 - doc.md <<'"'"'PY'"'"'\ns = open("doc.md").read()\ns = s.replace("git rm", "git restore --staged")\nprint("rm -rf and git push --force are refused")\nPY')"
probe allow "$(printf 'python3 - <<'"'"'PY'"'"'\nprint("shutil.rmtree is refused")\nPY')"
probe allow "$(printf 'python3 - README.md <<'"'"'PY'"'"'\ns = open("README.md").read().replace("`git rm`", "`git restore --staged`")\nPY')"
probe allow "$(printf 'for h in a b; do\n  git add "$h"  # the hook'"'"'s copy\ndone')"
probe allow 'echo see README.md#hooks'
probe allow 'bash -o pipefail -c "git status"'
probe allow 'echo "git push --force is refused" | tee notes.txt'
probe allow 'cat notes.md | grep "git rm"'
probe allow "(cd $onmain && git status); git push" "$feat"
probe allow "cd $onmain && cd - >/dev/null && git push" "$feat"
probe allow 'git config --get-regexp alias'
probe allow "\$'echo' hi"
probe allow 'xargs -0 -n1 echo < list.txt'
probe allow 'git push origin develop' "$onmain"
probe allow 'gh api graphql -f query="query { repository(owner: \"o\", name: \"r\") { viewerCanDelete } }"'

echo
if [ "$fails" -gt 0 ]; then echo "$fails of $total failed (sandboxes: $root)"; exit 1; fi
echo "all $total passed"
