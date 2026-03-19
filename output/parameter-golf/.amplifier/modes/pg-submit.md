---
mode:
  name: pg-submit
  description: Prepare and validate submission artifacts
  default_action: block
  paired_agent: submission-packager
  allow_clear: true
  tool_policies:
    read_file:
      action: safe
      rationale: Read training scripts, logs, and sweep metadata
    write_file:
      action: safe
      rationale: Create submission artifacts (README.md, submission.json, train_gpt.py copy)
    edit_file:
      action: safe
      rationale: Finalize submission files
    bash:
      action: safe
      rationale: Size validation, reproducibility checks, git operations
    delegate:
      action: safe
      rationale: Delegates to submission-packager, foundation:git-ops, foundation:modular-builder
    grep:
      action: safe
      rationale: Search and verify submission file contents
    glob:
      action: safe
      rationale: Find submission artifacts and verify folder completeness
    load_skill:
      action: safe
      rationale: Load domain knowledge for submission requirements
  transitions:
    - pg-strategize
    - pg-analyze
---

# Submit Mode `/pg-submit`

Use this mode when a winning configuration has been identified and verified, and it's time
to **prepare the challenge submission**. All file operations are enabled since creating
submission artifacts is the core purpose of this mode.

This is a **terminal mode** — once submission is packaged and the PR is open, you can
clear the mode (`allow_clear: true`).

## What it enables

- Delegating to `submission-packager` to create `records/track_10min_16mb/<name>/` with
  all required files: `README.md`, `submission.json`, `train.log`, `train_gpt.py`
- Validating all challenge constraints: artifact < 16MB, wallclock < 10 min, reproducible
- Opening a PR via `foundation:git-ops`
- Optionally exporting the winning model to HuggingFace format for vLLM serving

## Submission validation checklist

Before the PR is opened, confirm:
- [ ] `total_submission_size_bytes < 16,000,000` (from train.log)
- [ ] `final_int8_zlib_roundtrip_exact: true` (from train.log)
- [ ] Training wallclock ≤ 600 seconds (from log timestamps)
- [ ] Result verified in ≥ 2 independent runs with the same seed
- [ ] All 4 required files present in the submission folder
- [ ] `train_gpt.py` has no external network calls

## Transitions back

If validation reveals issues (size too large, result not reproducible), use:
- `/pg-analyze` — re-examine results to find a better candidate
- `/pg-strategize` — if the current best isn't good enough and more experiments are needed

## Suggested entry prompt

> "Package the winning config from sweep_005 run_042 for submission. val_bpb = 1.2148, seed = 42, two reproductions confirmed."
