# Jarvis

[English](./README.md) · **繁體中文**

> **繁中摘要**：Jarvis 是這台機器的個人 AI agent Skills 版本庫。它讓
> `~/.Jarvis/agents` 成為唯一 canonical copy，透過 `~/.agents` 與 Claude
> Code／Codex 的 symlink 共用；它也提供 Friday 基線的安全採用 wrapper。專案
> 本身必須不依賴 Jarvis 仍可重現。

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
- **Friday 採用：** 一個本機 wrapper 會先預覽，並在取得全新明確授權後，才將
  已 pin 的 Friday baseline 採用到一個空白專案中。

## 範圍與擁有權

| Layer | Owns | Does not own |
| --- | --- | --- |
| **Jarvis** | 這台機器的 canonical 個人 Skills、bridge script，以及個人 Skill 的 provenance | 某個專案的 `.agents/`、專案政策，或個人設定 |
| **Friday** | 一份經審查、consumer 可以 pin 並採用的共享 baseline | 這台機器的個人目錄，或某個 consumer 的衝突處理 |
| **Consumer project** | 它自己的 `.agents/` seed、overlays、整合、測試，以及已記錄的 Friday provenance | Jarvis 的個人 Skills，或 Friday 的 vendor payload |

一個專案必須在沒有 `~/.Jarvis` 的情況下仍可重現。Jarvis 可以協助 agent 在專案
上工作，但絕不能成為專案隱性的依賴。

## 目前的運作情境

> **繁中摘要**：個人 Skills 是可選輔助，專案必需成果必須由專案自身的
> 文件、測試或自動化承載；Matt Pocock 等 vendor Skill 維持原廠更新路徑。相同
> 名稱的個人 Skill 優先只屬 owner policy，不能當作任何 runtime 的載入保證。

Jarvis 始終是個人、可選的那一層；專案必需的成果必須活在專案自身控制的文件、
測試或自動化裡。[TDD](./agents/skills/tdd/)、[Wayfinder](./agents/skills/wayfinder/)
及其他類似的個人 helper 可以協助工作，但它們的缺席絕不能阻擋 consumer
project。

Matt Pocock 與其他 CLI-managed 的 vendor Skills，只透過它們各自的 owning CLI
更新，且更新前要先審查指名的上游來源。不要為了實作專案 setup 或政策而去修改
它們 vendored 的檔案。當有可選的外部 tracker 可用時，它的專案輸出由該專案自己
的 contract 定義：先解析出 Git root，再使用
`docs/temp/matt-pocock/<feature>/<unique-suffix>/`。若該可選能力、repository
root，或有效的 feature 不存在，就停止該可選工作流程，而不是寫到其他個人或
vendor 的位置。

owner 對某個同名個人 Skill 的偏好，只是一項 ownership policy，不代表任何
runtime 的優先順序。Jarvis 不對 bridge 限制之外的事做任何優先順序宣告。Codex
Skill Phase B 整體上仍屬 **UNVERIFIED**；不要從個別探測或 bridge entries 推論
已經完成。

## 目前盤點

**盤點觀察，2026-10-22：** 這個 checkout 有 36 個 canonical `SKILL.md`
檔案、36 個 Claude bridge links、36 個 Codex bridge links，以及 35 筆 lock
entries。每個 canonical Skill 在兩個工具中都可被存取。

`orca-cli` 與 `orchestration` 曾短暫無法存取：`skills` CLI 會寫入 canonical
副本與 lock entry，但不會建立 bridge，因此它安裝的 Skill 在
[`sync-personal-skills.sh`](./sync-personal-skills.sh) 執行之前，對 Claude Code
與 Codex 都是看不見的。這是正常的操作順序，不是故障 —— 先用 CLI 安裝，再做
bridge。

Claude bridge 目錄中另有一個 `synced` 項目。它是真實目錄而非 symlink，屬於
其他工具，因此 bridge 腳本刻意不去動它。
[`setup-project-agents`](./agents/skills/setup-project-agents/) 則是唯一沒有
lock entry 的 canonical Skill。

```sh
find ~/.Jarvis/agents/skills -mindepth 1 -maxdepth 2 -name SKILL.md -type f | wc -l
find ~/.claude/skills -maxdepth 1 -type l | wc -l
find "${CODEX_HOME:-$HOME/.codex}/skills" -maxdepth 1 -type l | wc -l
jq '.skills | length' ~/.Jarvis/agents/.skill-lock.json
comm -23 \
  <(find ~/.Jarvis/agents/skills -mindepth 1 -maxdepth 2 -name SKILL.md -type f \
    -exec sed -n 's/^name:[[:space:]]*//p' {} \; | sort) \
  <(jq -r '.skills | keys[]' ~/.Jarvis/agents/.skill-lock.json | sort)
```

## 架構與版面配置

```
AGENTS.md                    rules for an agent working in this repository
CLAUDE.md                    a pointer that imports AGENTS.md
agents/
  skills/<name>/SKILL.md     canonical skill content
  .skill-lock.json           what the skills CLI installed, and from where
sync-personal-skills.sh      ensures the Claude bridge directory and
                             missing/dangling canonical-name links; idempotent
```

[`AGENTS.md`](./AGENTS.md) 是告訴 agent 在這裡不該碰什麼的地方：多數 Skill 是
vendored、屬於上游的 CLI，其中兩個與 Friday 基線衝突，而那些 hook 是副本。它的工作
規則是**這個 repository 自己的**，寫在那裡而不是借來的 —— 基礎紀律不該依賴另一個
repository。例外是 Git 規則，那些跟著 hook 一起來：那三個 hook 是 Friday 的逐位元組
副本，所以它們強制的規則就是 Friday 的文字，也隨 hook 一起改變。

`agents/` 才是真正的內容。這個 repo 以外的一切都只是指向它的 symlink，因此每個
skill 永遠只有一份副本。

`~/.agents` **必須是指向 `~/.Jarvis/agents` 的 symlink**。它是 Claude 與 Codex
bridge links 解析時所依賴的穩定位址。

一個 skill 是「包含 `SKILL.md` 的目錄」——不只是任何目錄。Skills 可以被歸在
一個本身沒有 `SKILL.md` 的 container 下方、低一層的位置；這個 container 不會
被 link，但裡面的 skills 會。link 的名稱來自各個 skill 的 `name:` frontmatter，
也是工具用來比對的依據，所以 `agents/skills/git/commit/`（`name: git-commit`）
會被 link 成 `~/.claude/skills/git-commit`。目前這個 repo 裡沒有任何巢狀結構；
之所以支援這種寫法，是因為 pet_care 用這種方式把它的四個 git skills 分組，而
曾經有一支假設「一個 skill 對應一個目錄」的腳本，結果同時把那個無法載入的
container link 了出去，也把真正的 skills 藏在裡面。

## Symlink 鏈

```
~/.agents                 -> .Jarvis/agents
~/.claude/skills/<name>   -> ../../.agents/skills/<name>
${CODEX_HOME:-$HOME/.codex}/skills/<name>
                           -> ../../.agents/skills/<name>
```

兩段 hop，而且第二段才是關鍵：`~/.claude/skills/<name>` 把 `../../` 解析回
`~/`，所以它會經過 `~/.agents`，而不是直接指向這個 repo。這是刻意設計——
`~/.agents` 是那個穩定位址，而 bridge script 則要求這個 repository 必須 clone
在 `~/.Jarvis`。

## 沒有東西需要同步

`~/.agents` 是一個 symlink，不是一份副本。`~/.agents/skills/foo/SKILL.md` 和
`~/.Jarvis/agents/skills/foo/SKILL.md` 是同一個 inode——一份檔案有兩個名字。
透過任一路徑編輯都是在編輯同一批 bytes，而這個 repo 裡的 `git status` 會立刻
看到。兩者不可能漂移，因為本來就只有一份。

這正是為什麼這個 repo 要 clone 在 `~/.Jarvis`、並讓 `~/.agents` 指向它內部，
而不是在兩個地方各維護一份同樣形狀的副本。兩個真實目錄就需要同步，也就會漂移；
一個目錄有兩個名字則不會。

唯一會讓這套機制壞掉的情況，是有東西把 `~/.agents` 這個 symlink **取代**成
一個真實目錄——這樣兩份副本就真的存在了，編輯會落在工具當時打開的那一份，而
且不會有任何提示。[`sync-personal-skills.sh`](./sync-personal-skills.sh)
在這種情況下會拒絕執行，並要求你先 diff 兩者再做選擇，而不是悄悄地在錯誤的
那一份上面繼續 link。

## 在新機器上設定

> **繁中摘要**：Jarvis 是個人可選層。先確認 Git、Bash 與遠端存取權，且
> `~/.Jarvis` 不存在；clone 後只執行 bridge 與唯讀確認。此流程不安裝 Claude／
> Codex、不設定憑證，也不讓新專案依賴 Jarvis。

前置條件是 Git、Bash，以及對設定好的 Jarvis remote 的存取權。只有在
`~/.Jarvis` 還不存在時才選擇這個 canonical destination；絕對不要在既有的
checkout 上面再 clone 一次。既有的 checkout 應該在它自己的 Git history 下
檢查與調解。

```sh
(
  set -eu
  if [ -e "$HOME/.Jarvis" ] || [ -L "$HOME/.Jarvis" ]; then
    echo '~/.Jarvis already exists or is a dangling link; inspect it instead of overwriting it.' >&2
    exit 1
  fi
  git clone git@github.com:ShenYo/Jarvis.git "$HOME/.Jarvis"
  "$HOME/.Jarvis/sync-personal-skills.sh"
)
```

這個 bridge 指令既不會安裝任何 runtime，也不會建立任何憑證。對某個專案而言，
完全省略 Jarvis 也是安全的：個人 Skills 始終是可選的。執行 bridge 之後，請用
[驗證](#驗證) 小節裡的唯讀檢查，確認 canonical symlink 以及任何已安裝的
Claude/Codex bridge 目錄。

對於新專案，請從另外一份經過審查、乾淨的 Friday checkout 來 bootstrap 這份
可攜式 baseline；不要把 Jarvis 的 Skills 複製進專案裡。位於 `~/.agents` 下的
可選 Skill
[`setup-project-agents`](./agents/skills/setup-project-agents/) 只是一個
方便用的 wrapper，用於空白專案的 Friday 採用，並不是這個手動流程、或任何
consumer project 的前提條件。

這支腳本會在 `~/.agents` 不存在時建立它、確保 Claude bridge 目錄存在，並且只
在某個 canonical-name entry 缺失或 dangling 時才建立或替換它。它只在
`${CODEX_HOME:-$HOME/.codex}/skills` 已經存在時才對 Codex 做 bridge；不存在
的 Codex 目錄會被跳過，而不是視為錯誤。它會檢查每個 canonical skill，在每個
已 bridge 的工具裡，是否都有一個以其宣告名稱存在的 entry，回報 dangling 的
non-reserved entries，並拒絕一個既不是 Skill、也不是 grouping directory 的
top-level canonical 目錄。一個指向錯誤目標、但本身仍是 live 的
canonical-name entry 會被保留不動，也不會被偵測出來。這些檢查任一失敗，它就會
以非零狀態結束。每次新增或移除一個 skill 之後，請重新執行它。

## 日常維護

### 新增

在 `agents/skills/` 底下（或某個 grouping directory 低一層的位置）新增一個
包含 `SKILL.md` 的目錄。當 bridge 名稱需要和目錄名稱不同時，給它一個獨一無二
的 `name:` frontmatter 欄位，然後執行 bridge script 並檢查結果：

```sh
~/.Jarvis/sync-personal-skills.sh
git -C ~/.Jarvis diff --check
git -C ~/.Jarvis status --short
```

### 更新

對於本地維護的內容，直接編輯受追蹤的檔案、檢查 diff，再執行 bridge script。
對於 CLI-managed 的 Skill，先檢查
[`agents/.skill-lock.json`](./agents/.skill-lock.json) 裡記錄的來源，確認那個
指名的上游 Skill 仍然存在，才使用它的 owning CLI 去更新那個指名的 Skill。

不要把 `npx skills update -g` 這種大範圍更新當成例行維護。上游有可能刪除
Skills，而一次大範圍的更新可能會悄悄移除本地已安裝的版本。指名、經過審查的
更新，才能保留「什麼東西離開這個 repository」這個決定權。

### 移除

透過一次經過審查的 Git 變更來移除某個 canonical Skill。接著檢查它留下的
dangling bridge links，只移除那些確切的 links，再重新執行 bridge script。這支
腳本會回報 dangling 的 non-reserved entries，但只會在某個 canonical skill
名稱上替換掉 dangling entry；它不會去猜哪些看起來還活著的工具 entries 可以
安全刪除。

```sh
find ~/.claude/skills -maxdepth 1 -type l ! -exec test -e {} \; -print
CODEX_SKILLS="${CODEX_HOME:-$HOME/.codex}/skills"
[ ! -d "$CODEX_SKILLS" ] || find "$CODEX_SKILLS" -maxdepth 1 -type l ! -exec test -e {} \; -print
```

### 驗證

執行
[`~/.Jarvis/sync-personal-skills.sh`](./sync-personal-skills.sh) 就是標準的
bridge 檢查。若要做唯讀檢查，可以使用：

```sh
test -L ~/.agents && test "$(cd -P ~/.agents && pwd)" = "$(cd -P ~/.Jarvis/agents && pwd)"
find ~/.Jarvis/agents/skills -mindepth 1 -maxdepth 2 -type f -name SKILL.md | sort
find ~/.claude/skills -maxdepth 1 -type l -print | sort
CODEX_SKILLS="${CODEX_HOME:-$HOME/.codex}/skills"
[ ! -d "$CODEX_SKILLS" ] || find "$CODEX_SKILLS" -maxdepth 1 -type l -print | sort
```

### 修復 `~/.agents` 衝突

如果腳本回報 `~/.agents` 是一個真實目錄，或解析到別的地方，請先停下來。先把
它跟 canonical 目錄比較，再決定哪一份副本是目前有效的版本：

```sh
diff -ru ~/.agents ~/.Jarvis/agents
```

完成比較之後，把有衝突的那個目錄保留成一份有日期標記的備份，重新建立所需的
symlink，再重新執行 bridge script。沒有備份就直接取代，可能會遺失未提交的
Skills。

```sh
mv ~/.agents "$HOME/.agents.conflict-$(date +%Y%m%d-%H%M%S)"
ln -s .Jarvis/agents ~/.agents
~/.Jarvis/sync-personal-skills.sh
```

## Friday 採用 wrapper

[`setup-matt-pocock-skills`](./agents/skills/setup-matt-pocock-skills/) 是
third-party/CLI-managed 的。**不要為了專案 setup 去修改它。**請改用本地維護
的 [`setup-project-agents`](./agents/skills/setup-project-agents/) wrapper。
它刻意設計得很窄：它採用的是 Friday 的共享 baseline，不是個人 Skills、
consumer overlays，也不是衝突處理。

只在一個空白的 Git repository 裡，使用 `$setup-project-agents` 來預覽並採用
一個已 pin 的 Friday baseline：

```text
$setup-project-agents target=/absolute/path/to/repository friday=/absolute/path/to/Friday
```

兩個路徑都是必需的。這個 skill 會將它們 canonicalize，要求 `target` 必須是
一個 Git repository root，`friday` 必須是另一個乾淨、擁有正常 `install.sh` 與
`payload` 路徑的 Git worktree，然後記錄 Friday 的完整 SHA 與 target 的 Git
狀態。它在取得授權之前唯一會做的動作是：

```sh
bash "$friday/install.sh" --check "$target"
```

把那個經過審查的 Friday SHA 記錄為 pin。任何衝突或預覽失敗，都會停止這個
工作流程，交由 consumer 自行調解；這個 wrapper 和 Friday 都不是 update
engine。要進行安裝，需要一次全新、明確的授權，同時指名 canonical target 以及
那個確切已 pin 的 SHA。只有到那時，這個 skill 才會執行 Friday 的 installer、
再次預覽、執行 consumer 的 checker，並回報 target 的狀態與 diff 檢查結果。

不要手動複製 baseline 檔案、修改 Friday 或它的 vendor payload，也不要為了
這個工作流程去更動任何 lock file。這個 skill 不會建立任何 commit 或 push；
consumer 要依照自己經過審查的慣例，記錄已 pin 的 provenance 以及任何原子性的
採用 commit。

## CLI-managed 與本地維護的內容

[`agents/.skill-lock.json`](./agents/.skill-lock.json) 記錄了 Skills CLI
安裝過的 Skills，包括它們的來源、路徑、hash 與時間戳記。請把它們當成
third-party/CLI-managed：不要隨意修改它們的內容，也不要為了讓某次安裝看起來
不一樣而改寫這份 lock。缺少 lock entry，只代表那個 CLI 沒有記錄那個 Skill；
並不會讓某個 canonical Skill 失效。

Jarvis 的 bridge script、這份 README，以及
[`setup-project-agents`](./agents/skills/setup-project-agents/) 都是本地
維護的。個人設定則刻意被排除在外：`~/.claude/settings.json` 與
`~/.codex/config.toml` 可能包含本機路徑或機密資訊，目前並不屬於這個
repository。

## 本機 Git hooks

`core.hooksPath` 指向 [`.githooks/`](.githooks)，所以這個 clone 會執行三道
commit 期與 push 期的檢查。它們是防手滑的護欄，不是伺服器端的控制：
`core.hooksPath` 是 per-clone 設定、永遠不會被 clone 帶走，所以重新 clone
這個 repository 之後，在有人再次設定之前這三道檢查都不會執行。

| Hook | 會拒絕什麼 |
| --- | --- |
| [`pre-commit`](.githooks/pre-commit) | staged diff 的新增行看起來像憑證、金鑰、token、密碼或連線字串。它只會說出規則名稱與檔案，不會印出比對到的值。 |
| [`commit-msg`](.githooks/commit-msg) | 主旨不符 Conventional Commits；以及較大的改動沒有內文說明「為什麼」。 |
| [`pre-push`](.githooks/pre-push) | 刪除 remote ref、改寫歷史（force-push）、以及直接推送 default branch。它是依據被推送的 ref 判斷，不是看指令字串。 |

這三個都是這個平台的姊妹 repository 發給 consumer 的檔案副本，位於
[Friday](https://github.com/ShenYo/Friday) 的 `payload/.agents/githooks/`。
這個 repository 不是 Friday payload consumer —— 它沒有 `.agents/` 樹 ——
所以 `install.sh` 無法接線，只能用副本。每一個現在都與 payload 的對應檔案
**逐位元組相同**，`pre-push` 也包含在內：這些 hook 改成在執行期解析指引文件的
路徑、而不是寫死它，這正是最後一處預期差異消失的原因。因此

```sh
for h in pre-commit commit-msg pre-push; do
  diff ~/.Friday/payload/.agents/githooks/$h .githooks/$h
done
```

應該完全不輸出任何東西；只要有輸出，那就是走樣。

### `hooks.json`

上面三個 hook 都是副本，所以需要有東西在其中之一走樣時發現。`hooks.json`
以 `sha256sum -c` 能讀的版面記錄每一個的 sha256，而
[`.github/workflows/hooks-drift.yml`](.github/workflows/hooks-drift.yml)
會在變更時與每天各檢查一次。不需要 Friday 的 checkout，也不需要跨
repository 的 token：這份記錄是自給自足的。

**這個 repository 不是 Friday consumer，兩者也沒有互相綁定。** Friday 的
payload 有十九個檔案；這個 repository 只取其中**三個** —— 上面那些 hook ——
別的都不取：沒有 `.agents/` 樹、沒有 Friday 的任何文件、沒有
`.claude/settings.json`。它自己的 [`AGENTS.md`](./AGENTS.md) 是本地撰寫的，陳述它
自己的工作規則；只在那三個 hook 所強制的規則上連結 Friday，而那些規則依其構成本來
就是 Friday 的。Friday 也完全不依賴這個 repository。兩者各自維護、服務不同對象：這邊是
personal scope，Friday 是 project scope。

這也是檔名不帶 `friday-` 前綴的原因。它只以它唯一的身分命名 —— 這個
repository 所保有的那些 hook 的記錄。**consumer** 帶的是
`.friday-lock.json`；兩者永不同時出現，而 `friday-lock` 會拒絕同時持有兩者的
repository。

它之所以存在，是因為另一種做法失敗過：當 Friday 的 `pre-push` 改動時，這裡的
副本被漏掉了 —— 連 Friday 自己那份也一樣 —— 而且沒有任何東西回報。讓副本保持
同步曾經是一個手動步驟，而手動步驟會被跳過。

這裡的走樣用複製修復；若是 Friday 的 payload 動了，則照正規路徑帶過來：

```sh
bash ~/.Friday/bin/friday-propagate ~/.Jarvis
```

### 為什麼 push 規則放在這裡，也放在 GitHub 上

它們以前是放在這裡**而非** GitHub：private repository 的 ruleset 需要付費
方案，而這個 repository 當時是免費方案下的 private repo。現在它是 public，
所以 `main` 上有一個生效中的 ruleset —— 它拒絕刪除與 non-fast-forward push、
並要求 pull request，且沒有任何 bypass actor。

`pre-push` 保留，有兩個理由。它在推送的那一刻就拒絕，而不是等一趟往返之後，
所以 agent 得到的是原因而不是一個被拒的 ref。而且它保護這個 clone，即使面對
一個完全沒有規則的 remote —— 某個 fork、某個 mirror，或是日後被誰放寬的
ruleset。伺服器端的規則是無法被跳過的那一個；hook 是會解釋自己的那一個。

無論如何，hook 只保護這一個 clone —— 正因為如此，它拒絕的那三個操作同時也被
寫成「對 agent 永久禁止」，而不是指望這個 hook 一定存在。

### 如果 hook 擋了不該擋的東西

不要動用 `--no-verify`，collaborative Git guard 會拒絕這個旗標。規則錯了就該
修 hook 並記錄原因，或是在該行標上 `secret-scan:allow` 並就地說明理由。那個
標記刻意是逐行的：沒有檔案層級或目錄層級的整體豁免。

## 歷史背景

在 2026-09-07 之前，這個 bridge 都是手動維護的，已安裝的 Skills 可能存在於
磁碟上，卻對 Claude Code 不可見。正是這次事件，促成了這個 bridge 必須是可以
安全重複執行、並且會檢查 canonical-name 是否存在與 dangling entries，而不只是
印出「成功」。

## Bridge 狀態與限制

[`sync-personal-skills.sh`](./sync-personal-skills.sh) 確保每個 canonical
名稱，在每個已 bridge 的工具裡都存在對應的 entry，並回報 dangling 的
non-reserved entries。它不會驗證或修復一個指向錯誤目標、但本身仍是 live 的
canonical-name entry，也沒有證明 Git-operation 的強制力，或各個 runtime 自身
native skill-loader 的行為。

Claude Code 在 `~/.claude/skills/` 收到 links。Codex 在
`${CODEX_HOME:-$HOME/.codex}/skills` 收到 links；`.system` 與
`codex-primary-runtime` 仍是 tool-owned，這支腳本會跳過它們。Codex 的
installer 文件與一支 Python listing 工具，都支援這個目標位置與 symlink 慣例，
但那個已編譯的 Codex runtime loader 行為仍未被驗證。

Jarvis 不對 Claude 或 Codex 在個人、專案與內建 Skills 之間的 runtime 優先
順序做任何宣告。一個 live 的 link 只是檔案系統層級的證據，並不能證明某個特定
prompt 一定會載入某個特定 Skill。

以下兩點是在 **Claude Code 2.1.306** 上原生觀察到的（2026-10-22），地點是一個
消費端 repository 與一次性 fixture。它們不會把上面那段話變成優先序規則；它們
只是被看到的事實。

- **這個 bridge 確實能到達消費端 repo 的 session。** 一個根在其他 repository
  的 session 回報 `code-review`、`tdd`、`research`、`writing-for-agents` 與
  `setup-project-agents` 皆為可用，解析路徑是 `~/.claude/skills/<name>` →
  `~/.agents/skills`，而 `~/.agents` → `.Jarvis/agents`。所以這裡的集中化確實
  會到達一個運作中的 session，不只是存在於檔案系統上。
- **同名碰撞時，出現的是個人版，而專案版完全沒有被列出。** 一個 fixture 在
  `.claude/skills/research/` 放了專案版 skill，與這個 repository 的個人
  `research` 同名。一個停用了所有工具的 session —— 因此答案只能來自已載入的
  context —— 回報**恰好一個**名為 `research` 的 skill，並逐字引用了個人版的
  描述。同一個 fixture 裡的控制組（一個沒有同名對手的專案 skill）**有**被
  列出，這才讓碰撞結果具有意義，而不是單純的「沒被發現」。

  實務上的後果是：輸的那個 Skill 是**不可見**的，而不只是優先序較低，所以
  session 沒辦法被要求改用另一個。如果某個專案需要自己版本的、而這裡也存在的
  名稱，請把其中一個改名。

  一個名稱、一個 fixture、一個版本、兩個 scope。對 project-vs-plugin、
  plugin-vs-personal 或 Codex，都不做任何宣稱。

Gemini 目前沒有由這支腳本建立的 bridge。它的 discovery 與 runtime 行為在
這裡是 pending/unknown 的；這份 README 不對 Gemini 做任何強制性宣告。

## 兩個該知道的 CLI 行為

避免使用 `npx skills add -y`：它那種 non-interactive 的 fan-out，可能會在
`$HOME` 裡建立不相關的 agent 目錄。讓它用 prompt 或 select 的方式，只處理
你真正要的 agents。

避免大範圍使用 `npx skills update -g`：2026-09-07 的一次稽核發現，上游曾經
移除過一些仍在本地安裝的 Skills。只有在先檢查過某個特定上游 Skill 之後，才
使用 `npx skills update -g <name>`，然後再檢查 diff。目前全域 lock 的檔名是
[`agents/.skill-lock.json`](./agents/.skill-lock.json)；`skills-lock.json`
則是 project scope 的。缺少 `agents/openai.yaml` descriptors，本身並不是
重新安裝的理由。

## 疑難排解

```sh
# Confirm the required canonical symlink and its resolved destination.
ls -ld ~/.agents ~/.Jarvis/agents
readlink ~/.agents

# Ensure bridge directories and missing/dangling canonical-name links; report
# dangling non-reserved entries.
~/.Jarvis/sync-personal-skills.sh

# Show dangling bridge links without changing them.
find ~/.claude/skills -maxdepth 1 -type l ! -exec test -e {} \; -print
CODEX_SKILLS="${CODEX_HOME:-$HOME/.codex}/skills"
[ ! -d "$CODEX_SKILLS" ] || find "$CODEX_SKILLS" -maxdepth 1 -type l ! -exec test -e {} \; -print

# Show canonical names that determine bridge entry names.
find ~/.Jarvis/agents/skills -mindepth 1 -maxdepth 2 -name SKILL.md -type f \
  -exec sed -n 's/^name:[[:space:]]*//p' {} \; | sort

# Inspect CLI provenance when jq is available.
jq -r '.skills | to_entries[] | "\(.key)\t\(.value.source)\t\(.value.skillPath)"' \
  ~/.Jarvis/agents/.skill-lock.json | sort
```

不要用「再建立一份真正的 `~/.agents` 副本」「把每個 Skill 手動複製進某個
工具目錄」，或「讓某個專案改成依賴 Jarvis」的方式，來解決 bridge 失敗。請修復
那唯一一份 canonical 副本，再重新執行這支腳本。

## 不在這個 repo 裡

- 專案層級的 `.agents/`——參見開頭的說明；它留在它自己的專案裡。
- `~/.claude/skills/*` 以及設定好的 Codex skills 目錄（預設是
  `~/.codex/skills/*`）——這些是產生出來的 bridge entries；這支腳本只在它們
  缺失或 dangling 時，才建立或替換 canonical-name entries。
- `~/.claude/settings.json`、`~/.codex/config.toml`——可能包含 tokens 或
  路徑的機器層級設定；目前刻意排除在外，值得日後再討論。
- `~/.claude/skills-backup-2026-08-04/`——這個 repo 存在之前的一份手動備份，
  在 2026-09-07，於確認其中九個 skills 都與受追蹤的副本逐 byte 相同之後被
  刪除。現在 Git 就是備份。
