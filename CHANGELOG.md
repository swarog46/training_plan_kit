# Changelog

Versions are tags on `main`. Pre-1.0: minor versions may break API;
the determinism contract (same inputs → same plan) holds across all of
them, and refactors are verified by diffing rendered plan catalogs.

## Unreleased

- Pace: long runs render 5% faster than easy (Pfitz general-aerobic vs
  long); Pro easy runs stay conversational at goal +18%.
- Recovery: deloads carry no marathon-pace work in any tier. Competitive
  half/marathon recovery keeps the days and cuts ~20-25% (was -40%+),
  with a stepped-down taper long run. 30K/50K Advanced and Competitive
  5K/10K deloads now dip below the build week they follow.
- `WorkoutSubtype.race` for race day (was `.easy`).
- Recalibration: the pace-offset door anchors to the plan's rendered
  paces; a direction rail keeps a recalibration from moving workouts
  against the race-pace direction; taper-tail and missed-training fixes.
- Short Runs: an open-ended fitness preset per level
  (`.shortRunsBeginner` / `.shortRunsIntermediate` / `.shortRunsAdvanced`).
  Every run is 40 minutes or less, with one 50-60 minute run every fourth
  week, and the quality sessions climb in density over the weeks.
- Pro 5K/10K presets now target a Sub-20 5K and a Sub-40 10K on five days a
  week (four also supported). `competitiveGoalTimeSeconds(distanceMeters:)`
  is the shared goal table, and the gate anchors the 5K at 20:00.
- `PlanCategory` gains `.fiveKCompetitive`, `.tenKCompetitive` and
  `.shortRuns`, plus `isOpenEnded`.
- Long-run growth: no run more than 15% longer than the longest of the
  previous 30 days (Frandsen et al. 2025, BJSM). Applied by the
  generator and again after the pace render; replaces the +25% chain cap.
- Short VO2 reps ease to Daniels' ratios: 90 s or less at 0.91 × 5K pace
  (was 0.88), up to 3 min at 0.95 (was 0.92). Strides and long reps keep
  their paces.
- Intermediate and Advanced half/marathon plans drop the late time trial
  that stacked with the race-pace rehearsal; the mid-plan one stays.
- Advanced recovery weeks from 15K up keep one quality session; the
  Advanced half caps its peak week at 400 minutes (marathon: 430).
- Multi-race seasons: `SeasonPlanner` lays out up to 11 months of races
  (goal, own-block and tune-up races, each block at least its plan's
  minimum build); `SeasonPlanBuilder` renders each block with the
  single-race engine and keeps the growth cap across blocks.
- Quality cap: Intermediate and Advanced plans under the half hold two
  quality sessions a week (one on three days), Maintenance one, Pro
  5K/10K three; recovery weeks keep one. Extra sessions become easy runs
  of the same length. `PlanConfiguration.maxQualitySessions` overrides it.
- Pro half/marathon medium-long runs stop at 120 and 100 minutes (Pfitz
  18/70) instead of stretching to the long run's length.
- Seasons: a tune-up race on a block's boundary day is added once;
  `SeasonPlanner.maxOtherRaces`.

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
