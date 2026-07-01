# Render consolidation — pace-aware generation (plan)

*2026-07-01. Status: planned, not started. Do this deliberately, in one sitting, with the
byte-diff recipe below.*

## Problem

Generation (PlanGeneratorV3) is pace-blind: it sizes long runs in minutes. The render
(PaceZoneConverter) then re-fits durations to the runner — km window (floor/cap),
minute ceilings, deload ~20% clamp, taper floor-off, 5-min tick. Result: two layers
shape the same duration. Every long-run bug of June 2026 (inverted builds, wrong deload
depth, longest-run-in-taper) lived in the seam.

Current state (v0.4.0+): the seam is documented (LAYER CONTRACT comments), the render
owns duration policy alone, generation owns structure alone (deloads never pick
rehearsals — `applyLongRunMonotonic` + `rampRehearsalMPSegment(isDeloading:)`). Livable.
The consolidation below removes the seam entirely.

## Goal

Generation receives the same pace anchors the render uses and selects/sizes long runs
in target km directly. Render shrinks to: zone→pace conversion + 5-min tick. No km
window, no deload clamp, no taper suppression at render.

## Steps

1. **Plumb paces into generation.** `generatePlanV3WithDeloads(config:…, paceAnchors:)`
   — racePace/easyPace + optional end-anchors (the render's lerp, reproduced per week
   index). App call site: PlanConfigurationView already has both before it generates.
2. **Move `clampLongRunDistance` math into selection.** Per week: compute the km the
   candidate renders to (duration ÷ interpolated easy pace, per-interval for MP blocks),
   apply floor·ramp / cap / ceilings to the *target* the selector aims at — so the
   engine picks a template that already lands in-window instead of rescaling one later.
3. **Move the deload dip into targets.** Deload week long-run target = 0.80 × prior
   delivered (the #171 rule), computed generation-side off the previous week's actual
   pick. Delete `recoveryLongRunTarget` (superseded) and the render clamp.
4. **Taper needs nothing** — with no render floor there is nothing to suppress; taper
   monotonic logic already exists generation-side.
5. **Render keeps**: zone→pace conversion, progressive multipliers, 5-min tick.
   Delete: `clampLongRunDistance`, the deload clamp, `isTaperWeek`/`isDeloadWeek`
   plumbing (WorkoutEvent transient fields go too).

## Verification (non-negotiable)

- Before starting: regen all matrices at HEAD, stash as `/tmp/matrices_before/`.
- After each step: `swift build && swift test` (39), `audit_long_runs.sh` exit 0,
  `test_plans.py` diff vs `/tmp/base_fails.txt` (zero new), regen matrices and diff
  against before — expect near-byte-identical (the whole point is same output, one brain).
- Finish with the 5-tier agent validation (VALIDATION_PLAYBOOK Round 4 brief).

## Risks

- The app generates once and stores events; adaptive re-render paths must pass the same
  anchors or plans shift on re-open. Audit every `applyPaceProgression` caller first.
- Selection targets in km change which templates score best → some churn in picks is
  expected; hold the line on load/duration invariants, not on identical workout IDs.
