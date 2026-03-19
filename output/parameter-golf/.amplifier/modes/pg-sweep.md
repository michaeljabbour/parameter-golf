---
mode:
  name: pg-sweep
  description: Launch and monitor training sweeps on the DGX
  default_action: block
  paired_agent: sweep-runner
  tool_policies:
    bash:
      action: safe
      rationale: Primary tool — torchrun invocation, log tailing, process monitoring
    delegate:
      action: safe
      rationale: Delegates to sweep-runner and foundation:bug-hunter for failures
    read_file:
      action: safe
      rationale: Read sweep configs and training logs
    glob:
      action: safe
      rationale: Find log files and sweep directories
    grep:
      action: safe
      rationale: Search log output for metrics and failure indicators
    load_skill:
      action: safe
      rationale: Load domain knowledge (e.g., debugging skills for training failures)
    edit_file:
      action: warn
      rationale: Emergency config fixes only — confirm before modifying any file
    write_file:
      action: warn
      rationale: Emergency config writes only — confirm before creating any file
  transitions:
    - pg-analyze
    - pg-strategize
    - pg-submit
---

# Sweep Mode `/pg-sweep`

Use this mode when a strategy plan is ready and it's time to **launch and monitor training
runs** on the DGX Spark. Bash execution is fully enabled for torchrun invocations and log
monitoring.

## What it enables

- Delegating to `sweep-runner` to translate strategy plans into `run_recurrent_qat_sweep.py`
  invocations and launch them on 8×H100s
- Real-time monitoring via log tailing (`tail -f logs/<run_id>.log`)
- Diagnosing and handling training failures (OOM, NaN loss, wallclock overrun)
- Escalating undiagnosable failures to `foundation:bug-hunter`

## What it warns on

- `edit_file` and `write_file` — file modifications during an active sweep should be
  intentional. You'll be asked to confirm before any file is touched. Emergency config
  fixes (e.g., adjusting `MAX_WALLCLOCK_SECONDS` mid-sweep) are the expected use case.

## Typical flow

```
/pg-strategize           ← plan produced here
/pg-sweep                ← you are here
  → delegate to sweep-runner
  → launch sweep
  → monitor progress
  → sweep complete
/pg-analyze              ← parse results here
```

## Suggested entry prompt

> "Run sweep_004 with the configs from the strategy plan: NUM_UNIQUE_BLOCKS={3,4}, BLOCK_SHARE_STRATEGY=cycle, QAT_START_FRACTION={0.65,0.70,0.75}."

or to monitor an in-progress run:

> "Check the status of sweep_004 and report current progress."
