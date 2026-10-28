# Workflow

本 repo 採用 AI spec-driven development（參考 `unknowntpo/oss-knowledge-base` 的 `docs/process/workflow.md`）。

## 角色

- **Human**：擁有意圖與取捨。審 spec 的 Example、簡化審查、測試計畫與 verifier 判決；不逐行審 diff。
- **Implementer agent**：在已接受的 spec 下做最小變更，先寫測試，逐行自我審查。
- **Independent verifier**：另一個 agent，只拿 spec 路徑、commit SHA 與執行方式。
- **Machines**：CI、traceability、test-plan 一致性、量測。

一個 PR 一個意圖。

## Spec

- 從 `docs/specs/_template/spec.md` 開始。
- Example 用真實資料，標明擷取時間與來源。
- 簡化審查依序：質疑需求 → 刪除 → 簡化 → 縮短驗證週期 → 最後才自動化。
- Acceptance 分四類：Behavior、Failure and retry（數量 ≥ Behavior）、Budget、Observability。
- Acceptance ID（`B1`、`F2`、`M1`…）是 join key：spec → 測試名稱含 `ID:` → PR 描述。只能靠量測證明的標 `[measure]`，只能由 human 在真機確認的標 `[manual]`。
- 測試計畫表格的資料放在 case file（`Tests/**/Cases/*.json`），Swift Testing 以 `@Test(arguments:)` 迭代；由 script 渲染進 spec 的 `<!-- test-plan:start … -->` 區塊。
- Behavior 中每個邊界兩側各一個 case。新 spec 或 spec 變更需 human 接受後才實作。

## Gates

| Gate | 指令 | 何時加入 |
| --- | --- | --- |
| Build + unit tests | `swift test` | Spec 001 slice 1 |
| Traceability | `swift run taipo-dev check-traceability` | Spec 001 slice 1 |
| Test plan 一致性 | `swift run taipo-dev render-test-plan --check` | Spec 001 slice 1 |
| Budget | `swift run -c release taipo-bench` | Spec 001 |

本機先綠 → CI（GitHub Actions, macOS runner）→ 才 merge。

## 實作

- 先寫測試並記錄失敗輸出；從沒看過失敗的測試不算證據。
- 「不出現」類測試要在同一條輸入路徑上搭配正向對照。
- 每個 acceptance behavior 至少一個 mutation，列出 caught / surviving。

## 驗證與 merge

- Verifier 只信執行結果，逐 ID 給 pass / fail / unverifiable 與證據，並自己跑 mutation。
- 任何新 commit 都使判決失效，需在最終 commit 重驗。
- Core decision（新意圖、資料格式、授權、公開發佈、上架、刪除）需先與 human 對齊。
- 已接受 spec 的實作、測試、工具、重構：gates 綠＋verifier 通過即可自行 merge，事後一行回報。Markdown-only PR 只需 gates 綠。
