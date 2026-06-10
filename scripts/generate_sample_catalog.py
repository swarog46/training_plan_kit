#!/usr/bin/env python3
"""Build a small sample catalog the generator can run against.

This is not RunPlan's full tuned library — it pulls a handful of workouts per
subtype from a source catalog so the engine has enough variety to lay out
plans across every distance and level. The shipped sample was made from
RunPlan's own catalog; point SOURCE_CATALOG at any catalog with the same
shape to make your own.

    SOURCE_CATALOG=/path/to/workouts.json python3 scripts/generate_sample_catalog.py

Shape of a workout: see Sources/TrainingPlanKit/Models/Workout.swift.
"""

import json
import os
import sys

PER_SUBTYPE = 3  # how many to keep per subtype, spread across durations

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "Sources/TrainingPlanKit/Catalog/sample_catalog.json")

source = os.environ.get("SOURCE_CATALOG")
if not source or not os.path.exists(source):
    sys.exit(
        "Set SOURCE_CATALOG to a catalog JSON (array of workouts) to sample from.\n"
        "The shipped sample_catalog.json was generated this way from RunPlan's catalog."
    )

workouts = json.load(open(source))

# Group by subtype, then keep an even spread across the duration range so the
# sample has short and long variants of each, not five near-identical ones.
by_subtype = {}
for w in workouts:
    by_subtype.setdefault(w.get("subtype", "unknown"), []).append(w)

sample = []
for subtype, group in sorted(by_subtype.items()):
    group.sort(key=lambda w: w.get("duration", 0))
    if len(group) <= PER_SUBTYPE:
        picked = group
    else:
        step = (len(group) - 1) / (PER_SUBTYPE - 1)
        picked = [group[round(i * step)] for i in range(PER_SUBTYPE)]
    sample.extend(picked)

# Stable order + ids so the file diffs cleanly between runs.
sample.sort(key=lambda w: (w.get("subtype", ""), w.get("duration", 0), w.get("id", 0)))

with open(OUT, "w") as f:
    json.dump(sample, f, indent=1, ensure_ascii=False)
    f.write("\n")

print(f"Wrote {len(sample)} workouts across {len(by_subtype)} subtypes to {OUT}")
