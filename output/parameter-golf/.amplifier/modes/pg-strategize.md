---
mode:
  name: pg-strategize
  description: Plan next experiments, review accumulated results, make strategic decisions
  default_action: block
  paired_agent: strategist
  tool_policies:
    delegate:
      action: safe
      rationale: Delegates to strategist and foundation:zen-architect
    read_file:
      action: safe
      rationale: Read logs, configs, leaderboards, and architecture references
    grep:
      action: safe
      rationale: Search logs and code for patterns
    glob:
      action: safe
      rationale: Find log and sweep files
    web_search:
      action: safe
      rationale: Research ML techniques and relevant papers
    web_fetch:
      action: safe
      rationale: Read papers, reference documentation
    load_skill:
      action: safe
      rationale: Load domain knowledge relevant to ML strategy
    bash:
      action: block
      rationale: No code execution during strategy phase — thinking only
    write_file:
      action: block
      rationale: No file modification during strategy — read-only deliberation
    edit_file:
      action: block
      rationale: No file modification during strategy — read-only deliberation
  transitions:
    - pg-sweep
    - pg-analyze
    - pg-optimize
    - pg-submit
---

# Strategy Mode `/pg-strategize`

Use this mode when you need to **decide what experiments to run next**. It provides a
read-only, research-oriented environment tuned for deliberation — execution tools are
blocked so the focus stays on reasoning, not doing.

## What it enables

- Delegating to `strategist` to analyze accumulated sweep results and produce prioritized
  experiment plans with specific env var configurations
- Reading leaderboards, logs, and architecture references to inform strategy
- Searching the web for ML techniques, recent papers, or relevant prior work
- Transitioning to `/pg-sweep` once a plan is ready to execute

## What it prevents

- Accidentally launching training runs while still planning
- Modifying files during the deliberation phase

## Typical flow

```
/pg-strategize           ← you are here
  → delegate to strategist
  → review leaderboard, identify patterns
  → produce experiment plan
/pg-sweep                ← execute the plan
```

## Suggested entry prompt

> "Analyze the results from sweep_003 and design the next experiment configurations."

or after a plateau:

> "We've been at 1.2050 for two cycles. What should we try next?"
