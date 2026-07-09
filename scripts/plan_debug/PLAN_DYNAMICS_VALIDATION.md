# Plan Dynamics Validation

Read-only dynamics audit of **all 56 generated plan variants** (16 families:
Beg/Int/Adv/Cmp × 5K/10K/21K/42K + Maintenance + VO2, including the Accessible-tier
mirrors). Built from the current working tree — **includes the uncommitted
recovery-week fix** (`PlanGeneratorV3` + the 4 level generators: ~20% long-run cut +
relaxed interval floor on deload weeks).

- **Engine build:** `./scripts/plan_debug/build.sh` (current working tree, recovery-week fix present)
- **Catalog:** `RunPlan/Resources/JSON/workouts.json` — **804 workouts**, `ADAPTIVE=1`
- **Data:** `dump` (titles/load/subtype/phase), `daydump` (real scheduler day placement),
  `aerobic` (per-interval Z1-2 vs Z3+ minutes), `pacedump` (faithful per-§1 inputs), `phases`
- **Method:** all data dumped to `/tmp/plan_audit/`, parsed by `analyze.py` / `analyze2.py`.
  Parser verified to cover **767/767 week-headers and 3186/3186 workout lines** (an early
  regex dropped space-padded low-load weeks; fixed and re-run before any conclusions).
- **Scope constraint honored:** the intentionally-light volume and the LOCKED day-counts
  (Beg 2/2/3/4, Int 3/3/4/4, Adv 4/4/5/5) are **not** treated as failures. This audits
  **structure/dynamics**, not magnitude.

---

## Issues found

**3 real issues, all LOW severity (notes). 0 blockers, 0 warnings.** No plan fails any of
the five criteria on a structural basis. The notes below are defensible design choices
worth awareness, not defects.

### 1. (LOW) Progression-run sits the day before a quality session in Adv/Maint peak weeks
*Criterion 5 (spacing). Worst offender: **Adv 42K (long, 22w)**.*

The day-scheduler never places two **true quality** sessions on consecutive days
(STRICT quality-on-quality adjacency = **0** across all 56 plans; the tool's own
`⚠ back-to-back quality` count = 0 for every family). But it treats **progression runs
as non-quality**, so a mid-week progression run can land the calendar-day *before* a
threshold / mile-rep / marathon-pace day. 28 such broad adjacencies, concentrated in
**Adv** (and `Maint Adv`):

| Plan | Weeks | Pattern (Wed → Thu) |
|------|-------|---------------------|
| **Adv 42K (long, 22w)** | W13, W16, W19 | Progression Run (49-56min) → **Marathon Pace** (90-110min) |
| Adv 21K (long, 18w) | W7, W10, W13, W16 | Progression Run (54-66min) → **Threshold Run** |
| Adv 42K (long, 22w) | W7, W10 | Progression → Mile Repeats / Threshold |
| Maint Adv (12w) | W5, W8, W11 | Progression → Ladder/Threshold |
| Adv 5K/10K (several) | — | Progression (Fri) → Progressive Long Run (Sat) |

Why it's only a note: the real schedule keeps the two *high-intensity* anchors (Mon
intervals, Thu threshold/MP) 2-3 days apart, with Tue rest and Fri easy around the
Wed progression. A medium/progression run before a threshold day is a recognized
cumulative-fatigue pattern in advanced marathon plans. **Recurs every 3rd week through
the peak block**, so if anything is ever tightened, this is the lever — add
`progression` to the scheduler's quality-spacing set, or move the Wed progression to
the open Tue/Sun slot.

### 2. (LOW) `Acc Beg 10K (rec, 9w)` opens with a 3-week flat load plateau
*Criterion 2 (load progression).*

W1 = W2 = W3 at **load 4660** (identical), then progression resumes (W4 4847 → W6 12495).
The **standard** `Beg 10K (rec, 9w)` ramps from the start (4660 → 4847 → 5792), so this
is specific to the Accessible-tier's lighter/stretched base. It's BASE-phase onboarding
(easing a beginner in is reasonable), but it is the **only ≥3-week identical-load
plateau in the entire audit**. Every other plan shows a clean sawtooth.

### 3. (LOW) `Beg 5K` and `VO2 Beg` run hot on the intensity ratio
*Criterion 4 (distribution). By aerobic MINUTES, not load.*

Faithful easy:hard by Z1-2 vs Z3+ minutes: `VO2 Beg` **56% hard**, `Acc/Beg 5K (long/rec)`
**44-55% hard** — well outside 80/20. This is *structural to short speed/VO2-focused
plans on 2 days/week*: the easy backbone is thin by design (locked day-count), the plan's
whole point is the speed stimulus, and absolute hard volume is tiny (≤6 quality
sessions). Listed for completeness; **not** a defect given the constraint to not flag the
intentionally-light volume. Note the gradient is monotone and correct — Cmp plans sit at
a healthy 14-18% hard, Adv 21K/42K at 22-29%.

---

## PASS / FAIL matrix (per family)

✅ = pass · 📝 = pass-with-note (see Issues). Families fold their Accessible-tier mirrors.

| Family | 1. No 4+wk repeat | 2. Load sawtooth | 3. Pace progression | 4. 80/20 distribution | 5. No all-hard / no B2B |
|--------|:---:|:---:|:---:|:---:|:---:|
| Beg 5K | ✅ | ✅ | ✅ | 📝 hot ratio (short plan) | ✅ |
| Int 5K | ✅ | ✅ | ✅ | ✅ | ✅ |
| Adv 5K | ✅ | ✅ | ✅ | ✅ | 📝 prog→PLR (W2/W5) |
| Beg 10K | ✅ | 📝 Acc flat W1-3 | ✅ | ✅ | ✅ |
| Int 10K | ✅ | ✅ | ✅ | ✅ | ✅ |
| Adv 10K | ✅ | ✅ | ✅ | ✅ | 📝 prog→PLR (W4/W7) |
| Beg 21K | ✅ | ✅ | ✅ | ✅ | ✅ |
| Int 21K | ✅ | ✅ | ✅ | ✅ | ✅ |
| Adv 21K | ✅ | ✅ | ✅ | ✅ | 📝 prog→threshold (peak, every 3rd wk) |
| Cmp 21K | ✅ (titles rotate) | ✅ | ✅ | ✅ | ✅ |
| Beg 42K | ✅ | ✅ | ✅ | ✅ | ✅ |
| Int 42K | ✅ | ✅ | ✅ | ✅ | ✅ |
| Adv 42K | ✅ | ✅ | ✅ | ✅ | 📝 **prog→MP (W13/16/19)** — worst |
| Cmp 42K | ✅ (titles rotate) | ✅ | ✅ | ✅ | ✅ |
| Maintenance | ✅ | ✅ (no peak by design) | ✅ | 📝 Maint Adv 41% hard | 📝 Maint Adv prog→threshold |
| VO2 | ✅ | ✅ | ✅ | 📝 VO2 Beg 56% hard | ✅ |

No ❌ in any cell. The 📝 cells are the three low-severity notes above; none is a
structural failure.

---

## Notes per criterion

### Criterion 1 — No same workout repeated 4+ consecutive weeks  → **PASS (all families)**

Checked by runner-visible **base title** across consecutive weeks (a title appearing 4+
weeks running = candidate failure), then validated whether the underlying session
actually rotates.

- The aerobic backbone — `Easy Run`, `Long Run`, `Medium-Long Run`, `Easy + Strides` —
  recurs every week in long plans (streaks up to 25 wks, e.g. `Cmp 21K (max)` Easy+Strides
  wks 1-25). **This is by design** and excluded; every plan must have easy days weekly.
- **Quality-title** streaks ≥4 wks all resolve to **rotating parameterizations**, verified
  by inspecting durations/reps:
  - `Cmp 42K (build, 28w)` "Threshold Run" wks 11-25 (15-wk streak) → alternates
    `3×8min ↔ 3×10min`, then shifts to `2×12min ↔ 2×15min`. Different session every week.
  - `Cmp 21K (max, 32w)` "Intervals" wks 20-31 → 5/4/10/6-segment variants rotate.
  - `Progressive Long Run` streaks (max 8 wks, `Cmp 21K max` W18-25) → duration oscillates
    with the sawtooth (75→80→90→100→105→115min building, dips on recovery). The long-run
    label is generic; the actual session length varies.
- **Verdict:** no plan repeats a genuinely identical quality session 4+ weeks. The catalog's
  same-title/different-duration variants are doing their job (this is exactly the case the
  audit brief anticipated).

### Criterion 2 — Load progression sensible  → **PASS (all families)**

Clean sawtooth everywhere; the recovery-week fix is working.

- **Build/peak plans ramp then cut back on schedule.** Examples (×1000 load):
  - `Adv 21K (long)`: 20→24→24→29 (base) → 34→32→34→36→38→41 (speed, W11 cutback 34) →
    42→45→W14 dip 34→**peak 51**→40 → taper 25→12. Textbook.
  - `Cmp 42K (build, 28w)`: regular deload every 3rd week (W3 23k, W6 26k, W9 30k) inside a
    long ramp to ~47k, then taper 19→18→12.
  - `Int 21K (long)`: recovery dips at W8 (16k) and W14 (15.5k) between higher blocks —
    the long-run cut from the uncommitted fix lands these troughs.
- **`[SPIKE_UP]` flags (29) are all legitimate**, not erratic: each is either (a) a
  base→speed onboarding ramp where beginners start very easy (e.g. `Beg 5K` W3→4
  +211% off a near-zero base), or (b) a **rebound out of a deload trough** into the next
  peak (e.g. `Int 21K long` W7 27k → W8 40k). The "spike" is *up from a recovery week* =
  the sawtooth functioning. None is a random mid-build jump.
- **`[NO_BUILD]` (Maint Beg/Int):** correct behavior — maintenance plans have no peak phase
  by design (flat-ish with deload weeks).
- **One real `[FLAT]`:** `Acc Beg 10K (rec)` W1-3 identical (Issue #2 above).

### Criterion 3 — Pace progression sensible  → **PASS (all families)**

`pacedump` with faithful per-§1 inputs (typical + slow per distance; Cmp build-band + clear).

- Pace sanity gate passed: **no pace outside 2:50-10:30/km**; slow-runner easy compresses to
  7:4x-8:1x (not 9:xx); easy < race everywhere; rep/interval ≥ race; zone ladder ordered.
- Quality paces **hold or sharpen** through each plan (the documented easing-in), e.g.
  `Int 5K (long)` 5K-pace work 4:45 → 4:40 → 4:40 across the block; hill/interval paces
  tighten toward peak. **No quality inversion** (a later same-type session slower than an
  earlier one without reason) in any family.
- The documented "intensity-correct not label-correct" flips are present and **correct, not
  bugs**: threshold/tempo run *slower* than race pace for 5K/10K (a 5K is run above
  threshold) and *faster* for half/marathon — exactly the expected 10K→half flip.

### Criterion 4 — Distribution (80/20 by stress, type variety)  → **PASS (all families)**

Measured two ways; the faithful one is **aerobic minutes** (Z1-2 incl. warmup/cooldown/
recovery vs Z3+ work), the proper 80/20-by-time denominator (TSS-load over-weights short
hard sessions and is misleading here).

- **Distribution gradient is monotone and sane:** Cmp plans **14-18% hard-min**, Adv
  21K/42K **22-29%**, Int **18-32%**, beginners at longer distances **32-39%**, and the
  short speed/VO2 plans the hottest (**44-56%**, Issue #3). The races that *should* be
  most polarized (long Cmp marathon) are the most aerobic. No family inverts.
- **Type variety is healthy:** Adv/Cmp plans carry **9-12 distinct hard subtypes**
  (intervals, hills, ladders, threshold, mile-reps, yasso, time-trial, 5K/10K-pace,
  marathon-pace, progression, race-rehearsal). Two mild concentration flags
  (`VO2 Int` 63% of hard load = `fivekPace`; `Int 5K (short)` 72% = `fivekPace`) are
  **correct for their purpose** — a VO2 plan and a 5-week 5K sharpener *should* lean on
  5K-pace work — and still carry 3-5 hard types.
- No week is all-easy; phase balance is correct (BASE aerobic-heavy, PEAK race-specific —
  e.g. Adv 42K peak introduces marathon-pace + race-rehearsal blocks).

### Criterion 5 — No all-hard week / adequate recovery  → **PASS (all families)**

This is the criterion where the **label-vs-intensity distinction matters most**, so it was
validated against the **real scheduler** (`daydump`), not just the workout list.

- **No genuinely all-hard week.** A label-level scan flagged 13 "all-hard" weeks, but
  every one, viewed through the real day-scheduler, has **rest days and aerobic/moderate
  sessions interspersed** — the "hardness" came from counting `progression` /
  `progressiveLong` as pure quality. Example, `Adv 5K (rec) W2`: Mon Q Hills · Tue rest ·
  Wed Q Threshold · Thu rest · Fri Progression · Sat Progressive-Long · Sun rest. Two true
  quality days, properly spaced, three rest days. By intensity these weeks are **not**
  all-hard.
- **Zero back-to-back true-quality days** across all 56 plans (tool `⚠` count = 0;
  independent re-derivation from `daydump` = 0). The scheduler reliably separates VO2/
  threshold sessions with an easy or rest day.
- The only adjacency class is **progression → quality** (Issue #1) — a deliberate scheduler
  choice (progression is not in its quality-spacing set), defensible, low severity.

---

## Data / reproduction

```bash
cd training_plan_kit
./scripts/plan_debug/build.sh
PROD=RunPlan/Resources/JSON/workouts.json   # 804 workouts
WORKOUTS_PATH=$PROD ADAPTIVE=1 ./scripts/plan_debug/plan_debug dump    > /tmp/plan_audit/dump_all.txt
WORKOUTS_PATH=$PROD ADAPTIVE=1 ./scripts/plan_debug/plan_debug daydump > /tmp/plan_audit/daydump_all.txt
WORKOUTS_PATH=$PROD ADAPTIVE=1 ./scripts/plan_debug/plan_debug aerobic > /tmp/plan_audit/aerobic_all.txt
# pacedump per §1 manifest (typ + slow per distance; Cmp build-band + clear)
python3 /tmp/plan_audit/analyze.py     # criteria 1,2,4,5a
python3 /tmp/plan_audit/analyze2.py    # criteria 1(quality-only),4(aerobic-min),5b(adjacency)
```

Parser coverage verified at 767/767 weeks and 3186/3186 workout lines before drawing
conclusions. Spacing checked against the real `createMarathonPlanV3` scheduler, not the
flat workout list.

---

## Post-reshaping prod re-audit (deload-session reshaping)

Read-only re-audit on the **production catalog (804 workouts, `ADAPTIVE=1`)** after a
second, uncommitted recovery-week change layered on top of the prior fix. **Method:
A/B diff** — built the CLI on the working tree (reshaping present), then `git stash`-ed
the 5 generator files to rebuild the pre-reshaping baseline (commit `1ef7404`), and
diffed every build-phase deload week. Data in `/tmp/plan_reaudit/`
(`reaudit.py`, `diff_reshaping.py`).

**The reshaping under test (BUILD-phase deload weeks only — base/speed/peak):**
- `>=5`-session weeks **drop** the largest aerobic fill (mediumLong/easy; never the
  long run, never quality) → week lands at `>=4` sessions (a real rest day).
- `<=4`-session weeks (or when no aerobic fill exists to drop) **lighten**: replace the
  single heaviest quality with a progression near its duration (`deload_progression`),
  else an easy run (`deload_easy`).

Verified it fires on prod: **64 `deload_*` tags** (53 progression, 11 easy) across 26
plan variants, plus 63 silent drop-a-session weeks. 172 build-deload weeks total:
drop=63, lighten→prog=44, lighten→easy=11 (remainder are RACE/Maint weeks the phases
model marks `[deload]` that this BUILD-only step intentionally doesn't touch).

### Verdict: NO REGRESSION. All 5 criteria still PASS; two get measurably better.

The A/B diff is unambiguous: **reshaping introduced 0 new test failures** (the suite
fails 18 checks *identically* on baseline and reshaped — all pre-existing peak-LR tier
caps / Cmp BASE long-run ordering / VO2 1–2s race-pace bunching / stale "unchanged"
sentinels, none deload-related), **0 new back-to-back-quality days** (`daydump` ⚠ = 0
on both), and **0 new sawtooth breaks**.

| Criterion | Result | Evidence (baseline → reshaped) |
|---|---|---|
| **1. No 4+ wk repeat** | ✅ PASS | All quality-title streaks still rotate by duration/reps. Reshaping *shortened* one streak (Adv 42K MP W15–19→W15–18) and broke others by injecting progression/easy; created none. |
| **2. Load sawtooth + deeper dips** | ✅ PASS (improved) | Mean realized deload-week load **26 984 → 23 106 (−14%)** over 172 weeks — the intended deeper dip. Sawtooth-break count (deload week ≥ its non-deload neighbour mean) **52 → 22**; reshaping *introduced none, fixed 30*. Remaining 22 are pre-existing phase-label quirks (Maint every-4th, 5K-rec SPEED peak, phase boundaries). No plan flattened. |
| **3. Pace progression** | ✅ PASS | Injected `deload_*` sit in the aerobic band: e.g. Int 21K progression 5:00–5:45 vs that plan's threshold 4:55–5:00 (no work-segment inversion); easy < race everywhere. Quality keeps sharpening across remaining hard weeks. The only ">race" hits are (a) strides (by-design neuromuscular) and (b) progression runs finishing at ~MP/threshold — distance-correct per §2A, ≤31s, pre-existing, not reshaping-introduced. |
| **4. 80/20 distribution** | ✅ PASS | **No plan dropped to zero hard sessions.** Lighten branch trades a few H→P on deload weeks (e.g. Int 42K long 36H→30H, +4P); Cmp plans lose **0** hard sessions (they drop aerobic fill) and just shed 5–7% load. Total-load delta −0% to −7%, concentrated on deload weeks. No over-tip toward easy. |
| **5. No all-hard / no B2B** | ✅ PASS | Removing/lightening hard load on deloads only helps. `daydump` back-to-back-quality = **0 → 0**. No all-hard week. |

### Only nuance worth a note (LOW, not a regression)

**`Int 5K (long, 10w)` W8** (PEAK deload) is the single week where the lighten branch
fell through to `deload_easy`: baseline `Intervals (10 seg) l=6097` → reshaped
`Easy + Strides (2×15s) l=2010`, leaving that one week with no quality body (the strides
retain a neuromuscular touch). It happens because no progression template sits within
±12 min of the 26-min target. It's a correct down-week, the plan is not flattened, and
absolute load is tiny — defensible. If ever tightened, widen the progression
duration-match window or fall back to a *short* progression before pure easy. Every other
`deload_easy`/`deload_progression` week retains a long run and/or a progression stimulus;
**zero** build-deload weeks are truly stimulus-free as a result of the reshaping (the 6
other all-easy `[deload]` weeks — Maint W10, 5K/42K RACE-phase tapers — are unchanged
from baseline and outside this step's scope).

### Reproduction
```bash
cd training_plan_kit
PROD=/Users/dansh/Sandbox/runplan/RunPlan/Resources/JSON/workouts.json
# reshaped:
./scripts/plan_debug/build.sh
WORKOUTS_PATH=$PROD ADAPTIVE=1 ./scripts/plan_debug/plan_debug dump    > /tmp/plan_reaudit/dump_all.txt
WORKOUTS_PATH=$PROD ADAPTIVE=1 ./scripts/plan_debug/plan_debug phases  > /tmp/plan_reaudit/phases_all.txt
WORKOUTS_PATH=$PROD ADAPTIVE=1 ./scripts/plan_debug/plan_debug daydump > /tmp/plan_reaudit/daydump_all.txt
# baseline: git stash the 5 Engine/*Generator*.swift, rebuild, dump -> BASE_dump_all.txt, pop
python3 /tmp/plan_reaudit/reaudit.py        # 5-criteria pass on reshaped
python3 /tmp/plan_reaudit/diff_reshaping.py # per-deload-week baseline→reshaped diff
```

## R22 — Cmp 5K/10K certification (2026-07-09)

**Status: CERTIFIED** at rec length (12w), sub-19 / sub-40 class anchors.

Shape: exact 2/4/4/2 phase split at 12w (ratios 0.2/0.4/0.4 normalize clean
over the 10 non-taper weeks) → mid-phase deloads W5+W9, crescendo peaking at
peak-end. Volumes (pacedump km/wk): 5K 52→98 peak@W10; 10K 63→81. Gate
anchors extended (sub-19/sub-40); recommendedPlanWeeks already generic.
Suite: +6 R22 band/crescendo/arrival checks (MUST pass SPEED_PACE — without
it Z4/Z5 render defaults and paces read inverted; that artifact produced a
false P0 in both sonnet eyeballs).

Adversarial eyeball (2 sonnet agents): all P0/P1 dissolved on verification —
anchor artifact, the dump-vs-pacedump render trap (deload-LR clamp #171 and
km-caps apply at RENDER; pre-render dumps show uncapped minutes), or traits
shared with certified tiers (threshold=5K×1.03 by R8 design, ladder flat
jogs, cross-phase session reuse, easy-pace improvement drift).

Surviving polish (R23 candidates, all P2-class):
- 5K 12w W6 (speed-end): hills+threshold+ML week carries zero Z5 touch
  (strides evicted by fill); neighbors carry 20+ z5-min. Variety-defensible.
- 5K 16w PEAK z5 dose (~6-12min/wk) never re-reaches SPEED's 20min sessions;
  16w is the damped variant by tier design, but peak-phase 5K-pace volume
  could hold rather than halve.
- 10w floor variant has no mid-plan deload (no phase ≥4w) and out-peaks 12w
  — same class as the blessed Int-5K long-vs-short known-fail; gate steers
  to 12w+.

## R23 — new distances certification: 15K / 10mi / 30K / 50K (2026-07-09)

**Status: CERTIFIED** at rec lengths (12w mid / 16w 30K / 18w 50K).

Quantitative: km/wk at per-tier class anchors, all 10 plans in band with
back-half peaks/plateaus (Beg mid ~30km → Adv 50K 83km peak @W13); 20
permanent band+crescendo checks. 50K peak LRs render 28-30km (window 28-34),
MP rehearsals escalate 60→70→90min as the peak block's only quality anchor.

Sonnet eyeball ×2 → fixed:
- fastFinish "@ MP" templates leaked into the mid band via subtype-wide
  eligibility → 15K/10mi removed from fastFinish (progressiveLong covers).
- Int 15K/10mi W1→W2 LR inversion (-29%, monotonic fallback firing) →
  base rungs raised to 85; residual -12% W2 dip accepted.
- Adv/Int 30K+50K peak tune-up TT stacked with MP rehearsals (worst: TT
  l=14545 beside a 170min rehearsal) → #156 extended: NEW marathon-class
  skips the peak TT (mid-plan recalib TTs stay); first guard attempt
  (dropping the rehearsal) backfired into a 49911-load week — dropping the
  TT is the correct direction.

Accepted as tier conventions (not defects): 50K W12-14 3:1 escalating
rehearsal block; W15 deload's 40min MP touch (Pfitz final race-pace touch
10-14 days out); Int flat-top volume curves; Int 30K first deload at W6.

R24 candidates (P2): back-to-back long days for 50K (real ultra-prep gap,
engine doesn't model B2B); Adv mid-band deload weeks keep 2 quality
sessions; one Int session shape recycled across 4 phases (feeds the
variety audit); LR==ML render tie (km-cap coincidence, one week).

## R24 — disposition of the R23 P2s (2026-07-09)

- **50K back-to-back long days: BUILT.** Ultra-class plans place the week's
  medium-long on the day before the long run (tired-legs stacking) via a
  third placement pass; never displaces a hard day back next to the LR.
  Kit test locks adjacency for 50K and spread placement for 42K.
- **Adv deload weeks keep 2 quality: DISSOLVED** — dump census shows
  quality=2 deloads are the certified Adv/Cmp signature everywhere
  (Adv 21K/42K, Cmp 21K/42K, Acc Adv). New plans match their siblings.
  (Also honors the reverted total-load-anchor decision.)
- **LR==ML render tie: DISSOLVED** — same km-cap coincidence occurs in
  certified Cmp weeks (110/110). Tier-wide render trait, one-week cosmetic.
- **Session-shape recycling: DEFERRED to the #8 variety audit** — same
  class as the pending Adv-10K repeat (#173); fixing it means touching
  cross-plan variety scoring, which is that audit's job, not R23's.
