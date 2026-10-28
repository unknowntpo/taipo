# Spec 006: 打錯多鍵時仍找得到正確答案

Status: Draft（2026-10-19；待 human 審查）
Date: 2026-10-19
Traceability: enforced
Builds on: Spec 001–005；量測見 `docs/research/typo-recall.md`

## Intent

使用者一個詞打錯兩三個鍵，或連打兩個詞時打錯一鍵，正確答案仍會出現在候選前幾名；平常打字的每鍵延遲不變慢到超過 16 ms。

## Evidence

`docs/research/typo-recall.md`（1,605 筆合成錯字，2026-10-19）：錯 3 處時正確答案在前 20 名只有 21.7%（單詞）／13.1%（兩詞）；兩個詞連打錯 1 處，前 20 名卡在 91.2%，與修正上限無關。

## Example

| 按鍵 | 想打的 | 之前 | 之後 |
| --- | --- | --- | --- |
| `u t;3xjig6` | 一場落實 | 不在前 5 | 前 3（每格保留 2 條路徑） |
| `ao6vu;3q2lr3`（錯 3 處） | 沒想到 | 沒想導 | 停頓後變為第一名「沒想到」 |

## Behavior

1. **多路徑**：中文 DP 每個（位置、已用修正數）保留分數最高的 2 條路徑（同樣文字只留最高分），句子候選從全部保留的路徑產生。
2. **停頓後的深度搜尋**：`decode(deep: true)` 在 6–24 鍵的輸入、且所有真正候選都用滿修正上限（或沒有候選）時，以上限 +1 重試一次；第 3 次修正不得是「漏按」（漏按最多 1 次）。只在打字停頓 150 ms 後執行（`CompositionSession.deepen()`），每個 buffer 最多一次，不在每鍵的同步路徑上。
3. **IME 停頓順序**：停頓 150 ms → 深度搜尋 →（若開啟）decision model。新按鍵取消尚未執行的步驟。

## Acceptance

### Behavior
- R1：具名測試：`ao6vu;3q2lr3` 一般解碼不在前 5，`deepen()` 後第一名為「沒想到」；同一 buffer 不重複深化。
- R3：見 case `two-phrases-runner-up-path`（兩列）。
- R4：見 case `single-phrase-unchanged`。

### Failure and retry
- R2：具名測試：短輸入（`123`）與已有精確解的輸入（`su3cl3ji3`）`deepen()` 不改變任何結果。
- R5：Spec 001–005 的所有 case row 與具名測試不變（深度搜尋只在 `deep: true` 時發生）。

### Budget
- R6：[measure] 同一負載下與 Spec 005 輪流量測（2026-10-19，load average 7–10）：長句每鍵 p95 15.1–16.0 ms（Spec 005：13.3–15.0）、混合句 9.8–10.3 ms（8.8–9.0）、M1 2.8–2.9 ms（2.6）。每格 3 條路徑時長句為 17.0 ms，超出預算，故用 2。
- R7：[measure] 召回（`docs/specs/006-recall/evidence/recall.txt`）：錯 3 處前 20 名 21.7% → 58.8%（單詞）、13.1% → 64.0%（兩詞）；兩詞錯 1 處前 5 名 91.2% → 94.8%。

### Observability
- R8：[manual] `TAIPO_DEEP=1 taipo batch` 可在命令列比較深度搜尋的結果。

## Test plan

<!-- test-plan:start Tests/TaipoCoreTests/Cases/recall-cases.json -->
| ID | Case | Input | Prev | Learn first | Expect |
| --- | --- | --- | --- | --- | --- |
| R3 | two-phrases-runner-up-path | `u␣t;3xjig6` | — | — | top3 ∋ 一場落實 |
| R3 | two-phrases-runner-up-path-2 | `ek42u4g4g6g4;` | — | — | top3 ∋ 各地事實上 |
| R4 | single-phrase-unchanged | `su3cl3` | — | — | top1 = 你好 |
<!-- test-plan:end -->

## 簡化審查

1. **質疑需求**：多路徑（兩詞連打的缺口）、深度搜尋（錯 3 處的缺口）。
2. **刪除**：學出來的按鍵 embedding（量測顯示便宜做法已補回大半，先不做）；每鍵同步重試（實測長句 25–99 ms）；「只在沒候選時重試」（同樣慢且召回較差）。
3. **簡化**：重試只多 1 次修正、漏按最多 1 次。
4. **縮短驗證週期**：召回語料與 `taipo batch` 可在一分鐘內重跑。
5. **自動化**：無。

## Non-goals

- 學出來的按鍵 embedding（若錯 3 處以上的需求變重要再評估）。
- 深度搜尋在 decision model 評估語料上的效果（之後量）。
