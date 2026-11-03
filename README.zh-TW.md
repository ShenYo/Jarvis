# Jarvis

[English](./README.md) · **繁體中文**

> **繁中摘要**：Jarvis 是這台機器的個人 AI agent Skills 版本庫。它讓
> `~/.Jarvis/.agents` 成為唯一 canonical copy，透過 `~/.agents` 與 Claude
> Code／Codex 的 symlink 共用；它也保管個人指示與 Claude Code guard。專案
> 本身必須不依賴 Jarvis 仍可重現。歷史與觀察記錄在 `docs/history.md`。

Jarvis 是這台機器上、版本控制的 home，存放個人 AI-agent Skills 唯一的
canonical copy。

## 它解決的問題

Jarvis 處理四個相關情境：

- **個人 Skills 版本控制：** 機器層級的 Skills 擁有歷史紀錄、審查與復原能力，
  不再只活在未受追蹤的 home 目錄資料夾裡。
- **新機器 bootstrap：** 一次 clone 加一次 bridge 指令，就能為受支援的本機
  工具還原 canonical layout。
- **Claude/Codex bridge 檢查：** 這支腳本確保 Claude bridge 目錄存在，並建立
  或替換缺失或 dangling 的 canonical-name links；其他 dangling 的
  non-reserved bridge entries 會明顯失敗。
- **Claude Code guard：** 一份受版本控管的規則，複製進
  `~/.claude/settings.json`，在這台機器的每個專案裡拒絕破壞性的 Git 與檔案操作。

## 範圍與擁有權

| Layer | Owns | Does not own |
| --- | --- | --- |
| **Jarvis** | 這台機器的 canonical 個人 Skills、bridge script，以及個人 Skill 的 provenance；以 `~/.claude/CLAUDE.md` 與 `~/.codex/AGENTS.md` 連結的個人指示；複製進 `~/.claude/settings.json` 的 [Claude Code guard](./docs/guard.md#claude-code-guard) | 某個專案的 `.agents/`、專案政策，或其他任何個人設定 |
| **Friday** | 一份經審查、consumer 可以 pin 並採用的共享 baseline | 這台機器的個人目錄，或某個 consumer 的衝突處理 |
| **Consumer project** | 它自己的 `.agents/` seed、overlays、整合、測試，以及已記錄的 Friday provenance | Jarvis 的個人 Skills，或 Friday 的 vendor payload |

Consumer 專案必須在一台完全沒有個人層的機器上 build、測試並通過 CI —— CI
runner 或別人的筆電上沒有這個 repository 的副本。因此專案所需的一切，屬於該專案
本身或它所採用的 Friday 基線，不屬於這裡。Jarvis 可以協助 agent 在專案上工作，
但絕不能成為專案隱性的依賴。[TDD](./.agents/skills/tdd/) 或
[Wayfinder](./.agents/skills/wayfinder/) 這類個人輔助工具可以幫忙，但專案必需的成果
要放在該專案自己的文件、測試或自動化裡，缺少某個輔助工具也不能擋住它。

這條限制的對象是 consumer 專案，不是 Jarvis。Jarvis 預期存在於這台機器上，在這裡
工作的 agent 可以依賴它。

## 狀態 (2026-11-02)

已就緒：

- **個人指示。** [`.agents/AGENTS.md`](./.agents/AGENTS.md) 被連結成 Claude Code 的
  `~/.claude/CLAUDE.md`，以及 Codex 的 `~/.codex/AGENTS.md`，所以兩者在每個 session
  都會載入它。它依 scope 分組：*Base behavior*（回覆語系、書面規則優先於 auto
  memory、把工作交給較便宜的 model）、*Coding*（先理解、不做臆測、外科手術式的修改、
  驗證、把決定寫在它該在的地方）與 *Contracts*（英文文件加中文摘要、沒有自己規則的
  repository 的 Git 規則）。
- **派工文件。** [`docs/dispatch/`](./docs/dispatch/policy.md) 收有 policy、prompt
  templates 與 Codex adapter。Codex 以 `gpt-6.1-sol` 擔任 Commander，以 `gpt-6-luna`
  擔任 Implementer 與 Worker，已於 2026-10-25 在 codex-cli 0.164.0 上驗證。
- **Claude Code guard。** [guard](./docs/guard.md#claude-code-guard) 拒絕永久禁止的 Git 與檔案操作，並在
  人工審核的關卡詢問，包括可能帶出 tag 的 push 之前。
- **Codex guard。** 同一個 guard 以 user-level 的 Codex hook 執行；因為 Codex 無法詢問，
  Claude Code 會詢問的地方，它一律拒絕（[Codex](./docs/guard.md#codex)）。
- **Git hooks 與 CI。** 三道[本機 hook](./docs/git-hooks.md) 在這個 clone 裡執行。
  [`CI`](.github/workflows/ci.yml) workflow 在每個 pull request 上執行，它的四項檢查
  （Linux 與 macOS 上的測試、Skills 檢查、secret 掃描）在 `main` 上是必要的。
- **發佈版本。** Jarvis 從 v1.0.0（第一個 tag）開始有版本；每個 release 的說明在
  [`CHANGELOG.md`](./CHANGELOG.md)（見[發佈版本](./docs/releases.md)）。
- **Agent 身分。** Claude Code 與 Codex 以各自設定在每台機器上的 machine account 在
  GitHub 上操作，guard 也能拒絕身分沒有套用的 runtime（v1.2.0，
  [#13](https://github.com/ShenYo/Jarvis/issues/13)）。見 [Agent identity](./docs/agent-identity.md)。

待辦：

- agy 的 agent 身分：[#16](https://github.com/ShenYo/Jarvis/issues/16)。
- Codex Skill Phase B 整體上仍屬 **UNVERIFIED**；不要從個別探測或 bridge entries 推論
  已經完成。

一路走來發生了什麼（附日期），以及某些規則背後的量測，都在
[`docs/history.md`](./docs/history.md)。

## 目前盤點

這個 checkout 有 35 個 canonical `SKILL.md` 檔案、35 個 Claude bridge links、35 個
Codex bridge links，以及 35 筆 lock entries。每個 canonical Skill 都是 CLI-managed，
在兩個工具中都可被存取。

`skills` CLI 會寫入 canonical 副本與 lock entry，但不會建立 bridge，因此它安裝的
Skill 在 [`sync-personal-skills.sh`](./sync-personal-skills.sh) 執行之前，對 Claude
Code 與 Codex 都是看不見的：先用 CLI 安裝，再做 bridge
（[歷史](./docs/history.md#inventory-and-unreachable-skills)）。Claude bridge 目錄中若有真實目錄而非
symlink，它屬於其他工具，bridge 腳本刻意不去動它。

這些數字是點算的結果，不是快取；請重新點算而不要直接相信：

```sh
find ~/.Jarvis/.agents/skills -mindepth 1 -maxdepth 2 -name SKILL.md -type f | wc -l
find ~/.claude/skills -maxdepth 1 -type l | wc -l
find "${CODEX_HOME:-$HOME/.codex}/skills" -maxdepth 1 -type l | wc -l
jq '.skills | length' ~/.Jarvis/.agents/.skill-lock.json
comm -23 \
  <(find ~/.Jarvis/.agents/skills -mindepth 1 -maxdepth 2 -name SKILL.md -type f \
    -exec sed -n 's/^name:[[:space:]]*//p' {} \; | sort) \
  <(jq -r '.skills | keys[]' ~/.Jarvis/.agents/.skill-lock.json | sort)
```

## 快速開始

在一台有 Git、能連到 Jarvis remote、而且還沒有 `~/.Jarvis` 的機器上：

```sh
git clone git@github.com:ShenYo/Jarvis.git ~/.Jarvis
git -C ~/.Jarvis config core.hooksPath .githooks
~/.Jarvis/sync-personal-skills.sh
```

這就是完整的 bridge：`~/.Jarvis/.agents` 下唯一一份 canonical copy，連結進 Claude Code 與
Codex。接下來是 guard 與 agent identity；[在新機器上設定](./docs/setup-new-machine.zh-TW.md)
依序帶你走完每一步，每一步之後都有檢查。

## 文件

| 文件 | 何時閱讀 |
| --- | --- |
| [在新機器上設定](./docs/setup-new-machine.zh-TW.md) | 第一次在一台機器上安裝 Jarvis：每一步依序進行，並附檢查。 |
| [讓機器保持最新](./docs/keep-machine-current.zh-TW.md) | Jarvis 有變動，已經導入的機器要跟上：列出各種情境，以及每個情境的步驟。 |
| [Architecture](./docs/architecture.md) | 想了解版面配置與 symlink 鏈如何運作、哪些內容由 CLI 管理，以及 bridge 不能證明什麼。 |
| [Guard](./docs/guard.md) | 想知道 Claude Code 與 Codex 的 guard 拒絕什麼，或要打開 agent-identity 開關。 |
| [Agent identity](./docs/agent-identity.md) | 需要 agent 的 GitHub 帳號的參考資料：建立、設定檔、檢查、Codex 與已知限制。 |
| [Maintenance](./docs/maintenance.md) | 新增、更新、移除或驗證 Skill，或 bridge 出了問題。 |
| [Local Git hooks](./docs/git-hooks.md) | hook 拒絕了某件事，或你要修改其中一個。 |
| [Releases](./docs/releases.md) | 要選版本號或發佈 release。 |
| [Git rules](./docs/git.md) | 要在這裡執行 Git 操作之前。 |
| [History](./docs/history.md) | 想看某條規則背後的來歷與量測。 |
| [Dispatch policy](./docs/dispatch/policy.md) | 要把工作交給另一個 model。 |
| [Changelog](./CHANGELOG.md) | 想知道某個 release 改了什麼，以及在這台機器上要做什麼。 |

設定指南有[英文](./docs/setup-new-machine.md)與繁體中文兩版；其餘文件只有英文，開頭附中文摘要。

## 不在這個 repo 裡

- 專案層級的 `.agents/`——參見開頭的說明；它留在它自己的專案裡。
- `~/.claude/skills/*` 以及設定好的 Codex skills 目錄（預設是
  `~/.codex/skills/*`）——這些是產生出來的 bridge entries；這支腳本只在它們
  缺失或 dangling 時，才建立或替換 canonical-name entries。
- `~/.claude/settings.json`、`~/.codex/config.toml`——可能包含 tokens 或
  路徑的機器層級設定；目前刻意排除在外，值得日後再討論。
