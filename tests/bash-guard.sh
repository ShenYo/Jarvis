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

# Hermetic: this suite may run inside an agent session whose environment carries the applied
# identity; none of it may reach the hook. Every case sets what it needs.
for v in $(compgen -e | grep -E '^(GIT_CONFIG_|GIT_AUTHOR_|GIT_COMMITTER_)'); do unset "$v"; done
unset GIT_SSH_COMMAND GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GH_CONFIG_DIR GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN \
  GITHUB_ENTERPRISE_TOKEN GH_HOST JARVIS_AGENT_IDENTITY JARVIS_REQUIRE_AGENT_IDENTITY CODEX_HOME CLAUDE_CONFIG_DIR XDG_CONFIG_HOME

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
hook="${BASH_GUARD:-$repo/.agents/claude-guard/bash-guard.py}"
py=$(command -v /usr/bin/python3 || command -v python3)
root=$(mktemp -d "${TMPDIR:-/tmp}/bash-guard-test.XXXXXX")
# The corpus below runs with the agent-identity switch off, whatever this
# machine has set; the switch's own cases set it themselves.
unset JARVIS_REQUIRE_AGENT_IDENTITY JARVIS_AGENT_IDENTITY
# The hook falls back to ~/.claude and ~/.codex for its records; point both at empty
# directories, so this machine's own applied identity never reaches a case.
no_claude="$root/no-claude"; no_codex="$root/no-codex"; mkdir -p "$no_claude" "$no_codex"
# The guard also reads the default ~/.claude for the require record, so HOME is an empty directory too.
mkdir -p "$root/home"; export HOME="$root/home"
export CLAUDE_CONFIG_DIR="$no_claude" CODEX_HOME="$no_codex"
hook_args=""
# An applied identity: the marker, the environment apply-agent-identity.sh writes,
# and the record of it that the hook compares that environment with.
applied_home="$root/applied-home"; mkdir -p "$applied_home"
jq -n '{version: 1, env: {GH_CONFIG_DIR: "/agent/gh", GIT_SSH_COMMAND: "ssh -F /dev/null -i /agent/key -o IdentitiesOnly=yes",
  GIT_CONFIG_COUNT: "2", GIT_CONFIG_KEY_0: "url.git@github.com:.insteadOf", GIT_CONFIG_VALUE_0: "https://github.com/",
  GIT_CONFIG_KEY_1: "credential.helper", GIT_CONFIG_VALUE_1: "", GIT_AUTHOR_NAME: "Claude Code"}}' >"$applied_home/agent-identity.applied.json"
apply_identity() {
  export JARVIS_AGENT_IDENTITY=some-agent CLAUDE_CONFIG_DIR="$applied_home"
  export GH_CONFIG_DIR=/agent/gh GIT_SSH_COMMAND="ssh -F /dev/null -i /agent/key -o IdentitiesOnly=yes"
  export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=url.git@github.com:.insteadOf GIT_CONFIG_VALUE_0=https://github.com/
  export GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1=
}
drop_identity() {
  export CLAUDE_CONFIG_DIR="$no_claude"
  unset JARVIS_AGENT_IDENTITY GH_CONFIG_DIR GIT_SSH_COMMAND GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 \
    GIT_CONFIG_VALUE_0 GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1 GIT_CONFIG_KEY_2 GIT_CONFIG_VALUE_2
}

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
git_init "$root/https"; git -C "$root/https" switch -q -c feat/h
git -C "$root/https" remote add origin https://github.com/example/shared.git
# Release tags: one in a repository with a shared remote, one in a scratch one.
git -C "$onmain" tag v1.0.0
git -C "$root/sandbox" tag v1.0.0
git -C "$feat" config alias.nuke '!git branch -D "$@"'
git -C "$feat" config alias.yolo 'push --force'
git -C "$feat" config alias.st 'status'
for k in 1 2 3 4 5 6 7 8 9; do git -C "$feat" config "alias.a$k" "a$((k + 1))"; done
git -C "$feat" config alias.a10 'branch -D'

# Bare pushes that reach the default branch through configuration.
shared=git@github.com:example/shared.git
for name in matching upstream pushref pushremote pushurl fileurl develop nested followtags; do
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
git -C "$root/followtags" config push.followTags true
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
  local want=$1 cmd=$2 dir=${3:-$feat} got out rc
  # A hook that does not answer within 5 s is a failure of its own: in a real
  # session it trips the hook timeout and blocks the call.
  jq -n --arg c "$cmd" --arg d "$dir" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' >"$root/in.json"
  out=$(perl -e 'alarm 5; exec @ARGV' "$py" -I "$hook" $hook_args <"$root/in.json"); rc=$?
  if [ "$rc" = 142 ]; then
    got=hang
  else
    got=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty')
    got=${got:-allow}
  fi
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
probe ask 'gh release create v1.0.0 --notes-from-tag'
probe ask 'gh release edit v1.0.0 --notes x'
probe ask 'gh release upload v1.0.0 build.zip'
probe ask 'gh api repos/o/r/releases -f tag_name=v1.0.0'
probe ask 'gh api -X PATCH repos/o/r/releases/123 -f body=x'
probe ask 'gh api repos/o/r/git/refs -f ref=refs/tags/v9.9.9 -f sha=abc'
probe allow 'gh release view v1.0.0'
probe allow 'gh release list'
probe allow 'gh api repos/o/r/releases'
probe allow 'gh api repos/o/r/git/refs -f ref=refs/heads/feat/x -f sha=abc'
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
echo "== pushing a release tag waits for the user"
probe ask 'git push origin v1.0.0' "$onmain"
probe ask 'git push origin refs/tags/v9.9.9' "$onmain"
probe ask 'git push origin v1.0.0:refs/tags/v1.0.0' "$onmain"
probe ask 'git push --tags origin feat/y' "$onmain"
probe ask 'git push --follow-tags origin feat/y' "$onmain"
probe ask 'git push origin feat/y' "$root/followtags"
probe allow 'git push origin feat/y' "$onmain"
probe allow 'git push origin v1.0.0' "$root/sandbox"
probe allow 'git push --dry-run --tags origin' "$onmain"

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
probe allow 'tr -dc A-Za-z0-9 </dev/urandom | head -c 8'
probe allow 'cat < /dev/zero | head -c 8'
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

echo "== agent identity: the switch is off unless JARVIS_REQUIRE_AGENT_IDENTITY=1"
export JARVIS_REQUIRE_AGENT_IDENTITY=0
probe allow 'gh pr create --title x --body y'
probe allow 'git push origin feat/y' "$onmain"
probe allow 'gh api -X POST repos/o/r/issues -f title=x'
export JARVIS_REQUIRE_AGENT_IDENTITY=
probe allow 'gh issue create --title x'
unset JARVIS_REQUIRE_AGENT_IDENTITY
probe allow 'gh release view v1.0.0'

echo "== agent identity: switch on, no identity on this machine -> GitHub writes are refused"
export JARVIS_REQUIRE_AGENT_IDENTITY=1
probe deny 'git push origin feat/y' "$onmain"
probe deny 'git push -u origin feat/x'
probe deny 'git push' "$feat"
probe deny 'cd '"$onmain"' && git push origin feat/y'
probe deny 'bash -c "gh pr create --title x"'
probe deny 'git push origin feat/y' "$root/https"
probe deny 'git push' "$root/https"
probe deny 'gh pr create --title x --body y'
probe deny 'gh -R o/r pr create --title x'
probe deny 'gh pr edit 12 --title x'
probe deny 'gh pr comment 12 --body hi'
probe deny 'gh pr review 12 --comment -b ok'
probe deny 'gh pr merge 12'
probe deny 'gh pr close 12'
probe deny 'gh pr reopen 12'
probe deny 'gh issue create --title x'
probe deny 'gh issue edit 3 --title y'
probe deny 'gh issue comment 3 --body hi'
probe deny 'gh issue close 3'
probe deny 'gh issue reopen 3'
probe deny 'gh release create v2.0.0 --notes x'
probe deny 'gh release edit v1.0.0 --notes x'
probe deny 'gh release upload v1.0.0 build.zip'
probe deny 'gh repo create ShenYo/x --private'
probe deny 'gh repo edit --description x'
probe deny 'gh repo fork o/r'
probe deny 'gh api -X POST repos/o/r/issues -f title=x'
probe deny 'gh api repos/o/r/issues -f title=x'
probe deny 'gh api -X PATCH repos/o/r/issues/3 -f state=closed'
probe deny 'gh api --method=put repos/o/r/topics'
probe deny 'gh api graphql -f query="mutation { addComment(input: {subjectId: \"x\", body: \"y\"}) { clientMutationId } }"'
probe deny 'gh api graphql --input missing.json' "$root/sandbox"
echo "== agent identity: switch on, no identity -> reads and local work stay allowed"
probe allow 'gh pr view 12 --json state'
probe allow 'gh pr list'
probe allow 'gh pr diff 12'
probe allow 'gh pr checkout 12'
probe allow 'gh issue view 3'
probe allow 'gh issue list'
probe allow 'gh repo view o/r'
probe allow 'gh release view v1.0.0'
probe allow 'gh api repos/o/r'
probe allow 'gh api -X GET repos/o/r/issues -f per_page=1'
probe allow 'gh api graphql -f query="query { viewer { login } }"'
probe allow 'git fetch origin'
probe allow 'git status --short'
probe allow 'git commit -m "docs: mention gh pr create"'
probe allow 'git push --dry-run origin feat/x'
probe allow 'git push --dry-run origin feat/y' "$root/https"
probe allow 'git push -u origin feat/x' "$root/sandbox"
probe allow 'echo "gh pr create is refused"'
export JARVIS_AGENT_IDENTITY="   "
probe deny 'gh pr create --title x'
echo "== agent identity: switch on, identity present -> exactly the usual behaviour"
apply_identity
probe allow 'gh pr create --title x --body y'
probe allow 'git push origin feat/y' "$onmain"
probe allow 'git push origin feat/y' "$root/https"
probe ask 'git push origin main' "$root/https"
probe allow 'gh api -X POST repos/o/r/issues -f title=x'
probe allow 'gh issue create --title x'
probe ask 'gh pr merge 12'
probe ask 'gh pr review 12 --approve'
probe ask 'git push origin main'
probe ask 'gh release create v2.0.0 --notes x'
probe deny 'git push --force origin feat/x'
probe deny 'gh api -X DELETE repos/o/r/git/refs/heads/x'
echo "== agent identity: the same in Codex mode, where an ask is a deny anyway"
# Codex mode reads the switch from the hook's --require-identity argument only, and counts only a
# Codex record as the applied identity: the marker in the environment, which the Claude Code
# session sets, means nothing to it. (Changed from before: with the marker and no record the
# answer was allow; with the environment switch and no marker it was deny.)
hook_args="--codex --require-identity"
probe deny 'gh pr create --title x'
probe deny 'git push origin feat/y' "$onmain"
probe deny 'gh pr merge 12'
probe allow 'gh pr view 12'
drop_identity
probe deny 'gh pr create --title x'
probe deny 'git push origin feat/y' "$onmain"
probe allow 'gh pr view 12'
hook_args="--codex"
probe allow 'gh pr create --title x'
probe allow 'git push origin feat/y' "$onmain"
probe deny 'gh pr merge 12'
hook_args=""
unset JARVIS_REQUIRE_AGENT_IDENTITY

echo "== agent identity: switch on, no identity -> every gh subcommand that is not a known read is a write"
export JARVIS_REQUIRE_AGENT_IDENTITY=1
for c in 'gh pr ready 12' 'gh pr update-branch 12' 'gh pr lock 12' 'gh issue transfer 3 o/r' 'gh issue lock 3' \
         'gh issue pin 3' 'gh issue develop 3 -b x' 'gh repo sync' 'gh repo deploy-key add key.pub' \
         'gh workflow run ci.yml' 'gh workflow enable ci.yml' 'gh run rerun 1' 'gh run cancel 1' 'gh label create bug' \
         'gh secret set X' 'gh variable set X' 'gh gist create f.txt' 'gh ssh-key add k.pub' 'gh gpg-key add k.asc' \
         'gh auth login' 'gh auth refresh' 'gh alias set x y' 'gh codespace create' 'gh ruleset check' 'gh browse' \
         'gh extension install o/ext' 'gh cache delete 1' 'gh somefuturecommand now'; do
  probe deny "$c"
done
probe deny 'bash -c "gh workflow run ci.yml"'
probe deny 'xargs gh label create < labels.txt'
echo "== agent identity: switch on, no identity -> the known read-only gh forms"
for c in 'gh pr status' 'gh issue status' 'gh pr checks 12' 'gh pr view 12' 'gh pr diff 12' 'gh pr list' 'gh search issues bug' \
         'gh search repos x' 'gh status' 'gh browse --no-browser' 'gh browse -n' 'gh auth status' 'gh --help' 'gh help' \
         'gh --version' 'gh version' 'gh pr create --help' 'gh pr' 'gh run view 1' 'gh run list' 'gh label list' \
         'gh secret list' 'gh repo clone o/r' 'gh run watch 1' 'gh release download v1.0.0' 'gh api repos/o/r' \
         'gh api graphql -f query="query { viewer { login } }"'; do
  probe allow "$c"
done
unset JARVIS_REQUIRE_AGENT_IDENTITY

echo "== agent identity applied: no GitHub write while something overrides who it acts as"
apply_identity
for var in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST GIT_CONFIG_PARAMETERS; do
  export "$var=x"
  probe deny 'gh pr create --title t'
  probe deny 'git push origin feat/y'
  probe deny 'gh api -X POST repos/o/r/issues -f title=x'
  probe allow 'gh pr view 12'
  probe allow 'git fetch origin'
  unset "$var"
done
export GH_TOKEN=x
drop_identity
probe allow 'gh pr create --title t'
export JARVIS_REQUIRE_AGENT_IDENTITY=1
probe deny 'gh pr create --title t'
unset JARVIS_REQUIRE_AGENT_IDENTITY GH_TOKEN
apply_identity
for sw in off on; do
  [ "$sw" = on ] && export JARVIS_REQUIRE_AGENT_IDENTITY=1
  probe deny 'GH_TOKEN=x gh pr create --title t'
  probe deny 'GITHUB_TOKEN=x gh pr create --title t'
  probe deny 'GH_ENTERPRISE_TOKEN=x gh pr create --title t'
  probe deny 'GH_CONFIG_DIR=/x gh pr create --title t'
  probe deny 'GH_HOST=h.example gh pr create --title t'
  probe deny 'GIT_SSH_COMMAND="ssh -i /x" git push origin feat/y'
  probe deny 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.x.insteadOf GIT_CONFIG_VALUE_0=y git push origin feat/y'
  probe deny 'GIT_CONFIG_PARAMETERS=x git push origin feat/y'
  probe deny 'env GH_TOKEN=x gh pr create --title t'
  probe deny 'env -u GH_CONFIG_DIR gh pr create --title t'
  probe deny 'env -u GIT_SSH_COMMAND git push origin feat/y'
  probe deny 'env --unset=GH_CONFIG_DIR gh pr create --title t'
  probe deny 'unset GH_CONFIG_DIR; gh pr create --title t'
  probe deny 'unset GIT_CONFIG_COUNT && git push origin feat/y'
  probe deny 'export GH_TOKEN=x; gh pr create --title t'
  probe deny 'git -c credential.helper=store push origin feat/y'
  probe deny 'git -c url.https://x.example/.insteadOf=y push origin feat/y'
  probe deny 'git -c core.sshCommand=ssh push origin feat/y'
  probe deny 'git -c http.extraheader=x push origin feat/y'
  probe deny 'git --config-env=credential.helper=HELPER push origin feat/y'
  probe deny 'bash -c "GH_TOKEN=x gh pr create --title t"'
  probe allow 'GH_TOKEN=x gh pr view 12'
  probe allow 'git -c credential.helper=store fetch origin'
  probe allow 'env -u GH_CONFIG_DIR gh pr list'
  probe allow 'unset GH_TOKEN; gh pr view 12'
  probe allow 'FOO=1 gh pr create --title x'
  probe allow 'git -c core.editor=true push origin feat/y'
  probe allow 'git -c user.name=x push origin feat/y'
done
unset JARVIS_REQUIRE_AGENT_IDENTITY; drop_identity
echo "== agent identity applied: an empty environment, and the GIT_CONFIG_* variables that count"
apply_identity
probe deny 'env -i gh pr create --title t'
probe deny 'env --ignore-environment gh pr create --title t'
probe deny 'env - gh pr create --title t'
probe deny 'env -i PATH=/usr/bin git push origin feat/y'
probe deny 'env -iu FOO gh pr create --title t'
probe deny 'env -i bash -c "gh pr create --title t"'
probe allow 'env -i gh pr view 12'
probe allow 'env FOO=1 gh pr create --title t'
probe allow 'env -u FOO gh pr create --title t'
probe deny 'GIT_CONFIG_GLOBAL=/x git push origin feat/y'
probe deny 'GIT_CONFIG_SYSTEM=/x git push origin feat/y'
probe deny 'GIT_CONFIG_KEY_7=a.b git push origin feat/y'
probe deny 'GIT_CONFIG_VALUE_3=a git push origin feat/y'
probe deny 'GIT_CONFIG_COUNT=0 git push origin feat/y'
probe allow 'GIT_CONFIG_NOSYSTEM=1 git push origin feat/y'
probe allow 'GIT_CONFIG_NOSYSTEM=1 gh pr create --title t'
drop_identity
echo "== agent identity applied: the hook's environment must still be what was applied"
apply_identity
probe allow 'gh pr create --title t'
probe allow 'git push origin feat/y'
for var in GH_CONFIG_DIR GIT_SSH_COMMAND GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1; do
  saved=${!var}
  export "$var=/other"
  probe deny 'gh pr create --title t'
  probe deny 'git push origin feat/y'
  probe allow 'gh pr view 12'
  export "$var=$saved"
done
export GH_CONFIG_DIR=/other
reason=$(jq -n --arg d "$feat" '{tool_name: "Bash", tool_input: {command: "gh pr create --title t"}, cwd: $d}' | "$py" -I "$hook" | jq -r '.hookSpecificOutput.permissionDecisionReason')
total=$((total + 1))
if printf '%s' "$reason" | grep -qF 'differs from the applied identity in GH_CONFIG_DIR' && printf '%s' "$reason" | grep -qF 'apply-agent-identity.sh --check'; then
  echo "ok   the reason names the variable that differs and the --check command"
else
  echo "FAIL the reason names the variable that differs and the --check command: $reason"; fails=$((fails + 1))
fi
export GH_CONFIG_DIR=/agent/gh
unset GIT_CONFIG_COUNT
probe deny 'gh pr create --title t'
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_2=core.editor
probe deny 'gh pr create --title t'
unset GIT_CONFIG_KEY_2
export GIT_CONFIG_VALUE_2=x
probe deny 'git push origin feat/y'
unset GIT_CONFIG_VALUE_2
probe allow 'gh pr create --title t'
echo "== agent identity applied: no record to compare with means no GitHub write"
export CLAUDE_CONFIG_DIR="$root/no-such-claude-home"
probe deny 'gh pr create --title t'
probe deny 'git push origin feat/y'
probe allow 'gh pr view 12'
mkdir -p "$root/bad-home"; echo '{ not json' >"$root/bad-home/agent-identity.applied.json"
export CLAUDE_CONFIG_DIR="$root/bad-home"
probe deny 'gh pr create --title t'
jq -n --arg d "$feat" '{tool_name: "Bash", tool_input: {command: "gh pr create --title t"}, cwd: $d}' >"$root/in.json"
reason=$("$py" -I "$hook" <"$root/in.json" | jq -r '.hookSpecificOutput.permissionDecisionReason')
total=$((total + 1))
if printf '%s' "$reason" | grep -qF 'is missing or unreadable' && printf '%s' "$reason" | grep -qF 'bash ~/.Jarvis/scripts/apply-agent-identity.sh --check'; then
  echo "ok   a missing record is explained and points at --check"
else
  echo "FAIL a missing record is explained and points at --check: $reason"; fails=$((fails + 1))
fi
drop_identity

codex_fixture() { # dir: a CODEX_HOME whose record, config.toml block and gitconfig all agree
  local d=$1 blk sha
  mkdir -p "$d"
  blk=$'# >>> jarvis agent-identity: test\n[shell_environment_policy]\nset = { A = "1" }\n# <<< jarvis agent-identity\n'
  printf 'model = "x"\n\n%s' "$blk" >"$d/config.toml"
  printf '[credential]\n\thelper =\n' >"$d/agent-identity.gitconfig"
  sha=$("$py" -I -c 'import sys,hashlib; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$d/agent-identity.gitconfig")
  jq -n --arg block "$blk" --arg cfg "$d/config.toml" --arg gc "$d/agent-identity.gitconfig" --arg sha "$sha" \
    '{version: 1, set: {GH_CONFIG_DIR: "/agent/gh", JARVIS_AGENT_IDENTITY: "some-agent", GH_TOKEN: ""}, gitconfig: $gc, gitconfig_sha256: $sha, block: $block, prefix: "\n", config: $cfg}' >"$d/agent-identity.applied.json"
  CODEX_BLOCK=$blk
}
echo "== Codex: the identity is applied when the record is in CODEX_HOME (a Codex hook cannot see the policy's env)"
hook_args="--codex"
codex_home="$root/codex-home"; mkdir -p "$codex_home"
codex_fixture "$codex_home"
export CODEX_HOME="$codex_home"
for sw in off on; do
  [ "$sw" = on ] && hook_args="--codex --require-identity"
  probe deny 'GH_TOKEN=x gh pr create --title t'
  probe deny 'GITHUB_TOKEN=x gh pr create --title t'
  probe deny 'GH_HOST=h.example gh pr create --title t'
  probe deny 'GH_CONFIG_DIR=/x gh pr create --title t'
  probe deny 'GIT_CONFIG_GLOBAL=/x git push origin feat/x'
  probe deny 'GIT_CONFIG_SYSTEM=/x git push origin feat/x'
  probe deny 'GIT_SSH_COMMAND="ssh -i /x" git push origin feat/x'
  probe deny 'env -u GH_CONFIG_DIR gh pr create --title t'
  probe deny 'git -c credential.helper=store push origin feat/x'
  probe allow 'git push origin feat/x'
  probe allow 'gh pr create --title t'
  probe allow 'gh pr view 12'
  probe allow 'GH_TOKEN=x gh pr view 12'
done
hook_args="--codex"
echo "== Codex: the hook's own environment is not the command's, so it is not compared"
export GH_TOKEN=x GH_CONFIG_DIR=/other GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.editor GIT_CONFIG_VALUE_0=vim
probe allow 'gh pr create --title t'
probe allow 'git push origin feat/x'
probe deny 'GH_TOKEN=x gh pr create --title t'
unset GH_TOKEN GH_CONFIG_DIR GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
echo "== Codex: a record that cannot be read is a refusal"
mkdir -p "$root/codex-bad"; echo '{ not json' >"$root/codex-bad/agent-identity.applied.json"
export CODEX_HOME="$root/codex-bad"
probe deny 'gh pr create --title t'
probe deny 'git push origin feat/x'
probe allow 'gh pr view 12'
jq -n --arg d "$feat" '{tool_name: "Bash", tool_input: {command: "gh pr create --title t"}, cwd: $d}' >"$root/in.json"
reason=$("$py" -I "$hook" --codex <"$root/in.json" | jq -r '.hookSpecificOutput.permissionDecisionReason')
total=$((total + 1))
if printf '%s' "$reason" | grep -qF 'Codex agent identity record' && printf '%s' "$reason" | grep -qF 'is unreadable' && printf '%s' "$reason" | grep -qF 'apply-agent-identity.sh --check --codex'; then
  echo "ok   an unreadable record is explained and points at --check --codex"
else
  echo "FAIL an unreadable record is explained and points at --check --codex: $reason"; fails=$((fails + 1))
fi
echo '{"version": 1}' >"$root/codex-bad/agent-identity.applied.json"
probe deny 'gh pr create --title t'
rm -f "$root/codex-bad/agent-identity.applied.json"; mkdir "$root/codex-bad/agent-identity.applied.json"
probe deny 'gh pr create --title t'
# The record alone is not "applied": what it lists must still be there, byte for byte.
stale_case() { # name, mutation (run in the fixture dir)
  local d="$root/cx-$1"
  codex_fixture "$d"
  ( cd "$d" && eval "$2" )
  export CODEX_HOME="$d"
  probe deny 'gh pr create --title t'
  probe deny 'git push origin feat/x'
  probe allow 'gh pr view 12'
}
stale_case "block-gone" 'printf "model = \"x\"\n" >config.toml'
stale_case "block-edited" 'sed "s/A = \"1\"/A = \"2\"/" config.toml >c.new && mv c.new config.toml'
stale_case "block-twice" 'printf "%s" "$CODEX_BLOCK" >>config.toml'
stale_case "key-after-marker" 'printf "extra = 1\n" >>config.toml'
stale_case "comment-then-key-after-marker" 'printf "\n# note\nextra = 1\n" >>config.toml'
stale_case "gitconfig-gone" 'rm agent-identity.gitconfig'
stale_case "gitconfig-edited" 'printf "# x\n" >>agent-identity.gitconfig'
stale_case "config-gone" 'rm config.toml'
stale_case "record-lacks-config" 'jq "del(.config)" agent-identity.applied.json >r.new && mv r.new agent-identity.applied.json'
stale_case "record-empty-block" 'jq ".block = \"\"" agent-identity.applied.json >r.new && mv r.new agent-identity.applied.json'
jq -n --arg d "$feat" '{tool_name: "Bash", tool_input: {command: "gh pr create --title t"}, cwd: $d}' >"$root/in.json"
for what in gitconfig-gone block-gone gitconfig-edited; do
  export CODEX_HOME="$root/cx-$what"
  reason=$("$py" -I "$hook" --codex <"$root/in.json" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  total=$((total + 1))
  if printf '%s' "$reason" | grep -qF 'apply-agent-identity.sh --check --codex'; then
    echo "ok   $what: the reason names --check --codex"
  else
    echo "FAIL $what: the reason names --check --codex: $reason"; fails=$((fails + 1))
  fi
done
# a blank line, a comment and then a table after the block is fine
codex_fixture "$root/cx-table-after"; printf '\n# note\n[other]\nextra = 1\n' >>"$root/cx-table-after/config.toml"
export CODEX_HOME="$root/cx-table-after"
probe allow 'gh pr create --title t'
echo "== Codex: no record means nothing changes"
mkdir -p "$root/codex-none"; export CODEX_HOME="$root/codex-none"
probe allow 'GH_TOKEN=x gh pr create --title t'
probe allow 'GIT_CONFIG_GLOBAL=/x git push origin feat/x'
probe allow 'gh pr create --title t'
# The environment variable is Claude Code's switch; a Codex hook ignores it.
export JARVIS_REQUIRE_AGENT_IDENTITY=1
probe allow 'gh pr create --title t'
probe allow 'git push origin feat/y' "$onmain"
unset JARVIS_REQUIRE_AGENT_IDENTITY
echo "== Codex: the switch is the hook's --require-identity argument, and only that"
hook_args="--codex --require-identity"
probe deny 'gh pr create --title t'
probe deny 'git push origin feat/y' "$onmain"
probe deny 'gh api -X POST repos/o/r/issues -f title=x'
probe allow 'gh pr view 12'
probe allow 'git fetch origin'
probe allow 'git push --dry-run origin feat/x'
# a marker inherited from a Claude Code session does not make the identity applied
export JARVIS_AGENT_IDENTITY=some-agent
probe deny 'gh pr create --title t'
probe deny 'git push origin feat/y' "$onmain"
probe deny 'git push origin feat/y' "$root/https"
unset JARVIS_AGENT_IDENTITY
# with a sound record, the identity is applied and the switch changes nothing
export CODEX_HOME="$codex_home"
probe allow 'gh pr create --title t'
probe allow 'git push origin feat/y' "$onmain"
probe deny 'GH_TOKEN=x gh pr create --title t'
# with a record that fails, the switch says so too
export CODEX_HOME="$root/cx-gitconfig-gone"
probe deny 'gh pr create --title t'
probe allow 'gh pr view 12'
export CODEX_HOME="$root/codex-none"
hook_args="--codex"
echo "== Claude Code: a Codex record changes nothing"
hook_args=""
export CODEX_HOME="$codex_home"
probe allow 'GH_TOKEN=x gh pr create --title t'
probe allow 'GIT_CONFIG_GLOBAL=/x git push origin feat/x'
export CODEX_HOME="$no_codex"

echo "== agent identity: the --require record keeps the switch on in Claude mode, whatever the environment says"
rec_home="$root/require-home"; mkdir -p "$rec_home"
echo '{"version": 1, "env": {"JARVIS_REQUIRE_AGENT_IDENTITY": "1"}, "env_created": false}' >"$rec_home/agent-identity.require.json"
export CLAUDE_CONFIG_DIR="$rec_home"
probe deny 'gh pr create --title t'
probe deny 'git push origin feat/y' "$onmain"
probe allow 'gh pr view 12'
export JARVIS_REQUIRE_AGENT_IDENTITY=      # a project's env blanks the variable
probe deny 'gh pr create --title t'
export JARVIS_REQUIRE_AGENT_IDENTITY=0
probe deny 'gh pr create --title t'
unset JARVIS_REQUIRE_AGENT_IDENTITY
# with the identity applied the usual behaviour follows, record or not
cp "$applied_home/agent-identity.applied.json" "$rec_home/agent-identity.applied.json"
apply_identity; export CLAUDE_CONFIG_DIR="$rec_home"
probe allow 'gh pr create --title t'
probe deny 'GH_TOKEN=x gh pr create --title t'
drop_identity
# a readable record that does not say "1" leaves the switch off
export CLAUDE_CONFIG_DIR="$rec_home"
echo '{"env": {"JARVIS_REQUIRE_AGENT_IDENTITY": "0"}}' >"$rec_home/agent-identity.require.json"
probe allow 'gh pr create --title t'
echo '{"version": 1}' >"$rec_home/agent-identity.require.json"
probe allow 'gh pr create --title t'
# a record that exists but cannot be read, or is not a record, counts as ON (the guard fails closed)
for bad in '{ not json' '[]' '"x"' '{"env": 5}' ''; do
  printf '%s' "$bad" >"$rec_home/agent-identity.require.json"
  probe deny 'gh pr create --title t'
  probe allow 'gh pr view 12'
done
rm -f "$rec_home/agent-identity.require.json"; mkdir "$rec_home/agent-identity.require.json"
probe deny 'gh pr create --title t'
rmdir "$rec_home/agent-identity.require.json"
printf '{ not json' >"$rec_home/agent-identity.require.json"
reason=$("$py" -I "$hook" <"$root/in.json" | jq -r '.hookSpecificOutput.permissionDecisionReason')
total=$((total + 1))
if printf '%s' "$reason" | grep -qF "$rec_home/agent-identity.require.json exists but cannot be read as a require record, which counts as on"; then
  echo "ok   an unreadable record is named in the refusal, with its path"
else
  echo "FAIL an unreadable record is named in the refusal, with its path: $reason"; fails=$((fails + 1))
fi
# the record is looked up in the default ~/.claude too: a project that points CLAUDE_CONFIG_DIR elsewhere cannot hide it
mkdir -p "$HOME/.claude"
echo '{"version": 1, "env": {"JARVIS_REQUIRE_AGENT_IDENTITY": "1"}}' >"$HOME/.claude/agent-identity.require.json"
export CLAUDE_CONFIG_DIR="$no_claude" JARVIS_REQUIRE_AGENT_IDENTITY=
probe deny 'gh pr create --title t'
probe deny 'git push origin feat/y' "$onmain"
probe allow 'gh pr view 12'
export CLAUDE_CONFIG_DIR="$root/does-not-exist"
probe deny 'gh pr create --title t'
unset CLAUDE_CONFIG_DIR JARVIS_REQUIRE_AGENT_IDENTITY
probe deny 'gh pr create --title t'
echo '{"env": {"JARVIS_REQUIRE_AGENT_IDENTITY": "0"}}' >"$HOME/.claude/agent-identity.require.json"
export CLAUDE_CONFIG_DIR="$no_claude"
probe allow 'gh pr create --title t'
rm -f "$HOME/.claude/agent-identity.require.json"
export CLAUDE_CONFIG_DIR="$rec_home"
echo '{"env": {"JARVIS_REQUIRE_AGENT_IDENTITY": "1"}}' >"$rec_home/agent-identity.require.json"
# the refusal names the record, not the variable, as the cause when the record alone turned the switch on
jq -n --arg d "$feat" '{tool_name: "Bash", tool_input: {command: "gh pr create --title t"}, cwd: $d}' >"$root/in.json"
reason=$("$py" -I "$hook" <"$root/in.json" | jq -r '.hookSpecificOutput.permissionDecisionReason')
total=$((total + 1))
if printf '%s' "$reason" | grep -qF "switch ($rec_home/agent-identity.require.json records it as on) caused" && ! printf '%s' "$reason" | grep -qF '(JARVIS_REQUIRE_AGENT_IDENTITY=1)' \
   && printf '%s' "$reason" | grep -qF "$rec_home/agent-identity.require.json records it as on but JARVIS_AGENT_IDENTITY is empty"; then
  echo "ok   a record-only switch is named as the cause, with its path"
else
  echo "FAIL a record-only switch is named as the cause, with its path: $reason"; fails=$((fails + 1))
fi
reason=$(JARVIS_REQUIRE_AGENT_IDENTITY=1 "$py" -I "$hook" <"$root/in.json" | jq -r '.hookSpecificOutput.permissionDecisionReason')
total=$((total + 1))
if printf '%s' "$reason" | grep -qF 'switch (JARVIS_REQUIRE_AGENT_IDENTITY=1) caused'; then
  echo "ok   with the variable on, the variable is the cause"
else
  echo "FAIL with the variable on, the variable is the cause: $reason"; fails=$((fails + 1))
fi
# Codex mode does not read it
hook_args="--codex"
probe allow 'gh pr create --title t'
hook_args=""
export CLAUDE_CONFIG_DIR="$no_claude"
probe allow 'gh pr create --title t'

echo "== agent identity: the refusal under Codex names the switch, the fix and the way back"
jq -n --arg d "$feat" '{tool_name: "Bash", tool_input: {command: "gh pr create --title x"}, cwd: $d}' >"$root/in.json"
reason=$("$py" -I "$hook" --codex --require-identity <"$root/in.json" | jq -r '.hookSpecificOutput.permissionDecisionReason')
total=$((total + 1))
if printf '%s' "$reason" | grep -qF "agent-identity switch" && printf '%s' "$reason" | grep -qF 'bash ~/.Jarvis/scripts/apply-agent-identity.sh --check --codex' \
   && printf '%s' "$reason" | grep -qF 'apply-agent-identity.sh --setup --codex' && printf '%s' "$reason" | grep -qF 'bash ~/.Jarvis/scripts/apply-agent-identity.sh --unrequire' \
   && printf '%s' "$reason" | grep -qF 'gh pr create'; then
  echo "ok   the Codex reason names the switch, --check --codex, --setup --codex and --unrequire"
else
  echo "FAIL the Codex reason names the switch, --check --codex, --setup --codex and --unrequire: $reason"; fails=$((fails + 1))
fi
reason=$(CODEX_HOME="$root/cx-gitconfig-gone" "$py" -I "$hook" --codex --require-identity <"$root/in.json" | jq -r '.hookSpecificOutput.permissionDecisionReason')
total=$((total + 1))
if printf '%s' "$reason" | grep -qF 'no longer' || printf '%s' "$reason" | grep -qF 'is missing'; then
  if printf '%s' "$reason" | grep -qF "agent-identity switch" && printf '%s' "$reason" | grep -qF 'apply-agent-identity.sh --unrequire'; then
    echo "ok   a failing Codex record with the switch on also names the switch and --unrequire"
  else
    echo "FAIL a failing Codex record with the switch on also names the switch and --unrequire: $reason"; fails=$((fails + 1))
  fi
else
  echo "FAIL the failing-record case did not fail on the record: $reason"; fails=$((fails + 1))
fi
reason=$(CODEX_HOME="$root/cx-gitconfig-gone" "$py" -I "$hook" --codex <"$root/in.json" | jq -r '.hookSpecificOutput.permissionDecisionReason')
total=$((total + 1))
if printf '%s' "$reason" | grep -qF "agent-identity switch"; then
  echo "FAIL with the switch off the record problem does not blame the switch: $reason"; fails=$((fails + 1))
else
  echo "ok   with the switch off a record problem does not blame the switch"
fi

echo "== agent identity not applied and switch off: an override changes nothing"
probe allow 'GH_TOKEN=x gh pr create --title t'
probe allow 'env -u GH_CONFIG_DIR gh pr create --title t'
probe allow 'git -c credential.helper=store push origin feat/y'

echo "== agent identity: the refusal says what to run"
export JARVIS_REQUIRE_AGENT_IDENTITY=1
jq -n --arg d "$feat" '{tool_name: "Bash", tool_input: {command: "gh pr create --title x"}, cwd: $d}' >"$root/in.json"
reason=$("$py" -I "$hook" <"$root/in.json" | jq -r '.hookSpecificOutput.permissionDecisionReason')
unset JARVIS_REQUIRE_AGENT_IDENTITY
total=$((total + 1))
if printf '%s' "$reason" | grep -qF 'bash ~/.Jarvis/scripts/apply-agent-identity.sh --check' && printf '%s' "$reason" | grep -qF '~/.Jarvis/config-local/agent-identity' && printf '%s' "$reason" | grep -qF 'gh pr create'; then
  echo "ok   the reason names the --check command, the config path and the command"
else
  echo "FAIL the reason names the --check command, the config path and the command: $reason"; fails=$((fails + 1))
fi
total=$((total + 1))
if printf '%s' "$reason" | grep -qF "agent-identity switch" && printf '%s' "$reason" | grep -qF 'apply-agent-identity.sh --setup' \
   && printf '%s' "$reason" | grep -qF 'bash ~/.Jarvis/scripts/apply-agent-identity.sh --unrequire' && ! printf '%s' "$reason" | grep -qF -- '--codex'; then
  echo "ok   the Claude reason names the switch, --setup and --unrequire, and no Codex flag"
else
  echo "FAIL the Claude reason names the switch, --setup and --unrequire, and no Codex flag: $reason"; fails=$((fails + 1))
fi

apply_identity
jq -n --arg d "$feat" '{tool_name: "Bash", tool_input: {command: "GH_TOKEN=x gh pr create --title t"}, cwd: $d}' >"$root/in.json"
reason=$("$py" -I "$hook" <"$root/in.json" | jq -r '.hookSpecificOutput.permissionDecisionReason')
drop_identity
total=$((total + 1))
if printf '%s' "$reason" | grep -qF "overrides the agent's identity (sets GH_TOKEN)" && printf '%s' "$reason" | grep -qF 'gh pr create'; then
  echo "ok   the override reason names what is overridden"
else
  echo "FAIL the override reason names what is overridden: $reason"; fails=$((fails + 1))
fi

echo "== gh pr merge --auto: allowed only where GitHub requires the owner's approval, verified at hook time"
# A stub gh on PATH answers the endpoints the check reads from fixture files, logs what it was asked
# and with which login, and can fail or hang. Nothing here reaches GitHub.
hook_args=""; drop_identity
unset JARVIS_REQUIRE_AGENT_IDENTITY GH_REPO GH_HOST
export CODEX_HOME="$no_codex" CLAUDE_CONFIG_DIR="$no_claude"
stub="$root/ghstub"; mkdir -p "$stub/bin" "$stub/contents"
cat >"$stub/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\tGH_CONFIG_DIR=%s\tGH_TOKEN=%s\tGITHUB_TOKEN=%s\tGH_HOST=%s\n' "$*" "${GH_CONFIG_DIR-unset}" \
  "${GH_TOKEN-unset}" "${GITHUB_TOKEN-unset}" "${GH_HOST-unset}" >>"$STUB_DIR/log"
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
[ -n "${STUB_FAIL:-}" ] && exit 1
[ "$1" = api ] || exit 1
case "$2" in
  repos/*/pulls/*) f=pull.json ;;
  repos/*/rules/branches/*) f=rules.json ;;
  repos/*/rulesets/*) f=ruleset-${2##*/}.json ;;
  repos/*/contents/*) k=${2#*/contents/}; k=${k%%\?*}; k=${k//\//_}; f=contents/${k#.}.json ;;
  repos/*/codeowners/errors*) f=errors.json ;;
  user) f=user.json ;;
  *) exit 1 ;;
esac
[ -f "$STUB_DIR/$f" ] || exit 1
cat "$STUB_DIR/$f"
EOF
chmod +x "$stub/bin/gh"
# The shape GitHub answers rules/branches/{branch} with (read from the real API), the pull_request
# rule's parameters passed through a jq filter, and the ruleset id it came from.
rules_json() { # jq filter, [ruleset id]
  jq -n --argjson id "${2:-1}" "[{type:\"deletion\",ruleset_source_type:\"Repository\",ruleset_source:\"example/shared\",ruleset_id:\$id},
    {type:\"pull_request\",parameters:({required_approving_review_count:1,dismiss_stale_reviews_on_push:true,required_reviewers:[],
      require_code_owner_review:true,require_last_push_approval:true,required_review_thread_resolution:true,
      require_extra_approval_for_unattributed_changes:true,allowed_merge_methods:[\"merge\",\"squash\",\"rebase\"]} | $1),
      ruleset_source_type:\"Repository\",ruleset_source:\"example/shared\",ruleset_id:\$id},
    {type:\"required_status_checks\",parameters:{strict_required_status_checks_policy:false,
      required_status_checks:[{context:\"tests\",integration_id:15368}]},ruleset_source_type:\"Repository\",ruleset_source:\"example/shared\",ruleset_id:\$id}]"
}
set_rules() { rules_json "$1" "${2:-1}" >"$stub/rules.json"; }
set_pull() { printf '{"number":12,"state":"open","base":{"ref":"%s"}}' "$1" >"$stub/pull.json"; }
set_bypass() { printf '{"id":%s,"name":"main","enforcement":"%s","current_user_can_bypass":"%s"}' "$1" "${3:-active}" "$2" >"$stub/ruleset-$1.json"; }
# a CODEOWNERS file the way the contents API answers: base64 in "content", with the line breaks it adds
codeowners_body() { jq -n --arg c "$(printf '%s\n' "$1" | base64 | fold -w 60)" '{type: "file", name: "CODEOWNERS", encoding: "base64", content: $c}'; }
set_codeowners() { rm -f "$stub"/contents/*; for p in "$@"; do p=${p//\//_}; codeowners_body '* @ShenYo' >"$stub/contents/${p#.}.json"; done; }
set_codeowners_text() { rm -f "$stub"/contents/*; codeowners_body "$1" >"$stub/contents/github_CODEOWNERS.json"; }
reset_stub() {
  : >"$stub/log"; set_pull main; set_rules .; set_bypass 1 never; set_codeowners .github/CODEOWNERS
  echo '{"errors":[]}' >"$stub/errors.json"; echo '{"login":"agent-claude-code"}' >"$stub/user.json"; rm -f "$stub/ruleset-2.json"
}
gh_stub() { STUB_DIR="$stub" PATH="$stub/bin:$PATH" "$@"; }
assert() { local name=$1; shift; total=$((total + 1)); if "$@"; then echo "ok   $name"; else echo "FAIL $name"; fails=$((fails + 1)); fi; }
asked() { grep -qF -- "$1" "$stub/log"; }
none_asked() { [ ! -s "$stub/log" ]; }
reason_of() { # command, [cwd]: the reason the hook gives
  jq -n --arg c "$1" --arg d "${2:-$feat}" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' >"$root/in.json"
  STUB_DIR="$stub" PATH="$stub/bin:$PATH" "$py" -I "$hook" $hook_args <"$root/in.json" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'
}
reason_is() { # name, glob, command
  local r; r=$(reason_of "$3" "${4:-}"); total=$((total + 1))
  if [[ "$r" == $2 ]]; then echo "ok   $1"; else echo "FAIL $1: $r"; fails=$((fails + 1)); fi
}
R=example/shared

reset_stub
echo "-- allowed: a single command naming its repository, where the rules bind the agent to the owner's approval"
gh_stub probe allow "gh pr merge 12 --auto --squash -R $R"
assert "it read the pull request, the rules, the ruleset, CODEOWNERS and its errors, for the base branch" bash -c "
  grep -qF 'api repos/$R/pulls/12' '$stub/log' && grep -qF 'api repos/$R/rules/branches/main' '$stub/log' &&
  grep -qF 'api repos/$R/rulesets/1' '$stub/log' && grep -qF 'api repos/$R/contents/.github/CODEOWNERS?ref=main' '$stub/log' &&
  grep -qF 'api repos/$R/codeowners/errors?ref=main' '$stub/log'"
gh_stub probe allow "gh pr merge 12 --auto -R $R"
gh_stub probe allow "gh pr merge 12 --auto --merge -R $R"
gh_stub probe allow "gh pr merge -R $R --rebase --auto 12"
gh_stub probe allow "gh pr merge 12 --auto --repo $R"
gh_stub probe allow "gh pr merge 12 --auto --repo=$R"
gh_stub probe allow "gh pr merge 12 --auto -R$R"
: >"$stub/log"
gh_stub probe allow "gh pr merge https://github.com/url/repo/pull/12 --auto --squash"
assert "a pull request URL names the repository" asked 'api repos/url/repo/pulls/12'
gh_stub probe allow "gh pr merge https://github.com/$R/pull/12 --auto -R $R"
: >"$stub/log"; set_pull release/v2
gh_stub probe allow "gh pr merge 12 --auto -R $R"
assert "a base branch with a slash is URL-encoded in the rules and the CODEOWNERS ref" bash -c "grep -qF 'rules/branches/release%2Fv2' '$stub/log' && grep -qF 'codeowners/errors?ref=release%2Fv2' '$stub/log'"
reset_stub
# several pull_request rules apply: one satisfying all four is enough, in either order
jq -s '.[0] + .[1]' <(rules_json .) <(rules_json 'del(.require_code_owner_review)' 2) >"$stub/rules.json"
gh_stub probe allow "gh pr merge 12 --auto -R $R"
jq -s '.[0] + .[1]' <(rules_json 'del(.require_code_owner_review)' 2) <(rules_json .) >"$stub/rules.json"
gh_stub probe allow "gh pr merge 12 --auto -R $R"
jq -s '.[0] + .[1]' <(rules_json 'del(.require_code_owner_review)') <(rules_json 'del(.require_last_push_approval)' 2) >"$stub/rules.json"
gh_stub probe ask "gh pr merge 12 --auto -R $R"
reset_stub
# the satisfying ruleset binds the agent, even if another ruleset does not
jq -s '.[0] + .[1]' <(rules_json . 2) <(rules_json . 1) >"$stub/rules.json"; set_bypass 2 exempt
gh_stub probe allow "gh pr merge 12 --auto -R $R"
set_bypass 1 exempt
gh_stub probe ask "gh pr merge 12 --auto -R $R"
reset_stub
for where in CODEOWNERS docs/CODEOWNERS; do
  set_codeowners "$where"
  gh_stub probe allow "gh pr merge 12 --auto -R $R"
done
reset_stub
echo "-- allowed: --disable-auto reduces what merges, so it needs no check"
: >"$stub/log"
STUB_FAIL=1 gh_stub probe allow 'gh pr merge 12 --disable-auto'
STUB_FAIL=1 gh_stub probe allow "gh pr merge 12 --disable-auto -R other/repo"
STUB_FAIL=1 gh_stub probe allow 'gh pr merge https://github.com/url/repo/pull/12 --disable-auto'
assert "--disable-auto asks GitHub nothing" none_asked

echo "-- refused: a rule field is missing or not enough, one at a time"
for f in "required_approving_review_count = 0|required_approving_review_count" "require_code_owner_review = false|require_code_owner_review" \
         "dismiss_stale_reviews_on_push = false|dismiss_stale_reviews_on_push" "require_last_push_approval = false|require_last_push_approval"; do
  name=${f#*|}
  set_rules ".${f%|*}"
  gh_stub probe ask "gh pr merge 12 --auto -R $R"
  reason_is "$name false: the reason names it and docs/git.md" "*$name*docs/git.md*" "gh pr merge 12 --auto -R $R"
  set_rules "del(.$name)"
  gh_stub probe ask "gh pr merge 12 --auto -R $R"
  reason_is "$name missing: the reason names it and docs/git.md" "*$name*docs/git.md*" "gh pr merge 12 --auto -R $R"
done
reset_stub; set_rules '.required_approving_review_count = "1"'; gh_stub probe ask "gh pr merge 12 --auto -R $R"
set_rules '.required_approving_review_count = true'; gh_stub probe ask "gh pr merge 12 --auto -R $R"
set_rules '.require_code_owner_review = "true"'; gh_stub probe ask "gh pr merge 12 --auto -R $R"
echo "-- refused: rules that are missing or cannot be read"
reset_stub; echo '[]' >"$stub/rules.json"; gh_stub probe ask "gh pr merge 12 --auto -R $R"
reason_is "no rules: the reason says nothing requires an approval" '*no pull_request rule*' "gh pr merge 12 --auto -R $R"
echo '[{"type":"deletion"},{"type":"non_fast_forward"}]' >"$stub/rules.json"; gh_stub probe ask "gh pr merge 12 --auto -R $R"
echo '{"message":"Not Found"}' >"$stub/rules.json"; gh_stub probe ask "gh pr merge 12 --auto -R $R"
echo 'not json' >"$stub/rules.json"; gh_stub probe ask "gh pr merge 12 --auto -R $R"
rm -f "$stub/rules.json"; gh_stub probe ask "gh pr merge 12 --auto -R $R"
reset_stub; echo '{"base":{}}' >"$stub/pull.json"; gh_stub probe ask "gh pr merge 12 --auto -R $R"
echo '{"number":12}' >"$stub/pull.json"; gh_stub probe ask "gh pr merge 12 --auto -R $R"
rm -f "$stub/pull.json"; gh_stub probe ask "gh pr merge 12 --auto -R $R"
echo "-- refused: the agent's login can bypass the rule, or it is not known not to"
reset_stub
for v in exempt always pull_requests_only bogus; do
  set_bypass 1 "$v"; gh_stub probe ask "gh pr merge 12 --auto -R $R"
done
set_bypass 1 exempt
reason_is "a bypassable ruleset: the reason names current_user_can_bypass and docs/git.md" "*current_user_can_bypass*exempt*docs/git.md*" "gh pr merge 12 --auto -R $R"
echo '{"id":1,"name":"main"}' >"$stub/ruleset-1.json"; gh_stub probe ask "gh pr merge 12 --auto -R $R"
echo '{"id":1,"current_user_can_bypass":null}' >"$stub/ruleset-1.json"; gh_stub probe ask "gh pr merge 12 --auto -R $R"
echo '[]' >"$stub/ruleset-1.json"; gh_stub probe ask "gh pr merge 12 --auto -R $R"
rm -f "$stub/ruleset-1.json"; gh_stub probe ask "gh pr merge 12 --auto -R $R"
reset_stub; set_rules . '"x"'; gh_stub probe ask "gh pr merge 12 --auto -R $R"
reset_stub; jq '[.[] | del(.ruleset_id)]' "$stub/rules.json" >"$stub/r.json"; mv "$stub/r.json" "$stub/rules.json"; gh_stub probe ask "gh pr merge 12 --auto -R $R"
reset_stub; jq '[.[] | .ruleset_source_type = "Organization"]' "$stub/rules.json" >"$stub/r.json"; mv "$stub/r.json" "$stub/rules.json"; gh_stub probe ask "gh pr merge 12 --auto -R $R"
echo "-- refused: no CODEOWNERS file on the base branch, or one with errors"
reset_stub; set_codeowners; gh_stub probe ask "gh pr merge 12 --auto -R $R"
reason_is "no CODEOWNERS: the reason names it and docs/git.md" "*no CODEOWNERS file*docs/git.md*" "gh pr merge 12 --auto -R $R"
echo '[{"type":"dir"}]' >"$stub/contents/CODEOWNERS.json"; gh_stub probe ask "gh pr merge 12 --auto -R $R"
# only a file counts, whatever else the entry says: a symlink or a directory is not a CODEOWNERS file
reset_stub
for t in symlink dir submodule; do
  codeowners_body '* @ShenYo' | jq --arg t "$t" '.type = $t' >"$stub/contents/github_CODEOWNERS.json"
  gh_stub probe ask "gh pr merge 12 --auto -R $R"
done
reason_is "a symlink is not a CODEOWNERS file" "*no CODEOWNERS file*docs/git.md*" "gh pr merge 12 --auto -R $R"
reset_stub; echo '{"errors":[{"line":1,"kind":"Invalid owner"}]}' >"$stub/errors.json"; gh_stub probe ask "gh pr merge 12 --auto -R $R"
reason_is "CODEOWNERS errors: the reason names them" "*CODEOWNERS*errors*docs/git.md*" "gh pr merge 12 --auto -R $R"
echo '{"message":"Not Found"}' >"$stub/errors.json"; gh_stub probe ask "gh pr merge 12 --auto -R $R"
echo 'not json' >"$stub/errors.json"; gh_stub probe ask "gh pr merge 12 --auto -R $R"
rm -f "$stub/errors.json"; gh_stub probe ask "gh pr merge 12 --auto -R $R"
reset_stub
echo "-- the CODEOWNERS file itself: one rule, * and the owner, never the agent"
for t in '* @ShenYo' $'# the owner\n\n* @ShenYo   # approves everything\n' '* @ShenYo @other-user' '*   @ShenYo' '* @Shen-Yo2'; do
  set_codeowners_text "$t"; gh_stub probe allow "gh pr merge 12 --auto -R $R"
done
set_codeowners_text $'# nothing\n# at all'
gh_stub probe ask "gh pr merge 12 --auto -R $R"
reason_is "no rule: the reason says so" "*CODEOWNERS*it has no rule*docs/git.md*" "gh pr merge 12 --auto -R $R"
set_codeowners_text '/docs/ @ShenYo'
gh_stub probe ask "gh pr merge 12 --auto -R $R"
reason_is "a path rule: the reason names the line" "*line 1 (/docs/ @ShenYo) is not the \`*\` rule*" "gh pr merge 12 --auto -R $R"
set_codeowners_text $'* @ShenYo\n*.md @someone-else'
gh_stub probe ask "gh pr merge 12 --auto -R $R"
reason_is "a second rule: the reason names the line" "*line 2 (*.md @someone-else) is a second rule*" "gh pr merge 12 --auto -R $R"
set_codeowners_text $'# header\n* @ShenYo\n/docs/ @ShenYo'
gh_stub probe ask "gh pr merge 12 --auto -R $R"
set_codeowners_text $'[Section]\n* @ShenYo'
gh_stub probe ask "gh pr merge 12 --auto -R $R"
set_codeowners_text '*'
gh_stub probe ask "gh pr merge 12 --auto -R $R"
reason_is "no owner: the reason names the line" "*line 1 (*) names no owner*" "gh pr merge 12 --auto -R $R"
set_codeowners_text '* @some-org/some-team'
gh_stub probe ask "gh pr merge 12 --auto -R $R"
reason_is "a team: the reason names it" "*@some-org/some-team is not a GitHub user*" "gh pr merge 12 --auto -R $R"
set_codeowners_text '* owner@example.com'
gh_stub probe ask "gh pr merge 12 --auto -R $R"
set_codeowners_text '* ShenYo'
gh_stub probe ask "gh pr merge 12 --auto -R $R"
set_codeowners_text '* @ShenYo @agent-claude-code'
gh_stub probe ask "gh pr merge 12 --auto -R $R"
reason_is "the agent among the owners: the reason says so" "*@agent-claude-code is the agent's own login*" "gh pr merge 12 --auto -R $R"
set_codeowners_text '* @Agent-Claude-Code'
gh_stub probe ask "gh pr merge 12 --auto -R $R"
reset_stub; echo '{"type":"file","encoding":"base64","content":"!!!"}' >"$stub/contents/github_CODEOWNERS.json"
gh_stub probe ask "gh pr merge 12 --auto -R $R"
echo '{"type":"file","encoding":"none","content":""}' >"$stub/contents/github_CODEOWNERS.json"
gh_stub probe ask "gh pr merge 12 --auto -R $R"
echo '{"type":"file"}' >"$stub/contents/github_CODEOWNERS.json"
gh_stub probe ask "gh pr merge 12 --auto -R $R"
reset_stub; echo '{"message":"Not Found"}' >"$stub/user.json"; gh_stub probe ask "gh pr merge 12 --auto -R $R"
reason_is "no login: the reason says the owners cannot be checked" "*login could not be read*" "gh pr merge 12 --auto -R $R"
rm -f "$stub/user.json"; gh_stub probe ask "gh pr merge 12 --auto -R $R"
reset_stub
echo "-- the ruleset must be active"
for e in evaluate disabled bogus; do set_bypass 1 never "$e"; gh_stub probe ask "gh pr merge 12 --auto -R $R"; done
reason_is "a ruleset not active: the reason names enforcement" "*enforcement = 'bogus'*docs/git.md*" "gh pr merge 12 --auto -R $R"
printf '{"id":1,"current_user_can_bypass":"never"}' >"$stub/ruleset-1.json"; gh_stub probe ask "gh pr merge 12 --auto -R $R"
reset_stub
echo "-- refused: gh fails, hangs or is not there"
STUB_FAIL=1 gh_stub probe ask "gh pr merge 12 --auto -R $R"
STUB_SLEEP=31 gh_stub probe ask "gh pr merge 12 --auto -R $R"
# the pattern's bracket keeps this checker's own command line from matching it
assert "a hung gh is killed and leaves no process behind" bash -c '! pgrep -f "sleep 3[1]" >/dev/null'
empty_path="$root/no-gh-bin"; mkdir -p "$empty_path"
total=$((total + 1))
if [ "$(jq -n --arg d "$feat" --arg c "gh pr merge 12 --auto -R $R" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' | PATH="$empty_path" "$py" -I "$hook" | jq -r '.hookSpecificOutput.permissionDecision // empty')" = ask ]; then
  echo "ok   no gh on PATH: refused"
else
  echo "FAIL no gh on PATH: refused"; fails=$((fails + 1))
fi
echo "-- the deadline: no gh is started once the guard's budget is spent"
# Loaded as a module with Popen replaced by a counter: with the budget spent gh_answer must not reach Popen
# at all (a timeout of zero or less would only hide that it did); with the budget open it must.
deadline_probe() { # seconds from now the deadline falls: prints the answer and the number of Popen calls
  "$py" -I - "$hook" "$1" <<'PY'
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("guard", sys.argv[1])
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
calls = []
def fake(*args, **kwargs):
    calls.append(args)
    raise OSError("no gh in this test")
guard.subprocess.Popen = fake
guard.DEADLINE = time.monotonic() + float(sys.argv[2])
print(guard.gh_answer({}, "api", "repos/x/y/pulls/1"), len(calls))
PY
}
total=$((total + 1))
if [ "$(deadline_probe 5)" = "None 1" ]; then echo "ok   budget open: gh is started"; else echo "FAIL budget open: gh is started"; fails=$((fails + 1)); fi
total=$((total + 1))
if [ "$(deadline_probe -1)" = "None 0" ]; then echo "ok   budget spent: gh is not started"; else echo "FAIL budget spent: gh is not started"; fails=$((fails + 1)); fi
echo "-- refused: the repository is not named, or is named two ways, or the environment redirects gh"
gh_stub probe ask 'gh pr merge 12 --auto'
reason_is "no -R: the reason asks for an explicit repository" "*--auto needs an explicit -R owner/repo*docs/git.md*" 'gh pr merge 12 --auto'
gh_stub probe ask "gh pr merge 12 --auto --squash"
gh_stub probe ask "gh pr merge https://github.com/url/repo/pull/12 --auto -R other/repo"
GH_REPO=other/repo gh_stub probe ask "gh pr merge 12 --auto -R $R"
GH_HOST=ghe.example gh_stub probe ask "gh pr merge 12 --auto -R $R"
echo "-- refused: anything around the command, or any other form, without asking GitHub"
: >"$stub/log"
more() { # the command, and the glob its reason must match
  gh_stub probe ask "$1"
  reason_is "the reason names what disqualified: $1" "$2" "$1"
}
more "GIT_DIR=/other/.git gh pr merge 12 --auto -R $R" '*starts with an assignment (GIT_DIR=*docs/git.md*'
more "export GIT_DIR=/other/.git; gh pr merge 12 --auto -R $R" '*not the only command*`;`*docs/git.md*'
more ". ./env.sh; gh pr merge 12 --auto -R $R" '*not the only command*`;`*'
more "gh repo set-default other/x && gh pr merge 12 --auto -R $R" '*not the only command*`&`*'
more "gh pr merge 12 --auto -R $R || true" '*not the only command*'
more "gh pr merge 12 --auto -R $R;true" '*not the only command*`;`*'
more "gh pr merge 12 --auto -R $R&&true" '*not the only command*`&`*'
more "gh pr merge 12 --auto -R $R|cat" '*not the only command*`|`*'
gh_stub probe ask 'gh pr merge 12 --auto -R example/sh$x'
gh_stub probe ask 'gh pr merge 12 --auto -R example/shared$HOME'
gh_stub probe ask "gh pr merge 12 --auto -R example/*"
gh_stub probe ask "gh pr merge 12 --auto -R ~/x"
gh_stub probe ask "gh pr merge 12 --auto -R example/sh{a,b}red"
more "gh pr merge 12 --auto -R $R | cat" '*not the only command*`|`*'
more "echo -R other/x | xargs gh pr merge 12 --auto" '*needs an explicit -R*'
more "echo --delete-branch | xargs gh pr merge 12 --auto -R $R" '*not the only command*'
more "gh() { :; }; gh pr merge 12 --auto -R $R" '*not the only command*'
more "alias gh=true; gh pr merge 12 --auto -R $R" '*not the only command*'
more "cd /tmp && gh pr merge 12 --auto -R $R" '*not the only command*'
more "gh pr merge 12 --auto -R $R &" '*not the only command*'
more "$(printf 'echo x\ngh pr merge 12 --auto -R %s' $R)" '*not the only command*newline*'
more "(gh pr merge 12 --auto -R $R)" '*substitution, subshell*'
more 'echo $(gh pr merge 12 --auto -R example/shared)' '*substitution, subshell*'
more "echo \`gh pr merge 12 --auto -R $R\`" '*substitution, subshell*'
more "gh pr merge 12 --auto -R $R >/dev/null" '*redirection*'
more "gh pr merge 12 --auto -R \"$R\"" '*quoting*'
more "gh pr merge 12 --auto -R $R #" '*quoting or a character the shell expands*'
more "env GH_REPO=other/x gh pr merge 12 --auto -R $R" '*run through `env`*'
more "command gh pr merge 12 --auto -R $R" '*run through `command`*'
more "builtin gh pr merge 12 --auto -R $R" '*run through `builtin`*'
more "xargs gh pr merge 12 --auto -R $R" '*run through `xargs`*'
more "timeout 5 gh pr merge 12 --auto -R $R" '*run through `timeout`*'
more "/opt/homebrew/bin/gh pr merge 12 --auto -R $R" '*run through `/opt/homebrew/bin/gh`*'
more "find . -exec gh pr merge 12 --auto -R $R \\;" '*not the only command*'
more "bash -c 'gh pr merge 12 --auto -R $R'" '*quoting*'
more "GIT_DIR=/other/.git gh pr merge 12 --disable-auto" '*starts with an assignment*'
more "cd /tmp && gh pr merge 12 --disable-auto" '*not the only command*'
more "gh pr merge 12 --auto --admin -R $R" '*the flag --admin*'
more "gh pr merge 12 --auto --match-head-commit abc -R $R" '*the flag --match-head-commit*'
more "gh pr merge 12 --auto --body x -R $R" '*the flag --body*'
more "gh pr merge 12 --auto --some-new-flag -R $R" '*the flag --some-new-flag*'
more "gh pr merge 12 --auto -s -R $R" '*the flag -s*'
more "gh pr merge --auto -R $R" '*no pull request number or URL*'
more "gh pr merge 12 --auto --squash --rebase -R $R" '*--rebase is given with --squash*'
more "gh pr merge 12 --auto --disable-auto -R $R" '*both given*'
more "gh pr merge 12 --disable-auto --squash" '*--squash is given with --disable-auto*'
more "gh pr merge 12 13 --auto -R $R" '*a second argument (13)*'
more "gh pr merge 12 --auto -R a/b -R c/d" '*given twice*'
more "gh pr merge feat/x --auto -R $R" '*not a pull request number*'
more "gh pr merge 12 --auto -R github.com/o/r" '*not owner/repo*'
more "gh pr merge 12 --auto -R o/.." '*not owner/repo*'
more "gh pr merge http://github.com/o/r/pull/12 --auto" '*not a pull request number*'
more "gh pr merge https://github.com/o/r/issues/12 --auto" '*not a pull request number*'
more "gh pr merge -- 12 --auto -R $R" '*the flag --*'
gh_stub probe deny "gh pr merge 12 --auto --delete-branch -R $R"
gh_stub probe deny "gh pr merge 12 --auto --squash --delete-branch -R $R"
gh_stub probe deny "gh pr merge 12 --auto -d -R $R"
gh_stub probe deny "gh pr merge 12 --disable-auto --delete-branch"
gh_stub probe ask "gh pr merge 12 -R $R"
gh_stub probe ask "gh pr merge 12 --squash -R $R"
gh_stub probe ask "gh pr merge 12 --admin -R $R"
gh_stub probe ask 'gh pr merge 12'
gh_stub probe ask 'gh api -X PUT repos/example/shared/pulls/12/merge'
gh_stub probe ask 'gh api graphql -f query="mutation { enablePullRequestAutoMerge(input: {pullRequestId: \"x\"}) { clientMutationId } }"'
gh_stub probe ask 'gh api graphql -f query="mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }"'
assert "no refused form asked GitHub anything" none_asked

echo "-- retargeting a pull request is a merge checkpoint: an armed auto-merge would follow it to another base"
base_pat='*base branch*armed auto-merge*owner*approval*'
for c in 'gh pr edit 12 --base release' 'gh pr edit 12 -B release' 'gh pr edit 12 --base=release' 'gh pr edit 12 -Brelease' \
         'gh api -X PATCH repos/o/r/pulls/12 -f base=release' 'gh api repos/o/r/pulls/12 -f base=release' \
         'gh api repos/o/r/pulls/12 --method PATCH -F base=release' \
         'gh api graphql -f query="mutation { updatePullRequest(input: {pullRequestId: \"x\", baseRefName: \"release\"}) { clientMutationId } }"' \
         'gh api graphql -f query="mutation { updatePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }" -f baseRefName=release'; do
  gh_stub probe ask "$c"
  reason_is "the reason names the risk: $c" "$base_pat" "$c"
done
printf '{"base": "release"}' >"$root/sandbox/b.json"
gh_stub probe ask 'gh api -X PATCH repos/o/r/pulls/12 --input b.json' "$root/sandbox"
printf '{"b\\u0061se": "release"}' >"$root/sandbox/b-esc.json"
printf '{"title": "x", "\\u0062ase": "release"}' >"$root/sandbox/b-esc2.json"
printf '{"title": "x"}' >"$root/sandbox/b-title.json"
printf '{"title": "x" ' >"$root/sandbox/b-broken.json"
printf 'base=release' >"$root/sandbox/b-form.txt"
gh_stub probe ask 'gh api -X PATCH repos/o/r/pulls/12 --input b-esc.json' "$root/sandbox"
reason_is "an escaped base key is a retarget" "$base_pat" 'gh api -X PATCH repos/o/r/pulls/12 --input b-esc.json' "$root/sandbox"
gh_stub probe ask 'gh api -X PATCH repos/o/r/pulls/12 --input b-esc2.json' "$root/sandbox"
gh_stub probe ask 'gh api -X PATCH repos/o/r/pulls/12 --input b-broken.json' "$root/sandbox"
reason_is "a body that is not JSON is a retarget" "*not JSON*cannot be ruled out*" 'gh api -X PATCH repos/o/r/pulls/12 --input b-broken.json' "$root/sandbox"
gh_stub probe ask 'gh api -X PATCH repos/o/r/pulls/12 --input b-form.txt' "$root/sandbox"
gh_stub probe ask 'gh api -X PATCH repos/o/r/pulls/12 --input=b-esc.json' "$root/sandbox"
gh_stub probe allow 'gh api -X PATCH repos/o/r/pulls/12 --input b-title.json' "$root/sandbox"
gh_stub probe allow 'gh api -X GET repos/o/r/pulls/12 --input b-broken.json' "$root/sandbox"
gh_stub probe allow 'gh pr edit 12 --title x'
gh_stub probe allow 'gh pr edit 12 --body "the base is fine"'
gh_stub probe allow 'gh pr edit 12 --add-label bug'
gh_stub probe allow 'gh api -X PATCH repos/o/r/pulls/12 -f title=x'
gh_stub probe allow 'gh api repos/o/r/pulls/12'
gh_stub probe allow 'gh api graphql -f query="mutation { updatePullRequest(input: {pullRequestId: \"x\", title: \"t\"}) { clientMutationId } }"'
echo "-- the same checkpoints however gh is given the fields, the body or the path"
printf '{"b\\u0061se": "release"}' >"$root/sandbox/b-esc.json"
printf '{"query": "mutation { \\u006dergePullRequest(input: {pullRequestId: \\"x\\"}) { clientMutationId } }"}' >"$root/sandbox/q-merge-esc.json"
printf '{"query": "mutation { updatePullRequest(input: {pullRequestId: \\"x\\", \\u0062aseRefName: \\"release\\"}) { clientMutationId } }"}' >"$root/sandbox/q-base-esc.json"
printf '{"query": "query { viewer { login } }"}' >"$root/sandbox/q-read.json"
printf '{"state": "clos\\u0065d"}' >"$root/sandbox/st-esc.json"
printf '{"event": "\\u0041PPROVE"}' >"$root/sandbox/ev-esc.json"
printf 'not json' >"$root/sandbox/not.json"
printf '{"query": "mutation { delet\\u0065Ref(input: {refId: \\"x\\"}) { clientMutationId } }"}' >"$root/sandbox/q-delete-esc.json"
for c in 'gh api -X PATCH repos/o/r/pulls/12 -fbase=release' 'gh api -X PATCH repos/o/r/pulls/12 -Fbase=release' \
         'gh api -X PATCH repos/o/r/pulls/12 -f=base=release' 'gh api -X PATCH repos/o/r/pulls/12 -ifbase=release' \
         'gh api repos/o/r/pulls/12 -fbase=release' 'gh api -XPATCH repos/o/r/pulls/12 -fbase=release' \
         'gh api -X PATCH repos/o/r/pulls/12 --field=base=release' 'gh api -X PATCH repos/o/r/pulls/12 --raw-field base=release' \
         'gh api graphql -fquery="mutation { updatePullRequest(input: {pullRequestId: \"x\", baseRefName: \"release\"}) { clientMutationId } }"' \
         'gh api graphql -Fquery="mutation { updatePullRequest(input: {pullRequestId: \"x\", baseRefName: \"release\"}) { clientMutationId } }"' \
         'gh api graphql -fquery="mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }"' \
         'gh api graphql -fquery="mutation { enablePullRequestAutoMerge(input: {pullRequestId: \"x\"}) { clientMutationId } }"' \
         'gh api graphql -fquery="mutation { closePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }"' \
         'gh api -X PUT repos/o/r/pulls/12/merge -fmerge_method=squash' 'gh api -X PATCH repos/o/r/pulls/12 -fstate=closed' \
         'gh api repos/o/r/pulls/12/reviews -fevent=APPROVE' 'gh api repos/o/r/releases -ftag_name=v1.0.0'; do
  gh_stub probe ask "$c"
done
gh_stub probe deny 'gh api graphql -fquery="mutation { deleteRef(input: {refId: \"x\"}) { clientMutationId } }"'
for c in 'gh api -X PATCH repos/o/r/pulls/12 --input b-esc.json' 'gh api -X PATCH repos/o/r/pulls/12 --input=b-esc.json' \
         'gh api graphql --input q-merge-esc.json' 'gh api graphql --input=q-merge-esc.json' 'gh api graphql --input q-base-esc.json' \
         'gh api -X PATCH repos/o/r/pulls/12 --input st-esc.json' 'gh api repos/o/r/pulls/12/reviews --input ev-esc.json' \
         'gh api graphql --input not.json' 'gh api -X PATCH repos/o/r/pulls/12 --input not.json' 'gh api -X PUT repos/o/r/pulls/12/merge --input not.json' \
         'gh api -X PATCH repos/o/r/issues/12 --input not.json' \
         "echo '{\"b\\u0061se\": \"release\"}' | gh api -X PATCH repos/o/r/pulls/12 --input -" \
         "echo '{\"query\": \"mutation { \\u006dergePullRequest(input: {pullRequestId: 1}) { clientMutationId } }\"}' | gh api graphql --input -" \
         'cat q.json | gh api graphql --input -' 'curl -s https://example.invalid/b | gh api -X PATCH repos/o/r/pulls/12 --input -'; do
  gh_stub probe ask "$c" "$root/sandbox"
done
reason_is "an escaped base key in a body: the reason names the risk" "$base_pat" 'gh api -X PATCH repos/o/r/pulls/12 --input b-esc.json' "$root/sandbox"
reason_is "a body that is not JSON: the reason says it cannot be read" "*not JSON*cannot be ruled out*" 'gh api graphql --input not.json' "$root/sandbox"
for c in 'gh api -X PUT repos/o/r/pulls/%31%32/merge' 'gh api -X PATCH repos/o/r/pulls/%31%32 -fbase=release' 'gh api -X PATCH repos/o/r/pulls/%31%32 -fstate=closed' \
         'gh api -X PATCH repos/o/r/issues/%31%32 -fstate=closed' 'gh api repos/o/r/pulls/%31%32/reviews -fevent=APPROVE' \
         'gh api -X PUT repos/o/r/pulls/12%2Fmerge' 'gh api repos/o/r/%72eleases -ftag_name=v1.0.0' 'gh api -X PATCH repos/%6f/r/branches/main/%70rotection -fenforce_admins=true'; do
  gh_stub probe ask "$c" "$root/sandbox"
done
gh_stub probe deny 'gh api -X DELETE repos/o/r/git/refs/heads/%78'
gh_stub probe deny 'gh api graphql --input q-delete-esc.json' "$root/sandbox"
gh_stub probe allow 'gh api -X PATCH repos/o/r/pulls/12 -ftitle=x'
gh_stub probe allow 'gh api -X PATCH repos/o/r/pulls/%31%32 -ftitle=x'
gh_stub probe allow 'gh api repos/o/r/pulls/%31%32'
gh_stub probe allow 'gh api graphql -fquery="query { viewer { login } }"'
gh_stub probe allow 'gh api graphql --input q-read.json' "$root/sandbox"
gh_stub probe allow 'gh api -H "Accept: application/vnd.github+json" repos/o/r/pulls/12'
gh_stub probe allow 'gh api -X POST repos/o/r/issues/12/comments -fbody=thanks'
echo "-- every armed pull request in a compound is refused with it"
reset_stub
gh_stub probe ask "gh pr merge 12 --auto -R $R && gh pr merge 13 --auto -R $R"
reset_stub

echo "-- the login gh runs with: the agent's own, and nobody's token"
export GH_CONFIG_DIR=/proc/gh
: >"$stub/log"
gh_stub probe allow "gh pr merge 12 --auto -R $R"
assert "no identity: gh runs with the process's own GH_CONFIG_DIR" asked "GH_CONFIG_DIR=/proc/gh"$'\t'
# a token the merge would inherit is one the checks must not hide
: >"$stub/log"
for v in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; do
  env "$v=secret" STUB_DIR="$stub" PATH="$stub/bin:$PATH" "$py" -I "$hook" <<<"$(jq -n --arg d "$feat" --arg c "gh pr merge 12 --auto -R $R" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}')" >"$root/out.json"
  total=$((total + 1))
  if [ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$root/out.json")" = ask ] && jq -r .hookSpecificOutput.permissionDecisionReason "$root/out.json" | grep -qF "$v is set"; then
    echo "ok   $v set: refused, and the reason names it"
  else
    echo "FAIL $v set: refused, and the reason names it"; fails=$((fails + 1))
  fi
done
GH_TOKEN=secret gh_stub probe ask "gh pr merge 12 --auto -R $R"
GITHUB_TOKEN=secret gh_stub probe allow 'gh pr merge 12 --disable-auto'
assert "a token in the environment: GitHub is not asked" none_asked
# what gh is asked with has no token or host, whatever the environment holds
total=$((total + 1))
if [ "$(GH_TOKEN=a GITHUB_TOKEN=b GH_HOST=h GH_ENTERPRISE_TOKEN=c GH_CONFIG_DIR=/proc/gh "$py" -I -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("guard", sys.argv[1]); g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
env = g.gh_env(); print(sorted(k for k in ("GH_TOKEN", "GITHUB_TOKEN", "GH_HOST", "GH_ENTERPRISE_TOKEN") if k in env), env["GH_CONFIG_DIR"])' "$hook")" = "[] /proc/gh" ]; then
  echo "ok   gh_env strips the token and host variables"
else
  echo "FAIL gh_env strips the token and host variables"; fails=$((fails + 1))
fi
# the identity record is used only when the identity is applied
export CLAUDE_CONFIG_DIR="$applied_home"
: >"$stub/log"
gh_stub probe allow "gh pr merge 12 --auto -R $R"
assert "a record but no marker: the process's GH_CONFIG_DIR, which is what the merge will use" asked "GH_CONFIG_DIR=/proc/gh"$'\t'
assert "...for every call" bash -c "[ \"\$(grep -c 'GH_CONFIG_DIR=/proc/gh' '$stub/log')\" = \"\$(wc -l <'$stub/log' | tr -d ' ')\" ]"
unset GH_CONFIG_DIR; export CLAUDE_CONFIG_DIR="$no_claude"
apply_identity
: >"$stub/log"
gh_stub probe allow "gh pr merge 12 --auto -R $R"
assert "identity applied: gh runs with the applied GH_CONFIG_DIR and no token or host" asked "GH_CONFIG_DIR=/agent/gh"$'\t'"GH_TOKEN=unset"$'\t'"GITHUB_TOKEN=unset"$'\t'"GH_HOST=unset"
assert "...for every call, the bypass and CODEOWNERS checks included" bash -c "[ \"\$(grep -c 'GH_CONFIG_DIR=/agent/gh' '$stub/log')\" = \"\$(wc -l <'$stub/log' | tr -d ' ')\" ]"
gh_stub probe allow 'gh pr merge 12 --disable-auto'
set_rules 'del(.require_last_push_approval)'
gh_stub probe ask "gh pr merge 12 --auto -R $R"
set_rules .
gh_stub probe ask 'gh pr edit 12 --base release'
: >"$stub/log"
GH_TOKEN=x gh_stub probe deny "gh pr merge 12 --auto -R $R"
GH_TOKEN=x gh_stub probe deny 'gh pr merge 12 --disable-auto'
gh_stub probe deny "GH_CONFIG_DIR=/x gh pr merge 12 --auto -R $R"
assert "an overridden identity is refused before GitHub is asked" none_asked
drop_identity
export JARVIS_REQUIRE_AGENT_IDENTITY=1
gh_stub probe deny "gh pr merge 12 --auto -R $R"
gh_stub probe deny 'gh pr merge 12 --disable-auto'
assert "switch on, no identity: refused before GitHub is asked" none_asked
unset JARVIS_REQUIRE_AGENT_IDENTITY

echo "-- Codex mode: the record's GH_CONFIG_DIR, and an ask is a deny"
hook_args="--codex"
codex_gh="$root/codex-gh"; codex_fixture "$codex_gh"
jq '.set.GH_CONFIG_DIR = "/codex/gh"' "$codex_gh/agent-identity.applied.json" >"$codex_gh/r.json" && mv "$codex_gh/r.json" "$codex_gh/agent-identity.applied.json"
export CODEX_HOME="$codex_gh" GH_CONFIG_DIR=/proc/gh
: >"$stub/log"
gh_stub probe allow "gh pr merge 12 --auto --squash -R $R"
assert "Codex: gh runs with the Codex record's GH_CONFIG_DIR, not the hook's" asked "GH_CONFIG_DIR=/codex/gh"$'\t'"GH_TOKEN=unset"
gh_stub probe allow 'gh pr merge https://github.com/url/repo/pull/12 --auto'
gh_stub probe allow 'gh pr merge 12 --disable-auto'
gh_stub probe deny 'gh pr merge 12'
gh_stub probe deny "gh pr merge 12 --auto --admin -R $R"
gh_stub probe deny "gh pr merge 12 --auto --delete-branch -R $R"
gh_stub probe deny 'gh pr merge 12 --auto'
gh_stub probe deny "GIT_DIR=/x gh pr merge 12 --auto -R $R"
gh_stub probe deny "cd /tmp && gh pr merge 12 --auto -R $R"
gh_stub probe deny "echo --delete-branch | xargs gh pr merge 12 --auto -R $R"
gh_stub probe deny 'gh pr edit 12 --base release'
gh_stub probe deny 'gh api -X PATCH repos/o/r/pulls/12 -f base=release'
gh_stub probe deny 'gh api graphql -f query="mutation { enablePullRequestAutoMerge(input: {pullRequestId: \"x\"}) { clientMutationId } }"'
set_bypass 1 exempt
gh_stub probe deny "gh pr merge 12 --auto -R $R"
set_bypass 1 never; set_codeowners
gh_stub probe deny "gh pr merge 12 --auto -R $R"
set_codeowners .github/CODEOWNERS
set_rules 'del(.require_code_owner_review)'
gh_stub probe deny "gh pr merge 12 --auto -R $R"
set_rules .
STUB_FAIL=1 gh_stub probe deny "gh pr merge 12 --auto -R $R"
STUB_SLEEP=31 gh_stub probe deny "gh pr merge 12 --auto -R $R"
hook_args="--codex --require-identity"
gh_stub probe allow "gh pr merge 12 --auto -R $R"
hook_args="--codex"
export CODEX_HOME="$no_codex" GH_CONFIG_DIR=/proc/gh
: >"$stub/log"
gh_stub probe allow "gh pr merge 12 --auto -R $R"
assert "Codex, no record: gh runs with the process's own GH_CONFIG_DIR" asked "GH_CONFIG_DIR=/proc/gh"$'\t'
export CODEX_HOME="$root/cx-gitconfig-gone"
: >"$stub/log"
gh_stub probe deny "gh pr merge 12 --auto -R $R"
assert "Codex, an unsound record: refused before GitHub is asked" none_asked
GH_TOKEN=secret gh_stub probe deny "gh pr merge 12 --auto -R $R"
export CODEX_HOME="$no_codex"
hook_args=""
unset GH_CONFIG_DIR
export CODEX_HOME="$no_codex"
reset_stub

echo
if [ "$fails" -gt 0 ]; then echo "$fails of $total failed (sandboxes: $root)"; exit 1; fi
echo "all $total passed"
