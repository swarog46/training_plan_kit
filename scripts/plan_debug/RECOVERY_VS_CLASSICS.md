# Recovery / Cutback-Week Design vs. the Classics

Read-only audit. Validates RunPlan's recovery-week design (`PlanGeneratorV3.calculateWeeklyTargetsV3`
+ the per-type generators) against Pfitzinger, Daniels, Higdon, and modern coaching
consensus. **No engine code was modified.** Numbers below are from real generated plans
(`plan_debug dump`, production 804-workout catalog, `ADAPTIVE=1`).

Generated 2026-06-16. Source-tagging convention:
- **[BOOK]** = stated in/derived from the named book or the author's published plan.
- **[COACH]** = modern coaching consensus (multiple coach sources agree).
- **[INFER]** = my inference from the data/theory; lower confidence, flagged.
- **[THIN]** = source was weak; treat as directional only.

---

## 0. Headline verdict

RunPlan's recovery model is **directionally correct but mechanically unreliable in the
fitter tiers.** The *idea* — periodic cutback weeks, ~15-25% off, long run trimmed ~20%,
quality lightened not removed — is squarely inside the Pfitz/Higdon/coach mainstream.
But the **implementation does not deliver a real cutback where it matters most**: in the
Intermediate/Advanced/Competitive SPEED and PEAK phases the designated "every-3rd-week"
recovery week frequently lands FLAT or even ABOVE its predecessor, because the
quality-week-alternation sawtooth and the phase ramp dominate the modest 0.85/0.75
multiplier. The beginner tier (which has the explicit below-prior-week anchor) works; the
fitter tiers — which were given only a trajectory-relative cut — largely do not.

Two design judgments are **right and should NOT be "corrected"**: (a) cutting the long run
on recovery weeks (Higdon and the coach consensus both cut it; only Pfitzinger sometimes
holds it), and (b) lightening rather than deleting quality (Pfitz/Higdon lighten; only
Daniels fully removes it, and that's a different philosophy). The single most important
real bug is the **unreliable dip in the fitter tiers**, not the magnitudes.

---

## 1. What RunPlan actually does (confirmed in code)

| Mechanism | Where | Behaviour |
|---|---|---|
| Mid-phase recovery cadence | `PlanGeneratorV3.swift` ~305-310 | `weekInPhase % 3 == 2`, phase ≥4w, `weekInPhase ≥2`, not race/taper/phase-end. I.e. recovery at the **3rd, 6th, 9th… week of each phase**. |
| Recovery load/duration cut | ~320-338 | `× recoveryWeekLoadMultiplier` = **0.85** (beginner/int/adv), **0.75** competitive. Applied to weekly load + duration target. |
| Below-prior-week anchor | ~332-335 | Only when `profile.cutbackDipsBelowPriorWeek == true` → **Beginner only**. Anchors the cut to `weekInPhase-1`'s progression so the week lands below the prior one. Fitter tiers keep the *trajectory-relative* cut (this is the bug surface — see §3.1). |
| Phase-end deload | ~315-319 | `phaseProgression ≥ 0.8` → cut ~15-25% (avg of `phaseFinishDeloadPercent`, capped 25%). |
| Long-run recovery cut | `recoveryLongRunTarget`, `recoveryLongRunCutback = 0.80` | On deload BUILD weeks (base/speed/peak), cut the LR target **20%, floored at 60 min**. |
| Long-run monotonic relax | `applyLongRunMonotonic`, `isDeloading` branch | On deload BUILD weeks, skip the non-decreasing rule and floor the pool at the 0.80 cutback target so the LR can dip without collapsing to the 60-min catalog floor. |
| Deload interval-floor relax | each generator ~125-135 | On deload weeks (non-race) the min-interval floor drops to **22 min** so the selector can pick a *lighter* quality session instead of being forced onto the heaviest one. |
| Deload selector bias | `selectWorkoutByTargetV3` ~429-435 | On deload, prefer same/longer rest (lighter), penalize shorter rest. |

**Key confirmed fact about quality on recovery weeks:** the recovery logic **never drops a
quality session** — it only makes the selector pick an *easier* one. In `Int 42K (long)`
the hard-session count per week is driven by the quality-week alternation (1 vs 2 hard
days), NOT the recovery flag: the designated recovery weeks (e.g. W13 = peak 3/9 =
weekInPhase 2) still carry **H=2**. So RunPlan = "lighten, retain," never "remove."

---

## 2. The classics (researched)

### 2.1 Pfitzinger, *Advanced Marathoning* — **[BOOK]/[THIN]**
- Pfitz uses **"down weeks"** with reduced volume every few weeks, but his plans are
  famous for **"remarkably little rest and recovery in all but the lowest-mileage plan"**
  (fellrnr review, corroborated by multiple plan write-ups). The recovery is *modest* and
  the build is nearly continuous.
- The defining Pfitz trait vs Higdon: Pfitz tends to **keep the long run and the
  medium-long runs high through a down week and shave the easy/recovery mileage and the
  total instead**, because the long & medium-long runs ARE the stimulus he's protecting.
  Quality (LT tempo, VO₂) is generally **retained** on down weeks, sometimes shortened.
  *(I could not extract exact per-week mileage from a clean public Pfitz table — the book's
  schedules aren't reproduced in full online — so the "holds the long run" claim is
  [BOOK]-level from the plan's known shape + reviews, not a quoted week. Flagged [THIN].)*
- **Net:** Pfitz is the one classic that argues AGAINST always cutting the long run on a
  down week. He cuts the *total* (and the filler easy miles) more than the long run.

### 2.2 Daniels, *Running Formula* — **[BOOK]**
- Periodization in ~3-4 week mesocycles. The signature move: **"the fourth week with no
  quality training"** — an easy/recovery week where **quality is REMOVED entirely**, not
  just lightened, and volume is held easy.
- Cadence guidance commonly summarized as **easy week every 3-4 weeks with reduced volume**;
  hard weeks keep their quality, the recovery week drops it.
- **Net:** Daniels is MORE aggressive on quality than RunPlan (full removal on the down
  week) but his down weeks are about *intensity withdrawal*, not necessarily a big
  long-run cut. RunPlan diverges by keeping (lightened) quality every week.

### 2.3 Higdon (Novice 1/2, Intermediate 1/2) — **[BOOK]** (his plans are public)
- Explicit rule, in his own words: **"every third week is a 'stepback' week, where we
  reduce mileage to allow you to gather strength for the next push upward."** → a clean
  **3:1** cadence, identical in spirit to RunPlan's `%3==2`.
- Verified long-run step-backs from the published Intermediate-1 & Novice-2 tables:
  - 9→6 mi (**−33%**), 12→9 (**−25%**), 18→13 (**−28%**), 20→12 (**−40%**), 20→12 (**−40%**).
  - **Average stepback ≈ −33%, range −25% to −40%.**
- The **long run is the thing that drops**; weekday mileage is nearly flat (3-4-5-ish mi),
  so the long-run cut *is* the weekly-volume cut. (One fetch claimed weekday also drops a
  bit; the schedules show weekday roughly flat — the long run dominates the delta. Source
  tension noted; the dominant driver is the long run.)
- **Net:** Higdon STRONGLY supports cutting the long run on every recovery week, but
  **deeper than RunPlan's 20%** — his are 25-40%.

### 2.4 Modern coaching consensus — **[COACH]**
- **Cadence:** "cutback every fourth week works best" (3 hard + 1 down), but 3-week cycles
  (2 up + 1 down) also endorsed. RunPlan's per-phase 3:1 is squarely in range.
- **Magnitude:** reduce weekly volume **~15-30%** (most say 15-25%; "20-30% is easiest to
  follow"). RunPlan's **0.85 (−15%) is at the LOW end**; 0.75 (−25%) is mid-range.
- **Long run:** consensus is to **reduce** it, "by at least as much as the weekly volume,"
  and some coaches go aggressive (**−40 to −50%**). RunPlan's −20% is in-band but on the
  gentle side.
- **Quality:** "reduce volume without increasing paces" — keep the effort, shorten the rep
  total. Some coaches (esp. injury-prone / base phase) **skip a quality session**. RunPlan's
  "lighten, retain" matches the mainstream; never-skip is slightly less conservative than
  the injury-cautious branch.
- **Measurement baseline — the crux:** sources split. Several say "reduce from the
  **highest of the previous few weeks**," others "from the prior week." The strongest
  framing: a cutback should produce a clearly *lower-stress* week than the recent peak —
  not necessarily strictly below the immediately preceding week if that week was itself a
  partial down week. **[COACH]** consensus does NOT demand a strict below-immediate-
  predecessor dip on *total load*; it demands a genuine reduction in stress vs the build.

---

## 3. Validation: each RunPlan element classified

### 3.1 Every-3rd-week cadence + the below-predecessor INTENT — **DIVERGES (real bug in fitter tiers)**
- The **cadence itself is ALIGNED** (Higdon 3:1, coach 3:1/4:1). Good.
- The **intent** ("every recovery week dips below its predecessor on total load") is only
  enforced for **Beginner** (`cutbackDipsBelowPriorWeek=true`). For **Int/Adv/Cmp it is
  NOT achieved.** Evidence from real plans:
  - `Int 21K (long)` SPEED loads: W5 28199 → **W6 21360 → W7 21933(recovery, weekInPhase2)**.
    W7 is ABOVE W6. The designated recovery week did not dip; the real low is W8 (16303),
    which is NOT a recovery week — it's a quality-alternation trough.
  - `Int 21K (long)` PEAK: recovery week W13 (weekInPhase2) = 27166 ≈ W12 27484 (flat). The
    deep low is W14 (15544), again not the designated recovery week.
  - `Int 42K (long)` PEAK recovery weeks (weekInPhase 2,5,8 → W13/W16/W19): only **1 of 3**
    (W16) actually dipped below its predecessor. W13 and W19 rose.
  - `Cmp 42K (long)` PEAK (8w, 0.75 mult): recovery weeks W14/W17 are BOTH **higher** than
    their predecessors (45581>41663; 48465>46692). **The competitive deload is invisible** —
    the exact failure the 0.75 comment claims it was raised to fix; it isn't fixed.
- **Why:** in fitter tiers the week-to-week load is dominated by (a) the phase ramp
  (`progressionFactor`, amplifier 5.0) and (b) the 1-vs-2-hard-day quality alternation.
  A trajectory-relative 0.85/0.75 nudge is smaller than those swings, so the recovery week
  lands wherever the sawtooth puts it.
- **[COACH] caveat:** a *strict* below-immediate-predecessor rule is arguably too rigid
  (see §3.6). But the current state isn't "deliberately not-strict" — it's "no reliable
  reduction vs the surrounding build at all," which IS wrong by every classic.

### 3.2 Long-run −20% on every recovery BUILD week (floored 60) — **MOSTLY ALIGNED; magnitude light**
- Cutting the LR on a recovery week is **correct** for Higdon and coach consensus
  (Pfitz is the dissenter — see §3.5). Keep it.
- **Magnitude is on the gentle side.** Higdon's real stepbacks are **−25 to −40%** (avg ~−33);
  coaches say "≥ weekly cut," often −30 to −50. RunPlan's flat **−20%** is below Higdon's
  floor. **[INFER]** A −25% to −30% LR cut would match Higdon/coach better; −20% is
  defensible-but-soft.
- **The 60-min floor is sensible** (don't let a mid-marathon LR collapse to 9 km) and
  matches the "don't over-cut" instinct. No change needed there.

### 3.3 `recoveryWeekLoadMultiplier` 0.85 / 0.75 — **0.85 is too shallow; 0.75 right but swamped**
- **0.85 (−15%)** is the bottom of the coach range (15-30%) and, combined with §3.1, is too
  weak to surface a dip against the ramp in Int/Adv. **[COACH]** mid-range is ~−20-25%.
- **0.75 (−25%)** competitive is a *good number*, but §3.1 shows it's **swamped** by the
  competitive PEAK ramp and never produces a dip. The multiplier value isn't the problem
  there — the *anchoring* is (it's trajectory-relative, not below-peak).

### 3.4 Lightening (not removing) quality on down weeks — **ALIGNED (with one classic dissent)**
- Matches **Pfitz** (retain, maybe shorten) and **coach** mainstream ("reduce volume, keep
  pace"). The floor-relax → easier-session mechanism is a clean way to do it. **Keep.**
- **Daniels DIVERGES** (he removes quality entirely on the 4th week). RunPlan's never-remove
  is a deliberate, defensible philosophy choice — *not* a bug. Only worth revisiting if you
  want an explicit Daniels-style "no-quality" recovery week as an option (see §4, low-pri).
- Minor: the injury-cautious coach branch *skips* a quality session on base-phase down
  weeks. RunPlan never does. Fine for a general engine; note for the beginner base phase.

### 3.5 Cutting the long run on EVERY recovery week — **ALIGNED for Higdon/coach; DIVERGES from Pfitz**
- This is STEP 3's explicit question. Answer: **mostly correct.** Higdon and the coach
  consensus cut the long run on the down week — and for Higdon it's the *primary* lever.
- **Pfitzinger is the exception:** he tends to **hold the long & medium-long runs and shave
  total/easy mileage** on a down week. **[THIN]** on exact weeks, but this is his well-known
  shape. So a "hold-LR, cut-midweek" variant is the *Pfitz-authentic* alternative — relevant
  only if you want a Pfitz-flavored marathon plan. For the current general/Higdon-flavored
  plans, cutting the LR is right.
- **Verdict:** do NOT stop cutting the long run by default. Optionally offer a Pfitz-style
  hold-LR mode later (low priority).

### 3.6 The implicit goal "every recovery week must dip below predecessor on TOTAL LOAD" —
**TOO RIGID as a literal total-load rule; the *right* target is stress, not load sum**
- STEP 3's physiology question. **[INFER]/[COACH]** A week with a shorter long run + lighter
  quality but an extra easy aerobic day genuinely *is* lower-stress even if total *load*
  (a single scalar mixing intensity and volume) is flat or higher. Aerobic easy volume is
  low-stress; the long run and the hard sessions carry the recovery-relevant stress.
- So **measuring the cutback on a single total-load scalar is the wrong invariant.** The
  physiologically sound target is: **long-run duration ↓ AND quality intensity/volume ↓**
  vs the surrounding peak — total load may stay flat if easy volume backfills, and that's
  *fine*. The classics implicitly do this (Higdon cuts the long run; total drops because
  weekday is flat — they don't police a load scalar).
- **Implication for RunPlan:** the fix in §3.1 should NOT be "force total load below the
  prior week" (that would over-constrain and could force dropping useful easy aerobic
  volume). It should be **"guarantee the long run and the hard-session stress dip on the
  recovery week vs the recent peak"** — which the LR-cut (§3.2) + a quality-lightening that
  actually bites already aim at; they're just too weak to show against the ramp.

### 3.7 Phase-end deload (`phaseProgression ≥ 0.8`, ~15-25%) — **ALIGNED**
- A deload into a phase transition is standard. Magnitude (15-25%, capped 25%) is in the
  coach band. Taper (§ separate) lands race week ~50-55% of peak per the code comment,
  matching Pfitz/Daniels taper targets. No change.

---

## 4. Ranked corrections (what to change, classic support, effort, risk)

Ordered by impact. "Effort" is rough engine-change size; all assume the existing test
harness (`plan_debug dump` byte-diff + `test_plans.py`) gates the change.

### #1 — Make the fitter-tier recovery week actually reduce stress vs the recent peak. **[HIGH IMPACT]**
- **Problem (confirmed):** Int/Adv/Cmp recovery weeks routinely land flat/above predecessor
  (§3.1); the competitive PEAK deload is invisible.
- **What to change:** anchor the recovery cut to the **recent peak**, not the still-rising
  trajectory, for the fitter tiers too — i.e. extend the spirit of `cutbackDipsBelowPriorWeek`
  to Int/Adv/Cmp, but **target the long run + quality stress** (not a raw total-load floor,
  per §3.6). Concretely: on a recovery week, set the LR target and the quality target
  relative to the *max of the last ~2-3 weeks* × (1 − cut), so the dip is measured against
  the peak it's recovering from. Keep easy aerobic volume free to backfill.
- **Supports:** Higdon 3:1 stepback (the dip is the whole point); **[COACH]** "reduce from
  the highest of the previous few weeks."
- **Effort:** medium (touches `calculateWeeklyTargetsV3` anchoring + needs the prior-weeks
  peak threaded in; the LR side already has `recoveryLongRunTarget`).
- **Risk:** medium — changes load curves for 3 tiers; must re-baseline the dump diffs and
  re-check it doesn't gut a phase. Mitigate by gating on quality+LR stress, not total load,
  so easy volume isn't sacrificed.

### #2 — Deepen the recovery multiplier / LR cut to the classic band. **[MED IMPACT]**
- **What to change:** raise the standard `recoveryWeekLoadMultiplier` from **0.85 → ~0.80**
  (−20%, mid-coach-range) and the LR cut `recoveryLongRunCutback` from **0.80 → ~0.72-0.75**
  (−25-28%, Higdon-aligned), keeping the 60-min floor. Leave competitive 0.75.
- **Supports:** Higdon stepbacks (−25 to −40%, avg −33); **[COACH]** 15-30% volume, LR ≥
  weekly cut.
- **Effort:** low (two constants), but **only meaningful AFTER #1** — deepening a cut that
  doesn't currently bite just makes a deeper invisible cut. Do #1 first.
- **Risk:** low-medium — a −25-30% LR cut on a marathon peak LR is still well above the
  60-min floor; mainly re-baseline diffs.

### #3 — Keep "lighten, don't remove" as default; (optional) add a Daniels-style no-quality recovery week. **[LOW IMPACT / OPTIONAL]**
- **What:** default behaviour is already aligned (Pfitz/coach) — **no change needed.**
  Optionally, for a future Daniels-flavored or beginner-base variant, allow a recovery week
  that **drops one quality session** (injury-cautious coach branch) or **removes quality
  entirely** (Daniels 4th-week). Profile-gated, off by default.
- **Supports:** Daniels (full removal); **[COACH]** injury-prone branch (skip one).
- **Effort:** low-medium (a profile flag + selector path that omits a hard day on the flagged
  week). **Risk:** low (opt-in, off by default). **Do not** flip the default.

### #4 — (Optional, future) Pfitz-style "hold the long run, cut midweek" recovery mode. **[LOW / NICHE]**
- **What:** for a Pfitz-flavored marathon plan, a recovery variant that **holds the LR &
  medium-long near peak and shaves easy/total** instead of cutting the LR.
- **Supports:** Pfitzinger **[BOOK/THIN]**.
- **Effort:** medium (inverts the LR-cut logic for that profile). **Risk:** low (opt-in).
  Only if/when a Pfitz-style plan is on the roadmap; current Higdon-flavored default is fine.

---

## 5. Confidence ledger

- **HIGH confidence (verified in real generated data):** fitter-tier recovery weeks fail to
  dip (§3.1); competitive PEAK deload invisible; quality count not reduced by recovery logic;
  RunPlan magnitudes (0.85/0.75, −20% LR) and cadence (3:1 per phase) as described.
- **HIGH confidence (public plans):** Higdon 3:1 stepback, −25 to −40% long-run cuts;
  Daniels "4th week no quality"; coach consensus 15-30% volume / cut-the-LR / lighten-quality.
- **MED/[THIN]:** Pfitzinger "holds the long run, shaves total/easy" and "retains quality" on
  down weeks — derived from the plan's known shape + reviews, not a quoted week-by-week table
  (the book's schedules aren't cleanly reproduced online). Treat #4 as directional.
- **[INFER]:** the physiology argument that total-load-scalar is the wrong invariant and the
  cutback should target long-run + quality stress (§3.6). Well-grounded in training theory and
  consistent with how the classics actually behave, but it's my synthesis, not a book quote.

---

## 6. Sources

- Higdon, *Marathon: The Ultimate Training Guide* — public Intermediate-1 & Novice-2 plans
  (halhigdon.com): explicit "every third week is a stepback week"; verified −25 to −40% LR cuts.
- Daniels, *Running Formula* — "fourth week with no quality"; 3-4 week mesocycle, easy week
  every 3-4 weeks (fellrnr.com/wiki/Jack_Daniels + coach summaries).
- Pfitzinger & Douglas, *Advanced Marathoning* — "down weeks," "remarkably little rest in all
  but the lowest-mileage plan," long/medium-long emphasis (fellrnr.com/wiki/Pfitzinger +
  runningwithrock.com plan reviews). [THIN] on exact weekly tables.
- Modern coaching consensus on cutback weeks: HillRunner (cutback-weeks), Laura Norris Running,
  Runners Connect, RunToTheFinish — cadence 3:1/4:1, volume −15-30%, cut the long run, lighten
  (or occasionally skip) quality, "reduce from the highest of recent weeks."
- RunPlan engine: `Sources/TrainingPlanKit/Engine/PlanGeneratorV3.swift`
  (`calculateWeeklyTargetsV3`, `recoveryLongRunTarget`, `applyLongRunMonotonic`,
  `selectWorkoutByTargetV3`), `PlanProfile.swift`, `PlanConfiguration+{Beginner,Competitive,…}.swift`,
  and the four per-type generators (interval-floor relax). Real plans via
  `scripts/plan_debug/plan_debug dump` (804-workout production catalog, ADAPTIVE=1).
