# Overhead Evaluation (P5 — design only)

Start P5 only after P1–P4 tests are green. Scope-change protocol and tiered testing
are already implemented (P1/P2) and are INPUTS to measurement, not deferred items.
No benchmark code is added here — this is a retrospective scoring method.

## Metrics (per task, read from `.powerflow/<slug>/` + harness logs)

| Metric | Source | Why |
|---|---|---|
| User checkpoints per task | `summary.md` User decisions lines | Measures interruption cost; feeds clarification-threshold rule |
| Subagent delegations per phase | `summary.md` + execution log | Measures delegation overhead (Small should be ~0) |
| Input/output tokens per phase | Harness logs, copied manually (no new tooling) | Measures token cost of ceremony vs work |
| Artifact count + lines | `find .powerflow/<slug> -type f \| wc`, `wc -l` | Measures task-dir volume |
| Wall time (human) | Manual note at closeout | Measures elapsed cost |
| Review rounds | `reviews/` file versions | Measures review-loop cost; cap is 3 |
| Tier 3 runtime | `pre-integration-test-run.log` COMMAND wall time | Measures full-suite cost; feeds waiver policy |
| Scope changes | `reports/scope-change.md` count | Measures contract-fit quality |
| Post-integration defects | Follow-up fixes within 7 days | Measures whether gates caught real bugs |

## Method

1. Sample 5 Small + 5 Big retrospective task dirs (real past work, not synthetic).
2. Score each with the one-page sheet below. No automation required.
3. Compare matched pairs where possible: Powerflow run vs direct run on similar tasks,
   or Small-direct vs Big-full within the suite.

### One-page scoring sheet

```
Task: <slug> | Classification: Small/Big | Complexity: Low/High | Risk: Low/High
Checkpoints: _  Delegations: _  Tokens in/out: _/_  Artifacts: _ files, _ lines
Wall time: _  Review rounds: _  Tier3 runtime: _  Scope changes: _
Defects ≤7d: _
Checkpoint that changed a decision (if any): _
Artifact never read back (if any): _
```

## Decision rules

- If Tier 3 dominates runtime on Low/Low tasks with zero defect delta across the sample
  → allow recorded Tier 3 waivers for Low/Low (Tier 1+2 still mandatory).
- If a checkpoint never changes a decision across N tasks → demote it to announce-only
  (state assumptions and continue; user can still intervene).
- If Small-task artifact volume exceeds ~2× the implementation diff without resume value
  → reduce doc levels for Low/Low (concise `summary.md` + evidence only).
- If per-step atomic commits add overhead on docs/config/interdependent steps with no
  isolation benefit → allow grouped commits for those change types (record exception reason).

## Constraint

No simplification may weaken P1 safety (preflight, base discipline, verify-before-delete)
or P3 gates (verdict vocab, AC→evidence, diff ⊆ scope, SHA equality). Overhead tuning
changes cost, never correctness invariants.

## Explicitly deferred (not this enhancement)

- 3-layer core protocol / adapter / policy-profile split — revisit only when a second
  harness actually diverges.
- Full A/B benchmark harness — the scoring sheet above is sufficient signal at this size.
