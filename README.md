# TrainingPlanKit

The running-plan generator behind [RunPlan](https://runplan.app). Give it a
goal — a distance, a fitness level, a number of weeks — and a catalog of
workouts, and it lays out a periodized training plan: base, sharpening, peak,
taper, with the weekly load rising and backing off the way a coach would write
it.

This is the real engine, not a rewrite. It's the same code RunPlan ships, with
the iOS app, the watch app, and the localization stripped away. There's a
longer write-up of how it thinks on the [RunPlan blog](https://runplan.app/blog/how-training-plans-work).

## What's here

- **The generator** — phase periodization, weekly load progression with
  deloads, taper into race week, and workout selection per phase.
- **VDOT pacing** — Daniels' VDOT model turns a recent race result into
  training paces and heart-rate zones.
- **The models** — `Workout`, `Plan`, `PlanConfiguration`, the workout
  taxonomy. Plain value types, `Codable`.
- **A sample catalog** — 100 workouts, enough variety to generate real plans
  at every distance and level. Not RunPlan's full tuned library (see below).
- **A CLI and a test suite** — the same tools used to develop the engine.

## The plans it makes

**Distances.** 5K, 10K, Half (21.1 km), Marathon (42.2 km), plus non-race
fitness blocks (maintenance, recovery, a VO2-max block).

**Levels.** Beginner, Intermediate, Advanced. Level sets the weekly volume,
the number of quality sessions, and how aggressive the progression is — a
Beginner Marathon plan peaks far lower and gentler than an Advanced one.

**Pro vs. non-Pro.** Two ways to anchor intensity:

- **Non-Pro** plans target a *fitness level*. Intensity is prescribed as
  heart-rate zones, so they work without knowing your race times.
- **Pro** plans target a *time* — Sub-3:00 Marathon, Sub-1:30 Half. You give a
  recent race result; the engine derives your VDOT and prescribes every
  quality session as a pace band, holding the zones at goal pace instead of
  easing them down for comfort. They're stricter, longer, and assume you can
  already run close to the target.

## Quick start

```swift
import TrainingPlanKit

let catalog = loadSampleCatalog()              // or loadCatalog(atPath:)
let config = PlanConfiguration.intermediate42Default
let plan = generatePlan(config: config, totalWeeks: 16, catalog: catalog)

for week in plan.keys.sorted() {
    print("Week \(week):")
    for session in plan[week]! {
        print("  \(session.role): \(session.workout.title)")
    }
}
```

Add it to a project with Swift Package Manager:

```swift
.package(url: "https://github.com/swarog46/training_plan_kit.git", from: "0.1.0")
```

## The CLI

The library builds with `swift build`. The analysis CLI compiles separately,
straight from the sources (no Xcode, no SPM), and prints plans for inspection:

```bash
./scripts/plan_debug/build.sh
./scripts/plan_debug/plan_debug                 # one-line summary per plan
./scripts/plan_debug/plan_debug dump 21K        # week-by-week, half-marathon plans
./scripts/plan_debug/plan_debug pacedump Adv    # pace-converted target zones
```

## Tests

```bash
swift test                                  # unit tests
python3 scripts/plan_debug/test_plans.py    # plan regression suite
```

The regression suite is split in two. Most of it checks structural
invariants — volume progresses then tapers, deloads land on cadence, phases
stay ordered, paces converge to target. Those run and pass against the
bundled sample. The rest assert the exact volumes and aerobic mix of
RunPlan's *full* catalog (peak weekly km, marathon-pace counts), which a
small sample can't reproduce — they print `SKIP` on the sample and run
against a complete catalog:

```bash
WORKOUTS_PATH=/path/to/full_catalog.json python3 scripts/plan_debug/test_plans.py
```

Run both from the repo root — the CLI resolves the bundled sample catalog
relative to the working directory.

A few checks track known-open issues (marked in the inline comments). They
print `KNOWN-FAIL` and are listed in the summary, but don't fail the build —
so CI flags real regressions, not documented gaps.

## The catalog

The engine takes the catalog as an argument — it doesn't ship the catalog. A
catalog is a JSON array of `Workout` (the schema is in
`Sources/TrainingPlanKit/Models/Workout.swift`). The generator filters it by
subtype, duration, and target as it fills each slot.

The sample here is deliberately small. RunPlan's full library is its tuned core
and stays in the app. `scripts/generate_sample_catalog.py` shows how the sample
was pulled from a larger catalog; point it at your own to build a bigger one.

## License

MIT. See [LICENSE](LICENSE).
