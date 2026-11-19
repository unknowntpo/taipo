# Spec 025: 在公開 repo 開發（open development）

Status: Accepted（2026-11-18，決定見「決定」一節）
Date: 2026-11-13
Traceability: pending（實作時改為 enforced；spec-only 時 check-traceability 才會通過）
Builds on: Spec 011（評測語料與 `taipo-asr`）、Spec 019（私有 → 公開同步、leak gate）、`docs/process/workflow.md`（角色、Gates、Core decision、merge 權限）

## Intent

使用者希望台灣在開源世界有一席之地，所以 Taipo 改為公開開發。公開 repo `unknowntpo/taipo`（Apache-2.0）成為主線：之後所有 PR、issue 與 CI 都在公開 repo 進行。私有 repo `unknowntpo/taipo-private` 只保存私有資料（`private/`：評測語料、私人比對清單）。

切換之後必須仍然成立：

- 私有 repo 的 git 歷史一定不會進入公開 repo。公開歷史從公開 repo 自己的歷史接續。
- 使用者的自架 runner `macbook` 一定不會接到公開 repo。
- 使用者的錄音與私有評測資料一定不會進入公開 repo；需要它們的評測仍在本機對公開 checkout 執行。
- Leak gate（Spec 019 的掃描）繼續保護公開 repo。
- 任何地方都不記錄使用者打的字或錄音。

README、CONTRIBUTING、安全回報、issue 與 PR 範本說明怎麼參與。目前沒有外部協作者：所有 PR 由擁有者或擁有者的 agent merge（決定 D6）。核心決定仍由 human 做。

## Evidence

- 私有 main（c4b4ad1）有 90 個 commit。依 Spec 019 的 Example，私有歷史中有 6 個檔案含私有語料原句；90 個 commit 的作者 email 全部是擁有者的私人 email（只列數量，不寫內容）。所以私有歷史不能公開，也不能用 filter 清理後公開（Spec 019 Non-goals）。
- 公開 repo 目前只靠 Spec 019 的同步取得程式碼。公開 repo 上的 PR 要在私有 repo 用 `git am` 移植再同步回來（Spec 019 Behavior 8）。所以公開 PR 無法直接 merge，開發過程也不公開。
- 公開 CI 已在 GitHub-hosted `macos-26` 上通過完整的 `core` job（見 Example），所以 build、單元測試、traceability、test plan、budget 都不需要 `macbook`。
- 2026-11-12 公開 CI 第一次失敗（run 43137856331）：G19 在沒有 `private/` 的公開 checkout 上失敗。隔天由私有 PR #30 修正（測試在執行時產生 fixture）。這證明 leak gate 在公開 checkout 上必須有明確的「沒有私有資料」模式，而不是依賴檔案是否存在。
- 輸入法能看到使用者所有的按鍵。Workflow、leak gate、相依套件，或碰到網路、log、錄音的變更出錯，後果比一般 app 嚴重，所以這些變更列為 core decision（Behavior 13）。

## Example

擷取時間 2026-11-13，來源：`git`、`gh api`、`gh run view`（唯讀查詢）。

### 現況

| 項目 | 私有 `unknowntpo/taipo-private` | 公開 `unknowntpo/taipo` |
| --- | --- | --- |
| main HEAD | c4b4ad1（Merge PR #30） | ba689b5（`Sync from private main`，`Synced-From: c4b4ad1…`） |
| Root commit | 5b89bda | 9de17d6 |
| 公開歷史 | — | 9de17d6 → 26cc003 → 2debe2a → c26690b → ba689b5（5 個 commit，2 個是同步 commit） |
| 檔案數 | 公開 tree 加上 `private/`、`.public-exclude`、`.github/workflows/public-sync.yml` | 122 |
| Open PR（2026-11-18 擷取） | 15 個（不含本 PR #34）：#13、#19、#20、#22、#25、#26、#27、#28、#29、#31、#32、#33、#35、#36、#37 | 0；issue 0 |
| CI runner | `macbook`（self-hosted, macOS, ARM64，online）；只註冊在私有 repo | 0 個 self-hosted runner；`core` 跑在 `macos-26` |
| 最近一次 `core` | run 43338500333，`macbook`，7 分 08 秒，success | run 43142538303，`macos-26`，13 分 42 秒，success |
| `public-sync-dry-run` | ubuntu，6 秒，success | job 有 `if: github.repository == 'unknowntpo/taipo-private'`，公開 repo 上 skipped |
| 同步設定 | variable `PUBLIC_SYNC_ENABLED=true`；environment `public-sync` | deploy key `taipo-public-sync`（寫入） |
| Branch protection（main） | — | 沒有（`Branch not protected`） |
| Fork PR 的 workflow 核准 | — | `all_external_contributors`（每位外部貢獻者都需要核准） |
| Private vulnerability reporting | — | `enabled: false` |
| Community profile | — | 42%；已有 `license`、`readme`；缺 CONTRIBUTING、CODE_OF_CONDUCT、issue 範本、PR 範本 |

### 公開 `core` job 的步驟（run 43142538303）

| 步驟 | 結果 | 需要什麼 |
| --- | --- | --- |
| `swift test` | success（153 個測試） | Xcode 26（Swift 6.2）；SwiftPM 下載 `mlx-swift-lm` 3.32.3 與 whisper.cpp b5454 XCFramework |
| `taipo-dev check-traceability` | success | 只有 Swift |
| `taipo-dev render-test-plan --check` | success | 只有 Swift |
| `taipo-bench`（M1–M3） | success | release build；不需要模型權重 |
| Build input method bundle（`xcodebuild -downloadComponent MetalToolchain` + `scripts/install-ime.sh --build`） | skipped（只在 `workflow_dispatch` 執行；私有與公開都還沒在 CI 上跑過） | Metal toolchain、編譯 MLX 的 Metal shader（約 10 分鐘） |

### 切換後的預期結果

| 事情 | 切換前 | 切換後 |
| --- | --- | --- |
| 開 PR、issue | 私有 repo | 公開 repo |
| 主要的本機 clone | `~/repo/unknowntpo/taipo`（私有） | `~/repo/unknowntpo/taipo-public`（公開）；worktree 從這裡建立 |
| 私有資料 | 私有 repo 的 `private/` | 同一個私有 clone 的 `private/`；本機以 `TAIPO_PRIVATE_DIR=~/repo/unknowntpo/taipo/private` 指向它 |
| CI | `macbook` | GitHub-hosted `macos-26`（`core`）與 `ubuntu-latest`（`leak-gate`） |
| Leak gate 的私有規則（私有語料、私人身分） | 私有 CI 的 `public-sync-dry-run` | 擁有者本機的 pre-push hook（阻擋）＋私有 repo 每日的 `public-watch`（偵測） |
| Leak gate 的公開規則（路徑、音檔、家目錄、金鑰…） | 同上 | 公開 CI 的 `leak-gate` job，每個 PR 都跑 |
| Spec 019 同步 | 私有 main 每次 merge 後推到公開 | 停用並移除 |

ASR 評測在切換後的實際指令（在公開 checkout 執行；錄音仍在 repo 外的 `~/Library/Application Support/Taipo/asr-eval`）：

```
swift run -c release taipo-asr score --sentences "$TAIPO_PRIVATE_DIR/asr-eval/sentences.tsv"
```

擁有者 push 時，pre-push hook 的輸出（成功時；失敗時只有 `路徑:行號 規則名稱`，與 Spec 019 相同）：

```
leak-check: rules full, 3 commits, 124 files
gate: ok
```

## Behavior

1. **切換前提**：以下全部成立，使用者才執行一次性切換（見「一次性切換」）。
   - 每個 open 的私有 PR 都已在私有 repo merge 或關閉（決定 D1；2026-11-18 為 Example 列出的 15 個，加上本 PR #34）。Merge 的內容已由 Spec 019 同步到公開 repo。`gh pr list -R unknowntpo/taipo-private --state open` 為空。
   - 本 PR 以外只含 spec 的 PR 關閉。若還要做，切換後在公開 repo 開新 PR（內容須通過 `--rules full`）。
   - #13（Spec 011 真人錄音結果）關閉。需要保存的內容放進私有 repo 的 `private/asr-eval/`。
   - 私有 PR 一律不移植到公開 repo。
   - 本 spec 的實作切片 1（Behavior 3–7、11 的檔案）已在私有 main merge 並同步。
   - `scripts/public-sync.sh --dry-run --public https://github.com/unknowntpo/taipo.git` 印出 `already in sync`，且公開 main 的 `core` 是 success。
2. **公開歷史只接續公開 repo**：公開 main 從 ba689b5（或切換時最後一個同步 commit）往下長。私有歷史一定不會被 push 或 merge 進公開 repo。
   - Gate 新規則 `private-history`：待檢查的 commit 範圍中，任一 commit 的祖先包含私有 root commit 5b89bda，就失敗。SHA 本身不透露內容，可以寫在公開 repo（`scripts/private-roots.txt`）。
   - 不在公開 clone 加私有 repo 的 remote。
3. **Leak gate 分兩種規則組**。`scripts/leak-check.sh` 是唯一入口，必須明確指定 `--rules public` 或 `--rules full`；沒指定就 exit 2，不猜。
   - `public`（不需要私有資料）：Spec 019 規則 5.1（`excluded-path`，固定為 `private/`）、5.3（`media`）、5.4（`home-path`）、5.6（`secret`）、`symlink`，加上本 spec 的 `private-history`、`self-hosted`、`workflow-secret`。Commit message 跑 `home-path`、`secret`。
   - `full`：`public` 全部，加上 `private-sentence`、`private-fragment`（N=10、K=2，同 Spec 019）、`private-identity`。私有資料從 `--private-dir`（預設 `$TAIPO_PRIVATE_DIR`）讀 `asr-eval/sentences.tsv` 與 `leak-patterns.txt`；任一不存在或為空就失敗（fail closed，同 Spec 019 Behavior 6）。
   - Commit 作者：不要求每個 commit 都是擁有者的 noreply。理由：leak gate 已擋下擁有者的私人 email，所以其他 commit email 都允許。`full` 模式下，author 或 committer email 出現在 `leak-patterns.txt` 就算 `private-identity` 失敗。
   - 掃描範圍：`--tree <rev|worktree>` 的檔案（預設 `HEAD`）、`--range <base>..<head>` 的 commit metadata（預設 `origin/main..HEAD`）、`--text <file>`（只掃這個檔案，給 PR 描述與留言用）。
   - 輸出規則不變：只輸出 `路徑:行號 規則名稱`，外洩的路徑用代稱（Spec 019 Behavior 5），最後一行 `gate: ok` 或 `gate: failed (<命中數>)`；第一行列出規則組、commit 數、檔案數。絕不印出命中的內容。
4. **Workflow 規則**：`self-hosted`：`.github/workflows/` 下任何非註解行出現 `self-hosted` 就失敗。`workflow-secret`：任何 workflow 使用 `pull_request_target`，或引用 `secrets.`（`secrets.GITHUB_TOKEN` 除外），就失敗。公開 repo 的 workflow 不需要任何 secret。
5. **本機 pre-push hook**：`scripts/git-hooks/pre-push`，以 `git config core.hooksPath scripts/git-hooks` 啟用（擁有者的公開 clone 執行一次；同一個 clone 的 worktree 共用）。
   - 對每個要 push 的 ref 跑 `leak-check.sh --rules full --range <remote 上的舊 SHA>..<新 SHA> --tree <新 SHA>`。新分支的範圍起點是 `origin/main`。刪除 ref 不檢查。
   - `TAIPO_PRIVATE_DIR` 未設定、或目錄裡缺檔案：拒絕 push，訊息說明要設定的變數（fail closed）。
   - Agent 一律不用 `git push --no-verify`（寫進 `docs/process/workflow.md`）。
6. **Agent 發到 GitHub 的文字**：擁有者的 agent 在公開 repo 發 PR 描述、issue、留言之前，先把文字寫進暫存檔，跑 `scripts/leak-check.sh --rules full --text <file>`，通過才用 `--body-file` 發出。評測結果只貼總數與句子 ID，不貼句子原文。
7. **私有評測在本機執行**：需要私有資料的評測（Spec 011 ASR 評測、`taipo-asr score` 的 worst sentences）在公開 checkout 執行，語料用 `--sentences "$TAIPO_PRIVATE_DIR/asr-eval/sentences.tsv"`。錄音與結果留在 `~/Library/Application Support/Taipo/asr-eval`（repo 外）。不在公開 repo 加任何指向私有資料的預設路徑；`taipo-asr` 的預設值（`<dir>/sentences.tsv`）不變。
8. **公開 CI**（`.github/workflows/ci.yml`，切換後的第一個公開 PR 修改）：
   - `core`：`runs-on: macos-26`（字面值，移除依 `github.repository` 選 runner 的運算式），步驟不變。
   - `leak-gate`：`runs-on: ubuntu-latest`，`fetch-depth: 0`，跑 `scripts/leak-check.sh --rules public --range origin/main..HEAD`（push 到 main 時範圍是 `<before>..<after>`）。
   - 移除 `public-sync-dry-run` job。
   - 觸發：`pull_request`、`push: branches: [main]`、`workflow_dispatch`。`permissions: contents: read`。Bundle build 步驟維持只在 `workflow_dispatch` 執行：切換時跑一次（K8），之後每次發佈前跑一次（決定 D10）。
   - 公開 repo 一律不使用 `macbook`（決定 D3）。
9. **私有 repo 的偵測**：私有 repo 新增 `.github/workflows/public-watch.yml`，`runs-on: ubuntu-latest`，每天一次（`schedule`）加 `workflow_dispatch`，不用 `macbook`。
   - Checkout 私有 repo（取得 `private/`）與公開 repo main（取得 `scripts/`）。執行公開 checkout 裡的 `scripts/public-watch.sh --private-dir private`。
   - `public-watch.sh` 對公開 main 跑 `leak-check.sh --rules full`，範圍是公開 main 的全部歷史；再把公開 repo 所有 PR 與 issue 的標題、內文、留言（用 `GITHUB_TOKEN` 讀公開資料）各存成暫存檔，逐一跑 `--text`。
   - PR 與 issue 文字一定要掃描（決定 D7）。這是唯一覆蓋 GitHub 網頁上文字的檢查。
   - 命中就讓 job 失敗（GitHub 會通知擁有者）。Job summary 只寫每條規則的命中數與 `路徑:行號 規則名稱`，不寫內容。
   - 這是偵測，不是阻擋。阻擋靠 Behavior 5、6；偵測補上 GitHub 網頁上的編輯、squash merge 的 message、其他機器的 push。
10. **Spec 019 退役**：切換時停用同步，之後移除同步的程式。
    - 切換當下（一次性切換第 1 步）：`PUBLIC_SYNC_ENABLED` 改為 `false`，之後不再同步。
    - 公開 repo 的退役 PR：刪除 `scripts/public-sync.sh` 與只測同步的測試（G2、G3、G4、G17、G18、G21、G25，以及 G1 中測產生器的 case）。保留 gate 測試（G8–G16、G19、G22–G24），改成呼叫 `leak-check.sh`。
    - Spec 019 的 Status 改為 `Retired（2026-MM-DD，由 Spec 025 取代）`。已刪除測試的 ID 從 `## Acceptance` 移到新的 `## Retired acceptance` 一節，讓 check-traceability 不再要求它們。
    - 私有 repo 的 `.github/workflows/public-sync.yml`、`.public-exclude` 隨 Behavior 11 一起移除。
11. **私有 repo 只留資料**：最後一個私有 PR 讓私有 main 只剩 `private/`、`README.md`（說明這個 repo 只存私有資料、主線在公開 repo、如何設定 `TAIPO_PRIVATE_DIR`）與 `.github/workflows/public-watch.yml`。私有歷史保持原狀，不改寫、不公開。之後新增評測語料直接 commit 到私有 main。
12. **貢獻者文件**（公開 repo，切換後的公開 PR）：
    - `README.md`：繁體中文在前；新增 `## English` 一節（功能、安裝、開發指令、如何貢獻、授權）。
    - `CONTRIBUTING.md`（繁體中文在前，英文摘要在後）：新行為先開 issue；新意圖先送 spec PR（`docs/specs/_template/spec.md`），被接受後才實作；測試名稱含 acceptance ID；送 PR 前跑 README 的 gates；可以使用 AI 工具，但貢獻者要理解並負責每一行；issue、PR、測試裡只用編造的句子，不貼真實打字內容、不附錄音；issue、PR、spec 可用繁體中文或英文（決定 D8）；不需要 DCO 或 CLA（Apache-2.0 第 5 條，決定 D4）。
    - `SECURITY.md`：用 GitHub private vulnerability reporting 回報。範圍明確包含：把打字內容或音訊送出本機、寫進 log 或磁碟、輸入法權限被濫用。只支援 `main`。
    - `.github/ISSUE_TEMPLATE/bug.yml`（macOS 版本、Taipo commit、用編造文字寫的重現步驟；說明不要附錄音，log 只用 README 的 `log stream` 指令且貼上前先確認沒有打字內容）、`feature.yml`（問題、例子）、`config.yml`（安全問題連到 SECURITY.md）。
    - `.github/pull_request_template.md`：意圖或 spec 連結、acceptance ID、gates 結果、兩個勾選項（沒有真實打字內容或錄音；我理解每一行變更）。
    - 不記錄打字內容與音訊的規則寫進 CONTRIBUTING 與 SECURITY。公開 CI 的 `media` 規則讓音檔與權重無法進入公開 repo。
13. **Merge 權限**（更新 `docs/process/workflow.md`）：
    - 目前沒有外部協作者（決定 D6）。所有 PR 都由擁有者或擁有者的 agent merge，沿用現行規則：已接受 spec 的實作、測試、工具、重構，gates 綠＋verifier 通過可自行 merge，事後一行回報。
    - Core decision 增加：`.github/workflows/`、`scripts/leak-check.sh`、`scripts/public_leak_gate.py`、`scripts/git-hooks/`、`scripts/private-roots.txt`、CONTRIBUTING、SECURITY 的修改；新增或升級相依套件；任何碰到網路、log、錄音的變更。這些依 `docs/process/workflow.md` 先與 human 對齊；對齊之後，擁有者或擁有者的 agent 可以 merge。
14. **Branch protection 與 repo 設定**（使用者在一次性切換時設定，本 spec 不改任何設定）：公開 `main` 必須經過 PR；必須通過 `core` 與 `leak-gate`；不允許 force push 與刪除；管理員也不能略過。必要 approval 數為 0（只有一位維護者，無法 approve 自己的 PR）。Fork PR 的 workflow 要先經核准才執行，這個設定維持現狀 `all_external_contributors`（比只核准首次貢獻者更嚴；輸入法能看到每一個按鍵）。只開放 squash merge，merge 後自動刪除分支（決定 D9）。

### 一次性切換（Behavior 1 成立後，由使用者執行）

1. 停用同步：`gh variable set PUBLIC_SYNC_ENABLED --repo unknowntpo/taipo-private --body false`。
2. 移除公開 repo 的 deploy key `taipo-public-sync`（`gh repo deploy-key list --repo unknowntpo/taipo` 取得 ID，再 `gh repo deploy-key delete <id> --repo unknowntpo/taipo`）；刪除私有 repo 的 environment `public-sync`（含 secret `PUBLIC_DEPLOY_KEY`）。
3. 確認公開 repo 沒有 self-hosted runner：`gh api repos/unknowntpo/taipo/actions/runners -q .total_count` 為 `0`。`macbook` 不做任何變更（決定 D3）。
4. 開啟公開 repo 的 private vulnerability reporting：`gh api -X PUT repos/unknowntpo/taipo/private-vulnerability-reporting`。
5. 設定 Behavior 14 的 branch protection（在 `leak-gate` job 第一次執行之後，才能把它選為必要檢查）。設定 merge 方式：`gh repo edit unknowntpo/taipo --enable-squash-merge --enable-merge-commit=false --enable-rebase-merge=false --delete-branch-on-merge`。
6. 在 GitHub 帳號的 email 設定開啟「Block command line pushes that expose my email」。
7. 擁有者的公開 clone：`git -C ~/repo/unknowntpo/taipo-public config core.hooksPath scripts/git-hooks`；在 shell 設定 `TAIPO_PRIVATE_DIR=~/repo/unknowntpo/taipo/private`。
8. 私有 clone 的舊 worktree（`~/repo/unknowntpo/taipo-0NN`）在 PR 都處理完後移到垃圾桶；之後的 worktree 從公開 clone 建立。

### 遷移順序

1. 本 spec 被接受並 merge（私有 repo，PR #34）。
2. 實作切片 1（私有 repo，一般 PR，由 Spec 019 同步到公開）：`scripts/leak-check.sh`、gate 的規則組與新規則、`scripts/private-roots.txt`、`scripts/git-hooks/pre-push`、`scripts/public-watch.sh` 與測試。這時私有 ci.yml 不動（還在用 `macbook`）。
3. 等待 Behavior 1 的前提成立。
4. 使用者執行「一次性切換」第 1–4、6–7 步。
5. 公開 repo 的第一個 PR：ci.yml（Behavior 8）與 `docs/process/workflow.md`（Behavior 5、6、13）。這是 core decision：先與 human 對齊，之後由擁有者或擁有者的 agent merge。之後執行第 5 步 branch protection。
6. 公開 repo：貢獻者文件 PR（Behavior 12），Spec 019 退役 PR（Behavior 10）。
7. 私有 repo：只留資料的 PR（Behavior 11）。之後執行第 8 步。

## Acceptance

### Behavior
- K1：具名測試：只含公開檔案的 fixture repo，`leak-check.sh --rules public` 通過，第一行是 `leak-check: rules public`，最後一行 `gate: ok`；不需要任何私有資料檔。
- K2：具名測試：同一個 fixture 加上 fixture 私有資料目錄，`--rules full` 通過，第一行是 `leak-check: rules full`。
- K3：具名測試：啟用 hook、`TAIPO_PRIVATE_DIR` 指向 fixture 私有資料目錄，push 不含私有內容的 commit 到 fixture bare remote → 成功，remote ref 前進。刪除 ref 的 push 不跑 gate。
- K4：具名測試（G19 的後繼）：本 repo 自己的 tree 與 `origin/main..HEAD` 用 `--rules public` 通過；設定 `TAIPO_PRIVATE_DIR` 時另外用 `--rules full` 通過。
- K5：具名測試：本 repo 的 `.github/workflows/ci.yml` 中 `core` 的 `runs-on` 是 `macos-26`、`leak-gate` 是 `ubuntu-latest`；沒有 `public-sync-dry-run`；`permissions` 是 `contents: read`。（切換後的第一個公開 PR 才成立，所以這個測試隨該 PR 加入。）
- K6：具名測試：`--text <file>` 只掃描該檔案；不相關的文字通過。
- K7：[deploy] 切換後第一個公開 PR 的 `core` 在 `macos-26`、`leak-gate` 在 `ubuntu-latest` 執行並通過；`gh api repos/unknowntpo/taipo/actions/runners -q .total_count` 為 `0`。
- K8：[deploy] 在公開 repo 以 `workflow_dispatch` 執行 ci.yml 一次，bundle build（Metal toolchain 下載、`scripts/install-ime.sh --build`）在 `macos-26` 通過。若失敗，記錄原因，bundle build 列為只能在本機執行的檢查。
- K9：[manual] 擁有者在公開 checkout 執行 Example 的 `taipo-asr score` 指令並得到分數；之後 `git status --porcelain` 為空（沒有新檔案進入公開 checkout）。
- K10：[deploy] 私有 repo 的 `public-watch` 第一次 `workflow_dispatch` 通過，summary 列出每條規則的命中數（全為 0）、掃描的 commit 數、PR 與 issue 文字數。
- K11：[measure] 貢獻者文件 PR merge 後，`gh api repos/unknowntpo/taipo/community/profile` 的 `files.contributing`、`files.issue_template`、`files.pull_request_template` 都不是 null。`files.code_of_conduct` 維持 null（決定 D5）。
- K12：[manual] 遷移完成後：`gh pr list -R unknowntpo/taipo-private --state open` 為空；私有 main 只有 `private/`、`README.md`、`.github/workflows/public-watch.yml`；公開 main 的 root commit 仍是 9de17d6。

### Failure and retry
- K13：具名測試：`--rules public` 對 `private/x.tsv`、`.wav` 檔、家目錄路徑、執行時拼出的假金鑰各自失敗，輸出 `路徑:行號 規則名稱`。正向對照：同一 fixture 移除該檔通過。
- K14：具名測試：`--rules full` 時私有資料目錄不存在、`sentences.tsv` 為空、`leak-patterns.txt` 不存在 → 各自失敗（exit 不為 0），訊息說明缺少哪個檔案；不會自動降為 `public`。
- K15：具名測試：沒有 `--rules`、或值不是 `public`/`full` → exit 2，什麼都不掃描。
- K16：具名測試：fixture 的 `private-roots.txt` 列出 fixture 私有 root SHA；範圍中有 commit 以它為祖先 → `commit:0 private-history`。正向對照：無關的歷史通過。
- K17：具名測試：workflow 檔 `runs-on: [self-hosted, macOS]`、或運算式中含 `self-hosted` → `self-hosted` 失敗。邊界：只有註解行提到 `self-hosted` → 通過。
- K18：具名測試：workflow 使用 `pull_request_target`、或引用 `secrets.PUBLIC_DEPLOY_KEY` → `workflow-secret` 失敗。邊界：只引用 `secrets.GITHUB_TOKEN` → 通過。
- K19：具名測試：commit 內容含 fixture 私有句時 push → hook 拒絕，remote refs 不變，stdout 與 stderr 都不含該句子（「不出現」斷言）。正向對照：同一路徑換成不相關句子 → push 成功。
- K20：具名測試：啟用 hook 但未設 `TAIPO_PRIVATE_DIR` → 拒絕 push，訊息含 `TAIPO_PRIVATE_DIR`，remote refs 不變。正向對照：設定 `TAIPO_PRIVATE_DIR` 後同一個 push 成功。
- K21：具名測試：`--rules full` 時 commit author 或 committer 的 email 在 fixture `leak-patterns.txt` 中 → `private-identity` 失敗，輸出不含該 email。正向對照：不在 `leak-patterns.txt` 的 `x@example.org` → 通過（不要求 noreply）。
- K22：具名測試：`--text` 的檔案含 fixture 私有句或私有句的長片段 → 失敗，輸出不含句子。
- K23：具名測試：`public-watch.sh` 對 fixture 公開 repo 與 fixture PR 文字目錄執行；任一處含 fixture 私有句 → exit 不為 0，summary 只有命中數與 `路徑:行號 規則名稱`。正向對照：都乾淨時通過。
- K24：[measure] 一次性切換後：`gh api repos/unknowntpo/taipo/branches/main/protection` 顯示必要檢查 `core`、`leak-gate`，`enforce_admins` 為 true，`allow_force_pushes` 與 `allow_deletions` 為 false；`gh api repos/unknowntpo/taipo/actions/permissions/fork-pr-contributor-approval -q .approval_policy` 為 `all_external_contributors`；`gh api repos/unknowntpo/taipo -q '[.allow_squash_merge,.allow_merge_commit,.allow_rebase_merge,.delete_branch_on_merge]'` 為 `[true,false,false,true]`。

### Budget
- K26：[measure] 公開 CI：`core` ≤ 20 分鐘（2026-11-13 實測 13 分 42 秒，run 43142538303）；`leak-gate` ≤ 2 分鐘。公開 repo 使用 GitHub-hosted 標準 runner 不計費。
- K27：[measure] 本機 pre-push hook 對一個 PR 的 commit 範圍 ≤ 10 秒（Spec 019 的 dry-run 對整個 tree 為 2.3 秒）。私有 repo 的 `public-watch` 每次 ≤ 3 分鐘、每月 ≤ 100 分鐘 ubuntu。

### Observability
- K28：具名測試：`leak-check.sh` 成功時輸出兩行：`leak-check: rules <public|full>, <N> commits, <M> files` 與 `gate: ok`；失敗時每個命中一行 `路徑:行號 規則名稱`，最後一行 `gate: failed (<命中數>)`。輸出不含任何檔案內容。
- K29：[deploy] 公開 CI 的 `leak-gate` 與私有 `public-watch` 在 job summary 寫每條規則的命中數；失敗時只寫 `路徑:行號 規則名稱`。

## 無法在 GitHub-hosted runner 執行的檢查

| 檢查 | 原因 | 在哪裡做 |
| --- | --- | --- |
| Leak gate 私有規則（`private-sentence`、`private-fragment`、`private-identity`） | 需要私有語料與比對清單，不能放進公開 repo 或公開 CI | 擁有者本機 pre-push hook；私有 repo `public-watch` |
| ASR 評測（Spec 011、`taipo-asr record/transcribe/score`） | 需要私有語料、使用者的錄音與約 1 GB 的模型；hosted macOS runner 沒有可用的 Metal GPU | 擁有者本機，對公開 checkout |
| Decision model 實際推論與品質（Spec 004，Qwen3-0.6B MLX） | 需要使用者自行放的模型權重；需要 Metal GPU | 擁有者本機 |
| 真機輸入法：安裝、在系統設定加入、各 app 實際打字、麥克風與語音、權限提示（Spec 002、012、024 的 `[manual]`） | 需要登入的桌面工作階段、使用者授權與麥克風 | 擁有者真機 `[manual]` |
| Bundle build（MLX Metal shader） | 可能可以；尚未在任何 CI 上跑過 | K8 驗證一次；失敗就列為本機檢查 |

## 決定

擁有者於 2026-11-18 決定；不重要的項目依原本的建議。

1. **D1**（2026-11-18）：切換前，每個 open 的私有 PR 都 merge 或關閉；只含 spec 的 PR 關閉，切換後若還要做就在公開 repo 重開；#13 關閉，需要保存的內容放進 `private/asr-eval/`（Behavior 1）。
2. **D2**（2026-11-18）：私有規則用本機 pre-push hook 阻擋（Behavior 5），加上私有 repo 每日 `public-watch` 偵測（Behavior 9）。
3. **D3**（2026-11-18）：公開 CI 只用 GitHub-hosted runner（`core` 在 `macos-26`，`leak-gate` 在 `ubuntu-latest`），一律不使用擁有者的自架 runner `macbook`。本 spec 不改私有 repo 的 runner。
4. **D4**（2026-11-18）：不要 DCO，也不要 CLA。
5. **D5**（2026-11-18）：目前不加 `CODE_OF_CONDUCT.md`。Repo 在擁有者的帳號下，沒有外部協作者，所以不需要專案 email。
6. **D6**（2026-11-18）：假設沒有外部協作者。所有 PR 由擁有者或擁有者的 agent 依 `docs/process/workflow.md` 的 merge 規則 merge（Behavior 13）。Fork PR 的 workflow 核准維持現狀 `all_external_contributors`，不放寬（Behavior 14）。
7. **D7**（2026-11-18）：`public-watch` 也掃描 PR 與 issue 文字（Behavior 9）。
8. **D8**（2026-11-18）：issue、PR、spec 用繁體中文或英文；README 與 CONTRIBUTING 繁體中文在前、英文在後（Behavior 12）。
9. **D9**（2026-11-18）：只開放 squash merge，merge 後自動刪除分支（Behavior 14）。
10. **D10**（2026-11-18）：Bundle build 只用 `workflow_dispatch` 執行：切換時一次，之後每次發佈前一次（Behavior 8）。

D3 的措辭、D6 的 fork 核准、Behavior 3 的理由、Behavior 13 與遷移順序第 5 步的 merge 方式，由擁有者授權的代理人於 2026-11-18 決定。

後續：在公開 CI 用公開的語音或文字語料評測。它補充擁有者的私有語料，不取代它。2026-11-18 的研究結果：

- 沒有一個公開語料同時是台灣口音、富含技術詞，而且沒有被 Breeze-ASR-25 訓練過（NTUML2021 在它的訓練資料中）。
- 之後的計畫：decoder 測試句取自 Common Voice zh-TW 的句子文字（CC0，可以 commit）。
- 之後的計畫：公開 CI 的 ASR 回歸測試用 ASCEND test（CC-BY-SA-4.0，測試時下載，不 commit）與 Common Voice zh-TW test（需要申請，要 token）。
- 技術詞的正確率仍用擁有者的私有語料。
- 本 spec 不實作這些。

## 簡化審查

1. **質疑需求**：需要搬家嗎？需要。Spec 019 讓公開 repo 只能被動接收，公開 PR 要繞道私有 repo。能否把私有 repo 直接改成公開？不行：私有歷史含私有語料與私人 email（Evidence）。能否保留雙 repo 開發、只把 issue 開在公開？不行：PR 與 CI 仍然不透明。
2. **刪除**：不搬私有歷史、不改寫歷史、不做反向同步、不做鏡像。不加 CODEOWNERS（只有一位維護者）、不開 Discussions、不設 label 分類、不加 stale bot、不做 release 自動化、不加 DCO 或 CLA（D4）、不加行為準則（D5）、不定外部 PR 的規則（D6）、不另寫英文版 spec。移除 Spec 019 的同步程式、deploy key、environment。私有 repo 不封存（它還要存新的評測語料），但移除所有程式碼。2026-11-18 依決定刪除只為外部貢獻者或行為準則存在的部分：K25、`CODE_OF_CONDUCT.md`、Behavior 13 的外部 PR 規則、hook 的 `TAIPO_LEAK_RULES=public` 模式（K20 後半）、K11 的 100% 目標。
3. **簡化**：一個入口 `leak-check.sh`，兩個規則組；沿用 Spec 019 的 gate 程式與輸出格式，只新增 3 條規則（`private-history`、`self-hosted`、`workflow-secret`）。公開 CI 只多一個 ubuntu job。私有 repo 只剩一個 workflow。
4. **縮短驗證週期**：K1–K6、K13–K23、K28 都用本機 fixture repo 測，不碰 GitHub。只有 K7、K8、K10、K11、K24、K26、K29 需要真的 GitHub，K9、K12 需要 human。
5. **自動化**：最後才加 `public-watch` 的排程；先以 `workflow_dispatch` 跑一次（K10）。

## Non-goals

- 公開私有 repo 的歷史、改寫私有歷史、刪除私有 repo。
- 把私有 PR 移植到公開 repo（只含 spec 的 PR 在公開 repo 開新 PR，不算移植）。
- 在公開 CI 跑任何需要私有資料、錄音或模型權重的檢查。
- 本 spec 實作期間修改 GitHub 設定（visibility、branch protection、runner、secret、variable）；這些全部由使用者在「一次性切換」執行。
- 公開 repo 的 release、簽章、上架（日後另寫 spec，屬於 core decision）。
- iOS 鍵盤的公開開發安排。
- 行為準則：第一位外部貢獻者出現時再加 `CODE_OF_CONDUCT.md`。
- 外部 PR 的規則（merge 權限、在擁有者機器上執行外部程式碼）：第一位外部貢獻者出現時再定。
