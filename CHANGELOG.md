# Changelog

Versions are tags on `main`. Pre-1.0: minor versions may break API;
the determinism contract (same inputs → same plan) holds across all of
them, and refactors are verified by diffing rendered plan catalogs.

## 0.7.0

- Distance-class refactor: distances are a first-class axis instead of
  ~59 scattered literals.
- Four new race distances — 15K, 10 miles, 30K, 50K — with ten presets
  across levels. Existing plans stayed byte-identical through the
  refactor.
- Certification pass for every new-distance plan: km bands,
  plateau-aware long-run checks, back-to-back long days for the ultra.

## 0.6.0

- Determinism fix: strides rotation could flake the generated plan
  between runs (equal-load variants + unordered dictionary iteration);
  a title tiebreaker on the load sort ends it.
- Beginner onboarding: no hard VO2 sessions in week 1 or on early
  deloads; quality starts from the second displayed week.
- Couch-to-5K preset (`.couchTo5K`), Pro 5K/10K presets, VO2-max block
  presets, and the accessible (lighter-load) tier for every level.
- Load-spike guards: aerobic top-up respects the easy ceiling in weeks
  without a long run.

## 0.5.0

- `PlanRecalculator`: checkpoint-driven mid-plan recalibration —
  re-anchor the remaining weeks to a new fitness estimate, preserving
  completed work, with a ±6% race-pace rail per step.
- Missed-training detection with a conservative detraining model (no
  loss under 10 days, then gradual).
- `VDOT.fromRacePace` inversion and `storedPlannedRacePace` exposed.

## 0.4.0

- Deload and taper quality: deload long runs clamp to 0.8× the prior
  delivered long run; taper weeks stop re-rendering the plan's longest
  run; recovery floors tuned per tier.
- Long-run progression: monotonic builds, no flat-then-spike.

## 0.3.0

- Pace correctness batch: thresholds render at true lactate-threshold
  pace at every level, 10K-pace work hits actual 10K pace, easy pace
  anchors to the runner's real pace, Z5 work gets a race-pace floor.

## 0.2.0

- API tightened to seven public entry points; public types usable
  cross-module.
- `plan_debug` gains the `phases` mode.

## 0.1.0

- First extraction from the RunPlan app: generator, VDOT pacing,
  models, sample catalog, CLI, tests.
