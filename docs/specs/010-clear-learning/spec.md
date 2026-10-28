# Spec 010: 清除學習紀錄

Status: Accepted（2026-10-24，使用者要求加清除按鈕）
Date: 2026-10-24
Traceability: enforced
Builds on: Spec 001 B7、Spec 008

## Intent

使用者可以在 Taipo App 一鍵清除學過的選擇（`user.json`），清除後輸入法立即回到沒學過的排序，不需重新啟動。

## Evidence

2026-10-24 使用者要求加清除按鈕。當天 `~/Library/Application Support/Taipo/user.json` 有 12 筆選擇、3 個新詞，先前只能手動把檔案移到垃圾桶再 `pkill -x Taipo`。

## Example

學過 `up␣` → 音之後：

| 動作 | `up␣` 第一名 | `user.json` |
| --- | --- | --- |
| 清除前 | 音（學過） | 存在 |
| 按「清除學習紀錄」並確認 | 因（引擎原本的第一名） | 移到垃圾桶 |

## Behavior

1. Taipo App「學習」區塊顯示目前筆數（選擇＋新詞），並有「清除學習紀錄…」按鈕；按下先跳確認，確認後才清除。沒有紀錄時按鈕停用。
2. 清除＝把 `user.json` **移到垃圾桶**（可復原，不永久刪除），再送出分散式通知 `com.unknowntpo.inputmethod.Taipo.userDictionaryCleared`。
3. 檔案不存在時仍送出通知（輸入法記憶體裡可能還有紀錄）。輸入法收到通知後清空記憶體中的使用者詞庫（`Decoder.clearUserDictionary()`），並再把 `user.json` 移到垃圾桶一次（若清除與學習同時發生，檔案可能被舊內容寫回）。
4. `Decoder.clearUserDictionary()` 只清記憶體，不碰檔案；檔案由呼叫端處理。
5. 檔案路徑由 `UserDictionaryStore.defaultURL` 統一提供，輸入法與 App 共用。

## Acceptance

### Behavior
- U1：具名測試：學過 `up␣` → 音之後呼叫 `clearUserDictionary()`，`up␣` 第一名回到「因」；之後再學仍可運作。
- U2：具名測試：`UserDictionaryStore.entryCount` 回報選擇＋新詞數；檔案不存在時為 0。
- U3：具名測試：`UserDictionaryStore.clear` 呼叫注入的移除動作（預設是移到垃圾桶）並送出通知；檔案不存在時不呼叫移除、回傳 false，但仍送出通知。
- U4：[manual] 在 Taipo App 按清除並確認後，`user.json` 出現在垃圾桶；在 TextEdit 打 `up␣` 第一名是「因」，不需重啟輸入法。

### Failure and retry
- U5：具名測試：移除失敗時 `clear` 丟出錯誤、不送通知（App 顯示錯誤，紀錄保持原樣）。

### Budget
- 不適用：只在使用者按下時執行一次。

### Observability
- 不適用：筆數與錯誤顯示在 App。

## 簡化審查

1. **質疑需求**：使用者直接要求；Spec 008 已把它列為 non-goal，這次明確要求。
2. **刪除**：不做逐筆刪除、匯出、復原按鈕（垃圾桶本身就能復原）。
3. **簡化**：沿用 Spec 004 的分散式通知模式；移除動作可注入，測試不碰真正的垃圾桶。
4. **縮短驗證週期**：Decoder 與 store 都是單元測試，只有 App 按鈕是 manual。
5. **自動化**：無新增。

## Non-goals

- 逐筆檢視或刪除紀錄、只學短輸入（使用者未要求）。
- iOS 鍵盤的清除按鈕（Spec 009 另議）。
