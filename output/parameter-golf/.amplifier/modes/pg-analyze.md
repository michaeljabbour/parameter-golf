---
mode:
  name: pg-analyze
  description: Deep-dive results analysis — parse logs, compare configs, identify patterns
  default_action: block
  paired_agent: result-analyst
  tool_policies:
    delegate:
      action: safe
      rationale: Delegates to result-analyst for structured log analysis
    read_file:
      action: safe
      rationale: Read training logs, leaderboard TSVs, and sweep metadata
    grep:
      action: safe
      rationale: Search for specific metric patterns within log files
    glob:
      action: safe
      rationale: Find log and sweep files across multiple sweep directories
    bash:
      action: safe
      rationale: Run the summarize command to build leaderboard TSVs
    load_skill:
      action: safe
      rationale: Load domain knowledge for analysis methodology
    write_file:
      action: block
      rationale: Analysis is strictly read-only — no modifications during analysis phase
    edit_file:
      action: block
      rationale: Analysis is strictly read-only — no modifications during analysis phase
  transitions:
    - pg-strategize
    - pg-sweep
    - pg-optimize
    - pg-submit
---

# Analysis Mode `/pg-analyze`

Use this mode when a sweep has completed and you need to **parse results, rank configs,
and identify patterns** before deciding the next move. File writes are blocked to enforce
a clean read-only analysis boundary.

## What it enables

- Delegating to `result-analyst` to run `run_recurrent_qat_sweep.py summarize` and build
  ranked leaderboard TSVs
- Cross-sweep comparison: identifying which parameters consistently drive val_bpb improvements
- Pattern reports: sensitivity tables, interaction effects, risk flags (configs near 16MB limit)
- Reading any log file, leaderboard, or sweep metadata directly

## What it prevents

- Modifying `train_gpt.py` or sweep configs while analyzing — that's for `/pg-sweep` or
  a dedicated code-optimizer session

## Typical flow

```
/pg-sweep                ← sweep completed here
/pg-analyze              ← you are here
  → delegate to result-analyst
  → build leaderboard
  → identify patterns
  → produce analysis report
/pg-strategize           ← plan next experiments based on findings
```

## Suggested entry prompt

> "Analyze the results from sweep_004 — build the leaderboard and identify which parameters drove the best configs."

or for cross-sweep analysis:

> "Compare all sweeps completed so far and identify the consistent winners across the full experiment history."
