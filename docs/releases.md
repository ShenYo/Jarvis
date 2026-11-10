# Releases

> **中文摘要**：這份文件說明 Jarvis 的版本規則（PATCH／MINOR／MAJOR 各代表什麼）、release 的
> 說明如何隨 pull request 進入 `docs/changelog/` 的版本檔（`CHANGELOG.md` 連到各檔），以及打 tag 與發佈 GitHub Release 的步驟；推送 tag 與
> 發佈 release 都是關卡，要使用者點名 tag 與 commit。

Jarvis tags releases as `vMAJOR.MINOR.PATCH`, starting at v1.0.0:

- **PATCH** for a documentation-only change.
- **MINOR** for a change to what runs: the guard, the bridge script, the apply
  scripts, the Git hooks, or how the Skills are bridged.
- **MAJOR** for a large structural change.

Nothing consumes a release: no project depends on Jarvis, so a release is a
labelled point on this machine, not something to propagate. Every release
carries a note, found through [`CHANGELOG.md`](../CHANGELOG.md), above all a MINOR or MAJOR
one, which says what changed, why, and what to do on this machine afterwards.

To cut a release, the pull request that makes it adds the entry under
`## Unreleased`, at the top of the file for the newest major version in
[`docs/changelog/`](./changelog/) (which `CHANGELOG.md` links), and renames that
heading to `## vX.Y.Z (YYYY-MM-DD)`, the date being the tag's own date in Taipei
time (UTC+8), so the note is reviewed. Tag on the day the heading names, or
correct the heading in a follow-up pull request. A release that starts a new major version
moves `## Unreleased` into a new `docs/changelog/vN.md` and adds a row for it in
`CHANGELOG.md`. After the merge, the entry becomes the tag's message and
the GitHub Release's notes:

```sh
git tag -a vX.Y.Z <commit> -F <file holding the entry>
git push origin vX.Y.Z
gh release create vX.Y.Z --notes-from-tag
```

Pushing the tag and publishing the release are both checkpoints: the user
authorizes each by naming the tag and the commit. Deleting a tag or a release is
never the agent's ([`docs/git.md`](./git.md)).
