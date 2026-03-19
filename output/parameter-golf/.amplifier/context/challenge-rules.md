# Challenge Rules — OpenAI Parameter Golf

## Hard Constraints

### Artifact Size
- **Limit:** ≤ 16,000,000 bytes total
- **Counted as:** UTF-8 bytes of `train_gpt.py` code **+** compressed model bytes (int8 weights + zlib)
- Baseline sits at ~15.86 MB — only ~137 KB of headroom. Every byte of code added costs model capacity.

### Training Time
- **Wallclock limit:** 10 minutes on 8×H100 SXM
- Training script must complete (or gracefully stop via `MAX_WALLCLOCK_SECONDS`) within this window
- `stopping_early: wallclock_cap` in the log confirms the run hit the limit

### Evaluation
- **Evaluation cap:** 10 minutes (separate from training)
- Evaluation must be reproducible from the submitted `train_gpt.py` alone

## Self-Containment
- **No external downloads or network calls during evaluation**
- All weights, tokenizer data, and logic must be embedded in or derived from `train_gpt.py`
- Exception: the training dataset is provided by the evaluation harness

## Reproducibility
- Results that cannot be reproduced are **disqualified**
- Fix the random seed (`SEED` env var) and verify cross-run consistency before submitting
- `final_int8_zlib_roundtrip_exact` in the log confirms the quantization is bit-exact

## Improvement Bar
- New SOTA must beat the existing record by **≥ 0.005 nats** (val_bpb units)
- Statistical significance required: **p < 0.01**
- Current SOTA: `val_bpb = 1.2244`
- Target to beat: `val_bpb ≤ 1.2194`

## Code Location Rules
- All counted code must live in **`train_gpt.py`**
- Upstream convention: **≤ 1500 lines** (hard to enforce but strongly expected)
- Helper scripts (`scripts/`, `data/`) are not counted but cannot be called during evaluation

## Tokenizer Scrutiny
- Tokenizer changes are **heavily scrutinized** by reviewers
- If you change the tokenizer, you must prove BPB correctness rigorously
- The baseline uses 1024-vocab SentencePiece BPE with tied embeddings

## Submission Format

Folder: `records/track_10min_16mb/<submission_name>/`

Required files:
| File | Contents |
|---|---|
| `README.md` | Detailed explanation of approach, architecture changes, and why it works |
| `submission.json` | Leaderboard metadata (val_bpb, artifact size, run config) |
| `train.log` | Exact training log from the winning run |
| `train_gpt.py` | Self-contained training script — must reproduce the submitted result |

## Deadline

**April 30, 2026**

## Key Violation Triggers

- Artifact > 16 MB → automatic disqualification
- Training wallclock > 10 min without `MAX_WALLCLOCK_SECONDS` guard → disqualification
- Non-reproducible result → disqualification
- External network call in `train_gpt.py` → disqualification
- Improvement < 0.005 nats over existing SOTA → not accepted as new record
