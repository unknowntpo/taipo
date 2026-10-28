# Spec 007: 即時檢視（live inspector）

Status: Draft（2026-10-19，依使用者要求；待 human 審查）
Date: 2026-10-19
Traceability: enforced
Builds on: Spec 002–006

## Intent

使用者在任何 App 用 Taipo 打字時，可以在 Taipo App 的「即時檢視」分頁看到它如何挑字：按鍵與對應的注音、每個候選的引擎分數與修正、停頓後的深度搜尋、decision model 的 LM 分數與選擇，以及每一步花的時間。

## Evidence

使用者要求「比較視覺化的方法，讓我知道它怎麼挑選字」（2026-10-19）；目前只能用 `log stream` 看文字 log。

## Behavior

1. **事件**：IME 在每次按鍵（解碼）、停頓後深度搜尋、decision model 決定、送出文字時，各送一個 `InspectorEvent`：按鍵、最多 8 個候選（文字、語言、來源、引擎分數、修正、詞段、LM 分數）、選中的索引、耗時、備註。
2. **通道**：本機 distributed notification（JSON）。
3. **開關**：`inspectorEnabled`（與 decision model 同一個 preferences domain），預設關閉；關閉時 IME 完全不送事件。App 的開關文字明示「打的字會即時傳給這個 App」。
4. **畫面**：按鍵畫成大千鍵帽（鍵＋注音符號）；候選以長條顯示引擎分數（藍）與 LM 分數（綠），長度為該分數在畫面上最低與最高分之間的位置；時間軸保留最近 60 個事件。
5. **App 啟動即接收**：資料模型由 App 持有，不必先切到分頁。

## Acceptance

### Behavior
- V1：具名測試：事件經 userInfo 往返不失真，−∞（原文）以「無分數」傳送。
- V4：具名測試：DecisionCoordinator 把 decider 的分數、選擇、耗時交給 `onDecision`。
- V5：具名測試：每個大千鍵都有注音標籤。
- V6：[manual] 打開開關，在 TextEdit 用 Taipo 打 `suecl3`，即時檢視出現鍵帽、候選長條與時間軸。

### Failure and retry
- V2：具名測試：開關關閉時不送任何事件（同一路徑正向對照）。
- V3：具名測試：開關預設關閉，可在 preferences domain 往返。
- V7：收到無法解析的通知 → 忽略（`InspectorEvent(userInfo:)` 回傳 nil，V1 測試涵蓋格式）。

### Budget
- V8：[measure] 開關開啟時每鍵額外成本為一次 JSON 編碼與通知送出；未量測，關閉時為零（V2）。

### Observability
- V9：[manual] 即時檢視本身即為觀測工具。

## 簡化審查

1. **質疑需求**：鍵帽（大千鍵位與注音的對應是除錯時最常要查的）、兩種分數長條（引擎與模型的分歧是使用者想看的重點）、時間軸（看出哪一步改了第一名）。
2. **刪除**：網頁版、遠端傳送、持久化記錄（隱私）；完整 trie 搜尋過程的視覺化。
3. **簡化**：沿用 distributed notification，不另開 socket。
4. **縮短驗證週期**：事件格式與開關都有單元測試，不需要啟動輸入法。
5. **自動化**：無。

## Non-goals

- 記錄到檔案、跨機器傳送。
- 顯示被模糊 walk 剪掉的路徑。
