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

---

## 6. Owner review — Int/Adv (round 3)

Checks distilled from a manual Intermediate/Advanced read (2026-06). Each is a
standing invariant to re-verify after engine/catalog/pace-math changes. Prod
catalog only (`WORKOUTS_PATH=$PROD`, currently 810 workouts). Anchors via
`vdotpaces` (typical VDOT ~40, plus a fast runner where noted). Verdicts as
found at review time — re-confirm, don't assume.

### C1 — Progression Run must show a real easy→fast spread (REAL BUG)
A `progression` workout that renders a single pace or a ≤5s/km span is a defect
(the owner saw `[4:25, 4:26]` and a lone `4:25`). **Mechanism:** the catalog has
two "Progression Run" shapes — `Z2→Z3` (fine: easy→race, ~50s spread) and
**`Z3→Z4`** (the 35min-Z3 + 6min-Z4 family, ~15 templates). In
`PaceZoneConverter`, Z3 renders at **exact race pace** (base mult 1.0, not 5s-
rounded, line ~371) and Z4 (threshold) is **floored at race pace** for 10K+ via
`r = min(r, racePace/speedPace)` (lines ~355-364). On **5K/10K** (race pace ≈ 5K
speed) that floor pins Z4 to ≈race, so both blocks collapse onto race pace.
- Repro (the real app path = projection mode):
  ```bash
  pr=$(WORKOUTS_PATH=$PROD DIST=10000 TIME=3000 LEVEL=adv TARGET=10000 WEEKS=10 ./plan_debug progress)
  eval "$(echo "$pr" | grep -E '^(RACE_PACE|EASY_PACE|SPEED_PACE|RACE_PACE_END|EASY_PACE_END|SPEED_PACE_END)=')"
  WORKOUTS_PATH=$PROD RACE_PACE=$RACE_PACE EASY_PACE=$EASY_PACE SPEED_PACE=$SPEED_PACE \
    RACE_PACE_END=$RACE_PACE_END EASY_PACE_END=$EASY_PACE_END SPEED_PACE_END=$SPEED_PACE_END \
    ./plan_debug pacedump "Adv 10K (rec" | grep "Progression"
  # observed: "Progression Run 49min [4:45/km, 4:46/km]" (1s) and "56min [4:49/km, 4:50/km]"
  ```
- Also surfaces in legacy fixed-anchor 10K (`56min  5:00/km` lone single) and any
  21K where 5K-threshold rounds onto race. 21K with faithful anchors stays ~10-13s
  (tolerable); 5K/10K is where it collapses. The in-plan structure line confirms
  the shape: `↳ WU 3min · 35:00 @ Z3 · 6:00 @ Z4 · CD 3min` (Int 21K W12, deload).
- **Invariant:** every delivered `progression` workout has ≥2 distinct rendered
  paces spanning **≥15s/km**. Sweep distances/VDOTs; flag span <10s as fail.
- **One-line fix proposal:** on 5K/10K, drop the `Z3→Z4` progression templates
  from the pool (keep `Z2→Z3` + the `Z2/Z3/Z4` 3x-NN), OR render the Z3 block at
  ~Z2-easy when its neighbour Z4 is race-floored, so the two steps don't collide.

### C2 — Int 21K should get a raceRehearsalHM in PEAK (REAL GAP, mild)
Int 42K carries `raceRehearsalM` and Adv 21K/Beg 21K carry `raceRehearsalHM`, but
**Int 21K carries ZERO** (dump grep: Int21K=0, Adv21K=13, Beg21K=3, Int42K=12).
- Confirm: `WORKOUTS_PATH=$PROD ./plan_debug dump "Int 21K" | grep -c raceRehearsalHM` → 0.
- **Mechanism (IntermediatePlanGenerator):** the rehearsal IS appended to
  `longRunTypes` in PEAK for all levels (lines ~347-353, gated on
  `eligibleDistances.contains(21097)` ✓). It loses the **load/duration selection**:
  Int 21K's `maxLongRunMinutes: 100` caps the LR low, and at that duration the
  `raceRehearsalHM` templates (load 7245+) are out-scored by lighter `steadyLong`
  (4677-6233) and the HMP-tail `fastFinish` (7073-8311) which fills the race-pace-
  long role. 42K force-selects its rehearsal via the MP plumbing; 21K has no such
  hook. Holds even at long (18w) — fastFinish wins every PEAK week.
- Verdict: a gap, but Int 21K runners still get HMP exposure via `fastFinish`
  (15-30min @ HMP tail) and `progressiveLong` (Z3). Not a blocker; a polish gap.
- **One-line fix proposal:** add a PEAK forcing hook for 21K mirroring the 42K
  `preferMP` block — on alternating PEAK weeks restrict the LR pool to
  `raceRehearsalHM` so the dedicated rehearsal lands at least 1-2× before taper.

### C3 — Long-run cadence is monotonic-with-deload, not big/small alternation (SOUND)
The "90/130/90/130/90/150" the owner read is the **deload sawtooth + phase-
boundary jump**, not a long/medium-long flip. Actual Int 42K LR (rec) tagged
`/long`: `70 75 80 90 / 85 90 80 130 / 130 135 120 145 155 145 150` — grows
monotonically; deload weeks dip ~20% (`recoveryLongRunTarget`,
`recoveryLongRunCutback`); `applyLongRunMonotonic` forbids a true sawtooth
(BASE non-decreasing; SPEED/PEAK 5min slack; deload floored at ~80% prior). The
big single jump (e.g. short Int 42K W5 80→W6 130) is the SPEED→PEAK boundary where
the LR target leaps from `p.speed` to `p.peak` — amplified by front-trim on short
plans. Physiologically standard (cutback weeks). **Invariant:** LR never *increases*
into a deload week and never drops >35% week-to-week in BUILD.
- Watch-out: don't conflate `mediumLong/easy` (weekday MLR, role `easy`) and
  `marathonPace/threshold` (45-65min) with the LR — grep `/long]` specifically.

### C4 — Consecutive deloads at PEAK end (3:1-meets-phase-end collision; borderline)
Deloads can land 2 weeks running. Confirmed Adv 42K (rec, 18w): **W14+W15 both
`[deload]`, both 4-session** (down from 5), then W16+W17 taper (also deload). Int
42K shows the same W14+W15 pair. **Mechanism (calculateWeeklyTargetsV3):** two
triggers — `isPhaseEndDeload` (`phaseProgression >= 0.8`) and `isMidPhaseRecovery`
(`weekInPhase % 3 == 2`, phases ≥4w). A **7-week PEAK** makes weekInPhase 5 hit
BOTH the 3:1 cut and `5/6=0.83 ≥ 0.8`, and weekInPhase 6 (`1.0`) is also phase-end
→ W14+W15 back-to-back cuts. Note: in `phases` (un-trimmed) mode the deload *load*
sometimes still climbs (progression amplifier), but the **LR and session count do
drop**, so the athlete feels two easy weeks in a row before taper.
- Verdict: borderline. W16/W17 are taper (correct — taper IS a progressive
  deload). The questionable one is **two full-PEAK cutbacks adjacent** (W14+W15).
  Not dangerous (it's *less* load), but it wastes a peak-load week.
- Repro: `WORKOUTS_PATH=$PROD ./plan_debug phases "Adv 42K (rec" | grep -E "PEAK|TAPER"`.
- **One-line fix proposal:** suppress `isMidPhaseRecovery` when the same week (or
  the next) already qualifies as `isPhaseEndDeload`, so a phase emits at most one
  trailing deload before taper.

### C5 — Easy = Long = Medium-Long pace on 42K (INTENDED — capture as check)
Within a given week, `easy`, `steadyLong`/`long`, and `mediumLong` render the
**same pace** (all Z2, same progression factor) — e.g. Adv 42K W9 Long Run and
Easy Run both `5:50/km`. They differ only by **duration**. Correct: aerobic runs
share pace; the stimulus difference is time-on-feet, not intensity.
`progressiveLong` differs only because it adds a Z3 finish (`[5:26, 5:50]`).
Per-week paces drift down across the plan (5:35→6:00 early→late) from VDOT easing,
not per-workout. **Invariant:** in any one week, all pure-aerobic Z2 long/easy/MLR
runs share one rendered pace; only Z3+ tails diverge.

### C6 — Strides ≥20s; ladder catalog is ~80% padding bloat (catalog hygiene)
- **Strides:** the catalog has 15s/20s/25s stride segments; **18 templates use
  15s**, and `2 x 15s` strides DO ship (55 occurrences of "Easy + Strides (2 x 15s)"
  across plans; 31 in Int, 22 in Adv). 15s is too short for a neuromuscular stride
  — **floor stride work-segments at 20s** (prefer 20-30s).
  Check: `WORKOUTS_PATH=$PROD ./plan_debug dump "" | grep -c "0:15 @ Z5"`.
- **Ladder bloat:** `ladderIntervals` = **122 templates but only ~40 distinct
  work-duration sequences** (the rest differ only by WU/CD/recovery padding the
  engine treats as interchangeable). Across ALL delivered plans only **~19 distinct
  ladder bodies ever appear**, and the top ~6 carry the bulk. `pyramidIntervals` =
  0 in prod (pyramids live under `ladderIntervals`). Only a handful are meaningful;
  the catalog could shed most of the 122 without changing any delivered plan.
  Check: `WORKOUTS_PATH=$PROD ./plan_debug dump "" | grep -A1 ladderIntervals | grep "↳" | sed -E 's/.*↳ //;s/WU [0-9]+min · //;s/ · CD.*//' | sort | uniq -c`.
