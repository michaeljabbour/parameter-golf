# Bundle Specification: parameter-golf

## Overview

- **Tier:** Application Bundle
- **Purpose:** Orchestrate solving the OpenAI Parameter Golf challenge — achieve the lowest possible val_bpb within the 16MB compressed artifact / 10-minute training constraint on 8×H100 GPUs.
- **Path:** Create New
- **Bundle Identifier:** `parameter-golf`
- **Repository:** `/home/mjabbour/dev/parameter-golf` (fork of `openai/parameter-golf` at `michaeljabbour/parameter-golf`)

### Environment Assumptions

- Runs directly on DGX Spark (192.168.0.200) with 8×H100 GPUs — no SSH, direct local execution.
- Three local models via LiteLLM proxy: 120B (opus on .200), Qwen3 Coder (sonnet on .201), 20B (haiku on .202).
- Python 3.14, PyTorch 2.10, existing `.venv` with all dependencies installed.
- Existing tooling already in repo: `train_gpt.py` (training script with env var knobs), `scripts/run_recurrent_qat_sweep.py` (grid sweep runner with `run`/`summarize` subcommands), `data/` (dataset downloader, tokenizer builder, smoke test data).

### Human-AI Split

- **Human:** Strategic decisions — when to pivot architectures, when to try tokenizer changes, brainstorming and hard problems.
- **Bundle:** Everything mechanical — running sweeps, parsing results, generating configs, optimizing code, packaging submissions.

### Secondary Goal

Export winning model to HuggingFace format for vLLM serving through Amplifier (conversion step in submission-packager, not an architectural constraint).

---

## File Structure

```
.amplifier/
├── bundle.md
├── behaviors/
│   └── parameter-golf.yaml
├── agents/
│   ├── strategist.md
│   ├── sweep-runner.md
│   ├── result-analyst.md
│   ├── code-optimizer.md
│   └── submission-packager.md
├── context/
│   ├── instructions.md
│   ├── challenge-rules.md
│   ├── architecture-reference.md
│   └── experiment-tracking.md
├── modes/
│   ├── pg-strategize.md
│   ├── pg-sweep.md
│   ├── pg-analyze.md
│   └── pg-submit.md
└── recipes/
    ├── sweep-cycle.yaml
    ├── single-experiment.yaml
    └── full-solve.yaml
```

All bundle files live in `.amplifier/` at the repo root for workspace-level auto-discovery.

---

## Components

### bundle.md

Thin router. ≤20 lines YAML frontmatter. No `@mentions` in body. Body is a menu of modes, agents, and recipes.

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

Body: table of modes (`/pg-strategize`, `/pg-sweep`, `/pg-analyze`, `/pg-submit`), brief agent roster, recipe entry points.

---

### Behaviors

#### `behaviors/parameter-golf.yaml`

Single behavior — one concern (challenge orchestration). Registers all agents, mounts tools, includes root context.

```yaml
behavior:
  name: parameter-golf
  description: |
    Core behavior for the Parameter Golf challenge orchestration bundle.
    Registers agents, mounts tools, and includes root context.

tools:
  - module: tool-filesystem
    source: git+https://github.com/microsoft/amplifier-module-tool-filesystem@main
    # TODO: pin to version tag before release
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

**Root context budget:** 1 file (`instructions.md`, ≤100 lines). All domain-heavy context flows down to agents via `@mention`.

---

### Agents

#### 1. `agents/strategist.md`

| Field | Value |
|-------|-------|
| **Name** | `strategist` |
| **Model Role** | `reasoning` (routes to 120B on .200) |
| **Role** | ML research strategist — analyzes accumulated results, reasons about architecture tradeoffs, designs next experiment strategy |
| **Context @mentions** | `@parameter-golf:context/challenge-rules.md`, `@parameter-golf:context/architecture-reference.md`, `@parameter-golf:context/experiment-tracking.md` |
| **Delegation Targets** | `foundation:zen-architect` (high-level architecture analysis), human (strategic pivots) |

**Description (WHY/WHEN/WHAT/HOW):**

Use when deciding what experiments to run next. Analyzes accumulated sweep results, reasons about architecture tradeoffs (recurrence depth vs. width, vocab size, quantization timing), and produces a prioritized experiment strategy. Delegates hard strategic decisions (major architecture pivots, tokenizer changes) to the human. Delegates to `foundation:zen-architect` for high-level architecture analysis when exploring fundamentally new directions.

Produces: Prioritized experiment plan with specific env var configurations, expected impact estimates, and rationale for each experiment.

```
<example>
Context: First sweep complete, 12 configs tested, best val_bpb = 1.2180
user: "Analyze these results and plan the next sweep"
assistant: "I'll delegate to parameter-golf:strategist to analyze the sweep
results and design the next experiment strategy."
<commentary>
Strategist reviews the leaderboard, identifies which sharing strategies and
QAT fractions performed best, and proposes a focused follow-up sweep
targeting the most promising region of the config space.
</commentary>
</example>

<example>
Context: Three sweep cycles complete, improvement has plateaued at val_bpb = 1.2050
user: "We're stuck. What should we try?"
assistant: "I'll delegate to parameter-golf:strategist to analyze the plateau
and recommend whether we need architectural changes or can squeeze more from tuning."
<commentary>
Strategist examines the improvement trajectory, determines whether the
plateau is due to architecture limits or optimizer saturation, and either
proposes code changes or escalates to human for a strategic pivot decision.
</commentary>
</example>
```

**Tools:** read_file, grep, glob, web_search, web_fetch, delegate.

---

#### 2. `agents/sweep-runner.md`

| Field | Value |
|-------|-------|
| **Name** | `sweep-runner` |
| **Model Role** | `fast` (routes to 20B on .202) |
| **Role** | Generates sweep configs from strategy, launches torchrun grid via `scripts/run_recurrent_qat_sweep.py run`, monitors progress via log tailing |
| **Context @mentions** | `@parameter-golf:context/architecture-reference.md`, `@parameter-golf:context/experiment-tracking.md` |
| **Delegation Targets** | `foundation:bug-hunter` (training failures), `foundation:explorer` (codebase navigation) |

**Description (WHY/WHEN/WHAT/HOW):**

Use when it's time to launch training experiments. Takes a strategy plan from the strategist (specific env var configurations) and translates it into `run_recurrent_qat_sweep.py run` invocations. Executes directly on the DGX — no SSH needed. Monitors training progress by tailing logs in `logs/`. Detects failures early (OOM, NaN loss, wallclock overrun) and escalates to `foundation:bug-hunter` for diagnosis.

Produces: Running sweep with real-time progress. Log files in `logs/` and sweep metadata in `sweeps/`.

```
<example>
Context: Strategist produced a plan with 6 configurations varying NUM_UNIQUE_BLOCKS and QAT_START_FRACTION
user: "Run this sweep"
assistant: "I'll delegate to parameter-golf:sweep-runner to launch the
6-config sweep on the DGX."
<commentary>
Sweep-runner translates the strategy into CLI arguments for the sweep script,
launches torchrun with nproc_per_node=8, and monitors for early failures.
</commentary>
</example>

<example>
Context: Training run is producing NaN losses after step 500
user: "Something's wrong with the current run"
assistant: "I'll delegate to parameter-golf:sweep-runner to check the logs
and diagnose the failure."
<commentary>
Sweep-runner tails the active log, identifies the NaN, and delegates
to foundation:bug-hunter if the root cause isn't immediately obvious
from the hyperparameter configuration.
</commentary>
</example>
```

**Tools:** bash (primary — torchrun invocation, log tailing), read_file, delegate.

---

#### 3. `agents/result-analyst.md`

| Field | Value |
|-------|-------|
| **Name** | `result-analyst` |
| **Model Role** | `coding` (routes to Qwen3 Coder on .201) |
| **Role** | Parses training logs, compares configurations, identifies winning patterns, builds ranked leaderboards |
| **Context @mentions** | `@parameter-golf:context/experiment-tracking.md`, `@parameter-golf:context/architecture-reference.md` |
| **Delegation Targets** | None (self-contained analysis) |

**Description (WHY/WHEN/WHAT/HOW):**

Use when a sweep completes and results need to be analyzed. Invokes `scripts/run_recurrent_qat_sweep.py summarize` to parse all training logs and build a leaderboard TSV. Reads individual log files directly for deeper analysis. Compares configurations across sweeps to identify patterns: which block sharing strategies win, where QAT start fraction matters, how recurrence depth trades off with width. Reports findings as structured analysis with ranked configurations and actionable insights.

Produces: Ranked leaderboard (TSV), cross-sweep comparison analysis, pattern identification report with specific observations (e.g., "cycle sharing at 3 unique blocks consistently beats grouped at same depth by ~0.003 val_bpb").

```
<example>
Context: 12-config sweep just finished, all logs in logs/
user: "Analyze the sweep results"
assistant: "I'll delegate to parameter-golf:result-analyst to parse the
logs and build the leaderboard."
<commentary>
Result-analyst runs the summarize command, reads the TSV output, ranks
configs by final val_bpb, and identifies which parameter combinations
drove the best results.
</commentary>
</example>

<example>
Context: Three sweeps complete, need cross-sweep pattern analysis
user: "What patterns are emerging across all our experiments?"
assistant: "I'll delegate to parameter-golf:result-analyst to do a
cross-sweep comparison and identify consistent winners."
<commentary>
Result-analyst reads logs from all sweep directories, correlates
performance with specific parameter choices, and produces a pattern
report showing which knobs have the most impact.
</commentary>
</example>
```

**Tools:** bash (for `summarize` command), read_file, grep, glob.

---

#### 4. `agents/code-optimizer.md`

| Field | Value |
|-------|-------|
| **Name** | `code-optimizer` |
| **Model Role** | `coding` (routes to Qwen3 Coder on .201) |
| **Role** | Makes targeted changes to `train_gpt.py` based on analysis — new architecture knobs, optimizer tweaks, quantization improvements, vocab changes |
| **Context @mentions** | `@parameter-golf:context/challenge-rules.md`, `@parameter-golf:context/architecture-reference.md` |
| **Delegation Targets** | `foundation:modular-builder` (when implementation spec is clear), `python-dev:python-dev` (code quality), `foundation:git-ops` (commits) |

**Description (WHY/WHEN/WHAT/HOW):**

Use when analysis reveals that new architecture knobs, optimizer tweaks, or quantization improvements are needed in `train_gpt.py`. Makes targeted, surgical changes — never rewrites the whole file. Must preserve challenge compliance: all code in `train_gpt.py`, no external downloads, artifact size ≤ 16MB, ≤1500 lines per upstream convention. Delegates to `python-dev:python-dev` for code quality review and `foundation:git-ops` for committing changes.

Produces: Modified `train_gpt.py` with new or improved knobs, ready for the next sweep cycle. Git commit with clear description of what changed and why.

```
<example>
Context: Analysis shows QAT needs a graduated schedule instead of hard cutover
user: "Implement graduated QAT scheduling"
assistant: "I'll delegate to parameter-golf:code-optimizer to add a
graduated QAT schedule to train_gpt.py."
<commentary>
Code-optimizer reads the current QAT implementation, designs a graduated
schedule controlled by a new env var, implements it surgically, validates
the change doesn't break the training loop, and commits.
</commentary>
</example>

<example>
Context: Strategist identified that wider models with fewer layers might win
user: "Add an env var for MLP intermediate dimension independent of MLP_MULT"
assistant: "I'll delegate to parameter-golf:code-optimizer to add the
new knob to the Hyperparameters class and wire it through the model."
<commentary>
Code-optimizer adds the new parameter, wires it into the MLP constructor,
verifies it falls back to the existing MLP_MULT behavior when unset,
and delegates to python-dev for a quality check.
</commentary>
</example>
```

**Tools:** read_file, edit_file, write_file, bash (for testing changes), grep, LSP, delegate.

---

#### 5. `agents/submission-packager.md`

| Field | Value |
|-------|-------|
| **Name** | `submission-packager` |
| **Model Role** | `writing` (routes to appropriate model for documentation) |
| **Role** | Prepares challenge-compliant submission artifacts, validates constraints, optionally exports to HuggingFace format |
| **Context @mentions** | `@parameter-golf:context/challenge-rules.md` |
| **Delegation Targets** | `foundation:git-ops` (PR creation), `foundation:modular-builder` (HF export implementation) |

**Description (WHY/WHEN/WHAT/HOW):**

Use when a winning configuration is identified and it's time to prepare a challenge submission. Creates the submission folder under `records/track_10min_16mb/` with all required artifacts: `README.md` (detailed explanation), `submission.json` (leaderboard metadata), `train.log` (exact training log), and self-contained `train_gpt.py`. Validates: artifact size < 16,000,000 bytes (code UTF-8 bytes + compressed model bytes), training completes within 10-minute wallclock, the run is reproducible. Secondary goal: exports the winning model to HuggingFace format for vLLM serving.

Produces: Complete submission folder ready for PR, validated against all challenge constraints. Optionally, HuggingFace-format model export.

```
<example>
Context: Best config achieves val_bpb = 1.2150, need to submit
user: "Package this for submission"
assistant: "I'll delegate to parameter-golf:submission-packager to
create the submission folder and validate all constraints."
<commentary>
Submission-packager creates the records folder, copies the winning
train_gpt.py, generates README.md and submission.json, verifies
artifact size and reproducibility, then delegates to git-ops for PR.
</commentary>
</example>

<example>
Context: Submission packaged, also want HF export for vLLM
user: "Also export the model for HuggingFace"
assistant: "I'll delegate to parameter-golf:submission-packager to
handle the HuggingFace conversion."
<commentary>
Submission-packager delegates to foundation:modular-builder for the
actual conversion implementation, since the HF format spec is well-defined.
</commentary>
</example>
```

**Tools:** read_file, write_file, edit_file, bash (for size validation, reproducibility checks), grep, glob, delegate.

---

### Context Files

#### 1. `context/instructions.md` (root — loaded always via behavior)

**Max 100 lines.** Contains:
- Bundle identity: what this bundle does, who it's for
- Agent routing table: which agent handles which type of request
- Mode quick-reference: shortcut → purpose (one line each)
- Workflow overview: strategize → sweep → analyze → (loop or submit)
- Human-AI split: human owns strategic pivots, bundle owns mechanical execution
- Model routing note: strategist → reasoning (120B), sweep-runner → fast (20B), result-analyst/code-optimizer → coding (Qwen3), submission-packager → writing

**@mentioned by:** No agents (loaded at root via behavior `context.include`). Agents do NOT re-@mention this file.

---

#### 2. `context/challenge-rules.md` (agent-level — loaded on demand)

Contains:
- Hard constraints: artifact size ≤ 16,000,000 bytes (code UTF-8 + compressed model), 10-minute training on 8×H100 SXM, 10-minute evaluation cap
- Self-containment: no external downloads or network calls during evaluation
- Reproducibility requirement: non-reproducible results disqualified
- Improvement bar: new SOTA must beat existing record by ≥ 0.005 nats at p < 0.01
- Code location: all counted code must live in `train_gpt.py` (≤1500 lines upstream convention)
- Tokenizer scrutiny: tokenizer changes heavily scrutinized, BPB correctness must be proven
- Submission format: `README.md`, `submission.json`, `train.log`, self-contained `train_gpt.py` in `records/track_10min_16mb/` folder
- Deadline: April 30, 2026

**@mentioned by:** `strategist`, `code-optimizer`, `submission-packager`

---

#### 3. `context/architecture-reference.md` (agent-level — loaded on demand)

Contains:
- Baseline architecture: 9 layers, 512 dim, 8 Q-heads / 4 KV-heads (GQA), ~17M params, 1024 vocab SentencePiece BPE, tied embeddings
- Baseline performance: val_bpb = 1.2244 (SOTA), val_bpb = 1.2074 (4-hour unlimited)
- Artifact budget: post-int8+zlib = ~15.86MB, ~137KB headroom under 16MB cap
- All env var knobs in `train_gpt.py` `Hyperparameters` class:
  - Model shape: `NUM_LAYERS`, `NUM_UNIQUE_BLOCKS`, `BLOCK_SHARE_STRATEGY`, `LOGICAL_LAYER_CONTROLS`, `MODEL_DIM`, `NUM_HEADS`, `NUM_KV_HEADS`, `MLP_MULT`, `VOCAB_SIZE`, `TIE_EMBEDDINGS`, `ROPE_BASE`, `LOGIT_SOFTCAP`
  - Training: `ITERATIONS`, `WARMDOWN_ITERS`, `WARMUP_STEPS`, `TRAIN_BATCH_TOKENS`, `TRAIN_SEQ_LEN`, `MAX_WALLCLOCK_SECONDS`, `VAL_LOSS_EVERY`, `SEED`
  - Optimizer: `EMBED_LR`, `HEAD_LR`, `TIED_EMBED_LR`, `MATRIX_LR`, `SCALAR_LR`, `MUON_MOMENTUM`, `MUON_BACKEND_STEPS`, `BETA1`, `BETA2`, `GRAD_CLIP_NORM`
  - QAT: `QAT_ENABLE`, `QAT_START_STEP`, `QAT_START_FRACTION`
  - System: `PREFER_CUDA`, `TORCH_COMPILE`
- Key insight: architecture is the lever (4-hour run only 0.017 better than 10-min — diminishing returns from more training time)

**@mentioned by:** `strategist`, `sweep-runner`, `result-analyst`, `code-optimizer`

---

#### 4. `context/experiment-tracking.md` (agent-level — loaded on demand)

Contains:
- Log file structure: `logs/<run_id>.log` with timestamped entries
- Key log line patterns (regex): `final_int8_zlib_roundtrip_exact`, `val_loss/val_bpb` per step, `Total submission size int8+zlib`, `model_params`, `stopping_early: wallclock_cap`
- How to invoke the sweep runner: `scripts/run_recurrent_qat_sweep.py run` (CLI args for grid dimensions), `scripts/run_recurrent_qat_sweep.py summarize` (parses logs, builds leaderboard TSV)
- Sweep output structure: `sweeps/<sweep_name>/` with config metadata
- Metrics that matter: `final_val_bpb` (post-quant, the competition metric), `best_prequant_val_bpb` (training signal), `total_submission_size_bytes` (must stay under 16MB), `stop_step`/`wallclock_ms` (whether training is time-constrained)
- Leaderboard format: TSV with columns from `RunSummary` dataclass
- Cross-sweep comparison methodology: how to correlate parameter choices with outcomes

**@mentioned by:** `strategist`, `sweep-runner`, `result-analyst`

---

### Modes

#### 1. `/pg-strategize`

| Field | Value |
|-------|-------|
| **Name** | `pg-strategize` |
| **Description** | Plan next experiments, review accumulated results, make strategic decisions |
| **Paired Agent** | `strategist` (delegate strategy work) |
| **Default Action** | `block` |

**Tool Permissions:**

| Tool | Permission | Rationale |
|------|-----------|-----------|
| `delegate` | safe | Delegates to strategist, zen-architect |
| `read_file` | safe | Read logs, configs, results |
| `grep` | safe | Search logs and code |
| `glob` | safe | Find log files |
| `web_search` | safe | Research ML techniques |
| `web_fetch` | safe | Read papers/references |
| `load_skill` | safe | Load domain knowledge |
| `bash` | **blocked** | No execution during strategy phase |
| `write_file` | **blocked** | No file modification during strategy |
| `edit_file` | **blocked** | No file modification during strategy |

**Allowed Transitions:** `pg-sweep`, `pg-analyze`, `pg-submit`

---

#### 2. `/pg-sweep`

| Field | Value |
|-------|-------|
| **Name** | `pg-sweep` |
| **Description** | Launch and monitor training sweeps on the DGX |
| **Paired Agent** | `sweep-runner` (delegate sweep execution) |
| **Default Action** | `block` |

**Tool Permissions:**

| Tool | Permission | Rationale |
|------|-----------|-----------|
| `bash` | safe | torchrun invocation, log tailing, process monitoring |
| `delegate` | safe | Delegates to sweep-runner, bug-hunter |
| `read_file` | safe | Read configs, logs |
| `glob` | safe | Find log files |
| `grep` | safe | Search log output |
| `edit_file` | **warn** | Emergency config fixes only |
| `write_file` | **warn** | Emergency config writes only |
| `load_skill` | safe | Load domain knowledge |

**Allowed Transitions:** `pg-analyze`, `pg-strategize`, `pg-submit`

---

#### 3. `/pg-analyze`

| Field | Value |
|-------|-------|
| **Name** | `pg-analyze` |
| **Description** | Deep-dive results analysis — parse logs, compare configs, identify patterns |
| **Paired Agent** | `result-analyst` (delegate analysis work) |
| **Default Action** | `block` |

**Tool Permissions:**

| Tool | Permission | Rationale |
|------|-----------|-----------|
| `delegate` | safe | Delegates to result-analyst |
| `read_file` | safe | Read logs, leaderboards |
| `grep` | safe | Search patterns in logs |
| `glob` | safe | Find log and sweep files |
| `bash` | safe | Run `summarize` command |
| `load_skill` | safe | Load domain knowledge |
| `write_file` | **blocked** | Analysis is read-only |
| `edit_file` | **blocked** | Analysis is read-only |

**Allowed Transitions:** `pg-strategize`, `pg-sweep`, `pg-submit`

---

#### 4. `/pg-submit`

| Field | Value |
|-------|-------|
| **Name** | `pg-submit` |
| **Description** | Prepare and validate submission artifacts |
| **Paired Agent** | `submission-packager` (delegate packaging work) |
| **Default Action** | `block` |

**Tool Permissions:**

| Tool | Permission | Rationale |
|------|-----------|-----------|
| `read_file` | safe | Read all source files |
| `write_file` | safe | Create submission artifacts |
| `edit_file` | safe | Finalize files |
| `bash` | safe | Size validation, reproducibility checks, git |
| `delegate` | safe | Delegates to submission-packager, git-ops |
| `grep` | safe | Search and verify |
| `glob` | safe | Find files |
| `load_skill` | safe | Load domain knowledge |

**Allowed Transitions:** `pg-strategize`, `pg-analyze`
**Allow Clear:** `true` (terminal mode — submission complete)

---

### Recipes

#### 1. `recipes/sweep-cycle.yaml`

**Pattern:** Convergence while-loop (adapted from attractor pattern in `@recipes:examples/attractor/attractor.yaml`).

**Purpose:** Iterative optimize-evaluate loop: strategize → configure → run sweep → analyze → decide whether to continue.

**Context Variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `improvement_threshold` | `0.005` | Minimum val_bpb improvement to continue |
| `max_iterations` | `10` | Maximum sweep cycles before stopping |
| `current_best_bpb` | `1.2244` | Tracks best val_bpb across iterations |
| `converged` | `false` | Set to true when improvement < threshold |

**Steps (per iteration):**

| Step | Agent | Description |
|------|-------|-------------|
| 1. Strategize | `strategist` | Analyze accumulated results, design next experiment configs |
| 2. Configure | `sweep-runner` | Translate strategy into sweep CLI args |
| 3. Execute | `sweep-runner` | Launch `run_recurrent_qat_sweep.py run`, monitor to completion |
| 4. Analyze | `result-analyst` | Parse logs via `summarize`, build leaderboard, identify patterns |
| 5. Evaluate | `strategist` | Compare new best vs. `current_best_bpb`. If improvement < `improvement_threshold` → set `converged=true` |

**Break Condition:** `converged == true` OR `current_iteration >= max_iterations` OR human says stop.

**No approval gates** — runs autonomously within the loop. Human can interrupt at any time.

---

#### 2. `recipes/single-experiment.yaml`

**Pattern:** Flat sequential (3 steps).

**Purpose:** Run one training configuration end-to-end, evaluate, report.

**Context Variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `env_vars` | (required) | Space-separated env var overrides for the training run |
| `run_id` | (auto-generated) | Unique identifier for this run |

**Steps:**

| Step | Agent | Description |
|------|-------|-------------|
| 1. Execute | `sweep-runner` | Launch single `torchrun` run with specified env vars, monitor to completion |
| 2. Analyze | `result-analyst` | Parse the training log, extract final metrics (val_bpb, artifact size, stop step) |
| 3. Report | `result-analyst` | Produce structured report: final metrics, comparison to current best, recommendation |

**No approval gates.** Fully autonomous.

---

#### 3. `recipes/full-solve.yaml`

**Pattern:** Staged recipe with human approval gates at major strategic pivots.

**Purpose:** End-to-end challenge solve: initial strategy → sweep cycles → code optimization → final submission.

**Context Variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `target_bpb` | `1.2194` | Target val_bpb (current SOTA − 0.005) |
| `max_sweep_rounds` | `5` | Max rounds of sweep-cycle invocations |

**Stages:**

| Stage | Steps | Approval Gate | Description |
|-------|-------|---------------|-------------|
| **1. Initial Strategy** | strategist plans first sweep based on baseline analysis | None | Analyze baseline architecture, identify most promising directions |
| **2. Sweep Rounds** | Invoke `sweep-cycle.yaml` (sub-recipe), repeat up to `max_sweep_rounds` | **Gate: after each round** — human approves continuation or pivots strategy | Iterative experimentation. Each round runs sweep-cycle to convergence |
| **3. Code Optimization** | code-optimizer implements changes based on accumulated insights | **Gate: before code changes** — human reviews proposed changes | Targeted `train_gpt.py` modifications (new knobs, architecture tweaks) |
| **4. Validation Sweep** | Single sweep-cycle with optimized code to validate improvements | None | Confirm code changes actually improve val_bpb |
| **5. Submission** | submission-packager prepares and validates submission artifacts | **Gate: before PR** — human reviews submission package | Create records folder, validate constraints, prepare PR |

**Approval gates fire ONLY for:** major strategic pivots (stage 2 between rounds), code modifications (stage 3), and final submission review (stage 5). Mechanical work within stages runs autonomously.

---

## Delegation Map

| Concern | Delegated To | When |
|---------|-------------|------|
| High-level architecture analysis | `foundation:zen-architect` | Strategist exploring fundamentally new model architectures |
| Implementation with clear spec | `foundation:modular-builder` | Code-optimizer or submission-packager with well-defined changes |
| Codebase exploration | `foundation:explorer` | Any agent needing to understand unfamiliar parts of `train_gpt.py` |
| Debugging training failures | `foundation:bug-hunter` | Sweep-runner encountering NaN, OOM, or unexpected training behavior |
| Git operations (commits, PRs) | `foundation:git-ops` | Code-optimizer after changes, submission-packager for PR creation |
| Python code quality | `python-dev:python-dev` | Code-optimizer after modifying `train_gpt.py` |
| Strategic decisions | **Human** | Strategist facing major architecture pivots, tokenizer changes, or unfamiliar tradeoffs |

**What the bundle carries (does NOT delegate):**
- ML domain knowledge (embedded in agent instructions and context files)
- Log parsing and sweep orchestration (via existing `run_recurrent_qat_sweep.py`)
- Challenge-specific constraint validation
- Experiment tracking and leaderboard management
- Cross-sweep pattern analysis

---

## Ecosystem Context

- **Greenfield:** No ML bundles exist in the Amplifier ecosystem. This is the first.
- **Structural template:** The sweep-cycle recipe adapts the attractor convergence pattern from `@recipes:examples/attractor/attractor.yaml` — same while-loop-with-break-condition structure, but with ML-specific agents and metrics instead of software scenarios.
- **Existing tooling:** Must work with the sweep runner and `train_gpt.py` knobs already built by Codex. The bundle orchestrates existing tools, not replaces them.
- **Provider routing:** Amplifier providers route to local DGX Spark models via LiteLLM. Agent `model_role` values map to: `reasoning` → 120B (opus alias), `coding` → Qwen3 Coder (sonnet alias), `fast` → 20B (haiku alias), `writing` → routed by provider config.

---

## Convergence Expectations

### Level 1: Structural (pass/fail)

| Gate | Specific Check |
|------|---------------|
| Bundle loads | `bundle.md` frontmatter parses, includes resolve |
| Agent refs resolve | All 5 agents in `behaviors/parameter-golf.yaml` → `agents.include` have corresponding `.md` files |
| No duplicate context | `instructions.md` loaded at root; `challenge-rules.md`, `architecture-reference.md`, `experiment-tracking.md` loaded only via agent `@mention` — no overlap |
| Mode refs valid | All 4 mode files in `modes/` discoverable by `hooks-mode` via `search_paths` |
| Source URIs valid | All `source:` URIs in behavior YAML are syntactically correct (note: `@main` acceptable during development, must pin before any publish) |
| Recipe refs valid | All 3 recipe files parse as valid YAML, agent references match declared agents |

### Level 2: Philosophical (target ≥ 0.85)

| Criterion | Target | Notes |
|-----------|--------|-------|
| Thin Bundle Pattern | 1.0 | bundle.md ≤20 lines frontmatter, no @mentions in body, no redeclaration |
| Context Sink Discipline | 1.0 | 1 root context file (instructions.md, ≤100 lines), agents @mention only what they need, no duplicate loading |
| Agent Description Quality | 1.0 | All 5 agents have WHY/WHEN/WHAT/HOW, 2+ examples with `<example>` tags |
| Composition Hygiene | 0.75 | `@main` in tool source URIs acceptable during development (pinned before release), no circular includes, single behavior per concern |

**Expected Level 2 score: 0.94** (only composition deduction for unpinned dev URIs).

### Level 3: Functional (target ≥ 0.80)

| Check | How to Verify |
|-------|--------------|
| Modes activate and enforce permissions | Activate each mode, verify tool permissions match spec |
| Agents respond to trigger conditions | Delegate test tasks to each agent, verify they produce expected output type |
| Sweep-cycle recipe runs end-to-end | Execute one iteration of sweep-cycle with a small config (2-3 configs, reduced iterations) |
| Result analysis produces leaderboard | Run `summarize` against existing logs, verify structured output |
| Submission packager validates constraints | Package a test submission, verify size check and artifact completeness |
| Model routing correct | Verify each agent's `model_role` routes to the intended local model |

**Functional acceptance:** Primary workflow (strategize → sweep → analyze → submit) completes end-to-end on the DGX with real training runs.
