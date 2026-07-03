#!/bin/bash
# Audit the RENDERED long-run minute curve for every (tier × distance × level).
# Catches the Acc-Beg-21K class: long runs that don't build (FLAT), shrink
# (INVERTED), or sit pinned at a clamp boundary (FLOOR-PINNED) across the build.
# Renders app-faithfully (progress mode → per-level VDOT anchors + _END easing).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
B="$HERE/plan_debug"
PROD=/Users/dansh/Sandbox/runplan/RunPlan/Resources/JSON/workouts.json
TSV=/tmp/lr_audit.tsv
: > "$TSV"
[ -x "$B" ] || "$HERE/build.sh" >/dev/null 2>&1

# NOTE: awk -v processes escapes, so \[ must be \\[ here or the pattern
# degrades into a character class and matches nearly every line (R9 finding —
# the audit ran vacuously green for weeks).
LR_TAGS='\\[(steadyLong|progressiveLong|long|raceRehearsalM|raceRehearsalHM|raceRehearsal10K|fastFinish)\\]'

# Render one combo, emit "combo<TAB>week<TAB>longrun_minutes" for each long-run week.
emit() { # combo filter weeks  (anchor env already set)
  WEEKS=$3 WORKOUTS_PATH=$PROD ADAPTIVE=1 \
  RACE_PACE=${RACE_PACE:-} EASY_PACE=${EASY_PACE:-} SPEED_PACE=${SPEED_PACE:-} \
  RACE_PACE_END=${RACE_PACE_END:-} EASY_PACE_END=${EASY_PACE_END:-} SPEED_PACE_END=${SPEED_PACE_END:-} \
  "$B" pacedump "$2" 2>/dev/null \
  | awk -v combo="$1" -v tags="$LR_TAGS" '
      /^W *[0-9]+:/ { if (match($0,/[0-9]+/)) wk=substr($0,RSTART,RLENGTH) }
      $0 ~ tags { d=""; line=$0
                  while (match(line,/[0-9]+min/)) { d=substr(line,RSTART,RLENGTH); line=substr(line,RSTART+RLENGTH) }
                  if (d!="") { sub(/min/,"",d); print combo"\t"wk"\t"d } }
    ' >> "$TSV"
}
proj() { # DIST TIME LEVEL TARGET WEEKS
  unset RACE_PACE EASY_PACE SPEED_PACE RACE_PACE_END EASY_PACE_END SPEED_PACE_END VDOT_START VDOT_END
  eval $(DIST=$1 TIME=$2 LEVEL=$3 TARGET=$4 WEEKS=$5 WORKOUTS_PATH=$PROD "$B" progress 2>/dev/null \
    | grep -E '^(RACE_PACE|EASY_PACE|SPEED_PACE)(_END)?=')
}

# distance | target_m | textbook_long_weeks | accessible_rec_weeks
DISTS=("5K|5000|8|7" "10K|10000|10|9" "21K|21097|16|14" "42K|42195|20|18")
# 5K-ref-time (sec) per tier+level — bash 3.2 has no assoc arrays, so use a case.
time_for() {
  case "$1_$2" in
    beg_slow) echo 1980;; beg_typ) echo 1800;; beg_fit) echo 1620;;
    int_slow) echo 1620;; int_typ) echo 1440;; int_fit) echo 1320;;
    adv_slow) echo 1260;; adv_typ) echo 1140;; adv_fit) echo 1050;;
  esac
}

for tier in beg int adv; do
  Pre=$(echo $tier | sed 's/beg/Beg/;s/int/Int/;s/adv/Adv/')
  for lvl in slow typ fit; do
    t=$(time_for $tier $lvl)
    for d in "${DISTS[@]}"; do
      IFS='|' read -r dn target tw aw <<< "$d"
      # textbook
      proj 5000 $t $tier $target $tw
      emit "TEXTBOOK $Pre $dn $lvl" "$Pre $dn (long" $tw
      # accessible (shipping)
      proj 5000 $t $tier $target $aw
      emit "ACCESS $Pre $dn $lvl" "Acc $Pre $dn" $aw
    done
  done
done

python3 - "$TSV" <<'PY'
import sys, collections
rows = collections.defaultdict(dict)   # combo -> {week:minutes}
for ln in open(sys.argv[1]):
    p = ln.rstrip("\n").split("\t")
    if len(p)!=3 or not p[1].isdigit() or not p[2].isdigit(): continue
    combo, wk, d = p[0], int(p[1]), int(p[2])
    rows[combo][wk] = max(rows[combo].get(wk,0), d)  # max long-run that week

def verdict(durs):
    if len(durs) < 3: return ("SKIP", "only %d long-run weeks"%len(durs))
    start, peak = durs[0], max(durs)
    pidx = durs.index(peak)
    rise = (peak-start)/start if start else 0
    cnt = collections.Counter(durs)
    pinned_n = cnt.most_common(1)[0][1]
    if pidx == 0:                       return ("INVERTED", "peak is week-1 (%dmin); never builds → %s"%(peak,durs))
    if rise < 0.10:                     return ("FLAT", "rise only %.0f%% (%d→%d) → %s"%(rise*100,start,peak,durs))
    if pinned_n >= 5 and rise < 0.25:   return ("FLOOR-PINNED", "%dmin repeats %dx → %s"%(cnt.most_common(1)[0][0],pinned_n,durs))
    # #174: build-chain cliff — a week jumping >35% above the max of the two
    # prior weeks (two-week max ≈ skip-the-deload). Ignore tiny bases (<70min).
    for i in range(2, len(durs)):
        ref = max(durs[i-1], durs[i-2])
        if ref >= 70 and durs[i] > ref * 1.35:
            return ("JUMPY", "W%d %d→%dmin (+%.0f%%) → %s"%(i+1, ref, durs[i], (durs[i]/ref-1)*100, durs))
    return ("OK", "%d→%d (+%.0f%%), peak@%d/%d"%(start,peak,rise*100,pidx+1,len(durs)))

order = {"INVERTED":0,"JUMPY":1,"FLAT":2,"FLOOR-PINNED":3,"OK":4,"SKIP":5}
out = []
for combo, wkmap in rows.items():
    durs = [wkmap[w] for w in sorted(wkmap)]
    v, msg = verdict(durs)
    out.append((order[v], combo, v, msg))
out.sort()
print("\n================= LONG-RUN BUILD AUDIT =================")
flagged = [o for o in out if o[2] in ("INVERTED","JUMPY","FLAT","FLOOR-PINNED")]
for _, combo, v, msg in out:
    if v in ("INVERTED","JUMPY","FLAT","FLOOR-PINNED"):
        print(f"  ⚠️ {v:13} {combo:34} {msg}")
print(f"\n  ── {len(flagged)} flagged / {len([o for o in out if o[2]!='SKIP'])} judged ({len([o for o in out if o[2]=='OK'])} OK, {len([o for o in out if o[2]=='SKIP'])} skipped) ──")
print("  (SKIP = <3 long-run weeks, e.g. 5K/10K speed tiers)")
# CI gate: hard-fail the Acc-Beg-21K-class regression — a half/full-marathon long
# run that peaks EARLY and never returns to that peak late (the declining/inverted
# curve). A flat curve whose peak recurs late (a fit runner's km-build compressed in
# minutes) is a warning, not a failure. Build-to-a-late-peak is the invariant.
regressions = []
for combo, wkmap in rows.items():
    if not (" 21K " in combo or " 42K " in combo): continue
    durs = [wkmap[w] for w in sorted(wkmap)]
    if len(durs) < 6: continue
    peak = max(durs)
    last_peak = len(durs) - 1 - durs[::-1].index(peak)   # latest week the peak occurs
    if last_peak < 0.4 * len(durs):                       # peak only in the early 40%
        regressions.append((combo, durs))
if regressions:
    print("\n  ❌ REGRESSION: %d half/full-marathon long run(s) peak early & never build to a late peak:" % len(regressions))
    for combo, durs in sorted(regressions): print(f"     {combo}: {durs}")
    sys.exit(1)
print("\n  ✅ PASS — every half/full-marathon long run builds to a late peak")
PY