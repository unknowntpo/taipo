# Gardening

已知的權宜之計與後續事項。新增權宜之計時必須在此登記；能刪掉就不要解釋。

| 項目 | 來源 | 建議處理 |
| --- | --- | --- |
| 英文詞頻只有 SCOWL 級別（35–60），同級字同分（the／ten），以「對調 ×0.8」打破 | Spec 001 D2 | 取得真實英文詞頻（例如 Google Books Ngram，CC BY 3.0）；需 human 同意下載與授權 |
| 英文屈折形由 `scripts/build_lexicon.py` 規則產生，會產生雜訊字（如 `anoning`、`adrifted`），且缺不規則變化（ran） | Spec 001 實作 | 換成 SCOWL 完整建置輸出或 hunspell 字典展開 |
| B5「0 編輯優先」讓罕見精確字壓過常見修正：`s96`→孻 先於 來、`baldy` 先於 badly | Spec 001 mutation 找到的真實案例 | 需 human 決定是否改規則（例如精確字詞頻過低時允許修正勝出） |
| `taipo-dev` 的 gate 沒有自己的測試，只做過手動 mutation（traceability 曾因全形冒號而永遠通過） | Spec 001 實作 | 為兩個 gate 加 fixture 測試 |
| libtabe 的 BSD 授權全文尚未收進 THIRD_PARTY_NOTICES.md | Spec 001 D2 | 對外發佈前補上（需從 libtabe 原始碼取得） |
| 結尾多個空白也算進編輯上限，`ji3␣␣` 只剩原文 | Spec 001 verifier | 決定解碼前是否修剪多餘空白 |
| 超過 32 鍵時繞過已學習的選擇；英文接受 `'` 但詞庫沒有含撇號的字 | Spec 001 verifier | 低優先 |
| M3 量的是 page cache 已熱的載入時間，不是真正的冷啟動 | Spec 001 verifier | 需要時用 `purge` 後量測 |
| 使用者字典 `{}`（缺 `version`）也被當成損毀並隔離 | Spec 001 verifier | 可放寬為缺欄位用預設值 |
| IMKCandidates 顯示時是否攔截 ↑↓／Enter 尚未在真機確認 | Spec 002 verifier | I12 真機測試時一併確認 |
| 註冊輸入法時，注音模式因 `tsInputModeDefaultStateKey` 預設為 enabled | Spec 002 安裝 | 確認是否要改成 false，讓使用者自己加 |
| 詞庫缺少只以大寫收錄的常用字（OK、TV 等），因為 build_lexicon.py 只收全小寫 | Spec 003 verifier 期間發現 | 收錄大寫字並以小寫為鍵 |
| 刪鍵比用詞解釋按鍵便宜：`5k4ek7go` 的「這個」（刪 2 鍵，−12）排在「這個 go」（換語言 −6 加 go 的 log 詞頻約 −10）前 | Spec 003 X14 | 考慮讓 extra 編輯的懲罰隨被刪的鍵是否能組成詞而調整 |
