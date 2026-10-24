#!/usr/bin/env bash
# Behaviour tests for Jarvis's own Git hooks in .githooks/.
#
# Each case runs in a scratch repository whose core.hooksPath points at this
# checkout's hooks, and asserts what the hook does: refuse or accept. These
# hooks are maintained here on their own, so nothing else compares them
# against anything; a hook that stopped refusing would otherwise go unseen.
#
# Sandboxes are left in place; see tests/claude-guard.sh for why.
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
hooks="${GITHOOKS_DIR:-$repo/.githooks}"
root=$(mktemp -d "${TMPDIR:-/tmp}/githooks-test.XXXXXX")
echo "sandboxes: $root"

fails=0
total=0
expect() { # want (refused|accepted), name, then the command
  local want=$1 name=$2 got; shift 2
  total=$((total + 1))
  if "$@" >"$root/last.log" 2>&1; then got=accepted; else got=refused; fi
  if [ "$got" = "$want" ]; then
    echo "ok   $want: $name"
  else
    echo "FAIL want $want, got $got: $name"; sed 's/^/     /' "$root/last.log" | head -5
    fails=$((fails + 1))
  fi
}

# A remote whose default branch is main, and a clone with the hooks wired.
# The seed commit is pushed before the hooks are wired, so no case below
# needs to step around them.
git init -q --bare -b main "$root/remote.git"
git init -q -b main "$root/work"
w="$root/work"
g() { git -C "$w" -c user.name=t -c user.email=t@example.invalid "$@"; }
g commit -q --allow-empty -m "chore: seed"
g remote add origin "$root/remote.git"
g push -q origin main
g remote set-head origin -a >/dev/null
g config core.hooksPath "$hooks"

msg() { printf '%s\n' "$1" >"$root/msg"; "$hooks/commit-msg" "$root/msg"; }

echo "== commit-msg"
expect accepted "a conventional subject" msg "docs: explain the hook path"
expect accepted "a scoped subject" msg "fix(guard): parse attached option values"
expect refused "not Conventional Commits" msg "updated some stuff"
expect refused "an unknown type" msg "feature: add a thing"
expect refused "a trailing period" msg "docs: explain the hook path."
expect refused "past tense" msg "docs: added the hook path"
expect refused "a vague summary" msg "chore: misc cleanup"
expect refused "a subject over 72 characters" msg "docs: $(printf 'x%.0s' $(seq 1 70))"
expect accepted "a 37-character Chinese subject" msg "docs: 說明為什麼 hook 會拒絕這種提交訊息與它的格式規則"

echo "== pre-commit"
printf 'plain text\n' >"$w/notes.txt"
g add notes.txt
expect accepted "a staged diff with no credential" g commit -q -m "docs: add notes"
# Built at run time, so this file never holds the literal the scanner refuses.
printf 'aws_key = %s%s\n' "AKIA" "ABCDEFGHIJKLMNOP" >"$w/config.txt"
g add config.txt
expect refused "a staged AWS access key" g commit -q -m "chore: add config"
g reset -q -- config.txt

echo "== pre-push"
expect refused "a push to the default branch" g push -q origin main
expect accepted "a push to a feature branch" g push -q origin HEAD:refs/heads/feat/a
expect refused "deleting a remote branch" g push -q origin --delete feat/a
g push -q origin HEAD:refs/heads/feat/c
expect refused "deleting through an empty source" g push -q origin :feat/c
g commit -q --allow-empty -m "docs: diverge from the pushed branch"
g push -q origin HEAD:refs/heads/feat/b
g checkout -q -b rewrite HEAD~1
g commit -q --allow-empty -m "docs: take another path"
expect refused "a force push that rewrites history" g push -q --force origin HEAD:refs/heads/feat/b

echo
if [ "$fails" -gt 0 ]; then echo "$fails of $total failed"; exit 1; fi
echo "all $total passed"
