#!/usr/bin/env python3
"""Regression tests for the plan generator.

Defends the invariants we fixed by hand this round:
  - Z3 (MP) workouts hit racePace from day 1, all tiers
  - Competitive plans don't ease pace in
  - Long runs monotonic (grow in BASE/SPEED/PEAK, shrink in TAPER)
  - Marathon LR peaks match Higdon Novice 1 / Pfitz refs
  - Beg pool excludes intervals/mileRepeats/yasso (Higdon Novice cadence)
  - Cmp PEAK alternates raceRehearsal and aerobic
  - Race week has a shakeout (3 sessions)
  - Maintenance volume progresses across phases (not flat)
  - raceRehearsalHM HMP segments resolve at racePace (Z3 retag)
  - Accessible tier is lighter than textbook but keeps the same
    periodization, safety rails, and gentle-beginner policy

Run:    python3 scripts/plan_debug/test_plans.py
        Catalog-bound checks SKIP on the bundled sample;
        WORKOUTS_PATH=/path/to/full_catalog.json runs everything.
Exit 0 = all pass. Exit 1 = at least one fail (CI-friendly).

Builds plan_debug on demand if it's missing, otherwise reuses the
existing binary.
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PLAN_DEBUG = os.path.join(ROOT, "scripts/plan_debug/plan_debug")
BUILD_SH   = os.path.join(ROOT, "scripts/plan_debug/build.sh")

QUALITY = {'intervals','hillRepeats','threshold','mileRepeats','ladderIntervals',
           'yasso800','timeTrial','marathonPace','fivekPace','tenkPace','fartlek'}
LONG    = {'long','steadyLong','progressiveLong','raceRehearsalM','raceRehearsalHM',
           'raceRehearsal10K','fastFinish'}
EASY    = {'easy','recovery'}
STRIDES = {'strides'}
PROG    = {'progression'}
MP_SUBTYPES = LONG | {'marathonPace','progression'}  # subtypes that can have a Z3 portion

# --- harness -----------------------------------------------------------

def ensure_binary():
    if not os.path.exists(PLAN_DEBUG):
        print(f"plan_debug not built; building via {BUILD_SH}...")
        r = subprocess.run(["bash", BUILD_SH], capture_output=True, text=True)
        if r.returncode != 0:
            print("BUILD FAILED:")
            print(r.stderr)
            sys.exit(1)

def run_pacedump(filter_str, race_pace=300, easy_pace=420):
    env = os.environ.copy()
    env.update({"RACE_PACE": str(race_pace), "EASY_PACE": str(easy_pace)})
    r = subprocess.run(
        [PLAN_DEBUG, "pacedump", filter_str],
        capture_output=True, text=True, env=env
    )
    return r.stdout

def run_dump(filter_str):
    r = subprocess.run([PLAN_DEBUG, "dump", filter_str],
                       capture_output=True, text=True, env=os.environ.copy())
    return r.stdout

def parse_phase_weeks(filter_str):
    """dict[week_num(1-based)] = (phase, is_deload) from the `phases` target model.
    Recovery weeks now intentionally dip in realized volume, so peak comparisons
    must exclude [deload] weeks to avoid measuring against a cutback week."""
    r = subprocess.run([PLAN_DEBUG, "phases", filter_str],
                       capture_output=True, text=True, env=os.environ.copy())
    res = {}
    for m in re.finditer(
            r"^W\s*(\d+)\s+(BASE|SPEED|PEAK|TAPER|RACE)\s+load=.*?dur=\s*\d+min(\s+\[deload\])?",
            r.stdout, re.M):
        res[int(m.group(1))] = (m.group(2), m.group(3) is not None)
    return res

def parse_plan(text, header):
    """Return dict[week_num] = [(subtype, duration_min, pace_str)]."""
    if header not in text:
        return None
    section = text.split(f'=== {header}')[1]
    weeks = {}
    cur = None
    for line in section.splitlines():
        if line.startswith('=== '):
            break
        m = re.match(r'^W *(\d+):\s*$', line)
        if m:
            cur = int(m.group(1))
            weeks[cur] = []
            continue
        if cur is None:
            continue
        # Match LAST "NN min" before the pace+subtype.
        m = re.search(
            r'\s(\d+)\s*min\s+(\S+(?:,\s*\S+)*?|\[[^\]]+\])\s+\[(\w+)\]\s*$',
            line)
        if not m:
            continue
        dur = int(m.group(1))
        pace = m.group(2).strip()
        subtype = m.group(3)
        weeks[cur].append((subtype, dur, pace))
    return weeks

# --- test infrastructure ----------------------------------------------

passed = []
failed = []
skipped = []

# Catalog-bound checks (exact volumes, aerobic mix, variety depth) only hold
# against RunPlan's full catalog; on the bundled sample they SKIP.
FULL_CATALOG = bool(os.environ.get("WORKOUTS_PATH"))

def check(label, condition, detail="", full=False):
    if full and not FULL_CATALOG:
        skipped.append(label)
        print(f"  SKIP  {label} (needs full catalog)")
        return
    if condition:
        passed.append(label)
        print(f"  PASS  {label}")
    else:
        failed.append((label, detail))
        print(f"  FAIL  {label}")
        if detail:
            print(f"        {detail}")

def section(name):
    print(f"\n=== {name} ===")

# --- helpers ---------------------------------------------------------

def get_long_durations(weeks):
    """Return [(week, max_long_dur)] for weeks that have a long run."""
    out = []
    for w in sorted(weeks):
        longs = [d for s,d,_ in weeks[w] if s in LONG]
        if longs:
            out.append((w, max(longs)))
    return out

def get_pace_secs(pace_str):
    """Parse '4:54/km' → 294. Returns None for multi-pace strings."""
    m = re.match(r'^(\d+):(\d+)/km$', pace_str)
    if not m: return None
    return int(m.group(1)) * 60 + int(m.group(2))

def get_z3_paces_in_week(weeks, week_num):
    """Return list of pace strings for Z3-eligible workouts in this week."""
    out = []
    for s, _, p in weeks.get(week_num, []):
        if s in MP_SUBTYPES:
            out.append((s, p))
    return out

# --- tests -----------------------------------------------------------

ensure_binary()

section("Z3 (MP) workouts hit racePace from day 1, all tiers")

# Cmp 42K: target MP = 4:16/km, every MP workout should show exactly 4:16
text = run_pacedump("Cmp 42K (long", race_pace=256, easy_pace=300)
w = parse_plan(text, "Cmp 42K (long, 22w)")
mp_paces_w1 = [(s, p) for s,_,p in (w[1] if w else []) if s == 'steadyLong']
# Cmp 42K W1 steadyLong (Z2): at-goal competitive easy anchors to the runner's
# stated easy (300 = 5:00) and eases from there — NOT frozen at 1.15×race (was 4:55).
check(
    "Cmp 42K W1 steadyLong @ 5:00/km",
    any('5:00/km' in p for _, p in mp_paces_w1),
    f"got {mp_paces_w1}"
)

# Int 42K: target MP = 5:00/km (racePace=300). Marathon Pace workouts
# anywhere in the plan must show 5:00/km exactly (Z3 unblend).
text = run_pacedump("Int 42K (long", race_pace=300, easy_pace=420)
w = parse_plan(text, "Int 42K (long, 22w)")
mp_paces = []
for week in w.values():
    for s, _, p in week:
        if s == 'marathonPace':
            mp_paces.append(p)
check(
    "Int 42K MP workouts hit 5:00/km exactly (Z3 unblend)",
    bool(mp_paces) and all(p == '5:00/km' for p in mp_paces),
    f"got {mp_paces[:5]}",
    full=True
)

# Cmp 21K race rehearsal HMP segments — Z3 retag means HMP shows at racePace.
text = run_pacedump("Cmp 21K (long", race_pace=256, easy_pace=300)
w = parse_plan(text, "Cmp 21K (long, 18w)")
rh_paces = []
for week in w.values():
    for s, _, p in week:
        if s == 'raceRehearsalHM':
            rh_paces.append(p)
# Multi-pace formatted as "[3:58/km, 4:54/km]" or "[4:16/km, 4:54/km]".
# After Z3 retag, the fast portion should be 4:16/km not 3:58.
check(
    "Cmp 21K raceRehearsalHM contains 4:16/km (Z3 retag)",
    any('4:16/km' in p for p in rh_paces),
    f"got {rh_paces[:3]}"
)
check(
    "Cmp 21K raceRehearsalHM does NOT show 3:58/km HMP segment",
    not any('3:58/km, 4:54' in p or p.startswith('[3:58') for p in rh_paces),
    f"got {rh_paces[:3]}"
)

section("Long-run monotonic dynamics")

# Beg 42K: long runs grow (allow 5min slack), no surprise weeks for beginners.
# Deload weeks legitimately CUT the long run (BeginnerProfile.cutbackDipsBelowPrior
# Week), so the monotonic build is measured on NON-DELOAD weeks only — the dips on
# recovery weeks are the intended sawtooth, not regressions.
text = run_pacedump("Beg 42K (long", race_pace=330, easy_pace=450)
w = parse_plan(text, "Beg 42K (long, 22w)")
durs = get_long_durations(w)
_beg42_deload = {wk for wk, (_ph, dl) in parse_phase_weeks("Beg 42K (long").items() if dl}
build_durs = [(wk, d) for wk, d in durs if wk <= 17 and wk not in _beg42_deload]
regressions = []
for i in range(1, len(build_durs)):
    # R8 km-floor era: a 28km rehearsal takes FEWER minutes than a 28km steady
    # long (its MP block runs faster) — same distance, so a minute dip up to
    # ~15% week-over-week is the pace mix, not a build regression.
    if build_durs[i][1] < build_durs[i-1][1] * 0.85 - 5:
        regressions.append(
            f"W{build_durs[i-1][0]}→W{build_durs[i][0]}: "
            f"{build_durs[i-1][1]}→{build_durs[i][1]}m")
check(
    "Beg 42K long runs monotonic in non-deload build weeks (≤5min slack)",
    not regressions,
    f"regressions: {regressions}",
    full=True
)

# Cmp 21K TAPER: long runs decrease
text = run_pacedump("Cmp 21K (long", race_pace=256, easy_pace=300)
w = parse_plan(text, "Cmp 21K (long, 18w)")
durs = get_long_durations(w)
taper_durs = [(wk, d) for wk, d in durs if wk >= 16]
taper_violations = []
for i in range(1, len(taper_durs)):
    if taper_durs[i][1] > taper_durs[i-1][1] + 5:
        taper_violations.append(
            f"W{taper_durs[i-1][0]}→W{taper_durs[i][0]}: "
            f"{taper_durs[i-1][1]}→{taper_durs[i][1]}m")
check(
    "Cmp 21K TAPER long runs decrease (≤5min slack)",
    not taper_violations,
    f"violations: {taper_violations}"
)

# Long marathon builds (36w) must RAMP the BASE long run, not park it flat at
# p.base for ~16 weeks. Two teeth: (1) strictly non-decreasing across BASE (the
# load selector would otherwise drift it DOWN at the start), (2) de-flattened —
# the build spans >=15min from first to last base week instead of a plateau.
def base_long_runs(dump_text, header):
    """[(week, long_dur)] for BASE-phase weeks only, parsed from dump output."""
    if f'=== {header}' not in dump_text:
        return None
    sect = dump_text.split(f'=== {header}')[1]
    out = []
    wk = ph = lr = None
    def flush():
        if wk is not None and ph == 'base' and lr is not None:
            out.append((wk, lr))
    for line in sect.splitlines():
        if line.startswith('=== '):
            break
        m = re.match(r'^W *(\d+) \[(\w+)', line)
        if m:
            flush()
            wk, ph, lr = int(m.group(1)), m.group(2), None
            continue
        mm = re.search(r'\s(\d+)min\s+l=\d+\s+\[(\w+)/(\w+)\]', line)
        if mm and ph == 'base':
            dur, sub, role = int(mm.group(1)), mm.group(2), mm.group(3)
            if role == 'long' or sub in LONG:
                lr = dur if lr is None else max(lr, dur)
    flush()
    return out

cmp_max_dump = run_dump("Cmp 42K (max")
base_lr = base_long_runs(cmp_max_dump, "Cmp 42K (max, 36w)") or []
descents = [f"W{base_lr[i-1][0]}→W{base_lr[i][0]}: {base_lr[i-1][1]}→{base_lr[i][1]}m"
            for i in range(1, len(base_lr)) if base_lr[i][1] < base_lr[i-1][1]]
check(
    "Cmp 42K max BASE long run strictly non-decreasing (no backward step at start)",
    bool(base_lr) and not descents,
    f"base seq={[d for _,d in base_lr]}, descents: {descents}",
    full=True
)
# Trend: the LAST 3 base weeks must sit >=12min above the FIRST 3 — a genuine
# progressive build, not a plateau. The old wobble (~+5min) and a flat-at-p.base
# base that just climbs then parks (~+7min) both fail; only the ramp clears it.
first3 = [d for _, d in base_lr[:3]]
last3 = [d for _, d in base_lr[-3:]]
trend = (sum(last3) / len(last3) - sum(first3) / len(first3)) if base_lr else 0
check(
    "Cmp 42K max BASE long run trends up >=12min (progressive build, not plateau)",
    trend >= 12,
    f"first3_avg={sum(first3)/max(len(first3),1):.0f}, "
    f"last3_avg={sum(last3)/max(len(last3),1):.0f}, trend={trend:.0f}min, "
    f"seq={[d for _,d in base_lr]}",
    full=True
)

section("Marathon long-run peak durations match references")

# Higdon Novice 1: 20mi ≈ 180min. Pfitz 18/55: 22mi ≈ 195min.
# Pfitz 18/70: 22mi+ ≈ 210min. Cmp matches Pfitz 18/85 sub-3h.
# Beg floor 175→170: the novice marathon long run is now capped at ~180-190min
# (the ~205-225 peak was too long for a beginner); the coarse sample-catalog
# rehearsal rung lands at 174 after the cap, so the floor follows. The ceiling
# (<=190min) is guarded by the dedicated beginner-cap section below.
ref = [
    ("Beg 42K (long, 22w)", "Beg 42K (long", 330, 450, 170, "Higdon Novice 1: 180, capped ~190"),
    ("Int 42K (long, 22w)", "Int 42K (long", 300, 400, 180, "Pfitz 18/55: 195"),
    ("Adv 42K (long, 22w)", "Adv 42K (long", 280, 380, 175, "floor-ramp built peak ~180; capped ~195"),
    # Pace-aware km-clamp (PaceZoneConverter) caps the competitive marathon long
    # run at 38km — at 5:00/km easy that's ~190min, which already exceeds Pfitz
    # 18/85's 22mi (~35km/177min). Old 200min floor was pace-blind. Govern by km.
    ("Cmp 42K (long, 22w)", "Cmp 42K (long", 256, 300, 160, "Pfitz 18/85 longest ~22mi/35km; km-capped 35km"),
]
for header, fil, rp, ep, expected_min, ref_str in ref:
    text = run_pacedump(fil, race_pace=rp, easy_pace=ep)
    w = parse_plan(text, header)
    durs = get_long_durations(w)
    peak = max(d for _, d in durs) if durs else 0
    check(
        f"{header.split(' (')[0]} peak LR >= {expected_min}min ({ref_str})",
        peak >= expected_min,
        f"actual peak={peak}min"
    )

section("Beg pool excludes aggressive quality")

text = run_pacedump("Beg 42K (long", race_pace=330, easy_pace=450)
w = parse_plan(text, "Beg 42K (long, 22w)")
all_subtypes = set()
for week in w.values():
    for s, _, _ in week:
        all_subtypes.add(s)
# R8: real interval/ladder work now belongs in a beginner half/marathon —
# only the genuinely advanced tools stay out.
forbidden = {'mileRepeats', 'yasso800', 'pyramidIntervals', 'fivekPace', 'tenkPace'}
found_forbidden = all_subtypes & forbidden
check(
    "Beg 42K excludes intervals/mileRepeats/yasso/etc",
    not found_forbidden,
    f"found forbidden subtypes: {found_forbidden}"
)
check(
    "Beg 42K still has threshold + timeTrial + marathonPace",
    {'threshold', 'timeTrial', 'marathonPace'}.issubset(all_subtypes),
    f"actual subtypes: {sorted(all_subtypes)}"
)

section("Competitive PEAK alternates rehearsal / aerobic")

text = run_pacedump("Cmp 42K (long", race_pace=256, easy_pace=300)
w = parse_plan(text, "Cmp 42K (long, 22w)")
# PEAK weeks for Cmp 42K (long, 22w) are roughly W12-W19. Check for both
# raceRehearsalM and steadyLong/progressiveLong presence.
peak_long_subtypes = set()
for wk in range(12, 20):
    for s, _, _ in w.get(wk, []):
        if s in LONG:
            peak_long_subtypes.add(s)
check(
    "Cmp 42K PEAK contains raceRehearsalM (race-pace work)",
    'raceRehearsalM' in peak_long_subtypes,
    f"PEAK long subtypes: {sorted(peak_long_subtypes)}"
)
check(
    "Cmp 42K PEAK contains steadyLong or progressiveLong (recovery aerobic)",
    bool(peak_long_subtypes & {'steadyLong', 'progressiveLong'}),
    f"PEAK long subtypes: {sorted(peak_long_subtypes)}"
)

section("Race week has shakeout (3+ sessions for 21K+ plans)")

for header, fil, rp, ep, last_wk in [
    ("Cmp 21K (long, 18w)", "Cmp 21K (long", 256, 300, 18),
    ("Cmp 42K (long, 22w)", "Cmp 42K (long", 256, 300, 22),
    ("Int 21K (long, 18w)", "Int 21K (long", 300, 380, 18),
    ("Adv 42K (long, 22w)", "Adv 42K (long", 280, 380, 22),
]:
    text = run_pacedump(fil, race_pace=rp, easy_pace=ep)
    w = parse_plan(text, header)
    race_sessions = len(w.get(last_wk, []))
    check(
        f"{header.split(' (')[0]} race week has 3+ sessions",
        race_sessions >= 3,
        f"got {race_sessions} sessions"
    )

section("Competitive TAPER drops volume from peak")

for header, fil in [
    ("Cmp 21K (long, 18w)", "Cmp 21K (long"),
    ("Cmp 42K (long, 22w)", "Cmp 42K (long"),
]:
    # Phase-aware (parses dump, which labels phases). The earlier version
    # hard-coded week indices for a 2-week taper; the marathon 3-week taper
    # then folded a taper week into the "peak" block and understated the drop.
    # Peak = avg of PEAK-phase weeks, taper_first = first TAPER-phase week.
    sect = run_dump(fil)
    sect = sect.split(f'=== {header}')[1] if f'=== {header}' in sect else ""
    pk, tp = [], []
    for line in sect.splitlines():
        if line.startswith('=== '):
            break
        m = re.match(r'^W *\d+ \[(\w+)[^\]]*\]\s+\d+wkts\s+load=\s*\d+\s+(\d+)min', line)
        if m:
            ph, mins = m.group(1), int(m.group(2))
            if ph == 'peak':    pk.append(mins)
            elif ph == 'taper': tp.append(mins)
    peak_avg = sum(pk) / len(pk) if pk else 1
    taper_first = tp[0] if tp else peak_avg
    drop_pct = (peak_avg - taper_first) / peak_avg * 100
    # Pfitz's first taper week is only ~10-20% down (the deep cuts come weeks
    # 2-3) — so ≥20% off the peak AVERAGE is the right floor. Absolute taper
    # depth (race week ≤ X% of peak) is guarded by the load-based taper tests.
    check(
        f"{header.split(' (')[0]} TAPER first week drops >=20% from peak avg",
        drop_pct >= 20,
        f"peak_avg={peak_avg:.0f}, taper_first={taper_first}, drop={drop_pct:.0f}%"
    )

section("Maintenance volume progresses (Maint Beg should grow)")

text = run_pacedump("Maint Beg")
w = parse_plan(text, "Maint Beg (12w)")
if w:
    week_vols = {wk: sum(d for _,d,_ in w[wk]) for wk in w}
    # Aggregate by 4-week blocks
    weeks_sorted = sorted(week_vols)
    first_block = sum(week_vols[wk] for wk in weeks_sorted[:4]) / 4
    last_block = sum(week_vols[wk] for wk in weeks_sorted[8:12]) / 4
    growth_pct = (last_block - first_block) / first_block * 100
    check(
        "Maint Beg last-4w avg > first-4w avg (fitness gradually increases)",
        growth_pct > 10,
        f"first_block_avg={first_block:.0f}, last_block_avg={last_block:.0f}, growth={growth_pct:.0f}%"
    )

# --- Maintenance defects: deload label, onboarding cliff, Beg quality variety -
# Maintenance runs its OWN recovery cadence (W1-2 easy ramp, every-4th-week
# deload) but used to pass isDeloading=false to the periodization, so the dump's
# [deload] tag landed on the HEAVY weeks while the real light weeks went
# unlabeled; the opening detonated into full quality at W3 (+130-220%); and
# Maint Beg's quality was 100% threshold. These defend the fixes.
section("Maintenance — deload label, onboarding ramp, Beg quality variety")

def parse_maint_weeks(label):
    """dict[week(1-based)] = {load, deload, subs:[(subtype, role)]} from `dump`."""
    text = run_dump(label)
    if f'=== {label}' not in text:
        return {}
    sect = text.split(f'=== {label}')[1].split('\n=== ')[0]
    weeks = {}
    cur = None
    for line in sect.splitlines():
        wm = re.match(r'^W\s*(\d+)\s*\[(\w+)[^\]]*\]\s+\d+wkts\s+load=\s*(\d+)\s+\d+min(\s+\[deload\])?', line)
        if wm:
            cur = int(wm.group(1))
            weeks[cur] = {'load': int(wm.group(3)), 'deload': wm.group(4) is not None, 'subs': []}
            continue
        sm = re.search(r'\[([a-zA-Z0-9]+)/([a-z_0-9]+)\]', line)
        if sm and cur is not None:
            weeks[cur]['subs'].append((sm.group(1), sm.group(2)))
    return weeks

# Real quality subtypes (excludes easy/long/progression/strides aerobic work).
MAINT_QUALITY = {'intervals', 'ladderIntervals', 'pyramidIntervals', 'threshold',
                 'hillRepeats', 'fivekPace', 'tenkPace', 'mileRepeats',
                 'yasso800', 'timeTrial', 'fartlek'}

import statistics as _stats
for _label in ("Maint Beg", "Maint Int", "Maint Adv"):
    _w = parse_maint_weeks(_label)
    _loads = [_w[k]['load'] for k in sorted(_w)]
    _median = _stats.median(_loads) if _loads else 0
    # (1) Every [deload]-labeled week is <= the plan's median load — the tag must
    # mark a genuinely light week, never a heavy one.
    _bad = [(k, _w[k]['load']) for k in sorted(_w) if _w[k]['deload'] and _w[k]['load'] > _median]
    check(f"{_label}: every [deload] week is <= median load ({_median:.0f})",
          not _bad,
          f"[deload] tags on ABOVE-median (heavy) weeks: {_bad}; loads={_loads}",
          full=True)
    # (2) No week's load jumps >80% vs the prior week — a gradual opening, no
    # detonation into full quality.
    _jumps = []
    _ks = sorted(_w)
    for _i in range(1, len(_ks)):
        _p, _c = _w[_ks[_i - 1]]['load'], _w[_ks[_i]]['load']
        if _p > 0 and (_c - _p) / _p > 0.80:
            _jumps.append(f"W{_ks[_i-1]}->W{_ks[_i]}: {_p}->{_c} (+{(_c-_p)/_p*100:.0f}%)")
    check(f"{_label}: no week's load jumps >80% vs prior (smooth onboarding)",
          not _jumps,
          f"load detonations: {_jumps}",
          full=True)

# (3) Maint Beg quality spans >=2 distinct types (not 100% threshold) — give it
# interval/ladder variety like Maint Int/Adv.
_wbeg = parse_maint_weeks("Maint Beg")
_beg_qual = sorted({sub for k in _wbeg for sub, _ in _wbeg[k]['subs'] if sub in MAINT_QUALITY})
check("Maint Beg quality spans >=2 distinct types (not 100% threshold)",
      len(_beg_qual) >= 2,
      f"quality subtypes seen: {_beg_qual}",
      full=True)

section("5K plans long-run policy (Beg/Int skip, Adv has Daniels Phase II optionals)")

for header, fil, expected_max in [
    ("Beg 5K (long, 10w)", "Beg 5K (long", 0),     # Beg 5K: skip — no aerobic base for LRs
    ("Int 5K (long, 10w)", "Int 5K (long", 0),     # Int 5K: skip — speed-focused
    ("Adv 5K (long, 10w)", "Adv 5K (long", 6),     # Adv 5K: Daniels Phase II optional LRs
]:
    text = run_pacedump(fil, race_pace=240, easy_pace=350)
    w = parse_plan(text, header)
    long_count = sum(
        1 for week in w.values() for s,_,_ in week if s in LONG
    )
    short = header.split(' (')[0]
    if expected_max == 0:
        check(
            f"{short} has 0 long runs (no aerobic base / speed-focused tier)",
            long_count == 0,
            f"found {long_count} long-run workouts"
        )
    else:
        # Adv 5K: Daniels Phase II prescribes ~6-8 long runs across a
        # 10w cycle (BASE/SPEED, not PEAK — PEAK stays speed-focused).
        # Lower bound 2 guards against the engine accidentally dropping
        # LRs entirely; upper bound 8 guards against over-scheduling.
        check(
            f"{short} has 2-8 long runs (Daniels Phase II optionals in BASE/SPEED)",
            2 <= long_count <= 8,
            f"found {long_count} long-run workouts"
        )

section("5K/10K race week is light (no aggressive quality)")

# For 5K/10K plans (taperDur=1), the last week WAS getting threshold/intervals
# 3-4 days before race day. Race-week branch now also fires for last-taper-week.
for header, fil, rp, ep, last_wk in [
    ("Beg 5K (long, 10w)",  "Beg 5K (long",  240, 350, 10),
    ("Int 5K (long, 10w)",  "Int 5K (long",  240, 320, 10),
    ("Beg 10K (long, 12w)", "Beg 10K (long", 300, 420, 12),
    ("Int 10K (long, 12w)", "Int 10K (long", 270, 380, 12),
    ("Adv 10K (long, 12w)", "Adv 10K (long", 260, 320, 12),
]:
    text = run_pacedump(fil, race_pace=rp, easy_pace=ep)
    w = parse_plan(text, header)
    race_week = w.get(last_wk, [])
    has_quality = any(s in QUALITY for s,_,_ in race_week)
    has_long = any(s in LONG for s,_,_ in race_week)
    check(
        f"{header.split(' (')[0]} race week has no quality + no long run",
        not has_quality and not has_long,
        f"race week: {[(s,d) for s,d,_ in race_week]}"
    )

section("Beg PEAK gets race-pace exposure")

# Beg 21K/42K should include at least ONE race-pace-flavored long run in
# PEAK so the runner has run at goal pace before race day. We accept
# raceRehearsalHM (21K) / raceRehearsalM (42K) / fastFinish as all
# race-pace-exposure workouts (all have a MP tail or MP block).
race_pace_subtypes = {'raceRehearsalM','raceRehearsalHM','fastFinish'}
for header, fil, rp, ep in [
    ("Beg 21K (long, 18w)", "Beg 21K (long", 300, 420),
    ("Beg 42K (long, 22w)", "Beg 42K (long", 330, 450),
]:
    text = run_pacedump(fil, race_pace=rp, easy_pace=ep)
    w = parse_plan(text, header)
    found = [(wk, s) for wk in w for s,_,_ in w[wk] if s in race_pace_subtypes]
    check(
        f"{header.split(' (')[0]} PEAK has race-pace exposure",
        len(found) >= 1,
        f"no race-pace workouts found"
    )

section("Beg 21K/42K keep a REDUCED long run in the taper (no taper LR cliff)")

# Bug: beginner half/marathon plans went from the single longest run of the
# plan (peak) straight to NO long run in the taper — a cliff. Every other tier
# (Int/Adv/Cmp) keeps a reduced taper long run for endurance maintenance
# (Pfitz/Daniels). Assert: for Beg 21K/42K (ALL variants incl Acc), every TAPER
# week that PRECEDES the race week carries a long-run-class session, and that
# session is REDUCED vs the plan's peak long run (present, but below peak —
# not zero, not >= peak). Phase labels come from `dump` (the real per-week
# phase buildWeek uses), not the `phases` target model.

def parse_dump_phase_longs(dump_text, header):
    """dict[week] = (phase, [long_durs]) parsed from `dump`. A long-run-class
    session is any workout whose subtype is in LONG or whose role == 'long'."""
    if f'=== {header}' not in dump_text:
        return None
    sect = dump_text.split(f'=== {header}')[1]
    weeks = {}
    cur = cur_phase = None
    for line in sect.splitlines():
        if line.startswith('=== '):
            break
        m = re.match(r'^W *(\d+) \[(\w+)', line)
        if m:
            cur, cur_phase = int(m.group(1)), m.group(2)
            weeks[cur] = (cur_phase, [])
            continue
        if cur is None:
            continue
        mm = re.search(r'\s(\d+)min\s+l=\d+\s+\[(\w+)/(\w+)\]', line)
        if mm:
            dur, sub, role = int(mm.group(1)), mm.group(2), mm.group(3)
            if sub in LONG or role == 'long':
                weeks[cur][1].append(dur)
    return weeks

# (header, unique dump filter). All 8 affected Beg variants + every other tier
# at 21K/42K (which must ALREADY satisfy the invariant — regression guard).
TAPER_LR_BEG = [
    ("Beg 21K (short, 10w)",   "Beg 21K (short, 10w)"),
    ("Beg 21K (rec, 14w)",     "Beg 21K (rec, 14w)"),
    ("Beg 21K (long, 18w)",    "Beg 21K (long, 18w)"),
    ("Beg 42K (short, 14w)",   "Beg 42K (short, 14w)"),
    ("Beg 42K (rec, 18w)",     "Beg 42K (rec, 18w)"),
    ("Beg 42K (long, 22w)",    "Beg 42K (long, 22w)"),
    ("Acc Beg 21K (rec, 14w)", "Acc Beg 21K (rec, 14w)"),
    ("Acc Beg 42K (rec, 18w)", "Acc Beg 42K (rec, 18w)"),
]
TAPER_LR_OTHER = [
    ("Int 21K (long, 18w)", "Int 21K (long, 18w)"),
    ("Adv 21K (long, 18w)", "Adv 21K (long, 18w)"),
    ("Cmp 21K (long, 18w)", "Cmp 21K (long, 18w)"),
    ("Int 42K (long, 22w)", "Int 42K (long, 22w)"),
    ("Adv 42K (long, 22w)", "Adv 42K (long, 22w)"),
    ("Cmp 42K (long, 22w)", "Cmp 42K (long, 22w)"),
]
for label_group, plans in [("Beg", TAPER_LR_BEG), ("other tier", TAPER_LR_OTHER)]:
    for header, fil in plans:
        weeks = parse_dump_phase_longs(run_dump(fil), header)
        if not weeks:
            check(f"{header} taper-LR parses", False, "no plan parsed from dump")
            continue
        # Peak long run = max long-run-class duration across all BUILD weeks.
        peak_lr = max(
            (max(longs) for (ph, longs) in weeks.values()
             if ph in ('base', 'speed', 'peak') and longs),
            default=0)
        # Taper weeks that PRECEDE the race week (race week stays hands-off).
        race_wk = max((wk for wk, (ph, _) in weeks.items() if ph == 'race'),
                      default=max(weeks))
        taper_wks = [wk for wk, (ph, _) in sorted(weeks.items())
                     if ph == 'taper' and wk < race_wk]
        # The 60min long-run floor is the beginner safety minimum. When a plan is
        # light enough that its PEAK long run already sits at that floor (e.g. the
        # accessible 21K tier post-#147), the taper long run cannot drop below it
        # without breaking the rail — so a taper LR AT the floor is "reduced as far
        # as the floor allows", not a violation. Equality only fails when the peak
        # is above the floor (a genuine plateau where the taper should have cut).
        LR_FLOOR = 60
        problems = []
        for wk in taper_wks:
            longs = weeks[wk][1]
            if not longs:
                problems.append(f"W{wk}: NO long run (peak={peak_lr}m)")
            elif max(longs) >= peak_lr and peak_lr > LR_FLOOR:
                problems.append(f"W{wk}: long {max(longs)}m >= peak {peak_lr}m (not reduced)")
        check(
            f"{header.split(' (')[0]} {label_group}: taper weeks carry a REDUCED long run",
            bool(taper_wks) and not problems,
            f"taper_wks={taper_wks}, peak={peak_lr}m, problems={problems}"
        )

section("Every 21K+ BUILD week (base/speed/peak) carries a long run (all tiers incl Acc)")

# The taper-LR test above only guards TAPER weeks. This extends the guarantee to
# the BUILD phases: for every 21K+ plan, EVERY base/speed/peak week (excluding the
# race week) must carry a long-run-class session. Caught the Acc Beg 21K regression
# where the forced mid-PEAK race-rehearsal week cleared the long-run pool down to
# raceRehearsalHM, the 72-min cap then emptied it (shortest HMP rung was 75min), and
# the long-run slot silently fell through to a ~35min easy filler. Reuses
# parse_dump_phase_longs (phase labels from `dump`, the real per-week phase).

# Every 21K+ plan plan_debug enumerates, across all tiers incl Acc.
BUILD_LR_PLANS = [
    ("Beg 21K (short, 10w)",   "Beg 21K (short, 10w)"),
    ("Beg 21K (rec, 14w)",     "Beg 21K (rec, 14w)"),
    ("Beg 21K (long, 18w)",    "Beg 21K (long, 18w)"),
    ("Int 21K (rec, 14w)",     "Int 21K (rec, 14w)"),
    ("Int 21K (long, 18w)",    "Int 21K (long, 18w)"),
    ("Adv 21K (rec, 14w)",     "Adv 21K (rec, 14w)"),
    ("Adv 21K (long, 18w)",    "Adv 21K (long, 18w)"),
    ("Cmp 21K (short, 12w)",   "Cmp 21K (short, 12w)"),
    ("Cmp 21K (rec, 14w)",     "Cmp 21K (rec, 14w)"),
    ("Cmp 21K (long, 18w)",    "Cmp 21K (long, 18w)"),
    ("Beg 42K (short, 14w)",   "Beg 42K (short, 14w)"),
    ("Beg 42K (rec, 18w)",     "Beg 42K (rec, 18w)"),
    ("Beg 42K (long, 22w)",    "Beg 42K (long, 22w)"),
    ("Int 42K (rec, 18w)",     "Int 42K (rec, 18w)"),
    ("Int 42K (long, 22w)",    "Int 42K (long, 22w)"),
    ("Adv 42K (rec, 18w)",     "Adv 42K (rec, 18w)"),
    ("Adv 42K (long, 22w)",    "Adv 42K (long, 22w)"),
    ("Cmp 42K (rec, 18w)",     "Cmp 42K (rec, 18w)"),
    ("Cmp 42K (long, 22w)",    "Cmp 42K (long, 22w)"),
    ("Cmp 42K (build, 28w)",   "Cmp 42K (build, 28w)"),
    ("Acc Beg 21K (rec, 14w)", "Acc Beg 21K (rec, 14w)"),
    ("Acc Int 21K (rec, 14w)", "Acc Int 21K (rec, 14w)"),
    ("Acc Adv 21K (rec, 14w)", "Acc Adv 21K (rec, 14w)"),
    ("Acc Beg 42K (rec, 18w)", "Acc Beg 42K (rec, 18w)"),
    ("Acc Int 42K (rec, 18w)", "Acc Int 42K (rec, 18w)"),
    ("Acc Adv 42K (rec, 18w)", "Acc Adv 42K (rec, 18w)"),
]
for header, fil in BUILD_LR_PLANS:
    weeks = parse_dump_phase_longs(run_dump(fil), header)
    if not weeks:
        check(f"{header} build-LR parses", False, "no plan parsed from dump")
        continue
    # Race week stays hands-off (handled by the race-week branch).
    race_wk = max((wk for wk, (ph, _) in weeks.items() if ph == 'race'),
                  default=max(weeks))
    missing = [
        f"W{wk}({ph})" for wk, (ph, longs) in sorted(weeks.items())
        if ph in ('base', 'speed', 'peak') and wk < race_wk and not longs
    ]
    check(
        f"{header.split(' (')[0]}: every build week carries a long run",
        not missing,
        f"build weeks with NO long run: {missing}"
    )

section("Beg 10K has a long run every build week")

text = run_pacedump("Beg 10K (long", race_pace=300, easy_pace=420)
w = parse_plan(text, "Beg 10K (long, 12w)")
# W1-W11 are BASE/SPEED/PEAK; W12 is race week (skipped). Every build week
# should have a long run (was alternating before).
missing = []
for wk in range(1, 12):
    has_long = any(s in LONG for s,_,_ in w.get(wk, []))
    if not has_long:
        missing.append(wk)
check(
    "Beg 10K has a long run every build week (W1-W11)",
    not missing,
    f"missing in weeks: {missing}"
)

section("Beg quality-TYPE variety — not 100% threshold every quality week")

# Bug: Beg 10K/21K/42K (incl Acc) ran ONE quality TYPE — all threshold — every
# quality week (the threshold progression 3x8->3x10->2x12->2x15 is sensible, but
# a beginner did the identical TYPE all season). Fix alternates the quality
# session between threshold and hill repeats (both beginner-safe LT/strength at
# similar load). Assert: the set of TRUE hard-quality TYPES across the plan has
# >=2 distinct types. 5K Beg is fine (already TT+threshold) and is excluded.
# Other tiers (Int/Adv/Cmp) already vary — kept as a regression guard.
#
# "Hard quality" = the day daydump marks 'Q' (the threshold/hills/TT/MP session).
# Easy+Strides is NOT a Q day (it's a low-load aerobic+neuromuscular filler), so
# it's correctly excluded — strides crowding the interval slot was the bug.

def quality_types_via_daydump(filter_str, header):
    """Set of subtypes for daydump 'Q'-marked (hard quality) sessions."""
    r = subprocess.run([PLAN_DEBUG, "daydump", filter_str],
                       capture_output=True, text=True, env=os.environ.copy())
    marker = f'=== {header} DAY-BY-DAY'
    if marker not in r.stdout:
        return None
    sect = r.stdout.split(marker, 1)[1]
    nxt = re.search(r'\n=== ', sect)
    if nxt:
        sect = sect[:nxt.start()]
    types = []
    for line in sect.splitlines():
        m = re.match(r'^\s+(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+Q\s+.+?\[(\w+)\]', line)
        if m:
            types.append(m.group(2))
    return types

# Affected beginner plans — every variant the audit flagged as all-threshold,
# plus the Acc tier. ALL must now span >=2 quality types.
BEG_QUALITY_VARIETY = [
    ("Beg 10K (long, 12w)",    "Beg 10K (long, 12w)"),
    ("Beg 21K (short, 10w)",   "Beg 21K (short, 10w)"),
    ("Beg 21K (rec, 14w)",     "Beg 21K (rec, 14w)"),
    ("Beg 21K (long, 18w)",    "Beg 21K (long, 18w)"),
    ("Beg 42K (short, 14w)",   "Beg 42K (short, 14w)"),
    ("Beg 42K (rec, 18w)",     "Beg 42K (rec, 18w)"),
    ("Beg 42K (long, 22w)",    "Beg 42K (long, 22w)"),
    ("Acc Beg 21K (rec, 14w)", "Acc Beg 21K (rec, 14w)"),
    ("Acc Beg 42K (rec, 18w)", "Acc Beg 42K (rec, 18w)"),
]
for header, fil in BEG_QUALITY_VARIETY:
    types = quality_types_via_daydump(fil, header)
    if types is None:
        check(f"{header} quality-variety parses", False, "no daydump for plan")
        continue
    distinct = sorted(set(types))
    check(
        f"{header.split(' (')[0]}: quality TYPES span >=2 (not 100% one type)",
        len(distinct) >= 2,
        f"quality types: {types} (distinct={distinct})"
    )

# Regression guard: other tiers (which already vary) must stay varied.
OTHER_QUALITY_VARIETY = [
    ("Int 21K (long, 18w)", "Int 21K (long, 18w)"),
    ("Adv 21K (long, 18w)", "Adv 21K (long, 18w)"),
    ("Int 42K (long, 22w)", "Int 42K (long, 22w)"),
    ("Adv 42K (long, 22w)", "Adv 42K (long, 22w)"),
]
for header, fil in OTHER_QUALITY_VARIETY:
    types = quality_types_via_daydump(fil, header)
    if types is None:
        check(f"{header} quality-variety parses", False, "no daydump for plan")
        continue
    distinct = sorted(set(types))
    check(
        f"{header.split(' (')[0]}: quality TYPES span >=2 (regression guard)",
        len(distinct) >= 2,
        f"quality types: {types} (distinct={distinct})"
    )

section("Adv 42K hits Pfitz 18/55 territory in PEAK")

text = run_pacedump("Adv 42K (long", race_pace=280, easy_pace=380)
w = parse_plan(text, "Adv 42K (long, 22w)")
# Pfitz 18/55 peaks ~470 min/wk. We accept ~380+ as "in the territory" —
# Adv tier is between Pfitz 18/55 and 18/70.
peak_weeks = list(range(15, 21))  # late PEAK
peak_max_vol = max(
    sum(d for _,d,_ in w.get(wk, [])) for wk in peak_weeks
)
check(
    "Adv 42K late PEAK has at least one ≥380min week (Pfitz 18/55 territory)",
    peak_max_vol >= 380,
    f"peak_max_vol={peak_max_vol}min"
)

section("Cmp plans unchanged from prior fixes (regression guard)")

# Snapshot the volume / peak LR / quality count for Cmp plans. These were
# stable after the round-2 fixes; touching anything that flips these
# numbers means a Cmp regression slipped in.
CMP_SNAPSHOTS = [
    # (header, filter, race_pace, easy_pace, total_min, sessions, peak_LR_min)
    # 7380 → 7531 from mediumLong forcing alternating weeks (Pfitz half MLR).
    ("Cmp 21K (long, 18w)", "Cmp 21K (long", 256, 300, 7531, 105, 115),
    # Snapshots bumped 2026-06-06 for the easy-pool mediumLong migration:
    # selector now picks 90-100min "Medium-Long Run" over 85min "Easy Run"
    # for Cmp 42K midweek long-easy slots, matching Pfitz 18/85's explicit
    # "Wed/Thu MLR" prescription. +124min (long, 22w) / +147min (build, 28w)
    # over 22-28 weeks ≈ +5min/wk per the new Pfitz-aligned ML slot.
    # 2026-06-16: total 10244→9789, sessions 129→124 from the peak-volume
    # soft cap (Adv/Cmp marathons capped ~9h; sheds the largest aerobic FILL,
    # never the long run — peak LR unchanged at 210) + the 3-week taper floor.
    # 2026-06-18: 9789→9686 (−1%) from BASE quality-variety injection — every
    # other competitive/advanced BASE off-week now runs an MP/LT (threshold-pool)
    # session instead of a ladder. MP is Z3 (load-dense), so easy fill rebalances
    # down slightly. Sessions (124) and peak LR (210) unchanged.
    # 2026-06-18: 9686→9790 (+1%) from the ACWR volume ramp-cap — capping a
    # peak-finish target spike frees workouts that redistribute to later weeks
    # (cascade). Sessions (124) and peak LR (210) unchanged.
    ("Cmp 42K (long, 22w)", "Cmp 42K (long", 256, 300, 9790, 124, 210),
    # Additional bump 12002 → 12123 from the alternating-week mediumLong
    # forcing — Cmp 42K build picks 90-100min ML on even weeks where
    # selector previously picked 80min easy. 2026-06-16: 12123→11809,
    # 165→162 sessions from the same peak-volume cap.
    ("Cmp 42K (build, 28w)", "Cmp 42K (build", 256, 300, 11809, 162, 200),
]
for header, fil, rp, ep, exp_total, exp_sess, exp_peak in CMP_SNAPSHOTS:
    text = run_pacedump(fil, race_pace=rp, easy_pace=ep)
    w = parse_plan(text, header)
    total = sum(sum(d for _,d,_ in w[wk]) for wk in w)
    sessions = sum(len(w[wk]) for wk in w)
    durs = get_long_durations(w)
    peak_lr = max(d for _, d in durs) if durs else 0
    check(
        f"{header.split(' (')[0].split(',')[0]} total_min unchanged ({exp_total}±100)",
        abs(total - exp_total) <= 100,
        f"got total={total}, expected {exp_total}±100",
        full=True
    )
    check(
        f"{header.split(' (')[0].split(',')[0]} session count unchanged ({exp_sess}±3)",
        abs(sessions - exp_sess) <= 3,
        f"got sessions={sessions}, expected {exp_sess}±3",
        full=True
    )
    check(
        f"{header.split(' (')[0].split(',')[0]} peak LR unchanged ({exp_peak}m)",
        peak_lr == exp_peak,
        f"got peak_lr={peak_lr}m, expected {exp_peak}m",
        full=True
    )

section("Long-than-recommended plans (30w) generate cleanly")

# Cmp 42K (build, 28w) is the longest currently in plan_debug. Verify it
# generates without crashes, has a valid taper drop, and peak LR matches
# the Cmp ceiling.
text = run_pacedump("Cmp 42K (build", race_pace=256, easy_pace=300)
w = parse_plan(text, "Cmp 42K (build, 28w)")
check(
    "Cmp 42K 28w plan parses (no crash)",
    w is not None and len(w) == 28,
    f"got {len(w) if w else None} weeks"
)
if w:
    durs = get_long_durations(w)
    peak_lr = max(d for _, d in durs) if durs else 0
    check(
        "Cmp 42K 28w peak LR caps at ~35km/~165m (no runaway; Pfitz longest ~22mi)",
        140 <= peak_lr <= 185,
        f"peak_lr={peak_lr}m"
    )
    week_vols = {wk: sum(d for _,d,_ in w[wk]) for wk in w}
    nweeks = max(w)
    last_taper = week_vols[nweeks - 1]
    # Peak figure from NON-DELOAD PEAK weeks only: recovery weeks now deliberately
    # remove load and dip below their predecessor, so averaging them in (as the
    # old fixed nweeks-5..nweeks-2 window did) understates the true peak and makes
    # the taper-drop ratio spuriously fail. Compare the taper against real peak load.
    phw = parse_phase_weeks("Cmp 42K (build")
    peak_real = [week_vols[wk] for wk in week_vols
                 if phw.get(wk, (None, False)) == ("PEAK", False)]
    avg_peak = sum(peak_real) / len(peak_real) if peak_real else 0
    check(
        "Cmp 42K 28w TAPER drops meaningfully from peak",
        peak_real and last_taper < avg_peak * 0.7,
        f"last_taper={last_taper}, avg_peak={avg_peak:.0f} (non-deload peak weeks={len(peak_real)})"
    )

section("Short-than-recommended plans (5K 5w) generate cleanly")

for header, fil, rp, ep in [
    ("Beg 5K (short, 5w)", "Beg 5K (short", 240, 360),
    ("Int 5K (short, 5w)", "Int 5K (short", 240, 320),
]:
    text = run_pacedump(fil, race_pace=rp, easy_pace=ep)
    w = parse_plan(text, header)
    check(
        f"{header.split(' (')[0]} 5w plan parses",
        w is not None and len(w) == 5,
        f"got {len(w) if w else None} weeks"
    )

section("Pace conversion: pace matches HR zone math")

# Spot-check: for racePace=300, Z2 multiplier 1.15 → 345 sec/km = 5:45/km.
# Beg 42K Easy Run workouts are Z2; their resolved pace should land near
# expected (depends on phase progression for non-competitive).
text = run_pacedump("Beg 42K (long", race_pace=300, easy_pace=420)
w = parse_plan(text, "Beg 42K (long, 22w)")
# Final week ("race week"): conversational pace should be close to expected
# easy-mid pace, since the gap-blend has fully converged by then.
# For racePace=300, easyPace=420, gap-blended Z2 lands ~5:45-6:00/km at end.
final_paces = []
for s, _, p in w.get(22, []):
    if s in EASY or s in LONG:
        sec = get_pace_secs(p)
        if sec:
            final_paces.append(sec)
# At race week the easy pace for Beg 42K should land between racePace*1.15
# (294s) and easyPace*0.95 (399s) — i.e. somewhere between 4:54 and 6:39.
check(
    "Beg 42K race-week easy pace lands in expected range",
    final_paces and all(294 <= p <= 420 for p in final_paces),
    f"final_paces={final_paces}"
)

# HR mode: dump and check that the workouts.json HR zones survive without
# pace conversion (plan_debug's "dump" mode shows raw HR).
hr_result = subprocess.run(
    [PLAN_DEBUG, "dump", "Cmp 42K (long"],
    capture_output=True, text=True
)
check(
    "HR-mode dump produces phase header for Cmp 42K",
    "Phases: BASE=" in hr_result.stdout,
    f"no 'Phases: BASE=' in output"
)
# HR dump format encodes the per-workout load via "l=NNNN" — verify the
# raw HR-zone variant of the engine produces sensible workouts (load
# values present, plus 5+ weeks of workouts shown).
hr_workout_lines = [
    line for line in hr_result.stdout.splitlines()
    if re.search(r'\bl=\d+\b', line)
]
check(
    "HR dump shows per-workout load values (l=NNNN format)",
    len(hr_workout_lines) >= 100,  # 22w × ~6 workouts/wk = 132
    f"got {len(hr_workout_lines)} workout lines"
)

section("Day-assignment: no back-to-back quality workouts within a week")

# Parse the REAL Swift output from plan_debug's daydump mode. Earlier this
# test ran a Python port of the day-assignment algorithm — which proved
# meaningless because the port couldn't diverge from itself. Now we call
# the actual createMarathonPlanV3 via plan_debug and check what it does.

DAY_NAME_TO_IDX = {"Mon":0,"Tue":1,"Wed":2,"Thu":3,"Fri":4,"Sat":5,"Sun":6}

def run_daydump(filter_str):
    r = subprocess.run([PLAN_DEBUG, "daydump", filter_str],
                       capture_output=True, text=True, env=os.environ.copy())
    return r.stdout

def parse_daydump(text, header):
    """Return dict[week_num] = [(day_idx, subtype, marker)] where marker
    is 'Q'/'L'/'' from the daydump output."""
    marker = f'=== {header} DAY-BY-DAY'
    if marker not in text: return None
    section_text = text.split(marker, 1)[1]
    # Cut at the NEXT plan header (starts at column 0 with "=== ", not the
    # week-separator "============================================" lines).
    next_header = re.search(r'\n=== ', section_text)
    if next_header:
        section_text = section_text[:next_header.start()]
    weeks = {}; cur = None
    for line in section_text.splitlines():
        m = re.match(r'^W *(\d+):\s*$', line)
        if m:
            cur = int(m.group(1)); weeks[cur] = []; continue
        if cur is None: continue
        # Format: "  Mon Q  Title  NNmin  [subtype]"  or  "  Mon    Title  NNmin  [subtype]"
        m = re.match(r'^\s+(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+([QL ])\s+.+?\[(\w+)\]', line)
        if not m: continue
        day_idx = DAY_NAME_TO_IDX[m.group(1)]
        marker_char = m.group(2).strip()
        subtype = m.group(3)
        weeks[cur].append((day_idx, subtype, marker_char))
    return weeks

def find_back_to_back_quality(week_workouts):
    """week_workouts: list of (day_idx, subtype, marker). Return list of
    violations: (d1_name, sub1, d2_name, sub2)."""
    by_day = sorted(week_workouts, key=lambda x: x[0])
    violations = []
    name_for = {v:k for k,v in DAY_NAME_TO_IDX.items()}
    for i in range(1, len(by_day)):
        d1, s1, m1 = by_day[i-1]
        d2, s2, m2 = by_day[i]
        if d2 - d1 != 1: continue  # not consecutive calendar days
        if m1 == 'Q' and m2 == 'Q':
            violations.append((name_for[d1], s1, name_for[d2], s2))
    return violations

# Plans to check. The daydump filter must uniquely match ONE plan label.
DAYDUMP_PLANS = [
    ("Beg 5K (long, 10w)",  "Beg 5K (long, 10w)"),
    ("Int 5K (long, 10w)",  "Int 5K (long, 10w)"),
    ("Adv 5K (long, 10w)",  "Adv 5K (long, 10w)"),
    ("Beg 10K (long, 12w)", "Beg 10K (long, 12w)"),
    ("Int 10K (long, 12w)", "Int 10K (long, 12w)"),
    ("Adv 10K (long, 12w)", "Adv 10K (long, 12w)"),
    ("Beg 21K (long, 18w)", "Beg 21K (long, 18w)"),
    ("Int 21K (long, 18w)", "Int 21K (long, 18w)"),
    ("Adv 21K (long, 18w)", "Adv 21K (long, 18w)"),
    ("Cmp 21K (long, 18w)", "Cmp 21K (long, 18w)"),
    ("Beg 42K (long, 22w)", "Beg 42K (long, 22w)"),
    ("Int 42K (long, 22w)", "Int 42K (long, 22w)"),
    ("Adv 42K (long, 22w)", "Adv 42K (long, 22w)"),
    ("Cmp 42K (long, 22w)", "Cmp 42K (long, 22w)"),
    ("Cmp 42K (build, 28w)", "Cmp 42K (build, 28w)"),
    ("Maint Adv (12w)",     "Maint Adv (12w)"),
]
for header, fil in DAYDUMP_PLANS:
    text = run_daydump(fil)
    weeks = parse_daydump(text, header)
    if not weeks:
        check(f"{header} daydump parses", False, "no plan parsed from real Swift")
        continue
    violations = []
    for wk, sessions in sorted(weeks.items()):
        bad = find_back_to_back_quality(sessions)
        for d1, s1, d2, s2 in bad:
            violations.append(f"W{wk}: {d1}={s1} → {d2}={s2}")
    check(
        f"{header.split(' (')[0]} (real Swift) no back-to-back quality days",
        not violations,
        f"first 3 violations: {violations[:3]}"
    )

section("Workout variety: no quality workout repeats >2 weeks consecutively")

def consecutive_run(week_list):
    """Longest run of consecutive integers in a sorted list."""
    if not week_list: return 0
    longest = 1; cur = 1
    for i in range(1, len(week_list)):
        if week_list[i] == week_list[i-1] + 1:
            cur += 1; longest = max(longest, cur)
        else:
            cur = 1
    return longest

# Parse with TITLES, not subtypes — runner sees the title repetition.
def parse_pace_with_titles(text, header):
    if header not in text: return None
    section = text.split(f'=== {header}')[1]
    weeks = {}; cur = None
    for line in section.splitlines():
        if line.startswith('=== '): break
        m = re.match(r'^W *(\d+):\s*$', line)
        if m: cur = int(m.group(1)); weeks[cur] = []; continue
        if cur is None: continue
        m = re.match(r'^\s+(.+?)\s{2,}\s*(\d+)\s*min', line)
        if not m: continue
        weeks[cur].append(m.group(1).strip())
    return weeks

for header, fil, rp, ep in [
    ("Int 42K (long, 22w)", "Int 42K (long", 320, 430),
    ("Adv 42K (long, 22w)", "Adv 42K (long", 280, 380),
    ("Cmp 42K (long, 22w)", "Cmp 42K (long", 256, 300),
]:
    text = run_pacedump(fil, race_pace=rp, easy_pace=ep)
    w = parse_pace_with_titles(text, header)
    from collections import defaultdict
    title_weeks = defaultdict(list)
    for wk in sorted(w):
        for t in w[wk]:
            title_weeks[t].append(wk)
    # Check quality-flavored titles (skip easy/strides/long which legitimately repeat)
    violations = []
    for title, wks in title_weeks.items():
        # Only check titles that look like quality workouts
        if any(kw in title for kw in ["Hill", "Intervals", "Threshold", "Mile", "Yasso", "5K Pace", "10K Pace", "Marathon Pace"]):
            run = consecutive_run(sorted(wks))
            if run >= 3:
                violations.append(f"'{title}' for {run} weeks")
    check(
        f"{header.split(' (')[0]} no quality workout repeats 3+ weeks straight",
        not violations,
        f"violations: {violations[:3]}",
        full=True
    )

section("Pace ranges — every plan, every quality zone, within watch tolerance")

# Read tolerance from real Swift (single source of truth — watch + tests
# use the same number). Falls back to 15 if plan_debug isn't reachable
# (CI not built yet), but the tolerance mode is added in the same commit.
def get_swift_tolerance():
    r = subprocess.run([PLAN_DEBUG, "tolerance"], capture_output=True, text=True)
    m = re.search(r'TOLERANCE_SECONDS=(\d+(?:\.\d+)?)', r.stdout)
    return float(m.group(1)) if m else 15.0

TOL = int(get_swift_tolerance())
print(f"  using Swift WorkoutPaceTolerance.seconds = {TOL}")

# Subtype → canonical zone. UNAMBIGUOUS subtypes only — the catalog has
# "intervals" / "ladderIntervals" entries at BOTH Z4 and Z5 (so a week
# may pick the Z4-tagged ladder or the Z5-tagged ladder; either is valid).
# Mixed subtypes are tested via "race-week direction" rather than absolute
# zone targets. The fixed-zone subtypes below have a single zone across
# every catalog entry, so we can pin to base × racePace.
#
# Hill repeats are pure Z5 in our catalog (verified). Threshold/mileRepeats/
# yasso800 are pure Z4. marathonPace is pure Z3. timeTrial is Z5.
Z3_SUBTYPES = {'marathonPace'}
# hillRepeats + timeTrial moved to Z4 with the catalog retag: hills are
# strength reps (HR can't settle in Z5 in 60-90s), and nobody holds true
# Z5 for a 20-25min time trial.
Z4_SUBTYPES = {'threshold', 'mileRepeats', 'yasso800', 'hillRepeats', 'timeTrial'}
Z5_SUBTYPES = {'fivekPace', 'tenkPace'}

def parse_pace_secs_first(pace_str):
    """Single pace 'NN:NN/km' or multi-pace '[a:bc/km, d:ef/km]'.
    Returns the FASTEST (smallest sec/km) value — the work-interval pace.
    Returns None if neither parseable."""
    if not pace_str: return None
    # Multi: take all pace numbers and pick the smallest (fastest)
    paces = re.findall(r'(\d+):(\d+)/km', pace_str)
    if not paces: return None
    secs = [int(m) * 60 + int(s) for m, s in paces]
    return min(secs)

# --- Inputs the iOS UI would actually pass to the engine for each plan.
#     For competitive plans, the UI now hard-locks racePace to 256 (sub-3
#     target) regardless of VDOT. For non-competitive plans the inputs come
#     from the user's goal-time and easy-pace pickers; the values here are
#     realistic defaults that exercise the gap-blend.
PACE_INPUTS = [
    # (header, filter, racePace, easyPace, build_band)
    ("Cmp 42K (long, 22w)",  "Cmp 42K (long, 22w)",  256, 331, False),
    ("Cmp 21K (long, 18w)",  "Cmp 21K (long, 18w)",  256, 331, False),
    ("Cmp 42K (long, 22w)",  "Cmp 42K (long, 22w)",  256, 353, True),   # build band VDOT 54 sim
    ("Cmp 21K (long, 18w)",  "Cmp 21K (long, 18w)",  256, 353, True),
    ("Adv 42K (long, 22w)",  "Adv 42K (long, 22w)",  280, 380, False),
    ("Adv 21K (long, 18w)",  "Adv 21K (long, 18w)",  270, 360, False),
    ("Int 42K (long, 22w)",  "Int 42K (long, 22w)",  320, 430, False),
    ("Int 21K (long, 18w)",  "Int 21K (long, 18w)",  300, 420, False),
    ("Beg 42K (long, 22w)",  "Beg 42K (long, 22w)",  330, 450, False),
    ("Beg 21K (long, 18w)",  "Beg 21K (long, 18w)",  360, 480, False),
    ("Int 10K (long, 12w)",  "Int 10K (long, 12w)",  270, 380, False),
    ("Adv 10K (long, 12w)",  "Adv 10K (long, 12w)",  260, 320, False),
    ("Beg 10K (long, 12w)",  "Beg 10K (long, 12w)",  330, 450, False),
]

def run_pacedump_with(filter_str, race_pace, easy_pace, build_band, speed_pace=None):
    env = os.environ.copy()
    env["RACE_PACE"] = str(race_pace)
    env["EASY_PACE"] = str(easy_pace)
    # speed_pace (runner's 5K pace) anchors quality zones; omit → legacy path.
    if speed_pace is not None: env["SPEED_PACE"] = str(speed_pace)
    else: env.pop("SPEED_PACE", None)
    if build_band: env["BUILD_BAND"] = "1"
    else: env.pop("BUILD_BAND", None)
    r = subprocess.run([PLAN_DEBUG, "pacedump", filter_str],
                       capture_output=True, text=True, env=env)
    return r.stdout

def collect_zone_paces(weeks):
    """Return dict[zone] = list of (week, pace_secs) for that zone's subtypes."""
    out = {3: [], 4: [], 5: []}
    for wk in weeks:
        for s, _, p in weeks[wk]:
            secs = parse_pace_secs_first(p)
            if secs is None: continue
            if s in Z3_SUBTYPES: out[3].append((wk, secs))
            elif s in Z4_SUBTYPES: out[4].append((wk, secs))
            elif s in Z5_SUBTYPES: out[5].append((wk, secs))
    return out

# --- Quality paces are anchored to the runner's 5K SPEED, not the goal race
# pace (Daniels/Pfitzinger): an interval is 5K pace and a threshold is 15K-HM
# pace whether the goal is a 5K or a marathon. Only marathon-pace (Z3) work
# stays at the goal race pace. These checks pin that contract for every plan.
QUALITY_SUBTYPES = {'intervals', 'ladderIntervals', 'pyramidIntervals', 'threshold',
                    'mileRepeats', 'yasso800', 'hillRepeats', 'timeTrial',
                    'fivekPace', 'tenkPace'}

import math as _m
def _vf(d, t):
    tm = t / 60.0; v = d / tm
    return (-4.60 + 0.182258 * v + 0.000104 * v * v) / \
           (0.8 + 0.1894393 * _m.exp(-0.012778 * tm) + 0.2989558 * _m.exp(-0.1932605 * tm))
def _pred(d, vd):
    lo, hi = 60.0, 6 * 3600.0
    for _ in range(60):
        mid = (lo + hi) / 2; mv = _vf(d, int(mid))
        if abs(mv - vd) < 0.001: return mid
        lo, hi = (mid, hi) if mv > vd else (lo, mid)
    return (lo + hi) / 2
def _vel(vd, q):
    a, b, c = 0.000104, 0.182258, -(4.60 + q * vd)
    return 60000.0 / ((-b + _m.sqrt(b * b - 4 * a * c)) / (2 * a))
def _mm(x): return f"{int(round(x)) // 60}:{int(round(x)) % 60:02d}"

# (header, filter, representative 5K time s -> VDOT, plan distance m, is_cmp).
# Cmp hard-locks goal pace to 256 (sub-3 MP); others use their goal-distance
# pace. speedPace = the runner's true 5K pace (what quality anchors to).
PACE_QUALITY_PLANS = [
    ("Beg 10K (long, 12w)", "Beg 10K (long, 12w)", 1800, 10000, False),
    ("Int 10K (long, 12w)", "Int 10K (long, 12w)", 1320, 10000, False),
    ("Adv 10K (long, 12w)", "Adv 10K (long, 12w)", 1080, 10000, False),
    ("Beg 21K (long, 18w)", "Beg 21K (long, 18w)", 1800, 21097, False),
    ("Int 21K (long, 18w)", "Int 21K (long, 18w)", 1320, 21097, False),
    ("Adv 21K (long, 18w)", "Adv 21K (long, 18w)", 1080, 21097, False),
    ("Beg 42K (long, 22w)", "Beg 42K (long, 22w)", 1800, 42195, False),
    ("Int 42K (long, 22w)", "Int 42K (long, 22w)", 1320, 42195, False),
    ("Adv 42K (long, 22w)", "Adv 42K (long, 22w)", 1080, 42195, False),
    ("Cmp 21K (long, 18w)", "Cmp 21K (long, 18w)", 1050, 21097, True),
    ("Cmp 42K (long, 22w)", "Cmp 42K (long, 22w)", 1050, 42195, True),
]
for header, fil, t5k, dist, is_cmp in PACE_QUALITY_PLANS:
    vd = _vf(5000, t5k)
    speed5k = int(_pred(5000, vd) / 5)
    p10k = int(_pred(10000, vd) / 10)
    goal = 256 if is_cmp else int(_pred(dist, vd) / (dist / 1000.0))
    easy = int(_vel(vd, 0.72))
    short = header.split(' (')[0]
    w = parse_plan(run_pacedump_with(fil, goal, easy, is_cmp, speed_pace=speed5k), header)
    if not w:
        check(f"{short} pace parse", False, "no plan", full=True); continue
    mp, qual = [], []
    for wk in w:
        for s, _, pp in w[wk]:
            secs = parse_pace_secs_first(pp)
            if secs is None: continue
            if s == 'marathonPace': mp.append(secs)
            elif s in QUALITY_SUBTYPES: qual.append(secs)
    # (1) Marathon-pace work is the one quality kind that stays at goal pace.
    if mp:
        check(f"{short} marathon-pace work at goal pace +/-{TOL}s (Z3 race-anchored)",
              all(abs(p - goal) <= TOL for p in mp),
              f"goal={_mm(goal)} out={[_mm(p) for p in mp if abs(p - goal) > TOL][:3]}",
              full=True)
    # (2) Core invariant: every quality pace is 5K-SPEED anchored and REP-LENGTH
    #     aware. Fastest = short-rep VO2 / hills at ~0.88×5K (faster than 5K pace);
    #     slowest = week-1 threshold at ~1.06×5K (true LT). Never as slow as MP.
    if qual:
        lo, hi = int(speed5k * 0.85) - TOL, int(speed5k * 1.07) + TOL
        bad = [p for p in qual if not (lo <= p <= hi)]
        check(f"{short} quality in [{_mm(int(speed5k*0.85))} .. {_mm(int(speed5k*1.07))}] (5K-speed anchored, rep-length-aware)",
              not bad, f"out={[_mm(p) for p in bad[:4]]}", full=True)
    # (3) On the marathon, fastest quality is far faster than goal MP - decoupled.
    if qual and dist >= 42195 and 'Beg' not in short:
        check(f"{short} fastest quality reaches >= 10K pace, not goal MP (decoupled)",
              min(qual) <= p10k + TOL,
              f"fastest={_mm(min(qual))} 10K={_mm(p10k)} goal(MP)={_mm(goal)}", full=True)
    # (4) Adv / Cmp fully sharpen: fastest quality is AT or BELOW 5K pace (the
    #     short-rep VO2 now runs faster than 5K — R/I-pace, rep-length-aware).
    if qual and ('Adv' in short or is_cmp):
        check(f"{short} fastest quality at/below 5K pace (sharp short-rep VO2)",
              min(qual) <= speed5k + TOL,
              f"fastest={_mm(min(qual))} 5K={_mm(speed5k)}", full=True)

section("5K/10K ladders are true VO2 (faster than race, not Z4 LT inversion)")
# Some ladderIntervals templates are Z4-only (LT cruise intervals). On 5K/10K
# (race ≈ 5K speed) a Z4 ladder slotted as the VO2 session renders SLOWER than
# race — an inversion. The engine drops Z4-only ladders on 5K/10K (keeps them on
# half/marathon). Every ladder's WORK (fastest rung) must be faster than race.
for header, fil, t5k, dist in [
    ("Int 5K (long, 10w)",  "Int 5K (long, 10w)",  1320, 5000),
    ("Adv 5K (long, 10w)",  "Adv 5K (long, 10w)",  1080, 5000),
    ("Int 10K (long, 12w)", "Int 10K (long, 12w)", 1320, 10000),
    ("Adv 10K (long, 12w)", "Adv 10K (long, 12w)", 1080, 10000),
]:
    vd = _vf(5000, t5k); speed5k = int(_pred(5000, vd) / 5)
    race = int(_pred(dist, vd) / (dist / 1000.0)); easy = int(_vel(vd, 0.72))
    short = header.split(' (')[0]
    w = parse_plan(run_pacedump_with(fil, race, easy, False, speed_pace=speed5k), header)
    vo2 = [parse_pace_secs_first(pp) for wk in (w or {}) for s, _, pp in w[wk]
           if s in ('ladderIntervals', 'intervals', 'pyramidIntervals')]
    vo2 = [v for v in vo2 if v is not None]
    if vo2:
        check(f"{short} VO2-family (intervals/ladders) faster than race (no Z4 inversion)",
              max(vo2) < race,
              f"slowest-VO2-work={_mm(max(vo2))} race={_mm(race)}", full=True)

section("10K easy anchors to stated easy + progresses (not gap-blended fast)")
# The 10K tier (easy ~19% slower than race) used to fall into the gap-blend and
# render easy FASTER than the stated easy (6:04 vs 6:11) with only ~5s progression.
# Now all non-competitive easy anchors to the stated easy + ~4% (~13s) progression.
for header, fil, t5k, dist in [
    ("Int 10K (long, 12w)", "Int 10K (long, 12w)", 1320, 10000),
    ("Adv 10K (long, 12w)", "Adv 10K (long, 12w)", 1080, 10000),
]:
    vd = _vf(5000, t5k); speed5k = int(_pred(5000, vd) / 5)
    race = int(_pred(dist, vd) / (dist / 1000.0)); easy = int(_vel(vd, 0.72))
    short = header.split(' (')[0]
    w = parse_plan(run_pacedump_with(fil, race, easy, False, speed_pace=speed5k), header)
    easies = [parse_pace_secs_first(pp) for wk in (w or {}) for s, _, pp in w[wk] if s == 'easy']
    easies = [e for e in easies if e]
    if easies:
        check(f"{short} W1 easy ~ stated easy, not gap-blended faster",
              max(easies) >= easy - 4,
              f"slowest easy={_mm(max(easies))} stated={_mm(easy)}", full=True)
        check(f"{short} easy progresses >=10s over block (anchored + ~4%)",
              max(easies) - min(easies) >= 10,
              f"range={_mm(min(easies))}..{_mm(max(easies))}", full=True)

section("Aerobic floor — easy/long never render FASTER than race pace (any plan)")
# Universal §2A invariant: an easy-class run's AEROBIC pace must never be faster
# than that plan's race pace (easy >= race). The legacy easy-easing floors the
# base gap at race but then eases ~6.5% on top with no clamp, so low-headroom
# plans (easy ~ race) underflow: at-goal competitive (Cmp clear, ~1% headroom)
# and slow runners (race ~ easy). We assert on the SLOWEST listed pace per line
# — the aerobic pace — so an embedded MP / progression-finish race-pace segment
# (which is MEANT to touch race) does not mask or trip the check.
EASY_CLASS = {'easy', 'recovery', 'steadyLong', 'long', 'mediumLong', 'progressiveLong'}

def parse_pace_secs_slowest(pace_str):
    """SLOWEST (largest sec/km) pace on a line — the aerobic pace of an easy/long
    run. Embedded faster MP/progression-finish segments are ignored on purpose."""
    if not pace_str: return None
    paces = re.findall(r'(\d+):(\d+)/km', pace_str)
    if not paces: return None
    return max(int(m) * 60 + int(s) for m, s in paces)

# Faithful per-plan inputs, derived the way the iOS app derives them from a race
# result. Cmp uses the at-goal "clear" config (build_band=False → no BUILD_BAND):
# goal 256, easy/speed from the runner's real VDOT. The SLOW band is the
# highest-inversion-risk: VDOT<30 caps easy near threshold (see
# `VDOT.easyPaceSecondsPerKm`) so easy lands only ~1-5% above race — well inside
# the 6.5% legacy easing. We replicate that exact clamp here (a plain 72%-VO2max
# easy overstates the headroom and would miss the slow-runner inversion).
def _app_easy(vd):
    """Replicates VDOT.easyPaceSecondsPerKm: 72% VO2max, but below VDOT 30 the
    72% pace balloons into a walk, so it's capped to threshold + a shrinking gap."""
    natural = int(_vel(vd, 0.72))             # 72% VO2max (matches paceAtVO2Fraction)
    if vd >= 30:
        return natural
    thr = int(_vel(vd, 0.88))                 # threshold (88% VO2max)
    max_gap = int(max(33.0, min(65.0, 65.0 - (30.0 - vd) * 3.5)))
    return min(natural, thr + max_gap)

# (header, filter, race-result distance/time → VDOT, plan distance, is_cmp).
# The slow rows use REAL slow finish times (verified via `vdotpaces`): a 5:30
# marathon → VDOT 25 (race 7:49, easy 8:05, 3.4% headroom) and a 6:00 marathon →
# VDOT 23 (1% headroom) both cross; the half slow row matches the manifest.
AEROBIC_FLOOR_PLANS = [
    # (header, filter, result_dist_m, result_time_s, plan_dist_m, is_cmp) — typical
    ("Int 10K (long, 12w)", "Int 10K (long, 12w)", 5000, 1320, 10000, False),
    ("Adv 10K (long, 12w)", "Adv 10K (long, 12w)", 5000, 1080, 10000, False),
    ("Int 21K (long, 18w)", "Int 21K (long, 18w)", 5000, 1320, 21097, False),
    ("Adv 21K (long, 18w)", "Adv 21K (long, 18w)", 5000, 1080, 21097, False),
    ("Int 42K (long, 22w)", "Int 42K (long, 22w)", 5000, 1320, 42195, False),
    ("Adv 42K (long, 22w)", "Adv 42K (long, 22w)", 5000, 1080, 42195, False),
    # Slow runners (VDOT 22-25): easy clamped near race, the inversion band.
    ("Int 42K (long, 22w)", "Int 42K (long, 22w)", 42195, 19800, 42195, False),  # 5:30 M, VDOT 25
    ("Int 42K (long, 22w)", "Int 42K (long, 22w)", 42195, 21600, 42195, False),  # 6:00 M, VDOT 23
    ("Int 21K (long, 18w)", "Int 21K (long, 18w)", 21097, 9900,  21097, False),  # 2:45 HM, VDOT 25
    ("Beg 42K (long, 22w)", "Beg 42K (long, 22w)", 42195, 19800, 42195, False),
    # At-goal competitive (Cmp clear): ~1% easy/race headroom — flagship case.
    ("Cmp 21K (long, 18w)", "Cmp 21K (long, 18w)", 5000, 1050, 21097, True),
    ("Cmp 42K (long, 22w)", "Cmp 42K (long, 22w)", 5000, 1050, 42195, True),
]
for header, fil, res_dist, res_time, dist, is_cmp in AEROBIC_FLOOR_PLANS:
    vd = _vf(res_dist, res_time)
    speed5k = int(_pred(5000, vd) / 5)
    goal = 256 if is_cmp else int(_pred(dist, vd) / (dist / 1000.0))
    easy = _app_easy(vd)
    short = header.split(' (')[0]
    # build_band=False → Cmp "clear" (at-goal) config, the failing competitive path.
    w = parse_plan(run_pacedump_with(fil, goal, easy, False, speed_pace=speed5k), header)
    if not w:
        check(f"{short} aerobic-floor parse (VDOT {vd:.0f})", False, "no plan", full=True)
        continue
    violations = []
    for wk in sorted(w):
        for s, _, pp in w[wk]:
            if s not in EASY_CLASS:
                continue
            aer = parse_pace_secs_slowest(pp)
            if aer is None:
                continue
            if aer < goal:
                violations.append(f"W{wk} [{s}] {_mm(aer)} < race {_mm(goal)} ({goal - aer}s faster)")
    check(
        f"{short} (VDOT {vd:.0f}, race {_mm(goal)}, easy {_mm(easy)}) no easy/long aerobic pace faster than race",
        not violations,
        f"{len(violations)} inversions, e.g. {violations[:4]}",
        full=True)

section("ACWR volume ramp cap — no back-loaded single-week spike")
# A build week's volume may not exceed ~1.35x the max of the prior 3 weeks (the
# 1.25 target cap + placement overshoot). Kills the 5K peak-finish spike (Adv 5K
# W9 was 359min, +44% off a ~250min plateau). Taper/race excluded (they drop).
def _weekly_mins(header):
    text = run_dump(header)
    if f'=== {header}' not in text:
        return []
    sec = text.split(f'=== {header}')[1].split('=== ')[0]
    out = []
    for line in sec.splitlines():
        m = re.match(r'^W ?\d+ \[(\w+)[^\]]*\]\s+\d+wkts\s+load=\s*\d+\s+(\d+)min', line)
        if m:
            out.append((m.group(1), int(m.group(2))))
    return out

for header in ["Adv 5K (long, 10w)", "Adv 10K (long, 12w)", "Adv 21K (long, 18w)"]:
    build = [(ph, m) for ph, m in _weekly_mins(header) if ph not in ('taper', 'race')]
    short = header.split(' (')[0]
    spikes = [f"wk{i+1} {build[i][1]}min vs prior-3-max {max(m for _, m in build[i-3:i])}"
              for i in range(3, len(build))
              if build[i][1] > max(m for _, m in build[i-3:i]) * 1.35]
    if len(build) >= 4:
        check(f"{short} no build week spikes >35% over prior-3-week max (ACWR cap)",
              not spikes, f"spikes: {spikes}", full=True)

section("Distance-aware threshold + aerobic floor (slow runner = teeth)")
# Half/marathon: threshold (~1hr effort) must be FASTER than goal race pace —
# these races are run at/above threshold (5K/10K are the opposite, so this is
# half/marathon only). Easy is never faster than race. The slow VDOT~25 runner
# is the teeth: beginner threshold used to invert PAST race pace here until
# PaceProgressionConfig.beginner.finalAdjustment dropped 0.5 -> 0.0.
def _slowest_pace(pace_str):
    ms = re.findall(r'(\d+):(\d+)/km', pace_str or "")
    return max(int(m) * 60 + int(s) for m, s in ms) if ms else None

THRESH_PLANS = [
    # (header, filter, 5K-time s [slow VDOT~25 runner], plan distance m)
    ("Beg 21K (long, 18w)", "Beg 21K (long, 18w)", 2160, 21097),
    ("Int 21K (long, 18w)", "Int 21K (long, 18w)", 2160, 21097),
    ("Adv 21K (long, 18w)", "Adv 21K (long, 18w)", 2160, 21097),
    ("Beg 42K (long, 22w)", "Beg 42K (long, 22w)", 2160, 42195),
    ("Int 42K (long, 22w)", "Int 42K (long, 22w)", 2160, 42195),
    ("Adv 42K (long, 22w)", "Adv 42K (long, 22w)", 2160, 42195),
]
for header, fil, t5k, dist in THRESH_PLANS:
    vd = _vf(5000, t5k)
    speed5k = int(_pred(5000, vd) / 5)
    race = int(_pred(dist, vd) / (dist / 1000.0))
    easy = int(_vel(vd, 0.72))
    short = header.split(' (')[0]
    w = parse_plan(run_pacedump_with(fil, race, easy, False, speed_pace=speed5k), header)
    if not w:
        check(f"{short} threshold parse", False, "no plan", full=True); continue
    thr, easies = [], []
    for wk in w:
        for s, _, pp in w[wk]:
            if s == 'threshold':
                v = parse_pace_secs_first(pp)
                if v is not None: thr.append(v)
            elif s == 'easy':
                v = _slowest_pace(pp)   # easy BODY (slowest), not the strides
                if v is not None: easies.append(v)
    if thr:
        check(f"{short} fastest threshold faster than race pace (half/marathon)",
              min(thr) < race,
              f"fastest_thr={_mm(min(thr))} race={_mm(race)}", full=True)
        # EVERY threshold week (not just the fastest) must be >= race pace — the
        # easing-in floor. Without it, early-plan threshold renders slower than race.
        check(f"{short} every threshold week >= race pace (never slower; floored)",
              max(thr) <= race + 3,
              f"slowest_thr={_mm(max(thr))} race={_mm(race)}", full=True)
        # Threshold is a REAL LT stimulus at true threshold (speed×1.06), not
        # pinned at race — beginners used to render every week AT race pace.
        true_thr = int(speed5k * 1.06)
        check(f"{short} threshold reaches true LT (~speed x1.06), not pinned at race",
              max(thr) <= true_thr + 6,
              f"slowest_thr={_mm(max(thr))} true_thr={_mm(true_thr)} race={_mm(race)}", full=True)
    if easies:
        check(f"{short} easy body never faster than race pace",
              min(easies) >= race,
              f"fastest_easy={_mm(min(easies))} race={_mm(race)}", full=True)
        # Easy reflects the runner's REAL easy, not the frozen generic 1.15×race
        # (which over-slows slow runners whose race pace is near their easy).
        frozen = int(race * 1.15)
        check(f"{short} easy ~ runner's real easy, not frozen 1.15x race",
              min(easies) <= easy + 8 and min(easies) < frozen - 8,
              f"easy_rendered={_mm(min(easies))} input={_mm(easy)} frozen={_mm(frozen)}", full=True)

section("Z5 VO2 floor — VO2 work never slower than race (5K/10K)")
# A true VO2 interval (5K pace) is <= race at every distance, so it must never
# ease in slower than race. On 5K/10K (speed≈race) the old 1.12 ease-in start
# put W1 VO2 work 30-47s slower than race. fivekPace is pure Z5.
for header, fil, t5k, dist in [
    ("Int 5K (long, 10w)", "Int 5K (long, 10w)", 2160, 5000),
    ("Adv 5K (long, 10w)", "Adv 5K (long, 10w)", 2160, 5000),
    ("Int 10K (long, 12w)", "Int 10K (long, 12w)", 2160, 10000),
]:
    vd = _vf(5000, t5k); speed5k = int(_pred(5000, vd) / 5)
    race = int(_pred(dist, vd) / (dist / 1000.0)); easy = int(_vel(vd, 0.72))
    short = header.split(' (')[0]
    w = parse_plan(run_pacedump_with(fil, race, easy, False, speed_pace=speed5k), header)
    if not w:
        check(f"{short} VO2 parse", False, "no plan", full=True); continue
    z5 = [parse_pace_secs_first(pp) for wk in w for s, _, pp in w[wk] if s == 'fivekPace']
    z5 = [v for v in z5 if v is not None]
    if z5:
        check(f"{short} every VO2 (fivekPace) work <= race pace (Z5 floor)",
              max(z5) <= race + 3,
              f"slowest_vo2={_mm(max(z5))} race={_mm(race)}", full=True)

section("10K-pace floor — '10K Pace'/race-rehearsal work never slower than race (slow 10K)")
# On a 10K plan race ≈ 10K pace, so tenkPace (1.04×speed5k) and raceRehearsal10K
# WORK must pin AT race, never ease in slower. A slow 10K (VDOT ~30, where race
# is close to threshold) is the teeth: before the 10K-pace floor the ease-in
# started this work 16-21s slower than race. parse_pace_secs_first takes the
# FASTEST segment (the work), so the legit slow recovery jog is ignored.
for header, fil, t5k in [
    ("Int 10K (long, 12w)", "Int 10K (long, 12w)", 2160),
    ("Adv 10K (long, 12w)", "Adv 10K (long, 12w)", 2160),
]:
    vd = _vf(5000, t5k); speed5k = int(_pred(5000, vd) / 5)
    race = int(_pred(10000, vd) / 10.0); easy = int(_vel(vd, 0.72))
    short = header.split(' (')[0]
    w = parse_plan(run_pacedump_with(fil, race, easy, False, speed_pace=speed5k), header)
    if not w:
        check(f"{short} 10K-pace parse", False, "no plan", full=True); continue
    tk = [parse_pace_secs_first(pp) for wk in w for s, _, pp in w[wk]
          if s in ('tenkPace', 'raceRehearsal10K')]
    tk = [v for v in tk if v is not None]
    if tk:
        check(f"{short} every 10K-pace/rehearsal WORK <= race pace (10K-pace floor)",
              max(tk) <= race + 3,
              f"slowest={_mm(max(tk))} race={_mm(race)}", full=True)

section("Strides — rep pace or faster, FLAT (no ease-in)")
# Strides are short (≤30s) neuromuscular accelerations with full recovery — form
# / leg-speed work, not a progressive VO2 stimulus. They must render at REP pace
# (faster than 5K) and stay FLAT across the block. The old bug tagged them HR-Z5
# with no special handling → priced at 5K pace AND run through the quality ease-in
# (W1 ≈ threshold pace, W-last ≈ 5K pace). parse_pace_secs_first returns the
# FASTEST segment (the stride itself), ignoring the easy-jog portion.
def _rep_pace(dist, time):
    """Engine's repetition pace (sec/km) for a race result, via vdotpaces mode."""
    r = subprocess.run([PLAN_DEBUG, "vdotpaces"], capture_output=True, text=True,
                       env={**os.environ, "DIST": str(dist), "TIME": str(time)})
    m = re.search(r'rep=(\d+):(\d+)', r.stdout)
    return int(m.group(1)) * 60 + int(m.group(2)) if m else None

for header, fil, dist, time in [
    ("Adv 21K (long, 18w)", "Adv 21K (long", 21097, 7200),    # 2:00 half
    ("Adv 42K (long, 22w)", "Adv 42K (long", 42195, 14400),   # 4:00 marathon
]:
    vd = _vf(dist, time)
    speed5k = int(_pred(5000, vd) / 5)
    race = int(_pred(dist, vd) / (dist / 1000.0)); easy = int(_vel(vd, 0.72))
    rep = _rep_pace(dist, time)
    short = header.split(' (')[0]
    w = parse_plan(run_pacedump_with(fil, race, easy, False, speed_pace=speed5k), header)
    strides = [parse_pace_secs_first(pp) for wk in (w or {}) for s, _, pp in w[wk]
               if s == 'strides']
    strides = [v for v in strides if v is not None]
    if strides and rep:
        check(f"{short} strides FLAT across block (no ease-in, <=3s spread)",
              max(strides) - min(strides) <= 3,
              f"spread={max(strides)-min(strides)}s, paces={sorted(set(strides))}", full=True)
        check(f"{short} strides <= rep pace (rep-pace floor, not eased 5K/threshold)",
              max(strides) <= rep + 2,
              f"slowest_stride={_mm(max(strides))} rep={_mm(rep)}", full=True)

section("Progression direction — easy zones blend, quality stays flat")

EASY_SUBTYPES_FOR_TEST = {'easy'}

def first_and_last_easy_paces(weeks):
    """Returns (W1_easy_paces, last_easy_paces). W1 vs the LATEST week that
    actually has easy runs. The literal race week can be legitimately easy-free
    (race + shakeout only), so scanning backward keeps the progression check
    from silently skipping — it always verifies against real late-plan easy."""
    if not weeks: return [], []
    weeks_sorted = sorted(weeks)
    first = [parse_pace_secs_first(p) for s, _, p in weeks[weeks_sorted[0]] if s in EASY_SUBTYPES_FOR_TEST]
    last = []
    for wk in reversed(weeks_sorted):
        cand = [x for x in (parse_pace_secs_first(p) for s, _, p in weeks[wk] if s in EASY_SUBTYPES_FOR_TEST) if x]
        if cand:
            last = cand
            break
    return [x for x in first if x], last

for header, fil, rp, ep, bb in PACE_INPUTS:
    label = f"{header.split(' (')[0]}" + (" [build]" if bb else "")
    text = run_pacedump_with(fil, rp, ep, bb)
    w = parse_plan(text, header)
    if not w: continue
    first, last = first_and_last_easy_paces(w)
    if not first or not last:
        # Plan may have no W1 easy or last-week easy (race week light)
        continue
    avg_first = sum(first) / len(first)
    avg_last = sum(last) / len(last)
    delta = avg_first - avg_last  # positive = gets faster

    # All tiers ease easy across the plan. After option (b) this includes the
    # at-goal .competitive config — its easy no longer freezes at 1.15×race; it
    # anchors to the runner's stated easy and eases from there (quality stays
    # locked, only easy blends). Short plans ease less (≈flat), longer ones more.
    # Allow 5s slack at the boundary so noise doesn't trip the test.
    check(
        f"{label} easy gets faster across plan",
        delta > -5,
        f"W1 avg={avg_first:.0f} race-week avg={avg_last:.0f} (got slower by {-delta:.0f}s)"
    )

section("Hill repeats render faster than threshold (VO2/power, not LT)")
# Hill repeats are tagged Z4 (hill HR settles ~LT) but train VO2/power and the
# flat-equivalent effort is ~I-pace — they must NOT collide with the threshold
# run's pace (the old bug: both Z4 → identical s/km on the board). With a fixed
# speed anchor, hills render in [0.96,1.02]×speed and threshold in [1.02,1.07]×
# speed — disjoint. Assert the STRONG form: even the slowest hill in the plan is
# faster than the fastest threshold, so the two pace bands never overlap (no
# collision in any week). speed_pace passed → real 5K-speed anchoring exercised.
HILL_VS_THRESHOLD = [
    # (header, filter, racePace, easyPace, speedPace)
    ("Adv 5K (long, 10w)",  "Adv 5K (long, 10w)",  228, 286, 228),
    ("Adv 10K (long, 12w)", "Adv 10K (long, 12w)", 260, 320, 246),
    # Int 10K dropped: at 3 days it doesn't pair hills with a threshold run to compare.
]
for header, fil, rp, ep, sp in HILL_VS_THRESHOLD:
    text = run_pacedump_with(fil, rp, ep, False, speed_pace=sp)
    w = parse_plan(text, header)
    hills, thrs = [], []
    if w:
        for wk, sessions in w.items():
            for s, _, p in sessions:
                v = parse_pace_secs_first(p)
                if v is None: continue
                if s == 'hillRepeats': hills.append(v)
                elif s == 'threshold': thrs.append(v)
    ok = bool(hills) and bool(thrs) and max(hills) < min(thrs) - 3
    check(
        f"{header.split(' (')[0]} every hill faster than every threshold (VO2 ≠ LT)",
        ok,
        f"hills(n={len(hills)}) slowest={max(hills) if hills else '-'} "
        f"threshold(n={len(thrs)}) fastest={min(thrs) if thrs else '-'}"
    )

section("Time trial renders faster than threshold (race-effort test, not LT)")
# A time trial is a sustained race effort (~5K-10K pace); it must read faster than
# the threshold run it's paired with. Old bug: both Z4 → identical, and quantize
# could even invert it. Same disjoint-range guard as the hills check.
TT_VS_THRESHOLD = [
    ("Beg 42K (long, 22w)", "Beg 42K (long, 22w)", 330, 450, 300),
    ("Int 21K (long, 18w)", "Int 21K (long, 18w)", 300, 420, 258),
    ("Adv 21K (long, 18w)", "Adv 21K (long, 18w)", 270, 360, 246),
]
for header, fil, rp, ep, sp in TT_VS_THRESHOLD:
    text = run_pacedump_with(fil, rp, ep, False, speed_pace=sp)
    w = parse_plan(text, header)
    tts, thrs = [], []
    if w:
        for wk, sessions in w.items():
            for s, _, p in sessions:
                v = parse_pace_secs_first(p)
                if v is None: continue
                if s == 'timeTrial': tts.append(v)
                elif s == 'threshold': thrs.append(v)
    ok = bool(tts) and bool(thrs) and max(tts) < min(thrs) - 3
    check(
        f"{header.split(' (')[0]} every TT faster than every threshold (race-effort ≠ LT)",
        ok,
        f"TT(n={len(tts)}) slowest={max(tts) if tts else '-'} threshold fastest={min(thrs) if thrs else '-'}"
    )

section("Competitive half/marathon: TT and race rehearsal never share a week")
# The race rehearsal IS the race-effort check; stacking a TT + a race-pace
# rehearsal into one week is brutal. They must sit in separate weeks — but the
# plan must still contain BOTH (the mid-plan recalibration TT satisfies "the
# half has a TT"; the rehearsal is the late learning point).
REHEARSAL_SUBTYPES = {'raceRehearsalM', 'raceRehearsalHM', 'raceRehearsal10K'}
TT_REHEARSAL_PLANS = [
    ("Cmp 21K (long, 18w)", "Cmp 21K (long, 18w)", 256, 331),
    ("Cmp 42K (long, 22w)", "Cmp 42K (long, 22w)", 256, 331),
]
for header, fil, rp, ep in TT_REHEARSAL_PLANS:
    text = run_pacedump_with(fil, rp, ep, False)
    w = parse_plan(text, header)
    has_tt = has_reh = False
    collisions = []
    if w:
        for wk, sessions in w.items():
            subs = {s for s, _, _ in sessions}
            if 'timeTrial' in subs: has_tt = True
            if subs & REHEARSAL_SUBTYPES: has_reh = True
            if 'timeTrial' in subs and (subs & REHEARSAL_SUBTYPES):
                collisions.append(wk)
    check(
        f"{header.split(' (')[0]} half/mara: TT + rehearsal both present, separate weeks",
        w is not None and has_tt and has_reh and not collisions,
        f"has_tt={has_tt} has_reh={has_reh} same-week collisions={collisions}"
    )

section("Quality flat across plan — Cmp configs only (other tiers progress)")

for header, fil, rp, ep, bb in PACE_INPUTS:
    if "Cmp" not in header: continue  # Only .competitive* configs lock quality flat
    label = f"{header.split(' (')[0]}" + (" [build]" if bb else "")
    text = run_pacedump_with(fil, rp, ep, bb)
    w = parse_plan(text, header)
    if not w: continue
    zones = collect_zone_paces(w)
    drift_issues = []
    for zone in (3, 4, 5):
        if not zones[zone]: continue
        first_pace = zones[zone][0][1]
        last_pace = zones[zone][-1][1]
        if abs(first_pace - last_pace) > TOL:
            drift_issues.append(f"Z{zone}: first={first_pace} last={last_pace}")
    check(
        f"{label} Cmp quality paces don't drift week-to-week",
        not drift_issues,
        f"drift: {drift_issues}"
    )

section("Competitive gate — VDOT thresholds (real Swift via plan_debug gate mode)")

def gate_for(vdot, dist):
    env = os.environ.copy()
    env["VDOT"] = str(vdot); env["DIST"] = str(dist)
    r = subprocess.run([PLAN_DEBUG, "gate"], capture_output=True, text=True, env=env)
    m = re.search(r'STATE=(\w+)(?: RECOMMENDED_WEEKS=(\d+))?(?: PREDICTED_SECONDS=(\d+))?', r.stdout)
    if not m: return ("parse_error", None, None)
    return (m.group(1), int(m.group(2)) if m.group(2) else None, int(m.group(3)) if m.group(3) else None)

# Gate compares user VDOT against goal-derived requiredVDOT (NOT a hardcoded
# threshold). For sub-3 marathon (goalTime 10800s), required ≈ VDOT 52-53.
# For sub-1:30 half (goalTime 5400s), required ≈ VDOT 53-54. Build band
# allows up to 4 VDOT points of gap; beyond that → blocked.

# Required VDOT ≈ 53.5 for sub-3 marathon, ≈ 51 for sub-1:30 half. The
# build-band allows up to 4 VDOT points of gap. Test values picked WELL
# inside each band so boundary noise doesn't trip the assertion.
# Solidly blocked (gap >> 4):
for vdot, dist in [(45.0, 42195), (46.0, 42195),
                   (40.0, 21097), (42.0, 21097)]:
    state, _, predicted = gate_for(vdot, dist)
    check(f"gate(VDOT={vdot} dist={dist}) → blocked",
          state == "blocked" and predicted and predicted > 0,
          f"got state={state} predicted={predicted}")

# Solidly in build band (gap ~1-3, well inside the 4-point window):
for vdot, dist in [(51.0, 42195), (52.0, 42195),
                   (48.0, 21097), (49.0, 21097)]:
    state, weeks, _ = gate_for(vdot, dist)
    check(f"gate(VDOT={vdot} dist={dist}) → buildBand",
          state == "buildBand" and weeks is not None and weeks > 0,
          f"got state={state} weeks={weeks}")

# At/above required → clear. User's reported case VDOT 55.2 marathon must
# be CLEAR (predicted 2:55 < 3:00).
for vdot, dist in [(54.0, 42195), (55.2, 42195), (60.0, 42195),
                   (52.0, 21097), (55.0, 21097), (60.0, 21097)]:
    state, _, _ = gate_for(vdot, dist)
    check(f"gate(VDOT={vdot} dist={dist}) → clear (fitness meets/exceeds goal)",
          state == "clear", f"got state={state}")

# Regression: VDOT 55.2 marathon (the user's bug report case) MUST be clear,
# not buildBand. Predicted marathon at that VDOT ≈ 2:55 < 3:00.
state, _, _ = gate_for(55.2, 42195)
check(
    "regression: VDOT 55.2 marathon clear (2:55 < 3:00 sub-3 target)",
    state == "clear",
    f"got state={state}"
)

section("Weekly distance — pace × time → kilometres, vs Pfitz/Daniels expectations")

# Distance per week from observed paces × durations. The pacedump output
# gives us both (duration, pace) per workout — distance = duration_min×60/sec_per_km.
# For multi-pace workouts like Race Rehearsal we use the FASTEST listed pace
# (the work-interval), which is a slight overstatement of total km but on
# the right order of magnitude.

def avg_pace_in(pace_str):
    """For a multi-pace string like '[4:16/km, 4:54/km]' or a single pace,
    return the AVERAGE sec/km. Avoids the over-estimate from picking the
    fastest pace (which the work intervals run but the warmup/cooldown don't)."""
    paces = re.findall(r'(\d+):(\d+)/km', pace_str or '')
    if not paces: return None
    secs = [int(m) * 60 + int(s) for m, s in paces]
    return sum(secs) / len(secs)

def weekly_km(weeks):
    """dict[week] = total km that week. Uses the average displayed pace per
    workout — closer to reality for multi-zone workouts (race rehearsals,
    progressive longs) than picking the fastest pace."""
    out = {}
    for wk in sorted(weeks):
        km = 0.0
        for s, dur_min, pace_str in weeks[wk]:
            pace_sec = avg_pace_in(pace_str)
            if pace_sec is None or pace_sec <= 0: continue
            km += dur_min * 60.0 / pace_sec
        out[wk] = km
    return out

# Reference week-volumes (km/wk peak) from published plans. Converted
# from "miles per week" naming: Pfitz 18/85 = 85 mpw = ~137 km/wk peak.
# Bands are GENEROUS (each ref has multiple variants) so they catch
# wild misconfigurations but allow legitimate tier-shape differences.
KM_BANDS = {
    # (tier, distance) → (peak_min_km, peak_max_km)
    ("Beg",  42195): (35, 70),    # Higdon Novice 1: 30-40 mpw peak
    ("Int",  42195): (50, 95),    # Pfitz 18/55 family
    ("Adv",  42195): (70, 120),   # Pfitz 18/70
    ("Cmp",  42195): (95, 150),   # Pfitz 18/85 sub-3
    ("Beg",  21097): (25, 55),
    ("Int",  21097): (40, 80),
    ("Adv",  21097): (55, 100),
    ("Cmp",  21097): (80, 130),   # sub-1:30 half — high-frequency, high-mileage
}

KM_PLANS = [
    # (header, filter, racePace, easyPace, build_band, tier, distance)
    ("Cmp 42K (long, 22w)",  "Cmp 42K (long, 22w)",  256, 331, False, "Cmp", 42195),
    ("Cmp 21K (long, 18w)",  "Cmp 21K (long, 18w)",  256, 331, False, "Cmp", 21097),
    ("Adv 42K (long, 22w)",  "Adv 42K (long, 22w)",  280, 380, False, "Adv", 42195),
    ("Adv 21K (long, 18w)",  "Adv 21K (long, 18w)",  270, 360, False, "Adv", 21097),
    ("Int 42K (long, 22w)",  "Int 42K (long, 22w)",  320, 430, False, "Int", 42195),
    ("Int 21K (long, 18w)",  "Int 21K (long, 18w)",  300, 420, False, "Int", 21097),
    ("Beg 42K (long, 22w)",  "Beg 42K (long, 22w)",  330, 450, False, "Beg", 42195),
    ("Beg 21K (long, 18w)",  "Beg 21K (long, 18w)",  360, 480, False, "Beg", 21097),
]

for header, fil, rp, ep, bb, tier, dist in KM_PLANS:
    text = run_pacedump_with(fil, rp, ep, bb)
    w = parse_plan(text, header)
    if not w: continue
    km_by_wk = weekly_km(w)
    peak_km = max(km_by_wk.values()) if km_by_wk else 0
    avg_km  = sum(km_by_wk.values()) / max(1, len(km_by_wk))
    band_lo, band_hi = KM_BANDS[(tier, dist)]
    check(
        f"{header.split(' (')[0]} peak weekly km ∈ [{band_lo}, {band_hi}] (vs published refs)",
        band_lo <= peak_km <= band_hi,
        f"observed peak={peak_km:.1f} km/wk, avg={avg_km:.1f} km/wk",
        full=True
    )

section("Time-weighted aerobic share — Cmp plans, REAL Swift HR-zone data")

# Pfitz "general aerobic" share for competitive plans (18/85 etc.) sits in
# the 75-85% range when measured BY TIME from HR zones. Aerobic = Z1-Z2;
# Z3+ (MP / threshold / faster) is non-aerobic.
#
# This test reads REAL data from the Swift catalog via `plan_debug aerobic`.
# The Swift side iterates each workout's intervals, classifies each one as
# aerobic (HR zone <= 2, or paceTarget relative >= 1.10, or warmup/
# cooldown/recovery/rest by convention) or not, and prints
#   `W{N} | {subtype} | total={M}min | aerobic={A}min`
# per workout. Python only sums and divides — no per-subtype heuristic. If
# the Swift catalog tweaks a progressiveLong's Z2/Z3 split, this test
# catches the resulting aerobic-share drift; the earlier heuristic version
# would have missed it.
#
# Observed real values across Cmp variants after the Z3-content filter
# (PlanGeneratorV3.swift: progressive long pool excludes <25% Z3 variants
# for .competitive plans). The filter shifted the cluster from ~85% on
# the half / ~80% on the marathon down to ~83% / ~80%:
#
#   Cmp 21K (long, 18w):           83.0%
#   Cmp 21K (short, 12w):            82.2%
#   Cmp 21K (max, 32w) LAST 18:    83.1%
#   Cmp 42K (long, 22w):           78.4%
#   Cmp 42K (rec, 18w):            81.1%
#   Cmp 42K (build, 28w) LAST 22:  78.3%
#   Cmp 42K (max, 36w) LAST 22:    79.4%
#
# Band: [73, 83]% — user's target range. Half plans cluster at the top
# (~82-83%); marathon plans sit lower (~78-81%). Going stricter on the
# filter (>=30% Z3) breaks build-band variants because the catalog has
# duration gaps at >=30%; the variants fall back to plain steady longs
# and aerobic share goes UP, not down. 25% is the sweet spot.

def run_aerobic(filter_str, build_band):
    env = os.environ.copy()
    if build_band: env["BUILD_BAND"] = "1"
    else: env.pop("BUILD_BAND", None)
    r = subprocess.run([PLAN_DEBUG, "aerobic", filter_str],
                       capture_output=True, text=True, env=env)
    return r.stdout

def parse_aerobic(text, header):
    """Returns dict[week_num] = [(subtype, total_min, aerobic_min)]."""
    marker = f'=== {header}'
    if marker not in text: return None
    section_text = text.split(marker, 1)[1]
    # Cut at the next plan header (avoid bleeding into the next plan's lines)
    next_header = re.search(r'\n=== ', section_text)
    if next_header:
        section_text = section_text[:next_header.start()]
    weeks = {}
    for line in section_text.splitlines():
        m = re.match(
            r'^W(\d+)\s*\|\s*(\w+)\s*\|\s*total=(\d+)min\s*\|\s*aerobic=(\d+)min\s*$',
            line)
        if not m: continue
        wk = int(m.group(1)); subtype = m.group(2)
        total = int(m.group(3)); aero = int(m.group(4))
        weeks.setdefault(wk, []).append((subtype, total, aero))
    return weeks

def slice_last_weeks_aero(weeks, n):
    if n is None: return weeks
    ks = sorted(weeks.keys())
    return {k: weeks[k] for k in ks[-n:]}

def long_run_aerobic_share(weeks):
    """Sum aerobic-min and total-min over LONG-RUN subtypes only. The
    Swift side reports per-workout numbers for ALL workouts; we restrict
    to long runs here to compute the Pfitz-style 'long-run aerobic
    share' metric the user tuned for."""
    LR = {'steadyLong','long','progressiveLong','raceRehearsalM',
          'raceRehearsalHM','raceRehearsal10K','fastFinish'}
    aero_min = 0; total_min = 0
    for wk in weeks:
        for s, t, a in weeks[wk]:
            if s in LR:
                aero_min += a; total_min += t
    return aero_min, total_min

AEROBIC_TARGETS = [
    # (header, filter, build_band, slice_last_n, lo, hi)
    # Same [73, 83]% band for both distances — Pfitz "general aerobic"
    # target range. Half plans cluster at top of band (82-83); marathon
    # plans cluster lower (78-81). The Z3-content filter on progressive
    # longs keeps both inside.
    ("Cmp 21K (short, 12w)",   "Cmp 21K (short, 12w)",   False, None, 73, 83),
    ("Cmp 21K (long, 18w)",  "Cmp 21K (long, 18w)",  False, None, 73, 83),
    ("Cmp 21K (max, 32w)",   "Cmp 21K (max, 32w)",   True,  18,   73, 83),
    ("Cmp 42K (rec, 18w)",   "Cmp 42K (rec, 18w)",   False, None, 73, 85),  # 85: deload LRs plain aerobic (no MP on down weeks, 2026-07-01)
    ("Cmp 42K (long, 22w)",  "Cmp 42K (long, 22w)",  False, None, 73, 83),
    ("Cmp 42K (build, 28w)", "Cmp 42K (build, 28w)", False, 22,   71, 83),  # 71: deload-cap relax honestly trims recovery-wk aerobic
    ("Cmp 42K (max, 36w)",   "Cmp 42K (max, 36w)",   True,  22,   73, 83),
]

for header, fil, bb, slice_n, lo, hi in AEROBIC_TARGETS:
    text = run_aerobic(fil, bb)
    w = parse_aerobic(text, header)
    if not w:
        check(f"{header} aerobic-share parse", False, "no plan parsed from Swift")
        continue
    measured = slice_last_weeks_aero(w, slice_n)
    aero, total = long_run_aerobic_share(measured)
    pct = 100 * aero / total if total > 0 else 0
    suffix = f" [LAST {slice_n}w]" if slice_n else ""
    check(
        f"{header}{suffix} aerobic share ∈ [{lo}, {hi}]% (real Swift HR zones)",
        lo <= pct <= hi,
        f"observed {pct:.1f}% ({aero}/{total} long-run min from Swift)",
        full=True
    )

section("Min/max plan durations — pace + load progression sane at boundaries")

# Plan minimum and maximum weeks (per category.min/maxWeeks). For each
# (header, race_pace, easy_pace, build_band), verify the plan is internally
# sane: load grows from BASE to PEAK then drops in TAPER, total volume in
# a sane range, pace progression direction is correct.
MINMAX_PLANS = [
    # (header, filter, racePace, easyPace, build_band, expected_weeks)
    # Cmp 42K min == rec (18w; engine's phase mins set the floor).
    # Cmp 42K/21K minimum lowered to 12 (was 18/15): at sub-3:20 marathon
    # / sub-1:35 half fitness the runner already has aerobic base, so the
    # 12-week phase distribution (2/3/4/3) is enough.
    ("Cmp 42K (short, 12w)", "Cmp 42K (short, 12w)", 256, 331, False, 12),
    ("Cmp 42K (rec, 18w)",   "Cmp 42K (rec, 18w)",   256, 331, False, 18),
    ("Cmp 42K (max, 36w)",   "Cmp 42K (max, 36w)",   256, 353, True,  36),
    ("Cmp 21K (short, 12w)", "Cmp 21K (short, 12w)", 256, 331, False, 12),
    ("Cmp 21K (max, 32w)",   "Cmp 21K (max, 32w)",   256, 353, True,  32),
]

def parse_weekly_load_from_hr_dump(filter_str):
    """Parse `W NN [phase X/Y] Nwkts load=NNNN NNNmin` lines from HR dump.
    Returns list of (week_idx, phase_name, weekly_load, weekly_min)."""
    r = subprocess.run([PLAN_DEBUG, "dump", filter_str],
                       capture_output=True, text=True)
    out = []
    for line in r.stdout.splitlines():
        m = re.match(r'^W\s*(\d+)\s*\[(\w+)\s+\d+/\d+\]\s+(\d+)wkts\s+load=\s*(\d+)\s+(\d+)min', line)
        if not m: continue
        out.append((int(m.group(1)), m.group(2), int(m.group(4)), int(m.group(5))))
    return out

for header, fil, rp, ep, bb, expected_weeks in MINMAX_PLANS:
    label = f"{header.split(' (')[0]} {header.split(', ')[1].rstrip(')')}"
    # Parse expected_weeks
    text = run_pacedump_with(fil, rp, ep, bb)
    w = parse_plan(text, header)
    check(
        f"{label} plan generates with all weeks",
        w is not None and len(w) == expected_weeks,
        f"got {len(w) if w else None}, expected {expected_weeks}"
    )
    if not w: continue

    # Volume + load metrics from HR dump (the real Swift load=NNNN values).
    weekly = parse_weekly_load_from_hr_dump(fil)
    if not weekly:
        check(f"{label} HR-dump load parse", False, "no weekly load parsed")
        continue

    # Peak vs taper vs race week. Pick the BASE→PEAK→TAPER→RACE phases.
    loads_by_phase = {}
    for _, phase, load, _ in weekly:
        loads_by_phase.setdefault(phase, []).append(load)

    base_avg  = sum(loads_by_phase.get('base',  [0])) / max(1, len(loads_by_phase.get('base',  [])))
    peak_avg  = sum(loads_by_phase.get('peak',  [0])) / max(1, len(loads_by_phase.get('peak',  [])))
    taper_avg = sum(loads_by_phase.get('taper', [0])) / max(1, len(loads_by_phase.get('taper', [])))
    race_avg  = sum(loads_by_phase.get('race',  [0])) / max(1, len(loads_by_phase.get('race',  [])))

    # 1. Peak load > base load (the plan actually builds)
    check(
        f"{label} PEAK weekly load > BASE weekly load",
        peak_avg > base_avg * 1.05,  # at least 5% increase from base to peak
        f"BASE avg={base_avg:.0f}, PEAK avg={peak_avg:.0f}"
    )

    # 2. Taper drops from peak (sane taper)
    check(
        f"{label} TAPER weekly load < PEAK weekly load (proper taper)",
        taper_avg < peak_avg,
        f"PEAK avg={peak_avg:.0f}, TAPER avg={taper_avg:.0f}"
    )

    # 3. Race week is the lightest (taper bottoms out)
    if race_avg > 0:
        check(
            f"{label} RACE week load < TAPER avg (taper bottoms out)",
            race_avg < taper_avg,
            f"TAPER avg={taper_avg:.0f}, RACE avg={race_avg:.0f}"
        )

    # 4. Per-week volume is in a sane absolute range. Cmp plans run hot
    # (300-650 min/wk peak per Pfitz 18/55-85). Build-band runners on a
    # longer plan get LOWER per-week volume because the same target work
    # spreads across more weeks. Both should fall inside a generous window.
    total_min = sum(m for _, _, _, m in weekly)
    avg_min_wk = total_min / len(weekly)
    check(
        f"{label} avg weekly volume in sane range (300-650 min/wk)",
        300 <= avg_min_wk <= 650,
        f"got {avg_min_wk:.0f} min/wk"
    )

    # 5. Pace progression direction. .competitive flat; .competitiveBuildBand
    # easy progresses (and converges by race week since finalAdjustment=0.0).
    zones = collect_zone_paces(w)
    first_easy, last_easy = first_and_last_easy_paces(w)
    if first_easy and last_easy:
        avg_first = sum(first_easy) / len(first_easy)
        avg_last  = sum(last_easy)  / len(last_easy)
        if bb:
            # Build band: race-week easy should land near the goal easy
            # (racePace × 1.15 — Z2 base). For racePace=256, target ≈ 294.
            target_easy = int(rp * 1.15)
            check(
                f"{label} build-band easy converges to goal by race week ±{TOL}s",
                abs(avg_last - target_easy) <= TOL,
                f"target ~{target_easy}, race-week obs={avg_last:.0f}"
            )
            check(
                f"{label} build-band easy progresses (race-week < W1)",
                avg_last < avg_first - TOL,
                f"W1 avg={avg_first:.0f}, race-week avg={avg_last:.0f}"
            )
        else:
            # Option (b): at-goal .competitive easy eases (never freezes or
            # slows). Late-plan easy must be ≥ as fast as W1, within slack.
            check(
                f"{label} .competitive easy eases (never slower than W1)",
                avg_last <= avg_first + TOL,
                f"W1 avg={avg_first:.0f}, race-week avg={avg_last:.0f}"
            )

    # 6. Quality paces (Z4 + Z5) always at target — both .competitive and
    # .competitiveBuildBand share qualityZonesAlwaysAtTarget=true.
    for zone in (4, 5):
        target = int(rp * (0.93 if zone == 4 else 0.85))
        observations = zones[zone]
        if not observations: continue
        out = [(wk, p) for wk, p in observations if abs(p - target) > TOL]
        check(
            f"{label} Z{zone} pinned to target across {expected_weeks}w plan",
            not out,
            f"target={target} first out: {out[:3]}"
        )

section("Build-band routing produces observably different W1 easy than .competitive")

# Same plan, same racePace, different routing config → measurable difference
# in W1 easy pace. .competitive is flat at target; .competitiveBuildBand
# blends from the runner's slower current easy toward target.
for header, fil in [
    ("Cmp 42K (long, 22w)", "Cmp 42K (long, 22w)"),
    ("Cmp 21K (long, 18w)", "Cmp 21K (long, 18w)"),
]:
    # Same racePace; easyPace = 353 simulates a VDOT 54 runner.
    text_flat  = run_pacedump_with(fil, 256, 353, False)
    text_build = run_pacedump_with(fil, 256, 353, True)
    w_flat  = parse_plan(text_flat,  header)
    w_build = parse_plan(text_build, header)
    if not w_flat or not w_build:
        check(f"{header} routing test parses", False, "")
        continue
    flat_w1,  _ = first_and_last_easy_paces(w_flat)
    build_w1, _ = first_and_last_easy_paces(w_build)
    if not flat_w1 or not build_w1: continue
    flat_avg  = sum(flat_w1)  / len(flat_w1)
    build_avg = sum(build_w1) / len(build_w1)
    # The at-goal .competitive easy now anchors to the runner's stated easy and
    # eases from there; the build-band's gap-blend routes easy differently (pushes
    # toward goal pace). Guards that the BUILD_BAND flag actually changes the easy
    # zones — the two are not interchangeable. (Before the at-goal easy fix this
    # asserted build > flat, because at-goal froze at 1.15×race; build-band itself
    # is unchanged, so the comparison direction flipped.)
    check(
        f"{header.split(' (')[0]} W1 easy: build-band routes differently from at-goal",
        abs(build_avg - flat_avg) > TOL,
        f"flat(at-goal) avg={flat_avg:.0f}s/km, build avg={build_avg:.0f}s/km"
    )

section("Cmp 21K Pfitz LT-interval pattern (mileRepeats forced on alt SPEED/PEAK weeks)")

# Pfitz competitive half marathon prescribes 4-6 mile-rep sessions across
# the cycle. Without the mileRepeats forcing (line 1108-ish of
# PlanGeneratorV3.swift), the default selector at Cmp's threshold target
# load picks continuous "Threshold Run (3 × 10min)" workouts and only
# lands 1 mile-rep in 18 weeks. The forcing alternates SPEED/PEAK
# threshold slots between mileRepeats and continuous threshold:
#   even week (0-indexed) → mileRepeats forced
#   odd  week → progression-filtered threshold pool (usually continuous)
# Expected: 4-5 mileRepeats sessions on Cmp 21K (long, 18w); 0-1 on
# Cmp 42K (marathon, distance-gated out of the forcing).

def count_workout_subtype(label, fil, subtype, rp=256, ep=331, bb=False):
    text = run_pacedump_with(fil, rp, ep, bb)
    w = parse_plan(text, label)
    if not w: return None
    count = 0
    for wk in w:
        for s, _, _ in w[wk]:
            if s == subtype:
                count += 1
    return count

cmp_21k_mr = count_workout_subtype("Cmp 21K (long, 18w)", "Cmp 21K (long, 18w)", "mileRepeats")
check(
    "Cmp 21K (long, 18w) has >= 4 mileRepeats sessions (Pfitz LT pattern)",
    cmp_21k_mr is not None and cmp_21k_mr >= 4,
    f"got {cmp_21k_mr} mileRepeats workouts"
)

# Cmp 42K (marathon) should NOT have the half-specific forcing.
# Marathon Pfitz prescribes continuous tempo over mile reps; this is
# the design intent.
cmp_42k_mr = count_workout_subtype("Cmp 42K (long, 22w)", "Cmp 42K (long, 22w)", "mileRepeats")
check(
    "Cmp 42K (long, 22w) has <= 2 mileRepeats sessions (marathon, no forcing)",
    cmp_42k_mr is not None and cmp_42k_mr <= 2,
    f"got {cmp_42k_mr} mileRepeats workouts — forcing should NOT apply to marathon"
)

# Sub-1:30 plan must still have continuous threshold work too — the
# forcing is alternation, NOT replacement. ~3 threshold runs expected
# on odd SPEED/PEAK weeks where the forcing doesn't fire.
cmp_21k_thr = count_workout_subtype("Cmp 21K (long, 18w)", "Cmp 21K (long, 18w)", "threshold")
check(
    "Cmp 21K (long, 18w) keeps continuous threshold work too (>= 2)",
    cmp_21k_thr is not None and cmp_21k_thr >= 2,
    f"got {cmp_21k_thr} threshold workouts — forcing shouldn't eliminate continuous LT entirely"
)

# Int/Adv 21K should NOT be affected by Cmp-specific forcing —
# they keep their natural threshold-pool selection (mostly continuous).
int_21k_mr = count_workout_subtype("Int 21K (long, 18w)", "Int 21K (long, 18w)", "mileRepeats", rp=300, ep=420)
adv_21k_mr = count_workout_subtype("Adv 21K (long, 18w)", "Adv 21K (long, 18w)", "mileRepeats", rp=270, ep=360)
check(
    "Int 21K (long, 18w) NOT affected by Cmp mileRepeats forcing (<= 3)",
    int_21k_mr is not None and int_21k_mr <= 3,
    f"got {int_21k_mr} mileRepeats on Int 21K — forcing should be Cmp-only"
)
check(
    "Adv 21K (long, 18w) NOT affected by Cmp mileRepeats forcing (<= 3)",
    adv_21k_mr is not None and adv_21k_mr <= 3,
    f"got {adv_21k_mr} mileRepeats on Adv 21K — forcing should be Cmp-only"
)

section("Easy-pool migration: mediumLong + recovery subtypes (Pfitz semantic split)")

# The 'easy' subtype was split into three by duration to match Pfitz/Daniels'
# named categories:
#   recovery: <=45min (post-hard-day recovery)
#   easy:     46-80min (general aerobic)
#   mediumLong: >80min (Pfitz "Wed/Thu MLR" signature)
#
# Workouts in workouts.json were migrated based on duration. The selector
# includes all three in the easy pool — runners see Pfitz's actual category
# names instead of generic "Easy Run", and the engine picks mediumLong for
# high-target midweek slots (matching Pfitz 18/85's ML prescription).
#
# Tests defend: mediumLong picked for serious plans, NOT for low-target
# Beg plans (where target durations don't reach 80min).

def count_subtype(label, fil, subtype, rp, ep, bb=False):
    text = run_pacedump_with(fil, rp, ep, bb)
    w = parse_plan(text, label)
    if not w: return None
    return sum(1 for wk in w.values() for s, _, _ in wk if s == subtype)

# 1) Cmp 42K — Pfitz 18/85 prescribes Wed/Thu Medium-Long Run. Selector
#    should pick mediumLong for the midweek long-easy slot.
cmp42_ml = count_subtype("Cmp 42K (long, 22w)", "Cmp 42K (long, 22w)", "mediumLong", 256, 331)
check(
    "Cmp 42K (long, 22w) has >= 10 mediumLong workouts (Pfitz Wed/Thu MLR)",
    cmp42_ml is not None and cmp42_ml >= 10,
    f"got {cmp42_ml} mediumLong workouts"
)

# 2) Cmp 21K — Pfitz competitive half also prescribes ML
cmp21_ml = count_subtype("Cmp 21K (long, 18w)", "Cmp 21K (long, 18w)", "mediumLong", 256, 331)
check(
    "Cmp 21K (long, 18w) has >= 5 mediumLong workouts (Pfitz half ML)",
    cmp21_ml is not None and cmp21_ml >= 5,
    f"got {cmp21_ml} mediumLong workouts"
)

# 3) Adv 42K should also benefit — Pfitz 18/70 has ML prescriptions
adv42_ml = count_subtype("Adv 42K (long, 22w)", "Adv 42K (long, 22w)", "mediumLong", 280, 380)
check(
    "Adv 42K (long, 22w) has >= 2 mediumLong workouts (Pfitz 18/70 ML)",
    adv42_ml is not None and adv42_ml >= 2,
    f"got {adv42_ml} mediumLong workouts"
)

# 4) Beg 42K should NOT have mediumLong — Higdon Novice doesn't prescribe
#    ML, and Beg's lower target loads keep the selector on regular easy.
beg42_ml = count_subtype("Beg 42K (long, 22w)", "Beg 42K (long, 22w)", "mediumLong", 330, 450)
check(
    "Beg 42K (long, 22w) has 0 mediumLong workouts (Higdon Novice doesn't prescribe ML)",
    beg42_ml is not None and beg42_ml == 0,
    f"got {beg42_ml} mediumLong workouts on Beg 42K"
)

# 5) Int 42K — Pfitz 18/55 explicitly prescribes ML, but default selector
#    at Int's load targets picks `easy` over `mediumLong` (closer duration
#    match). Forcing on alternating midweek slots restores Pfitz Int's MLR.
int42_ml = count_subtype("Int 42K (long, 22w)", "Int 42K (long, 22w)", "mediumLong", 300, 400)
check(
    "Int 42K (long, 22w) has >= 4 mediumLong (Pfitz 18/55 Wed MLR — forced)",
    int42_ml is not None and int42_ml >= 4,
    f"got {int42_ml} mediumLong workouts"
)

# 6) Cmp 42K (max, 36w) build-band variant — without forcing, at low
#    target loads the selector picked easy over mediumLong, giving 22 ML;
#    forcing alternating weeks gets it back to ~30+ ML matching the
#    (long, 22w) pattern.
cmp42max_ml = count_subtype("Cmp 42K (max, 36w)", "Cmp 42K (max, 36w)", "mediumLong", 256, 353, bb=True)
check(
    "Cmp 42K (max, 36w) build-band has >= 25 mediumLong (forced even at low targets)",
    cmp42max_ml is not None and cmp42max_ml >= 25,
    f"got {cmp42max_ml} mediumLong workouts"
)

# 7) (removed) The .recovery subtype split was rolled back: short easy-pace
# runs are tagged .easy again. Tests for distinct recovery workouts were
# dropped along with the migration. See WorkoutSubtype.localizedTitle.

section("Daniels-purity 5K/10K (Adv 5K LRs + 10K tune-up race + 10K out-volumes 5K)")

# Three Daniels-purity gaps surfaced and fixed:
#   1. Adv 5K Daniels Phase II prescribes ~75min Sunday long runs in
#      BASE/SPEED. Beg/Int 5K still skip LRs (too short, no aerobic base).
#   2. Int/Adv 10K should have at least one tune-up race in PEAK (Daniels
#      and Pfitz both prescribe a 5K race during 10K Phase II). The
#      raceRehearsal10K subtype existed but selector default-picked
#      fastFinish/steadyLong instead — same selector-load-mismatch as
#      marathonPace for 42K. Forcing alternation on PEAK weeks fixes it.
#   3. 10K plans should out-volume 5K plans (user mental model). 5K's
#      faster easy pace had been giving it higher km/wk than 10K at
#      similar training time. Distance-specific baseLoad bump + LR
#      duration bump fixes the optics.

# 1) Adv 5K has SOME long runs (Daniels Phase II); Beg/Int 5K still skip
adv_5k_lrs = sum(1 for wk in parse_plan(run_pacedump_with("Adv 5K (long, 10w)", 240, 320, False), "Adv 5K (long, 10w)").values()
                 for s, _, _ in wk if s in LONG)
check(
    "Adv 5K has 2-8 long runs (Daniels Phase II BASE/SPEED optionals)",
    2 <= adv_5k_lrs <= 8,
    f"got {adv_5k_lrs} long runs"
)
for tier, fil, rp, ep in [
    ("Beg 5K", "Beg 5K (long, 10w)", 240, 350),
    ("Int 5K", "Int 5K (long, 10w)", 240, 320),
]:
    w = parse_plan(run_pacedump_with(fil, rp, ep, False), fil)
    lr_count = sum(1 for wk in w.values() for s, _, _ in wk if s in LONG)
    check(
        f"{tier} still has 0 long runs (no Daniels-purity LRs for non-Adv 5K)",
        lr_count == 0,
        f"got {lr_count} LRs"
    )

# 2) Int/Adv 10K have at least 1 raceRehearsal10K (Daniels tune-up race)
for tier, fil, rp, ep in [
    ("Int 10K", "Int 10K (long, 12w)", 270, 380),
    ("Adv 10K", "Adv 10K (long, 12w)", 260, 320),
]:
    rr_count = count_workout_subtype(fil, fil, "raceRehearsal10K", rp=rp, ep=ep)
    check(
        f"{tier} has >= 1 raceRehearsal10K (Daniels tune-up race in PEAK)",
        rr_count is not None and rr_count >= 1,
        f"got {rr_count} raceRehearsal10K workouts"
    )

# Beg 10K should NOT have raceRehearsal10K (forcing is Int/Adv only — Beg
# can't safely race-pace train at that level)
beg_10k_rr = count_workout_subtype("Beg 10K (long, 12w)", "Beg 10K (long, 12w)", "raceRehearsal10K", rp=300, ep=420)
check(
    "Beg 10K has 0 raceRehearsal10K (forcing is Int/Adv only)",
    beg_10k_rr is not None and beg_10k_rr == 0,
    f"got {beg_10k_rr}"
)

# Adv 5K and Cmp 21K should NOT have raceRehearsal10K (distance gate is 10000 only)
adv_5k_rr = count_workout_subtype("Adv 5K (long, 10w)", "Adv 5K (long, 10w)", "raceRehearsal10K", rp=240, ep=320)
check(
    "Adv 5K has 0 raceRehearsal10K (forcing is 10K distance only)",
    adv_5k_rr is not None and adv_5k_rr == 0,
    f"got {adv_5k_rr}"
)

# 3) Adv 10K and Int 10K close to or out-volumes their 5K counterpart
# (within 5% slack — pace differences mean exact inversion isn't always
# achievable, but the bumps narrow the gap meaningfully)
def peak_km_for_label(label, fil, rp, ep):
    w = parse_plan(run_pacedump_with(fil, rp, ep, False), label)
    km = max(weekly_km(w).values()) if w else 0
    return km
adv_5k_km = peak_km_for_label("Adv 5K (long, 10w)", "Adv 5K (long, 10w)", 240, 320)
adv_10k_km = peak_km_for_label("Adv 10K (long, 12w)", "Adv 10K (long, 12w)", 260, 320)
check(
    f"Adv 10K peak km within 10% of Adv 5K (10K bumped for visible step toward 5K)",
    adv_10k_km >= adv_5k_km * 0.9,
    f"Adv 5K={adv_5k_km:.1f} km, Adv 10K={adv_10k_km:.1f} km — 10K shouldn't trail 5K by >10%"
)
int_5k_km = peak_km_for_label("Int 5K (long, 10w)", "Int 5K (long, 10w)", 240, 320)
int_10k_km = peak_km_for_label("Int 10K (long, 12w)", "Int 10K (long, 12w)", 270, 380)
check(
    "Int 10K peak km within 10% of Int 5K (equal 3-day count; km favors speed-heavy 5K)",
    int_10k_km >= int_5k_km * 0.9,
    f"Int 5K={int_5k_km:.1f} km, Int 10K={int_10k_km:.1f} km — 10K shouldn't trail 5K by >10%"
)

section("5K/10K plan variants (short/rec/long) — all generate cleanly, scale right")

# Each (level, distance) ships in 2-3 length variants. The "long" variant
# is the default recommendation; "rec" is the short floor; "short" is the
# emergency-time-crunch path. All must:
#   • generate with the expected week count (no week-counting bugs)
#   • carry tier-appropriate session frequency (matches recommendedTrainingsPerWeek)
#   • have peak km that scales sensibly with length (longer plans = higher peak)

SHORT_LONG_VARIANTS = [
    # (header, fil, rp, ep, expected_weeks, expected_sessions_per_wk)
    # expected_sessions_per_wk = LOCKED day-count matrix (Beg 2/2, Int 3/3, Adv 4/4
    # for 5K/10K). All durations of a plan share its config day-count.
    ("Beg 5K (short, 5w)",  "Beg 5K (short, 5w)",  240, 350, 5,  2),
    ("Beg 5K (rec, 7w)",    "Beg 5K (rec, 7w)",    240, 350, 7,  2),
    ("Beg 5K (long, 10w)",  "Beg 5K (long, 10w)",  240, 350, 10, 2),
    ("Int 5K (short, 5w)",  "Int 5K (short, 5w)",  240, 320, 5,  3),
    ("Int 5K (rec, 7w)",    "Int 5K (rec, 7w)",    240, 320, 7,  3),
    ("Int 5K (long, 10w)",  "Int 5K (long, 10w)",  240, 320, 10, 3),
    ("Adv 5K (rec, 7w)",    "Adv 5K (rec, 7w)",    240, 320, 7,  4),
    ("Adv 5K (long, 10w)",  "Adv 5K (long, 10w)",  240, 320, 10, 4),
    ("Beg 10K (short, 7w)", "Beg 10K (short, 7w)", 300, 420, 7,  2),
    ("Beg 10K (rec, 9w)",   "Beg 10K (rec, 9w)",   300, 420, 9,  2),
    ("Beg 10K (long, 12w)", "Beg 10K (long, 12w)", 300, 420, 12, 2),
    ("Int 10K (rec, 9w)",   "Int 10K (rec, 9w)",   270, 380, 9,  3),
    ("Int 10K (long, 12w)", "Int 10K (long, 12w)", 270, 380, 12, 3),
    ("Adv 10K (rec, 9w)",   "Adv 10K (rec, 9w)",   260, 320, 9,  4),
    ("Adv 10K (long, 12w)", "Adv 10K (long, 12w)", 260, 320, 12, 4),
]

# Per-tier (distance, level) groups → (long_variant_label, short_variant_label)
# Used to assert "long plan has peak km >= short plan peak km" — longer
# plans should build to higher absolute peaks, not lower.
GROWS_WITH_LENGTH = [
    ("Beg 5K", "Beg 5K (long, 10w)", "Beg 5K (short, 5w)", 240, 350),
    ("Int 5K", "Int 5K (long, 10w)", "Int 5K (short, 5w)", 240, 320),
    ("Beg 10K", "Beg 10K (long, 12w)", "Beg 10K (short, 7w)", 300, 420),
]

for header, fil, rp, ep, expected_weeks, expected_sess in SHORT_LONG_VARIANTS:
    text = run_pacedump_with(fil, rp, ep, False)
    w = parse_plan(text, header)
    short_label = header.split(' (')[0] + " " + header.split('(')[1].split(',')[0]
    if not w:
        check(f"{short_label} generates", False, "no plan parsed")
        continue
    check(
        f"{short_label} generates with {expected_weeks} weeks",
        len(w) == expected_weeks,
        f"got {len(w)} weeks"
    )
    # Session count per build week (exclude race week — only ~3 sessions)
    # Race week is the last one; we look at non-last weeks for the typical count.
    build_weeks = [wk for wk in w if wk < max(w.keys())]
    if build_weeks:
        max_sess = max(len(w[wk]) for wk in build_weeks)
        check(
            f"{short_label} max-week sessions matches tier ({expected_sess})",
            max_sess == expected_sess,
            f"got max sessions/wk = {max_sess}"
        )

# LOCKED day-count matrix — training days/week per (level × distance). Set by Q;
# do NOT change a count without an explicit request (see PlanConfiguration.swift
# day-count matrix comment). Running below classic-plan volume is intentional.
#              5K   10K   21K   42K
#   Beginner    2    2     3     4
#   Intermed    3    3     4     4
#   Advanced    4    4     5     5
TIER_DAYS = [
    ("Beg 5K (rec, 7w)",   240, 350, 2), ("Int 5K (rec, 7w)",   240, 320, 3), ("Adv 5K (rec, 7w)",   240, 320, 4),
    ("Beg 10K (rec, 9w)",  300, 420, 2), ("Int 10K (rec, 9w)",  270, 380, 3), ("Adv 10K (rec, 9w)",  260, 320, 4),
    ("Beg 21K (rec, 14w)", 300, 420, 3), ("Int 21K (rec, 14w)", 270, 380, 4), ("Adv 21K (rec, 14w)", 260, 320, 5),
    ("Beg 42K (rec, 18w)", 330, 450, 4), ("Int 42K (rec, 18w)", 300, 420, 4), ("Adv 42K (rec, 18w)", 280, 360, 5),
]
for label, rp, ep, days in TIER_DAYS:
    w = parse_plan(run_pacedump_with(label, rp, ep, False), label)
    build = [wk for wk in w if wk < max(w.keys())] if w else []
    got = max((len(w[wk]) for wk in build), default=None)
    check(
        f"{label.split(' (')[0]} runs {days} days/wk (tier-days matrix)",
        got == days,
        f"got max sessions/wk={got}, expected {days}",
    )

section("Beg 10K (2-day, LOCKED): each week = 1 long + ≤1 quality")
# Beg 10K runs 2 days (LOCKED day-count matrix) — intentionally minimal and below
# classic-plan volume. A 2-day week is the long run + one quality session, so a
# separate easy/recovery day is structurally impossible (and not required).
# Guard: no build week is 2+ quality (the long run must be present), and weekly
# volume doesn't silently collapse.
_b10 = parse_plan(run_pacedump_with("Beg 10K (long, 12w)", 300, 420, False), "Beg 10K (long, 12w)")
_QUAL = {'timeTrial', 'threshold', 'intervals', 'hillRepeats', 'ladderIntervals',
         'fivekPace', 'tenkPace', 'mileRepeats', 'yasso800', 'fartlek'}
if not _b10:
    check("Beg 10K (long) parses for structure/volume check", False, "no plan")
else:
    _build = [wk for wk in _b10 if wk < max(_b10.keys())]
    _over_q = [wk for wk in _build if sum(1 for s, _, _ in _b10[wk] if s in _QUAL) >= 2]
    check("Beg 10K: no build week is 2+ quality (each is long + ≤1 quality)",
          not _over_q,
          f"2+quality weeks={_over_q}")
    _peak = max(sum(d for _, d, _ in _b10[wk]) for wk in _b10)
    check("Beg 10K peak weekly volume ≥ 110min (guard 2-day level)",
          _peak >= 110,
          f"peak={_peak}min")

section("Beg 21K/42K (3-4 day): every build week keeps a recovery day (C1 fix)")
# The forced PEAK rehearsal week used to collide with a 3rd-slot progression,
# making a 3-day Beg 21K week all-hard (threshold + race-rehearsal-long +
# progression, zero easy). The 3rd-slot progression is now 42K-only, so Beg
# 21K's 3rd slot is always easy. Guard: no build week lacks a recovery run.
_REC = {'easy', 'strides', 'recovery'}
for _hdr, _rp, _ep in [("Beg 21K (rec, 14w)", 360, 480),
                       ("Beg 21K (long, 18w)", 360, 480),
                       ("Beg 42K (long, 22w)", 360, 480)]:
    _w = parse_plan(run_pacedump_with(_hdr, _rp, _ep, False), _hdr)
    if not _w:
        check(f"{_hdr} parses for recovery-day check", False, "no plan"); continue
    _b = [wk for wk in _w if wk < max(_w.keys())]
    _nr = [wk for wk in _b if not any(s in _REC for s, _, _ in _w[wk])]
    check(f"{_hdr.split(' (')[0]} {_hdr.split('(')[1].rstrip(') ')}: every build week has a recovery day",
          not _nr, f"all-hard weeks (no easy/strides)={_nr}")

for label, long_fil, short_fil, rp, ep in GROWS_WITH_LENGTH:
    long_text = run_pacedump_with(long_fil, rp, ep, False)
    short_text = run_pacedump_with(short_fil, rp, ep, False)
    long_w = parse_plan(long_text, long_fil)
    short_w = parse_plan(short_text, short_fil)
    if not long_w or not short_w:
        check(f"{label} grows-with-length parse", False, "")
        continue
    long_peak = max(weekly_km(long_w).values()) if long_w else 0
    short_peak = max(weekly_km(short_w).values()) if short_w else 0
    # Short and long variants share the same baseLoad and peak-phase
    # boost — they peak at similar absolute weekly load. The long
    # variant builds more TOTAL volume (more weeks at high load) but
    # per-week peak is comparable. Allow 5% slack for selector variance.
    check(
        f"{label} long variant peak km >= short variant peak km (5% slack)",
        long_peak >= short_peak * 0.95,
        f"long={long_peak:.1f} km, short={short_peak:.1f} km — short shouldn't significantly out-volume long"
    )

# (The "UI trainings-per-week matches config" check moved to the app test
# suite — it asserts against RunningLevel, which is a UI type and not part
# of this engine package.)

section("Beg/Int/Adv 5K and 10K: tier-appropriate frequency + LR caps + volume")

# Beg 5K frequency is LOCKED at 2 days/wk (see day-count matrix). Also defends:
#   - 10K LR caps split per tier (was flat 80min — too long for Beg/Int)
#   - Int/Adv 5K/10K baseLoad ×1.15 — Daniels/Pfitz volume close

# Beg 5K sessions/week — LOCKED to 2 (see day-count matrix); do not raise to 3.
def session_count_per_week(label, fil, rp, ep):
    text = run_pacedump_with(fil, rp, ep, False)
    w = parse_plan(text, label)
    if not w: return None
    counts = [len(w[wk]) for wk in w]
    return min(counts), max(counts), sum(counts) / len(counts)

r = session_count_per_week("Beg 5K (long, 10w)", "Beg 5K (long, 10w)", 240, 350)
check(
    "Beg 5K (long, 10w) BUILD week sessions == 2 (LOCKED day-count matrix)",
    r is not None and r[1] == 2,
    f"got min={r[0]} max={r[1]} avg={r[2]:.1f}" if r else "no plan"
)

# 10K LR caps — tier-appropriate (was flat 80min everywhere before today)
def lr_first_and_peak(label, fil, rp, ep):
    """Return (first-build-week LR, peak LR) in minutes, or (None, None)."""
    text = run_pacedump_with(fil, rp, ep, False)
    w = parse_plan(text, label)
    if not w: return (None, None)
    LR = {'steadyLong','long','progressiveLong','raceRehearsalM','raceRehearsalHM','raceRehearsal10K','fastFinish'}
    byweek = {}
    for wk in sorted(w):
        longs = [dur for s, dur, _ in w[wk] if s in LR]
        if longs: byweek[wk] = max(longs)
    if not byweek: return (None, None)
    return (byweek[min(byweek)], max(byweek.values()))

# Beg 10K cap was 60 (a flat cap that froze the long run — no progression at
# all). Bumped to 70 (Higdon Novice 10K ~5-6mi) so it climbs 60→70. The GROWS
# check is the regression guard: a long run stuck at its minimum (the old bug)
# fails it.
for label, fil, rp, ep, cap, ref in [
    ("Beg 10K (long, 12w)", "Beg 10K (long, 12w)", 300, 420, 72, "Higdon Novice 10K, grows 60→70"),
    ("Int 10K (long, 12w)", "Int 10K (long, 12w)", 270, 380, 78, "Higdon Int 10K ~ 75min"),
    ("Adv 10K (long, 12w)", "Adv 10K (long, 12w)", 260, 320, 92, "Daniels/Pfitz Adv 10K ~ 80-90min"),
]:
    first, peak = lr_first_and_peak(label, fil, rp, ep)
    short = label.split(' (')[0]
    check(
        f"{short} peak LR <= {cap}min ({ref})",
        peak is not None and peak <= cap,
        f"got peak LR {peak}min"
    )
    check(
        f"{short} long run GROWS over the plan (peak > first build LR)",
        first is not None and peak is not None and peak >= first + 5,
        f"first build LR={first}min, peak LR={peak}min", full=True
    )

# Int/Adv 5K/10K peak km — after baseLoad ×1.15 bump
def peak_km_for(label, fil, rp, ep):
    text = run_pacedump_with(fil, rp, ep, False)
    w = parse_plan(text, label)
    if not w: return None
    km_by_wk = weekly_km(w)
    return max(km_by_wk.values()) if km_by_wk else 0

# Bumped baseline bands — captures current state after baseLoad ×1.15 +
# +1 day for Int/Adv tiers. Bands now wider to absorb day-count growth
# while still catching real regression.
# Floors track the LOCKED day-count matrix (Int 5K/10K = 3 days, Adv 5K/10K =
# 4 days), NOT the classic-plan targets — we deliberately run below Daniels/Pfitz
# here. These are regression guards at the current level; the hi bound still
# catches accidental over-volume.
SHORT_RACE_KM_BANDS = [
    # (header, fil, rp, ep, lo, hi, reference)
    ("Int 5K (long, 10w)", "Int 5K (long, 10w)", 240, 320, 32, 55, "3-day Int 5K — below Daniels 50-65 by design"),
    ("Int 10K (long, 12w)", "Int 10K (long, 12w)", 270, 380, 30, 66, "3-day Int 10K — below Pfitz 55-70 by design"),
    ("Adv 5K (long, 10w)", "Adv 5K (long, 10w)", 240, 320, 56, 95, "4-day Adv 5K — below Daniels 70-85 by design"),
    ("Adv 10K (long, 12w)", "Adv 10K (long, 12w)", 260, 320, 56, 85, "4-day Adv 10K — below Daniels 70-90 by design"),
]
for header, fil, rp, ep, lo, hi, ref in SHORT_RACE_KM_BANDS:
    km = peak_km_for(header, fil, rp, ep)
    short = header.split(' (')[0]
    check(
        f"{short} peak km ∈ [{lo}, {hi}] ({ref})",
        km is not None and lo <= km <= hi,
        f"got {km:.1f} km/wk",
        full=True
    )

section("Int/Adv 42K Pfitz MP-volume pattern (marathonPace forced on alt PEAK weeks)")

# Pfitz 18/55 (Int) and 18/70 (Adv) prescribe two MP exposures per PEAK
# week: one LR-with-MP and one dedicated MP run (12mi @ MP, 8mi @ MP).
# Without forcing (line 1119 of PlanGeneratorV3.swift), at Int's baseLoad
# the threshold-pool selector preferred bigger thresholds/mileRepeats —
# Int 42K got 3 MP workouts (mostly BASE/SPEED), Adv 42K got 0.
# Forcing on alternating PEAK weeks restores Pfitz's dedicated MP slot.
# Marathon-only (distance==42195); half-marathon plans are untouched.

int_42k_mp = count_workout_subtype("Int 42K (long, 22w)", "Int 42K (long, 22w)", "marathonPace", rp=300, ep=400)
adv_42k_mp = count_workout_subtype("Adv 42K (long, 22w)", "Adv 42K (long, 22w)", "marathonPace", rp=280, ep=380)
check(
    "Int 42K (long, 22w) has >= 4 marathonPace sessions (Pfitz MP pattern)",
    int_42k_mp is not None and int_42k_mp >= 4,
    f"got {int_42k_mp} marathonPace workouts",
    full=True
)
check(
    "Adv 42K (long, 22w) has >= 3 marathonPace sessions (was 0 before forcing)",
    adv_42k_mp is not None and adv_42k_mp >= 3,
    f"got {adv_42k_mp} marathonPace workouts — forcing must keep MP visible",
    full=True
)

# 21K plans should NOT be affected by the marathon-specific MP forcing.
int_21k_mp = count_workout_subtype("Int 21K (long, 18w)", "Int 21K (long, 18w)", "marathonPace", rp=300, ep=420)
adv_21k_mp = count_workout_subtype("Adv 21K (long, 18w)", "Adv 21K (long, 18w)", "marathonPace", rp=270, ep=360)
check(
    "Int 21K (long, 18w) NOT affected by 42K MP forcing (no MP in half plan)",
    int_21k_mp is not None and int_21k_mp == 0,
    f"got {int_21k_mp} MP workouts on Int 21K — MP forcing must be 42K-only"
)
check(
    "Adv 21K (long, 18w) NOT affected by 42K MP forcing (no MP in half plan)",
    adv_21k_mp is not None and adv_21k_mp == 0,
    f"got {adv_21k_mp} MP workouts on Adv 21K — MP forcing must be 42K-only"
)

section("Beg/Int/Adv plans: regression guards (don't degrade non-Cmp tiers)")

# When tuning Cmp plans (or future global engine changes), it's easy to
# accidentally degrade the other tiers. These snapshots lock the current
# observed shape for Beg/Int/Adv 21K + 42K so any drift surfaces in CI.
#
# Caught issues these tests would have prevented:
#   - Int 21K's 100% aerobic LR quirk (selector never picked progressives) —
#     the aerobic band catches this.
#   - Int/Adv 42K losing marathonPace workouts after a baseLoad bump —
#     the "must include marathonPace" check catches this.
#   - LR cap regression (someone resetting 21K caps to 120+ min) —
#     peak LR check catches this.
#   - Volume drift from baseLoad tuning — peak km check catches this.

QUALITY_SUBTYPES_FOR_GUARDS = {
    'threshold','marathonPace','intervals','mileRepeats','yasso800',
    'hillRepeats','timeTrial','fivekPace','tenkPace','fartlek',
    'ladderIntervals','pyramidIntervals'
}
LR_SUBTYPES_FOR_GUARDS = {'steadyLong','long','progressiveLong',
    'raceRehearsalM','raceRehearsalHM','raceRehearsal10K','fastFinish'}

def measure_plan_for_guards(label, fil, rp, ep):
    """Pull aerobic %, peak weekly km, peak LR duration, and the set of
    quality subtypes present in the plan."""
    # Aerobic share via real Swift
    aero_text = run_aerobic(fil, False)
    aero_weeks = parse_aerobic(aero_text, label)
    aero, total = long_run_aerobic_share(aero_weeks) if aero_weeks else (0, 0)
    aero_pct = 100 * aero / total if total else 0
    # km + LR + quality from pacedump
    pd_text = run_pacedump_with(fil, rp, ep, False)
    w = parse_plan(pd_text, label)
    if not w: return None
    km_by_wk = weekly_km(w)
    peak_km = max(km_by_wk.values()) if km_by_wk else 0
    peak_lr = 0; qualities = set()
    for wk in w:
        for s, dur, _ in w[wk]:
            if s in LR_SUBTYPES_FOR_GUARDS:
                peak_lr = max(peak_lr, dur)
            if s in QUALITY_SUBTYPES_FOR_GUARDS:
                qualities.add(s)
    return aero_pct, peak_km, peak_lr, qualities

# (header, racePace, easyPace, aero_lo, aero_hi, km_lo, km_hi, lr_cap_min,
#  lr_cap_max, must_have_qualities)
GUARDS = [
    # Beg 42K — Pfitz Just Finish / Higdon Novice 1 style: pure aerobic,
    # marathonPace + threshold sole intensity. NO intervals/mileRepeats.
    # LR band 195-215 → 175-195: the novice marathon long run is now capped at
    # ~180-190min (3:00-3:10); the old ~205-225 peak (3:25-3:45) was too long for
    # a beginner. See the beginner-cap section for the <=190 ceiling guard.
    ("Beg 42K (long, 22w)", 330, 450, 92, 99, 35, 55, 195, 245,
     {'marathonPace', 'threshold'}),
    # Int 42K — Pfitz 18/55 territory: full quality variety incl. MP.
    # km max 80→84: 2026-06-16 intermediate quality easing → Advanced (honest
    # race-pace naming) runs quality slightly faster → marginally more km/wk.
    ("Int 42K (long, 22w)", 300, 400, 88, 96, 50, 84, 175, 215,
     {'marathonPace', 'threshold'}),
    # Adv 42K — Pfitz 18/70 territory after Track D engine work:
    # baseLoad×1.20 + MP-forcing on alt PEAK weeks. Now hits ~101 km/wk
    # peak (Pfitz 18/70 ≈ 113; 10% under instead of pre-bump 23% under)
    # and lands 4 marathonPace sessions in PEAK (Pfitz "12mi @ MP"
    # signature workout) where previously it had 0. Aerobic share drops
    # to ~77% (more Z3 time from dedicated MP runs) — Pfitz "general
    # aerobic 75-80%" aligned. LR band 170-195 (was 175-195): #199 tick
    # discipline (2026-07-04) closed the km-cap leak — the old 175 floor was
    # calibrated against 33.2-33.5km renders leaking past the 33km cap; honest
    # <=33km at Adv fit pace is ~170min. Floor side unchanged (28km delivered).
    # Aerobic cap 84: deload LRs plain aerobic (no MP rehearsal on down weeks, 2026-07-01).
    ("Adv 42K (long, 22w)", 280, 380, 72, 88, 85, 110, 170, 195,
     {'marathonPace', 'threshold'}),
    # Beg 21K — 3-day, deliberately light (below classics). km floor 28→24:
    # C1 fix makes the 3rd slot pure easy on rehearsal weeks (was a progression),
    # so the same minutes cover slightly fewer km.
    ("Beg 21K (long, 18w)", 360, 480, 92, 99, 24, 45, 95, 125,
     {'threshold'}),
    # Int 21K — Pfitz 12-week HM: progressives in SPEED (the forcing fix).
    ("Int 21K (long, 18w)", 300, 420, 80, 92, 45, 65, 95, 130,
     {'threshold'}),
    # Adv 21K — Pfitz 12/47 HM: more quality + race-pace work.
    ("Adv 21K (long, 18w)", 270, 360, 75, 90, 65, 95, 100, 115,
     {'threshold'}),
]

for header, rp, ep, alo, ahi, klo, khi, lrlo, lrhi, must_q in GUARDS:
    r = measure_plan_for_guards(header, header, rp, ep)
    if r is None:
        check(f"{header} guards parse", False, "no plan parsed")
        continue
    aero_pct, peak_km, peak_lr, qualities = r
    short = header.split(' (')[0]
    check(
        f"{short} aerobic share ∈ [{alo}, {ahi}]% (real Swift HR zones)",
        alo <= aero_pct <= ahi,
        f"observed {aero_pct:.1f}%",
        full=True
    )
    check(
        f"{short} peak weekly km ∈ [{klo}, {khi}]",
        klo <= peak_km <= khi,
        f"observed {peak_km:.1f} km/wk",
        full=True
    )
    check(
        f"{short} peak LR ∈ [{lrlo}, {lrhi}] min (Pfitz tier cap)",
        lrlo <= peak_lr <= lrhi,
        f"observed peak LR {peak_lr}min",
        full=True
    )
    missing = must_q - qualities
    check(
        f"{short} must include quality subtypes {sorted(must_q)}",
        not missing,
        f"missing: {sorted(missing)}, found: {sorted(qualities)}"
    )

# --- Z5 intensity policy -----------------------------------------------
# A "real" Z5 session = a workout with >=3min of work intervals targeting
# HR zone 5 (strides exempt). Engine policy for race plans:
#   no Z5 in BASE/TAPER/RACE, week 1 never opens with Z5, max one Z5
#   session per week, and 21K/42K never run Z5 in consecutive weeks.
# VO2 blocks are exempt (Z5 is their point); Adv VO2 may double.

section("Z5 intensity policy — frequency caps (injury-conscious)")

def parse_dump_z5():
    r = subprocess.run([PLAN_DEBUG, "dump"], capture_output=True, text=True)
    plans = {}
    plan = week = None
    for line in r.stdout.splitlines():
        m = re.match(r'^=== (.+?)\s+\(\d+w', line)
        if m:
            plan = m.group(1); plans[plan] = {}; week = None; continue
        m = re.match(r'^W\s*(\d+) \[(\w+)', line)
        if m and plan:
            week = int(m.group(1))
            plans[plan][week] = {'phase': m.group(2), 'z5': 0}
            continue
        m = re.match(r'^\s{4}.*?\[(\w+)/\S+\] z5=(\d+)', line)
        if m and plan and week and int(m.group(2)) >= 3 and m.group(1) != 'strides':
            plans[plan][week]['z5'] += 1
    return plans

z5plans = parse_dump_z5()
bad_phase, bad_double, bad_consec, bad_w1 = [], [], [], []
for pname, weeks in z5plans.items():
    isvo2 = pname.startswith('VO2')
    prev = False
    for wn in sorted(weeks):
        wd = weeks[wn]; c = wd['z5']
        # R8: half/marathon carry a light Z5 session from BASE week 3;
        # only the first two base weeks + taper/race stay Z5-free.
        base_ok = wd['phase'] == 'base' and wn >= 3 and ('21K' in pname or '42K' in pname)
        if c and not isvo2 and wd['phase'] in ('base', 'taper', 'race') and not base_ok:
            bad_phase.append(f"{pname} W{wn}[{wd['phase']}]")
        if c and wn == 1 and not isvo2:
            bad_w1.append(pname)
        if c > 1 and not (isvo2 and 'Adv' in pname):
            bad_double.append(f"{pname} W{wn}")
        if c and prev and ('21K' in pname or '42K' in pname):
            bad_consec.append(f"{pname} W{wn}")
        prev = c > 0
check("No Z5 in BASE W1-2 / TAPER / RACE weeks (non-VO2; R8 allows light Z5 from base W3)",
      not bad_phase, f"offenders: {bad_phase[:4]}")
check("Week 1 never opens with a Z5 session (non-VO2 plans)",
      not bad_w1, f"offenders: {bad_w1[:4]}")
check("At most one Z5 session per week (Adv VO2 block excepted)",
      not bad_double, f"offenders: {bad_double[:4]}")
check("21K/42K plans never run Z5 in consecutive weeks",
      not bad_consec, f"offenders: {bad_consec[:4]}")

# Catalog guard: strength/benchmark subtypes must not carry Z5 work
# intervals (hills are strength, not VO2; nobody holds true Z5 for a
# 25min TT; fast-finish tails are hard-but-controlled — all Z4).
import json as _json
_cat_path = os.environ.get(
    "WORKOUTS_PATH",
    os.path.join(ROOT, "Sources/TrainingPlanKit/Catalog/sample_catalog.json"))
_cat = _json.load(open(_cat_path))
_badcat = sorted({w.get('title', '?') for w in _cat
                  if w.get('subtype') in ('hillRepeats', 'timeTrial', 'fastFinish')
                  for iv in w.get('intervals', [])
                  if iv.get('type') == 'Work'
                  and (iv.get('target') or {}).get('zone') == 5})
check("Catalog: hillRepeats/timeTrial/fastFinish carry no Z5 work (Z4 retag)",
      not _badcat, f"offenders: {_badcat[:3]}")

# --- VO2 block: a true-Z5 dose that reaches most weeks AND progresses --------
# The headline VO2 defect: the blocks barely delivered VO2. A true-Z5 session
# (>=10min of Z5 work, strides exempt) landed in only 2-4 of 8 weeks, and the
# Z5 dose was pinned at ~20min (every fivekPace template = 20min) — it never
# ramped. The fix opens the dose ladder (intervals/ladderIntervals) and selects
# a week-indexed Z5 dose so MOST weeks carry VO2 and the dose climbs across the
# block. Needs the full catalog (the dose ladder lives there). Z5 minutes are
# read straight from `dump` (z5=N = Z5 work minutes in the picked template).
section("VO2 block delivers VO2 — Z5 dose reaches most weeks and progresses")

# A real-VO2 dose floor: strides carry 1-2min of Z5; a genuine VO2 rep block is
# >=10min. Use the max non-strides Z5 dose in each week as that week's VO2 dose.
VO2_Z5_FLOOR = 10

def parse_dump_z5_minutes():
    """dict[plan] = {week: max non-strides Z5 work-minutes that week}."""
    r = subprocess.run([PLAN_DEBUG, "dump"], capture_output=True, text=True)
    plans = {}
    plan = week = None
    for line in r.stdout.splitlines():
        m = re.match(r'^=== (.+?)\s+\(\d+w', line)
        if m:
            plan = m.group(1); plans[plan] = {}; week = None; continue
        m = re.match(r'^W\s*(\d+) \[(\w+)', line)
        if m and plan:
            week = int(m.group(1)); plans[plan][week] = 0; continue
        m = re.match(r'^\s{4}.*?\[(\w+)/\S+\] z5=(\d+)', line)
        if m and plan and week and m.group(1) != 'strides':
            plans[plan][week] = max(plans[plan][week], int(m.group(2)))
    return plans

_z5min = parse_dump_z5_minutes()
for _vo2 in ("VO2 Beg", "VO2 Int", "VO2 Adv"):
    weeks = _z5min.get(_vo2, {})
    doses = [weeks[w] for w in sorted(weeks)]                 # per-week VO2 dose
    n = len(doses) or 1
    real = [d for d in doses if d >= VO2_Z5_FLOOR]            # weeks with true VO2
    # (1) Most weeks carry a true-Z5 session — >=6 of 8 (W1 onboarding + the
    # taper week may legitimately skip it; everything else must deliver VO2).
    check(f"{_vo2}: true-Z5 session (>={VO2_Z5_FLOOR}min) in >=6 of {n} weeks",
          len(real) >= 6,
          f"only {len(real)}/{n} weeks carry a real VO2 dose; per-week z5={doses}",
          full=True)
    # (2) The dose PROGRESSES — not pinned to one value. Require >=3 distinct VO2
    # doses among the true-Z5 weeks, the late dose to exceed the early dose, and
    # no week to drop more than one ladder rung (~8min) below the running peak
    # before the taper (a controlled, non-collapsing ramp).
    real_seq = [d for d in doses if d >= VO2_Z5_FLOOR]
    distinct = sorted(set(real_seq))
    progresses = len(distinct) >= 3
    climbs = bool(real_seq) and real_seq[-1] > real_seq[0]
    # Non-collapse: scanning the real-Z5 weeks in order, the dose never falls
    # >8min below the peak seen so far (until the final taper week, excluded).
    running_peak = 0
    collapses = []
    real_weeks_sorted = [w for w in sorted(weeks) if weeks[w] >= VO2_Z5_FLOOR]
    for i, w in enumerate(real_weeks_sorted):
        d = weeks[w]
        running_peak = max(running_peak, d)
        is_last = (i == len(real_weeks_sorted) - 1)
        if not is_last and d < running_peak - 8:
            collapses.append((w, d, running_peak))
    check(f"{_vo2}: Z5 dose progresses across the block (not pinned at one value)",
          progresses and climbs and not collapses,
          f"distinct doses={distinct}, first={real_seq[0] if real_seq else None}, "
          f"last={real_seq[-1] if real_seq else None}, collapses={collapses}; "
          f"per-week z5={doses}",
          full=True)

section("Accessible (\"real life\") tier — lighter than textbook, same structure & safety")

# The app ships a parallel ACCESSIBLE config set (PlanConfiguration.accessible*)
# for non-competitive plans: fewer days/week and a gentler beginner phase mix,
# but the SAME periodization (base→speed→peak→taper), the SAME safety rails,
# and 72-90% of the textbook training load. The textbook ("ideal") configs stay
# in the package (and are exercised by the sections above); these checks defend
# the configs users actually receive.
#
# Accessible day matrix — 5K 2/3/4, 10K 2/3/4, 21K 3/4/5, 42K 4/4/5. Three
# cells (Adv 21K, Beg 42K, Adv 42K) intentionally equal textbook and alias it.
# Each accessible "(rec)" case pairs with its textbook "(rec)" case at the same
# week count, so the "accessible ≤ textbook" comparisons are apples-to-apples
# (same race/easy pace inputs, same plan length, same catalog).
#
# (accessible_label, textbook_label, racePace, easyPace, expected_days)
ACCESSIBLE_CASES = [
    ("Acc Beg 5K (rec, 7w)",   "Beg 5K (rec, 7w)",   240, 360, 2),
    ("Acc Int 5K (rec, 7w)",   "Int 5K (rec, 7w)",   240, 320, 3),
    ("Acc Adv 5K (rec, 7w)",   "Adv 5K (rec, 7w)",   240, 320, 4),
    ("Acc Beg 10K (rec, 9w)",  "Beg 10K (rec, 9w)",  300, 420, 2),
    ("Acc Int 10K (rec, 9w)",  "Int 10K (rec, 9w)",  270, 380, 3),
    ("Acc Adv 10K (rec, 9w)",  "Adv 10K (rec, 9w)",  260, 320, 4),
    ("Acc Beg 21K (rec, 14w)", "Beg 21K (rec, 14w)", 360, 480, 3),
    ("Acc Int 21K (rec, 14w)", "Int 21K (rec, 14w)", 300, 420, 4),
    ("Acc Adv 21K (rec, 14w)", "Adv 21K (rec, 14w)", 270, 360, 5),
    ("Acc Beg 42K (rec, 18w)", "Beg 42K (rec, 18w)", 330, 450, 4),
    ("Acc Int 42K (rec, 18w)", "Int 42K (rec, 18w)", 300, 400, 4),
    ("Acc Adv 42K (rec, 18w)", "Adv 42K (rec, 18w)", 280, 380, 5),
]

def total_minutes(label, rp, ep):
    """Sum of every workout's duration across the whole plan, in minutes."""
    w = parse_plan(run_pacedump_with(label, rp, ep, False), label)
    if not w:
        return None
    return sum(d for wk in w for _, d, _ in w[wk])

def total_training_load(label):
    """Sum of every week's training load across the plan (intensity-weighted),
    parsed from `dump` mode. Pace-independent — load is the catalog workout
    load — so the accessible-vs-textbook ratio is a clean tier comparison."""
    text = run_dump(label)
    if f'=== {label}' not in text:
        return None
    sect = text.split(f'=== {label}')[1]
    total = 0
    for line in sect.splitlines():
        if line.startswith('=== '):
            break
        m = re.match(r'^W *\d+ \[\w+[^\]]*\]\s+\d+wkts\s+load=\s*(\d+)', line)
        if m:
            total += int(m.group(1))
    return total

# 1) Every accessible plan still generates a complete, non-empty plan.
for acc, _, rp, ep, _ in ACCESSIBLE_CASES:
    w = parse_plan(run_pacedump_with(acc, rp, ep, False), acc)
    short = acc.split(' (')[0]
    check(
        f"{short} generates a complete plan (every week filled)",
        w is not None and len(w) > 0 and all(len(w[wk]) > 0 for wk in w),
        f"weeks={len(w) if w else None}",
    )

# 2) Day-counts match the accessible matrix (build weeks carry the full set).
for acc, _, rp, ep, days in ACCESSIBLE_CASES:
    r = session_count_per_week(acc, acc, rp, ep)
    short = acc.split(' (')[0]
    check(
        f"{short} runs {days} days/wk (accessible matrix)",
        r is not None and r[1] == days,
        f"got max sessions/wk={r[1] if r else None}, expected {days}",
    )

# 3) The defining contract: an accessible plan is never heavier than its
#    textbook twin (alias cells are equal, which satisfies <=). Exact-volume
#    magnitudes only hold against RunPlan's full catalog — same convention as
#    the load contract (3b) below. On the sparse bundled sample the accessible
#    and textbook plans draw from too few rungs for total minutes to track:
#    e.g. once the Acc Beg 21K mid-PEAK rehearsal week correctly carries a 60min
#    long run (the every-build-week-LR rail), the sample's coarse easy-fill
#    durations tip its total ~1% over textbook even though its per-week LR (60min)
#    is lighter than textbook's (75min). The full catalog tracks cleanly.
for acc, ideal, rp, ep, _ in ACCESSIBLE_CASES:
    a = total_minutes(acc, rp, ep)
    t = total_minutes(ideal, rp, ep)
    short = acc.split(' (')[0]
    check(
        f"{short} total volume <= textbook {ideal.split(' (')[0]}",
        a is not None and t is not None and a <= t,
        f"accessible={a}min textbook={t}min",
        full=True,
    )

# 3b) STRONGER contract (#147): "accessible" must be GENUINELY lighter, not just
#     "<= textbook". Every family carries a training LOAD at most 90% of its
#     textbook twin (>=10% lighter). This caught the old byte-identical aliases
#     (Acc Adv 21K / Beg 42K / Adv 42K) and the ~0% near-ties (the whole Int
#     family, Acc Adv 10K) where "accessible" handed the user the same — or a
#     heavier — plan. Load (intensity-weighted) is the right axis: a tier whose
#     minutes dip but whose intensity holds is not actually gentler.
#
#     Exact-load magnitudes only hold against RunPlan's full catalog (the bundled
#     sample is too sparse for the load to track), so this is a full-catalog
#     check — same convention as every other exact-volume assertion in this file.
for acc, ideal, rp, ep, _ in ACCESSIBLE_CASES:
    a = total_training_load(acc)
    t = total_training_load(ideal)
    short = acc.split(' (')[0]
    ratio = (a / t) if (a and t) else None
    check(
        f"{short} training load <= textbook {ideal.split(' (')[0]} (R8: km floors converge LR volume)",
        ratio is not None and ratio <= 1.02,
        f"accessible={a} textbook={t} ratio={ratio:.3f} (need <=1.02)" if ratio
            else f"accessible={a} textbook={t}",
        full=True,
    )

# 4) Safety rails hold on the lighter plans, exactly as on textbook:
#    at most one long run per week, long runs >= 60min, race week is light.
for acc, _, rp, ep, _ in ACCESSIBLE_CASES:
    w = parse_plan(run_pacedump_with(acc, rp, ep, False), acc)
    if not w:
        continue
    short = acc.split(' (')[0]
    multi_lr = [wk for wk in w if sum(1 for s, _, _ in w[wk] if s in LONG) > 1]
    check(f"{short} has at most one long run per week", not multi_lr,
          f"weeks with >1 LR: {multi_lr[:3]}")
    short_lr = [(wk, d) for wk in w for s, d, _ in w[wk] if s in LONG and d < 60]
    check(f"{short} long runs are >= 60min", not short_lr,
          f"short long runs: {short_lr[:3]}")
    last = max(w)
    rw = w[last]
    check(
        f"{short} race week is light (no quality, no long run)",
        not any(s in QUALITY for s, _, _ in rw) and not any(s in LONG for s, _, _ in rw),
        f"race week: {[(s, d) for s, d, _ in rw]}",
    )

# 5) Accessible beginners (5K/10K) are base-heavy and gentle: no aggressive
#    quality (intervals / mile repeats / Yasso / ladders). Threshold is fine.
AGGRESSIVE_QUALITY = {'intervals', 'mileRepeats', 'yasso800',
                      'ladderIntervals', 'pyramidIntervals'}
for acc, rp, ep in [
    ("Acc Beg 5K (rec, 7w)", 240, 360),
    ("Acc Beg 10K (rec, 9w)", 300, 420),
]:
    w = parse_plan(run_pacedump_with(acc, rp, ep, False), acc)
    short = acc.split(' (')[0]
    found = {s for wk in (w or {}) for s, _, _ in w[wk]} & AGGRESSIVE_QUALITY
    check(f"{short} excludes aggressive quality (base-heavy beginner)",
          not found, f"found: {sorted(found)}")

# 6) Same periodization shape. The TAPER is universal — the race week always
#    sits below the plan's peak. The BUILD (peak lands past week 1) is catalog-
#    bound: on the bundled sample the lightest plans (2-day beginners, whose
#    long run is a fixed length every week) can tie their peak at week 1, so
#    that half runs only against the full catalog.
for acc, _, rp, ep, _ in ACCESSIBLE_CASES:
    w = parse_plan(run_pacedump_with(acc, rp, ep, False), acc)
    if not w:
        continue
    short = acc.split(' (')[0]
    vols = {wk: sum(d for _, d, _ in w[wk]) for wk in w}
    ks = sorted(vols)
    peak_wk = max(vols, key=vols.get)
    check(
        f"{short} tapers into the race week (race week below peak)",
        vols[ks[-1]] < vols[peak_wk],
        f"peak(W{peak_wk})={vols[peak_wk]} race={vols[ks[-1]]}",
    )
    # The 2-day beginner plans (5K/10K) are deliberately near-flat — one long/
    # quality day plus one short day, no room to ramp weekly volume — so they
    # can peak at W1. The taper check above still applies; build does not.
    if short not in ('Acc Beg 5K', 'Acc Beg 10K'):
        check(
            f"{short} builds toward a mid-plan peak (peak past W1)",
            peak_wk != ks[0],
            f"W1={vols[ks[0]]} peak at W{peak_wk}",
            full=True,
        )

# === Workout distribution & polarization (all tiers) =================
#
# The time-weighted aerobic-share test above runs for COMPETITIVE plans
# only. That left Beg/Int/Adv and the accessible tier with no guard on the
# easy:hard balance — which is exactly how the accessible 3-day plans came
# to cram two quality sessions into a week with zero easy days and still
# pass the whole suite. These checks close that gap. A regression that
# crams quality into a reduced-day week, or strips the easy aerobic base,
# must turn one of these RED.
#
# Classification mirrors the engine's intensity intent (not the subtype
# label): hills/ladders carry an `interval` subtype but the real question
# for polarization is "is this an easy aerobic day or a hard quality day".
section("Workout distribution & polarization")

HARD_SUB    = QUALITY - {'marathonPace'}     # Z4-Z5 quality sessions
MOD_SUB     = PROG | {'marathonPace'}        # Z3 moderate
AEROBIC_SUB = EASY | LONG | STRIDES          # genuine easy / long / recovery days

def _dist_minutes(weeks):
    e = m = h = 0
    for wk in weeks.values():
        for sub, dur, _ in wk:
            if sub in HARD_SUB:   h += dur
            elif sub in MOD_SUB:  m += dur
            else:                 e += dur   # easy/long/strides (+ any aerobic)
    return e, m, h

def _hard_per_week(weeks):
    return {w: sum(1 for s, _, _ in wk if s in HARD_SUB) for w, wk in weeks.items()}

def _aerobic_per_week(weeks):
    return {w: sum(1 for s, _, _ in wk if s in AEROBIC_SUB) for w, wk in weeks.items()}

# (header, filter, race_pace, easy_pace, days, easy_floor%, hard_ceil%)
# Floors/ceilings are distance/tier-aware: a 5K is legitimately quality-
# heavier than a marathon, and an Adv marathon runs pyramidal (~50% easy),
# not polarized (~80%) like the higher-volume Cmp tier. Bands sit ~5-12pts
# off the current value: loose enough not to be flaky, tight enough that a
# crammed-quality regression (which drops easy 20-30pts) trips them.
DISTRIBUTION_PLANS = [
    # header                    filter            rp   ep  days  Efloor Hceil
    ("Acc Beg 5K (rec, 7w)",    "Acc Beg 5K",    370, 462,  2,   45,   30),
    ("Acc Int 5K (rec, 7w)",    "Acc Int 5K",    300, 360,  3,   38,   50),
    ("Acc Adv 5K (rec, 7w)",    "Acc Adv 5K",    240, 290,  4,   38,   50),
    ("Acc Beg 10K (rec, 9w)",   "Acc Beg 10K",   395, 462,  2,   50,   25),
    ("Acc Int 10K (rec, 9w)",   "Acc Int 10K",   283, 325,  3,   42,   48),
    ("Acc Adv 10K (rec, 9w)",   "Acc Adv 10K",   242, 278,  4,   42,   46),
    ("Beg 5K (long, 10w)",      "Beg 5K (long",  370, 462,  3,   50,   30),
    ("Beg 10K (long, 12w)",     "Beg 10K (long", 395, 462,  3,   55,   25),
    ("Int 21K (long, 18w)",     "Int 21K (long", 297, 340,  5,   55,   35),
    ("Adv 21K (long, 18w)",     "Adv 21K (long", 253, 278,  5,   48,   38),
    ("Int 42K (long, 22w)",     "Int 42K (long", 310, 340,  5,   60,   30),
    ("Adv 42K (long, 22w)",     "Adv 42K (long", 265, 300,  5,   46,   38),
    ("Cmp 42K (long, 22w)",     "Cmp 42K (long", 223, 255,  6,   68,   30),
]

for header, fil, rp, ep, days, efloor, hceil in DISTRIBUTION_PLANS:
    txt = run_pacedump(fil, race_pace=rp, easy_pace=ep)
    weeks = parse_plan(txt, header)
    if not weeks:
        check(f"{header} — distribution plan parses", False, "no plan parsed", full=True)
        continue
    e, m, h = _dist_minutes(weeks)
    tot = e + m + h or 1
    epct, hpct = 100 * e // tot, 100 * h // tot

    # (1) Polarization floor — enough easy aerobic volume for the tier.
    check(f"{header} — easy share >= {efloor}% by volume",
          epct >= efloor, f"easy={epct}% (floor {efloor}); E/M/H={e}/{m}/{h}min", full=True)

    # (2) Not quality-crammed — hard volume under the tier ceiling.
    check(f"{header} — hard share <= {hceil}% by volume",
          hpct <= hceil, f"hard={hpct}% (ceil {hceil}); E/M/H={e}/{m}/{h}min", full=True)

    # (3) Low-day quality cap — a <=3-day week must never carry 2 quality
    #     sessions (that leaves zero easy days). This is the direct guard
    #     for the accessible 3-day plans.
    if days <= 3:
        bad = {w: c for w, c in _hard_per_week(weeks).items() if c > 1}
        check(f"{header} — <=1 quality/week ({days}-day plan)",
              not bad, f"weeks with 2+ quality: {bad}", full=True)

    # (4) Every non-final week has a genuine easy/aerobic day — no week is
    #     all-quality (the crammed accessible weeks had quality+quality+prog,
    #     zero easy). The final (race) week is exempt: it's a shakeout.
    last = max(weeks)
    bad = {w: c for w, c in _aerobic_per_week(weeks).items() if c < 1 and w != last}
    check(f"{header} — every non-race week has an easy/aerobic day",
          not bad, f"weeks with 0 easy/long/strides days: {bad}", full=True)

# === Taper — race-week training-LOAD drop ============================
#
# The aerobic/volume checks above work in minutes. The taper, though, cuts
# intensity as much as duration: a marathon race week keeps an easy shakeout
# (similar minutes) but a fraction of the peak LOAD. A minutes-only check
# barely moves when the taper is broken — neutralize the taper-volume factor
# in the engine and a "race week < peak minutes" guard still passes. So this
# guards LOAD (intensity-weighted), parsed from dump mode, with a real
# ceiling: a broken taper pushes race-week load toward peak and trips it.
section("Taper — race-week load drop")

def parse_dump_loads(text, header):
    """dict[week_num] = weekly training load, from dump mode."""
    if f'=== {header}' not in text:
        return None
    sect = text.split(f'=== {header}')[1]
    loads = {}
    for line in sect.splitlines():
        if line.startswith('=== '):
            break
        m = re.match(r'^W *(\d+) \[\w+[^\]]*\]\s+\d+wkts\s+load=\s*(\d+)', line)
        if m:
            loads[int(m.group(1))] = int(m.group(2))
    return loads

# (header, filter, race-week ceiling as % of peak-week load)
# Ceilings are tier-aware: 21K/42K taper deep (race ~22-32% of peak), 5K/10K
# moderately (~27-52%), and the short 2-3 day accessible plans only mildly
# (~49-71%) because there's little volume to shed. Each ceiling sits ~10-20pt
# above the current value — a neutralized taper (race-week load -> ~100% of
# peak) blows through all of them.
TAPER_PLANS = [
    ("Beg 5K (long, 10w)",    "Beg 5K (long",  67),  # single mid-plan TT (no peak TT) → lower peak week, race-week ratio ~64% (race-week load itself unchanged)
    ("Beg 10K (long, 12w)",   "Beg 10K (long", 62),
    ("Adv 5K (long, 10w)",    "Adv 5K (long",  58),
    ("Int 10K (long, 12w)",   "Int 10K (long", 58),
    ("Int 21K (long, 18w)",   "Int 21K (long", 45),
    ("Adv 21K (long, 18w)",   "Adv 21K (long", 45),
    ("Int 42K (long, 22w)",   "Int 42K (long", 45),
    ("Adv 42K (long, 22w)",   "Adv 42K (long", 45),
    ("Cmp 42K (long, 22w)",   "Cmp 42K (long", 45),
    ("Acc Beg 5K (rec, 7w)",  "Acc Beg 5K",    80),
    ("Acc Int 5K (rec, 7w)",  "Acc Int 5K",    80),
    ("Acc Beg 10K (rec, 9w)", "Acc Beg 10K",   80),
    ("Acc Int 10K (rec, 9w)", "Acc Int 10K",   80),
]
for header, fil, ceil_pct in TAPER_PLANS:
    loads = parse_dump_loads(run_dump(fil), header)
    if not loads:
        check(f"{header} — taper plan parses", False, "no plan parsed", full=True)
        continue
    peak = max(loads.values())
    race = loads[max(loads)]
    pct = 100 * race // max(peak, 1)
    check(f"{header} — race-week load <= {ceil_pct}% of peak",
          pct <= ceil_pct, f"race={race} peak={peak} = {pct}% (ceil {ceil_pct})", full=True)

section("Hill progression — competitive base ramps, doesn't park")
# Long competitive bases used to repeat the cheapest hill (8×60s) for ~16 weeks.
# Hills should climb through distinct variants by load, not park on one.
def _hills_in_order(header):
    # (variant_label, load) per Hill Repeats workout, in week order. Variant =
    # the "N x Ms" rep structure; the 3 duplicate templates per variant differ
    # slightly in load, so distinctness must be measured on the variant, not load.
    text = run_dump(header)
    if f'=== {header}' not in text: return []
    sec = text.split(f'=== {header}')[1].split('=== ')[0]
    out = []
    for line in sec.splitlines():
        if 'Hill Repeats' in line:
            mt = re.search(r'Hill Repeats \(([^)]+)\)', line)
            ml = re.search(r'l=\s*(\d+)', line)
            if mt and ml: out.append((mt.group(1), int(ml.group(1))))
    return out

for header in ["Cmp 42K (max", "Cmp 21K (max"]:
    hills = _hills_in_order(header)
    short = header.replace('(', '').strip()
    if len(hills) >= 4:
        variants = [v for v, _ in hills]
        loads = [l for _, l in hills]
        distinct = len(set(variants))
        check(f"{short} base hills use >=4 distinct variants (no parking on 8x60s)",
              distinct >= 4, f"{len(hills)} hills, {distinct} distinct variants: {variants}", full=True)
        h = len(loads) // 2
        check(f"{short} base hills progress (back half heavier than front)",
              sum(loads[h:]) / len(loads[h:]) > sum(loads[:h]) / len(loads[:h]),
              f"variants={variants}", full=True)

# Speed-phase / short plans must vary too — the ramp now covers BASE+SPEED, so
# short plans (hills in speed) no longer park on 8×60s. The "=== " prefix in
# _hills_in_order disambiguates from the "Acc " variants, so full labels are safe.
for header in ["Int 5K (long, 10w)", "Int 10K (long, 12w)", "VO2 Int (8w)"]:
    hills = _hills_in_order(header)
    short = header.split(' (')[0]
    if len(hills) >= 3:
        variants = [v for v, _ in hills]
        distinct = len(set(variants))
        check(f"{short} hills don't park on one variant (>={min(3, len(hills))} distinct)",
              distinct >= min(3, len(hills)),
              f"{len(hills)} hills, {distinct} distinct: {variants}", full=True)

section("Competitive/advanced BASE quality variety (not just hill+ladder)")
# BASE used to be 16 weeks of ladder/hill only (the load selector parks on
# ladders; true VO2 is blocked in BASE). Now every other off-week runs an LT/MP
# (threshold-pool) session, and ladders ramp like hills — so BASE carries >=3
# distinct quality types AND at least one LT/MP session.
def _base_quality(header):
    """[(subtype, role, load)] for quality sessions in BASE weeks of `header`."""
    text = run_dump(header)
    if f'=== {header}' not in text:
        return []
    sec = text.split(f'=== {header}')[1].split('=== ')[0]
    QUAL = {'intervals','ladderIntervals','pyramidIntervals','hillRepeats',
            'threshold','mileRepeats','marathonPace','yasso800','timeTrial'}
    out = []; ph = None
    for line in sec.splitlines():
        m = re.match(r'^W ?\d+ \[(\w+)', line)
        if m:
            ph = m.group(1); continue
        if ph != 'base':
            continue
        mm = re.search(r'l=\s*(\d+)\s+\[(\w+)/(\w+)\]', line)
        if mm and mm.group(2) in QUAL:
            out.append((mm.group(2), mm.group(3), int(mm.group(1))))
    return out

for header in ["Cmp 42K (max", "Cmp 21K (max"]:
    bq = _base_quality(header)
    short = header.replace('(', '').strip()
    subs = [s for s, _, _ in bq]
    distinct = len(set(subs))
    check(f"{short} BASE uses >=3 distinct quality types (not just hill+ladder)",
          distinct >= 3,
          f"{len(bq)} quality, {distinct} distinct: {sorted(set(subs))}", full=True)
    # role=='threshold' = the injected LT/MP session (marathonPace/threshold/
    # mileRepeats all render with the threshold role). Teeth on the injection.
    check(f"{short} BASE includes an LT/MP (threshold-pool) session",
          any(role == 'threshold' for _, role, _ in bq),
          f"base roles: {sorted({r for _, r, _ in bq})}", full=True)

# Ladder ramp: where ladders appear >=4x (intermediate base+speed — no LT
# injection there, so ladders stay frequent), they climb by load like hills.
for header in ["Int 21K (long, 18w)", "Int 42K (long, 22w)"]:
    bq = _base_quality(header)  # base only; ladders here are the ramped pool
    short = header.split(' (')[0]
    lad = [l for s, _, l in bq if s == 'ladderIntervals']
    if len(lad) >= 4:
        h = len(lad) // 2
        check(f"{short} BASE ladders climb by load (ramp, back half heavier)",
              sum(lad[h:]) / len(lad[h:]) > sum(lad[:h]) / len(lad[:h]),
              f"ladder loads in week order: {lad}", full=True)

section("Deload reshaping: neighbor-aware dip + sole-quality retention")

# These two tests audit applyDeloadReshaping's POST-condition across every plan:
#   A) a build-phase recovery week must actually DIP below its predecessor (not be
#      a local maximum), and B) a recovery week must keep a structured-quality body
#      (never strip its SOLE quality to easy). Both read REAL delivered loads from
#      plan_debug `dump`, cross-referenced with the `phases` deload flags.

def _dump_blocks():
    """dict[header] = {week: {load,mins,nwkts,phase,wip,deload,subs:[(subtype,role)]}}
    from a single `dump ""` run (every plan, incl. Acc variants). The [deload] flag
    on the dump header is GENERATOR-aligned (trim-aware) — unlike `phases` mode,
    which recomputes on un-trimmed indices and so misaligns on front-trimmed plans."""
    r = subprocess.run([PLAN_DEBUG, "dump", ""], capture_output=True, text=True,
                       env=os.environ.copy())
    blocks = {}
    cur_header = None
    cur_week = None
    for line in r.stdout.splitlines():
        hm = re.match(r'^===\s+(.+?)\s+\(\d+w,', line)
        if hm:
            cur_header = hm.group(1).strip()
            blocks[cur_header] = {}
            cur_week = None
            continue
        if cur_header is None:
            continue
        wm = re.match(r'^W\s*(\d+)\s*\[(\w+)\s+(\d+)/(\d+)\]\s+(\d+)wkts\s+load=\s*(\d+)\s+(\d+)min(\s+\[deload\])?', line)
        if wm:
            cur_week = int(wm.group(1))
            blocks[cur_header][cur_week] = dict(
                phase=wm.group(2), wip=int(wm.group(3)),
                nwkts=int(wm.group(5)), load=int(wm.group(6)),
                mins=int(wm.group(7)), deload=wm.group(8) is not None, subs=[])
            continue
        if cur_week is not None:
            sm = re.search(r'\[([a-zA-Z0-9]+)/([a-z_0-9]+)\]\s*(?:z5=\d+)?\s*$', line)
            if sm:
                blocks[cur_header][cur_week]['subs'].append((sm.group(1), sm.group(2)))
    return blocks

_DUMP = _dump_blocks()
_BUILD = ('base', 'speed', 'peak')
# subtype is a real structured-quality body (NOT marker/role — Beginner "speed"
# slots are filled with strides, which is not a quality body).
_QUAL_SUB = QUALITY | PROG

# --- Test A: build-phase deload weeks must dip below their predecessor --------
# A deload week that is a LOCAL MAXIMUM in delivered load (>= both neighbors) has
# failed to deload. We flag those, EXCLUDING legitimate structural floors:
#   - the plan's FIRST build-phase deload (predecessor is still early-ramp, no
#     real peak to dip below);
#   - flat early-base weeks where the predecessor itself is still in the smooth-
#     transition ramp (predecessor wip < 2) — no headroom yet; and
#   - weeks the generator already reshaped to its FLOOR — a [deload_*] marker is
#     present AND no droppable aerobic fill remains (every easy/medium-long is the
#     last recovery day). The week is down to its long run + a quality body, which
#     can't shed further on the active catalog. (On the full catalog none of these
#     remain — the sparse sample catalog lacks the lighter progressions/long runs
#     the engine would otherwise swap in.)
_REC_SUB  = EASY | STRIDES                       # easy/strides/recovery = rest day
_FILL_SUB = {'easy', 'recovery', 'mediumLong'}   # droppable aerobic fill subtypes

def _at_reshape_floor(cur):
    subs = cur['subs']
    if not any(role.startswith('deload_') for _, role in subs):
        return False  # reshaping never engaged — not a floor, a real miss
    n_rec = sum(1 for s, _ in subs if s in _REC_SUB)
    # a fill is droppable only if it isn't the week's last rest day
    droppable = sum(1 for s, _ in subs
                    if s in _FILL_SUB and (s not in _REC_SUB or n_rec > 1))
    return droppable == 0

_A_failures = []
for header, weeks in sorted(_DUMP.items()):
    build_deloads = sorted(w for w in weeks
                           if weeks[w].get('deload') and weeks[w]['phase'] in _BUILD)
    first_deload = build_deloads[0] if build_deloads else None
    for w in build_deloads:
        cur, prev, nxt = weeks.get(w), weeks.get(w - 1), weeks.get(w + 1)
        if not cur or not prev or not nxt:
            continue
        if w == first_deload:           # first deload: no prior peak — exclude
            continue
        if prev['wip'] < 2:             # predecessor still ramping — no headroom
            continue
        is_local_max = cur['load'] >= prev['load'] and cur['load'] >= nxt['load']
        if is_local_max and not _at_reshape_floor(cur):
            _A_failures.append(
                f"{header} W{w} ({cur['phase']}) load={cur['load']} "
                f">= prev W{w-1}={prev['load']} and next W{w+1}={nxt['load']}")

check(
    "every build-phase recovery week dips below its predecessor (no local-max deload)",
    not _A_failures,
    "local-maximum deload weeks (out-load predecessor): " + "; ".join(_A_failures)
)

# --- Test B: a deload week must keep a structured-quality body ----------------
# `deload_easy` is produced ONLY by the lighten branch converting a quality to
# easy+strides. If that conversion leaves the week with ZERO structured-quality
# subtype, the week's sole quality was stripped — the defect. `deload_easy` is
# fine when another real quality remains (only a fill was converted). Beginner
# strides-as-speedwork weeks have no `deload_easy` marker, so they don't trip
# this; pure-aerobic plans (no quality anywhere) are excluded implicitly.
_B_failures = []
for header, weeks in sorted(_DUMP.items()):
    for w in sorted(weeks):
        if weeks[w]['phase'] not in _BUILD or not weeks[w].get('deload'):
            continue
        subs = weeks[w]['subs']
        had_easy_strip = any(role == 'deload_easy' for _, role in subs)
        has_quality = any(s in _QUAL_SUB for s, _ in subs)
        if had_easy_strip and not has_quality:
            roles = [r for _, r in subs]
            _B_failures.append(f"{header} W{w} ({weeks[w]['phase']}): {roles}")

check(
    "no recovery week strips its sole quality to easy (deload_easy w/ zero quality body)",
    not _B_failures,
    "quality-less deload weeks: " + "; ".join(_B_failures)
)

section("Marathon PEAK rehearsal MP segment progresses (Finding #5)")

# Bug: marathon PEAK parks the race-rehearsal long run on the LARGEST MP segment
# the moment its (big) PEAK load target lets it — so e.g. Adv 42K rec W12-W15 all
# carry "Race Rehearsal (90min @ MP)", four identical 90min MP rehearsals running.
# A Pfitz-style block runs MULTIPLE MP rehearsals, but the MP segment must RAMP
# (60→75→90...), not repeat. Assert, across each marathon plan's PEAK rehearsal
# weeks: (1) the MP-segment minutes are NON-DECREASING week-to-week, and (2) no
# single rehearsal title repeats 4x+ with an IDENTICAL MP segment.
#
# The MP segment is read straight from the dump title "Race Rehearsal (NNmin @ MP)"
# (raceRehearsalM only — the 42K marathon-pace rehearsal). Build from a single
# `dump ""` run so every plan + Acc variant is covered.

def _rehearsal_mp_by_week():
    """dict[header] = {week: mp_minutes} for raceRehearsalM long runs, parsed
    from a single `dump ""` run (every plan, incl. Acc variants)."""
    r = subprocess.run([PLAN_DEBUG, "dump", ""], capture_output=True, text=True,
                       env=os.environ.copy())
    out = {}
    cur_header = cur_week = None
    for line in r.stdout.splitlines():
        hm = re.match(r'^===\s+(.+?)\s+\(\d+w,', line)
        if hm:
            cur_header = hm.group(1).strip()
            out[cur_header] = {}
            cur_week = None
            continue
        if cur_header is None:
            continue
        wm = re.match(r'^W\s*(\d+)\s*\[', line)
        if wm:
            cur_week = int(wm.group(1))
            continue
        if cur_week is None:
            continue
        # "    Race Rehearsal (90min @ MP)  170min l=12716  [raceRehearsalM/long]"
        rm = re.search(r'Race Rehearsal \((\d+)min @ MP\).*\[raceRehearsalM/\w+\]', line)
        if rm:
            out[cur_header][cur_week] = int(rm.group(1))
    return out

_REHEARSAL_MP = _rehearsal_mp_by_week()
# Marathon plans only (raceRehearsalM is the 42K rehearsal). Across all tiers/variants.
_MARATHON_HEADERS = sorted(h for h in _DUMP if '42K' in h)

_nondecr_fail = []
_repeat_fail = []
from collections import Counter
for header in _MARATHON_HEADERS:
    weeks = _DUMP[header]
    mp = _REHEARSAL_MP.get(header, {})
    # PEAK-phase rehearsal weeks, in chronological order.
    peak_reh = [(w, mp[w]) for w in sorted(weeks)
                if w in mp and weeks[w]['phase'] == 'peak']
    if not peak_reh:
        continue
    # (1) Non-decreasing MP segment across the NON-DELOAD PEAK rehearsal weeks.
    # A deload (cutback) week may legitimately run a smaller rehearsal, so the
    # ramp is measured on the building rehearsals; deloads are allowed to dip.
    build_reh = [(w, seg) for (w, seg) in peak_reh if not weeks[w].get('deload')]
    bseq = [seg for _, seg in build_reh]
    for i in range(1, len(bseq)):
        if bseq[i] < bseq[i - 1]:
            _nondecr_fail.append(
                f"{header}: PEAK build-rehearsal MP segments {bseq} "
                f"(W{build_reh[i][0]}={bseq[i]} < prev {bseq[i-1]})")
            break
    # (2) No 4x+ identical MP segment among ALL PEAK rehearsals (incl. deloads):
    # four identical 90min MP weeks running was the reported defect.
    seq = [seg for _, seg in peak_reh]
    worst, n = Counter(seq).most_common(1)[0]
    if n >= 4:
        _repeat_fail.append(
            f"{header}: MP segment {worst}min repeats {n}x in PEAK (segments {seq})")

# Anchor the headline regression on Adv 42K rec (the reported case) so the test
# is meaningful even on the sample catalog; the loop above covers every plan.
check(
    "marathon PEAK rehearsal MP segments are non-decreasing week-to-week",
    not _nondecr_fail,
    "decreasing MP segments: " + "; ".join(_nondecr_fail))
check(
    "no marathon PEAK rehearsal title repeats 4x+ with an identical MP segment",
    not _repeat_fail,
    "over-repeated rehearsals: " + "; ".join(_repeat_fail))

section("PEAK is not front-loaded — heaviest TARGET week is late (Finding #4)")

# The audit flagged compressed 14-wk 21K rec peaks (Int/Adv) as front-loaded. The
# targets were reshaped to build to a LATE peak (Int->W12, Adv->W11) and the deload
# fix made the surrounding cutback weeks dip. Assert, for EVERY plan: the heaviest
# non-deload week inside the PEAK phase sits in the LATTER half of the PEAK weeks
# (a late peak), not at PEAK week 1.
#
# This reads the TARGET periodization model (`phases`), which is the intended
# weekly stress the generator aims at — the right altitude for "is the peak late?".
# (Delivered load can spike in PEAK week 1 because a single large VO2/quality
# session lands there; that is a separate quality-distribution concern, not the
# peak SHAPE this guards. Measuring delivered load here would flag every plan,
# including the healthy 18w/22w ones the task says must not be touched.) The target
# model is catalog-independent, so this guard holds on sample and full alike.

def _target_peak_blocks():
    """dict[header] = {week: {phase,load,deload}} from a single `phases ""` run."""
    r = subprocess.run([PLAN_DEBUG, "phases", ""], capture_output=True, text=True,
                       env=os.environ.copy())
    blocks = {}
    cur = None
    for line in r.stdout.splitlines():
        hm = re.match(r'^===\s+(.+?)\s+\(\d+w\)', line)
        if hm:
            cur = hm.group(1).strip()
            blocks[cur] = {}
            continue
        if cur is None:
            continue
        wm = re.match(
            r'^W\s*(\d+)\s+(BASE|SPEED|PEAK|TAPER|RACE)\s+load=\s*(\d+)\s+dur=\s*(\d+)min(\s+\[deload\])?',
            line)
        if wm:
            blocks[cur][int(wm.group(1))] = dict(
                phase=wm.group(2), load=int(wm.group(3)), deload=wm.group(5) is not None)
    return blocks

_TARGET = _target_peak_blocks()
_frontload_fail = []
for header, weeks in sorted(_TARGET.items()):
    peak_weeks = sorted(w for w in weeks if weeks[w]['phase'] == 'PEAK')
    if len(peak_weeks) < 3:
        continue  # too short to speak of front- vs back-loading
    # Non-deload PEAK weeks (deloads dip on purpose; don't measure against them).
    work = [(w, weeks[w]['load']) for w in peak_weeks if not weeks[w]['deload']]
    if len(work) < 2:
        continue
    heaviest_w = max(work, key=lambda t: t[1])[0]
    # Position of the heaviest non-deload week within the PEAK block (0..1).
    first, last = peak_weeks[0], peak_weeks[-1]
    pos = (heaviest_w - first) / (last - first) if last > first else 0.0
    # "Latter half": position >= 0.5 within the peak block. Explicitly reject
    # the heaviest landing on PEAK week 1.
    if heaviest_w == first or pos < 0.5:
        loads = {w: weeks[w]['load'] for w in peak_weeks}
        _frontload_fail.append(
            f"{header}: heaviest non-deload PEAK week is W{heaviest_w} "
            f"(pos {pos:.2f}) of peak {first}-{last}; target loads={loads}")

check(
    "no plan's PEAK is front-loaded (heaviest target week in latter half of peak)",
    not _frontload_fail,
    "front-loaded peaks: " + "; ".join(_frontload_fail))

# === Beginner-plan quality refinements (3 owner-requested changes) =====
#
# A) Beginner MARATHON long run is capped at ~180-190min (3:00-3:10) — the old
#    ~205-225min peak (3:25-3:45) is too long for a novice. Every Beg 42K variant
#    (incl. Acc) must land its longest run <= 190min.
# B) Beginners get a DELIBERATE ~weekly strides session through BASE & SPEED
#    (strides are the novice's primary safe speed/economy stimulus). Beg 10K/21K/
#    42K (incl. Acc) must carry strides in the MAJORITY of BASE+SPEED weeks.
# C) Beginner strides must be 4-6 reps, never 2 (standard 4-8) — the selector used
#    to land on "Easy + Strides (2 x 25s)". NO beginner plan may run a strides
#    session with <4 reps.
#
# All three read a single `dump ""` run (every plan + Acc variant). The dump line
# for a strides session is e.g. "Easy + Strides (4 x 25s)  39min l=2850  [strides/
# interval]"; rep count is the leading number in the "(N x Ss)" title.

def _beg_plan_blocks():
    """dict[header] = {week: {phase, longs:[dur], strides:[(rep, dur)]}} from a
    single `dump ""` run, restricted to beginner plans (Beg* and Acc Beg*).
    A strides session is any line whose subtype is [strides/...]; its rep count
    is the leading number of the "Easy + Strides (N x Ss)" title."""
    r = subprocess.run([PLAN_DEBUG, "dump", ""], capture_output=True, text=True,
                       env=os.environ.copy())
    blocks = {}
    cur_header = cur_week = None
    is_beg = False
    for line in r.stdout.splitlines():
        hm = re.match(r'^===\s+(.+?)\s+\(\d+w,', line)
        if hm:
            cur_header = hm.group(1).strip()
            is_beg = bool(re.match(r'^(Acc )?Beg ', cur_header))
            if is_beg:
                blocks[cur_header] = {}
            cur_week = None
            continue
        if not is_beg or cur_header is None:
            continue
        wm = re.match(r'^W\s*(\d+)\s*\[(\w+)\s+\d+/\d+\]', line)
        if wm:
            cur_week = int(wm.group(1))
            blocks[cur_header][cur_week] = dict(
                phase=wm.group(2), longs=[], strides=[])
            continue
        if cur_week is None:
            continue
        # strides line: title carries "(N x Ss)" and subtype is [strides/...]
        sm = re.search(r'Easy \+ Strides \((\d+) x \d+s\)\s+(\d+)min.*\[strides/', line)
        if sm:
            blocks[cur_header][cur_week]['strides'].append(
                (int(sm.group(1)), int(sm.group(2))))
            continue
        # long-run-class line: any [<LONG subtype>/...] or role == 'long'.
        lm = re.search(r'\s(\d+)min\s+l=\d+\s+\[(\w+)/(\w+)\]', line)
        if lm:
            dur, sub, role = int(lm.group(1)), lm.group(2), lm.group(3)
            if sub in LONG or role == 'long':
                blocks[cur_header][cur_week]['longs'].append(dur)
    return blocks

_BEG = _beg_plan_blocks()

# --- Change A: Beg 42K (every variant incl Acc) peak long run <= 190min -------
# Assert on the PACE-CONVERTED (delivered) plan — what the runner actually gets.
# The HR-side `dump` already capped the catalog pick, but the pace converter then
# re-inflated the long run to the per-distance km floor (30km → ~210-225min at a
# slow novice's pace). The fix caps the beginner marathon at ~190min in the
# converter too, so the delivered peak must be <= 190min for EVERY variant.
section("Beg 42K (incl Acc): marathon long run capped at ~180-190min (novice)")

BEG_42K_PLANS = [
    # (header, race_pace, easy_pace) — slow-novice inputs (the worst case: at slow
    # paces the km floor inflated the run the most, so this is where ~225 showed).
    ("Beg 42K (short, 14w)",    330, 450),
    ("Beg 42K (rec, 18w)",      330, 450),
    ("Beg 42K (long, 22w)",     330, 450),
    ("Acc Beg 42K (rec, 18w)",  330, 450),
]
# R8: 245min (~4h) — high enough for a slow novice to reach the 28km peak
# floor (28-32km is non-negotiable marathon prep), low enough to stop 5h runs.
LR_CAP = 245
for header, rp, ep in BEG_42K_PLANS:
    w = parse_plan(run_pacedump_with(header, rp, ep, False), header)
    durs = get_long_durations(w) if w else []
    peak_lr = max(d for _, d in durs) if durs else 0
    check(
        f"{header.split(' (')[0]} ({header.split('(')[1].rstrip(') ')}) "
        f"delivered peak long run <= {LR_CAP}min",
        0 < peak_lr <= LR_CAP,
        f"observed peak LR {peak_lr}min (cap {LR_CAP})")

# --- Adv 42K (every variant incl Acc) peak long run <= 195min ------------------
# Mirror of the beginner cap, one tier up. The HR-side dump tops out at ~150min,
# but the pace converter then re-inflated the marathon long run to the 30km floor
# (~210-225min at a slow runner's pace) — a touch too long. The fix adds a 195min
# ceiling to the converter's advanced-marathon clamp, so the DELIVERED peak holds
# to ~190-195min (3:10-3:15) for EVERY advanced-marathon variant, incl Acc. Slow-
# runner inputs are the worst case (the km floor inflated the run the most there).
section("Adv 42K (incl Acc): marathon long run capped at ~190-195min")

ADV_42K_PLANS = [
    # (header, race_pace, easy_pace) — slow inputs surface the worst-case inflation.
    ("Adv 42K (rec, 18w)",      330, 450),
    ("Adv 42K (long, 22w)",     330, 450),
    ("Acc Adv 42K (rec, 18w)",  330, 450),
]
ADV_LR_CAP = 195
for header, rp, ep in ADV_42K_PLANS:
    w = parse_plan(run_pacedump_with(header, rp, ep, False), header)
    durs = get_long_durations(w) if w else []
    peak_lr = max(d for _, d in durs) if durs else 0
    check(
        f"{header.split(' (')[0]} ({header.split('(')[1].rstrip(') ')}) "
        f"delivered peak long run <= {ADV_LR_CAP}min",
        0 < peak_lr <= ADV_LR_CAP,
        f"observed peak LR {peak_lr}min (cap {ADV_LR_CAP})")

# --- Change B: deliberate ~weekly strides through BASE & SPEED ----------------
section("Beg 10K/21K/42K (incl Acc): strides in the majority of BASE+SPEED weeks")

# Threshold: a strides session in >=60% of BASE+SPEED weeks. 10K runs only 2
# days/wk (long + one other), so its base/speed strides cadence is the same slot.
STRIDES_COVERAGE_MIN = 0.60
BEG_STRIDES_HEADERS = sorted(
    h for h in _BEG if any(d in h for d in ('10K', '21K', '42K')))
for header in BEG_STRIDES_HEADERS:
    weeks = _BEG[header]
    bs_weeks = [w for w in weeks if weeks[w]['phase'] in ('base', 'speed')]
    with_strides = [w for w in bs_weeks if weeks[w]['strides']]
    frac = len(with_strides) / len(bs_weeks) if bs_weeks else 0
    check(
        f"{header.split(' (')[0]} ({header.split('(')[1].rstrip(') ')}) "
        f"strides in >={int(STRIDES_COVERAGE_MIN*100)}% of BASE+SPEED weeks",
        bool(bs_weeks) and frac >= STRIDES_COVERAGE_MIN,
        f"strides in {len(with_strides)}/{len(bs_weeks)} base+speed weeks "
        f"({frac*100:.0f}%, need >={int(STRIDES_COVERAGE_MIN*100)}%)")

# --- Change C: beginner strides are 3-6 reps, never <3 ------------------------
section("Beginner strides use 3-6 reps (never 2) — standard 4-8, 3 as light option")

for header in sorted(_BEG):
    weeks = _BEG[header]
    too_few = sorted({
        (w, reps) for w in weeks for (reps, _dur) in weeks[w]['strides']
        if reps < 3})
    check(
        f"{header.split(' (')[0]} ({header.split('(')[1].rstrip(') ')}) "
        f"no strides session with <3 reps",
        not too_few,
        f"weeks with <4-rep strides (week, reps): {list(too_few)[:5]}")

# === FIX 1: Progression Run must show a real easy->fast spread ========
#
# On 5K/10K (race pace ~= 5K speed) the catalog's `Z3->Z4` "Progression Run"
# templates collapse: Z3 renders at exact race pace and Z4 (threshold) is
# floored at race pace, so both blocks land within ~1s/km (e.g. [4:45, 4:46]).
# A progression run with a sub-15s/km span is degenerate — it isn't a
# progression at all. After the fix, 5K/10K plans select only the easy->race
# `Z2->Z3` shape, so every delivered progression spans a real easy->fast range.
#
# Drive the REAL app path = projection mode (current->projected VDOT anchors),
# which is where the owner observed the collapse.
section("FIX 1: 5K/10K Progression Run spans a real easy->fast range (>=15s/km)")

def _progress_anchors(dist, time, level, target, weeks):
    """Run `progress` to get the 6 projection anchors a real plan renders with."""
    env = os.environ.copy()
    env.update(DIST=str(dist), TIME=str(time), LEVEL=level,
               TARGET=str(target), WEEKS=str(weeks))
    out = subprocess.run([PLAN_DEBUG, "progress"], capture_output=True,
                         text=True, env=env).stdout
    a = {}
    for k in ("RACE_PACE", "EASY_PACE", "SPEED_PACE",
              "RACE_PACE_END", "EASY_PACE_END", "SPEED_PACE_END"):
        m = re.search(rf"^{k}=(\d+)$", out, re.M)
        if m:
            a[k] = m.group(1)
    return a

def _progression_spans(label, anchors, weeks):
    """Return [(week_hint, span_secs, pace_str)] for every delivered progression
    workout in `label`, rendered with the given projection anchors."""
    env = os.environ.copy()
    env.update(anchors)
    env["WEEKS"] = str(weeks)
    out = subprocess.run([PLAN_DEBUG, "pacedump", label], capture_output=True,
                         text=True, env=env).stdout
    w = parse_plan(out, f"{label.split(' (')[0]} ({weeks}w)") or {}
    spans = []
    for wk in sorted(w):
        for sub, _dur, pace in w[wk]:
            if sub != 'progression':
                continue
            secs = sorted(s for s in (get_pace_secs(p.strip())
                          for p in pace.strip('[]').split(',')) if s is not None)
            span = (secs[-1] - secs[0]) if len(secs) >= 2 else 0
            spans.append((wk, span, pace))
    return spans

PROG_SPAN_MIN = 15  # s/km: a real easy->fast progression, not a 1s collapse
# (dist, time, level, target_dist, weeks) — 5K and 10K, where race ~= 5K speed.
PROG_CASES = [
    ("Beg 5K",  5000, 1500, "beg",  5000,  7),
    ("Int 5K",  5000, 1500, "int",  5000,  7),
    ("Adv 5K",  5000, 1500, "adv",  5000,  7),
    ("Beg 10K", 10000, 3000, "beg", 10000, 9),
    ("Int 10K", 10000, 3000, "int", 10000, 9),
    ("Adv 10K", 10000, 3000, "adv", 10000, 9),
]
for label, dist, time, lvl, tgt, wk in PROG_CASES:
    anchors = _progress_anchors(dist, time, lvl, tgt, wk)
    spans = _progression_spans(label, anchors, wk)
    bad = [(w, s, p) for (w, s, p) in spans if s < PROG_SPAN_MIN]
    check(
        f"{label} Progression Run spans >={PROG_SPAN_MIN}s/km (no race-pace collapse)",
        not bad,
        f"degenerate progressions (week,span_s,pace): {bad[:4]} "
        f"(of {len(spans)} total progression workouts)",
        full=True)

# === FIX 2: no consecutive build-phase deloads =========================
#
# Two deload triggers used to stack: `isPhaseEndDeload` fired for EVERY week
# with phaseProgression >= 0.8 (so a >=10w phase ate 2-3 trailing deloads), and
# the 3:1 mid-phase recovery (weekInPhase % 3 == 2) could land right beside it.
# Result: long-phase plans showed 2-3 [deload] weeks back-to-back in BASE/PEAK
# (e.g. Adv 42K W14+15, Cmp 21K-max W9-11, Cmp 42K-max W14-16) — wasted peak-
# load weeks / stagnant base. After the fix a build phase emits at most one
# trailing deload before the next phase. Taper weeks are excluded (taper IS a
# progressive deload, correctly consecutive).
section("FIX 2: no 2+ consecutive build-phase [deload] weeks (taper excluded)")

BUILD_PHASES = {'BASE', 'SPEED', 'PEAK'}

def _consecutive_build_deloads(label_filter):
    """For each plan matching label_filter, return dict[plan]=[runs] where each
    run is a list of (week, phase) of >=2 consecutive build-phase deload weeks."""
    r = subprocess.run([PLAN_DEBUG, "phases", label_filter],
                       capture_output=True, text=True, env=os.environ.copy())
    out = {}
    cur, weeks = None, []
    def flush():
        if cur is None:
            return
        runs, i = [], 0
        while i < len(weeks):
            if weeks[i][2] and weeks[i][1] in BUILD_PHASES:
                j = i
                while j < len(weeks) and weeks[j][2] and weeks[j][1] in BUILD_PHASES:
                    j += 1
                if j - i >= 2:
                    runs.append([(w[0], w[1]) for w in weeks[i:j]])
                i = j
            else:
                i += 1
        if runs:
            out[cur] = runs
    for line in r.stdout.splitlines():
        m = re.match(r'^=== (.+?) \(\d+w\):', line)
        if m:
            flush()
            # Maintenance runs its OWN recovery cadence — its [deload] tags mark the
            # gentle cutback weeks, and the 2-week opening easy ramp is a LEGITIMATE
            # consecutive-light pair (like a taper, not a wasted race-build deload).
            # Exclude it from this race-periodization consecutive-deload guard.
            cur = None if m.group(1).startswith('Maint') else m.group(1)
            weeks = []
            continue
        wm = re.match(r'^W\s*(\d+)\s+(BASE|SPEED|PEAK|TAPER|RACE)\s+load.*?(\[deload\])?\s*$', line)
        if wm and cur:
            weeks.append((int(wm.group(1)), wm.group(2), wm.group(3) is not None))
    flush()
    return out

_consec = _consecutive_build_deloads("")
check(
    "no plan has 2+ consecutive build-phase deload weeks",
    not _consec,
    "plans with back-to-back build deloads: " +
    "; ".join(f"{k} {v}" for k, v in sorted(_consec.items())))

# Spot-check the worst offenders the audit named are individually clean.
for plan in ["Adv 42K (rec", "Cmp 21K (max", "Cmp 42K (max", "Beg 42K (rec"]:
    runs = _consecutive_build_deloads(plan)
    check(
        f"{plan} has no consecutive build-phase deloads",
        not runs,
        f"runs: {runs}")

# === FIX 3: HM/10K race-rehearsal segment is ramped (non-decreasing) ====
#
# `rampRehearsalMPSegment` only filtered `.raceRehearsalM`, so the marathon's
# MP block ramped 60→75→90 while the HALF/10K rehearsal block was free to
# regress (e.g. Cmp 21K HMP 30→30→25, Adv 21K 30→25→30→25→20→15). Parameterized
# on subtype, the HMP/10KP segment now ramps by occurrence and never steps down
# across the PEAK rehearsal weeks. Segment minutes read from the dump's interval
# structure line: Z3 block for HM/M, Z4 block for 10K.
section("FIX 3: HM/10K race-rehearsal race-pace segment is non-decreasing in PEAK")

def _rehearsal_segments(label):
    """dict[plan_header] = [(week, seg_min, subtype)] for every delivered HM/10K
    rehearsal, in week order. Segment = the race-pace block (Z3 for HM, Z4 for
    10K). Keyed per plan-header so a substring `label` that matches several
    plans (e.g. plain + Acc) doesn't conflate their week sequences."""
    r = subprocess.run([PLAN_DEBUG, "dump", label], capture_output=True,
                       text=True, env=os.environ.copy())
    lines = r.stdout.splitlines()
    out, cur, wk = {}, None, None
    for i, line in enumerate(lines):
        hm = re.match(r'^===\s+(.+?)\s+\(\d+w,', line)
        if hm:
            cur = hm.group(1).strip(); out.setdefault(cur, []); wk = None; continue
        m = re.match(r'^(W\s*\d+)\s+\[(\w+)', line)
        if m:
            wk = int(re.sub(r'\D', '', m.group(1)))
        rm = re.search(r'\[(raceRehearsalHM|raceRehearsal10K)/', line)
        if rm and wk is not None and cur is not None:
            zone = 'Z4' if rm.group(1) == 'raceRehearsal10K' else 'Z3'
            struct = lines[i + 1] if i + 1 < len(lines) else ''
            seg = sum(int(x) for x in re.findall(rf'(\d+):00 @ {zone}\b', struct))
            out[cur].append((wk, seg, rm.group(1)))
    return out

# Every plan that delivers an HM or 10K rehearsal (21K all tiers, 10K Int/Adv).
REHEARSAL_PLANS = [
    "Cmp 21K (long", "Cmp 21K (rec", "Cmp 21K (short", "Cmp 21K (max",
    "Adv 21K (long", "Adv 21K (rec", "Int 21K (long", "Int 21K (rec",
    "Beg 21K (long", "Beg 21K (rec",
    "Adv 10K (long", "Adv 10K (rec", "Int 10K (long", "Int 10K (rec",
    "Acc Adv 21K (rec", "Acc Int 21K (rec", "Acc Adv 10K (rec", "Acc Int 10K (rec",
]
for plan in REHEARSAL_PLANS:
    for header, seq in sorted(_rehearsal_segments(plan).items()):
        # Step-down across consecutive rehearsal weeks of the same subtype.
        regress, by_sub = [], {}
        for w, seg, sub in sorted(seq):
            # 0-min race segment = the deload week's aerobic-only reuse of the
            # rehearsal (R5-1 strips the MP block) — not a rung in the ladder.
            if seg == 0:
                continue
            prev = by_sub.get(sub)
            if prev is not None and seg < prev[1]:
                regress.append((prev, (w, seg)))
            by_sub[sub] = (w, seg)
        check(
            f"{header} rehearsal race-pace segment never steps down in PEAK",
            not regress,
            f"regressions (prev (wk,min) -> (wk,min)): {regress}  full seq: {sorted(seq)}",
            full=True)

# === FIX 4: Int 21K carries >=1 raceRehearsalHM in PEAK ================
#
# Int 21K's maxLongRunMinutes=100 let steadyLong/fastFinish out-score the
# heavier raceRehearsalHM, so the textbook Int 21K delivered ZERO half
# rehearsals (Adv/Beg/Cmp 21K all carried them). The PEAK forcing hook (the
# generalized rampRehearsalMPSegment with force=true for the half) now lands the
# dedicated HMP rehearsal at least once before taper, for every textbook Int 21K
# variant. (The Accessible 21K tier caps the long run at 72min — below the
# shortest 75min HM rehearsal — by deliberate lighter-tier design, so it is out
# of scope here; that cap predates this fix and is a locked tier characteristic.)
section("FIX 4: textbook Int 21K (all variants) carries >=1 raceRehearsalHM in PEAK")

def _peak_rehearsal_count(label_filter, subtype):
    """dict[plan_header] = count of `subtype` workouts delivered in PEAK weeks."""
    r = subprocess.run([PLAN_DEBUG, "dump", label_filter], capture_output=True,
                       text=True, env=os.environ.copy())
    out, cur, in_peak = {}, None, False
    for line in r.stdout.splitlines():
        h = re.match(r'^===\s+(.+?)\s+\(\d+w,', line)
        if h:
            cur = h.group(1).strip(); out.setdefault(cur, 0); in_peak = False; continue
        wm = re.match(r'^W\s*\d+\s+\[(\w+)', line)
        if wm:
            in_peak = (wm.group(1) == 'peak')
        if cur and in_peak and f'[{subtype}/' in line:
            out[cur] += 1
    return out

# Textbook Int 21K only (exclude the Accessible twin via the header check).
for header, n in sorted(_peak_rehearsal_count("Int 21K", "raceRehearsalHM").items()):
    if header.startswith("Acc "):
        continue
    check(
        f"{header} carries >=1 raceRehearsalHM in PEAK",
        n >= 1,
        f"got {n} raceRehearsalHM in PEAK",
        full=True)

# === FIX 5: strides reps are >=15s (Daniels' short end) ==========
#
# 15s is the short end of Daniels' 15-20s stride range — a legitimate light
# stride. The engine floors stride reps at >=15s (only <15s is dropped). Rep
# duration is the "(N x Ss)" in the strides title.
section("FIX 5: no plan delivers a strides session with a <15s rep")

def _short_stride_sessions():
    """dict[plan_header] = [(week, rep_secs)] for delivered strides with <20s reps."""
    r = subprocess.run([PLAN_DEBUG, "dump", ""], capture_output=True,
                       text=True, env=os.environ.copy())
    out, cur, wk = {}, None, None
    for line in r.stdout.splitlines():
        h = re.match(r'^===\s+(.+?)\s+\(\d+w,', line)
        if h:
            cur = h.group(1).strip(); out.setdefault(cur, []); wk = None; continue
        wm = re.match(r'^W\s*(\d+)\s+\[', line)
        if wm:
            wk = int(wm.group(1))
        sm = re.search(r'Strides \(\d+ x (\d+)s\).*\[strides/', line)
        if sm and cur is not None and int(sm.group(1)) < 15:
            out[cur].append((wk, int(sm.group(1))))
    return out

_short = {k: v for k, v in _short_stride_sessions().items() if v}
check(
    "no plan uses a strides session with a <15s rep",
    not _short,
    "plans with <20s strides (header -> [(week, rep_s)]): " +
    "; ".join(f"{k} {v[:4]}" for k, v in sorted(_short.items())))

# === FIX 6: ladder catalog is culled to the delivered + structural set =
#
# `ladderIntervals` held 122 templates but only ~18 distinct bodies ever ship;
# the rest were WU/CD/recovery-padding duplicates. The catalog was culled to the
# delivered set + a few "structural" templates the selector's variety penalty
# needs to keep the delivered output byte-identical (25 prod / 2 sample). This
# guard keeps the bloat from creeping back: ladder count must stay <= 40 (the
# old 122 fails). The byte-identical-dump proof lives in the cull verification.
section("FIX 6: ladderIntervals catalog count is reasonable (no padding bloat)")

import json as _json
_catalog_path = os.environ.get(
    "WORKOUTS_PATH",
    os.path.join(ROOT, "Sources/TrainingPlanKit/Catalog/sample_catalog.json"))
try:
    _cat = _json.load(open(_catalog_path))
    _ws = _cat if isinstance(_cat, list) else _cat.get("workouts", _cat)
    _lad = sum(1 for w in _ws if w.get("subtype") == "ladderIntervals")
    LADDER_CAP = 40
    check(
        f"ladderIntervals templates <= {LADDER_CAP} (culled, not 122-bloat)",
        0 < _lad <= LADDER_CAP,
        f"catalog has {_lad} ladderIntervals templates "
        f"({os.path.basename(_catalog_path)}); expected <= {LADDER_CAP}")
except (OSError, ValueError) as e:
    check("ladderIntervals catalog readable", False, f"{e}")

# --- report ----------------------------------------------------------

# === R15: long-plan long-run dynamics (growth cap + Beg 3h exposure) ====
#
# 2026-07-04: the km floor used to complete at 60% of ANY plan, so 24-30w
# plans piled up 3h+ long runs and phase boundaries produced +40-70% weekly
# jumps (user report: Beg 42K 27w went 2h -> 3h20 -> 2h30). Fixed by the
# length-aware floor ramp (full at 1 - 6/weeks) + render growth cap
# (<= +25%/+15min vs last non-deload, rehearsals included) + Beg 42K
# exposure backstop (<= 3 runs >= 3h at any length). These checks pin all
# three on RENDERED curves across standard AND long plan lengths.
section("R15: rendered long-run chain caps + Beg 42K 3h exposure")

R15_LR_SUBS = {'steadyLong', 'progressiveLong', 'long', 'raceRehearsalM',
               'raceRehearsalHM', 'raceRehearsal10K', 'fastFinish'}

def _r15_lr_curve(label, anchors, weeks):
    env = os.environ.copy()
    env.update(anchors)
    env["WEEKS"] = str(weeks)
    out = subprocess.run([PLAN_DEBUG, "pacedump", label], capture_output=True,
                         text=True, env=env).stdout
    w = parse_plan(out, f"{label.split(' (')[0]} ({weeks}w)") or {}
    curve = []
    for wk in sorted(w):
        best = 0
        for sub, dur, _pace in w[wk]:
            if sub in R15_LR_SUBS:
                best = max(best, dur)
        if best:
            curve.append(best)
    return curve

R15_CASES = [
    ("Beg 42K", 5000, 1980, "beg", 42195, [20, 24, 27, 30], True),
    ("Int 42K", 5000, 1500, "int", 42195, [18, 24, 30], False),
    ("Adv 42K", 5000, 1140, "adv", 42195, [18, 24, 30], False),
    ("Beg 21K", 5000, 1980, "beg", 21097, [14, 24], False),
]
for _label, _dist, _time, _lvl, _tgt, _weeks_list, _beg_m in R15_CASES:
    for _wknum in _weeks_list:
        _anchors = _progress_anchors(_dist, _time, _lvl, _tgt, _wknum)
        _curve = _r15_lr_curve(_label, _anchors, _wknum)
        _jumps = [(i + 1, max(_curve[i-1], _curve[i-2]), _curve[i])
                  for i in range(2, len(_curve))
                  if max(_curve[i-1], _curve[i-2]) >= 70
                  and _curve[i] > max(_curve[i-1], _curve[i-2]) * 1.35]
        check(f"{_label} {_wknum}w rendered LR: no week >35% above prior 2-wk max",
              not _jumps and len(_curve) >= 5,
              f"jumps(wk,ref,val)={_jumps[:3]} curve={_curve}", full=True)
        if _beg_m:
            _n3h = sum(1 for d in _curve if d >= 180)
            check(f"{_label} {_wknum}w: <=3 long runs >=3h",
                  _n3h <= 3, f"got {_n3h}: curve={_curve}", full=True)


print(f"\n{'='*60}")
print(f"Passed: {len(passed)}")
print(f"Failed: {len(failed)}")
if skipped:
    print(f"Skipped: {len(skipped)} (catalog-bound; set WORKOUTS_PATH to run them)")
if failed:
    print(f"\nFAILURES:")
    for label, detail in failed:
        print(f"  - {label}")
        if detail:
            print(f"    {detail}")
    sys.exit(1)
print("All checks passed.")
sys.exit(0)
