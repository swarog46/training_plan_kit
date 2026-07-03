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

Always drive plans with the **production catalog** (716 workouts), not the 60-
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

**The app path is `progress` mode** (current → projected END anchors; see R6-0):
```bash
DIST=5000 TIME=1440 LEVEL=int TARGET=21097 WEEKS=14 ./plan_debug progress
# → RACE_PACE/EASY_PACE/SPEED_PACE + *_END — pass ALL SIX to pacedump
```
Legacy fixed-anchor manifest (no ENDs — only for legacy-mode spot checks):
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
- Quality (Z5-class, MP, 10K-pace) renders FLAT at planned-fitness anchors —
  the DOSE progresses, the pace doesn't (R8-4). Threshold and easy are the only
  movers (current-fitness anchors). A quality pace that drifts week-to-week is a bug.
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
grep -h "Loaded" /tmp/plan_audit/*.txt | sort -u      # every file = 716 workouts
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
catalog only (`WORKOUTS_PATH=$PROD`, currently 716 workouts). Anchors via
`vdotpaces` (typical VDOT ~40, plus a fast runner where noted). Verdicts as
found at review time — re-confirm, don't assume.

### C1 — Progression Run must show a real easy→fast spread (FIXED; keep as standing check)
*(2026-07-03: the Z3→Z4 collapse class is fixed — 5K/10K demote Z3→Z2 in those templates,
and threshold is now capped 5s/km faster than planned MP so Z3/Z4 blocks can't invert.
The invariant below stands; the mechanism text is historical.)*
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

### C2 — Int 21K raceRehearsalHM (RESOLVED 2026-07-03)
*(Root cause was the accessible 21K `maxLongRunMinutes: 72` silently filtering every
75-130min rehearsal template, plus no forcing hook. Fixed: caps 110/120 (Beg/Int), forced
peak alternation, HM rung ladder 20→25→30, and the km-floor now applies to rehearsals
(pace-intent work split). Check: Int 21K ≥2 rehearsals, rungs 20/25/30, 85-90min @ ~16km.)*
Historical finding:
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

### C6 — Strides: ≥15s rep, ≥3 reps (UPDATED 2026-06-28); ladder catalog is ~80% bloat
- **Strides policy (current):** rep duration **15/20/25s — 15s is allowed** (Daniels'
  short end, a legitimate light stride). Rep count **3–6 — 3 is allowed** as a lighter
  option; only **2-rep strides** are still under-dosed. So do NOT flag 15s or 3-rep
  strides — they're intentional variety. The engine floors stride reps at ≥15s
  (`hasShortStrideRep < 15`) and beginners at ≥3 reps.
  Check: `WORKOUTS_PATH=$PROD ./plan_debug dump "" | grep -c "0:1[0-4] @ Z5"` (only <15s is a fail).
- **Ladder bloat:** `ladderIntervals` = **122 templates but only ~40 distinct
  work-duration sequences** (the rest differ only by WU/CD/recovery padding the
  engine treats as interchangeable). Across ALL delivered plans only **~19 distinct
  ladder bodies ever appear**, and the top ~6 carry the bulk. `pyramidIntervals` =
  0 in prod (pyramids live under `ladderIntervals`). Only a handful are meaningful;
  the catalog could shed most of the 122 without changing any delivered plan.
  Check: `WORKOUTS_PATH=$PROD ./plan_debug dump "" | grep -A1 ladderIntervals | grep "↳" | sed -E 's/.*↳ //;s/WU [0-9]+min · //;s/ · CD.*//' | sort | uniq -c`.

---

## Round 4 — rendered long-run build, 5-min tick, ordering (2026-06-28)

These caught a **systemic** bug: 35/72 plan variants had long runs that didn't build.
The lesson threaded through all of them — **validate the RENDERED plan on the SHIPPING
tier, not the HR-side dump of the textbook tier.**

### R4-1 — Long runs must BUILD in RENDERED minutes (the Acc-Beg-21K class)
The km-clamp **floor**, applied flat across build weeks, pinned the long run at the
floor distance (30km M / 16km HM) from week 1 — erasing the HR-side build; easy-easing
then made the rendered **minutes** decline (`128→121`). Fixed by ramping the floor with
plan progression (0→full by the PEAK phase).
- **Validate on `pacedump` (rendered), not `dump` (HR-side).** The HR-side was flat-OK;
  the inversion only exists after rendering.
- **Invariant:** every 21K/42K long run peaks LATE (final ~third of build), never at
  week 1. Fitter runners' minute-curves compress (km build shows less in minutes) —
  flat-but-late-peak is OK; **early-peak-then-decline is the bug.**
- Check (CI gate, exits 1 on regression, all tier×distance×level): `bash scripts/plan_debug/audit_long_runs.sh`

### R4-2 — Aerobic-run durations on a 5-min tick
`easy/recovery/long/steadyLong/mediumLong/progressiveLong/progression` render at
multiples of 5min (no 1-min jitter: `128/126/125` was wrong; `120/115/110` is right).
Quality/interval/race-rehearsal durations stay dose-exact (NOT ticked).

### R4-3 — Progression paces in EXECUTION order (slow→fast)
Progressions are stored slow→fast (Z2→Z3). The rendered pace array reads `[5:00, 4:45]`
(slow→fast, as run), NOT sorted fast-first `[4:45, 5:00]`. (= Gemini's "progressive long
run pace inversion".)

### R4-4 — Validate the SHIPPING tier, not textbook
`PlanConfiguration.shipAccessibleTier = true` → the app serves the **accessible** configs
(`accessible{Beg,Int,Adv}*`), NOT the textbook ones. Audits + eyeballs MUST target
accessible (+ competitive / VO2 / maintenance). The Acc Beg 21K bug hid because reviews
only looked at the textbook matrices users never see.

### R4-5 — Beginner long-run ceilings (SUPERSEDED by R8-1)
Now: Beg half peaks 16-18km (cap 110min); Beg marathon peaks 28-32km with a 245min
ceiling. The old 13km/190min values predate the R8 km floors — do not enforce them.

### Gemini triage — what to validate vs ignore
- **VALIDATE:** long-run build (R4-1); progression order (R4-3); beginner ceilings (R4-5);
  per-tier peak heights sane (Int marathon ~30km, not absurdly longer than Adv).
- **INTENDED, not a flag:** progression runs finishing faster than MP (they finish at
  threshold/HM by design); aerobic easy/long/MLR sharing one pace (differ by duration);
  long-run-every-other-week (deload sawtooth).
- **NON-ISSUES:** "Slow" label = different VDOT per tier (app keys off VDOT, not the label);
  1-min total-volume wobble between adjacent weeks; Yasso/time-based WU-CD split.

## Round 5 — deload long-run policy (2026-07-01)

**R5-1 · Deload build weeks are plain aerobic.** Every `[deload]`-tagged BASE/SPEED/PEAK
week's long run must be `steadyLong`/`progressiveLong` — never `raceRehearsal*`/`fastFinish`.
A down week cuts the stressor; the rehearsal IS the stressor. Enforced in
`applyLongRunMonotonic` (pool filter), `rampRehearsalMPSegment(isDeloading:)`, and the
per-generator `isMPSegmentWeek`/forced-rehearsal guards. Taper `[deload]` tags are exempt
(taper has its own shape).

**R5-2 · Skipped rungs shift, not drop.** A rehearsal slot suppressed by a deload fires on
the next non-deload peak week (`pendingRehearsalSlot`), so short plans keep their ladder:
Cmp 42K rec-18w must show all three MP rungs (60→70→90); short-14w at least 60→70.
Check: `pacedump | grep "Race Rehearsal"` per plan — rungs monotonic, no dups, none on a
`[deload]` week.

**R5-3 · Deload dip stays ~18–22%** (render clamp, unchanged by R5-1) — the swapped-in
aerobic long run still lands at ~0.80× the prior delivered LR; 60-min floor on early base.

Aerobic-share re-bless from R5-1: Cmp 42K rec 83→85 (measured 83.9%), Adv 42K 82→84.

## Round 6 — pace-render invariants + the app-path rule (2026-07-02)

Root lesson: the app called `applyPaceProgression` WITHOUT end anchors (legacy
path) while every validation here passed them — five rounds validated a mode
users never ran. Full story: `PACE_FINDINGS.md`.

**R6-0 · Validate the app-shaped call.** Any render change must be checked in
BOTH modes: with `*_PACE_END` anchors (matrix path) and the kit unit tests that
mirror the app call (`PaceRenderInvariantTests`). The app itself now always
passes projected end anchors for non-Pro race plans.

**R6-1 · Zone separation, per interval.** The matrices now print every interval
with its rendered pace (WU/work/jog/CD). On any rehearsal / MP workout:
warmup and cooldown ≥15 s/km slower than the MP block (≥8 s/km on legacy
renders). No workout may show one identical pace across WU/work/CD.

**R6-2 · Intervals vs 5K (superseded by R8-4).** Z5-class work renders FLAT at
rep-length targets × PLANNED 5K from week 1 (0.88 ≤90s / 0.92 ≤3min / 0.96 longer+hills);
never slower than the planned 5K. 10K-pace work = 1.01×planned 5K flat (exact planned
race pace on 10K plans). The old "eases to target by 60%" band no longer exists.

**R6-3 · MP at the PLANNED race pace (revised 2026-07-02, same day).** Race-pace
work is practiced AT the planned (projected race-day) pace from the first MP
session — Daniels/Pfitz orthodoxy; the progression is the DOSE (60→70→90min
rungs), never a slower rehearsal pace. So: every Z3/MP block and rehearsal MP
segment renders at ONE flat pace = the projected race-day pace (exact, no 5s
rounding); 10K-plan race-pace work ("10K Pace", 10K rehearsals) likewise at
planned 10K pace. MP varying week-to-week is now the bug. Easy/quality anchors
still move current→projected. Pro unchanged (planned == goal, was already flat).
Also: the config screen's predicted finish and the generation anchors use the
SAME projection call (structure-derived perWeek + per-level ceiling) — one number.

**R6-4 · One progression mechanism.** Fitness progression lives in the moving
anchors only. Any new easing/blend on top of an anchor is a defect by
definition (see PACE_FINDINGS "standing lesson").

## Round 8 — training-content rules (owner review, 2026-07-03)

**R8-1 · Peak long run is a DISTANCE, not a minute count.** Marathon builds
peak 28-32km (Cmp 32-35km), half builds 16-18km (Cmp half 18-22km — competitive halves train at/above
race distance, Pfitz-style) — every level, every pace tier. A marathon plan whose longest run is ~17km is not marathon prep. The
km window in `clampLongRunDistance` floors AND caps; the beginner marathon
minute-ceiling is 245min (a slow novice may take ~4h to reach 28km). Check
the RENDERED km: peak LR km must land in band on every level × pace tier.

**R8-2 · Intervals are the lead rep instrument; hills are a flavor.** Real
`intervals`/`ladderIntervals` appear in every half/marathon plan including
BEGINNER (the old "no Z5 reps for beginners" pool rule is dead); hills may
not be the majority of a plan's interval-class sessions. 5K plans: "5K Pace"
sessions at most every other week — short reps (0.88-0.92×planned 5K) run
FASTER than 5K pace between them.

**R8-3 · Quality by W3.** First quality session lands by week 3 in every
half/marathon plan (2-day 5K/10K beginner weeks exempt — no room). 5-week
aerobic-only openings are a defect.

**R8-4 · Quality paces anchor to PLANNED fitness, flat.** Z5-class work
(intervals/ladders/pyramids/hills) renders at rep-length targets ×
PLANNED 5K (0.88 ≤90s / 0.92 ≤3min / 0.96 longer + hills), the same
philosophy as MP: practice destination pace, progress the dose. 10K-pace
work = 1.01×planned 5K (exact planned race pace on 10K plans). Threshold
family (threshold/mileRepeats) stays a CURRENT-fitness stimulus on the
moving 5K anchor (LT→tempo 1.07→1.02). Ladders/pyramids route as interval
work regardless of their catalog Z4 tag.

**R8-5 · Week composition.** (a) A MARATHON-rehearsal week carries no other
quality at all for Beg/Int (the 150min+ rehearsal IS the week; Adv keeps ≤1);
a HALF-rehearsal week keeps exactly ONE other quality (the ~85-90min rehearsal
alone would read as a junk week). No rehearsal week carries a standalone
Marathon Pace session. (b) An intervals week
doesn't also carry mile repeats (one rep-shaped session per week, Beg/Int).
(c) The weekly LONG run out-lasts any medium-long run (durations swap if a
fixed template inverts them). (d) Deload/taper rules from R5/R6 unchanged.

**R8-6 · Strides dosing (for reference).** Daniels prescribes 6-8×20-30s
strides — a 6×25s session is textbook, not excessive. Shakeouts keep ≥3 reps.

**R8-7 · Blessed-fails discipline.** The python suite's blessed-fail list
shrinks, never silently grows: Cmp snapshot drifts and known inversions are
listed in the current baseline (14 lines, /tmp is NOT the home for it — regen via
test_plans.py and compare). Fix underlying causes instead of re-blessing.

## Round 12 — current engine truth (2026-07-03, post Int-21K fix)

Supersedes anything above that contradicts it. Engine state as of kit `e694b36`:

- **Pace model:** MP/rehearsal blocks + Z5-class (intervals/ladders/pyramids/hills)
  + 10K-pace = FLAT at planned-fitness anchors (R8-4). Threshold = current-fitness
  LT curve (1.07→1.02 ×5K-now), capped ≥5s/km FASTER than planned MP. Easy/long =
  current-fitness easy anchor, moving. Race day itself renders at planned race pace.
- **Long runs:** km windows with floors AND caps — 42K 28-33km (Cmp 32-35),
  21K 16-18km Beg / 16-21km Int+Adv (Cmp 18-22); floors ramp in by ~60% of plan,
  off in taper; rehearsals take the floor too (work split by PACE INTENT, the
  segment tick reconciles to the scaled total). Beg-42K minute ceiling 245.
- **Rehearsal ladders:** M 60→70→90 (+4th rung repeats 90 on Cmp until a >90min template exists); HM 20→25→30; 10K 10→15→20. Rungs
  monotonic by occurrence, deload weeks skip (rung shifts, R5-2), titled dose
  delivered exactly (#178).
- **Variety:** intervals lead; ladders at most 1 week in 3; hills a flavor
  (≤~30% of rep sessions); short reps (≤2:30) preferred for beginners; "5K Pace"
  at most every other week on 5K plans; 10K-pace variants ramp.
- **Phase flavor:** BASE = no race-specific subtypes (tenkPace/fivekPace/
  mileRepeats/yasso) and no Z5 in weeks 1-2; PEAK prefers race-specific work;
  quality by W3 in every half/marathon plan (plan-week, not phase-week).
- **Week shape:** ≤1 rep-shaped session/week (Beg/Int); rehearsal-week rules per
  R8-5(a) as amended; long ≥ medium-long; deloads ~20% aerobic-only (R5).
- **Tooling:** `audit_long_runs.sh` is trustworthy again (regex + duration-column
  fixes — it ran vacuously green before 2026-07-03). Blessed python fails: 14
  lines, all pre-existing Cmp-snapshot class + the #189 Beg-42K-short W1 edge.

## Round 13 — per-level volume spread (2026-07-03, kit b78fb4b)

`topUpAerobicVolumeV3`: build weeks scale their plain-aerobic runs (easy/MLR/
recovery — never the LR, never quality) up toward the config's weekly-duration
target (≤+30%/run, 5-min tick; deload/taper/race exempt). The configs' per-level
targets now DELIVER: 42K Typical avg 215/239/274min (Beg/Int/Adv), peaks
340/372/406. Expected side effects (not bugs): midweek easies run longer
(45-75min), MLRs 90-110min, deload dips read deeper vs fuller build weeks.
Invariants: Beg<Int<Adv ladder holds per distance; easy runs stay ≤ the week's
MLR ≤ LR; aerobic shares may sit near their (updated) ceilings; no ACWR spikes.
