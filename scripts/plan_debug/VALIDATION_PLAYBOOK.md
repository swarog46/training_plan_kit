# Plan Validation Playbook

How to audit every generated training plan for sane paces, volumes, progression,
balance, and spacing — and fan the work out to agents. Re-run this whenever the
engine, catalog, or pace math changes.

The philosophy: **don't trust the test suite alone — generate real plans, read
them, and have independent agents look for what tests don't yet cover.** Tests
catch known regressions; this catches the unknown ones, and feeds new tests.

---

## 0. Build the CLI

```bash
cd training_plan_kit
./scripts/plan_debug/build.sh        # swiftc, no Xcode/SPM; ~10s
```

Always drive plans with the **production catalog** (804 workouts), not the 60-
workout sample baked into the binary:

```bash
PROD=/Users/dansh/Sandbox/runplan/RunPlan/Resources/JSON/workouts.json
WORKOUTS_PATH=$PROD ADAPTIVE=1 ./scripts/plan_debug/plan_debug <mode> <filter>
```

- `ADAPTIVE=1` = full/Pro catalog (paid subtypes incl. raceRehearsal, mileRepeats,
  yasso800, marathonPace). `ADAPTIVE=0` = free tier. Audit primarily at `1`.
- `<filter>` = case-insensitive label substring: `5K`, `10K`, `21K`, `42K`, `Cmp`,
  `VO2`, `Maint`, `Acc`. Empty = all plans. Each distance filter pulls **every
  duration variant** (short/rec/long/max) and every level — the duration sweep is free.

### Modes
| mode | what it shows | used for |
|------|---------------|----------|
| `summary` | one line/plan: E/L/H/P counts, load & min per week | cross-level volume scaling |
| `dump` | per-week, per-workout: duration, load, subtype, phase, Z5 min | volume, load progression, complexity, type balance |
| `pacedump` | per-workout converted **paces** (needs RACE/EASY/SPEED env) | pace sanity, inversions, pace progression |
| `daydump` | day-by-day via the real scheduler; auto-flags ⚠ back-to-back quality | spacing (hard-day separation) |
| `vdotpaces` | derive RACE/EASY/SPEED + threshold/interval/rep from a race result | faithful inputs; slow-runner checks |
| `phases` | phase split + per-week load target/multiplier | phase-structure sanity |

---

## 1. Derive faithful pace inputs

`pacedump` needs the same three paces the app passes (`PlanConfigurationView`):
`RACE_PACE` (race pace at the plan distance), `EASY_PACE` (`vdot.easyPaceSecondsPerKm`),
`SPEED_PACE` (`vdot.fiveKPaceSecondsPerKm`, anchors Z4/Z5). Get them from a race result:

```bash
DIST=10000 TIME=4500 ./scripts/plan_debug/plan_debug vdotpaces   # 75:00 10K → VDOT 24.7
```

Generate a **typical** (VDOT ~40) and a **slow** (VDOT ~25, sub-30 where easy-pace
compression fires and zones bunch) input per distance. Competitive plans anchor
`RACE_PACE` to the **goal** (256 = 4:16/km), with `EASY`/`SPEED` from the runner's
current VDOT (build-band ~55, clear ~58+).

> ⚠ **zsh gotcha**: the Bash tool runs under zsh, which does NOT word-split
> unquoted `$var`. A `for spec in "...";  set -- $spec` loop silently collapses to
> one arg and every row falls back to defaults. Use explicit calls or `${=spec}`.

Reference manifest (regenerate if the pace math changes):
```
5K  typ RACE=288 EASY=357 SPEED=288 | slow RACE=432 EASY=493 SPEED=432
10K typ RACE=300 EASY=358 SPEED=289 | slow RACE=450 EASY=493 SPEED=432
HM  typ RACE=312 EASY=355 SPEED=287 | slow RACE=469 EASY=491 SPEED=430
M   typ RACE=341 EASY=374 SPEED=302 | slow RACE=469 EASY=485 SPEED=422
CMP buildband RACE=256 EASY=277 SPEED=220 BUILD_BAND=1 | clear RACE=256 EASY=259 SPEED=205
```

---

## 2. What to look for

### A. Pace invariants (distance-aware — the naive "all quality ≥ race pace" is WRONG)
- **Universal:** easy & long-run dominant pace are **never faster than race pace**
  (aerobic floor). Long runs may *touch* race pace via marathon-pace segments.
- **Universal:** rep & interval (VO₂ work) are **never slower than race pace**. For a
  5K they land ≈ equal (interval = 5K pace − 3s); never slower.
- **Distance-dependent (do NOT flag):** threshold/tempo/mile-reps are **slower than
  race pace for 5K/10K** (threshold is a ~1-hour effort, a 5K is run above it) but
  **faster for half/marathon**. Expect the flip between 10K and half.
- **Zone ladder** stays ordered everywhere: rep < interval < threshold < marathon < easy.
- **In-workout:** within one session, a work/VO₂ segment must not be slower than that
  plan's own threshold; recovery/easy must not be faster than the work segment.
  This is the true "inversion bug" class — distance-independent.

### B. Magnitude rule (how to triage a flag)
**False positives are acceptable but must be validated.** For any suspected issue,
re-derive the expected value and measure the gap:
- gap ≲ **8s/km** → tolerable, note only.
- gap ≳ **30s/km and unexpected** → real finding, report.
- Slow runners (VDOT <30) bunch threshold/race/interval within ~15s — highest
  inversion risk, lowest tolerance. Look hardest there.

### C. Volume & load by level
- Weekly minutes/load scale **Beg < Int < Adv < Cmp**. No level inverts.
- Durations within caps (no 300-min beginner run, no 0-min workout).
- Volume sane for the distance (5K < 10K < half < marathon weekly minutes).

### D. Progression *through* the plan (check across short/rec/long)
- Quality paces **sharpen** week-to-week (easing-in), don't jump.
- Weekly load/volume **builds** then tapers; long run **grows** monotonically then drops.
- Workout **complexity grows** (e.g. 4×6min → 3×12min threshold; 8×75s → 12×90s hills).
- Short plans (front-trimmed) aren't broken; long/max plans don't plateau or repeat.

### E. Type balance & spacing
- Healthy E/L/H/P mix; no week that's all-quality or all-easy; no odd adjacencies.
- Week-to-week novelty — not the same three workouts every week.
- **Quality days separated** by an easy or rest day (`daydump` ⚠ flags = 0 is the goal).

---

## 3. Verify the data BEFORE spawning agents

Garbage in → garbage findings. Confirm:
```bash
grep -h "Loaded" /tmp/plan_audit/*.txt | sort -u      # every file = 804 workouts
grep -liE "FAILED|fatal|nil" /tmp/plan_audit/*.txt    # expect none
# pace outlier scan: flag <2:50 or >10:30 /km
# spot-check: slow easy compressed (not 9:xx), easy < race, long run grows,
#             daydump back-to-back count, duration variants present
```
Only proceed once paces sit in sane bands and spot-checks pass.

---

## 4. Spawn the agents

Pre-generate all data to `/tmp/plan_audit/` (structure + spacing + typ/slow paces),
then fan out **one agent per distance + competitive + a cross-cutting sentinel**.
Send all in one message so they run concurrently. Each agent is read-only on engine
source; **the orchestrator writes fixes/tests**, never the agents (avoids conflicting edits).

Per-agent prompt must include: scope (files), the §2 invariants + magnitude rule,
the requirement to **validate every flag** (re-derive expected, classify magnitude,
mark anything unconfirmed), and a structured return:

```
findings: [{ severity: blocker|warn|note,
             plan, location (week/workout),
             observed, expected, magnitude_sec,
             confidence: confirmed|needs-check,
             note }]
positives: [what was checked and is healthy]
```

Suggested slices:
1. **5K** — Beg/Int/Adv/Acc + VO₂ overlap
2. **10K** — Beg/Int/Adv/Acc
3. **Half (21K)** — Beg/Int/Adv/Acc (skip Cmp)
4. **Marathon (42K)** — Beg/Int/Adv/Acc (skip Cmp)
5. **Competitive** — Cmp 21K+42K, all lengths, build-band + clear
6. **Specialty** — VO₂, Maintenance, Accessible-tier vs full cross-check
7. **Inversion/magnitude sentinel** — all pace files, adversarial second opinion,
   slow-runner bunching focus; exists to catch what the distance agents rationalize away.

---

## 5. Synthesize → add tests

- Dedupe findings; keep only **confirmed** ones (re-verify with the CLI).
- For each real issue: fix in the engine, then **add a test with teeth** — break the
  thing, confirm the test goes red, restore. Prefer the Python suite
  (`scripts/plan_debug/test_plans.py`, parses CLI output) for plan-shape invariants;
  Swift `VDOTTests` for pace-derivation math.
- Encode the §2 invariants as standing tests where missing: easy/long ≤ race pace,
  rep/interval ≥ race pace, zone-ladder order, magnitude bounds, volume-by-level,
  long-run growth, 0 back-to-back-quality.
- Run `swift test` + `python3 scripts/plan_debug/test_plans.py` green before done.
