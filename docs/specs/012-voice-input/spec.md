# Spec 012: 語音輸入 MVP（macOS）

Status: Accepted（2026-10-26，使用者審過：觸發鍵改右 Command、贅字只刪三個；同日再改為右 Shift，見 Behavior 1；同日改用浮動條顯示狀態，見 Behavior 8；同日加入免持模式、拿掉 ✓、浮動條改版，見 Behavior 1、8）
Date: 2026-10-26
Traceability: enforced
Builds on: Spec 002（輸入法殼）、Spec 011（評測：Breeze-ASR-25 真人錄音 MER 4.9%）

## Intent

使用者在任何 App 打字時，按住一個鍵說話、放開後，說的話以繁體中文（中英夾雜）出現在游標處。全部在本機執行，不存音檔。

## Evidence

Spec 011 真人錄音 30 句：Breeze-ASR-25 MER 4.9%（apple 14.9%、qwen3-0.6b s2twp 後 10.4%），M1 Pro 平均 1.23 秒／句。使用者 2026-10-26 決定用 Breeze。

## Example

在 TextEdit、輸入法為 Taipo：

1. 按住右 Shift，螢幕底部中央淡入浮動條：左 ✕、右邊 9 條灰色細條（等待麥克風），聲音進來後細條隨聲音跳動。
2. 說「這個 API 的 timeout 有點 short」，放開右 Shift，浮動條變寬，顯示轉圈與「Thinking…」（2026-10-26 使用者要求，同 Typeless）。
3. 約 1–2 秒後送出「這個 API 的 timeout 有點 short」到游標處，浮動條淡出。
4. 免持：單獨點一下右 Shift 開始錄音，放開手說話；說完再點一下右 Shift，同樣辨識並送出。

## Behavior

1. **觸發**：輸入法為 Taipo 且焦點在文字欄位時，**單獨**按住右 Shift 開始錄音、放開結束（按住說話）。錄音中按 Esc 取消。組字中開始錄音時，先送出目前組字。
   - 免持（2026-10-26 使用者決定，參考 Typeless、Handy 的 HoldOrToggle）：**單獨**點一下右 Shift（按下到放開少於 0.3 秒，中間沒有其他按鍵或修飾鍵）開始錄音，放開不結束；再單獨點一下右 Shift，放開時結束並辨識，與按住說話放開時相同。Esc 或 ✕ 取消。免持錄音中按任何其他鍵：丟棄錄音，按鍵照常傳給 App。60 秒上限同樣適用。取代原本「按住少於 0.3 秒視為誤觸，不錄」。
   - 按住 0.3 秒以上維持按住說話：放開即結束。
   - 按住右 Shift 時按了任何其他鍵（例如打大寫字母 Shift+A，或 ⇧⌘C），視為一般按鍵或快捷鍵：丟棄錄音，按鍵照常傳給 App。所以用右 Shift 打大寫照常運作（0.3 秒內按下字母時尚未開始錄音）。
   - 按右 Shift 時已按住其他修飾鍵（Command、Control、Option、左 Shift、fn），不算觸發。
   - 輸入法只觀察 `flagsChanged`，從不吃掉右 Shift 本身，App 的修飾鍵狀態維持正確。
   - 理由：輸入法本來就收得到按鍵（`flagsChanged`），不需要「輔助使用」權限；左 Shift 留給 Spec 013 英文模式切換。
   - 2026-10-26 使用者改為右 Shift：右 Command 在使用者 Mac 上無反應（原因未查）。
2. **錄音**：在輸入法程式內以 16 kHz mono 錄進記憶體，最長 60 秒（到時自動結束）。音檔不寫入磁碟。第一次使用時系統會詢問麥克風權限（Info.plist 加 `NSMicrophoneUsageDescription`）。
3. **辨識**：Breeze-ASR-25，語言固定 zh。輸入法程式內以 Swift 呼叫，不依賴 Python。
   - 執行環境在 slice 1 決定：比較 whisper.cpp（Metal，Breeze GGML）與 WhisperKit（CoreML，以 whisperkittools 轉換），用 Spec 011 工具在使用者 30 句錄音上量測，選符合下方 Budget 且 MER 較低者。
   - 已決定（2026-10-26，W4）：whisper.cpp（Metal），模型 Breeze-ASR-25 GGML q5_0。
4. **後處理**：去掉句首句尾的空白；刪除獨立的贅字「嗯」「呃」「欸」。不處理重說（「這間咖啡這家咖啡店」）。
5. **送出**：辨識結果以一般送出（`insertText`，`replacementRange` 為 `{NSNotFound, 0}`）插入游標處；結果為空字串時什麼都不送，浮動條消失。
6. **開關與模型**：Taipo App「語音輸入」區塊：開關（預設關閉）、模型狀態與「下載模型」按鈕（下載到 `~/Library/Application Support/Taipo/models/`）。模型未安裝或開關關閉時，右 Shift 照常傳給 App。
7. **失敗**：麥克風被拒、模型載入失敗、辨識逾時（> 10 秒）時，浮動條顯示一行錯誤 2 秒後消失，不送出任何文字，鍵盤輸入照常運作。
8. **浮動條**（2026-10-26 使用者要求，參考 Typeless）：語音輸入的狀態只顯示在浮動條，不再使用組字區（不呼叫 `setMarkedText`）。
   - 外觀（2026-10-26 改版，參考 Handy RecordingOverlay，MIT）：膠囊高 40 pt、圓角 20 pt；平面底色跟隨系統淺色／深色外觀，1 px 細邊框，無陰影；左 ✕ 圓鈕，右邊 9 條波形細條。出現與消失各淡入淡出約 200 ms；淡出結束才收起面板，且只在淡出之後沒有新的顯示時收起（W18）。任何顯示與隱藏的順序之後，顯示都讓浮動條完全不透明，隱藏都讓面板收起；標記為顯示但不在畫面上或不透明度不足時，下一次顯示會重新淡入（W25）。
   - 位置：游標所在螢幕（取不到時用滑鼠所在螢幕）的底部中央，可見範圍底邊往上 15 pt（Dock 之上）。
   - 視窗：無邊框、不啟用（non-activating）的 `NSPanel`，絕不搶走 App 的焦點；層級高於一般視窗；出現在所有桌面空間；不參與 Mission Control。
   - 狀態：錄音開始到第一批麥克風音訊之前為「準備中」：細條為淡灰色，一道脈衝由左往右移動（W16）。之後細條為即時音量：每 512 個樣本（32 ms）一幀，Hann 窗後做 DFT（vDSP），400–4000 Hz 分成 9 段（越高頻越寬），每段平均功率換成 dB，-68 dB 為 0、-30 dB 為 1，再 ×1.3、^0.7，限制在 0…1，內側每段混入左右各 15%（W13），最多每秒 30 次；顯示前每段做指數平滑：前值 ×0.7 + 新值 ×0.3，每次錄音從 0 開始（W17）。辨識中膠囊平滑變寬，顯示轉圈與「辨識中…」；失敗時顯示一行錯誤 2 秒；成功或取消時淡出。按住右 Shift 未滿 0.3 秒時不出現。
   - ✕：取消（錄音中丟棄音訊；辨識中丟棄結果），不送字。
   - 2026-10-26 使用者決定拿掉 ✓：放開右 Shift（免持時再點一下）就是完成。
   - 理由：使用者 2026-10-26 回報 Claude Desktop（Electron）中組字區既不顯示「🎙 聆聽中…」也收不到文字（Raycast 正常）。不再設定組字區可能就修好此問題，但未在真機驗證；W15 以紀錄確認。
   - 2026-10-26：W15 已通過。實際原因是 Electron 每次右 Shift 送兩次 flagsChanged；忽略重複事件後可用（見 W1）。
9. **紀錄**：os Logger（subsystem `com.unknowntpo.inputmethod.Taipo`，category `voice`）在觸發按下／放開、錄音開始／結束（樣本數）、辨識完成（秒數、字數）、送出（client bundle id、`client()` 是否為 nil）各記一筆 notice。只記非內容資訊，不記辨識文字或音訊。

## Acceptance

### Behavior
- W1：具名測試：右 Shift 單獨按下／放開的判定（其他修飾鍵按住時不算觸發）；按住／放開的狀態機（Esc 取消、按住時按其他鍵即丟棄錄音並放行該鍵、右 Shift 加字母打大寫時字母照常傳給 App、組字中先送出組字、60 秒上限）。
  - 2026-10-26：Claude Desktop（Electron）把每次右 Shift 的 flagsChanged 送兩次；重複的按下／放開不改變狀態（有具名測試）。
  - 2026-10-26：「短於 0.3 秒不錄」改為免持模式（W20–W24），其測試已移除。
- W2：具名測試：後處理刪除獨立贅字、保留詞中的字（「嗯哼」不在清單內則保留）、空結果不送出。
- W3：具名測試：開關關閉或模型未安裝時右 Shift 不被攔截。
- W4：[measure] slice 1 執行環境比較：兩種執行環境在使用者 30 句上的 MER 與每句延遲，記錄於本 spec。
  - 2026-10-26，M1 Pro 32 GB、使用者 30 句（`scripts/asr/run_breeze_cpp.py`、`run_breeze_whisperkit.py` → `swift run taipo-asr score`）。兩者都以引擎自帶的本機 server 載入一次模型、每句一次請求；延遲為每句辨識牆鐘秒數（不含載入，含數 ms 本機 HTTP）；記憶體為 `/usr/bin/time -l` 量到的整個 server 程序峰值。語言 zh、無提示詞、greedy（溫度 0，預設 fallback）。

    | 執行環境 | MER | s2twp MER | p50 / p95 秒 | 載入秒 | 峰值 RSS | 模型大小 |
    |---|---|---|---|---|---|---|
    | whisper.cpp 1.9.5（Homebrew `whisper-server`，Metal + flash attention，4 threads），shdennlin/breeze-asr-25-ggml q5_0 | 6.1% | 7.3% | 1.31 / 1.38 | 0.8 | 1.49 GiB（1.61 GB） | 1.08 GB |
    | WhisperKit 1.1.1（`whisperkit-cli serve`，encoder/decoder 皆 cpuAndNeuralEngine），fredchu/breeze-asr-25-whisperkit-coreml 4-bit palettized | 6.1% | 7.3% | 2.13 / 2.61 | 4.1（首次 954，ANE 編譯） | 0.48 GiB（ANE 端記憶體未計入，未驗證） | 1.05 GB |
    | 參考：whisper.cpp q4_0 | 7.9% | 8.8% | 1.14 / 1.20 | 0.7 | 1.31 GiB（1.41 GB） | 0.89 GB |
    | 參考：WhisperKit 同模型，cpuAndGPU | 6.1% | 7.3% | 6.49 / 7.83 | 78 | 5.17 GiB | 1.05 GB |
    | 參考：Spec 011 breeze（mlx-whisper 5-bit，Python） | 4.9% | 6.1% | 平均 1.23 | — | — | 1.07 GB |

    - 建議：**whisper.cpp（Metal，q5_0）**。MER 兩者同為 6.1%；WhisperKit 單是辨識 p50 2.13 秒已超過 W8 的 1.5 秒，且首次載入需約 16 分鐘 ANE 編譯。whisper.cpp 辨識 p50 1.31 秒，端到端只剩約 0.2 秒餘裕（W8 待 slice 2 實測）；W9 峰值 1.49 GiB 若預算以 GiB 計剛好符合、以 10⁹ bytes 計超出 0.11 GB（改用 q4_0 為 1.41 GB，MER 升到 7.9%）。2026-10-26 使用者決定：採用 whisper.cpp q5_0，W9 預算以 GiB 計。
    - Slice 2（2026-10-26，同機同 30 句）：輸入法用的程序內執行環境（whisper.cpp `b5454` XCFramework，Metal + flash attention，4 threads，`swift run -c release taipo-asr transcribe --engine taipo-asr`）MER 6.4%、s2twp 7.6%、平均 1.33 秒／句，整個程序峰值 RSS 1.46 GiB（1.57 GB）。每次程序啟動時 Metal 編譯 flash attention kernel 約 15 秒（`whisper.cpp` 1.9.5 Homebrew 為 0.8 秒）；關掉 flash attention 載入 1.2 秒，但平均 1.75 秒／句、MER 5.2%。採用 flash attention：輸入法在開關開啟時於背景先載入模型，這 15 秒只在輸入法程序啟動後發生一次。
    - Swift 整合：whisper.cpp 為 MIT，C API（`whisper_full`），repo 已無 `Package.swift`；官方 XCFramework 只附在部分 build tag release（最近為 `b5454`，2026-10-06，`whisper-b5454-xcframework.zip`），以 SwiftPM `binaryTarget` 引入，或用 repo 的 `build-xcframework.sh` 自建。WhisperKit 為 MIT 的 SwiftPM 套件。兩個模型轉換與 Breeze-ASR-25 本體皆 Apache-2.0。
- W5：[manual] 在 TextEdit、IntelliJ、Safari 輸入框各說 3 句，文字出現在游標處；測試前後 `~/Library` 下新增的 `.wav` 為 0（評測資料夾除外）。
- W11：具名測試：浮動條狀態由 `VoiceSession` 推導：錄音開始 arming → 有音量後 listening(各段音量) → 放開後 recognizing → 送出後 hidden；失敗為 error 2 秒後 hidden；按住未滿 0.3 秒不出現；音量只在錄音中更新浮動條。
- W12：具名測試：✕ 在錄音中取消（麥克風停止、不辨識、不送字、浮動條消失）、在辨識中丟棄結果。
  - 2026-10-26：✓ 已拿掉，其兩個測試一併移除（`VoiceSession.finish()` 也已刪除）。
- W13：具名測試：各段音量（`VoiceSpectrum`）：靜音每段為 0；滿 512 個樣本才產生一幀（511 不產生、第 512 個產生）；500 Hz、1 kHz、3 kHz 正弦波的能量在對應的第 1、3、7 段，相隔兩段以上接近 0；dB 對應 -68…-30 → 0…1、×1.3、^0.7、限制範圍（兩端與飽和點兩側各一）；鄰段混合；節流：距上次更新未滿 1/30 秒不更新（邊界兩側各一）。
  - 2026-10-26：原本的 RMS 單一音量改為 9 段頻帶音量（參考 Handy，MIT，以 Accelerate 重寫）。
- W14：[manual] 浮動條外觀與焦點：在 TextEdit 按住右 Shift，浮動條出現在底部中央，波形隨聲音動，放開後轉圈，送字後消失；按 ✕ 後原 App 仍是前景、游標仍在、可繼續打字；切換桌面空間時浮動條仍在。
- W16：具名測試：錄音開始時浮動條為 arming，沒有音量進來就一直是 arming；第一批音量進來後改為 listening。
- W17：具名測試：各段平滑為前值 ×0.7 + 新值 ×0.3；每次錄音從 0 開始（第二次錄音再次 arming）。
- W18：具名測試：淡出完成時，若之後有新的顯示，不收起面板；沒有則收起；兩次淡出以後者為準。
- W19：[manual] 浮動條新外觀：高約 40 pt 的平面膠囊、細邊框、無陰影，淺色與深色外觀下都跟隨系統；出現與消失有淡入淡出；開始錄音先看到灰色細條與移動的脈衝，說話後 9 條細條跳動；放開後膠囊平滑變寬，顯示轉圈與「辨識中…」；錯誤一行 2 秒；位置在游標所在螢幕底部中央、Dock 之上；連續快速錄兩次時，第二次的浮動條不會被第一次的淡出收掉。
- W20：具名測試：單獨點一下右 Shift 開始免持錄音並顯示浮動條；放開後繼續錄音。
- W21：具名測試：免持錄音中再單獨點一下右 Shift，放開時結束、辨識並送字（按下時尚未結束）；免持錄音 60 秒自動結束並辨識。
- W22：具名測試：重複事件（按下、按下、放開、放開）只算一次點擊，開始與結束都是。
- W23：具名測試：免持錄音中按其他鍵（含再按右 Shift 後打大寫字母）：丟棄錄音，按鍵照常傳給 App，之後放開右 Shift 不會再開始錄音。
- W24：具名測試：免持錄音中按 Esc 或 ✕ 取消：丟棄音訊、不送字、浮動條消失；之後點一下可再開始（正向對照）。
- W25：具名測試：淡出途中再顯示：顯示會淡入，淡出結束時恢復浮動條（不收起、不留透明）；標記為顯示但透明或已收起時，再顯示會重新淡入；正向對照：已顯示且不透明時只更新內容，重複隱藏不做事。
  - 2026-10-27：修正浮動條消失後要重開輸入法才會再出現（面板在畫面上但 alpha 為 0，錄音時也不恢復）。淡入淡出改由輸入法自己逐格設定視窗 alpha，新的淡入或淡出會取消進行中的那一個，最後一次顯示或隱藏決定結果。

### Failure and retry
- W6：具名測試：辨識丟錯或逾時 → 不送出文字、顯示錯誤、之後按鍵正常（正向對照：成功時有送出）。
- W7：[manual] 拒絕麥克風權限後按右 Shift：顯示錯誤，打字不受影響。

### Budget
- W8：[measure] 放開右 Shift 到文字送出，5 秒以內的句子 p50 ≤ 1.5 秒、p95 ≤ 3 秒（M1 Pro）。
- W9：[measure] 語音輸入開啟後輸入法常駐記憶體增加 ≤ 1.5 GiB；開關關閉時不載入模型。

### Observability
- W10：[manual] Taipo App 的即時檢視（Spec 007，開啟時）顯示每次語音輸入的音長、辨識秒數與結果。
- W15：[manual] Claude Desktop（Electron）：按住右 Shift 說一句，文字出現在游標處。若沒有，以 `log stream --level info --predicate 'subsystem == "com.unknowntpo.inputmethod.Taipo" AND category == "voice"'` 的紀錄判斷停在哪一步（觸發、錄音、辨識、送出），紀錄中不出現辨識文字。
  - 2026-10-26：通過。使用者在 Claude Desktop 與 Raycast 以語音輸入訊息成功（忽略重複的 flagsChanged 之後）。

## 簡化審查

1. **質疑需求**：使用者要語音輸入；觸發鍵、贅字處理是 Typeless 類產品的基本體驗。
2. **刪除**：不做串流（邊講邊出字）、不做回饋迴路與個人詞庫提示（Spec 013）、不做重說清理、不做 LLM 改寫、不做 iOS。
3. **簡化**：沿用輸入法程式收按鍵與送字，不另開常駐 App、不要求輔助使用權限；模型與開關沿用 Spec 004 的 Taipo App 設定模式。
4. **縮短驗證週期**：狀態機、後處理、失敗路徑都用假的錄音與辨識器做單元測試；真機只驗 W5、W7。
5. **自動化**：W4、W8 用 Spec 011 的 taipo-asr 加一個引擎名稱量測。

## Non-goals

- 串流辨識、回饋迴路（Spec 013：個人詞庫 → 提示詞、修正擷取）。
- 多說話者回歸測試集（已列待辦，Spec 013 之前完成）。
- 輸入法不是 Taipo 時的全域快捷鍵。
