# 讓機器保持最新

[English](./keep-machine-current.md) · **繁體中文**

> **中文摘要**：Jarvis 更新之後，讓每一台已經導入的機器跟上最新狀態。先找出符合你狀況的情境，再照該情境的步驟做，每一步都附有檢查方式。
>
> guard 是複製進去的，不是 symlink，所以每次更新都要重跑 apply 腳本。Codex 只在 hook 定義改變時才需要重新信任。這台機器的身分設定檔 `config-local` 不會被更新動到。

這份文件適用於已經完成[新機器設定](./setup-new-machine.zh-TW.md)的機器。先找出符合你狀況的情境，再照它的步驟做。每個指令都在一般的終端機執行，不要在 Claude Code 或 Codex 裡用 `!` 執行。

Jarvis 安裝的東西分成兩類。個人規則和每個 Skill 都是連結，`~/.Jarvis` 更新後就會跟著更新。Claude Code 和 Codex 的 guard 則是複製進去的，要重跑它的腳本才會更新。agent 身分的設定檔 `~/.Jarvis/config-local/agent-identity` 屬於這台機器，任何更新都不會動到它。

## 你是哪一種情境？

| 情境 | 前往 |
| --- | --- |
| Jarvis 的 `main` 有新變動：merge 了 pull request，或發了新的 release | [A. 例行更新](#a-例行更新) |
| release 說明裡寫了這台機器要做的步驟 | [B. release 要求額外步驟](#b-release-要求額外步驟) |
| 更新之後 `--check` 或 `--trust` 回報問題 | [C. 更新後檢查失敗](#c-更新後檢查失敗) |
| 新增或移除了 Skill | [D. 新增或移除 Skill](#d-新增或移除-skill) |
| 不確定這台機器是不是最新的 | [E. 這台機器是最新的嗎？](#e-這台機器是最新的嗎) |

## A. 例行更新

Jarvis 的 `main` 有變動後，每台機器都做一次。每一步重複執行都沒關係。

1. 更新 clone：

   ```sh
   git -C ~/.Jarvis switch main
   git -C ~/.Jarvis pull --ff-only
   ```

   檢查：`git -C ~/.Jarvis status -sb` 顯示 `## main...origin/main`，沒有 ahead 也沒有 behind。如果 `pull --ff-only` 拒絕執行，代表這個 clone 有本機的 commit 或修改，請先看過它們再繼續。
2. 重跑 bridge：

   ```sh
   ~/.Jarvis/sync-personal-skills.sh
   ```

   檢查：最後一行以 `checks passed:` 開頭。
3. 重跑兩個 guard 腳本。它們會把目前的 guard 複製進去，agent-identity 開關維持原狀：

   ```sh
   bash ~/.Jarvis/scripts/apply-claude-guard.sh
   bash ~/.Jarvis/scripts/apply-codex-guard.sh
   ```

   檢查：Codex 那次的最後一行是 `trust: OK - Codex trusts the Jarvis guard entry …`。如果顯示 `UNTRUSTED` 或 `DISABLED`，代表 hook 的定義變了，請前往 [C](#c-更新後檢查失敗)。
4. 檢查兩個 runtime 的 agent 身分：

   ```sh
   bash ~/.Jarvis/scripts/apply-agent-identity.sh --check
   bash ~/.Jarvis/scripts/apply-agent-identity.sh --check --codex
   ```

   檢查：兩個都顯示 `state: applied`。如果開關是打開的，兩個也都會顯示 `agent-identity switch: Claude Code on, Codex on`。
5. 開一個新的 Claude Code session，並重新啟動 Codex，讓兩邊都載入新的 guard。
6. 看這次改了什麼。打開 [`CHANGELOG.md`](../CHANGELOG.md)（它連到每個大版號的檔案），讀完比這台機器原本版本更新的每一則條目。如果有條目寫了這台機器要做的事，請前往 [B](#b-release-要求額外步驟)。

## B. release 要求額外步驟

[`CHANGELOG.md`](../CHANGELOG.md) 裡每一則 MINOR 或 MAJOR 條目的最後，都會寫 owner 在這台機器上要做什麼。先做 [A](#a-例行更新) 的第 1 到 4 步，再依 release 的順序、從最舊的開始，做那則條目自己的步驟。常見的有：

- **重跑 apply 腳本。** A 已經包含這一步。
- **到 `/hooks` 重新信任 Codex hook。** 只有 hook 的定義改變時才需要。`bash ~/.Jarvis/scripts/apply-codex-guard.sh --trust` 會告訴你它有沒有改變。
- **打開某個功能**，例如 `--require`。請照條目連到的文件做，例如[打開開關](./guard.md#turning-the-switch-on)。

檢查：再跑一次 A 的第 3、4 步，每項檢查都沒有問題。

## C. 更新後檢查失敗

| 你看到的 | 該怎麼做 |
| --- | --- |
| `apply-codex-guard.sh` 顯示 `trust: UNTRUSTED` 或 `DISABLED` | 打開 Codex，執行 `/hooks`，選 **Codex guard: checking the command**，把它設為信任；如果是 `DISABLED`，就把它啟用。之後 `bash ~/.Jarvis/scripts/apply-codex-guard.sh --trust` 會顯示 `trust: OK`。在這之前，Codex 會跳過這個 guard。 |
| `apply-agent-identity.sh --check` 顯示 `MISSING`、`WRONG` 或 `CONFLICT` | 照它的 `fix:` 那一行做，再照它的 `Next:` 那一行做，然後重跑 `--check`。細節在 [Agent identity](./agent-identity.md)。 |
| 顯示 `state: ready`，不是 `applied` | 身分需要重新寫入，例如加了新的 key 之後。執行 `bash ~/.Jarvis/scripts/apply-agent-identity.sh`，或加上 `--codex` 再跑一次。 |
| `sync-personal-skills.sh` 以非零結束 | 看它印出的訊息。[Maintenance](./maintenance.md) 有復原步驟，例如 [Recover a `~/.agents` conflict](./maintenance.md#recover-a-agents-conflict)。 |
| 更新後 guard 擋下所有 GitHub 寫入 | 開關是打開的，但這個 runtime 的身分沒有套用。照上面檢查的輸出修好身分設定。修好之前要先關掉開關的話，執行 `bash ~/.Jarvis/scripts/apply-agent-identity.sh --unrequire`。 |

## D. 新增或移除 Skill

Skill 是連結，所以只改了 Skill 本身的內容時，`git pull` 就會帶到每台機器。新增或移除 Skill 會改變連結的集合，所以要做 [A](#a-例行更新) 的第 1、2 步：先 `git pull --ff-only`，再跑 `sync-personal-skills.sh`。然後開一個新的 session，讓 runtime 看到新的那一組 Skill。

檢查：bridge 印出 `checks passed:`。新的 Skill 出現在 `~/.claude/skills/<名稱>`；有安裝 Codex 的話，也出現在 `~/.codex/skills/<名稱>`。移除的 Skill 兩邊都不見了。

## E. 這台機器是最新的嗎？

```sh
git -C ~/.Jarvis fetch -q && git -C ~/.Jarvis status -sb | head -1
git -C ~/.Jarvis describe --tags --abbrev=0
bash ~/.Jarvis/scripts/apply-claude-guard.sh --check
bash ~/.Jarvis/scripts/apply-codex-guard.sh --check
```

四項都成立，這台機器就是最新的：

- 第一行沒有 `behind`；
- tag 是 [Releases](https://github.com/ShenYo/Jarvis/releases) 上最新的那一個；
- 兩個 `--check` 都以 0 結束。

否則請做 [A](#a-例行更新)。
