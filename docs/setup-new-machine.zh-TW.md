# 在新機器上設定

[English](./setup-new-machine.md) · **繁體中文**

> **中文摘要**：這份指南帶你在一台全新的機器上依序完成 Jarvis：安裝前置工具、clone 到
> `~/.Jarvis` 並啟用 Git hooks、執行 bridge、套用 Claude Code 與 Codex 的 guard、設定 agent
> identity（Claude Code 與 Codex 各一次），可選擇打開 `--require` 開關，最後逐項驗證。clone 與
> bridge 本身不安裝 runtime、不建立憑證，也不讓新專案依賴 Jarvis；憑證只出現在 agent identity 那幾步。

在一台從沒裝過 Jarvis 的機器上，從頭照著做。每一步結尾都有檢查，確認成功了再往下。
所有指令都在一般的終端機裡執行，不要在 Claude Code 或 Codex 裡用 `!`（見
[已經踩過的坑](#8-已經踩過的坑)）。每個部分的參考資料在
[Architecture](./architecture.md)、[Guard](./guard.md) 與
[Agent identity](./agent-identity.md)（這三份只有英文）。

## 1. 前置條件

前置條件是 Git、Bash，以及對設定好的 Jarvis remote 的存取權。只有在
`~/.Jarvis` 還不存在時才選擇這個 canonical destination；絕對不要在既有的
checkout 上面再 clone 一次。既有的 checkout 應該在它自己的 Git history 下
檢查與調解。

clone 與 bridge 不需要更多東西。這份指南其餘的部分需要，所以開始之前請全部裝好：

- `git`：用來 clone，也用來執行這個 repository 的 hooks。
- `gh`：GitHub CLI，用來以 machine account 登入。
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

每一行都應該以 `ok` 開頭。

## 2. Clone Jarvis

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

## 3. 建立 Skills 的 bridge

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
不存在時建立，懸空時替換。在兩種情況下它會拒絕，而且什麼都不改：一是
`~/.claude/CLAUDE.md` 是一個真正的檔案，因為那裡有人寫好的指示；二是它是一個指向
別處、仍然有效的 link，因為那是刻意的設定。若要在已經有 `~/.claude/CLAUDE.md` 的
機器上採用這個 link，先把要保留的內容搬進 `.agents/AGENTS.md`，移除原檔，再重跑
腳本。

安裝了 Codex 時，`${CODEX_HOME:-$HOME/.codex}/AGENTS.md` 也會得到同樣的 link 與同樣
的拒絕規則，所以兩個工具讀的是同一份檔案，沒有需要同步的副本。Codex 的 home 裡若有
非空的 `AGENTS.override.md`，Codex 會改讀它而不讀 `AGENTS.md`，所以只要它存在，腳本
就會失敗。

這支腳本會在 `~/.agents` 不存在時建立它、確保 Claude bridge 目錄存在，並且只
在某個 canonical-name entry 缺失或 dangling 時才建立或替換它。當
`${CODEX_HOME:-$HOME/.codex}` 存在時它會對 Codex 做 bridge，並在需要時建立其下的
`skills/`，因為全新安裝的 Codex 有 home 但還沒有該子目錄
（[歷史](./history.md#codex-bridge-decided-by-its-home)）。不存在的 Codex home 會被跳過，而不是視為
錯誤。它會檢查每個 canonical skill，在每個
已 bridge 的工具裡，是否都有一個以其宣告名稱存在的 entry，回報 dangling 的
non-reserved entries，並拒絕一個既不是 Skill、也不是 grouping directory 的
top-level canonical 目錄。一個指向錯誤目標、但本身仍是 live 的
canonical-name entry 會被保留不動，也不會被偵測出來。這些檢查任一失敗，它就會
以非零狀態結束。每次新增或移除一個 skill 之後，請重新執行它。

## 4. 套用 guard

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

## 5. 設定 agent identity

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

逐一執行下列指令；「OK」是它應該顯示的內容，而且每一個都以 0 離開。

| 指令 | OK 的樣子 |
| --- | --- |
| `~/.Jarvis/sync-personal-skills.sh` | 最後一行以 `checks passed:` 開頭 |
| `git -C ~/.Jarvis config --get core.hooksPath` | `.githooks` |
| `bash ~/.Jarvis/scripts/apply-claude-guard.sh --check` | `already carry the guard` |
| `bash ~/.Jarvis/scripts/apply-codex-guard.sh --check` | `already carry the guard`，接著是 `trust: OK - Codex trusts the Jarvis guard entry` |
| `bash ~/.Jarvis/scripts/apply-agent-identity.sh --check` | `state: applied`、`Next: nothing — the identity is already applied; a new Claude Code session uses it`、`all checks passed` |
| `bash ~/.Jarvis/scripts/apply-agent-identity.sh --check --codex` | `state: applied`、`Next: nothing — the identity is already applied; a new Codex session uses it`、`all checks passed` |

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
