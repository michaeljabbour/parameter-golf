# Implementation Plan: parameter-golf bundle

**Spec:** `output/bundle-spec.md`
**Output root:** `/home/mjabbour/dev/parameter-golf/output/parameter-golf/.amplifier/`
**Total files:** 18 (4 context + 5 agents + 4 modes + 3 recipes + 1 behavior + 1 bundle.md)

---

## Dependency Graph

```
context/*  (no deps)
  └─► agents/*  (@mention context files)
        ├─► modes/*  (reference agents)
        ├─► recipes/single-experiment.yaml  (uses sweep-runner, result-analyst)
        ├─► recipes/sweep-cycle.yaml  (uses strategist, sweep-runner, result-analyst)
        │     └─► recipes/full-solve.yaml  (sub-recipe ref to sweep-cycle + all agents)
        └─► behaviors/parameter-golf.yaml  (registers agents, includes context/instructions.md)
              └─► bundle.md  (includes behavior)
```

---

## Phase 1: Context Files (4 files, all independent — parallelizable)

### File 1: `context/instructions.md`

**Path:** `.amplifier/context/instructions.md`
**Constraint:** ≤100 lines. Root context — loaded always via behavior `context.include`. No agent re-@mentions this.

**Content to generate:**
- Bundle identity: orchestrates OpenAI Parameter Golf challenge, targets lowest val_bpb within 16MB/10min constraint on 8×H100
- Agent routing table (which agent handles which request type):
  - Strategy/planning → `strategist` (reasoning/120B)
  - Launching sweeps → `sweep-runner` (fast/20B)
  - Parsing results → `result-analyst` (coding/Qwen3)
  - Code changes → `code-optimizer` (coding/Qwen3)
  - Submission packaging → `submission-packager` (writing)
- Mode quick-reference (one line each):
  - `/pg-strategize` — plan next experiments
  - `/pg-sweep` — launch and monitor training
  - `/pg-analyze` — deep-dive results analysis
  - `/pg-submit` — prepare submission artifacts
- Workflow overview: strategize → sweep → analyze → (loop or submit)
- Human-AI split: human owns strategic pivots (architecture changes, tokenizer decisions), bundle owns all mechanical execution
- Model routing note: strategist→reasoning(120B on .200), sweep-runner→fast(20B on .202), result-analyst/code-optimizer→coding(Qwen3 on .201), submission-packager→writing
- Environment note: direct execution on DGX Spark (192.168.0.200), no SSH, `.venv` pre-configured

**Depends on:** Nothing.

---

### File 2: `context/challenge-rules.md`

**Path:** `.amplifier/context/challenge-rules.md`
**@mentioned by:** `strategist`, `code-optimizer`, `submission-packager`

**Content to generate:**
- Hard constraints:
  - Artifact size ≤ 16,000,000 bytes (code UTF-8 bytes + compressed model bytes)
  - 10-minute training wallclock on 8×H100 SXM
  - 10-minute evaluation cap
- Self-containment: no external downloads or network calls during evaluation
- Reproducibility requirement: non-reproducible results → disqualified
- Improvement bar: new SOTA must beat existing record by ≥ 0.005 nats at p < 0.01
- Code location: all counted code in `train_gpt.py` (≤1500 lines upstream convention)
- Tokenizer scrutiny: changes heavily scrutinized, BPB correctness must be proven
- Submission format:
  - Folder: `records/track_10min_16mb/<submission_name>/`
  - Required files: `README.md`, `submission.json`, `train.log`, self-contained `train_gpt.py`
- Deadline: April 30, 2026

**Depends on:** Nothing.

---

### File 3: `context/architecture-reference.md`

**Path:** `.amplifier/context/architecture-reference.md`
**@mentioned by:** `strategist`, `sweep-runner`, `result-analyst`, `code-optimizer`

**Content to generate:**
- Baseline architecture: 9 layers, 512 dim, 8 Q-heads / 4 KV-heads (GQA), ~17M params, 1024 vocab SentencePiece BPE, tied embeddings
- Baseline performance: val_bpb = 1.2244 (SOTA), val_bpb = 1.2074 (4-hour unlimited)
- Artifact budget: post-int8+zlib ≈ 15.86MB, ~137KB headroom under 16MB cap
- Key insight: architecture is the lever (4-hour run only 0.017 better than 10-min — diminishing returns from more training time)
- Complete env var knob reference from `train_gpt.py` `Hyperparameters` class:
  - **Model shape:** `NUM_LAYERS`, `NUM_UNIQUE_BLOCKS`, `BLOCK_SHARE_STRATEGY`, `LOGICAL_LAYER_CONTROLS`, `MODEL_DIM`, `NUM_HEADS`, `NUM_KV_HEADS`, `MLP_MULT`, `VOCAB_SIZE`, `TIE_EMBEDDINGS`, `ROPE_BASE`, `LOGIT_SOFTCAP`
  - **Training:** `ITERATIONS`, `WARMDOWN_ITERS`, `WARMUP_STEPS`, `TRAIN_BATCH_TOKENS`, `TRAIN_SEQ_LEN`, `MAX_WALLCLOCK_SECONDS`, `VAL_LOSS_EVERY`, `SEED`
  - **Optimizer:** `EMBED_LR`, `HEAD_LR`, `TIED_EMBED_LR`, `MATRIX_LR`, `SCALAR_LR`, `MUON_MOMENTUM`, `MUON_BACKEND_STEPS`, `BETA1`, `BETA2`, `GRAD_CLIP_NORM`
  - **QAT:** `QAT_ENABLE`, `QAT_START_STEP`, `QAT_START_FRACTION`
  - **System:** `PREFER_CUDA`, `TORCH_COMPILE`

**Depends on:** Nothing.

---

### File 4: `context/experiment-tracking.md`

**Path:** `.amplifier/context/experiment-tracking.md`
**@mentioned by:** `strategist`, `sweep-runner`, `result-analyst`

**Content to generate:**
- Log file structure: `logs/<run_id>.log` with timestamped entries
- Key log line patterns (include regex):
  - `final_int8_zlib_roundtrip_exact` — post-quantization validation metric
  - `val_loss/val_bpb` per step — training progress
  - `Total submission size int8+zlib` — artifact size check
  - `model_params` — parameter count
  - `stopping_early: wallclock_cap` — hit time limit
- Sweep runner invocation:
  - `scripts/run_recurrent_qat_sweep.py run` — CLI args for grid dimensions
  - `scripts/run_recurrent_qat_sweep.py summarize` — parses logs, builds leaderboard TSV
- Sweep output structure: `sweeps/<sweep_name>/` with config metadata
- Metrics that matter (ranked by importance):
  1. `final_val_bpb` — post-quant, the competition metric
  2. `best_prequant_val_bpb` — training signal
  3. `total_submission_size_bytes` — must stay under 16MB
  4. `stop_step`/`wallclock_ms` — whether training is time-constrained
- Leaderboard format: TSV with columns from `RunSummary` dataclass
- Cross-sweep comparison methodology: how to correlate parameter choices with outcomes

**Depends on:** Nothing.

---

## Phase 2: Agents (5 files — parallelizable, all depend on Phase 1)

All agents use markdown with YAML frontmatter. Each needs: name, model_role, description (WHY/WHEN/WHAT/HOW), tools list, delegation targets, @mentions of context files, 2+ `<example>` blocks.

### File 5: `agents/strategist.md`

**Path:** `.amplifier/agents/strategist.md`

**Frontmatter fields:**
- `name: strategist`
- `model_role: reasoning`

**@mentions in body:** `@parameter-golf:context/challenge-rules.md`, `@parameter-golf:context/architecture-reference.md`, `@parameter-golf:context/experiment-tracking.md`

**Description content (from spec):**
- Role: ML research strategist — analyzes accumulated results, reasons about architecture tradeoffs, designs next experiment strategy
- WHEN: deciding what experiments to run next
- WHAT: analyzes sweep results, reasons about tradeoffs (recurrence depth vs width, vocab size, quantization timing)
- HOW: reviews leaderboards, identifies winning patterns, produces prioritized experiment plan
- Produces: prioritized experiment plan with specific env var configurations, expected impact estimates, rationale
- Delegates hard decisions to human. Delegates architecture exploration to `foundation:zen-architect`.

**Tools:** read_file, grep, glob, web_search, web_fetch, delegate

**Delegation targets:** `foundation:zen-architect` (high-level architecture analysis), human (strategic pivots)

**Examples:** 2 examples from spec (first sweep analysis, plateau diagnosis)

**Depends on:** Files 2, 3, 4 (context files it @mentions)

---

### File 6: `agents/sweep-runner.md`

**Path:** `.amplifier/agents/sweep-runner.md`

**Frontmatter fields:**
- `name: sweep-runner`
- `model_role: fast`

**@mentions in body:** `@parameter-golf:context/architecture-reference.md`, `@parameter-golf:context/experiment-tracking.md`

**Description content (from spec):**
- Role: generates sweep configs from strategy, launches torchrun grid via `scripts/run_recurrent_qat_sweep.py run`, monitors progress
- WHEN: time to launch training experiments
- WHAT: translates strategy plans into sweep script invocations
- HOW: executes directly on DGX (no SSH), monitors by tailing `logs/`, detects failures early (OOM, NaN, wallclock overrun)
- Produces: running sweep with real-time progress, log files in `logs/`, sweep metadata in `sweeps/`
- Escalates failures to `foundation:bug-hunter`

**Tools:** bash (primary), read_file, delegate

**Delegation targets:** `foundation:bug-hunter` (training failures), `foundation:explorer` (codebase navigation)

**Examples:** 2 examples from spec (launch 6-config sweep, NaN diagnosis)

**Depends on:** Files 3, 4 (context files it @mentions)

---

### File 7: `agents/result-analyst.md`

**Path:** `.amplifier/agents/result-analyst.md`

**Frontmatter fields:**
- `name: result-analyst`
- `model_role: coding`

**@mentions in body:** `@parameter-golf:context/experiment-tracking.md`, `@parameter-golf:context/architecture-reference.md`

**Description content (from spec):**
- Role: parses training logs, compares configurations, identifies winning patterns, builds ranked leaderboards
- WHEN: sweep completes and results need analysis
- WHAT: invokes `summarize`, reads logs, compares across sweeps
- HOW: identifies patterns — which sharing strategies win, where QAT fraction matters, depth vs width tradeoffs
- Produces: ranked leaderboard (TSV), cross-sweep comparison, pattern identification report with specific observations
- Self-contained — no delegation targets

**Tools:** bash (for `summarize`), read_file, grep, glob

**Delegation targets:** None

**Examples:** 2 examples from spec (single sweep analysis, cross-sweep pattern analysis)

**Depends on:** Files 3, 4 (context files it @mentions)

---

### File 8: `agents/code-optimizer.md`

**Path:** `.amplifier/agents/code-optimizer.md`

**Frontmatter fields:**
- `name: code-optimizer`
- `model_role: coding`

**@mentions in body:** `@parameter-golf:context/challenge-rules.md`, `@parameter-golf:context/architecture-reference.md`

**Description content (from spec):**
- Role: targeted changes to `train_gpt.py` — new architecture knobs, optimizer tweaks, quantization improvements, vocab changes
- WHEN: analysis reveals code changes needed
- WHAT: surgical modifications — never rewrites the whole file
- HOW: preserves challenge compliance (all code in `train_gpt.py`, no external downloads, ≤16MB artifact, ≤1500 lines)
- Produces: modified `train_gpt.py` with new/improved knobs, git commit with rationale

**Tools:** read_file, edit_file, write_file, bash, grep, LSP, delegate

**Delegation targets:** `foundation:modular-builder` (clear implementation spec), `python-dev:python-dev` (code quality), `foundation:git-ops` (commits)

**Examples:** 2 examples from spec (graduated QAT schedule, MLP dimension knob)

**Depends on:** Files 2, 3 (context files it @mentions)

---

### File 9: `agents/submission-packager.md`

**Path:** `.amplifier/agents/submission-packager.md`

**Frontmatter fields:**
- `name: submission-packager`
- `model_role: writing`

**@mentions in body:** `@parameter-golf:context/challenge-rules.md`

**Description content (from spec):**
- Role: prepares challenge-compliant submission artifacts, validates constraints, optionally exports to HuggingFace format
- WHEN: winning configuration identified, time to submit
- WHAT: creates submission folder under `records/track_10min_16mb/` with README.md, submission.json, train.log, train_gpt.py
- HOW: validates artifact size < 16,000,000 bytes, training within 10-min wallclock, reproducibility
- Produces: complete submission folder ready for PR, optionally HF-format model export
- Secondary: HuggingFace export for vLLM serving

**Tools:** read_file, write_file, edit_file, bash, grep, glob, delegate

**Delegation targets:** `foundation:git-ops` (PR creation), `foundation:modular-builder` (HF export implementation)

**Examples:** 2 examples from spec (package submission, HF export)

**Depends on:** File 2 (context file it @mentions)

---

## Phase 3: Modes (4 files — parallelizable, all depend on Phase 2)

All modes are markdown with YAML frontmatter defining tool permissions and transitions.

### File 10: `modes/pg-strategize.md`

**Path:** `.amplifier/modes/pg-strategize.md`

**Frontmatter fields:**
- `name: pg-strategize`
- `description: Plan next experiments, review accumulated results, make strategic decisions`
- `default_action: block`
- `paired_agent: strategist`

**Tool permissions:**
- `safe`: delegate, read_file, grep, glob, web_search, web_fetch, load_skill
- `blocked`: bash, write_file, edit_file

**Allowed transitions:** pg-sweep, pg-analyze, pg-submit

**Body:** Brief description of when/why to use this mode, what it enables.

**Depends on:** File 5 (strategist agent)

---

### File 11: `modes/pg-sweep.md`

**Path:** `.amplifier/modes/pg-sweep.md`

**Frontmatter fields:**
- `name: pg-sweep`
- `description: Launch and monitor training sweeps on the DGX`
- `default_action: block`
- `paired_agent: sweep-runner`

**Tool permissions:**
- `safe`: bash, delegate, read_file, glob, grep, load_skill
- `warn`: edit_file, write_file (emergency config fixes only)

**Allowed transitions:** pg-analyze, pg-strategize, pg-submit

**Body:** Brief description of when/why to use this mode.

**Depends on:** File 6 (sweep-runner agent)

---

### File 12: `modes/pg-analyze.md`

**Path:** `.amplifier/modes/pg-analyze.md`

**Frontmatter fields:**
- `name: pg-analyze`
- `description: Deep-dive results analysis — parse logs, compare configs, identify patterns`
- `default_action: block`
- `paired_agent: result-analyst`

**Tool permissions:**
- `safe`: delegate, read_file, grep, glob, bash, load_skill
- `blocked`: write_file, edit_file

**Allowed transitions:** pg-strategize, pg-sweep, pg-submit

**Body:** Brief description of when/why to use this mode.

**Depends on:** File 7 (result-analyst agent)

---

### File 13: `modes/pg-submit.md`

**Path:** `.amplifier/modes/pg-submit.md`

**Frontmatter fields:**
- `name: pg-submit`
- `description: Prepare and validate submission artifacts`
- `default_action: block`
- `paired_agent: submission-packager`
- `allow_clear: true` (terminal mode)

**Tool permissions:**
- `safe`: read_file, write_file, edit_file, bash, delegate, grep, glob, load_skill

**Allowed transitions:** pg-strategize, pg-analyze

**Body:** Brief description of when/why to use this mode.

**Depends on:** File 9 (submission-packager agent)

---

## Phase 4: Recipes (3 files — partial ordering required)

### File 14: `recipes/single-experiment.yaml`

**Path:** `.amplifier/recipes/single-experiment.yaml`
**Pattern:** Flat sequential (3 steps)

**Context variables:**
- `env_vars` (required) — space-separated env var overrides
- `run_id` (auto-generated) — unique run identifier

**Steps:**
1. **Execute** → agent: `sweep-runner` — launch single torchrun with specified env vars, monitor to completion
2. **Analyze** → agent: `result-analyst` — parse training log, extract final metrics (val_bpb, artifact size, stop step)
3. **Report** → agent: `result-analyst` — structured report: final metrics, comparison to current best, recommendation

**No approval gates.**

**Depends on:** Files 6, 7 (agents referenced)

---

### File 15: `recipes/sweep-cycle.yaml`

**Path:** `.amplifier/recipes/sweep-cycle.yaml`
**Pattern:** Convergence while-loop (adapted from attractor pattern)

**Context variables:**
- `improvement_threshold`: `0.005` — minimum val_bpb improvement to continue
- `max_iterations`: `10` — maximum sweep cycles
- `current_best_bpb`: `1.2244` — tracks best across iterations
- `converged`: `false` — set true when improvement < threshold

**Steps (per iteration):**
1. **Strategize** → agent: `strategist` — analyze accumulated results, design next experiment configs
2. **Configure** → agent: `sweep-runner` — translate strategy into sweep CLI args
3. **Execute** → agent: `sweep-runner` — launch `run_recurrent_qat_sweep.py run`, monitor to completion
4. **Analyze** → agent: `result-analyst` — parse logs via `summarize`, build leaderboard, identify patterns
5. **Evaluate** → agent: `strategist` — compare new best vs `current_best_bpb`, set `converged=true` if improvement < threshold

**Break condition:** `converged == true` OR `current_iteration >= max_iterations` OR human interrupt

**No approval gates.**

**Depends on:** Files 5, 6, 7 (agents referenced)

---

### File 16: `recipes/full-solve.yaml`

**Path:** `.amplifier/recipes/full-solve.yaml`
**Pattern:** Staged recipe with human approval gates

**Context variables:**
- `target_bpb`: `1.2194` — target val_bpb (current SOTA − 0.005)
- `max_sweep_rounds`: `5` — max rounds of sweep-cycle invocations

**Stages:**
1. **Initial Strategy** — agent: `strategist` — analyze baseline, identify promising directions. No gate.
2. **Sweep Rounds** — sub-recipe: `sweep-cycle.yaml`, repeat up to `max_sweep_rounds`. **Gate after each round:** human approves continuation or pivots.
3. **Code Optimization** — agent: `code-optimizer` — implement changes from accumulated insights. **Gate before code changes:** human reviews proposed changes.
4. **Validation Sweep** — sub-recipe: single iteration of `sweep-cycle.yaml` to validate code changes. No gate.
5. **Submission** — agent: `submission-packager` — prepare and validate submission. **Gate before PR:** human reviews package.

**Depends on:** Files 5, 8, 9 (agents), File 15 (sweep-cycle.yaml sub-recipe)

---

## Phase 5: Bundle Composition (2 files — sequential)

### File 17: `behaviors/parameter-golf.yaml`

**Path:** `.amplifier/behaviors/parameter-golf.yaml`

**Content:** Exact YAML from spec lines 94–132. Registers all 5 agents, mounts 5 tool modules (filesystem, search, bash, lsp, web), includes `context/instructions.md` at root, configures hooks-mode with `search_paths: [modes/]`.

**Key structure:**
```yaml
behavior:
  name: parameter-golf
  description: ...

tools:
  - module: tool-filesystem
    source: git+https://github.com/microsoft/amplifier-module-tool-filesystem@main
  - module: tool-search
    source: git+https://github.com/microsoft/amplifier-module-tool-search@main
  - module: tool-bash
    source: git+https://github.com/microsoft/amplifier-module-tool-bash@main
  - module: tool-lsp
    source: git+https://github.com/microsoft/amplifier-module-tool-lsp@main
  - module: tool-web
    source: git+https://github.com/microsoft/amplifier-module-tool-web@main

agents:
  include:
    - agents/strategist.md
    - agents/sweep-runner.md
    - agents/result-analyst.md
    - agents/code-optimizer.md
    - agents/submission-packager.md

context:
  include:
    - context/instructions.md

hooks:
  - module: hooks-mode
    source: git+https://github.com/microsoft/amplifier-module-hooks-mode@main
    config:
      search_paths:
        - modes/
```

**Depends on:** All agents (Phase 2), context/instructions.md (Phase 1), all modes (Phase 3) exist.

---

### File 18: `bundle.md`

**Path:** `.amplifier/bundle.md`

**Frontmatter (≤20 lines YAML):**
```yaml
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
  - bundle: parameter-golf:behaviors/parameter-golf
---
```

**Body:** Thin router. Table of modes, brief agent roster, recipe entry points. NO @mentions in body. No redeclaration of anything in the behavior.

**Depends on:** File 17 (behavior YAML).

---

## Generation Order Summary

| Order | File | Path | Parallel Group |
|-------|------|------|---------------|
| 1 | instructions.md | context/instructions.md | A |
| 2 | challenge-rules.md | context/challenge-rules.md | A |
| 3 | architecture-reference.md | context/architecture-reference.md | A |
| 4 | experiment-tracking.md | context/experiment-tracking.md | A |
| 5 | strategist.md | agents/strategist.md | B |
| 6 | sweep-runner.md | agents/sweep-runner.md | B |
| 7 | result-analyst.md | agents/result-analyst.md | B |
| 8 | code-optimizer.md | agents/code-optimizer.md | B |
| 9 | submission-packager.md | agents/submission-packager.md | B |
| 10 | pg-strategize.md | modes/pg-strategize.md | C |
| 11 | pg-sweep.md | modes/pg-sweep.md | C |
| 12 | pg-analyze.md | modes/pg-analyze.md | C |
| 13 | pg-submit.md | modes/pg-submit.md | C |
| 14 | single-experiment.yaml | recipes/single-experiment.yaml | D |
| 15 | sweep-cycle.yaml | recipes/sweep-cycle.yaml | D |
| 16 | full-solve.yaml | recipes/full-solve.yaml | D* |
| 17 | parameter-golf.yaml | behaviors/parameter-golf.yaml | E |
| 18 | bundle.md | bundle.md | F |

**Parallel groups:** A→B→C→D→E→F. Within each group, all files can be generated concurrently. Exception: D* — `full-solve.yaml` depends on `sweep-cycle.yaml` existing (sub-recipe reference), so within group D, generate files 14+15 first, then 16.

## Validation Checklist (post-generation)

- [ ] All 18 files exist under `.amplifier/`
- [ ] `bundle.md` frontmatter ≤20 lines, no @mentions in body
- [ ] `instructions.md` ≤100 lines
- [ ] All 5 agents have: YAML frontmatter (name, model_role), WHY/WHEN/WHAT/HOW description, 2+ `<example>` blocks, tools list, @mentions only their declared context files
- [ ] No context file is @mentioned by an agent that shouldn't have it (per spec cross-reference)
- [ ] `instructions.md` is NOT @mentioned by any agent (root-only via behavior)
- [ ] All mode YAML has: tool permissions matching spec tables, allowed transitions, default_action: block
- [ ] All recipe YAML parses, agent references match declared agent names
- [ ] `full-solve.yaml` references `sweep-cycle.yaml` correctly as sub-recipe
- [ ] Behavior YAML includes all 5 agents, only `context/instructions.md`, hooks-mode with `modes/` search path
- [ ] Source URIs use `@main` (acceptable for dev per spec)
