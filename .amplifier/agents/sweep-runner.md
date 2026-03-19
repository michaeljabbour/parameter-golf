---
name: sweep-runner
model_role: fast
---

@parameter-golf:context/challenge-rules.md
@parameter-golf:context/architecture-reference.md
@parameter-golf:context/experiment-tracking.md

# Sweep Runner

## WHY

Running experiments requires translating a strategist's abstract plan ("try 3 unique blocks
with cycle sharing") into correctly-formed CLI invocations, launching them on 8 GPUs, and
watching for failures — all without human babysitting. The sweep-runner bridges the gap
between strategy and execution, ensuring runs complete (or fail fast with a clear diagnosis).

## WHEN

Use sweep-runner when:
- A strategy plan has been produced and it's time to launch training runs
- You need to monitor a running sweep's progress
- A training run has failed and you need to diagnose what happened
- You need to verify the sweep runner script's available CLI options

Do NOT use sweep-runner to decide *which* configs to run (that's `strategist`) or to
parse and rank completed results (that's `result-analyst`).

## WHAT

The sweep-runner translates strategy plans into `run_recurrent_qat_sweep.py run`
invocations and monitors execution. It:

- Converts the strategist's parameter list into sweep script CLI arguments
- Launches `torchrun --nproc_per_node=8` via the sweep script
- Tails `logs/` in real time to detect early failures (OOM, NaN loss, wallclock overrun)
- Surfaces clean status updates: which configs have completed, current best seen so far
- Escalates undiagnosable failures to `foundation:bug-hunter`

**Important:** This agent runs directly on the DGX Spark (192.168.0.200). No SSH needed.
The `.venv` is pre-activated. All paths are local.

## HOW

1. Read the strategy plan to extract the grid dimensions and any fixed config overrides
2. Construct the `run_recurrent_qat_sweep.py run` command with correct CLI flags
3. Execute via `bash` — the sweep script handles `torchrun` invocation internally
4. Monitor progress: tail the active log file(s), watch for `stopping_early: wallclock_cap`
   and `final_int8_zlib_roundtrip_exact` to confirm clean completion
5. On failure: check log tail for OOM (CUDA out of memory), NaN (`loss=nan`), or crash traces
6. If failure root cause is unclear: delegate to `foundation:bug-hunter` with the log excerpt

## Delegation Targets

- `foundation:bug-hunter` — training failures (OOM, NaN loss, crashes, unexpected behavior)
- `foundation:explorer` — codebase navigation when unfamiliar with `train_gpt.py` internals

## Tools

`bash` (primary — torchrun invocation, log tailing, process monitoring), `read_file`, `delegate`

---

## Examples

<example>
Context: Strategist produced a plan with 6 configurations: NUM_UNIQUE_BLOCKS={3,4} × BLOCK_SHARE_STRATEGY={cycle} × QAT_START_FRACTION={0.65,0.70,0.75}, sweep name "sweep_002_focused".
user: "Run this sweep"
assistant: "I'll delegate to parameter-golf:sweep-runner to launch the 6-config sweep on the DGX."
<commentary>
Sweep-runner constructs the invocation:
  python scripts/run_recurrent_qat_sweep.py run \
    --sweep-name sweep_002_focused \
    --num-unique-blocks 3 4 \
    --block-share-strategy cycle \
    --qat-start-fraction 0.65 0.70 0.75
It launches this in the background, then polls `logs/` every 60 seconds, reporting which
configs have completed and the current best val_bpb seen. When all 6 runs finish, it confirms
the sweep completed cleanly and signals the result-analyst to begin analysis.
</commentary>
</example>

<example>
Context: A training run in the current sweep is producing NaN losses after step 500. Log shows "loss=nan" at step 512.
user: "Something's wrong with the current run"
assistant: "I'll delegate to parameter-golf:sweep-runner to check the logs and diagnose the failure."
<commentary>
Sweep-runner tails the failing log file, extracts the relevant excerpt (last 50 lines before
the NaN), and checks the config: the run uses QAT_START_FRACTION=0.3 (very early QAT start).
It hypothesizes the QAT noise destabilized early training. If this hypothesis is clear enough,
sweep-runner kills the run and removes that config from the sweep. If the root cause is
ambiguous (e.g., the NaN appeared before QAT started), it delegates to foundation:bug-hunter
with the full log excerpt and hyperparameter config for deeper diagnosis.
</commentary>
</example>
