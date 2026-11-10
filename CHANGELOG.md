# Changelog

> **中文摘要**：這是 Jarvis 的 release note 導引。條目依大版號分檔，放在
> [`docs/changelog/`](./docs/changelog/)，最新的在每個檔案的最上面；這個檔案只留規則和各版本檔的連結。
> 每個 release 的 pull request 把 `## Unreleased` 下的條目改名為「版號 + 日期」，日期是 tag 當天的台北時間
> （UTC+8），所以條目會經過審查；它也是 annotated tag 的訊息，並由 tag 發佈成 GitHub Release。
> MINOR 與 MAJOR 要寫清楚改了什麼、為什麼，以及在這台機器上必須做什麼。v1.0.0 是第一個 release。

Jarvis tags releases as `vMAJOR.MINOR.PATCH`. How a version is chosen, and how a
release is cut, is in [Releases](./docs/releases.md). Release notes are kept one file
per major version, so no single file grows too long to read. This page holds the rules
and links to each file.

| Major | File | About |
| --- | --- | --- |
| v1 | [`docs/changelog/v1.md`](./docs/changelog/v1.md) | The first major version: the Skill catalog and its bridge, the Git hooks, the guard, agent identity, and session notes. |

How an entry is written:

- The pull request that makes a release adds its entry under `## Unreleased`, at the top
  of the file for the major it will be released in (the newest, unless it is a
  maintenance release of an older major), and renames that heading to `## vX.Y.Z (YYYY-MM-DD)`, so
  the entry is reviewed with the change. The date is the tag's own date in Taipei time
  (UTC+8). Tag on the Taipei day the heading names; if the tag lands on another day, correct the heading in a follow-up pull request. The same text is the annotated tag's message and the GitHub Release's notes.
- A PATCH entry (documentation only) may be one line.
- A MINOR or MAJOR entry says what changed, why, and what the owner must do on
  this machine afterwards: for example re-run an apply script, or trust the
  Codex hook again in `/hooks`. A release that needs nothing says so.
- Nothing here is a dependency of any project, so no entry has an upgrade path
  for a consumer.
- A release that starts a new major version moves `## Unreleased` out of the old file to the
  top of the new `docs/changelog/vN.md`, and adds a row for it to the table above, in the
  same pull request. Apart from a later maintenance release of that major, that is the last edit to the old file.
