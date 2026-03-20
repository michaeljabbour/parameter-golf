#!/bin/bash
# =============================================================================
# Parameter Golf — RunPod 8×H100 Full-Scale Deployment Script
# =============================================================================
# Usage: SSH into your RunPod pod, then:
#   git clone https://github.com/michaeljabbour/parameter-golf.git
#   cd parameter-golf
#   bash scripts/runpod_deploy.sh
#
# Or run individual phases:
#   bash scripts/runpod_deploy.sh setup      # Install deps + download data only
#   bash scripts/runpod_deploy.sh run        # Run the winning config
#   bash scripts/runpod_deploy.sh sweep      # Run a mini-sweep of top configs
# =============================================================================

set -euo pipefail

REPO_DIR="${REPO_DIR:-/workspace/parameter-golf}"
DATA_VARIANT="${DATA_VARIANT:-sp1024}"
NPROC="${NPROC:-8}"

# ---------------------------------------------------------------------------
# Phase 0: Setup (deps + data download)
# ---------------------------------------------------------------------------
setup() {
    echo "=== SETUP: Installing dependencies ==="
    cd "$REPO_DIR"
    pip install -r requirements.txt 2>&1 | tail -5

    echo ""
    echo "=== SETUP: Downloading FineWeb data (${DATA_VARIANT}) ==="
    python3 data/cached_challenge_fineweb.py --variant "$DATA_VARIANT"

    echo ""
    echo "=== SETUP: Verifying GPU availability ==="
    nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader
    GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)
    echo "Found $GPU_COUNT GPUs (need $NPROC for competition runs)"

    if [ "$GPU_COUNT" -lt "$NPROC" ]; then
        echo "WARNING: Only $GPU_COUNT GPUs available, need $NPROC"
        echo "Adjust NPROC=$GPU_COUNT or get a bigger pod"
    fi

    echo ""
    echo "=== SETUP COMPLETE ==="
}

# ---------------------------------------------------------------------------
# Phase 1: Run the champion config (u3_d832_grouped)
# ---------------------------------------------------------------------------
run_champion() {
    echo "=== RUNNING: u3_d832_grouped (champion config) ==="
    echo "Config: 9 layers, 3 unique blocks, grouped, dim=832, 15.4M params"
    echo "Budget: 524K batch, 20K iters, 600s wallclock, ${NPROC} GPUs"
    echo ""

    cd "$REPO_DIR"

    RUN_ID="${RUN_ID:-u3_d832_grouped_8gpu_$(date +%Y%m%d_%H%M%S)}" \
    DATA_PATH=./data/datasets/fineweb10B_sp1024 \
    TOKENIZER_PATH=./data/tokenizers/fineweb_1024_bpe.model \
    VOCAB_SIZE=1024 \
    NUM_LAYERS=9 \
    NUM_UNIQUE_BLOCKS=3 \
    BLOCK_SHARE_STRATEGY=grouped \
    MODEL_DIM=832 \
    NUM_HEADS=8 \
    NUM_KV_HEADS=4 \
    MLP_MULT=2 \
    TIE_EMBEDDINGS=1 \
    QAT_ENABLE=0 \
    TRAIN_BATCH_TOKENS=524288 \
    TRAIN_SEQ_LEN=1024 \
    ITERATIONS=20000 \
    MAX_WALLCLOCK_SECONDS=600 \
    WARMUP_STEPS=20 \
    WARMDOWN_ITERS=1200 \
    VAL_LOSS_EVERY=1000 \
    TRAIN_LOG_EVERY=200 \
    TORCH_COMPILE=1 \
    torchrun --standalone --nproc_per_node="$NPROC" train_gpt.py \
        2>&1 | tee "logs/${RUN_ID}.txt"

    echo ""
    echo "=== RUN COMPLETE ==="
    echo "Log: logs/${RUN_ID}.txt"
    grep "final_int8_zlib_roundtrip_exact" "logs/${RUN_ID}.txt" || echo "WARNING: No final roundtrip found"
    grep "Total submission size" "logs/${RUN_ID}.txt" || echo "WARNING: No submission size found"
}

# ---------------------------------------------------------------------------
# Phase 2: Run champion with QAT (best QAT fraction from Phase 2 was 0.7)
# ---------------------------------------------------------------------------
run_champion_qat() {
    echo "=== RUNNING: u3_d832_grouped + QAT@0.7 ==="

    cd "$REPO_DIR"

    RUN_ID="${RUN_ID:-u3_d832_grouped_qat07_8gpu_$(date +%Y%m%d_%H%M%S)}" \
    DATA_PATH=./data/datasets/fineweb10B_sp1024 \
    TOKENIZER_PATH=./data/tokenizers/fineweb_1024_bpe.model \
    VOCAB_SIZE=1024 \
    NUM_LAYERS=9 \
    NUM_UNIQUE_BLOCKS=3 \
    BLOCK_SHARE_STRATEGY=grouped \
    MODEL_DIM=832 \
    NUM_HEADS=8 \
    NUM_KV_HEADS=4 \
    MLP_MULT=2 \
    TIE_EMBEDDINGS=1 \
    QAT_ENABLE=1 \
    QAT_START_FRACTION=0.7 \
    TRAIN_BATCH_TOKENS=524288 \
    TRAIN_SEQ_LEN=1024 \
    ITERATIONS=20000 \
    MAX_WALLCLOCK_SECONDS=600 \
    WARMUP_STEPS=20 \
    WARMDOWN_ITERS=1200 \
    VAL_LOSS_EVERY=1000 \
    TRAIN_LOG_EVERY=200 \
    TORCH_COMPILE=1 \
    torchrun --standalone --nproc_per_node="$NPROC" train_gpt.py \
        2>&1 | tee "logs/${RUN_ID}.txt"

    echo ""
    echo "=== RUN COMPLETE ==="
    grep "final_int8_zlib_roundtrip_exact" "logs/${RUN_ID}.txt" || true
    grep "Total submission size" "logs/${RUN_ID}.txt" || true
}

# ---------------------------------------------------------------------------
# Phase 3: Mini-sweep of top 3 configs at full scale
# ---------------------------------------------------------------------------
run_sweep() {
    echo "=== SWEEP: Top 3 configs at full scale ==="

    CONFIGS=(
        "u3_d832_grouped:NUM_UNIQUE_BLOCKS=3:MODEL_DIM=832:BLOCK_SHARE_STRATEGY=grouped:QAT_ENABLE=0"
        "u4_d768_grouped:NUM_UNIQUE_BLOCKS=4:MODEL_DIM=768:BLOCK_SHARE_STRATEGY=grouped:QAT_ENABLE=0"
        "u3_d832_grouped_qat07:NUM_UNIQUE_BLOCKS=3:MODEL_DIM=832:BLOCK_SHARE_STRATEGY=grouped:QAT_ENABLE=1:QAT_START_FRACTION=0.7"
    )

    cd "$REPO_DIR"
    mkdir -p logs

    for CONFIG in "${CONFIGS[@]}"; do
        IFS=':' read -r NAME REST <<< "$CONFIG"
        RUN_ID="fullscale_${NAME}_$(date +%Y%m%d_%H%M%S)"

        echo ""
        echo "--- Starting: $NAME (run_id: $RUN_ID) ---"

        # Parse env vars from config string
        ENV_CMD=""
        IFS=':' read -ra PARTS <<< "$CONFIG"
        for i in "${!PARTS[@]}"; do
            [ "$i" -eq 0 ] && continue  # skip name
            ENV_CMD="$ENV_CMD ${PARTS[$i]}"
        done

        env \
            RUN_ID="$RUN_ID" \
            DATA_PATH=./data/datasets/fineweb10B_sp1024 \
            TOKENIZER_PATH=./data/tokenizers/fineweb_1024_bpe.model \
            VOCAB_SIZE=1024 \
            NUM_LAYERS=9 \
            NUM_HEADS=8 \
            NUM_KV_HEADS=4 \
            MLP_MULT=2 \
            TIE_EMBEDDINGS=1 \
            TRAIN_BATCH_TOKENS=524288 \
            TRAIN_SEQ_LEN=1024 \
            ITERATIONS=20000 \
            MAX_WALLCLOCK_SECONDS=600 \
            WARMUP_STEPS=20 \
            WARMDOWN_ITERS=1200 \
            VAL_LOSS_EVERY=500 \
            TRAIN_LOG_EVERY=100 \
            TORCH_COMPILE=1 \
            $ENV_CMD \
            torchrun --standalone --nproc_per_node="$NPROC" train_gpt.py \
                2>&1 | tee "logs/${RUN_ID}.txt"

        echo "--- Done: $NAME ---"
        grep "final_int8_zlib_roundtrip_exact" "logs/${RUN_ID}.txt" 2>/dev/null || echo "  WARNING: No final result"
        grep "Total submission size" "logs/${RUN_ID}.txt" 2>/dev/null || echo "  WARNING: No size data"
        echo ""
    done

    echo "=== SWEEP COMPLETE ==="
    echo ""
    echo "=== RESULTS SUMMARY ==="
    for f in logs/fullscale_*.txt; do
        NAME=$(basename "$f" .txt)
        BPB=$(grep "final_int8_zlib_roundtrip_exact" "$f" 2>/dev/null | head -1 | sed 's/.*val_bpb://')
        SIZE=$(grep "Total submission size int8" "$f" 2>/dev/null | head -1 | sed 's/.*: //; s/ bytes//')
        echo "$NAME | bpb=$BPB | size=$SIZE"
    done | sort -t= -k2 -n
}

# ---------------------------------------------------------------------------
# Phase 4: Quick results summary
# ---------------------------------------------------------------------------
summary() {
    echo "=== ALL FULL-SCALE RESULTS ==="
    cd "$REPO_DIR"
    for f in logs/*8gpu*.txt logs/fullscale_*.txt; do
        [ -f "$f" ] || continue
        NAME=$(basename "$f" .txt)
        BPB=$(grep "final_int8_zlib_roundtrip_exact" "$f" 2>/dev/null | head -1 | sed 's/.*val_bpb://')
        SIZE=$(grep "Total submission size int8" "$f" 2>/dev/null | head -1 | sed 's/.*: //; s/ bytes//')
        PARAMS=$(grep "^model_params:" "$f" 2>/dev/null | head -1 | sed 's/model_params://')
        WALL=$(grep "stopping_early\|step:.*train_time:" "$f" 2>/dev/null | tail -1)
        if [ -n "$BPB" ]; then
            SIZE_MB=$(echo "scale=2; $SIZE / 1048576" | bc 2>/dev/null)
            echo "DONE $NAME | bpb=$BPB | ${SIZE_MB}MB | params=$PARAMS"
        else
            LAST=$(grep "^step:" "$f" 2>/dev/null | tail -1)
            echo "RUN  $NAME | $LAST"
        fi
    done | sort -t= -k2 -n
}

# ---------------------------------------------------------------------------
# Main dispatcher
# ---------------------------------------------------------------------------
case "${1:-all}" in
    setup)          setup ;;
    run|champion)   run_champion ;;
    qat)            run_champion_qat ;;
    sweep)          run_sweep ;;
    summary)        summary ;;
    all)
        setup
        echo ""
        echo "============================================="
        echo "Setup complete. Starting champion run..."
        echo "============================================="
        echo ""
        run_champion
        ;;
    *)
        echo "Usage: $0 {setup|run|qat|sweep|summary|all}"
        echo ""
        echo "  setup    — Install deps + download data"
        echo "  run      — Run champion config (u3_d832_grouped)"
        echo "  qat      — Run champion + QAT@0.7"
        echo "  sweep    — Mini-sweep of top 3 configs"
        echo "  summary  — Show all full-scale results"
        echo "  all      — Setup + run champion (default)"
        exit 1
        ;;
esac
