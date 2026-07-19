# TrainingPlanKit

![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-F05138?logo=swift&logoColor=white)
![Platforms](https://img.shields.io/badge/platforms-macOS%2013%20|%20iOS%2016-blue)
![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen)
![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)

The running-plan generator behind [RunPlan](https://runplan.app). Give it a
goal — a distance, a fitness level, a number of weeks — and a catalog of
workouts, and it lays out a periodized training plan: base, sharpening, peak,
taper, with the weekly load rising and backing off the way a coach would
write it.

This is the real engine, not a rewrite. It's the same code RunPlan ships,
with the iOS app, the watch app, and the localization stripped away. If you
want to know why Tuesday says 6×800m — or you disagree with a taper — the
logic is all here.

```swift
import TrainingPlanKit

let catalog = loadSampleCatalog()                    // or your own JSON
let plan = generatePlan(config: .intermediate42Default,
                        totalWeeks: 16,
                        catalog: catalog)

for week in plan.keys.sorted() {
    print("Week \(week):")
    for session in plan[week]! {
        print("  \(session.role): \(session.workout.title)")
    }
}
```

```swift
.package(url: "https://github.com/swarog46/training_plan_kit.git", from: "0.7.0")
```

## Deterministic on purpose

Same inputs, same plan, every time. No randomness, no network, no state.
This is the engine's testing story: the CLI renders whole plan catalogs to
text, and every rule change gets reviewed as a diff over hundreds of
generated plans. A refactor that should change nothing has to produce
identical output. The habit has caught more real regressions than the unit
tests, and it means you can read any plan before a runner ever gets it.

```bash
./scripts/plan_debug/build.sh
./scripts/plan_debug/plan_debug                 # one-line summary per plan
./scripts/plan_debug/plan_debug dump 21K        # week-by-week, half-marathon plans
./scripts/plan_debug/plan_debug pacedump Adv    # pace-converted target zones
```

## What's encoded (and where it comes from)

The methodology is the classic coaching canon, turned into configuration and
generators rather than prose:

| Source | What the engine took from it |
|---|---|
| Jack Daniels — *Daniels' Running Formula* | VDOT: a race result → training paces and HR zones; intensity distribution |
| Pete Pfitzinger — *Advanced Marathoning* | Long-run progressions, medium-long runs, marathon-pace blocks, race rehearsals |
| Hal Higdon | The accessibility instinct: beginner plans a normal person can actually finish |
| Standard periodization | Base → speed → peak → taper phases, deload cadence, weekly ramp caps |

## The plans it makes

**Distances.** 5K, 10K, 15K, 10 miles, half marathon, 30K, marathon, 50K —
plus non-race blocks: maintenance, a VO2-max development block
(`.vo2maxIntermediate`), and a Couch-to-5K program (`.couchTo5K`).

**Levels.** Beginner, Intermediate, Advanced — level sets weekly volume,
quality-session count, and how aggressive the progression is. Each level
also has an *accessible* variant (`.accessibleIntermediate42Default`) with
lighter loads.

**Pro vs. non-Pro.** Two ways to anchor intensity:

- **Non-Pro** plans target a *fitness level*. Intensity is prescribed as
  heart-rate zones, so they work without knowing your race times.
- **Pro** plans (`.competitive42Default`, …) target a *time* — Sub-3:00
  Marathon, Sub-1:30 Half. You give a recent race result; the engine derives
  your VDOT and prescribes every quality session as a pace band, holding the
  zones at goal pace instead of easing them down for comfort. Stricter,
  longer, and they assume you can already run close to the target.

## Mid-plan recalibration

Runners get faster mid-plan, or they get sick and lose two weeks. The
`PlanRecalculator` re-anchors the *remaining* weeks of a plan to a new
fitness estimate — from a time trial, or from a detraining model after a
gap — while everything already completed stays untouched. Regeneration is
deterministic, so the recalibrated plan keeps the original's structure; only
the pace anchors move, clamped to a sanity rail. The detraining model is
deliberately slow to panic: no fitness loss for gaps under 10 days, then a
gradual decay.

## The catalog

The engine takes the catalog as an argument — it doesn't ship one. A catalog
is a JSON array of `Workout` (schema in
`Sources/TrainingPlanKit/Models/Workout.swift`); the generator filters it by
subtype, duration, and target as it fills each slot. The bundled sample
(100 workouts) is enough to generate real plans at every distance and level,
but it is deliberately not RunPlan's full tuned library — that's the app's
core and stays in the app. `scripts/generate_sample_catalog.py` shows how the
sample was pulled from a larger catalog; point it at your own.

## Tests

```bash
swift test                                  # unit tests
python3 scripts/plan_debug/test_plans.py    # plan regression suite
```

The regression suite checks structural invariants — volume progresses then
tapers, deloads land on cadence, long runs build monotonically, paces
converge to target — and those run against the bundled sample. A second
group asserts the exact volumes of RunPlan's full catalog and prints `SKIP`
on the sample:

```bash
WORKOUTS_PATH=/path/to/full_catalog.json python3 scripts/plan_debug/test_plans.py
```

Run both from the repo root — the CLI resolves the bundled sample catalog
relative to the working directory.

A few checks track known-open issues (marked in the inline comments). They
print `KNOWN-FAIL` and are listed in the summary, but don't fail the build —
so CI flags real regressions, not documented gaps.

## Status

Pre-1.0. The API is extracted from production code, and it shows in
places — it still moves between minor versions, with deprecations where we
can manage them. The engine logic is the stable part: twenty-plus
full-catalog audits so far, and every distance added in 0.7 went through
its own certification pass.

## Reading more

- [How the plans actually work](https://runplan.app/blog/how-training-plans-work) — the methodology, in prose
- [How we built RunPlan](https://runplan.app/blog/how-we-built-runplan) — the engine's design story, including the byte-diff testing habit
- [Three things we haven't figured out](https://runplan.app/blog/three-things-we-havent-figured-out) — the honest open problems

## Contributing

Issues and disagreements are welcome — especially methodology disagreements
("this taper is wrong because…") with a source. One rule for PRs: the
determinism contract holds. A refactor must leave the rendered catalog
unchanged. A behavior change should include the catalog diff in the PR —
that diff is how we review it.

## License

MIT. See [LICENSE](LICENSE).
