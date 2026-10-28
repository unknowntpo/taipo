# Taipo

唸起來就是 typo。Taipo 是 macOS 上的注音（大千）／英文輸入法：不用切換中英、打錯鄰近鍵也能對，選過的字會越用越準；也能按住右 Shift 用說的。所有輸入與語音辨識都在本機進行。

*Taipo is a macOS input method for Traditional Chinese (Zhuyin, Dachen layout) and English. Type both languages without switching, get typo-tolerant candidates, and dictate with on-device speech recognition. Your keystrokes, text, and audio never leave your Mac.*

## 功能

- **中英混打**：同一段按鍵自動切成中文詞與英文字，例如打完「這個好像有點 tricky」再一次送出。
- **容錯**：打錯鄰近鍵、漏鍵、多鍵仍找得到正確的詞。
- **越用越準**：選了非第一名的候選會被記住；可在 Taipo App 關閉「記住我的選擇」或清除學習紀錄。
- **英數模式**：單按左 Shift 暫停組字，直接打英文。
- **數字鍵選字**：候選窗出現後用 1–9 選字。
- **語音輸入（選用）**：按住右 Shift 說話，放開後文字出現在游標處；也可點一下開始、再點一下結束。使用 Breeze-ASR-25（whisper.cpp，Metal）在本機辨識，模型需在 Taipo App 內另外下載（約 1 GB）。
- **裝置上 decision model（選用、實驗中）**：引擎不確定時，由本機小模型（Qwen3-0.6B，MLX 4-bit）依上下文重新排序。模型需自行放到 `~/Library/Application Support/Taipo/models/Qwen3-0.6B-MLX-4bit/`。

## 開發路線

| 狀態 | 項目 |
| --- | --- |
| 已完成 | 注音／英文解碼與容錯（Spec 001、003、006）、輸入法殼（002）、長句（005）、學習開關與清除（008、010）、英數模式（013）、數字鍵選字（014、017） |
| 已完成 | 本機語音輸入：Breeze-ASR-25 + whisper.cpp（Spec 011 評估、012 實作） |
| 實驗中 | 本機 decision model 重新排序候選（Spec 004） |
| 規劃中 | 游標離開時暫存語音結果、只在數字會選字時顯示候選編號、專有名詞學習 |
| 之後 | iOS 鍵盤 |

## 安裝

需求：Apple silicon Mac、macOS 14 以上、Xcode 26（Swift 6.2）。

```bash
xcodebuild -downloadComponent MetalToolchain   # 每台機器一次
scripts/install-ime.sh
```

接著到「系統設定 → 鍵盤 → 文字輸入 → 編輯… → ＋ → 繁體中文 → Taipo」加入。如果清單裡沒有，登出再登入一次。開關（語音輸入、記住選擇、decision model）在 `~/Applications/Taipo.app`。

| 按鍵 | 作用 |
| --- | --- |
| 直接打大千注音或英文 | 不用切換；組字區顯示第一名 |
| 空白 | 能當一聲就當一聲，否則送出（英文會補空白） |
| ↑ ↓、1–9 | 在候選窗選字；選了非第一名會被記住 |
| Enter | 送出目前選的字 |
| Esc | 取消組字 |
| 單按左 Shift | 切換英數模式 |
| 按住右 Shift | 語音輸入（需先開啟並下載模型） |

## 隱私

- 按鍵、組字內容與語音都只在本機處理，Taipo 不會上傳任何資料。
- 錄音只存在記憶體，辨識完即丟棄，不寫入磁碟。
- 唯一的網路連線是你在 Taipo App 按「下載模型」時，從 Hugging Face 下載語音模型。
- 使用者字典存在 `~/Library/Application Support/Taipo/user.json`，可隨時清除。

## 開發

```bash
swift test
swift run taipo-dev check-traceability
swift run taipo-dev render-test-plan --check
```

每個功能先寫 spec（`docs/specs/`），流程見 [docs/process/workflow.md](docs/process/workflow.md)。除錯 log：`/usr/bin/log stream --predicate 'subsystem == "com.unknowntpo.inputmethod.Taipo"'`。

## 授權

Taipo 以 [Apache License 2.0](LICENSE) 授權。詞庫、語音模型與其他第三方元件的授權見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
