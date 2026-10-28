# Spec 001: TaipoCore 解碼引擎

Status: Accepted (2026-10-17；D1–D4 依建議)
Date: 2026-10-17
Traceability: enforced
Builds on: —

## Intent

在 Mac 鍵盤上打字的人，常打錯鄰近鍵，且要頻繁切換中英。
要達成的可觀察結果：使用者不按切換鍵、直接用 QWERTY 鍵位打注音（大千）或英文，即使打錯一兩個鄰近鍵，想要的字詞仍出現在候選第一位（至少前三位）；使用者選過的結果，下次同樣輸入會排第一。

本 spec 只做純 Swift 的引擎 `TaipoCore` 與驗證用 CLI；輸入法殼（InputMethodKit）是 Spec 002。

## Evidence

- 使用者回報：Mac／iOS 鍵盤鍵距擠，常打錯需頻繁修正；中英切換耗時（2026-10-17 對話）。
- 大千注音與英文共用同一組按鍵，所以同一串按鍵可以同時解讀為兩種語言；注音的合法音節很有限，是語言判斷的強訊號。

## Example

鍵位資料：大千標準配置，2026-10-17 由 research agent 與 libchewing `standard.rs` 比對確認：

```
聲母 1ㄅ qㄆ aㄇ zㄈ 2ㄉ wㄊ sㄋ xㄌ eㄍ dㄎ cㄏ rㄐ fㄑ vㄒ 5ㄓ tㄔ gㄕ bㄖ yㄗ hㄘ nㄙ
介音 uㄧ jㄨ mㄩ
韻母 8ㄚ iㄛ kㄜ ,ㄝ 9ㄞ oㄟ lㄠ .ㄡ 0ㄢ pㄣ ;ㄤ /ㄥ -ㄦ
聲調 space=一聲 6=ˊ 3=ˇ 4=ˋ 7=˙
```

| 按鍵 | 注音解讀 | 英文解讀 | 期望第一候選 | 原因 |
| --- | --- | --- | --- | --- |
| `su3cl3` | ㄋㄧˇ ㄏㄠˇ（合法） | 非英文字 | 你好 | 只有中文有 0 編輯候選 |
| `ki3` | ㄜㄛˇ（不合法） | 非英文字 | 我（前三） | k→j 鄰鍵修正成 ㄨㄛˇ |
| `hrllo` | 不合法 | 1 次鄰鍵修正 → hello | hello | r 鄰 e |
| `up␣` | ㄧㄣ 一聲（合法 → 因／音） | up（合法） | 依前一個語言 | 兩邊都是 0 編輯 |
| `form` | 不合法 | form（合法） | form，from 在前三 | 合法字不被自動改掉 |

匯入詞庫後的實際前五名（2026-10-17，`swift run -c release taipo query <keys>`，空使用者字典）：

| 按鍵 | 前五名 |
| --- | --- |
| `ji3` | 我、婐、捰、所、果 |
| `up␣` | 因、音、陰、姻、殷（phrase.occ：因 38348、音 10860） |
| `u4` | 一、意、議、義、易 |
| `su3cl3` | 你好、妳好、理好、你老、鳥 |
| `ki3` | 我、噁、婐、捰、ki3 |
| `teh` | the、ten、eh、tech、teh |

原本草稿預期 `up␣` 第一是「音」，真實詞頻是「因」，已改 case file。

## Behavior

1. **API**：`Decoder.candidates(for input: String, previousLanguage: Language?) -> [Candidate]`。`Candidate` 含 `text`、`language`（`zh`／`en`）、`edits`（套用的編輯）、`score`。由 Spec 002 的候選窗使用。
2. **雙重解讀**：每串輸入同時以英文與大千注音解讀。一個輸入只屬一種語言（同一 buffer 內中英混打是 non-goal）。
3. **注音解碼**：按鍵依大千鍵位轉成注音，以聲調鍵切分音節；合法音節是詞庫中出現過的讀音。多音節用詞庫詞組加 unigram 詞頻的 Viterbi 取最佳切分。英文解讀忽略結尾的空白。
4. **模糊匹配**：編輯類型有四種，每次在上限中算 1 次：鄰鍵替換（MacBook ANSI 配置上下左右相鄰）、相鄰對調、多按一鍵、少按一鍵。非相鄰替換只能用刪除＋插入表示（成本 2）。編輯上限依輸入鍵數：1–2 鍵為 0、3–5 鍵為 1、6 鍵以上為 2。
5. **排序**：`score = log(詞頻) − 編輯懲罰`；中文多詞段時為各段 log 詞頻相加。相鄰對調的懲罰是其他編輯的 0.8 倍：它是快打最常見的錯，也用來打破 SCOWL 級別同分（the／ten）。同語言中，0 編輯的合法詞永遠排在所有修正候選之前。
6. **語言判斷**：只有一種語言有 0 編輯候選時，該語言全部排在前面；兩種都有時，`previousLanguage` 那一種在前，沒有 hint 時預設 `zh`（D3）；兩種都沒有時，依分數交錯排序。
7. **使用者字典**：`learn(input:chosen:)` 之後：(a) 同樣輸入時 `chosen` 排第一；(b) `chosen` 若不在詞庫中，就成為使用者詞，參與之後的模糊匹配。資料以 JSON 原子寫入指定路徑，重啟後仍存在。
8. **原文保底**：原始輸入（英文字面）一定是候選之一，讓使用者永遠能送出自己打的內容。

## Acceptance

### Behavior
- B1：給定詞庫 → 呼叫 `candidates` → 每個候選都有 `text`、`language`、`edits`、`score` → 單元測試。
- B2：見測試計畫 `zh-exact`、`en-exact`。
- B3：見 `zh-phrase`。
- B4：見 `zh-adjacent` 到 `budget-6-keys-2-edits`；鍵數上限的兩側各有一列。
- B5：見 `exact-not-corrected`。
- B6：見 `zh-only-exact` 到 `tie-no-hint`。
- B7：見 `learn-literal`、`user-word-fuzzy`、`user-word-control`；另加具名測試 `B7 persists across restart`：learn → 用同一路徑重建 Decoder → 結果仍排第一。
- B8：見 `literal-always`。

### Failure and retry
- F1：空輸入 → 回傳空陣列，不 crash。
- F2：超過 32 鍵 → 不做模糊，只回原文（邊界：32 鍵仍做模糊）。
- F3：非鍵位字元（如 `é`、emoji）→ 沒有注音解讀，原文排第一。
- F4：使用者字典 JSON 損毀 → 初始化成功、字典為空，原檔改名為 `*.corrupt-<timestamp>`，`diagnostics` 出現一筆警告。
- F5：使用者字典檔不存在 → 字典為空，第一次 `learn` 時建立。
- F6：使用者字典寫入失敗（目錄唯讀）→ `learn` 拋出 `UserDictionaryError.writeFailed`，記憶體中的學習在本次執行仍有效。
- F7：只有聲調鍵（如 `3333`）→ 沒有注音候選，原文仍在候選中。
- F8：詞庫資源缺失或格式錯誤 → 初始化拋出 `LexiconError`，不使用 `fatalError`。

### Budget
在本機量測（Apple Silicon，macOS 26.3，release build）。下限依據 Spec 002 IME 的每鍵回應，以及未來 iOS 鍵盤 extension 的記憶體限制。
- M1：[measure] ≤12 鍵輸入的 `candidates` 延遲 p95 ≤ 10 ms。實測（2026-10-17）：2.47–2.53 ms，最慢輸入 `su3cl3ji3` 2.9 ms。`swift run -c release taipo-bench latency`
- M2：[measure] 載入詞庫後 resident memory 增量 ≤ 50 MB。實測：28.8–30.3 MB（第一版 54.7 MB，改為單次串流解析後下降）。`swift run -c release taipo-bench memory`
- M3：[measure] 詞庫冷載入 ≤ 300 ms。實測：49–54 ms。`swift run -c release taipo-bench load`

### Observability
- O1：`swift run taipo explain <input>` 對每個候選印出語言、套用的編輯、分數組成，以及是否啟用模糊 → 單元測試檢查輸出含編輯描述。

## Test plan

<!-- test-plan:start Tests/TaipoCoreTests/Cases/decoder-cases.json -->
| ID | Case | Input | Prev | Learn first | Expect |
| --- | --- | --- | --- | --- | --- |
| B2 | zh-exact | `ji3` | — | — | top1 = 我 (zh) |
| B2 | en-exact | `hello` | — | — | top1 = hello (en) |
| B3 | zh-phrase | `su3cl3` | — | — | top1 = 你好 |
| B3 | zh-phrase-preferred | `2u04sl3` | — | — | top1 = 電腦 |
| B3 | zh-sentence-uses-phrases | `184184g;3` | — | — | top1 = 爸爸上 |
| B4 | zh-adjacent | `ki3` | — | — | top3 ∋ 我 |
| B4 | en-adjacent | `hrllo` | — | — | top1 = hello |
| B4 | en-cross-row | `hdllo` | — | — | top1 = hello |
| B4 | zh-number-row | `rk4` | — | — | top3 ∋ 這 |
| B4 | zh-number-row-not-adjacent | `ek4` | — | — | ∌ 這 |
| B4 | en-missing-key | `helo` | — | — | top3 ∋ hello |
| B4 | en-extra-key | `helllo` | — | — | top1 = hello |
| B4 | en-transpose | `teh` | — | — | top1 = the |
| B4 | en-non-adjacent | `hqllo` | — | — | ∌ hello |
| B4 | budget-2-keys | `ib` | — | — | ∌ in |
| B4 | budget-5-keys-2-edits | `hrlli` | — | — | ∌ hello |
| B4 | budget-6-keys-2-edits | `tupinh` | — | — | top3 ∋ typing |
| B5 | exact-not-corrected | `form` | — | — | top1 = form; top3 ∋ from |
| B5 | zh-exact-rare | `s96` | — | — | top1 = 孻; top3 ∋ 來 |
| B6 | zh-only-exact | `u4` | — | — | top1 language = zh |
| B6 | en-only-exact | `us` | — | — | top1 = us (en) |
| B6 | en-exact-over-zh-fuzzy | `us␣` | — | — | top1 = us |
| B6 | zh-exact-over-en-fuzzy | `sl␣` | — | — | top1 = 孬 (zh) |
| B6 | en-exact-rare | `baldy` | — | — | top1 = baldy (en); top3 ∋ badly |
| B6 | tie-prev-zh | `up␣` | zh | — | top1 = 因 |
| B6 | tie-prev-en | `up␣` | en | — | top1 = up |
| B6 | tie-no-hint | `up␣` | — | — | top1 = 因 |
| B7 | learn-literal | `teh` | — | teh→teh | top1 = teh |
| B7 | learn-lexicon-word | `ji3` | — | ji3→婐 | top1 = 婐 |
| B7 | user-word-fuzzy | `taipi` | — | taipo→taipo | top3 ∋ taipo |
| B7 | user-word-control | `taipi` | — | — | ∌ taipo |
| B8 | literal-always | `qqqqq` | — | — | ∋ qqqqq |
| F1 | empty | `` | — | — | count = 0 |
| F2 | max-length | `abcdefghijabcdefghijabcdefghijab` | — | — | fuzzy = on |
| F2 | over-max-length | 33 鍵 | — | — | fuzzy = off; count = 1 |
| F2 | multibyte-max-length | é×32 | — | — | fuzzy = on |
| F3 | non-layout-chars | `café` | — | — | top1 = café; 無 zh |
| F3 | non-layout-with-zhuyin | `ji3!` | — | — | 無 zh |
| F7 | tone-keys-only | `3333` | — | — | ∋ 3333; 無 zh |
<!-- test-plan:end -->

上表由 `swift run taipo-dev render-test-plan` 從 case file 生成，`--check` 在 CI 擋住漂移。B1、F4–F6、F8、O1 與 B7 持久化為具名測試。

## Decisions（需 human 確認）

| ID | 決定 | 建議 | 理由 |
| --- | --- | --- | --- |
| D1 | 引擎：自建 Swift 或用 librime | 自建 Swift | librime 是 C++，資料多為 LGPL-3，且沒有內建「同一串鍵同時解讀注音與英文＋鄰鍵模糊」；自建可完整測試並與 iOS 共用。代價是要自己寫 Viterbi 切分。 |
| D2 | 詞庫來源 | 注音：McBopomofo 資料（MIT＋libtabe BSD，含 `phrase.occ` 詞頻）。英文：SCOWL size ≤ 60 的字表，以 size 級別當詞頻 | 都允許閉源商用，只需保留授權聲明。不用 vChewing（詞頻資料限非商用）、libchewing／RIME（LGPL）、wordfreq 與 FrequencyWords（BY-SA）、Norvig count_1w（未標資料授權）。 |
| D3 | 兩種語言平手、又沒有 hint 時的預設 | `zh` | 主要使用情境是注音輸入法。 |
| D4 | 使用者字典格式 | JSON 檔 | 001 只有單一 process；Spec 003 語音 App 共用時再評估 SQLite。 |

## 簡化審查

1. **質疑需求**：每個元件的需求者——注音／英文解讀與模糊（使用者痛點）、使用者字典（使用者要求的「越用越好用」）、`explain`（verifier 與除錯）、Budget（Spec 002 每鍵回應、iOS 記憶體）。
2. **刪除**：
   - 同一 buffer 內中英混打 → non-goal。
   - 字典的「忘記」功能 → 移到 002 UI；現階段 JSON 可手動編輯。
   - 詞頻累加加權 → 只保留「同輸入排第一」與「新增使用者詞」。
   - n-gram（bigram 以上）→ 只用 unigram。
   - 英文詞頻資料源 → 以 SCOWL 級別代替，少一個資料源與授權。
   - 拼音、其他注音鍵盤配置 → non-goal。
3. **簡化**：實作時刪掉「中文每個詞段扣固定懲罰」：真實詞庫中找不到任何常用二字詞（詞頻 > 2000）在沒有懲罰時會輸給逐字切分（mutation 存活後以腳本全量檢查）。合法音節直接由詞庫讀音定義，不另寫注音拼寫規則；編輯上限用三段固定表。
4. **縮短驗證週期**：全部邏輯放在 SwiftPM library，`swift test` 數秒內可跑完，不需要 Xcode 或安裝 IME。
5. **自動化**：traceability 與 test-plan gate 在 slice 1 才加入。

## Non-goals

- InputMethodKit 殼、候選窗 UI（Spec 002）。
- 語音輸入（Spec 003）、手寫、iOS。
- 拼音、倚天等其他注音配置。
- 同一 buffer 內中英混打（後由 Spec 003 處理）。
- 依上下文的 n-gram 語言模型、雲端任何功能。
