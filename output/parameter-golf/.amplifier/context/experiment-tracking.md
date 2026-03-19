# Experiment Tracking — Logs, Sweeps, and Metrics

## Log File Structure

Training logs live at: `logs/<run_id>.log`

Each log is a newline-delimited stream of timestamped entries written by `train_gpt.py`.
The `run_id` is either auto-generated (timestamp + config hash) or set via the sweep runner.

## Key Log Line Patterns

Use these regex patterns when parsing logs:

```
# Training progress — emitted every VAL_LOSS_EVERY steps
val_loss/val_bpb\s+step=(\d+)\s+loss=([\d.]+)\s+bpb=([\d.]+)

# Post-quantization roundtrip validation — appears at end of run
final_int8_zlib_roundtrip_exact:\s+(true|false)

# Artifact size — appears at end of run
Total submission size int8\+zlib:\s+([\d]+)\s+bytes

# Parameter count — appears at training start
model_params:\s+([\d,]+)

# Hit the wallclock limit (MAX_WALLCLOCK_SECONDS)
stopping_early:\s+wallclock_cap
```

## Sweep Runner Invocation

### Launch a sweep

```bash
python scripts/run_recurrent_qat_sweep.py run \
  --sweep-name <name> \
  --num-unique-blocks 2 3 4 \
  --block-share-strategy cycle grouped \
  --qat-start-fraction 0.5 0.7 \
  [additional grid dimensions...]
```

Each combination becomes one training run via `torchrun --nproc_per_node=8`.

### Summarize results

```bash
python scripts/run_recurrent_qat_sweep.py summarize \
  --sweep-name <name>
```

Outputs a TSV leaderboard ranked by `final_val_bpb`.

### Cross-sweep summarize

```bash
python scripts/run_recurrent_qat_sweep.py summarize \
  --sweep-name sweep_001 sweep_002 sweep_003
```

## Sweep Output Structure

```
sweeps/
└── <sweep_name>/
    ├── config.json          # Grid dimensions and sweep metadata
    ├── runs.json            # Per-run config records
    └── summary.tsv          # Leaderboard (written by summarize)
```

## Metrics That Matter (Ranked by Importance)

| Rank | Metric | Key | Notes |
|---|---|---|---|
| 1 | **Competition metric** | `final_val_bpb` | Post-quantization val BPB — this is what the leaderboard uses |
| 2 | Training signal | `best_prequant_val_bpb` | Pre-quant best — useful for diagnosing QAT timing |
| 3 | Size constraint | `total_submission_size_bytes` | Must be < 16,000,000 — hard disqualifier |
| 4 | Time constraint | `stop_step` / `wallclock_ms` | Did training hit wallclock cap? If yes, more iterations wouldn't help |

## Leaderboard TSV Format

`summary.tsv` has columns matching the `RunSummary` dataclass. Key columns:

| Column | Description |
|---|---|
| `run_id` | Unique run identifier |
| `final_val_bpb` | **Primary sort key** — competition metric |
| `best_prequant_val_bpb` | Best val_bpb before QAT |
| `total_submission_size_bytes` | Artifact size |
| `stop_step` | Step where training stopped |
| `wallclock_ms` | Total training time in ms |
| `num_unique_blocks` | Config: unique block count |
| `block_share_strategy` | Config: sharing strategy |
| `qat_start_fraction` | Config: QAT start point |
| `model_dim` | Config: hidden dimension |
| `num_layers` | Config: total layers |

## Cross-Sweep Comparison Methodology

1. **Merge TSVs** from multiple `summarize` runs into one DataFrame
2. **Group by each parameter** independently — compare mean `final_val_bpb` per value
3. **Interaction analysis** — cross-tabulate top-2 parameters to identify joint effects
4. **Monotonicity check** — does more of parameter X consistently help/hurt?
5. **Budget check** — flag any run where `total_submission_size_bytes ≥ 15,900,000`
   (within 100KB of limit) for size risk

**Reporting format:** Produce a structured report with:
- Top 5 configs ranked by `final_val_bpb`
- Per-parameter sensitivity table (mean BPB per value, with delta)
- Notable patterns (e.g., "cycle sharing beats grouped by ~0.003 at 3 unique blocks")
- Recommended next sweep dimensions based on patterns
