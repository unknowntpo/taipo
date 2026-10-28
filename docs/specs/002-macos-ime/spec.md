# Spec 002: macOS 輸入法殼

Status: Accepted provisionally（2026-10-17：使用者要求「做到可以直接在 MacBook 上試用」；human 尚未審查本 spec）
Date: 2026-10-17
Traceability: enforced
Builds on: Spec 001

## Intent

讓使用者在任何 macOS App 裡選用「Taipo」輸入法，用大千注音或英文直接打字，不按切換鍵；打錯鄰近鍵時，候選窗第一名仍是想要的字，選過的字下次排第一。

## Evidence

- Spec 001 引擎已能在 2.5 ms 內產生候選（M1），但只能從 CLI 使用。
- 使用者要在自己的 MacBook 上直接試用（2026-10-17）。

## Example

以 Spec 001 的實際輸出（2026-10-17）推演一次輸入：

| 按鍵 | buffer | 組字區（marked text） | 候選窗 | 送出 |
| --- | --- | --- | --- | --- |
| `j` `i` | `ji` | ji | ji | — |
| `3` | `ji3` | 我 | 我、婐、捰… | — |
| `Enter` | — | — | — | 我 |
| `h` `r` `l` `l` `o` | `hrllo` | hello | hello、hrllo | — |
| `Space` | — | — | — | `hello␣` |
| `u` `p` `Space` | `up␣` | 因 | 因、音、陰… | —（空白當一聲） |
| `↓` `Enter` | — | — | — | 音（並學習 `up␣`→音） |
| `u` `p` `Space` | `up␣` | 音 | 音、因… | — |

## Behavior

1. **組字狀態機**：純 Swift 的 `CompositionSession`（library `TaipoIME`，不依賴 AppKit）處理按鍵並回傳「是否吃掉這個鍵」與「要送出的文字」；InputMethodKit controller 只做轉接。由 verifier 與單元測試使用。
2. **輸入鍵**：無 ⌘／⌃／⌥ 修飾的 `a–z`、`A–Z`、`0–9`、`,` `.` `;` `/` `-` 加入 buffer；每次變動都重算候選，選擇回到第一名；組字區顯示目前選中的候選。
3. **空白鍵**：buffer 為空時不處理（交給 App）。否則：若 `buffer + 空白` 的第一名是 0 編輯的中文候選，空白加入 buffer（一聲）；不然送出目前選中的候選，英文候選後面補一個空白，中文不補。
4. **Enter**：buffer 非空時送出選中的候選（不換行）；buffer 為空時交給 App。
5. **Esc**：清空 buffer、不送出；buffer 為空時交給 App。
6. **Backspace**：刪掉 buffer 最後一鍵；buffer 為空時交給 App。
7. **↑／↓**：buffer 非空時移動選擇（不循環）；為空時交給 App。
8. **學習**：送出的候選不是第一名時，呼叫 `Decoder.learn(input: buffer, chosen:)`；送出第一名時不學習。
9. **其他鍵**（如 `!`、`?`、Tab、方向鍵 ←→、任何帶 ⌘／⌃／⌥ 的鍵）：buffer 非空時先送出選中的候選，再把該鍵交給 App。
10. **語言 hint**：每次送出後，把送出候選的語言當作下一次解碼的 `previousLanguage`。
11. **大寫**：buffer 第一鍵為大寫、送出的候選是英文詞庫或使用者詞時，首字母轉大寫。
12. **失焦**：輸入法被切走或 App 失焦時，送出選中的候選。
13. **安裝**：`scripts/install-ime.sh` 建置 `Taipo.app`（ad-hoc 簽章），放到 `~/Library/Input Methods/`。啟用輸入法由使用者在「系統設定」操作。

## Acceptance

### Behavior
- I1：見測試計畫：一般按鍵進 buffer、組字區顯示第一名。
- I2：見測試計畫：空白鍵三種情況（一聲、送出英文加空白、空 buffer 交出）。
- I3：見測試計畫：Enter 送出選中候選；空 buffer 交出。
- I4：見測試計畫：Esc 清空。
- I5：見測試計畫：Backspace。
- I6：見測試計畫：↑↓ 移動選擇且不循環。
- I7：見測試計畫：送出非第一名會學習，第一名不會（同一路徑正向對照）。
- I8：見測試計畫：其他鍵先送出再交出。
- I9：見測試計畫：`previousLanguage` 影響 `up␣`。
- I10：見測試計畫：大寫。
- I11：具名測試：`commitComposition` 送出選中候選並清空。
- I12：[manual] 在 TextEdit 用Taipo打出「我」「hello␣」「音」並看到候選窗。由 human 在 MacBook 上確認。

### Failure and retry
- I13：詞庫載入失敗 → `CompositionSession` 不建立，controller 對所有鍵回傳「不處理」，App 照常收到原始按鍵；`os_log` 記錄錯誤。具名測試驗證 controller 的 fallback 路徑（以 `SessionProvider` 注入失敗）。
- I14：學習寫檔失敗 → 文字照常送出，錯誤記到 `diagnostics`。具名測試。
- I15：buffer 超過 32 鍵 → 組字區顯示原文，可正常送出（Spec 001 F2）。見測試計畫。
- I16：只有數字（如 `123`）→ 送出原文；空白送出 `123␣`。見測試計畫。
- I20：Backspace 刪光 buffer → 組字區與候選清空；再按 Backspace 交給 App。見測試計畫。
- I21：Esc 或繼續打字後，選擇回到第一名，不沿用舊的選擇。見測試計畫。
- I22：學習寫檔失敗後繼續打字仍正常（同 I14 測試的後半）。具名測試。
- I23：候選窗點選超出範圍的 index → 不送出、不改狀態。具名測試。
- I24：在 controller 收到 `nil` event 或非 keyDown event → 不處理。具名測試（`KeyRouter` 層以 `.other` 表示時交出）。
- I25：buffer 為空時的非輸入鍵交給 App，不改 `previousLanguage`。見測試計畫。
- I26：大寫的注音鍵（Caps Lock）不當注音，送出原文。見測試計畫。
- I27：Backspace 可刪掉當一聲用的空白。見測試計畫。
- I28：buffer 為空時，所有控制鍵都交給 App。見測試計畫。
- I29：↓ 超過最後一個後再 ↑，回到前一個。見測試計畫。

### Budget
- I17：[measure] 每次按鍵處理（含解碼）p95 ≤ 16 ms（一個 60 Hz frame）。實測（2026-10-17）：1.91 ms，n=1740。`swift run -c release taipo-bench session`
- I18：[measure] 輸入法 process 啟動到詞庫可用 ≤ 1 s。從 `/usr/bin/log show` 的 `lexicon loaded` 訊息量測。實測：48 ms（直接啟動 `.build/Taipo.app/Contents/MacOS/Taipo`）。

### Observability
- I19：[manual] `log stream --predicate 'subsystem == "com.unknowntpo.inputmethod.Taipo"'` 顯示啟動、詞庫載入時間與錯誤。

## Test plan

<!-- test-plan:start Tests/TaipoIMETests/Cases/session-cases.json -->
| ID | Case | Keys | Expect |
| --- | --- | --- | --- |
| I1 | partial-syllable | `ji` | 組字區 = ji; 送出 = （無）; 最後一鍵被吃掉 |
| I1 | complete-syllable | `ji3` | 組字區 = 我; 送出 = （無） |
| I1 | punctuation-keys-are-zhuyin | `g;4{Enter}s/6{Enter}-6{Enter}x.6` | 組字區 = 樓; 送出 = `上能而` |
| I2 | space-as-tone1 | `up{Space}` | 組字區 = 因; 送出 = （無） |
| I2 | space-commits-english | `hrllo{Space}` | 組字區 = （空）; 送出 = `hello␣` |
| I2 | space-uses-selected-language | `ki3{Down}{Down}{Down}{Down}{Down}{Down}{Down}{Down}{Down}{Down}{Space}` | 送出 = `ki3␣` |
| I2 | space-after-tone-commits-chinese | `ji3{Space}` | 組字區 = （空）; 送出 = `我` |
| I2 | space-empty-passes | `{Space}` | 送出 = （無）; 最後一鍵交給 App |
| I3 | enter-commits | `ji3{Enter}` | 組字區 = （空）; 送出 = `我`; 最後一鍵被吃掉 |
| I3 | enter-empty-passes | `{Enter}` | 最後一鍵交給 App |
| I4 | escape-clears | `ji3{Esc}` | 組字區 = （空）; 送出 = （無）; 最後一鍵被吃掉 |
| I4 | escape-empty-passes | `{Esc}` | 最後一鍵交給 App |
| I5 | backspace-removes-key | `ji3{BS}` | 組字區 = ji; 最後一鍵被吃掉 |
| I5 | backspace-empty-passes | `{BS}` | 最後一鍵交給 App |
| I6 | down-selects-next | `ji3{Down}` | 組字區 = 婐 |
| I6 | up-clamps-at-first | `ji3{Up}` | 組字區 = 我 |
| I6 | down-clamps-at-last | `hrllo{Down}{Down}{Down}` | 組字區 = hrllo |
| I6 | down-empty-passes | `{Down}` | 最後一鍵交給 App |
| I7 | commit-non-first-learns | `up{Space}{Down}{Enter}up{Space}` | 組字區 = 音; 送出 = `音` |
| I7 | commit-first-does-not-learn | `up{Space}{Enter}up{Space}{Down}` | 組字區 = 音; 送出 = `因` |
| I7 | commit-first-adds-no-user-word | `qqqqq{Enter}qqqqw` | 組字區 = qqqqw |
| I8 | other-key-commits-then-passes | `ji3{!}` | 組字區 = （空）; 送出 = `我`; 最後一鍵交給 App |
| I8 | modified-key-commits-then-passes | `hrllo{Cmd+c}` | 組字區 = （空）; 送出 = `hello`; 最後一鍵交給 App |
| I9 | english-context-keeps-english | `hello{Space}up{Space}` | 組字區 = （空）; 送出 = `hello␣up␣` |
| I9 | chinese-context-keeps-zhuyin | `ji3{Enter}up{Space}` | 組字區 = 因; 送出 = `我` |
| I10 | capitalized-english | `Hrllo{Space}` | 送出 = `Hello␣` |
| I10 | capitalized-learned-choice | `Hello{Down}{Enter}{Esc}Hello` | 組字區 = Hell; 送出 = `Hell` |
| I15 | over-max-length-literal | `a×33{Enter}` | 送出 = `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa` |
| I16 | digits-literal | `123{Space}` | 送出 = `123␣` |
| I20 | backspace-to-empty-clears | `ji{BS}{BS}` | 組字區 = （空）; 最後一鍵被吃掉 |
| I20 | backspace-after-empty-passes | `ji{BS}{BS}{BS}` | 最後一鍵交給 App |
| I21 | selection-resets-after-escape | `ji3{Down}{Esc}ji3` | 組字區 = 我 |
| I21 | selection-resets-after-typing | `ji3{Down}{BS}3` | 組字區 = 我 |
| I25 | other-key-empty-passes | `{!}` | 送出 = （無）; 最後一鍵交給 App |
| I26 | uppercase-zhuyin-is-literal | `JI3{Enter}` | 送出 = `JI3` |
| I27 | backspace-removes-tone-space | `up{Space}{BS}` | 組字區 = up |
| I28 | empty-buffer-control-keys-pass | `{Up}{Down}{Esc}{BS}{Enter}{Space}` | 送出 = （無）; 最後一鍵交給 App |
| I29 | up-after-clamp | `hrllo{Down}{Down}{Up}` | 組字區 = hello |
<!-- test-plan:end -->

## 簡化審查

1. **質疑需求**：候選窗（使用者要看到模糊修正的其他選擇）、學習（Spec 001 B7 的入口）、空白當一聲（大千標準操作）、大寫（英文句首）。
2. **刪除**：
   - 數字鍵選字：數字是注音鍵，會衝突，改用 ↑↓＋Enter。
   - 設定畫面、選單、偏好設定。
   - 半形／全形切換、標點轉換（`,` 打出 ㄝ 而非「，」）。
   - 自動送出、聯想詞。
   - 使用者字典的刪除。
3. **簡化**：狀態機與 AppKit 分離，測試不需要啟動輸入法；組字區直接顯示候選，不另做注音符號預覽。
4. **縮短驗證週期**：狀態機用真實詞庫跑 `swift test`；只有 I12、I19 需要人工。
5. **自動化**：安裝腳本最後才寫。

## Non-goals

- 語音輸入（Spec 003）、iOS。
- App Store 上架、notarization、自動更新。
- 中文標點、全形符號、聯想詞。
- 自動啟用輸入法（需要使用者在系統設定操作）。
