---
mode:
  name: pg-optimize
  description: Surgical code changes to train_gpt.py — add knobs, modify architecture, unlock new search space
  default_action: block
  paired_agent: code-optimizer
  tool_policies:
    bash:
      action: safe
      rationale: Smoke-test runs after code changes (reduced-iteration torchrun invocations)
    read_file:
      action: safe
      rationale: Read train_gpt.py and logs before making any change
    grep:
      action: safe
      rationale: Locate exact insertion/modification points in train_gpt.py
    glob:
      action: safe
      rationale: Find relevant files and logs
    LSP:
      action: safe
      rationale: Semantic navigation of train_gpt.py class structure and call sites
    python_check:
      action: safe
      rationale: Code quality check (ruff + pyright) after every change to train_gpt.py
    delegate:
      action: safe
      rationale: Delegates to foundation:modular-builder (impl) and foundation:git-ops (commit)
    edit_file:
      action: warn
      rationale: Primary write tool — confirm before modifying train_gpt.py or any other file
    write_file:
      action: warn
      rationale: Confirm before creating new files during code optimization
  transitions:
    - pg-sweep
    - pg-analyze
    - pg-strategize
---

# Optimize Mode `/pg-optimize`

Use this mode when accumulated sweep results indicate that `train_gpt.py` needs **new knobs
or architectural changes** to unlock further val_bpb improvement. File writes require
confirmation to prevent accidental changes — every modification to `train_gpt.py` is
intentional and smoke-tested before committing.

## What it enables

- Delegating to `code-optimizer` to read, understand, and surgically modify `train_gpt.py`
- Adding new env var knobs to the `Hyperparameters` class
- Modifying training loop, model architecture, or QAT schedule
- Running smoke tests via `bash` (reduced iterations) to confirm changes don't crash
- Code quality checks via `python_check` (ruff + pyright) before every commit
- Committing via `foundation:git-ops` with clear, descriptive messages

## What it warns on

- `edit_file` and `write_file` — every file modification is deliberate. You'll be asked
  to confirm before any change is applied. The expected use is one surgical edit at a time.

## Hard constraints to preserve in every change

- All counted code stays in `train_gpt.py` — no external files for challenge logic
- No external network calls added
- File stays ≤ 1500 lines (upstream convention)
- Track artifact size budget: each line of code reduces model capacity

## Typical flow

```
/pg-analyze              ← patterns identified, new knob needed
/pg-optimize             ← you are here
  → delegate to code-optimizer
  → read + locate insertion point
  → edit_file (confirmed)
  → bash smoke test
  → python_check
  → delegate to foundation:git-ops for commit
/pg-sweep                ← validate the new knob with a focused sweep
```

## Suggested entry prompt

> "Analysis shows QAT hard-cutover causes instability. Add a QAT_RAMP_STEPS env var to
> train_gpt.py to graduate the quantization noise over N steps."

or:

> "Decouple MLP intermediate dimension from MLP_MULT — add an independent MLP_DIM knob."
