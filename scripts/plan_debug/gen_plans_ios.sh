#!/bin/bash
# Regenerate the readable "iOS App Matrix" plan files in the app repo root.
# Each cell: `progress` mode derives current->projected VDOT anchors, then
# `pacedump` renders the week blocks with week1->race-week pace interpolation
# (the *_END env anchors). Recovered from the Jun-2026 /tmp generator; the
# engine hooks (progress mode + pacedump _END overrides) live in main.swift /
# PaceZoneConverter.swift. Output: /Users/dansh/Sandbox/runplan/*_plans_ios.md
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
B="$HERE/plan_debug"
PROD=/Users/dansh/Sandbox/runplan/RunPlan/Resources/JSON/workouts.json
OUTDIR=/Users/dansh/Sandbox/runplan
[ -x "$B" ] || { echo "building plan_debug..."; "$HERE/build.sh" >/dev/null 2>&1; }

fmt() { printf "%d:%02d" $(( $1/60 )) $(( $1%60 )); }

# Set RACE_PACE/EASY_PACE/SPEED_PACE + *_END + VDOT_START/END from `progress`.
proj() { # DIST TIME LEVEL TARGET WEEKS
  unset RACE_PACE EASY_PACE SPEED_PACE RACE_PACE_END EASY_PACE_END SPEED_PACE_END VDOT_START VDOT_END
  eval $(DIST=$1 TIME=$2 LEVEL=$3 TARGET=$4 WEEKS=$5 WORKOUTS_PATH=$PROD "$B" progress 2>/dev/null \
    | grep -E '^(RACE_PACE|EASY_PACE|SPEED_PACE)(_END)?=|^VDOT_(START|END)=')
}

# Emit a fenced week-block. Env anchors must already be set; *_END optional.
dump_block() { # filter weeks
  echo '```'
  WEEKS=$2 WORKOUTS_PATH=$PROD ADAPTIVE=1 \
  RACE_PACE=${RACE_PACE:-} EASY_PACE=${EASY_PACE:-} SPEED_PACE=${SPEED_PACE:-} \
  RACE_PACE_END=${RACE_PACE_END:-} EASY_PACE_END=${EASY_PACE_END:-} SPEED_PACE_END=${SPEED_PACE_END:-} \
  "$B" pacedump "$1" 2>/dev/null | grep -E '^W *[0-9]+:|^  ' || echo "(no output for: $1)"
  echo '```'; echo ""
}

# ---------------- STANDARD: beginner / intermediate / advanced ----------------
# display | filter-distance | target_m | w_short w_norm w_long
dists=(
  "5K|5K|5000|6 7 8"
  "10K|10K|10000|8 9 10"
  "Half Marathon (21K)|21K|21097|12 14 16"
  "Marathon (42K)|42K|42195|14 17 20"
)
durnames=("short" "normal" "long")

gen_level() { # LevelName LevelPrefix levelcode "t1 t2 t3" "L1|L2|L3" outfile
  local lname="$1" lpre="$2" lcode="$3" outfile="$6"
  local -a times=($4); IFS='|' read -ra FL <<< "$5"
  {
  echo "# ${lname} Plans — iOS App Matrix (VDOT progression)"; echo ""
  echo "All ${lname} plans: **4 distances × 3 durations × 3 starting fitness levels**. Paces shift **current-VDOT (week 1) → projected-VDOT (race week)** — the projected fitness gain, bigger for longer plans, flat near the VDOT ceiling. Quality keeps its sharpening on top of the moving 5K-speed anchor. 5s-quantized; marathon-pace exact."; echo ""
  for d in "${dists[@]}"; do
    IFS='|' read -r dname dtok target weeks <<< "$d"; local -a wk=($weeks)
    echo "# $dname"; echo ""
    for fi in 0 1 2; do
      local t=${times[$fi]} flab=${FL[$fi]}
      echo "## $dname — $flab"; echo ""
      for i in 0 1 2; do
        local w=${wk[$i]} dn=${durnames[$i]}
        proj 5000 $t $lcode $target $w
        echo "### $dn — ${w}w"
        echo "VDOT ${VDOT_START}→${VDOT_END} · race $(fmt $RACE_PACE)→$(fmt $RACE_PACE_END) · easy $(fmt $EASY_PACE)→$(fmt $EASY_PACE_END) · 5K $(fmt $SPEED_PACE)→$(fmt $SPEED_PACE_END)"
        echo ""
        dump_block "$lpre $dtok (long" $w
      done
    done
    echo "---"; echo ""
  done
  } > "$OUTDIR/$outfile"
  echo "WROTE $outfile ($(wc -l < "$OUTDIR/$outfile") lines)"
}

gen_level "Beginner"     "Beg" beg "1980 1800 1620" "Slow (5K 33:00)|Typical (5K 30:00)|Fitter (5K 27:00)" beginner_plans_ios.md
gen_level "Intermediate" "Int" int "1620 1440 1320" "Slow (5K 27:00)|Typical (5K 24:00)|Fitter (5K 22:00)" intermediate_plans_ios.md
gen_level "Advanced"     "Adv" adv "1260 1140 1050" "Slow (5K 21:00)|Typical (5K 19:00)|Fitter (5K 17:30)" advanced_plans_ios.md

# ---------------- FITNESS: VO2 (VDOT progression) + Maintenance (hold) ----------------
{
echo "# Fitness Plans — VO2 Max + Maintenance"; echo ""
echo "Non-race fitness plans. **VO2 Max** is a fixed 8-week aerobic-power block (3 tiers); paces shift current→projected VDOT (small gain over 8w). **Maintenance** is an ongoing block (shown at 12w) that holds fitness — no VDOT build. Anchored to 5K-equivalent fitness per tier."; echo ""
echo "## VO2 Max (8-week block)"; echo ""
for t in "Beginner|beg|1800" "Intermediate|int|1440" "Advanced|adv|1140"; do
  IFS='|' read -r nm code time5k <<< "$t"; proj 5000 $time5k $code 5000 8
  echo "### VO2 Max — $nm (5K-anchored)"
  echo "VDOT ${VDOT_START}→${VDOT_END} · VO2/5K $(fmt $SPEED_PACE)→$(fmt $SPEED_PACE_END) · easy $(fmt $EASY_PACE)→$(fmt $EASY_PACE_END)"; echo ""
  dump_block "VO2 ${nm:0:3} (8w" 8
done
echo "---"; echo ""
echo "## Maintenance (ongoing — 12-week view)"; echo ""
for t in "Beginner|beg|1800" "Intermediate|int|1440" "Advanced|adv|1140"; do
  IFS='|' read -r nm code time5k <<< "$t"; proj 5000 $time5k $code 5000 12
  unset RACE_PACE_END EASY_PACE_END SPEED_PACE_END   # hold fitness, no VDOT build
  echo "### Maintenance — $nm"
  echo "VDOT ${VDOT_START} · easy $(fmt $EASY_PACE) · 5K $(fmt $SPEED_PACE)"; echo ""
  dump_block "Maint ${nm:0:3}" 12
done
} > "$OUTDIR/fitness_plans_ios.md"
echo "WROTE fitness_plans_ios.md ($(wc -l < "$OUTDIR/fitness_plans_ios.md") lines)"

# ---------------- COMPETITIVE: at-goal locked ----------------
{
echo "# Competitive (Pro) Plans — Sub-1:30 Half / Sub-3:00 Marathon"; echo ""
echo "Goal-locked plans: quality holds at the goal effort from day 1 (no ease-in), easy converges toward goal. Shown at the at-goal fitness."; echo ""
for c in "Sub-1:30 Half|21097|5400|Cmp 21K|12 18 32" "Sub-3:00 Marathon|42195|10800|Cmp 42K|14 22 36"; do
  IFS='|' read -r glabel target goaltime filt weeks <<< "$c"
  local_wk=($weeks); dn=("short" "normal" "long")
  echo "# $glabel"; echo ""
  proj $target $goaltime cmp $target ${local_wk[1]}
  unset RACE_PACE_END EASY_PACE_END SPEED_PACE_END   # locked at goal, no VDOT build
  echo "VDOT ${VDOT_START} (goal) · Goal race $(fmt $RACE_PACE)/km · easy $(fmt $EASY_PACE) · 5K speed $(fmt $SPEED_PACE)"; echo ""
  for i in 0 1 2; do
    echo "### ${dn[$i]} — ${local_wk[$i]}w"; echo ""
    dump_block "$filt (long" ${local_wk[$i]}
  done
  echo "---"; echo ""
done
} > "$OUTDIR/competitive_plans_ios.md"
echo "WROTE competitive_plans_ios.md ($(wc -l < "$OUTDIR/competitive_plans_ios.md") lines)"

# ---------------- ACCESSIBLE (SHIPPING tier — shipAccessibleTier=true) ----------------
# Same VDOT-progression render as the standard tiers, but the lighter accessible
# configs at their rec length. This is what the app actually serves.
gen_accessible() { # LevelName LevelPrefix levelcode "t1 t2 t3" "L1|L2|L3" outfile
  local lname="$1" lpre="$2" lcode="$3" outfile="$6"
  local -a times=($4); IFS='|' read -ra FL <<< "$5"
  {
  echo "# ${lname} — Accessible Tier (SHIPPING)"; echo ""
  echo "**This is what the app actually serves** (\`shipAccessibleTier = true\`). 4 distances × 3 fitness levels, rec length, lighter than textbook by load. Long runs build then taper; durations on a 5-min tick."; echo ""
  for d in "${dists[@]}"; do
    IFS='|' read -r dname dtok target weeks <<< "$d"
    local w; case "$dtok" in 5K) w=7;; 10K) w=9;; 21K) w=14;; 42K) w=18;; esac
    echo "# $dname"; echo ""
    for fi in 0 1 2; do
      local t=${times[$fi]} flab=${FL[$fi]}
      echo "## $dname — $flab"; echo ""
      proj 5000 $t $lcode $target $w
      echo "VDOT ${VDOT_START}→${VDOT_END} · race $(fmt $RACE_PACE)→$(fmt $RACE_PACE_END) · easy $(fmt $EASY_PACE)→$(fmt $EASY_PACE_END) · 5K $(fmt $SPEED_PACE)→$(fmt $SPEED_PACE_END)"; echo ""
      dump_block "Acc $lpre $dtok" $w
    done
    echo "---"; echo ""
  done
  } > "$OUTDIR/$outfile"
  echo "WROTE $outfile ($(wc -l < "$OUTDIR/$outfile") lines)"
}
gen_accessible "Beginner"     "Beg" beg "1980 1800 1620" "Slow (5K 33:00)|Typical (5K 30:00)|Fitter (5K 27:00)" beginner_accessible_plans_ios.md
gen_accessible "Intermediate" "Int" int "1620 1440 1320" "Slow (5K 27:00)|Typical (5K 24:00)|Fitter (5K 22:00)" intermediate_accessible_plans_ios.md
gen_accessible "Advanced"     "Adv" adv "1260 1140 1050" "Slow (5K 21:00)|Typical (5K 19:00)|Fitter (5K 17:30)" advanced_accessible_plans_ios.md

# ---------------- VOLUME COMPARISON (parses the 3 std files — must run last) ----------------
cd "$OUTDIR"
python3 - <<'PY'
import re
LEVELS=[('beginner','Beginner'),('intermediate','Intermediate'),('advanced','Advanced')]
DISTS=[('5K','5K'),('10K','10K'),('21K','Half Marathon (21K)'),('42K','Marathon (42K)')]
def parse(fn):
    lines=open(fn,encoding='utf-8').read().splitlines(); peak={}; easy=None; cur=None; cf=None
    for i,l in enumerate(lines):
        m=re.match(r'^## (.+?) — (.+)$',l)
        if m: cur=m.group(1); cf=m.group(2)
        if re.match(r'^### long',l):
            hdr=lines[i+1] if i+1<len(lines) else ''
            j=i
            while j<len(lines) and lines[j].strip()!='```': j+=1
            s=j+1; e=s
            while e<len(lines) and lines[e].strip()!='```': e+=1
            wk={}; cw=0
            for b in lines[s:e]:
                mw=re.match(r'^W\s*(\d+):',b)
                if mw: cw=int(mw.group(1))
                mm=re.search(r'\b(\d+)min\b',b)
                if mm and cw: wk[cw]=wk.get(cw,0)+int(mm.group(1))
            if wk:
                for k,full in DISTS:
                    if full==cur and k not in peak: peak[k]=max(wk.values())
                if 'Typical' in cf and easy is None:
                    em=re.search(r'easy (\d+):(\d+)',hdr)
                    if em: easy=int(em.group(1))*60+int(em.group(2))
    return peak, easy
OURS={}; EASY={}
for fn,name in LEVELS:
    p,e=parse(f'{fn}_plans_ios.md'); OURS[name]=p; EASY[name]=e
TB={
 '5K':  {'Beginner':(15,None,20),'Intermediate':(25,None,32),'Advanced':(35,None,42)},
 '10K': {'Beginner':(20,None,28),'Intermediate':(30,None,40),'Advanced':(40,None,50)},
 '21K': {'Beginner':(25,None,30),'Intermediate':(35,42,42),'Advanced':(45,55,52)},
 '42K': {'Beginner':(40,None,40),'Intermediate':(50,55,52),'Advanced':(55,70,62)},
}
DNAME={'5K':'5K','10K':'10K','21K':'Half Marathon','42K':'Marathon'}
out=["# Weekly Peak Volume — Ours vs Textbook","",
 "Peak-week volume (the single highest-volume week of the **long**-duration plan).",
 "Our plans are **duration-native** (minutes); the **≈mi** column converts our peak at",
 "the tier's *typical* easy pace, so a faster tier shows more miles for the same time.",
 "Textbook = approximate **peak weekly mileage** from the named plans (Higdon = accessible",
 "baseline; Pfitz = high-volume, marathon/half only; Daniels = VDOT-scaled). Rough, for shape-check.",""]
for k,_ in DISTS:
    out.append(f"## {DNAME[k]}");out.append("")
    out.append("| Tier | Our peak | ≈ our mi | Higdon | Pfitz | Daniels |")
    out.append("|---|---|---|---|---|---|")
    for _,name in LEVELS:
        pk=OURS[name].get(k); e=EASY[name]; mpm=e*1.609/60 if e else None
        mi=round(pk/mpm) if (pk and mpm) else None
        h,pf,da=TB[k][name]
        out.append(f"| {name} | {pk}min ({pk/60:.1f}h) | {mi} | {h} | {pf if pf else '—'} | {da} |")
    out.append("")
open('volume_comparison_ios.md','w',encoding='utf-8').write("\n".join(out))
print("WROTE volume_comparison_ios.md")
PY
echo "=== DONE ==="