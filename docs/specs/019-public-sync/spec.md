# Spec 019: 私有 repo 同步到公開 repo

Status: Accepted（2026-10-28，使用者接受「決定」一節的 8 項建議）
Date: 2026-10-28
Traceability: enforced
Builds on: Spec 011（評測語料 `sentences.tsv`）、Spec 012（語音輸入）、`docs/process/workflow.md`（Gates、Core decision）

## Intent

開發在私有 repo `unknowntpo/taipo-private` 進行（完整歷史、PR、評測資料）。公開 repo `unknowntpo/taipo`（Apache-2.0）在 2026-10-28 由私有 `origin/main` 660654c 的清理快照建立，之後只靠手動更新。

使用者在私有 main merge 一個 PR 之後，公開 repo 自動收到同一份程式碼，且私有資料（評測語料原文、本機路徑、私人 email、錄音、模型權重、金鑰）一定不會出現在公開 repo。任何一條檢查不通過，就不 push（fail closed）。

## Evidence

- 2026-10-28 建立公開 repo 時，需要手動改 17 個路徑（見 Example）。手動重做這些修改容易漏，漏一次就把私有語料公開。
- 私有 `Data/asr-eval/sentences.tsv` 是使用者的 30 句真人評測語料（每句 9–36 字元）。其中幾句原文也寫進了測試與 spec；私有 main 有 6 個檔案含完整原句（測試 3 個、spec 2 個、fail-first 紀錄 1 個）。
- 草稿分支 `spec/016-vocab-feedback` 的 spec 含 4 句完整原句。它 merge 後若不處理，下一次同步就會公開。
- 私有 CI 跑在自架 runner `macbook`，只註冊在 `taipo-private`。使用者規則：自架 runner 不可指向公開 repo（公開 repo 的 PR 可在 runner 上執行任意程式碼）。
- 私有 main 推送頻率：2026-10-14 到 10-28 共 16 次 first-parent commit，單日最多 7 次。

## Example

擷取時間 2026-10-28。私有 `origin/main` = 660654c（tree dc510c7，116 個檔案）。公開 `main` = 2debe2a（tree aa865b5，117 個檔案；歷史為 9de17d6 首次公開、26cc003 Breeze-ASR-25 來源註記、2debe2a README 路線圖與 explainer 用字）。兩邊 tree 的差異（`git diff --name-status`，不看歷史）就是同步必須重現的轉換：

| 路徑 | 差異 | 處理 | 原因 |
| --- | --- | --- | --- |
| `default.profraw` | 公開刪除（5.5 MB） | 源頭：私有也刪除，`.gitignore` 加 `*.profraw` | 誤 commit 的覆蓋率檔 |
| `Data/asr-eval/sentences.tsv` | 公開刪除 | 源頭搬到 `private/asr-eval/sentences.tsv`；`private/` 列入排除清單 | 私有語料，唯一必須排除的資料 |
| `Data/asr-eval/sentences.example.tsv` | 公開新增（3 句編造的句子） | 源頭：加進私有 | 公開也需要格式範例 |
| `LICENSE`、`NOTICE` | 公開新增 | 源頭：加進私有 | 授權不分公私 |
| `THIRD_PARTY_NOTICES.md` | 公開多 114 行 | 源頭：採用公開版 | 26cc003 的來源註記 |
| `README.md` | 公開改寫（功能、路線圖、隱私、授權） | 源頭：採用公開版 | 2debe2a；README 不需要分兩版 |
| `.gitignore` | 公開多 13 行（音檔、權重、`results/`、`models/`） | 源頭：採用公開版 | 防止誤 commit，私有也需要 |
| `Sources/taipo-asr/main.swift` | 公開版預設讀 `<dir>/sentences.tsv`，檔案不存在時提示 | 源頭：採用公開版 | 語料不再放 repo |
| `docs/explainers/taipo-decision-model.html` | 公開版把 6 個本機絕對路徑改成 repo 相對路徑 | 源頭：採用公開版 | 本機路徑不該進任何 repo |
| `Tests/TaipoIMETests/VoiceTests.swift`、`Tests/TaipoSpeechTests/MERTests.swift`、`Tests/TaipoSpeechTests/ReportTests.swift` | 私有語料原句換成編造的句子 | 源頭：採用公開版 | 測試只需要格式相同的句子 |
| `docs/specs/011-asr-eval/spec.md`、`docs/specs/012-voice-input/spec.md`、`docs/specs/012-voice-input/fail-first.txt` | 同上，原句換成編造的句子 | 源頭：採用公開版 | 同上 |
| `.github/workflows/ci.yml` | 私有 `runs-on: [self-hosted, macOS, ARM64]`；公開 `runs-on: macos-26` 並加 `permissions: contents: read` | 源頭：單一 ci.yml，依 `github.repository` 選 runner | 唯一真正因 repo 而異的設定 |

結論：17 個差異中，16 個可以在源頭消除，只剩「排除 `private/`」必須在同步時做。另有同步本身的檔案要排除：排除清單 `.public-exclude` 與同步 workflow `.github/workflows/public-sync.yml`。

洩漏檢查（leak gate）在兩棵 tree 上的實測結果（只列檔案數，不印內容）：

| 規則 | 私有 660654c（排除 `sentences.tsv` 後） | 公開 2debe2a |
| --- | --- | --- |
| 私有語料完整原句（去空白、小寫後比對） | 6 | 0 |
| 私有語料長片段（見 Behavior 5） | 6 | 0 |
| 絕對家目錄路徑 `/Users/<name>/` | 1（explainer） | 0 |
| 音檔、權重、profraw；或單檔大於 5 MB | 1（`default.profraw`） | 0 |
| 私人 email | 0 | 0 |
| 金鑰格式（GitHub、Hugging Face、AWS、私鑰） | 0 | 0 |

長片段的門檻也是實測挑的：把私有語料每句去空白、轉小寫，切成長度 N、至少含 K 個非 ASCII 字元的視窗，任一視窗出現在檔案中就算命中。

| N、K | 私有命中檔案 | 公開命中檔案（誤報） |
| --- | --- | --- |
| 10、1 | 7 | 1 |
| 10、2 | 6 | 0 |
| 12、2 | 6 | 0 |
| 只看漢字、連續 8 字 | 3（漏掉英文為主的句子） | 1 |

選 N=10、K=2：私有 6 個含原句的檔案全抓到，公開 0 誤報。比 N 短的整句直接當成一個視窗。

源頭對齊後的預期同步結果：私有 main 每 merge 一個 PR，workflow 產生一個公開 commit，例如

```
Sync from private main

- Spec 018: hide candidate numbers when digits would not select
- Spec 019: public sync (draft)

Synced-From: <私有 main 的 40 字元 SHA>
```

作者與 committer 都是 `Eric Chang <10594519+unknowntpo@users.noreply.github.com>`。

## Behavior

1. **源頭對齊**：第一個實作切片把 Example 表中 16 個「源頭」差異搬進私有 main，該 commit 帶 trailer `Ported-From: unknowntpo/taipo@9de17d6`、`@26cc003`、`@2debe2a`。之後私有 main 本身就是公開安全的，只有排除清單列的路徑例外。
   - 不做 overlay（同步時改寫檔案內容）。日後若出現只該存在於公開版的內容，改源頭，不加 overlay。
2. **單一 ci.yml**：`runs-on: ${{ github.repository == 'unknowntpo/taipo-private' && fromJSON('["self-hosted","macOS","ARM64"]') || 'macos-26' }}`，並設 `permissions: contents: read`。
   - 安全邊界是 runner 只註冊在私有 repo，不是這個運算式。運算式寫錯時，公開 repo 的 job 只會排隊不會執行，不會跑到 `macbook`。
3. **排除清單 `.public-exclude`**：每行一個 pattern，`#` 開頭（可先有空白）為註解，即使內容是真實路徑也不生效。pattern 一律從 repo 根目錄算起（`private/` 不排除 `docs/private/`）；`dir/` 排除整個目錄，其他用 glob，`*`、`?` 不跨 `/`，`**` 可跨。初始內容：
   - `private/`（評測語料 `private/asr-eval/sentences.tsv`、私人比對清單 `private/leak-patterns.txt`、日後其他私有資料）
   - `.public-exclude`
   - `.github/workflows/public-sync.yml`
4. **產生公開 tree**：`scripts/public-sync.sh` 取私有 main 的 tree（`git archive`，不含未追蹤檔），刪掉符合排除清單的路徑，放進暫存目錄。
   - `--source <rev>` 指定私有 commit（預設 `HEAD`）；`--source worktree` 改用工作目錄（已追蹤與未被忽略的未追蹤檔；被 `.gitignore` 忽略的檔案不算），用暫存 index，不改真正的 index，供本機與 G19 使用。
   - Gate 用 `${TAIPO_PYTHON:-python3} -I` 執行。本機測試用 uv 管理的 Python（`uv python find --python-preference only-managed`），找不到 uv 才用 `python3`（CI）。
   - 私有語料不在預設位置：本機評測用 `swift run taipo-asr ... --sentences private/asr-eval/sentences.tsv`。
5. **Leak gate**（`scripts/public_leak_gate.py`，只用 Python 標準函式庫）：掃描產生的 tree 與待 push 的 commit metadata。任一規則命中就失敗，輸出只有 `路徑:行號 規則名稱`（行號 0 表示整個檔案；commit 的路徑寫 `commit`），絕不印出命中的內容。規則名稱：`excluded-path`、`private-sentence`、`private-fragment`、`media`、`home-path`、`private-identity`、`secret`、`symlink`、`author`、`committer`。掃描範圍：
   - **路徑**：每個檔案的相對路徑也跑規則 2、4、5、6，命中時輸出 `<代稱>:0 規則名稱`。路徑本身外洩時，該檔所有命中都用代稱 `redacted-<sha256(路徑) 前 12 個十六進位字元>`，不印原始路徑。`public-sync.sh` 在 gate 通過後才印差異檔案清單，所以外洩的路徑不會進 log。
   - **編碼**：檔案內容先用 UTF-8 解碼。若出現無效位元組或 NUL 字元，再用 UTF-16 LE、UTF-16 BE、Big5（cp950）各解碼一次，每份解碼都掃描（同一行同一規則只報一次）。
   - **Symlink**：目標是絕對路徑、或解析後離開 tree，算 `symlink` 失敗（指向目錄的 symlink 也一樣）。其他 symlink 的目標字串跑規則 2、4、5、6；目標檔案本身照一般檔案掃描。

   規則：
   1. 任何路徑符合排除清單（與第 4 條獨立重檢一次）。
   2. 私有語料：從私有 tree 的 `private/asr-eval/sentences.tsv` 讀入。完整句比對：去空白、轉小寫後整句出現。長片段比對：見 Example，N=10、K=2。
   3. 音檔或權重：路徑中任何一段（含目錄，例如 `x.mlpackage/`）的副檔名為 `wav m4a flac caf mp3 aac ogg opus bin gguf ggml safetensors onnx pt pth npz mlmodel mlpackage profraw`；或檔頭為 RIFF/WAVE、`GGUF`、`ftyp`。另外任何檔案大於 5 MB（5,242,880 位元組；目前最大的公開檔案是 2.3 MB 的 `zh.tsv`）。
   4. 絕對家目錄路徑：regex `/Users/[A-Za-z0-9._-]+/`。`~/Library/...` 不算。
   5. 私人身分：`private/leak-patterns.txt` 列出的字串（例如擁有者的私人 email）。這份清單本身不公開，所以 gate 程式與測試裡都不出現私人 email。
   6. 金鑰格式：`gh[pousr]_` 加 36 字元、`github_pat_` 加 82 字元、`hf_` 加 30 字元以上、`AKIA` 加 16 字元、`-----BEGIN ... PRIVATE KEY-----`、`sk-` 加 20 字元以上、`xox[abp]-` 加 10 字元以上。`gh`、`hf_`、`AKIA`、`sk-`、`xox` 前面不可緊接英數字（避免 `desk-...` 這類誤報）。
   7. Commit metadata：author 與 committer 都必須是 `10594519+unknowntpo@users.noreply.github.com`；commit message 也跑規則 2、4、5、6。
   - Gate 自己的原始碼、測試與本 spec 都會進公開 tree，所以都必須通過 gate。測試裡的假金鑰與假路徑在執行時用字串拼接產生，fixture 句子一律是編造的。
6. **Fail closed**：私有語料檔或 `private/leak-patterns.txt` 不存在或為空、排除清單不存在、gate 程式出錯，都算失敗，不 push。
7. **Commit 形狀**：每次同步在公開 main 上最多產生一個 commit，parent 是當下的公開 main HEAD（只做 fast-forward，永遠不 force push）。Message：
   - 第一行 `Sync from private main`。
   - 列出這次範圍內私有 main 的 first-parent commit 標題；merge commit 取 PR 標題（message 第三行）。刪掉 `#數字`（私有 PR 編號在公開 repo 會連到錯的 issue）。
   - 範圍的起點是公開 main 上最後一個 `Synced-From` 的私有 SHA；還沒有同步 commit 時，是 `Ported-From` 指向公開 main HEAD 的私有 commit。範圍內沒有標題時，用私有 SHA 的標題。最多列 50 行。
   - Trailer `Synced-From: <私有 SHA>`。私有 SHA 不透露內容，用於稽核與判斷上次同步點。
   - 範圍內帶 `Ported-From` 的私有 commit，若作者不是擁有者（noreply 或 `private/leak-patterns.txt` 列出的 email），加 `Co-authored-by: <作者>`。不加任何 AI 共同作者。
   - Message 也要過 gate（第 5.7 條）。
8. **公開 repo 上的其他 commit**：公開 main 上每個 commit 必須是同步 commit（帶 `Synced-From`），或在私有 main 歷史中有對應的 `Ported-From: unknowntpo/taipo@<SHA>` trailer。否則同步失敗，列出這些 SHA，不 push。
   - 外部貢獻的處理：在私有 repo 用 `git am` 套用（保留原作者），commit 加 `Ported-From`；公開 PR 關閉並附上同步 commit 連結。下一次同步會把內容帶回公開 repo。
9. **冪等**：產生的 tree 與公開 main HEAD 的 tree 相同時，不產生 commit，印出 `already in sync`，exit 0。
10. **本機 dry-run**：`scripts/public-sync.sh --dry-run [--public <path-or-url>]` 產生 tree、跑 gate、與公開 main 比較，gate 通過後印出差異檔案清單，不 push、不改任何 repo。在 Actions 上（有 `GITHUB_STEP_SUMMARY` 時），dry run 也寫 job summary：私有 SHA、會 push 的 commit 與公開 HEAD（或 `already in sync`）、差異檔案清單、每條 gate 規則的命中數。不寫檔案內容。
11. **觸發與 runner**：私有 repo 的 `.github/workflows/public-sync.yml`，`on: push: branches: [main]` 與 `workflow_dispatch`（輸入 `dry_run`）。
    - `runs-on: ubuntu-latest`（GitHub-hosted；只需 git、bash、python3，不需 Swift）。不用 `macbook`。
    - Job 加 `if: github.repository == 'unknowntpo/taipo-private'`；`concurrency: public-sync`，不取消進行中的 run。
    - Push 觸發的真同步另外要求 repo variable `PUBLIC_SYNC_ENABLED` 為 `true`。這讓本 PR merge 後、一次性設定完成前，push 不會因為缺 secret 而失敗；設定完成後才開啟。`workflow_dispatch` 不看這個變數。
    - 真同步步驟在 `PUBLIC_DEPLOY_KEY` 為空時失敗（fail closed）。SSH 以 GitHub 公布的 ed25519 host key 驗證（`StrictHostKeyChecking=yes`），不用 `ssh-keyscan`。
    - 公開 repo 上不放任何帶 secret 的 workflow。公開 repo 自己的 CI 跑在 GitHub-hosted `macos-26`。
12. **認證**：公開 repo 的 deploy key（寫入權限，ed25519）。私鑰存成私有 repo environment `public-sync` 的 secret `PUBLIC_DEPLOY_KEY`，environment 只允許 `main` 分支。
13. **PR 前檢查**：私有 ci.yml 多一個 job `public-sync-dry-run`（`ubuntu-latest`，`if: github.repository == 'unknowntpo/taipo-private'`），跑 `scripts/public-sync.sh --dry-run --public https://github.com/unknowntpo/taipo.git`。把私有原句寫進測試的 PR 在 merge 前就失敗，而不是 merge 後同步失敗。放在 ubuntu 而不是 `macbook`，因為它只需要 git、bash、python3。

### 一次性設定（G7 前，由使用者執行）

1. 產生金鑰（不設密碼）：`ssh-keygen -t ed25519 -N "" -C "taipo-public-sync" -f taipo_public_sync`。
2. 把公鑰加成公開 repo 的 deploy key，勾選寫入權限：`gh repo deploy-key add taipo_public_sync.pub --repo unknowntpo/taipo --title taipo-public-sync --allow-write`。
3. 建立私有 repo 的 environment `public-sync`，只允許 `main` 分支部署：`echo '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' | gh api -X PUT repos/unknowntpo/taipo-private/environments/public-sync --input -`；再 `gh api -X POST repos/unknowntpo/taipo-private/environments/public-sync/deployment-branch-policies -f name=main -f type=branch`。
4. 把私鑰存成該 environment 的 secret：`gh secret set PUBLIC_DEPLOY_KEY --repo unknowntpo/taipo-private --env public-sync < taipo_public_sync`。
5. 刪掉本機的私鑰檔（移到垃圾桶）。之後只存在 GitHub secret 裡。
6. 在 Actions 手動執行 `public-sync`，`dry_run=true`，檢查差異清單與 gate 結果。
7. 再手動執行一次，`dry_run=false`。確認公開 main 多一個 commit、公開 CI 在 `macos-26` 通過。
8. 開啟 push 觸發：`gh variable set PUBLIC_SYNC_ENABLED --repo unknowntpo/taipo-private --body true`。

## Acceptance

### Behavior
- G1：具名測試：fixture 私有 repo 有 `private/a.tsv`、`.public-exclude`、`docs/x.md`；產生的 tree 不含前兩者，含 `docs/x.md`（正向對照）。`dir/` 與 `*` glob 的邊界各一個 case。另外：註解行 `#notes.md` 不排除根目錄的 `#notes.md`；`private/` 不排除 `docs/private/x.md`（產生器與 gate 各驗一次）。
- G2：具名測試：`--dry-run` 對 fixture 公開 repo（本機路徑）執行後，公開 repo 的 refs 與 HEAD 不變，暫存目錄含產生的 tree，輸出列出差異檔案。
- G3：具名測試：同步一次後，私有 repo 沒有新 commit 時再跑一次，公開 repo 沒有新 commit，輸出 `already in sync`，exit 0。
- G4：具名測試：同步 commit 的 parent 是原公開 HEAD；author 與 committer 是 noreply；message 有 `Synced-From: <私有 SHA>`、沒有 `#數字`。
- G5：[measure] 源頭對齊切片 merge 後，對私有 main 跑 `--dry-run --public` 公開 2debe2a。Example 表中 16 個源頭路徑必須與公開版逐位元相同；其餘差異只能是 660654c 之後私有 main 新增或修改、且不在排除清單內的路徑。把差異清單記錄在本 spec。
- G6：[deploy] 私有 PR 加入一句編造的 fixture 原句（臨時放進 `private/asr-eval/sentences.tsv` 與一個測試檔），PR 上的 dry-run 步驟失敗；移除後通過。
- G7：[manual] 第一次真正同步：使用者建立 deploy key 與 environment，`workflow_dispatch` 先跑 `dry_run=true` 檢視差異清單，再跑一次真同步。公開 main 多一個 commit，公開 CI 在 `macos-26` 通過。確認 deploy key 可以 push `.github/workflows/` 下的檔案。

### Failure and retry
- G8：具名測試：產生的 tree 中某檔含 fixture 私有句的完整句（含不同空白與大小寫）→ gate 失敗，輸出 `路徑:行號 private-sentence`。stdout 與 stderr 都不含該句子（「不出現」斷言）。正向對照：同一檔換成不相關句子 → 通過。
- G9：具名測試：含 fixture 句子中長度 10、2 個非 ASCII 字元的片段 → 失敗。邊界：長度 9 的片段、或只有 ASCII 的 10 字元片段 → 通過。行尾且是句子最後一個視窗的片段 → 失敗。
- G10：具名測試：直接把含 `private/x` 的 tree 交給 gate → 失敗（規則 5.1 獨立於第 4 條）。
- G11：具名測試：`.wav` 副檔名、改名為 `.txt` 但檔頭為 RIFF/WAVE、`GGUF` 檔頭、5 MB + 1 位元組的檔案 → 各自失敗。`ftyp` 檔頭、`x.mlpackage/` 目錄下的檔案 → 各自失敗。正向對照：5 MB 整的文字檔通過。
- G12：具名測試：含 `/Users/` 加名字加斜線的路徑 → 失敗；`~/Library/Application Support/Taipo` → 通過。
- G13：具名測試：fixture `leak-patterns.txt` 列 `someone@example.com`，tree 中出現 → 失敗；未列的 email → 通過。
- G14：具名測試：每種金鑰格式各一個執行時拼出的假值 → 失敗；長度少一個字元 → 通過。`AKIA` 前面緊接英數字 → 通過。
- G15：具名測試：commit author 或 committer 不是 noreply → 失敗；message 含 fixture 私有句 → 失敗。
- G16：具名測試：私有語料檔不存在、為空；`leak-patterns.txt` 不存在；`.public-exclude` 不存在 → 各自失敗，不 push。
- G17：具名測試：公開 fixture main 多一個非同步 commit → 失敗並列出其 SHA，公開 refs 不變。私有 repo 加上帶 `Ported-From: unknowntpo/taipo@<該 SHA>` 的 commit 後 → 同步成功，fast-forward。
- G18：具名測試：同步期間公開 main 被推進（模擬競爭）→ push 被拒、失敗，不 force push；重跑後成功。
- G19：具名測試：gate 掃描本 repo 自己產生的公開 tree（含 gate 程式、測試、本 spec）→ 通過。
- G22：具名測試：檔名含 fixture 私有句、長片段、家目錄路徑、`leak-patterns.txt` 字串、金鑰格式 → 各自失敗，輸出 `redacted-<12 hex>:0 規則名稱`；同檔內容的其他命中也用同一個代稱；被排除且外洩的路徑也用代稱。stdout、stderr 都不含原始路徑或句子；代稱在兩次執行間相同。經 `public-sync.sh` 時，gate 失敗不印差異檔案清單。正向對照：一般檔名通過。
- G23：具名測試：fixture 私有句以 UTF-16（有 BOM、無 BOM LE、BE）或 Big5 存檔 → 各自失敗，輸出 `路徑:行號 private-sentence`；UTF-16 的假金鑰 → `secret`。正向對照：Big5 的不相關句子通過。
- G24：具名測試：symlink 指向 `../..` 外、絕對路徑、或絕對路徑的目錄 → `symlink` 失敗。正向對照：tree 內的檔案與目錄 symlink 通過。目標字串含 fixture 私有句的 symlink → `private-sentence`。
- G25：具名測試：`--source worktree` 的 tree 含未追蹤、未被忽略的檔案，不含被 `.gitignore` 忽略的檔案；真正的 index 不變。

### Budget
- G20：[measure] 本機 `--dry-run` 對私有 main 的總時間 ≤ 60 秒；CI 上整個 job ≤ 3 分鐘（ubuntu，目前推送頻率約每月 300 分鐘以內）。

### Observability
- G21：[deploy] Workflow job summary 顯示：私有 SHA、公開 main 同步前後 SHA（或 `already in sync`）、變更檔案數、每條 gate 規則的命中數。失敗時只顯示 `路徑:行號 規則名稱`（外洩的路徑用代稱，見第 5 條）。`workflow_dispatch` 的 dry run 也寫 summary（差異檔案清單與每條規則的命中數，不含內容）；具名測試 `G21:` 用 fixture 驗證 dry run 的 summary 內容。

## 量測（2026-10-28）

- G5（merge 前，在本分支 HEAD 上量；merge 後重跑一次）：`scripts/public-sync.sh --dry-run --public <公開 repo 本機 clone，main = 2debe2a>`。Example 表的 16 個源頭路徑全部與公開版逐位元相同（不在差異清單中）。差異只有 7 個，都是本 PR 新增或修改、且不在排除清單內的路徑：`M .github/workflows/ci.yml`（runner 運算式與 `public-sync-dry-run` job；預期差異）、`M Package.swift`（`TaipoDevTests` target）、`A Tests/TaipoDevTests/PublicSyncTests.swift`、`A docs/specs/019-public-sync/fail-first.txt`、`A docs/specs/019-public-sync/spec.md`、`A scripts/public-sync.sh`、`A scripts/public_leak_gate.py`。Gate 0 命中。
  - 加入路徑、編碼、symlink 檢查後重量（c5266b4 加上本 spec 的修改，`--source worktree`，公開 repo 為 GitHub 新 clone，main 仍是 2debe2a）：差異仍是上面同樣的 7 個路徑，gate 0 命中（含新規則 `symlink`），總時間 1.8 秒。
- G20（本機部分）：同一次 dry-run 總時間 2.3 秒（≤ 60 秒）。CI job 時間待 G6、G7。
- 正向對照：同一個 gate 掃 660654c 的 tree（拿掉語料檔）時，命中 6 個含原句的檔案、explainer 的 home path、`default.profraw`，與 Example 的實測一致。

## 決定（2026-10-28 使用者接受全部建議）

1. **轉換放在哪裡**：建議源頭對齊（Behavior 1），同步只剩排除清單。替代：保留私有原狀，同步時套 overlay 與字串替換。替代方案每次都要維護兩份內容，漏改就外洩，不建議。
2. **私有語料位置**：建議搬到 `private/asr-eval/sentences.tsv`，所有私有資料集中在 `private/`。替代：留在 `Data/asr-eval/sentences.tsv`，排除清單逐檔列。
3. **Spec 016 草稿的 4 句原句**：建議 merge 前把原句換成編造的句子（同 011、012 的做法），spec 公開。替代：把 `docs/specs/016-vocab-feedback/` 列入排除清單；代價是公開版有實作與測試卻沒有 spec。
4. **同步程式的形式**：建議 bash + Python 標準函式庫，測試放新的 Swift test target `Tests/TaipoDevTests/PublicSyncTests.swift`，用 `Process` 執行 script，讓 check-traceability 不用改。替代：做成 `taipo-dev` 子命令；但 ubuntu runner 要解析整個 Package（含 MLX），慢且可能失敗。
5. **認證**：建議 deploy key。它只能存取這一個 repo、不綁使用者帳號、不會過期。替代：fine-grained PAT（只給 `unknowntpo/taipo` contents:write）；會過期需輪替，且以使用者身分操作；push workflow 檔還需要額外 workflows 權限。
6. **Commit 落地方式**：建議直接 fast-forward push 到公開 main，一次同步一個 squash commit。理由：gate fail closed，同一份測試已在私有 CI 通過，每次開 PR 等人按 merge 只增加延遲。替代：在公開 repo 開 PR，等公開 CI 通過再 merge；可擋下只在 `macos-26` 失敗的情況，但每次同步都要人工介入。
7. **Commit message 內容**：建議列私有 first-parent 標題（刪 `#數字`）加 `Synced-From` trailer。替代：只寫 `Sync from private main` 與日期，不列標題、不帶私有 SHA；更保守，但公開歷史幾乎沒資訊，也無法稽核。
8. **外部貢獻的作者資訊**：squash commit 會遺失貢獻者作者資訊。建議對範圍內帶 `Ported-From` 的私有 commit，在同步 commit 加 `Co-authored-by: <原作者>`（只用於外部貢獻者）。替代：不加，只在公開 PR 留言說明。

## 簡化審查

1. **質疑需求**：能否只維護一個 public repo？不行：私有評測語料、PR 討論與草稿 spec 需要私有空間，且私有 repo 的自架 runner 不能用在公開 repo。能否手動同步？2026-10-28 手動一次就要改 17 個路徑，且漏一次就外洩，所以需要自動化加 gate。
2. **刪除**：不做 overlay、不做雙向自動同步、不保留私有歷史到公開（不跑 filter-repo）、不同步 tags 與 releases、不同步 main 以外的分支。17 個差異刪到只剩一條排除規則。
3. **簡化**：同步 = 複製 tree 減去排除清單；gate 是單一 Python 檔、只用標準函式庫；runner 是最便宜的 ubuntu；只做 fast-forward。
4. **縮短驗證週期**：G1–G4、G8–G19 用本機 fixture repo 測，不碰 GitHub；`--dry-run` 讓本機與 PR 上就能看到結果；只有 G6、G7、G21 需要真的 GitHub。
5. **自動化**：最後才加 `public-sync.yml`，並先以 `dry_run=true` 手動執行一次。

## Non-goals

- 把私有 repo 歷史搬到公開 repo，或改寫私有歷史。
- 公開 repo 到私有 repo 的自動同步（外部貢獻由人工 `git am` 移植）。
- Tags、GitHub Releases、Issues、Wiki 的同步。
- 掃描私有 repo 歷史中的舊外洩（公開 repo 從未包含私有歷史）。
- Git LFS 或大型檔案託管。
