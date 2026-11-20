# Spec 001: TaipoCore 解碼引擎

Status: Accepted (2026-10-17；D1–D4 依建議)；Behavior 9、D5 為 2026-11-13 修訂，2026-11-19 human 接受（D5 依建議）；D6 為 2026-11-19 新增（owner 交由 agent 決定）
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

### 修訂 2026-11-13：有拼法變體的英文字

使用者回報（2026-11-13）：打 `practice` 變成 `proactive`。
原因：`en.tsv` 沒有 `practice`，引擎把它當錯字，改成 2 次編輯外的 `proactive`。

SCOWL 原始資料：`en-wl/wordlist` 分支 `v2`，commit `1e5b7d3`（2026-06-24），檔案 `data/scowl-pre.txt`。
它與本 repo 建置用的檔案 git blob 相同（`283adae`）。有變體的字在詞條前多一段拼法標記：

```
35 [] [12dicts] [ukfreq] … 85 [ukacd]: A B C: practice <n>
35 [] [12dicts] [ukfreq] … 85 [ukacd]: AV Cv: practise <n>
35 [] [12dicts] [ukfreq] … 85 [ukacd]: A Cv DV: color <n>
35 [] [12dicts] [ukfreq] … 85 [ukacd]: B C D: colour <n>
```

`A`＝美式、`B`／`Z`＝英式、`C`＝加拿大、`D`＝澳洲、`_`＝不分地區。
字母後的符號是變體等級：沒有符號＝0（非變體）、`.`＝1、`v`＝4、`V`＝6、`-`＝8，依此類推。
修訂前的 `build_en` 只接受小寫字開頭的詞條，所以這些行全部被跳過。

修訂前後的第一名（2026-11-13，`swift test` case rows；修訂前輸出見 `evidence/fail-first-b9.txt`）：

| 按鍵 | 修訂前第一名 | 修訂後第一名 |
| --- | --- | --- |
| `practice` | proactive | practice |
| `license` | licensee | license |
| `colour` | cloud | colour |
| `organie` | organ | organize（organise 在前三） |
| `advertize` | advertiser | advertise |

`build_en` 修訂後 `en.tsv` 從 90,881 行增為 97,227 行：新增 6,346 個字，17 個字的 size 變小（例如 `aging` 40 → 35），沒有字被移除。

2026-11-19 補修：詞性後帶語意標記 `{…}` 的行（例如 `_: so <av> {:1}`、`A B: disk <n> {:1}`）原本整行被跳過。
這次補修多收 398 個字（96,829 → 97,227 行；含屈折形），沒有字被移除。
其中 106 個原形來自有拼法標記的行（例如 so、disk、disc、icon、story、prize、tire、curb、analog、dialog、casino、whiskey），38 個來自沒有拼法標記的行（例如 die、genius、axis、phenomenon）。
另有 6 個字的 size 變小，因為它們的原形行現在讀得到（例如 `weaving` 50 → 40、`dyke` 40 → 35）。

| 按鍵 | 補修前第一名 | 補修後第一名 |
| --- | --- | --- |
| `disk` | dusk | disk |

`swift run -c release taipo-bench decision`（Spec 004）修訂前後相同：zh-typo 引擎 66.8%、λ=1.00 86.3%；zh-en 87.5%；mixed 100%。M1–M3 在量測雜訊內（M1 p95 2.75 → 2.78 ms、M2 31.9 → 29.5 MB、M3 49.8 → 48.4 ms）。

## Behavior

1. **API**：`Decoder.candidates(for input: String, previousLanguage: Language?) -> [Candidate]`。`Candidate` 含 `text`、`language`（`zh`／`en`）、`edits`（套用的編輯）、`score`。由 Spec 002 的候選窗使用。
2. **雙重解讀**：每串輸入同時以英文與大千注音解讀。一個輸入只屬一種語言（同一 buffer 內中英混打是 non-goal）。
3. **注音解碼**：按鍵依大千鍵位轉成注音，以聲調鍵切分音節；合法音節是詞庫中出現過的讀音。多音節用詞庫詞組加 unigram 詞頻的 Viterbi 取最佳切分。英文解讀忽略結尾的空白。
4. **模糊匹配**：編輯類型有四種，每次在上限中算 1 次：鄰鍵替換（MacBook ANSI 配置上下左右相鄰）、相鄰對調、多按一鍵、少按一鍵。非相鄰替換只能用刪除＋插入表示（成本 2）。編輯上限依輸入鍵數：1–2 鍵為 0、3–5 鍵為 1、6 鍵以上為 2。
5. **排序**：`score = log(詞頻) − 編輯懲罰`；中文多詞段時為各段 log 詞頻相加。相鄰對調的懲罰是其他編輯的 0.8 倍：它是快打最常見的錯，也用來打破 SCOWL 級別同分（the／ten）。同語言中，0 編輯的合法詞永遠排在所有修正候選之前。
6. **語言判斷**：只有一種語言有 0 編輯候選時，該語言全部排在前面；兩種都有時，`previousLanguage` 那一種在前，沒有 hint 時預設 `zh`（D3）；兩種都沒有時，依分數交錯排序。
7. **使用者字典**：`learn(input:chosen:)` 之後：(a) 同樣輸入時 `chosen` 排第一；(b) `chosen` 若不在詞庫中，就成為使用者詞，參與之後的模糊匹配。資料以 JSON 原子寫入指定路徑，重啟後仍存在。
8. **原文保底**：原始輸入（英文字面）一定是候選之一，讓使用者永遠能送出自己打的內容。
9. **拼法變體**：英文詞庫讀取 SCOWL 行首的拼法標記，決定該行原形（head word）是否進詞庫、以什麼 size 進。美式（`A`）或不分地區（`_`）且變體等級 ≤ 1 的字，以該行 size 進詞庫。英式（`B`、`Z`）且等級 ≤ 1 的字，以 size + 5 進詞庫（D5）。等級 ≥ 2 的變體（例如 `A-: advertize`、`Bv: connexion`、`B=: encyclopaedia`）不進詞庫。只標 `C`（加拿大）或 `D`（澳洲）的字不進詞庫（例如 `C: yogourt`、`Av Bv D: verandah`）。詞性後的語意標記 `{…}`（例如 `_: so <av> {:1}`、`A C: curb <n> {street edge}: curbs`）不影響讀取；沒有拼法標記的行也一樣（例如 `genius <n> {brilliance}`）。詞性後帶用語標記 `(vulgar-N)` 或 `(offensive-N)` 的行，整行不進詞庫，原形與行內形式都不收（例如 `A: asshole <n> (vulgar-1)`、`B: arsehole <n> (vulgar-1)`、`_: shit <v> (vulgar-1)`，見 D6）。拼法標記對原形的規則與 SCOWL 預設美式字表 `word-list 60 A 1` 相同，再加上英式非變體字；用語標記這條是本專案自己的規則。拼法標記的規則只管原形；屈折形與衍生形還不照這條規則，見 Non-goals 的「英文屈折形的變體等級」。

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
- B9：見 `en-variant-us` 到 `en-no-variant-control`；另加具名測試 `B9 en lexicon has common words whose SCOWL lines carry spelling-variant info`（詞庫含 practice、color、center、license、program、organize 等，以及英式 colour、centre 等；正向對照 travel）、`B9 region-neutral and level-1 SCOWL variants enter the en lexicon at the right size`（advisor、afterward 為 size 35；只有 `Z` 的 tranquillize 為 35 + 5 = 40）、`B9 SCOWL lines with a {sense} tag after the part of speech enter the en lexicon`（so、disk、icon、curb、genius、phenomenon、die 為 size 35，tyre 為 40）、`B9 Canadian-only and Australian-only SCOWL spellings stay out of the en lexicon`（yogourt、verandah 不在；正向對照 yogurt、veranda）、`B9 SCOWL lines with a (vulgar-N) or (offensive-N) usage tag stay out of the en lexicon`（asshole、arsehole、shit 不在；`(offensive-2)` 的 kraut、`(vulgar-3)` 的 crap 不在；行內形式 assholes 也不在；正向對照 disk，同一位置是 `{…}` 語意標記的行）。`en-variant-sense-tag`：打 `disk` 第一名是 disk。

### Failure and retry
- F1：空輸入 → 回傳空陣列，不 crash。
- F2：超過 32 鍵 → 不做模糊，只回原文（邊界：32 鍵仍做模糊）。
- F3：非鍵位字元（如 `é`、emoji）→ 沒有注音解讀，原文排第一。
- F4：使用者字典 JSON 損毀 → 初始化成功、字典為空，原檔改名為 `*.corrupt-<timestamp>`，`diagnostics` 出現一筆警告。
- F5：使用者字典檔不存在 → 字典為空，第一次 `learn` 時建立。
- F6：使用者字典寫入失敗（目錄唯讀）→ `learn` 拋出 `UserDictionaryError.writeFailed`，記憶體中的學習在本次執行仍有效。
- F7：只有聲調鍵（如 `3333`）→ 沒有注音候選，原文仍在候選中。
- F8：詞庫資源缺失或格式錯誤 → 初始化拋出 `LexiconError`，不使用 `fatalError`。
- F9：行首變體等級 ≥ 2 的 SCOWL 行，不會把它自己的原形帶進詞庫。同一個字仍可能由其他行的行內清單或 `inflections()` 進詞庫（見 Non-goals）→ 打 `advertize` 第一名是 `advertise`、打 `connexion` 第一名是 `connection`。見 `en-variant-uncommon`、`en-variant-gb-variant`；另加具名測試（`_~: cafe`、`_~: attache` 不在；SCOWL 沒有 `A~` 行，`_~` 與 `A` 走同一條規則；正向對照：同組的首選拼法與 `_: so` 在詞庫中），以及 `F9 British level-2 SCOWL spellings stay out of the en lexicon`（`AV B= Cv Dv: encyclopaedia`、`BV: burkha`、`AV B-: gage`、`B-: gaolbreak` 不在；正向對照 encyclopedia、burka、gauge、jailbreak）。

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
| B9 | en-variant-us | `practice` | — | — | top1 = practice |
| B9 | en-variant-sense-tag | `disk` | — | — | top1 = disk |
| B9 | en-variant-us-license | `license` | — | — | top1 = license |
| B9 | en-variant-gb | `colour` | — | — | top1 = colour |
| B9 | en-variant-us-preferred | `organie` | — | — | top1 = organize; top3 ∋ organise |
| B9 | en-no-variant-control | `travel` | — | — | top1 = travel |
| F1 | empty | `` | — | — | count = 0 |
| F9 | en-variant-uncommon | `advertize` | — | — | top1 = advertise |
| F9 | en-variant-gb-variant | `connexion` | — | — | top1 = connection |
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
| D5 | 英式拼法（`colour`、`centre`、`practise`）是否進詞庫（2026-11-13 提出，2026-11-19 human 接受建議） | 進詞庫，但 size + 5（約低半級），美式為主 | 英式拼法是合法英文字。不收的話，打 `colour` 會被當成錯字改掉（修訂前第一名是 cloud），和 `practice` 被改成 `proactive` 是同一類錯。size + 5 讓兩種拼法都差一次編輯時美式排前（`organie` → organize）。代價：美國使用者把 `center` 打成對調的 `centre` 時，不再自動修正，center 仍在前三。只收美式的替代方案：刪掉 `build_en` 中英式那一支即可。 |
| D6 | 帶用語標記 `(vulgar-N)`／`(offensive-N)` 的 SCOWL 行是否進詞庫（2026-11-19，owner 交由 agent 決定） | 不進詞庫 | 輸入法不應主動建議粗俗或冒犯字，也不應把別的字自動修正成這些字。使用者打的原文仍是候選（Behavior 8），所以仍能送出。代價：使用者真的要打這些字時，第一名會是別的字。例如 `taipo explain shit` 第一名是 hit，原文 shit 是第 10 名（最後一名）；main 也一樣。另一個分支正在做「原文放第 2 名」，做完後這些字就容易選到。SCOWL 只有這兩種用語標記。計數定義：size ≤ 60、原形或 `-` 之後（有詞性時在詞性之後）帶 `(vulgar-N)` 或 `(offensive-N)` 的行，不論拼法標記（例如 `shitted (vulgar-1)` 沒有詞性也算）。這樣有 54 行：49 行是原形行（37 個不同原形），5 行是 `-` 續行；50 行沒有拼法標記。其中 `_v: shat <v> (vulgar-1)` 也不符合 Behavior 9 的等級規則，所以後面「多 83 行」的數字不受它影響。這些行的原形、行內形式與 `inflections()` 猜出的形式中，本 PR 的 `en.tsv` 只含 buggered：它由沒有用語標記的 `buggered <aj>` 行（size 60）進詞庫，main 也有。要收的話：讓 `build_en` 的原形 regex 接受 `(?: \([a-z]+-\d+\))?`，`en.tsv` 會多 83 行。 |

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
- 英文屈折形的變體等級（Behavior 9 後續，另開 PR）：Behavior 9 與 F9 只管 SCOWL 行首標記對該行原形的效果。以下路徑目前不看變體等級（2026-11-19，本 PR 的 `en.tsv` 對 main）。
  - 等級 ≥ 2 的原形由其他路徑進詞庫：13 個字在 size ≤ 60 的行中只在等級 ≥ 2 的行當原形，卻由別行的 `listed` 或 `inflections()` 進詞庫：bros、calking、caps、caulking、diss、doggoned、drier、ins、kidnaping、mos、nos、programing、vs。其中 calking、caulking、diss、programing 4 個是本 PR 新增，其他 9 個 main 已有。
  - 英式 size 60 原形：5 個字在 size ≤ 60 的行中只在 `B:` 行當原形，size 60 + 5 = 65 > 60，該行不收它，卻由其他路徑以 size 40–60 進詞庫：travelling、tasselled、iodised、vulcanised、kerbing。其中 travelling 以外 4 個是本 PR 新增。
  - 只以等級 ≥ 2 出現的新字：定義為不在 main、本 PR 新增，不是任何被接受行的原形，而且在 SCOWL size ≤ 60 的行中每次出現（原形或行內形式；行內標記優先於行首標記）都不符合 Behavior 9 的等級與地區。帶字尾標記的行內形式（例如 `A B: tyro <n>: (tyros | -: tyroes!)` 的 tyroes）也算一次出現；至少要出現一次。共 43 個：20 個經由行內清單 `listed`（例如 canst、wouldst、clipt、presidia；其中 10 個也由 `inflections()` 猜出，例如 dominos、insignias），23 個只由 `inflections()` 猜出（例如 chilis、esophaguses、programed）。diss、programing 同時算在上面 13 個裡。
  - 行內清單：`build_en` 的 `listed` 讀取行內的 `(A B: kidnapped | AV: kidnaped)`，但不看每項的等級。本 PR 新讀到的行因此帶進等級 ≥ 2 的形式，例如 cicatrixes、presidia、reprograming（`A=: presidia`、`_~: reprograming`）。main 上本來就有同類字（例如 kidnaped、deprogramed）。
  - `-` 續行：`A B: - <v>: (A B: programmed | Av: programed)` 這類續行目前整行跳過。計數定義：size ≤ 60 的 `-` 續行中的小寫形式，行內標記優先於行首標記，套用 Behavior 9 的等級與地區規則（含用語標記），但不套英式 + 5 後的 size 上限。帶字尾標記（`!`、`-`、`*`，例如 `- <v>: -, (birdying! | -: birdieing!), -` 的 birdying）的形式不算。這樣有 3,183 個不在 main 的 `en.tsv`、2,356 個不在本 PR 的 `en.tsv`（例如 ate、began、became、bigger）。若再套英式 + 5 後 ≤ 60 的上限，是 3,153 與 2,336；差的 30 與 20 個是英式 size 60 行的形式（例如 bejewelled、relabelled）。不套上限、但把帶字尾標記的形式（去掉標記）也算進去，是 3,190 與 2,363。
  - `inflections()` 猜測：它替新讀到的原形猜屈折形，猜出的拼法可能是 SCOWL 標為等級 ≥ 2 的寫法，例如 programed、programing、reprogramed、chilis、esophaguses、oesophaguses。它用 `"v" in pos` 判斷動詞，所以副詞 `<av>` 也會被猜，本 PR 新增 soed、soing、afterwarded、backwardsed（main 已有 quicklied）。
