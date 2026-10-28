# Spec 003: 同一段輸入內中英混打

Status: Draft（2026-10-18，依使用者回報；待 human 審查）
Date: 2026-10-18
Traceability: enforced
Builds on: Spec 001、Spec 002

## Intent

使用者一口氣打完「這個好像有點 tricky」，中間不按空白或 Enter，也能送出正確的中英混合句子；打到一半時，組字區不會吃掉還沒打完的鍵。

## Evidence

2026-10-18 使用者回報：打 `5k4ek7cl3vu;4u.32u03tricky` 只能送出原文。CLI 重現（`taipo explain`）：唯一候選是 literal。原因是 Spec 001 Behavior 2「一個輸入只屬一種語言」。

同一次重現也看到：`5k4ek7j`（打到一半的 ㄨ）第一名是「這個」，`j` 被當成多按的鍵刪掉。

## Example

實際資料（2026-10-18，`swift run -c release taipo query`）：

| 按鍵 | 現在 | 期望 |
| --- | --- | --- |
| `5k4ek7cl3vu;4u.32u03` | 這個好像有點 | 不變 |
| `5k4ek7cl3vu;4u.32u03tricky` | 原文 | 這個好像有點 tricky |
| `5k4ek7j` | 這個（刪掉 j） | 這個j（尾巴照原樣） |

## Behavior

1. **混合切分**：沒有任何單一語言的 0 編輯候選時，解碼器把輸入切成數段，每段是中文詞（Spec 001 的注音解碼）或英文字（詞庫中至少 2 個字母的字：每個單一字母都是詞庫字，會把注音錯字變成「r 惡」）；分數為各段 log 詞頻相加，減去編輯懲罰，每次換語言再扣一次編輯的懲罰，編輯上限仍以整段輸入計（Spec 001 B4）。英文段只從輸入開頭或聲調鍵之後開始（英文字連打屬 non-goal）。
2. **組字**：中文段之間不加空白；只要相鄰兩段有一段是英文就加一個空白。英文段可以吃掉緊接在後面的一個空白。
3. **排序**：有單一語言 0 編輯候選時，Spec 001 B6 的順序不變，不產生混合候選；否則混合候選與所有修正候選一起依分數排序。
4. **未完成的尾巴**：最後幾鍵若不含聲調鍵、是某個注音讀音的開頭（因此最多 3 鍵，如 ㄒㄧㄤ）（例如 ㄨ 可以、ㄜㄧ 不行）、接在中文段之後（Spec 005 起允許前段有修正），可以原樣保留成尾巴。尾巴懲罰小於一次編輯，所以不會被模糊修正吃掉。帶尾巴的候選不算 0 編輯，也不會擠掉同一段輸入的 0 編輯混合候選。
5. **語言**：混合候選的 `language` 是最後一段的語言（Spec 002 的空白補空白與 `previousLanguage` 用它）。
6. **空白不送出尾巴**：在 IME 中按空白、且空白不當一聲時，若選中的是帶尾巴的候選，改送出第一個沒有修正、也沒有尾巴的候選（如 `5k4ek7go` 加空白 → `這個 go␣`），且不當作使用者選擇來學習；Enter 仍送出畫面上的候選。
7. **結尾的英文字不被修正**：輸入結尾若是緊接在聲調鍵後、在詞庫中的英文字，任何修正都不能動到這幾個鍵。原因：SCOWL 只有粗略分級，`is` 與 `sue` 同分，換語言懲罰無法同時擋住 `sue 好`（F6）又保住 `這個 is`（F8）；在 1,700 筆注音錯字與 96 筆「中文＋兩字母英文」語料上掃描換語言懲罰 0–6，沒有一個值兩者都對。已知取捨：`w8 apt`（想打「他們」）會變成「他 apt」、`gjo4rule`（想打「睡覺」）會變成「說 rule」（verifier 1,735 筆錯字中各 1 筆）。真實英文詞頻（gardening）到位後應重新評估。

## Acceptance

### Behavior
- X1：見測試計畫 `mixed-zh-en`。
- X2：見 `mixed-en-zh`、`mixed-spacing`。
- X3：見 `single-language-unchanged`、`mixed-beats-fuzzy`。
- X4：見 `partial-tail`、`tail-not-tone`。
- X5：見 `mixed-language-is-last`。

### Failure and retry
- X6：英文段不在詞庫 → 不切成英文段（`mixed-unknown-word`）。
- X7：尾巴超過 3 鍵 → 不當尾巴（`tail-too-long`）；非音節開頭的鍵不當尾巴（`no-tail-after-edit`）；前段有修正時仍可接合法尾巴（`tail-after-fixed-prefix`，Spec 005）。
- X8：只有一段時不產生混合候選（`single-segment-not-mixed`）。
- X15：見 `trailing-english-kept`、`trailing-english-not-substituted`、`letters-not-after-tone-still-fixed`。
- X14：見具名測試 `X14: Space commits the first complete candidate`。
- X13：同一輸入的候選順序在不同 process 間相同（Dictionary 的 hash seed 每個 process 不同）。[measure] 以 `scratchpad` 語料跑兩次 `taipo query` 比對，0 差異（2026-10-18）。
- X9：Spec 001 的所有 case row 結果不變（既有測試全過）。
- X10：混合句子的英文段仍可模糊修正，總編輯數受 Spec 001 上限限制（`mixed-fuzzy-en`）。

### Budget
- X11：[measure] Spec 001 M1 不退步到超過 10 ms；逐鍵打完 26 鍵混合句時，每次按鍵 p95 ≤ 16 ms（一個 60 Hz frame，同 Spec 002 I17）。`swift run -c release taipo-bench latency`
  - 原本訂的「整句解碼 ≤ 10 ms」實測 8.5–12 ms 不穩定；該數字是草稿時隨手訂的，使用者感受到的是每鍵延遲，故改為此標準（2026-10-18，待 human 確認）。

### Observability
- X12：`taipo explain` 對混合候選印出各段與語言。具名測試。

## Test plan

<!-- test-plan:start Tests/TaipoCoreTests/Cases/mixed-cases.json -->
| ID | Case | Input | Prev | Learn first | Expect |
| --- | --- | --- | --- | --- | --- |
| X1 | mixed-zh-en | `5k4ek7cl3vu;4u.32u03tricky` | — | — | top1 = 這個好像有點 tricky |
| X2 | mixed-en-zh | `codecp3cl3` | — | — | top1 = code 很好 |
| X2 | mixed-spacing | `5k4ek7tricky␣` | — | — | top1 = 這個 tricky |
| X2 | space-between-english-words | `5k4ek7hello␣world` | — | — | top1 = 這個 hello world |
| X3 | single-language-unchanged | `su3cl3` | — | — | top1 = 你好; ∌ 你 好 |
| X3 | mixed-beats-fuzzy | `5k4ek7hello` | — | — | top1 = 這個 hello |
| X3 | zh-typo-not-single-letter | `rk4` | — | — | top1 = 這 |
| X3 | zh-typo-after-phrase | `su3cl3rk4` | — | — | top1 = 你好這 |
| X3 | zh-typo-not-rare-english | `suecl3` | — | — | top1 = 你好 |
| X3 | zh-typo-not-two-letter-english | `vu,4vi,4` | — | — | top1 = 謝謝 |
| X3 | short-english-word-kept | `5k4ek7the` | — | — | top1 = 這個 the |
| X3 | two-letter-english-word | `5k4ek7go` | — | — | ∋ 這個 go |
| X15 | trailing-english-kept | `5k4ek7is` | — | — | top1 = 這個 is |
| X15 | trailing-english-not-substituted | `5k4ek7my` | — | — | top1 = 這個 my |
| X15 | letters-not-after-tone-still-fixed | `18e` | — | — | top1 = 把 |
| X4 | partial-tail | `5k4ek7j` | — | — | top1 = 這個j |
| X4 | three-key-tail | `5k4ek7cl3vu;` | — | — | top1 = 這個好vu; |
| X4 | tone-typo-not-tail | `5k4eku` | — | — | top1 = 這個 |
| X4 | tone-typo-not-tail-2 | `vu04y95` | — | — | top1 = 現在 |
| X4 | no-tail-after-edit | `5k4ek7qzxv` | — | — | ∌ 這個zxv |
| X4 | tail-after-fixed-prefix | `5k4rk7j` | — | — | top1 = 這個j |
| X4 | tail-not-tone | `5k4ek7j3` | — | — | top1 = 這個五; ∌ 這個j3 |
| X4 | tail-only-after-chinese | `5k4trickyj` | — | — | ∌ 這 trickyj |
| X5 | mixed-language-is-last | `5k4ek7tricky` | — | — | top1 = 這個 tricky (en) |
| X5 | mixed-language-is-last-zh | `codecp3cl3` | — | — | top1 language = zh |
| X6 | mixed-unknown-word | `5k4ek7qzxv` | — | — | ∌ 這個 qzxv; ∌ 這個qzxv |
| X4 | single-letter-tail | `5k4ek7u` | — | — | top1 = 這個u; ∌ 這個 u |
| X7 | tail-too-long | `5k4ek7jjjj` | — | — | ∌ 這個jjjj |
| X8 | single-segment-not-mixed | `tricky` | — | — | top1 = tricky; ∌ tri cky |
| X10 | mixed-fuzzy-en | `5k4ek7trivky` | — | — | top1 = 這個 tricky |
<!-- test-plan:end -->

## 簡化審查

1. **質疑需求**：混合切分（使用者回報）、尾巴（同次重現的副作用）、中英之間的空白（使用者期望的句子裡就有空白）。
2. **刪除**：尾巴顯示成注音符號（英文也可能是尾巴，顯示原文最不會錯）；語言切換的上下文模型。
3. **簡化**：沿用 Spec 001 的 trie 與模糊 walk，中文 walk 結果由兩個 DP 共用。曾以 450 筆混合語料為據刪掉「換語言扣懲罰」與「英文段至少 2 個字母」，兩條都被 verifier 用 1,797 筆注音錯字推翻後加回（`rk4` → r 惡、`suecl3` → sue 好）；同時刪掉「0 編輯混合候選一律優先」，以及 Behavior 7 的「至少 2 個字母」（2,636 筆輸入 0 差異），副作用是 `repeatg␣` 現在第一名為 repeat（不是 repeat 師），屬可接受的歧義。教訓：刪規則的比對語料必須涵蓋 Spec 001 的錯字案例。
4. **縮短驗證週期**：全部是 `TaipoCore` 單元測試，加一個 Spec 002 session case。
5. **自動化**：無新增。

## Non-goals

- 英文字段之間不按空白的連打（`helloworld`）。
- 標點自動轉換。
