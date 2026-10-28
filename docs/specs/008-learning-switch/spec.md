# Spec 008: 「記住我的選擇」開關

Status: Accepted（2026-10-19，使用者同意只做此開關）
Date: 2026-10-19
Traceability: enforced
Builds on: Spec 001 B7、Spec 002 I7、Spec 007

## Intent

使用者可以關掉學習：關閉後，選了非第一名的候選既不影響之後的排序，也不寫入 `user.json`。

## Evidence

2026-10-19 檢查發現 `user.json` 存了 10 筆使用者實際打的句子（例如整段組字），且沒有開關可以停止記錄。

## Behavior

1. `learningEnabled` 存在與其他開關相同的 preferences domain，**預設開啟**（保持既有行為）。
2. 關閉時，`CompositionSession` 送出非第一名候選時不呼叫 `Decoder.learn`：不更新記憶體，也不寫檔。
3. Taipo App「設定」分頁加入「記住我的選擇」開關與說明；切換立即生效。
4. 測試一律注入開關值，不讀機器上的真實設定。

## Acceptance

### Behavior
- P1：具名測試：預設開啟，可在 preferences domain 往返。
- P2：具名測試：關閉時選 `up␣` ↓ Enter 後，再打 `up␣` 仍是「因」，且沒有 `user.json`。
- P3：具名測試（正向對照）：開啟時同樣操作會記住「音」並寫檔。
- P4：[manual] 在 Taipo App 關掉開關後，在 TextEdit 選非第一名，`~/Library/Application Support/Taipo/user.json` 不出現。

### Failure and retry
- P5：本機真實設定為關閉時，既有 session 測試仍通過（測試注入 `isLearningEnabled: { true }`，見 `makeSession`）。[manual]

### Budget
- 不適用：每次送出多一次 preferences 讀取。

### Observability
- 不適用：開關狀態顯示在 App。

## Non-goals

- 只學短輸入、清除紀錄按鈕（使用者這次未要求）。
