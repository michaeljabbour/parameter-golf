# Parameter Golf Bundle — Root Instructions

## Identity

This bundle orchestrates solving the **OpenAI Parameter Golf challenge**: achieve the
lowest possible `val_bpb` within the 16 MB compressed artifact / 10-minute training
constraint on 8×H100 GPUs at `/home/mjabbour/dev/parameter-golf`.

## Agent Routing Table

| Request type | Agent | Model |
|---|---|---|
| What experiments to run next / strategy decisions | `strategist` | reasoning (120B, .200) |
| Launch or monitor training sweeps | `sweep-runner` | fast (20B, .202) |
| Parse logs, rank configs, identify patterns | `result-analyst` | coding (Qwen3, .201) |
| Modify `train_gpt.py` — new knobs, architecture tweaks | `code-optimizer` | coding (Qwen3, .201) |
| Prepare submission folder, validate constraints | `submission-packager` | writing |

## Mode Quick-Reference

| Mode | Purpose |
|---|---|
| `/pg-strategize` | Plan next experiments — review results, design sweep configs |
| `/pg-sweep` | Launch and monitor training runs on the DGX |
| `/pg-analyze` | Deep-dive results — parse logs, compare configs, surface patterns |
| `/pg-submit` | Prepare challenge submission, validate constraints, open PR |

## Core Workflow

```
/pg-strategize  →  /pg-sweep  →  /pg-analyze  →  (loop back or /pg-submit)
```

Recipes automate this loop: `sweep-cycle.yaml` (convergence loop),
`single-experiment.yaml` (one-shot run), `full-solve.yaml` (end-to-end with gates).

## Human-AI Split

- **Human owns:** strategic pivots (architecture changes, tokenizer decisions, when to
  submit, whether to continue after plateau).
- **Bundle owns:** all mechanical execution — launching sweeps, parsing logs, generating
  configs, modifying code, packaging submissions.

When the strategist hits a hard decision (major architecture pivot, tokenizer change,
unfamiliar tradeoff), it escalates to the human rather than guessing.

## Environment

- **Machine:** DGX Spark at 192.168.0.200 — direct local execution, no SSH required.
- **Python:** 3.14 with `.venv` pre-activated; PyTorch 2.10, all deps installed.
- **Key scripts:** `train_gpt.py` (all knobs via env vars), `scripts/run_recurrent_qat_sweep.py` (grid sweep runner).
- **LiteLLM proxy:** 120B (opus alias on .200), Qwen3 Coder (sonnet on .201), 20B (haiku on .202).
