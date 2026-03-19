# Architecture Reference — Parameter Golf Baseline

## Baseline Architecture

| Property | Value |
|---|---|
| Layers | 9 |
| Model dim | 512 |
| Attention heads | 8 Q-heads / 4 KV-heads (GQA) |
| Parameters | ~17M |
| Vocabulary | 1024 tokens, SentencePiece BPE |
| Embeddings | Tied (input ↔ output) |
| Recurrence | Block sharing via `BLOCK_SHARE_STRATEGY` |

## Baseline Performance

| Variant | val_bpb |
|---|---|
| SOTA (10-min, 8×H100) | **1.2244** |
| 4-hour unlimited | 1.2074 |
| Gap (architecture headroom) | 0.0170 |

**Key insight:** The 4-hour run is only 0.017 val_bpb better than the 10-minute run.
This means **more training time has sharply diminishing returns** — architecture changes
and quantization-aware training are the primary levers, not longer runs.

## Artifact Budget

| Component | Size |
|---|---|
| Baseline post-int8+zlib | ~15.86 MB |
| Limit | 16.00 MB |
| Headroom | ~137 KB |

Adding code to `train_gpt.py` directly reduces the model size budget. Each architectural
change must be evaluated for its code-byte cost vs. val_bpb improvement.

## Environment Variable Knobs (`train_gpt.py` → `Hyperparameters` class)

### Model Shape
| Variable | Effect |
|---|---|
| `NUM_LAYERS` | Total transformer layers (logical depth) |
| `NUM_UNIQUE_BLOCKS` | Unique block definitions (recurrence depth) |
| `BLOCK_SHARE_STRATEGY` | How unique blocks are tiled: `cycle`, `grouped`, `interleaved` |
| `LOGICAL_LAYER_CONTROLS` | Per-layer control overrides |
| `MODEL_DIM` | Hidden dimension |
| `NUM_HEADS` | Number of query attention heads |
| `NUM_KV_HEADS` | Number of key/value heads (GQA ratio = NUM_HEADS / NUM_KV_HEADS) |
| `MLP_MULT` | MLP intermediate dim multiplier |
| `VOCAB_SIZE` | Vocabulary size |
| `TIE_EMBEDDINGS` | Tie input and output embeddings (bool) |
| `ROPE_BASE` | RoPE base frequency |
| `LOGIT_SOFTCAP` | Logit soft-capping value (0 = disabled) |

### Training Schedule
| Variable | Effect |
|---|---|
| `ITERATIONS` | Total training steps |
| `WARMDOWN_ITERS` | LR warmdown duration (steps) |
| `WARMUP_STEPS` | LR warmup duration (steps) |
| `TRAIN_BATCH_TOKENS` | Tokens per gradient step |
| `TRAIN_SEQ_LEN` | Sequence length |
| `MAX_WALLCLOCK_SECONDS` | Hard stop at this many seconds (use 590 for 10-min runs) |
| `VAL_LOSS_EVERY` | Validation frequency (steps) |
| `SEED` | Random seed (fix for reproducibility) |

### Optimizer (Muon)
| Variable | Effect |
|---|---|
| `EMBED_LR` | Learning rate for embedding parameters |
| `HEAD_LR` | Learning rate for attention head parameters |
| `TIED_EMBED_LR` | LR for tied embedding (when `TIE_EMBEDDINGS=1`) |
| `MATRIX_LR` | LR for weight matrices |
| `SCALAR_LR` | LR for scalar parameters |
| `MUON_MOMENTUM` | Muon optimizer momentum |
| `MUON_BACKEND_STEPS` | Muon backend Newton-Schulz steps |
| `BETA1` | Adam β₁ |
| `BETA2` | Adam β₂ |
| `GRAD_CLIP_NORM` | Gradient clipping norm |

### Quantization-Aware Training (QAT)
| Variable | Effect |
|---|---|
| `QAT_ENABLE` | Enable QAT (bool) |
| `QAT_START_STEP` | Absolute step to begin QAT |
| `QAT_START_FRACTION` | Fraction of total steps to begin QAT (alternative to step) |

### System
| Variable | Effect |
|---|---|
| `PREFER_CUDA` | Force CUDA device selection (bool) |
| `TORCH_COMPILE` | Enable `torch.compile` (bool) |

## Promising Directions

1. **Block sharing strategy:** `cycle` vs `grouped` vs `interleaved` — different sharing
   patterns change the effective receptive field of the recurrent layers
2. **QAT timing:** Earlier QAT start (smaller `QAT_START_FRACTION`) gives more
   quant-aware steps but less pre-quant convergence — tradeoff to tune
3. **Width vs. depth:** Wider models (`MODEL_DIM`) with fewer unique blocks may fit more
   capacity in the same parameter budget than deep narrow models
4. **GQA ratio:** Varying `NUM_KV_HEADS` (1, 2, 4) trades memory for attention quality
5. **Vocab size:** Larger vocab improves BPE compression but costs model capacity budget
