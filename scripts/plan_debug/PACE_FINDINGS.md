# Pace-render findings — 2026-07-02

Three user-reported bugs, one shared root, and the refactor that followed.
Read this before touching `PaceZoneConverter.swift`.

## The root: two code paths, one validated

`applyPaceProgression` had two modes: VDOT-anchored (start paces → race-week
paces via `racePaceEnd`/`conversationalPaceEnd`/`speedPaceEnd`) and a legacy
mode when the end anchors were absent. The validation pipeline
(`gen_plans_ios.sh` → `proj()`) always passed end anchors; **the app never
did** (`PlanConfigurationView`). Five rounds of agent validation ran on a mode
users never executed. Rule going forward (playbook R6): **validate the
app-shaped call, not just the harness-shaped call.**

## Finding 1 — rehearsal WU / MP / CD rendered one identical pace

Legacy easy-pace math eased easy toward race and clamped at `max(1.0, …)` —
race pace exactly. For low-VDOT runners (easy↔MP headroom 3–5%) the clamp
engaged mid-plan and warmup, MP block, and cooldown all rendered the same
number. Fixes: app passes end anchors (easy rides its own moving anchor,
structurally distinct from MP); legacy floor raised 1.0 → 1.03.
Test: `testRehearsalWarmupAndCooldownStaySlowerThanMP_lowVDOT` (≥15 s/km,
every week, VDOT 32) + legacy variant (≥8 s/km).

## Finding 2 — "Intervals" slower than 5K pace for most of the plan

The Z5 ease-in band started at 1.02×5K and reached the VO2 target (0.96×5K)
only at race week — visible in our own exports (4:45 vs a 4:30 5K anchor).
Fixes: slow end capped at **1.00×current-5K** (a VO2 session slower than 5K
is not a VO2 session) and the band closes by **60% of the plan**.
Test: `testIntervalsNeverSlowerThan5KAndReachTargetBySixtyPercent`.

## Finding 3 — MP rendered 7:30 when the runner expected ~7:10

In legacy mode MP = current-fitness race pace, flat for the entire plan. The
projection model (blogged, shipped for plan-length recommendations) never
touched the app's paces. Fix: the app derives race-day anchors from
`vdot.projected(afterWeeks:)` and passes all three ends — MP now walks
current → projected across the plan and the final rehearsal lands on
projected race pace. Test: `testMarathonPaceConvergesToProjectedRacePace`.

## The refactor (same day)

Every bug traced to a second progression mechanism stacked on the anchors.
`PaceZoneConverter` now has one rule: **fitness progression lives exclusively
in the moving anchors.** Concretely:

- The fast-zone "conservative blend" engine (`conservativeTarget` /
  `initialAdjustment` easing toward slower-than-race intervals) is **deleted**.
- Quality policy is one readable function, `qualityRelative` — fixed
  relations × the 5K-speed anchor, with exactly two named training-design
  curves (threshold LT→tempo emphasis 1.07→1.02; the capped Z5 ease-in that
  closes by 60%). Race-pace floors preserved.
- Easy zones: anchored flat (VDOT mode), legacy 6.5% guardrail with a 1.03
  floor, and one explicit build-band branch (current-easy → goal-easy,
  start-depth = `initialAdjustment`).
- Z3 (MP) is the race anchor, exactly, always.

`PaceProgressionConfig`'s `conservativeTarget`/`minMultiplier` now matter only
to the no-speed-anchor fallback; the presets are otherwise inert markers.

## What the matrices show now

`gen_plans_ios.sh` prints every interval with its rendered pace — warmup,
work, jogs, cooldown (`pacedIntervalDetail` in plan_debug). Zone separation
is inspectable per line; agents and humans check the same artifact.

## Standing lesson

The pace easing knobs looked like tunable training design; they were actually
five interacting fitness models. When a runner-visible number is wrong three
ways at once, look for stacked progression mechanisms — and check which code
path production actually calls before trusting any validation result.

## Addendum (same day) — MP is the planned pace; one projection

Two follow-on decisions after owner review:

1. **MP/rehearsal blocks render at the PLANNED race-day pace, flat.** The
   first implementation had MP tracking the moving anchor (7:27 → 7:11).
   Orthodox prescription (Daniels/Pfitz) is to practice THE pace and progress
   the dose — the rung ladder (60→70→90min) already is the dose ramp. Applies
   to Z3 everywhere and to 10K-plan race-pace work; Pro plans unchanged
   (planned == goal there). R6-3 rewritten accordingly.
2. **One projection.** The config screen's predicted finish
   (structure-derived per-week growth + per-level adaptation ceiling) and the
   plan's end anchors now come from the same call — the pace the plan trains
   toward IS the time the screen predicts.

Bug caught during the change (by the python suite, within minutes): the Z3
rewrite accidentally dropped the `zone <= 2` guard on the aerobic floor,
race-flooring Z4/Z5 fallback paces. Restored with a comment. The guardrails
keep earning their keep.
