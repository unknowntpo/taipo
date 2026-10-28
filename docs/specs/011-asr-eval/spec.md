# Spec 011: 語音辨識評測（選引擎用）

Status: Accepted（2026-10-26，使用者同意先做錄音與評測工具）
Date: 2026-10-26
Traceability: enforced
Builds on: 2026-10-23 語音模型調查（Qwen3-ASR、Breeze-ASR-25、Apple SpeechTranscriber）

## Intent

在寫語音輸入之前，用使用者自己的聲音比較三個本機引擎，挑出 Taipo 語音輸入要用的引擎。同一套評分之後也拿來追蹤「越用越好」。

## Evidence

公開的台灣華語／中英夾雜數字都是廠商或單一作者自測（Qwen3-ASR ASCEND 10.57、Breeze-ASR-25 CSZS 13.01），沒有獨立評測，Apple SpeechTranscriber 沒有公開數字。

## Example

| 參考 | 引擎輸出 | 斷詞後 | MER |
| --- | --- | --- | --- |
| 這個 API 的 timeout 有點 short | 這個API的timeout有點short | 一樣 | 0 |
| 這個 API 的 timeout 有點 short | 这个 API 的 timeout 有点 short | 這／这、個／个、點／点 不同 | 3/8 = 37.5% |
| 同上，經 OpenCC s2twp | 這個 API 的 timeout 有點 short | 一樣 | 0 |

參考斷成 8 個 token：這 個 pr 的 timeout 有 點 short（漢字一字一 token、英文一字一 token）。

## Behavior

1. **評分（MER，mixed error rate）**：參考與輸出各自正規化後斷 token，算編輯距離 ÷ 參考 token 數。
   - 正規化：英文轉小寫、全形英數轉半形；標點與空白是 token 邊界，本身不算 token。
   - 斷 token：每個漢字一個；空白或標點之間的連續英文字母或數字一個（`consumer group` 是兩個；引擎寫成 `P R` 也算兩個）。
   - 引擎的 MER 是整個語料的錯誤總數 ÷ 參考 token 總數；RTF 是處理秒數總和 ÷ 音檔秒數總和。
   - 不做簡繁轉換：簡體字算錯（使用者看到的就是錯的）。另報經 OpenCC s2twp 之後的 MER，看轉換能救回多少。
2. **語料**：`~/Library/Application Support/Taipo/asr-eval/sentences.tsv`（每行 id、Tab、參考文字；可用 `--sentences` 指定其他位置），建議 30 句台灣口語、多數中英夾雜。語料與錄音一樣**不進 repo**；格式範例見 `Data/asr-eval/sentences.example.tsv`。錄音存在 `~/Library/Application Support/Taipo/asr-eval/<id>.wav`（16 kHz mono），**不進 repo**。
3. **錄音**：`swift run taipo-asr record` 逐句顯示參考文字，Enter 開始、Enter 結束。
4. **引擎**：每個引擎輸出 JSONL（`id`、`engine`、`text`、`seconds`）到 `~/Library/Application Support/Taipo/asr-eval/results/<engine>.jsonl`。
   - `apple`：Speech framework 的 SpeechTranscriber（zh_TW），Swift。
   - `qwen3-0.6b`：Qwen3-ASR-0.6B（MLX，4-bit）。
   - `breeze`：Breeze-ASR-25（MLX）。
   - Python 引擎以 `uv run` 跑在隔離環境，不裝進系統 Python。
5. **報表**：`swift run taipo-asr score` 印出每個引擎的 MER、s2twp 後 MER、平均延遲與 RTF（處理秒數 ÷ 音檔秒數），以及每句最差的 5 句。
6. **煙霧測試**：`taipo-asr synth` 用 macOS `say`（zh_TW 美佳）產生合成語音，不需要使用者錄音就能跑完整流程；合成語音的分數不能拿來選引擎。

## Acceptance

### Behavior
- S1：具名測試：正規化與斷 token（標點、空白、全形、大小寫；漢字逐字、英數連續成一個）。
- S2：具名測試：MER＝編輯距離 ÷ 參考 token 數；完全相同為 0；空輸出為 1。
- S3：具名測試：簡體輸出計為錯；Example 第二列 MER = 3/8。
- S4：具名測試：讀 sentences.tsv 與 results JSONL，缺錄音或缺結果的句子列為 missing，不算進 MER。
- S5：[measure] 用合成語音跑完 apple、qwen3-0.6b、breeze 三個引擎並印出報表（`swift run taipo-asr synth && … && swift run taipo-asr score`）。
  - 2026-10-26，M1 Pro、合成語音 30 句：apple MER 10.1%（s2twp 後 10.7%）RTF 0.06；breeze 3.0%（4.0%）RTF 0.41；qwen3-0.6b 29.3%（5.2%）RTF 0.04。合成語音不能拿來選引擎。
- S6：[manual] 使用者錄完 30 句後跑報表，依結果決定引擎。

### Failure and retry
- S7：具名測試：JSONL 中格式錯誤的行被略過並計數，不中止報表。

### Budget
- 不適用：離線評測工具。

### Observability
- 不適用：報表本身就是輸出。

## 簡化審查

1. **質疑需求**：使用者要求先比較模型再決定；需要自己的聲音，因為公開數字不可信。
2. **刪除**：不做串流評測（先比整句準確度）、不做 WER 以外的指標、不比較 1.7B（0.6B 不夠好再加）。
3. **簡化**：評分在 Swift（之後產品內追蹤個人 MER 會重用）；模型推論沿用各自現成的 Python MLX 套件，不先移植到 Swift。
4. **縮短驗證週期**：評分全是單元測試；合成語音讓整條流程不必等錄音。
5. **自動化**：無新增 gate。

## 已知限制

- 異體字與數字寫法算錯：`臺中`／`台中`、`9點半`／`九點半`。真人錄音結果出來後，若這類差異影響排名再決定是否正規化。

## Non-goals

- 語音輸入功能本身、回饋迴路（下一份 spec）。
- 串流延遲、麥克風權限 UX。
