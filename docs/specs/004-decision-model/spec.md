# Spec 004: 裝置上 decision model（開關控制）

Status: Draft（2026-10-19，依使用者要求實作；待 human 審查）
Date: 2026-10-19
Traceability: enforced
Builds on: Spec 001–003

## Intent

使用者可以在桌面的「Taipo」App 開關一個完全離線的 decision model。開啟時，遇到引擎無法確定的輸入，由模型依上下文重新挑第一名；使用者能用評估結果判斷它是否比手調的引擎更準。

## Evidence

- Spec 003 verifier：SCOWL 只有粗略分級，`is` 與 `sue` 同分，手調懲罰無法同時處理 F6 與 F8，只能加特例規則（Behavior 7）。
- 使用者要求不使用 Apple Foundation Models，改用自架的小型 Clef 類 decision model（2026-10-19）。
- `mlx-community/clef-flash-4bit` 的 `clef_mlx.py`（只讀，未執行）顯示 Clef = Qwen3.5 骨幹的 hidden states + 另外訓練的 JointSchemaHead（寬 1024、4 層）替每個選項打分，不是讓 LLM 生成答案。

## Example

模型與執行環境（2026-10-19 下載）：

| 項目 | 來源（固定 commit） | 授權 | 大小 |
| --- | --- | --- | --- |
| Clef-mini 骨幹 `Qwen/Qwen3-0.6B-MLX-4bit` | `173234aa840d113125e9f2271100ddbaf16c9620` | Apache-2.0 | 317 MB |
| 評估參考 `mlx-community/clef-flash-4bit` | `b5adbe2c3a95200d4bf04a0727c8ec457157d5e1` | Apache-2.0 | 6.2 GB |
| 執行環境 `ml-explore/mlx-swift-lm` 3.32.3（關閉 FoundationModels trait） | GitHub | MIT | — |

位置：`~/Library/Application Support/Taipo/models/<name>/`，不進 git。

| 按鍵 | 引擎第一名 | 期望（開啟 decision model 後） |
| --- | --- | --- |
| `5k4ek7is` | 這個 is | 這個 is（不變） |
| `suecl3` | 你好 | 你好（不變） |
| 實際正確率與延遲 | — | 由 `taipo-bench decision` 量測後補上 |

## Behavior

1. **開關**：`DecisionSettings.isEnabled` 存在 `com.unknowntpo.inputmethod.Taipo` preferences domain，預設關閉。設定 App 寫入並發出 distributed notification；IME 每次要做決定時讀取，不需重啟。
2. **Clef-mini 評分**：對每個候選，`總分 = 引擎的鍵盤修正分數（−編輯懲罰）+ λ × LM 分數`，LM 分數是 Qwen3-0.6B 在「上下文＋候選」上的平均 token log 機率（只跑 prefill，不生成）。取總分最高者；平手保留引擎順序。λ 由評估決定。
3. **觸發條件**：只在有歧義時：前兩名都不是原文，且兩者分數差 < 一次編輯懲罰或語言不同。最多評 5 個候選。（「第一名不是尾巴」已刪除：4,500 筆語料中沒有任何尾巴的第二名接近或換語言。）
4. **非同步**：停頓 150 ms 後在背景執行；新按鍵取消；結果回來時 buffer 不變才套用（被選中的候選移到第一名）。不阻塞按鍵處理。
5. **失敗**：模型目錄不存在、載入或推論失敗 → 當作關閉；設定 App 顯示原因；IME 記 `os_log`。
6. **設定 App**：開關、模型狀態（路徑、是否載入、載入時間）、試打欄位（輸入按鍵 → 顯示引擎候選、模型分數與延遲）。
7. **評估**：`swift run -c release taipo-bench decision` 用有標準答案的語料（注音鄰鍵錯字、中文＋英文、混合句）比較「只用引擎」與「引擎＋Clef-mini」的第一名正確率，並量延遲。

## Acceptance

### Behavior
- D1：開關預設關閉；寫入後另一個 process 讀得到。具名測試。
- D2：Clef-mini 對固定候選回傳的分數可重現，且 `這個 is` 在 `5k4ek7is` 不被降級。[measure] 需要模型檔，`taipo-bench decision`。
- D3：觸發條件的兩側案例（有歧義／沒歧義、尾巴）。具名測試。
- D4：buffer 改變後回來的結果不套用；buffer 相同才套用。具名測試（以假 decider）。
- D6：設定 App 能建置並啟動。[manual]
- D7：評估報告。[measure]

### Failure and retry
- D8：模型目錄不存在 → 載入回報錯誤，IME 行為等同關閉。具名測試。
- D9：decider 拋錯 → 保留引擎順序。具名測試（假 decider）。
- D10：decider 回傳超出範圍的 index → 保留引擎順序。具名測試。
- D11：開關關閉時完全不呼叫 decider。具名測試。
- D12：同一 buffer 連續多次停頓只評一次。具名測試。

### Budget
- D13：[measure] Clef-mini 一次決定（≤ 5 候選）p95 ≤ 300 ms（背景執行）。
- D14：[measure] 載入模型後 IME process 記憶體增量 ≤ 600 MB。
- D15：[measure] 開啟時按鍵處理 p95 仍 ≤ 16 ms（Spec 002 I17）。

### Observability
- D16：`os_log` 記錄每次決定的候選、分數、選擇與延遲（只記在本機）。[manual]

## 簡化審查

1. **質疑需求**：開關（使用者要求）、設定 App（使用者要求「在桌面切換」）、評估（判斷是否值得開）。
2. **刪除**：Apple Foundation Models（使用者拒絕）；讓 LLM 生成答案（Clef 也不生成）；雲端；自動下載模型（已手動下載）。
3. **簡化**：Clef-mini 先不訓練決策頭，只用 LM 機率取代粗糙的詞頻；Clef-flash 的決策頭移植放到下一步，只當評估上限參考。
4. **縮短驗證週期**：觸發、取消、套用邏輯用假 decider 做單元測試，不需要模型。
5. **自動化**：無。

## Non-goals

- iOS（記憶體不足）。
- 微調或訓練決策頭（後續 spec）。
- Clef-flash 放進 IME。
