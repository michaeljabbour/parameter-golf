#!/bin/bash
# =============================================================================
# Parameter Golf — Validation Sweep (3 runs to find the winning config)
# =============================================================================
# Run 1: Reproduce SOTA baseline (no sharing) — is our code clean?
# Run 2: Baseline + QAT@0.7 — does QAT alone beat SOTA?
# Run 3: Mild sharing + modest width — does speed-matched sharing help?
# =============================================================================
set -euo pipefail

REPO_DIR="${REPO_DIR:-/workspace/parameter-golf}"
NPROC="${NPROC:-8}"

cd "$REPO_DIR"
mkdir -p logs

# Common args for all runs
COMMON="DATA_PATH=./data/datasets/fineweb10B_sp1024 \
TOKENIZER_PATH=./data/tokenizers/fineweb_1024_bpe.model \
VOCAB_SIZE=1024 NUM_LAYERS=9 NUM_HEADS=8 NUM_KV_HEADS=4 MLP_MULT=2 \
TIE_EMBEDDINGS=1 TRAIN_BATCH_TOKENS=524288 TRAIN_SEQ_LEN=1024 \
ITERATIONS=20000 MAX_WALLCLOCK_SECONDS=600 WARMUP_STEPS=20 \
WARMDOWN_ITERS=1200 VAL_LOSS_EVERY=1000 TRAIN_LOG_EVERY=200 TORCH_COMPILE=1"

run_config() {
    local NAME="$1"; shift
    local LOG="logs/validation_${NAME}.txt"

    echo ""
    echo "================================================================"
    echo "  RUN: $NAME"
    echo "  Start: $(date)"
    echo "================================================================"
    echo ""

    env $COMMON "$@" RUN_ID="validation_${NAME}" \
        torchrun --standalone --nproc_per_node="$NPROC" train_gpt.py \
        2>&1 | tee "$LOG"

    echo ""
    echo "=== $NAME COMPLETE: $(date) ==="
    grep "final_int8_zlib_roundtrip_exact" "$LOG" 2>/dev/null || echo "  NO FINAL RESULT"
    grep "Total submission size int8" "$LOG" 2>/dev/null || echo "  NO SIZE DATA"
    grep "stopping_early\|step:.*/20000.*train_time" "$LOG" 2>/dev/null | tail -1
    echo ""
}

# ──────────────────────────────────────────────────────────────
# Run 1: CONTROL — Reproduce SOTA baseline (no block sharing)
# ──────────────────────────────────────────────────────────────
# This is the original baseline config: 9 layers, all unique,
# dim=512. Should match SOTA ~1.2244 if our code is clean.
run_config "baseline_u9_d512" \
    NUM_UNIQUE_BLOCKS=9 BLOCK_SHARE_STRATEGY=cycle \
    MODEL_DIM=512 QAT_ENABLE=0

# ──────────────────────────────────────────────────────────────
# Run 2: BASELINE + QAT@0.7 — Free improvement?
# ──────────────────────────────────────────────────────────────
# Same baseline, but with QAT enabled at 70% of training.
# SOTA had no QAT → ~0.007 quant gap. If QAT closes it, we win.
run_config "baseline_u9_d512_qat07" \
    NUM_UNIQUE_BLOCKS=9 BLOCK_SHARE_STRATEGY=cycle \
    MODEL_DIM=512 QAT_ENABLE=1 QAT_START_FRACTION=0.7

# ──────────────────────────────────────────────────────────────
# Run 3: MILD SHARING + MODEST WIDTH — Speed-matched
# ──────────────────────────────────────────────────────────────
# 6 unique blocks (minimal sharing), dim=576 (slightly wider).
# Should be nearly as fast as baseline per step.
run_config "mild_u6_d576_grouped" \
    NUM_UNIQUE_BLOCKS=6 BLOCK_SHARE_STRATEGY=grouped \
    MODEL_DIM=576 QAT_ENABLE=0

# ──────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  VALIDATION SWEEP COMPLETE — $(date)"
echo "================================================================"
echo ""
echo "RESULTS (ranked by val_bpb):"
for f in logs/validation_*.txt; do
    NAME=$(basename "$f" .txt | sed 's/validation_//')
    BPB=$(grep "final_int8_zlib_roundtrip_exact" "$f" 2>/dev/null | head -1 | sed 's/.*val_bpb://')
    SIZE=$(grep "Total submission size int8" "$f" 2>/dev/null | head -1 | sed 's/.*: //; s/ bytes//')
    STEPS=$(grep "stopping_early" "$f" 2>/dev/null | grep -oP 'step:\K[0-9]+' || grep "^step:.*/20000" "$f" 2>/dev/null | tail -1 | grep -oP 'step:\K[0-9]+')
    STEPAVG=$(grep "stopping_early\|^step:.*/20000" "$f" 2>/dev/null | tail -1 | grep -oP 'step_avg:\K[0-9.]+')
    if [ -n "$BPB" ]; then
        SIZE_MB=$(echo "scale=2; $SIZE / 1048576" | bc 2>/dev/null)
        echo "  $BPB | ${SIZE_MB}MB | ${STEPS} steps | ${STEPAVG}ms/step | $NAME"
    fi
done | sort -n
echo ""
echo "SOTA target: val_bpb <= 1.2194 (beat 1.2244 by >= 0.005)"
echo ""
echo "To stop the pod: curl the RunPod API or use the dashboard."
