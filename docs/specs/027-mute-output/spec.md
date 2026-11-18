# Spec 027: 錄音時把系統聲音靜音

Status: Accepted（2026-11-18，D1 靜音、D2 不加開關、H26 照建議）
Date: 2026-11-18
Traceability: enforced
Builds on: Spec 012（語音輸入）

## Intent

使用者按下語音鍵錄音時，其他 App 正在播放的聲音（音樂、影片、會議）會被麥克風一起收進去，辨識結果因此出錯。

錄音期間，Taipo 把系統預設輸出裝置靜音。錄音結束後，恢復成錄音前的狀態。Taipo 不暫停任何 App 的播放。

## Evidence

- 2026-11-18 使用者回報：「按下 shift 也就是錄音功能的時候……會不小心錄到背景，可能不用暫停但就是要把背景靜音」。
- 先前的 spec、PR 與 GTD 都沒有這條需求的紀錄，所以這是新的意圖。
- 喇叭外放時，背景聲音會直接進入麥克風。Spec 011 的語音辨識錯誤分析只用了安靜環境的錄音，沒有量過背景聲音的影響。

## Example

2026-11-18 在使用者的 MacBook（macOS 26.3）上跑 spike（一個用完即丟的實驗程式）：scratchpad `mute-spike/spike.swift`。

| 項目 | 實際值 |
| --- | --- |
| 預設輸出裝置的 transport type（連接方式） | `bltn`（內建喇叭） |
| `kAudioDevicePropertyMute`（output scope，main element） | 存在、可設定，目前值 0 |
| 各聲道（element 1、2）的 mute | 不存在 |
| 設成 1 的耗時 | < 1 ms，讀回 1 |
| 1 秒後還原成原值 0 | 成功，讀回 0 |

用這台機器說明預期行為：

| 錄音前 | 動作 | 錄音中 | 錄音後 |
| --- | --- | --- | --- |
| 內建喇叭播音樂，未靜音 | 按住右 Shift 說話，放開 | 靜音 | 取消靜音，音樂繼續播（播放從未暫停） |
| 使用者已自己靜音 | 同上 | 靜音 | 保持靜音（不是 Taipo 設的，不動它） |
| 輸出裝置沒有 mute 屬性 | 同上 | 不變 | 不變，錄音照常 |

## Forces

| ID | Force | 來源 | 種類 |
| --- | --- | --- | --- |
| FC1 | 錄音裡不能有背景播放的聲音 | 使用者 2026-11-18 | quality |
| FC2 | 不暫停播放；只要聽不到就好 | 使用者 2026-11-18：「可能不用暫停但就是要把背景靜音」 | taste |
| FC3 | 錄音結束後，使用者的聲音設定必須和錄音前一樣，Taipo 當掉也一樣 | 一旦卡在靜音，使用者會以為電腦壞了 | hard limit |
| FC4 | 不新增權限提示，也不用 private API | 上架與開源（Spec 025） | hard limit |
| FC5 | 送進辨識器的音訊不能改變，否則 Spec 011 量到的錯誤率會失效 | Spec 011、Spec 026（draft PR #35） | hard limit |
| FC6 | 在錄音路徑上加的延遲不能讓使用者察覺 | Spec 012 | quality |
| FC7 | 不在 log 記裝置名稱（可能含使用者名字） | 隱私規則 | hard limit |

衝突：FC1 和 FC2。暫停播放最乾淨，但使用者明說不要暫停，所以選靜音。

## Solution space

| 方案 | FC1 | FC2 | FC3 | FC4 | FC5 | 判斷 |
| --- | --- | --- | --- | --- | --- | --- |
| 不改（null design） | ✕ | ✓ | ✓ | ✓ | ✓ | 不解決問題 |
| **把預設輸出裝置靜音** | ✓（外放時） | ✓ | 需要還原機制 | ✓ | ✓ | **採用** |
| 調低音量（ducking） | 部分 | ✓ | 需要還原機制 | ✓ | ✓ | 見 D1 |
| `AVAudioEngine` voice processing（回音消除＋系統 ducking） | ✓ | ✓ | ✓ | ✓ | ✕ 會改變辨識器收到的訊號 | 要先量錯誤率；不在這個 slice |
| MediaRemote 暫停播放 | ✓ | ✕ | ✓ | ✕ private API | ✓ | 不採用 |
| 個別 process 的 audio tap | ✓ | ✓ | ✓ | ✕ 需要新權限 | ✓ | 不採用 |

## Decisions

- D1（2026-11-18 使用者決定：靜音）：靜音，還是把音量降到某個比例？選靜音。靜音一行就能還原；降音量要記住原本的音量，而且還是會錄進一點聲音。
- D2（2026-11-18 使用者決定：不加開關）：要不要在 Taipo 設定的語音區加開關？這次不加，永遠靜音。有人反映需要時再加，加的時候預設開。
- D3：在 recorder 這一層包一個 decorator（包住原物件、加上額外行為的物件），不改 `Voice.swift`。`Voice.swift` 同時被 PR #19、#27、#28、#32 修改，改它會增加衝突。
- D4：只處理錄音開始當下的預設輸出裝置的 main element mute。沒有 main element mute 的裝置不處理（見 Non-goals）。

## Behavior

1. **開始錄音時靜音**：錄音開始前，讀取預設輸出裝置與它的 mute 值。如果原本沒靜音，就設成靜音，並記住「是 Taipo 靜音的」與該裝置的 UID。（FC1、FC2）
2. **原本已靜音就不動**：錄音前已經是靜音時，Taipo 不設定、不記錄，錄音結束後也不取消靜音。（FC3）
3. **每條結束路徑都還原**：`stop`、`cancel`（包括 60 秒上限、按到其他修飾鍵而丟棄、焦點離開），以及錄音啟動失敗（`start` 丟錯），都會把 Taipo 靜音的那個裝置取消靜音。取消靜音在內部 recorder 的 `stop`／`cancel` 回傳之後才做，錄音的尾巴不會收到背景聲音。（FC1、FC3）
4. **還原 Taipo 靜音的那個裝置**：錄音中預設輸出換成別的裝置（例如插上耳機），還原時處理的是原本那個裝置，用 UID 找；找不到就略過。（FC3）
5. **當掉後復原**：Taipo 靜音時，先把裝置 UID 寫進 `UserDefaults`，再設定靜音；設定失敗就刪掉紀錄。正常還原後清除。IME 啟動時發現殘留紀錄，就把那個裝置取消靜音並清除紀錄。（FC3）
6. **不支援就略過**：裝置沒有 mute 屬性、不可設定，或讀寫失敗時，不靜音、不報錯，錄音照常。（FC6）
7. **不改音訊**：靜音只動輸出裝置，`MicrophoneRecorder` 收到並交給辨識器的樣本不變。（FC5）
8. **log**：只記「muted」「restored」「skipped」與 OSStatus 錯誤碼，不記裝置名稱與 UID。（FC7）
9. **取消靜音失敗不重試**：裝置還在，但取消靜音的寫入失敗時，Taipo 仍清除紀錄，log 記 skipped，之後的 `stop` 與下次啟動都不再嘗試。重試可能把使用者之後自己設的靜音取消。（FC3）

## Acceptance

### Behavior
- H10: 原本未靜音 → `start()` → 內部 recorder 開始之前，輸出已靜音，且記錄了裝置 UID。
- H11: H10 之後 → `stop()` → 取消靜音、清除紀錄，回傳內部 recorder 的樣本原封不動。
- H12: 原本已靜音 → `start()` 再 `stop()` → 從未呼叫設定 mute，結束後仍是靜音（正向對照：同一條路徑下，未靜音的情況會呼叫設定）。
- H13: 已開始 → `cancel()` → 取消靜音、清除紀錄。

### Failure and retry
- H14: 內部 recorder 的 `start()` 丟錯 → 錯誤照樣往上丟，而且已經取消靜音、清除紀錄。
- H15: 錄音中預設輸出換成別的裝置 → `stop()` → 取消靜音的是原本的裝置，新的預設裝置不動。
- H16: 裝置沒有 mute 屬性，或讀取失敗 → `start()` 照常開始錄音，不設定 mute、不寫紀錄。
- H17: 設定 mute 失敗 → 錄音照常，不寫紀錄，`stop()` 不嘗試取消靜音。
- H18: 啟動時 `UserDefaults` 有殘留紀錄 → 呼叫復原 → 那個裝置取消靜音，紀錄清除；沒有紀錄時不做任何事。
- H19: 啟動復原時找不到該裝置（已拔除）→ 清除紀錄，不報錯。
- H20: 連續兩次 `stop()`，或沒有 `start()` 就 `stop()` → 只取消靜音一次，不會把使用者自己設的靜音取消。
- H26: `start()` 之後，取消靜音的寫入失敗（裝置還在）→ `stop()` → 紀錄清除，事件是 muted、skipped；再一次 `stop()` 或啟動復原都不再寫入。

### Budget
- H21: [measure] 語音可用時（`VoiceSettings.isAvailable()`，載入語音模型的同時），在背景 queue 讀一次預設輸出裝置與 mute（暖機，只讀不寫），不佔 main thread。暖機後第一次 `start()` 多出來的時間：median < 5 ms，max < 10 ms。（2026-11-18 human 決定：原本的 max < 5 ms 是寫 spec 時未經量測的估計；10 ms 仍小於一格 60 Hz 畫面約 16.7 ms。）

### Observability
- H22: [manual] 在內建喇叭播音樂，按住右 Shift：聲音立刻消失；放開後聲音回來，播放位置有前進（沒有暫停）。
- H23: [manual] 先自己按靜音鍵再錄音：錄完仍是靜音。
- H24: [manual] 錄音中用 `kill -9` 結束 Taipo 的 IME process → 系統仍是靜音 → 切回 Taipo 輸入法（IME 重新啟動）→ 聲音恢復。
- H25: [manual] `log stream --predicate 'subsystem == "com.unknowntpo.inputmethod.Taipo" AND category == "voice" AND eventMessage BEGINSWITH "output "'` 錄一次音：只看到 `output muted`、`output restored`、`output skipped`，沒有裝置名稱與 UID。Apple 自己的 `com.apple.coreaudio` log 不在範圍內。

## 量測（2026-11-18）

- H21：在使用者的 MacBook（內建喇叭，原本未靜音）上，用 `CoreAudioOutputMute` 包一個不做事的 recorder。跑 10 個新 process，每個先暖機（讀預設輸出裝置與 mute），再做一次 `start()`／`stop()`。
  - 暖機（process 內第一次 CoreAudio 查詢）：94–112 ms。所以暖機放在語音可用、載入模型的時候，在背景 queue 做，不放在第一次錄音，也不擋 IME 啟動。語音關閉時不暖機；啟動復原（`recoverAfterCrash`）照樣在每次啟動時做。如果暖機還沒做完就開始錄音，那次 `start()` 會付這段時間。
  - 暖機在 main thread 時（10 個 process）：暖機後第一次 `start()` median 2.5 ms，max 3.6 ms。
  - 暖機改在背景 queue（用另一個 `CoreAudioOutputMute`，做完才在 main thread `start()`；30 個 process）：median 2.6 ms，max 5.2 ms。30 次中只有 1 次超過 5 ms，其餘都 ≤ 3.3 ms。median 2.6 ms < 5 ms、max 5.2 ms < 10 ms，通過（2026-11-18 human 接受放寬 max）。Verifier 量到單次 UID 轉換 < 0.01 ms，所以減少轉換次數不會變快。
  - 每個 process 靜音只有幾 ms，結束後讀回未靜音。
  - `start()` 要做 8 次 CoreAudio 呼叫（預設裝置、UID、UID 轉裝置兩次、有無 mute、可否設定、讀、寫）再寫一次 `UserDefaults`，所以比 spike 只量「設定 mute」的 < 1 ms 多。
  - 更正：先前記錄的「冷啟動 1.9–2.5 ms」其實已經暖機過，因為量測程式在 `start()` 前先讀了一次 mute。
- Fail-first 紀錄：`fail-first.txt`。
- 紀錄存在 IME 的 `UserDefaults.standard`；只有 IME process 讀寫它，而 IME 內的 `DecisionSettings.sharedDefaults` 本來就是同一個 domain。

## Non-goals

- 用耳機時，背景聲音本來就不會進麥克風；這次照樣靜音，不另外判斷。
- 只有各聲道 mute、沒有 main element mute 的裝置（部分 USB／HDMI 裝置）。有人遇到再處理。
- 麥克風收到的環境噪音（旁邊有人講話）。需要 voice processing，要先量錯誤率，另開 spec。
- 暫停播放（FC2）。
- 靜音中拔掉裝置：紀錄會被清除（找不到裝置就略過），之後再插回來，那個裝置仍是靜音，要使用者自己取消。
- 錄音中 IME 收到 SIGTERM（或其他不經過 `stop`／`cancel` 的結束）：一直靜音到 IME 下次啟動，由啟動復原取消靜音。
- 當掉後到 IME 下次啟動之間，使用者自己按了靜音：啟動復原仍會把紀錄裡的裝置取消靜音，因為紀錄分不出這次靜音是誰設的。
