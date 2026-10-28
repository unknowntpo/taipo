# Multi-typo recall (2026-10-19)

Question: would a learned key-sequence embedding (similarity search) help TaipoCore find candidates?
Measured first whether candidate generation is the bottleneck.

- Corpus: `scripts/make_typo_corpus.py` → `docs/research/typo-recall-corpus.tsv` (1,605 rows; common
  multi-character phrases and two-phrase combinations with 1–3 random slips: adjacent substitution,
  transposition, extra key, missing key).
- Command: `cut -f1 docs/research/typo-recall-corpus.tsv | TAIPO_TOP=20 .build/release/taipo batch`
- Results: `docs/research/typo-recall-results.txt`.

| typos | kind | top-20 recall, budget 1/2 (current) | top-20 recall, budget 2/3 |
| --- | --- | --- | --- |
| 1 | phrase | 99.2% | 99.2% |
| 1 | two phrases | 91.2% | 91.2% |
| 2 | phrase | 73.7% | 94.1% |
| 2 | two phrases | 81.1% | 82.2% |
| 3 | phrase | 21.7% | 74.8% |
| 3 | two phrases | 13.1% | 61.7% |

Findings:
1. Recall collapses beyond the edit budget (3 slips: ~20%). Generation, not only ranking, limits multi-typo input.
2. A higher budget recovers most of it but the batch took 58 s vs 10 s (system load average ~166 during both runs, so only the ratio is meaningful).
3. Two-phrase inputs stay at ~91% even with one slip under either budget: the sentence DP keeps one path per edit count, so alternatives for multi-phrase input are missing. That is independent of the budget.

Not done: no embedding prototype; latency not measured per keystroke on an idle machine.

## Follow-up: Spec 006 (2026-10-19)

Implemented the two cheap fixes instead of an embedding: two paths per DP cell, and an adaptive
retry (budget 2→3, at most one missing-key edit) that runs only after a typing pause. Results in
`docs/specs/006-recall/evidence/recall.txt`: three-slip top-20 recall 21.7% → 58.8% (phrase),
13.1% → 64.0% (two phrases), with per-keystroke p95 still ≤ 16 ms. Retrying on every keystroke
was measured at 25–99 ms for long input and rejected.
