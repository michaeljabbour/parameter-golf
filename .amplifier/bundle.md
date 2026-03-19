---
bundle:
  name: parameter-golf
  version: 0.1.0
  description: |
    Orchestrates solving the OpenAI Parameter Golf challenge.
    Manages experiment sweeps, result analysis, code optimization,
    and submission packaging for minimal val_bpb on 8×H100.

includes:
  - bundle: git+https://github.com/microsoft/amplifier-foundation@v1.0.0
  - behavior: behaviors/parameter-golf

provenance:
  generator: bundlewizard
  version: "1"
  convergence_iterations: 1
  final_evaluation:
    level_1: pass
    level_2: 0.935
    level_3: 0.90
  generated: "2026-03-19"
---

# Parameter Golf Bundle

Orchestrates the OpenAI Parameter Golf challenge — lowest `val_bpb` within the 16 MB / 10-minute constraint on 8×H100.

## Modes

| Mode | Purpose |
|---|---|
| `/pg-strategize` | Plan next experiments — analyze results, design sweep configs |
| `/pg-sweep` | Launch and monitor training runs on the DGX Spark |
| `/pg-analyze` | Deep-dive results — parse logs, rank configs, identify patterns |
| `/pg-optimize` | Surgical code changes to train_gpt.py — add knobs, modify architecture |
| `/pg-submit` | Prepare submission artifacts, validate constraints, open PR |

## Agents

| Agent | Role | Model |
|---|---|---|
| `strategist` | Designs experiment strategy from accumulated results | reasoning (120B) |
| `sweep-runner` | Launches and monitors training sweeps | fast (20B) |
| `result-analyst` | Parses logs, builds leaderboards, finds patterns | coding (Qwen3) |
| `code-optimizer` | Makes surgical changes to `train_gpt.py` | coding (Qwen3) |
| `submission-packager` | Packages and validates challenge submissions | coding (Qwen3) |

## Recipes

| Recipe | Purpose |
|---|---|
| `single-experiment` | Run one training config end-to-end and report |
| `sweep-cycle` | Convergence loop: strategize → sweep → analyze → repeat |
| `full-solve` | End-to-end solve with human gates at strategic pivots |
