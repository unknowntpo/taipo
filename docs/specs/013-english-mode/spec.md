# Spec 013: 英數模式（單按左 Shift 切換）

Status: Accepted（2026-10-26，使用者要求在 Taipo 內按一個鍵暫停組字）
Date: 2026-10-26
Traceability: enforced
Builds on: Spec 002（輸入法殼）

## Intent

在 IntelliJ（IdeaVim）等需要單鍵指令的地方，使用者不用切換輸入法，單按一下左 Shift 就讓 Taipo 暫停組字，所有按鍵直接交給 App；再按一下左 Shift 回到注音。

## Evidence

2026-10-26：IdeaVim normal mode 的 `j`、`k` 被 Taipo 組字吃掉（IdeaVim 在 normal mode 丟棄組字中文字）。系統的「Caps Lock 切換拉丁輸入方式」在 Taipo 下不會切換，使用者回報。

## Example

| 狀態 | 按鍵 | 結果 |
| --- | --- | --- |
| 注音模式 | `ji3` | 組字「我」 |
| 注音模式，組字中「我」 | 單按左 Shift | 送出「我」，切到英數模式，游標旁短暫顯示「A」 |
| 英數模式 | `j` `k` | IntelliJ 收到 `j`、`k`，游標上下移動 |
| 英數模式 | 單按左 Shift | 切回注音模式，短暫顯示「注」 |
| 任一模式 | Shift＋`a` | 不切換（大寫 A 照舊） |
| 任一模式 | 單按右 Shift | 不切換（右 Shift 留給 Spec 012 語音輸入） |

## Behavior

1. **單按左 Shift**：左 Shift 按下後 0.5 秒內放開，且期間沒有按其他鍵或其他修飾鍵（含右 Shift），視為一次切換。按住 Shift 打字、按太久都不切換。只有左 Shift 會切換（右 Shift 留給 Spec 012 語音輸入）。
   - 2026-10-26 使用者決定：Spec 012 語音輸入改用右 Shift 觸發，本功能改為只認左 Shift，兩者不衝突。原本左右 Shift 皆可。
2. **切換時**：若有組字，先送出目前顯示的候選（不學習，同 Spec 002 失焦送出），再切換。
3. **英數模式**：所有按鍵都不攔截，原樣交給 App；不組字、不學習。
4. **狀態**：整個輸入法共用一個模式（換 App 不重置），重新啟動輸入法回到注音模式。
5. **提示**：切換後在游標附近顯示「A」或「注」約 0.8 秒；取不到游標位置時不顯示。

## Acceptance

### Behavior
- E1：具名測試：單按偵測——0.5 秒內按放算一次；超過 0.5 秒、期間按了其他鍵、或同時有其他修飾鍵（含右 Shift）都不算；只有左 Shift 算，右 Shift 不切換（右 Shift 留給 Spec 012 語音輸入）。
- E2：具名測試：英數模式下 `ji3`、空白、Enter、Backspace 全部不攔截，且不產生組字（正向對照：注音模式下 `ji3` 被攔截並組字）。
- E3：具名測試：組字中切換會先送出目前候選，且不寫入使用者詞庫。
- E4：具名測試：再切一次回到注音模式後 `ji3` 照常組字。
- E5：[manual] 在 IntelliJ normal mode：單按 Shift 後 `j`、`k` 移動游標；再單按 Shift 後能打中文。
  - 2026-10-26 使用者在 IntelliJ 確認通過（當時左右 Shift 皆可；使用者用左／任一 Shift 驗證）。

### Failure and retry
- E6：[manual] 取不到游標位置的 App（例如部分 Electron App）切換仍生效，只是不顯示提示。

### Budget
- 不適用：每個按鍵多一次布林判斷。

### Observability
- 不適用：提示本身。

## 簡化審查

1. **質疑需求**：使用者直接要求；IdeaVimExtension 需要外掛且 Caps Lock 切換對 Taipo 無效。
2. **刪除**：不做每個 App 各自記憶模式、不做選單列圖示切換、不做可自訂按鍵。
3. **簡化**：模式放在 `CompositionSession`；單按偵測是無 AppKit 的小狀態機，可單元測試。
4. **縮短驗證週期**：E1–E4 單元測試；真機只驗 E5、E6。
5. **自動化**：無新增。

## Non-goals

- 修好系統 Caps Lock 切換（另查原因）。
- 選單列顯示目前模式。
