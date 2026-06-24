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
