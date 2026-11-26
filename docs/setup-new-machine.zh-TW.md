# 在新機器上設定

[English](./setup-new-machine.md) · **繁體中文**

> **中文摘要**：這份指南分三個階段帶你在一台全新的機器上完成 Jarvis：stage 1 指示與 Skills，
> stage 2 guard，stage 3 identity（選用，最後做，可以完全略過 machine account）。
> 內容依序是：安裝前置工具、clone 到
> `~/.Jarvis` 並啟用 Git hooks、執行 bridge、套用 Claude Code 與 Codex 的 guard、設定 agent
> identity（Claude Code 與 Codex 各一次），可選擇打開 `--require` 開關，最後逐項驗證。clone 與
> bridge 本身不安裝 runtime、不建立憑證，也不讓新專案依賴 Jarvis；憑證只出現在 agent identity 那幾步。

在一台從沒裝過 Jarvis 的機器上，從頭照著做。每一步結尾都有檢查，確認成功了再往下。
所有指令都在一般的終端機裡執行，不要在 Claude Code 或 Codex 裡用 `!`（見
[已經踩過的坑](#8-已經踩過的坑)）。每個部分的參考資料在
[Architecture](./architecture.md)、[Guard](./guard.md) 與
[Agent identity](./agent-identity.md)（這三份只有英文）。

採用分三個階段。依序進行，任何一個階段之後都可以停下來：

- **Stage 1，指示與 Skills：** clone 與 bridge（第 2、3 步）。這會得到 Skills 與個人指示，
  不安裝 runtime，也不建立憑證。
- **Stage 2，guard：** 第 4 步。它在這台機器的每個專案裡拒絕破壞性的 Git 與檔案操作。
- **Stage 3，identity（選用，最後做）：** 第 5、6 步。這讓 agent 擁有自己的 GitHub 帳號。
  machine account 可以完全略過：stage 1 與 stage 2 不用它就能安裝與運作。你放棄的是
  pull request 這一段：review loop 以 machine account 張貼 comment，沒有的話就什麼都不張貼
  （[review-loop.md](./dispatch/review-loop.md#never-as-the-owner)，只有英文），而且 agent 開的
  pull request 會是你自己的，你不能自己 approve
  （[fork 清單](./fork-checklist.md#5-what-a-fork-does-not-get)，只有英文）。

如果你是 fork 了 Jarvis，而不是 clone owner 的副本，請先讀 [fork 清單](./fork-checklist.md)
（只有英文）。

clone 之後（第 2 步），`bash ~/.Jarvis/scripts/bootstrap.sh` 會依 stage 的順序，做完 stage 1 與 stage 2 裡每一個腳本做得到的步驟，
並在每個標著 **Person-only** 的步驟停下來，說明要做什麼、在哪裡做、怎麼知道做成了，以及繼續的指令（就是再執行一次
同一個指令）。它可以安全地重複執行：已經做完的步驟不會有任何變動。它只做 stage 1 與 stage 2：stage 3 是選用的，
而且需要你親自做。它絕不安裝系統套件。`bash ~/.Jarvis/scripts/bootstrap.sh --check` 印出的內容和 `doctor.sh`
完全一樣，而且什麼都不改。下面的步驟就是腳本所做的事，以及需要手動做的事。

## 1. 前置條件

前置條件是 Git、Bash，以及對設定好的 Jarvis remote 的存取權。只有在
`~/.Jarvis` 還不存在時才選擇這個 canonical destination；絕對不要在既有的
checkout 上面再 clone 一次。既有的 checkout 應該在它自己的 Git history 下
檢查與調解。

clone 與 bridge 不需要更多東西。這份指南其餘的部分需要，所以開始之前請裝好你打算做的那些階段所需要的：

- `git`：用來 clone，也用來執行這個 repository 的 hooks。
- `gh`：GitHub CLI，用來以 machine account 登入。只有 stage 3 需要；
  略過 machine account 就可以不裝。
- `jq`：guard 的腳本與 agent-identity 腳本都要求它。
- `python3` 3.11 或更新的版本。guard hook 用它執行，而 Codex 是否信任這支 hook，是用
  `tomllib` 讀 `~/.codex/config.toml` 判斷的，只有 Python 3.11+ 才有 `tomllib`。
- `ssh` 與 `ssh-keygen`（OpenSSH）：用來產生與測試 agent 的 key。通常已經裝好。
- Claude Code：已安裝並啟動過一次，讓 `~/.claude` 存在。
- Codex CLI：已安裝並啟動過一次。只有在 Codex 的 home（`~/.codex`，或 `$CODEX_HOME`）存在時，
  bridge 才會連結 Codex。
- 選用：Node.js，用於 `npx skills`。只有之後要安裝或更新 CLI-managed Skill 時才需要。

檢查它們：

```sh
for c in git gh jq python3 ssh ssh-keygen claude codex; do
  command -v "$c" >/dev/null && echo "ok       $c" || echo "MISSING  $c"
done
python3 -c 'import tomllib' && echo "ok       python3 has tomllib"
```

每一行都應該以 `ok` 開頭，有兩個例外：只做到 stage 1 的話，`jq` 與 `python3` 可以缺少；
在 stage 3 之前停下來的話，`gh`、`ssh` 與 `ssh-keygen` 可以缺少。

**Person-only：** 安裝這些程式，以及安裝並啟動 Claude Code 與 Codex。Claude Code 還沒啟動過，或缺少 `jq` 或
`python3` 時，`bootstrap.sh` 會停下來，並指出缺了什麼。

## 2. Clone Jarvis

Stage 1。

clone 到 `~/.Jarvis`。路徑是固定的：bridge 腳本要求這個 repository 必須 clone 在那裡。下面的區塊
在 `~/.Jarvis` 已經存在時會拒絕執行。

```sh
(
  set -eu
  if [ -e "$HOME/.Jarvis" ] || [ -L "$HOME/.Jarvis" ]; then
    echo '~/.Jarvis already exists or is a dangling link; inspect it instead of overwriting it.' >&2
    exit 1
  fi
  git clone https://github.com/ShenYo/Jarvis.git "$HOME/.Jarvis"
)
```

接著啟用這個 repository 的 Git hooks。`core.hooksPath` 是 per-clone 設定，所以全新的 clone 在你設定它
之前不會執行任何 hook（[本機 Git hooks](./git-hooks.md)）：

```sh
git -C ~/.Jarvis config core.hooksPath .githooks
```

檢查：`git -C ~/.Jarvis config --get core.hooksPath` 印出 `.githooks`。

**Person-only，只做一次：** clone 是你自己輸入的那一個指令，因為 `bootstrap.sh` 就在 clone 裡面。它會檢查
checkout 是不是 `~/.Jarvis`，然後在 hooks 路徑尚未設定時自己設定上面的路徑，並做第 3 步。

## 3. 建立 Skills 的 bridge

Stage 1。

執行 bridge 腳本。它可以安全地重複執行，每次新增或移除 Skill 之後都要重新執行：

```sh
~/.Jarvis/sync-personal-skills.sh
```

檢查：它以 `checks passed:` 開頭的一行結束，並以 0 離開。

每一個 Skill 都被這個 repository 追蹤，所以 clone 加上 bridge 就是完整的設定：執行
期不需要抓取任何東西才能讓 Skill 可用，執行它們也不需要 Skills CLI。需要它的時機有
兩個：之後要安裝或更新 CLI-managed Skill 時，見[CLI-managed 與本地維護的內容](./architecture.md#cli-managed-and-locally-maintained-content)；
以及某一個 Skill 自己的流程 —— [`find-skills`](../.agents/skills/find-skills/) 是去找
**尚未**安裝的 Skill，所以它會連網，而它的搜尋步驟會執行 `npx skills find`。只有
clone 的機器可以執行這裡其他每一個 Skill；那一個會停在它的第一步。

這個 bridge 指令既不會安裝任何 runtime，也不會建立任何憑證。對某個專案而言，
完全省略 Jarvis 也是安全的：個人 Skills 始終是可選的。執行 bridge 之後，請用
[驗證](./maintenance.md#verify) 小節裡的唯讀檢查，確認 canonical symlink 以及任何已安裝的
Claude/Codex bridge 目錄。

新專案的 baseline，從維護那份 baseline 的地方取得，並依照該來源自己的採用指南。
不要把 Jarvis 的 Skills 複製進專案：它們是個人的，而專案必須在沒有它們的機器上
也能運作。

這支腳本也會把 `~/.claude/CLAUDE.md` 連結到 `.agents/AGENTS.md` 的個人指示：link
不存在時建立，懸空時替換。在兩種情況下它會拒絕，而且不會替換它：一是
`~/.claude/CLAUDE.md` 是一個真正的檔案，因為那裡有人寫好的指示；二是它是一個指向
別處、仍然有效的 link，因為那是刻意的設定。若要在已經有 `~/.claude/CLAUDE.md` 的
機器上採用這個 link，先把要保留的內容搬進 `.agents/AGENTS.md`，移除原檔，再重跑
腳本。

**Person-only，遇到時才需要：** 決定既有的指示檔或 Skill entry 要保留什麼。
`bootstrap.sh` 會先用 `sync-personal-skills.sh --check` 問 bridge，這個指令什麼都不改。
只要 bridge 回報任何 `CONFLICT` 或 `SHADOWED` 的行，`bootstrap.sh` 就會在寫入任何東西之前以 exit 3
停下來，並原樣列出 bridge 自己的那些行。缺失或 dangling 的 link 不是 stop：正常執行會建立或替換它。

安裝了 Codex 時，`${CODEX_HOME:-$HOME/.codex}/AGENTS.md` 也會得到同樣的 link 與同樣
的拒絕規則，所以兩個工具讀的是同一份檔案，沒有需要同步的副本。Codex 的 home 裡若有
非空的 `AGENTS.override.md`，Codex 會改讀它而不讀 `AGENTS.md`，所以只要它存在，腳本
就會停下來（bridge 稱之為 `SHADOWED`）。當 `~/.gemini/config` 存在時，agy 的
`~/.gemini/config/AGENTS.md` 也會得到同樣的 link 與同樣的拒絕規則（不碰 Gemini CLI
共用的 `~/.gemini/GEMINI.md`）。`~/.claude/skills` 或 `${CODEX_HOME:-$HOME/.codex}/skills`
底下若已有同名、但不是指向該 Skill 的 link 的 entry，也以同樣方式拒絕。

這支腳本會在 `~/.agents` 不存在時建立它、確保 Claude bridge 目錄存在，並且只
在某個 canonical-name entry 缺失或 dangling 時才建立或替換它。當
`${CODEX_HOME:-$HOME/.codex}` 存在時它會對 Codex 做 bridge，並在需要時建立其下的
`skills/`，因為全新安裝的 Codex 有 home 但還沒有該子目錄
（[歷史](./history.md#codex-bridge-decided-by-its-home)）。不存在的 Codex home 會被跳過，而不是視為
錯誤。它會檢查每個 canonical skill，在每個
已 bridge 的工具裡，是否都有一個以其宣告名稱存在的 entry，回報 dangling 的
non-reserved entries，並拒絕一個既不是 Skill、也不是 grouping directory 的
top-level canonical 目錄。一個 live、但沒有解析到其 canonical 目錄的
canonical-name entry 會被回報為 `CONFLICT`（entry、它指向哪裡、預期是什麼），並保留不動，
絕不覆寫。這些檢查任一失敗，它就會
以非零狀態結束。每次新增或移除一個 skill 之後，請重新執行它。

## 4. 套用 guard

Stage 2。

套用 guard：`bash ~/.Jarvis/scripts/apply-claude-guard.sh` 與
`bash ~/.Jarvis/scripts/apply-codex-guard.sh`。

```sh
bash ~/.Jarvis/scripts/apply-claude-guard.sh
bash ~/.Jarvis/scripts/apply-codex-guard.sh
```

每支腳本都把自己的檔案複製進 `~/.claude` 或 `~/.codex`（有設 `$CODEX_HOME` 就用它），並把被取代的內容
留成 `.guard-backup`。Claude Code 的 guard 在下一個 session 生效。guard 拒絕什麼，見
[Guard](./guard.md)。

Codex 要等你信任這支 hook 才會執行它。啟動 Codex，打開 `/hooks`，信任 Jarvis guard。信任是依 hash
計算的，所以 hook 或它的設定每次有變動，都要再信任一次。腳本絕不寫入那份信任，只讀它：

```sh
bash ~/.Jarvis/scripts/apply-codex-guard.sh --trust
```

檢查：兩支腳本加 `--check` 都以 0 離開，而 `--trust` 印出
`trust: OK - Codex trusts the Jarvis guard entry` 並以 0 離開。

**Person-only：** 在 Codex 的 `/hooks` 裡信任這支 hook。`bootstrap.sh` 會套用兩個 guard，然後停在這裡，直到
`--trust` 成功。

選用，而且 person-only：告訴 Claude Code 的 auto-mode classifier 這台機器信任哪些 repository。在 Claude Code 裡，從
Jarvis checkout（`~/.Jarvis`）內執行 `/auto-mode-setup`；從 home 目錄執行的話，它描述的是沒有 remote 的
目錄。它會先問要加到現有的 environment 清單還是取代：選加入，因為取代會丟掉手動補上的 repository 和
`"$defaults"` 項目。接著它會提供兩個選用的掃描；接受讀取 home 目錄下各 repository 的那一個，其他
repository 會一併起草，不接受就事後手動補上。起草結果只能整份接受或捨棄：先接受，事後再刪減。然後讀一下起草寫入的全部內容，不只 environment 清單：

```sh
jq '.autoMode' ~/.claude/settings.json
```

在 `environment` 裡只留下你擁有或會 push 的 repository，因為每一個都會成為受信任的目的地；刪掉你不認得的項目，例如沒有來源的受信任服務項目，並保留 `"$defaults"`，它代表內建的
項目（缺少而你想保留內建項目時，把它加成第一個項目）。如果起草加了 `allow` 項目，刪掉任何和 guard 的
Human-Review Checkpoint 規則重疊的項目（merge、auto-merge、關閉或重新開啟 pull request、push 到預設
branch、修改 repository 設定）：`allow` 項目是 guard 的 `soft_deny` 規則的例外，而
`--check` 看不到它。可以在 `/permissions` › Auto mode 或 `~/.claude/settings.json` 編輯清單，再用
`claude auto-mode config` 確認實際生效的內容。如果起草在 `soft_deny` 或 `hard_deny` 加了規則，再執行一次
`apply-claude-guard.sh`，讓它的 `--check` 以 0 離開。

repository 的組合有變動時，重新執行或直接編輯。這個設定是每台機器、每個人各自的：它記的是那台機器的
repository 與受信任服務，所以不要從別台機器複製。它不存在 `guard.json`，`apply-claude-guard.sh`
也不會寫入或覆寫它。

## 5. 設定 agent identity

Stage 3，選用。

**Person-only：** 這一節裡除了 `--check` 與寫入 identity 的單純 `apply-agent-identity.sh` 之外的全部：
machine account 與它的邀請、回答 `--setup`、在 GitHub 加入 public key、用 `gh` 登入，以及重新啟動。
`bootstrap.sh` 一樣都不做。

要讓 agent 以自己的帳號操作 GitHub，在 guard 之後依下列順序設定 [agent
identity](./agent-identity.md)：

### Machine account

machine account 已經存在，並且已經以 Write 角色被邀請進每個 repository。如果還沒有，或這是第一台機器，
請先做[建立 machine account](./agent-identity.md#creating-the-machine-account)（只有英文）。這個帳號由
所有機器共用；每台機器各有自己的 SSH key。

### Claude Code

在這台機器上執行 `bash ~/.Jarvis/scripts/apply-agent-identity.sh --setup`。它會建立設定檔與
這台機器的 key、顯示要加入的 public key（以 machine account 登入：Settings、SSH and GPG
keys、New SSH key），並印出讓 `gh` 以 machine account 登入的指令。

`--setup` 是互動式的，沒有終端機就拒絕執行，所以請在真正的終端機裡執行，不要用 `!`：

```sh
bash ~/.Jarvis/scripts/apply-agent-identity.sh --setup
```

它會詢問 machine account 的 login 與已驗證的 email（`12345+name@users.noreply.github.com` 的形式）、
私鑰路徑（預設 `~/.ssh/id_ed25519_agent_claude_<hostname>`）、`gh` 設定目錄（預設 `~/.config/gh-agent`，
不可以是你自己的）、agent 工作的 repository（`owner/repo`，以逗號分隔），以及 commit 作者名稱（預設
`Claude Code`）。它會顯示將要建立的設定檔 `~/.Jarvis/config-local/agent-identity`，寫入前先詢問。只有 key
檔不存在時，才會用 `ssh-keygen` 產生 key。

當它印出 public key，把它加到 machine account：以 machine account 的身分登入 GitHub，不是你自己（用
無痕視窗最保險），然後 Settings、SSH and GPG keys、New SSH key
（<https://github.com/settings/ssh/new>）。貼上 key、儲存，再回到腳本按 Enter。

接著腳本會印出讓 `gh` 以 machine account 登入的確切指令，其中的路徑是你自己的 `gh` 設定目錄，不是下面
範例的那個。在另一個終端機執行它，並在瀏覽器裡以 machine account 登入：

```sh
GH_CONFIG_DIR=~/.config/gh-agent gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key --web
```

`--git-protocol ssh` 與 `--skip-ssh-key` 讓 `gh` 不會改寫你自己的 `~/.gitconfig`，也不會上傳 key。回到
腳本再按一次 Enter；它會以完整檢查收尾。之後想檢查幾次都可以：

```sh
bash ~/.Jarvis/scripts/apply-agent-identity.sh --check
```

重複執行 `--check`，直到 `Next:` 那一行是 `Next: run without --check to apply`。每一行都是 `OK`、
`MISSING`、`WRONG`、`WARN` 或 `SKIP`，凡不是 `OK` 的都附一行 `fix:`。這時最後一行是
`apply-agent-identity: all checks passed`，exit 狀態為 0。允許有 `WARN`。

執行 `bash ~/.Jarvis/scripts/apply-agent-identity.sh` 寫入 identity，然後開新的 Claude
Code session。

```sh
bash ~/.Jarvis/scripts/apply-agent-identity.sh
```

檢查：現在 `--check` 印出 `apply-agent-identity: state: applied`。

### Codex

Codex 使用同一個 machine account，加上自己專屬的 SSH key，這把 key 因此可以單獨撤銷。設定檔必須已經存在，
所以先做 Claude Code。`--setup --codex` 會略過 `gh` 登入，因為 Codex 共用它：

```sh
bash ~/.Jarvis/scripts/apply-agent-identity.sh --setup --codex   # 詢問後把 key 附加到設定檔，並產生 Codex 的 key
# 把印出的 .pub 加到 GitHub 上的 machine account
bash ~/.Jarvis/scripts/apply-agent-identity.sh --check --codex
bash ~/.Jarvis/scripts/apply-agent-identity.sh --codex           # 寫入三個檔案
# 然後重新啟動 Codex：執行中的 session 仍用舊的環境
```

`--setup --codex` 在把 `codex_ssh_key` 與 `codex_author_name` 附加到設定檔、並產生 Codex 的 key 之前會先詢問。
把它的 `.pub` 用同樣的方式加到 machine account，同樣要以 machine account 登入。在 Codex 信任 guard hook 之前，
`--check --codex` 會回報 `UNTRUSTED`（見[第 4 步](#4-套用-guard)）。單純的 `--codex` 執行會寫入
`~/.codex/agent-identity.gitconfig`、`~/.codex/config.toml` 裡的一個區塊，以及旁邊的一份紀錄。之後請重新啟動
Codex：執行中的 session 仍用舊的環境。

檢查：`bash ~/.Jarvis/scripts/apply-agent-identity.sh --check --codex` 印出
`apply-agent-identity: state: applied`。

## 6. 選用：打開 agent-identity 開關

Stage 3，選用。

**Person-only：** 決定要不要打開，以及在 Codex 的 `/hooks` 再信任一次 hook。`bootstrap.sh` 不會執行 `--require`。

開關打開時，identity 沒有套用的 runtime 寫入 GitHub，一律被 guard 拒絕，Claude Code 與 Codex 一起。在你打開
之前它都是關的。它的作用見[打開開關](./guard.md#turning-the-switch-on)（只有英文）。請在第 5 步兩個 runtime
都完成、Codex 信任 guard hook、而且兩個 `--check` 都乾淨之後才做：

```sh
bash ~/.Jarvis/scripts/apply-agent-identity.sh --require
```

`--require` 會改變 Codex hook 的指令，所以在你於 Codex 打開 `/hooks` 並再信任一次之前，Codex 會略過 guard。
用 `bash ~/.Jarvis/scripts/apply-codex-guard.sh --trust` 檢查。

要回滾，執行 `bash ~/.Jarvis/scripts/apply-agent-identity.sh --unrequire`。它會把兩邊的開關一起關掉，
而 Codex 同樣需要在 `/hooks` 再信任一次。

## 7. 驗證整台機器

只要執行一個指令：`bash ~/.Jarvis/scripts/doctor.sh`，或 `bash ~/.Jarvis/scripts/bootstrap.sh --check`，兩者印出的內容相同。它會跑下面這些檢查，但不含 `core.hooksPath` 那一列；
它什麼都不修，每項檢查印一行（`ok`、`PROBLEM`、`skipped`、`UNVERIFIED`，檢查本身跑不起來時是 `ERROR`），
有問題的附上修正指令；沒有問題時以 0 離開。
如果你沒做第 5 步（identity 是選用的：沒有 config 檔、沒有開關、也沒有套用紀錄），identity 那行顯示
`skipped` 是正確的；沒有 Codex 時，Codex 那行顯示 `skipped` 也是。identity 那行只有在 `state:` 是 `applied`
時才是 `ok`。`UNVERIFIED` 不會讓它失敗，所以每一條都要讀。`live-callback` 那一行永遠是 `UNVERIFIED`：沒有任何檢查
能證明執行中的 session 會呼叫 hook（見[打開開關](./guard.md#turning-the-switch-on)）。它不會改你的任何檔案，
只有一個例外：identity 檢查的 SSH probe 第一次連線時，可能把 `github.com` 加進 `~/.ssh/known_hosts`。

下面的表一項一項列出這些檢查，想單獨跑某一項時用。「OK」是各項應該顯示的內容，而且每一個都以 0 離開。
最後一欄是該列所屬的 stage；沒做的 stage，它的列就跳過。

| 指令 | OK 的樣子 | Stage |
| --- | --- | --- |
| `~/.Jarvis/sync-personal-skills.sh` | 最後一行以 `checks passed:` 開頭 | 1 |
| `git -C ~/.Jarvis config --get core.hooksPath` | `.githooks` | 1 |
| `bash ~/.Jarvis/scripts/apply-claude-guard.sh --check` | `already carry the guard` | 2 |
| `bash ~/.Jarvis/scripts/apply-codex-guard.sh --check` | `already carry the guard`，接著是 `trust: OK - Codex trusts the Jarvis guard entry` | 2 |
| `bash ~/.Jarvis/scripts/apply-agent-identity.sh --check` | `state: applied`、`Next: nothing — the identity is already applied; a new Claude Code session uses it`、`all checks passed` | 只有 3 |
| `bash ~/.Jarvis/scripts/apply-agent-identity.sh --check --codex` | `state: applied`、`Next: nothing — the identity is already applied; a new Codex session uses it`、`all checks passed` | 只有 3 |

做完第 6 步之後，兩個 identity 檢查也會多出一行 `agent-identity switch` 的 `OK`，Claude Code 與 Codex 都是
`on`。

## 8. 已經踩過的坑

- **`!` 指令是以 agent 的身分執行。** 你在 Claude Code 裡用 `!` 輸入的指令會用 agent identity 執行，Codex 裡的也是
  （已測試的那些變數）。要以你自己的身分操作，例如核准 pull request 或用自己的名字 commit，請用外部終端機。
  驗證過的內容見[真正的執行寫入什麼](./agent-identity.md#what-a-run-writes)與
  [Codex](./agent-identity.md#codex)（只有英文）。
- **做完之後，在瀏覽器裡登出 machine account。** 你為了加入 key 與登入 `gh` 而以它登入過。瀏覽器若仍登入著它，
  你接下來在 GitHub 上做的事就會以 machine account 的身分發生。
- **`--setup` 需要真正的終端機。** 它要讀你的回答，所以在 `!` 之下、或輸入被 pipe 時都會失敗。
- **agent 的 key 不要放在預設路徑**（`~/.ssh/id_ed25519` 之類），也不要載入 `ssh-agent`，否則一般的 `ssh` 也會送出它
  （見[已知限制](./agent-identity.md#known-limits)）。
- **每次變動之後重新啟動。** identity 套用之後開新的 Claude Code session，`--codex` 之後重新啟動 Codex，
  `--require` 或 `--unrequire` 之後在 `/hooks` 再信任一次 Codex hook。
