//
//  main.swift
//  Plan debugger CLI
//
//  Generates a plan for every (distance × level × duration) combination
//  and prints week-by-week summaries. Pure Swift / Foundation —
//  no Xcode, no simulator, no XCTest.
//
//  Run via: ./scripts/plan_debug/build.sh && ./scripts/plan_debug/plan_debug
//

import Foundation

// MARK: - Pretty-printer

func dumpPlan(_ config: PlanConfiguration, weeks: Int, label: String, workouts: [Workout]) {
    let plan = simulatePlanV3(config: config, totalWeeks: weeks, allWorkouts: workouts, adaptive: adaptive)
    // Mirror the engine's front-trim: short plans are generated at
    // recommended length and trimmed from the start, so phase labels must
    // be computed against the generated length and offset by the trim.
    let minRequired = config.minBasePhaseWeeks + config.minSpeedPhaseWeeks
        + config.minPeakPhaseWeeks + config.minTaperPhaseWeeks
    let genWeeks = max(weeks, minRequired)
    let weeksTrimmed = genWeeks - weeks
    let phaseDurations = calculatePhaseDurations(config: config, totalWeeks: genWeeks)
    let baseDur = phaseDurations["base"] ?? 0
    let speedDur = phaseDurations["speed"] ?? 0
    let peakDur = phaseDurations["peak"] ?? 0
    let taperDur = phaseDurations["taper"] ?? 0

    print("\n=================================================================")
    print("=== \(label)  (\(weeks)w, \(config.trainingDays.count)d/wk)")
    print("=================================================================")
    print("Phases: BASE=\(baseDur) SPEED=\(speedDur) PEAK=\(peakDur) TAPER=\(taperDur)")
    print("Days: \(config.trainingDays.map(weekdayName).joined(separator: ",")) | LR=\(weekdayName(config.longestWorkoutDay))")
    print("-----------------------------------------------------------------")

    for week in 0..<weeks {
        let (phase, weekInPhase) = determinePhaseV3(weekIndex: week + weeksTrimmed, baseDur: baseDur, speedDur: speedDur, peakDur: peakDur, taperDur: taperDur)
        let ws = plan[week] ?? []
        let totalLoad = ws.reduce(0) { $0 + Int($1.workout.trainingLoad) }
        let totalMin  = ws.reduce(0) { $0 + Int($1.workout.duration) } / 60
        let phaseLen = phaseLength(phase, base: baseDur, speed: speedDur, peak: peakDur, taper: taperDur)
        print(String(format: "W%2d [%@ %d/%d] %dwkts load=%5d %3dmin",
                     week + 1, phase.rawValue, weekInPhase + 1, phaseLen,
                     ws.count, totalLoad, totalMin))
        for w in ws {
            let dur = Int(w.workout.duration) / 60
            let load = Int(w.workout.trainingLoad)
            let title = w.workout.title.padding(toLength: 28, withPad: " ", startingAt: 0)
            let subtype = w.workout.subtype.rawValue
            // Z5 work minutes from the actual picked template — ground truth
            // for the Z5-policy tests (title-based joins are ambiguous).
            let z5min = Int(w.workout.intervals
                .filter { $0.type == .work && $0.target == TargetRange.heartRateZone(zone: 5) }
                .reduce(0.0) { $0 + $1.duration } / 60)
            let z5tag = z5min > 0 ? " z5=\(z5min)" : ""
            print("    \(title) \(String(format: "%3dmin l=%4d  [%@/%@]%@", dur, load, subtype, w.type, z5tag))")
        }
    }
    print("=================================================================\n")
}

func summary(_ config: PlanConfiguration, weeks: Int, label: String, workouts: [Workout]) {
    let plan = simulatePlanV3(config: config, totalWeeks: weeks, allWorkouts: workouts, adaptive: adaptive)
    let all = plan.values.flatMap { $0 }
    let easy = all.filter { $0.workout.subtype == .easy }.count
    let long = all.filter {
        $0.workout.subtype == .steadyLong ||
        $0.workout.subtype == .progressiveLong ||
        $0.workout.subtype == .long
    }.count
    let hard = all.filter {
        ["intervals","threshold","tempo","speed","ladderIntervals","pyramidIntervals",
         "hillRepeats","mileRepeats","yasso800","timeTrial","marathonPace"].contains($0.workout.subtype.rawValue)
    }.count
    let progression = all.filter { $0.workout.subtype == .progression }.count
    let fartlek = all.filter { $0.workout.subtype == .fartlek }.count
    let totalLoad = all.reduce(0) { $0 + Int($1.workout.trainingLoad) }
    let totalMin = all.reduce(0) { $0 + Int($1.workout.duration) } / 60
    let avgLoadWk = totalLoad / max(weeks, 1)
    let avgMinWk = totalMin / max(weeks, 1)
    let labelPadded = label.padding(toLength: 22, withPad: " ", startingAt: 0)
    print("\(labelPadded) " +
          String(format: "%3dw %3dwkts E:%2d L:%2d H:%2d P:%2d F:%2d  load=%6d (%4d/wk)  %5dmin (%3d/wk)",
                 weeks, all.count, easy, long, hard, progression, fartlek,
                 totalLoad, avgLoadWk, totalMin, avgMinWk))
}

func phaseLength(_ phase: TrainingPhase, base: Int, speed: Int, peak: Int, taper: Int) -> Int {
    switch phase {
    case .base: return base
    case .speed: return speed
    case .peak: return peak
    case .taper: return taper
    case .race: return 1
    }
}

func weekdayName(_ idx: Int) -> String {
    ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"][max(0, min(6, idx))]
}

// MARK: - Main

// Catalog source: $WORKOUTS_PATH if set (point it at your own catalog),
// otherwise the sample catalog shipped in the repo.
let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repoRoot = scriptDir.deletingLastPathComponent().deletingLastPathComponent()
let sampleCatalog = repoRoot
    .appendingPathComponent("Sources/TrainingPlanKit/Catalog/sample_catalog.json").path
let catalogPath = ProcessInfo.processInfo.environment["WORKOUTS_PATH"] ?? sampleCatalog
let workouts: [Workout]
do {
    let data = try Data(contentsOf: URL(fileURLWithPath: catalogPath))
    workouts = try JSONDecoder().decode([Workout].self, from: data)
    print("# Loaded \(workouts.count) workouts from \(catalogPath)")
} catch {
    print("FAILED to load workouts: \(error)")
    exit(1)
}
if workouts.isEmpty {
    print("Catalog is empty.")
    exit(1)
}

// CLI args: [mode] [filter]
//   mode: "summary" (default) | "dump" | "pace" | "pacedump"
//   filter: substring to match plan label, e.g. "21K", "Marathon", "Beginner"
//   pacedump: per-workout dump in pace-converted form (see HR vs pace targets)
//
// Env: ADAPTIVE=0 simulates the free-tier plan (excludes paid subtypes:
// raceRehearsal, timeTrial, mileRepeats, yasso800, marathonPace).
// Default is adaptive=true (back-compat with current behavior).
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "summary"
let filter = args.count > 2 ? args[2] : ""
let adaptive = (ProcessInfo.processInfo.environment["ADAPTIVE"] ?? "1") != "0"
if !adaptive { print("# ADAPTIVE=0 — free-tier mode (no paid subtypes)") }

// (label, config, weeks-variant, weeks)
let cases: [(label: String, config: PlanConfiguration, weeks: Int)] = [
    // 5K — recommended 6-8w. Test short / rec / long.
    ("Beg 5K (short, 5w)",   .beginner5Default,      5),
    ("Beg 5K (rec, 7w)",     .beginner5Default,      7),
    ("Beg 5K (long, 10w)",   .beginner5Default,     10),
    ("Int 5K (short, 5w)",   .intermediate5Default,  5),
    ("Int 5K (rec, 7w)",     .intermediate5Default,  7),
    ("Int 5K (long, 10w)",   .intermediate5Default, 10),
    ("Adv 5K (rec, 7w)",     .advanced5Default,      7),
    ("Adv 5K (long, 10w)",   .advanced5Default,     10),

    // 10K — recommended 8-10w
    ("Beg 10K (short, 7w)",  .beginner10Default,     7),
    ("Beg 10K (rec, 9w)",    .beginner10Default,     9),
    ("Beg 10K (long, 12w)",  .beginner10Default,    12),
    ("Int 10K (rec, 9w)",    .intermediate10Default, 9),
    ("Int 10K (long, 12w)",  .intermediate10Default, 12),
    ("Adv 10K (rec, 9w)",    .advanced10Default,     9),
    ("Adv 10K (long, 12w)",  .advanced10Default,    12),

    // 21K — recommended 12-16w (after fix)
    ("Beg 21K (short, 10w)", .beginner21Default,    10),
    ("Beg 21K (rec, 14w)",   .beginner21Default,    14),
    ("Beg 21K (long, 18w)",  .beginner21Default,    18),
    ("Int 21K (rec, 14w)",   .intermediate21Default, 14),
    ("Int 21K (long, 18w)",  .intermediate21Default, 18),
    ("Adv 21K (rec, 14w)",   .advanced21Default,     14),
    ("Adv 21K (long, 18w)",  .advanced21Default,    18),

    // 21K Competitive — sub-1:30 target
    // Min (12w) and max (32w) cover the gate's build-band recommended
    // weeks at VDOT 54 (30w) which now fits under the bumped max cap.
    ("Cmp 21K (short, 12w)", .competitive21Default,  12),
    ("Cmp 21K (rec, 14w)",   .competitive21Default,  14),
    ("Cmp 21K (long, 18w)",  .competitive21Default,  18),
    ("Cmp 21K (max, 32w)",   .competitive21Default,  32),

    // Marathon — recommended 14-20w (after fix)
    ("Beg 42K (short, 14w)", .beginner42Default,    14),
    ("Beg 42K (rec, 18w)",   .beginner42Default,    18),
    ("Beg 42K (long, 22w)",  .beginner42Default,    22),
    ("Int 42K (rec, 18w)",   .intermediate42Default, 18),
    ("Int 42K (long, 22w)",  .intermediate42Default, 22),
    ("Adv 42K (rec, 18w)",   .advanced42Default,    18),
    ("Adv 42K (long, 22w)",  .advanced42Default,    22),

    // Marathon Competitive — sub-3:00 target. Min weeks now 12 for runners
    // already at goal fitness (was 18; phase mins still keep PEAK > TAPER).
    ("Cmp 42K (short, 12w)", .competitive42Default,  12),
    ("Cmp 42K (rec, 18w)",   .competitive42Default,  18),
    ("Cmp 42K (long, 22w)",  .competitive42Default,  22),
    ("Cmp 42K (build, 28w)", .competitive42Default,  28),  // VDOT-gap build path
    ("Cmp 42K (max, 36w)",   .competitive42Default,  36),

    // Maintenance — open-ended
    ("Maint Beg (12w)",      .maintenanceBeginner,   12),
    ("Maint Int (12w)",      .maintenanceIntermediate, 12),
    ("Maint Adv (12w)",      .maintenanceAdvanced,   12),

    // VO2 max — 8-week fixed block
    ("VO2 Beg (8w)",         .vo2maxBeginner,         8),
    ("VO2 Int (8w)",         .vo2maxIntermediate,     8),
    ("VO2 Adv (8w)",         .vo2maxAdvanced,         8),

    // Accessible ("real life") tier — lighter variants, same structure
    ("Acc Beg 5K (rec, 7w)",  .accessibleBeginner5Default,      7),
    ("Acc Int 5K (rec, 7w)",  .accessibleIntermediate5Default,  7),
    ("Acc Adv 5K (rec, 7w)",  .accessibleAdvanced5Default,      7),
    ("Acc Beg 10K (rec, 9w)", .accessibleBeginner10Default,     9),
    ("Acc Int 10K (rec, 9w)", .accessibleIntermediate10Default, 9),
    ("Acc Adv 10K (rec, 9w)", .accessibleAdvanced10Default,     9),
    ("Acc Beg 21K (rec, 14w)",.accessibleBeginner21Default,    14),
    ("Acc Int 21K (rec, 14w)",.accessibleIntermediate21Default,14),
    ("Acc Adv 21K (rec, 14w)",.accessibleAdvanced21Default,    14),
    ("Acc Beg 42K (rec, 18w)",.accessibleBeginner42Default,    18),
    ("Acc Int 42K (rec, 18w)",.accessibleIntermediate42Default,18),
    ("Acc Adv 42K (rec, 18w)",.accessibleAdvanced42Default,    18),
]

let filtered = cases.filter { filter.isEmpty || $0.label.lowercased().contains(filter.lowercased()) }

print("\n========== PLAN GENERATION SUMMARY ==========")
print("(E=easy, L=long, H=hard, P=progression, F=fartlek)")
print("---------------------------------------------------")
for c in filtered {
    summary(c.config, weeks: c.weeks, label: c.label, workouts: workouts)
}

if mode == "dump" {
    for c in filtered {
        dumpPlan(c.config, weeks: c.weeks, label: c.label, workouts: workouts)
    }
}

// Pace mode: dump the same plans but with HR targets converted to pace
// targets (the same conversion the iOS app applies for pace plans).
//
// Race pace defaults: 5:00/km (300 sec/km), conversational 6:30/km (390).
// Override via env: RACE_PACE=320 EASY_PACE=420 ./plan_debug pace
if mode == "pace" {
    let racePace = Int(ProcessInfo.processInfo.environment["RACE_PACE"] ?? "300") ?? 300
    let easyPace = Int(ProcessInfo.processInfo.environment["EASY_PACE"] ?? "390") ?? 390

    print("\n========== PACE PLAN MODE ==========")
    print("Race pace: \(racePace/60):\(String(format: "%02d", racePace%60))/km")
    print("Easy pace: \(easyPace/60):\(String(format: "%02d", easyPace%60))/km")
    print("(Override with RACE_PACE / EASY_PACE env vars in seconds/km)")
    print("=====================================")

    for c in filtered {
        let plan = simulatePlanV3(config: c.config, totalWeeks: c.weeks, allWorkouts: workouts, adaptive: adaptive)
        let hrEvents = plan.flatMap { _, ws in ws.map { $0.workout } }

        // Build a fake events array so PaceZoneConverter has dates to use
        let startDate = Date()
        let endDate = Calendar.current.date(byAdding: .weekOfYear, value: c.weeks, to: startDate)!

        var events: [WorkoutEvent] = []
        for (weekIdx, weekWorkouts) in plan.sorted(by: { $0.key < $1.key }) {
            let dayDate = Calendar.current.date(byAdding: .day, value: weekIdx * 7, to: startDate)!
            for (_, w) in weekWorkouts {
                events.append(WorkoutEvent(workout: w, planId: UUID(), date: dayDate))
            }
        }

        let progression: PaceProgressionConfig = {
            switch c.config.runnerLevel {
            case .beginner: return .beginner
            case .intermediate: return .intermediate
            case .advanced: return .advanced
            case .competitive:
                // Env: BUILD_BAND=1 forces the build-band variant. Used by
                // tests to verify the routing path that PlanConfigurationView
                // selects for VDOT 54-57 runners.
                let buildBand = ProcessInfo.processInfo.environment["BUILD_BAND"] == "1"
                return buildBand ? .competitiveBuildBand : .competitive
            }
        }()

        let paceEvents = PaceZoneConverter.applyPaceProgression(
            to: events,
            racePace: racePace,
            conversationalPace: easyPace,
            config: progression,
            startDate: startDate,
            endDate: endDate
        )

        // Tally pace targets by zone
        var paceCounts: [Int: Int] = [:]  // pace bucket (sec/km, rounded to 10) → count
        for event in paceEvents {
            for interval in event.workout.intervals {
                if case .paceTarget(let basePace, let relative) = interval.target {
                    let pace = Int(Double(basePace) * relative)
                    let bucket = (pace / 10) * 10
                    paceCounts[bucket, default: 0] += 1
                }
            }
        }
        let sorted = paceCounts.sorted { $0.key < $1.key }
        let total = sorted.reduce(0) { $0 + $1.value }
        let labelPadded = c.label.padding(toLength: 22, withPad: " ", startingAt: 0)
        print("\n\(labelPadded)  intervals=\(total)")
        for (bucket, count) in sorted {
            let pct = 100 * count / max(total, 1)
            let bar = String(repeating: "█", count: max(1, pct / 2))
            print(String(format: "  %d:%02d/km  %4d (%2d%%)  %@",
                         bucket/60, bucket%60, count, pct, bar))
        }
    }
    print()
}

// pacedump: per-week per-workout view with the pace targets actually
// applied. Lets you eyeball whether hill repeats hit Z5 pace, mile repeats
// hit threshold, marathon-pace hits race pace, etc.
if mode == "pacedump" {
    let racePace = Int(ProcessInfo.processInfo.environment["RACE_PACE"] ?? "300") ?? 300
    let easyPace = Int(ProcessInfo.processInfo.environment["EASY_PACE"] ?? "390") ?? 390
    // 5K speed anchor for quality zones (Z4/Z5). nil → legacy race-pace anchoring.
    let speedPace = ProcessInfo.processInfo.environment["SPEED_PACE"].flatMap { Int($0) }

    func fmtPace(_ secPerKm: Int) -> String {
        return String(format: "%d:%02d/km", secPerKm / 60, secPerKm % 60)
    }

    print("\n========== PACE DUMP ==========")
    print("Race pace: \(fmtPace(racePace)) | Easy pace: \(fmtPace(easyPace))")
    print("================================\n")

    for c in filtered {
        let plan = simulatePlanV3(config: c.config, totalWeeks: c.weeks, allWorkouts: workouts, adaptive: adaptive)
        let startDate = Date()
        let endDate = Calendar.current.date(byAdding: .weekOfYear, value: c.weeks, to: startDate)!

        var events: [WorkoutEvent] = []
        var dayOfWorkout: [UUID: Date] = [:]
        for (weekIdx, weekWorkouts) in plan.sorted(by: { $0.key < $1.key }) {
            let dayDate = Calendar.current.date(byAdding: .day, value: weekIdx * 7, to: startDate)!
            for (_, w) in weekWorkouts {
                let event = WorkoutEvent(workout: w, planId: UUID(), date: dayDate)
                dayOfWorkout[event.id] = dayDate
                events.append(event)
            }
        }

        let progression: PaceProgressionConfig = {
            switch c.config.runnerLevel {
            case .beginner: return .beginner
            case .intermediate: return .intermediate
            case .advanced: return .advanced
            case .competitive:
                // Env: BUILD_BAND=1 forces the build-band variant. Used by
                // tests to verify the routing path that PlanConfigurationView
                // selects for VDOT 54-57 runners.
                let buildBand = ProcessInfo.processInfo.environment["BUILD_BAND"] == "1"
                return buildBand ? .competitiveBuildBand : .competitive
            }
        }()

        let paceEvents = PaceZoneConverter.applyPaceProgression(
            to: events, racePace: racePace, conversationalPace: easyPace,
            speedPace: speedPace,
            config: progression, startDate: startDate, endDate: endDate
        )

        // Group by week
        var byWeek: [Int: [WorkoutEvent]] = [:]
        for ev in paceEvents {
            let day = dayOfWorkout[ev.id] ?? startDate
            let weekIdx = Calendar.current.dateComponents([.day], from: startDate, to: day).day! / 7
            byWeek[weekIdx, default: []].append(ev)
        }

        print("============================================================")
        print("=== \(c.label)  (\(c.weeks)w)")
        print("============================================================")
        for (week, evs) in byWeek.sorted(by: { $0.key < $1.key }) {
            print("W\(String(format: "%2d", week + 1)):")
            for ev in evs {
                let title = ev.workout.title.padding(toLength: 30, withPad: " ", startingAt: 0)
                let dur = Int(ev.workout.duration) / 60
                let subtype = ev.workout.subtype.rawValue
                // Find the dominant work-interval pace (longest Work segment)
                var bestPace: Int? = nil
                var bestDur: Double = 0
                for iv in ev.workout.intervals where iv.type == .work {
                    if case .paceTarget(let base, let rel) = iv.target {
                        if iv.duration > bestDur {
                            bestDur = iv.duration
                            bestPace = Int(Double(base) * rel)
                        }
                    }
                }
                // Also collect distinct paces across work intervals
                var paceSet = Set<Int>()
                for iv in ev.workout.intervals where iv.type == .work {
                    if case .paceTarget(let base, let rel) = iv.target {
                        paceSet.insert(Int(Double(base) * rel))
                    }
                }
                let paceStr: String
                if paceSet.count > 1 {
                    let sortedPaces = paceSet.sorted().map { fmtPace($0) }.joined(separator: ", ")
                    paceStr = "[\(sortedPaces)]"
                } else if let p = bestPace {
                    paceStr = fmtPace(p)
                } else {
                    paceStr = "-"
                }
                print("  \(title) \(String(format: "%3dmin", dur))  \(paceStr)  [\(subtype)]")
            }
        }
        print("")
    }
}

// daydump: per-day calendar view via the REAL createMarathonPlanV3. This is
// the only ground-truth check for the day-scheduler — plan_debug's other
// modes call simulatePlanV3 which doesn't do day assignment.
if mode == "daydump" {
    let calendar = Calendar.current
    // Start on a Monday so weekday math is intuitive. Day 1 = Tue, ..., Day 6 = Sun.
    var startComps = DateComponents()
    startComps.year = 2026; startComps.month = 1; startComps.day = 5  // Mon
    let startDate = calendar.date(from: startComps)!

    for c in filtered {
        let raceDate = calendar.date(byAdding: .weekOfYear, value: c.weeks, to: startDate)!
        let planId = UUID()
        let events = createMarathonPlanV3(startDate: startDate, raceDate: raceDate,
                                          from: workouts, planId: planId, config: c.config)

        // Group events by week-of-plan, then by weekday.
        var byWeek: [Int: [WorkoutEvent]] = [:]
        for ev in events {
            let weekIdx = calendar.dateComponents([.day], from: startDate, to: ev.date).day! / 7
            byWeek[weekIdx, default: []].append(ev)
        }

        let qualitySubtypes: Set<String> = [
            "intervals","hillRepeats","threshold","mileRepeats","ladderIntervals",
            "yasso800","timeTrial","marathonPace","fivekPace","tenkPace","fartlek",
            "pyramidIntervals"
        ]
        let dayNames = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]
        func dayName(_ date: Date) -> String {
            // Calendar.weekday: 1=Sun ... 7=Sat. Map to Mon=0..Sun=6.
            let wd = calendar.component(.weekday, from: date)
            let monIdx = (wd + 5) % 7
            return dayNames[monIdx]
        }

        print("============================================================")
        print("=== \(c.label) DAY-BY-DAY")
        print("============================================================")
        var totalConsecutive = 0
        for (week, evs) in byWeek.sorted(by: { $0.key < $1.key }) {
            print("W\(String(format: "%2d", week + 1)):")
            let sortedEvs = evs.sorted { $0.date < $1.date }
            var prevWasQuality = false
            var prevDate: Date? = nil
            for ev in sortedEvs {
                let subtype = ev.workout.subtype.rawValue
                let isQuality = qualitySubtypes.contains(subtype)
                let mark = isQuality ? "Q" : (subtype == "long" || subtype == "steadyLong" || subtype == "progressiveLong" || subtype == "raceRehearsalM" || subtype == "raceRehearsalHM" || subtype == "raceRehearsal10K" || subtype == "fastFinish" ? "L" : " ")
                var flag = ""
                if isQuality, prevWasQuality, let pd = prevDate {
                    let dayGap = calendar.dateComponents([.day], from: pd, to: ev.date).day ?? 0
                    if dayGap == 1 { flag = "  ⚠ back-to-back quality (prev day was also Q)"; totalConsecutive += 1 }
                }
                print("  \(dayName(ev.date)) \(mark)  \(ev.workout.title.padding(toLength: 32, withPad: " ", startingAt: 0))  \(Int(ev.workout.duration / 60))min  [\(subtype)]\(flag)")
                prevWasQuality = isQuality
                prevDate = ev.date
            }
        }
        if totalConsecutive > 0 {
            print("\nTotal back-to-back-quality occurrences: \(totalConsecutive)")
        }
    }
}

// tolerance: print the shared WorkoutPaceTolerance.seconds constant so
// Python tests assert against the same window the watch shows during a
// workout (no hardcoded "15" duplicated in two places).
if mode == "tolerance" {
    print("TOLERANCE_SECONDS=\(WorkoutPaceTolerance.seconds)")
}

// aerobic: per-workout aerobic-minutes count, computed from the REAL
// workout intervals' HR zones (Z1-Z2 = aerobic) and pace targets. Output
// is the source of truth for the Python aerobic-share test — no per-
// subtype heuristic, the test reads what the Swift catalog actually
// prescribes. If a catalog tweak changes a progressiveLong's Z2/Z3 split
// from 60/40 to 30/70, this mode reports the new aerobic minutes and
// the regression test sees the drift; the prior Python-heuristic version
// would have missed it.
//
// Aerobic classification per interval (in priority order):
//   1. heartRateZone target with zone <= 2 → aerobic
//   2. paceTarget with relative >= 1.10    → aerobic (Z2-ish; Z3 is 1.0)
//   3. interval type warmup/cooldown/recovery/rest → aerobic by convention
//   4. otherwise → non-aerobic (Z3+ work)
//
// Format: one line per workout, parseable:
//   W{N} | {subtype} | total={M}min | aerobic={A}min
if mode == "aerobic" {
    print("\n========== AEROBIC MINUTES ==========")
    for c in filtered {
        let plan = simulatePlanV3(config: c.config, totalWeeks: c.weeks, allWorkouts: workouts, adaptive: adaptive)
        print("=== \(c.label)  (\(c.weeks)w)")
        for (weekIdx, weekWorkouts) in plan.sorted(by: { $0.key < $1.key }) {
            for (_, w) in weekWorkouts {
                var aerobicSecs: Double = 0
                for iv in w.intervals {
                    let zoneIsAerobic: Bool = {
                        switch iv.target {
                        case .heartRateZone(let zone):
                            return zone <= 2
                        case .paceTarget(_, let rel):
                            return rel >= 1.10  // Z2-or-easier multiplier window
                        case .secondsRange, .noRange:
                            return false
                        }
                    }()
                    let conventionalAerobic = iv.type == .warmup
                        || iv.type == .cooldown
                        || iv.type == .recovery
                        || iv.type == .rest
                    if zoneIsAerobic || conventionalAerobic {
                        aerobicSecs += iv.duration
                    }
                }
                let totalMin = Int(w.duration) / 60
                let aerobicMin = Int(aerobicSecs / 60.0)
                print("W\(weekIdx + 1) | \(w.subtype.rawValue) | total=\(totalMin)min | aerobic=\(aerobicMin)min")
            }
        }
    }
}

// gate: evaluate competitiveGateState() for a (VDOT, distance) pair and
// print the result in a parseable form. Used by tests to verify the same
// gate function the iOS app uses for sub-3 / sub-1:30 plan setup.
//
// Args (env, since CLI args are already taken by mode/filter):
//   VDOT=NN.N  — VDOT value as Double
//   DIST=42195 — race distance in meters (42195 marathon / 21097 half)
if mode == "gate" {
    let vdotStr = ProcessInfo.processInfo.environment["VDOT"] ?? ""
    let distStr = ProcessInfo.processInfo.environment["DIST"] ?? "42195"
    guard let vdotValue = Double(vdotStr), let dist = Int(distStr) else {
        print("ERROR: pass VDOT=NN.N and DIST=NNNNN as env vars")
        exit(1)
    }
    let vdot = VDOT(value: vdotValue)
    let state = competitiveGateState(vdot: vdot, distanceMeters: dist)
    switch state {
    case .clear:
        print("STATE=clear VDOT=\(vdotValue) DIST=\(dist)")
    case .buildBand(let weeks):
        print("STATE=buildBand RECOMMENDED_WEEKS=\(weeks) VDOT=\(vdotValue) DIST=\(dist)")
    case .blocked(let predicted):
        print("STATE=blocked PREDICTED_SECONDS=\(predicted) VDOT=\(vdotValue) DIST=\(dist)")
    }
}

// (The "recommend" mode lived here — it compared the app's UI-advised
// trainings-per-week against the engine config. That's a UI-layer concern
// tied to RunningLevel, which is app-only, so it's not part of this package.)

// Exercise the realistic-outcome projection across a matrix of starting
// VDOTs × runner levels × plan lengths. Output is parsed by the Python
// test suite to assert the growth math behaves correctly (Adv ≥ Beg at
// long plans; matching projections at short plans; sensible Pro gate
// behavior near build-band VDOT). Format:
//   projection <vdot> <level> <weeks> <distance_m> = <seconds>
if mode == "projection" {
    // Mirror of `planStimulusProfile` + `vdotGrowthPerWeek` + the level
    // baseCaps from PlanConfigurationView.swift. perWeek is derived from
    // the plan's actual structural load (avg weekly miles × 0.005 +
    // quality sessions/wk × 0.04) instead of being picked. Keep these
    // tables in lock-step with the iOS helpers — drift here means
    // projection tests will silently stop predicting what the app shows.
    func stimulusProfile(level: String, distance: Int) -> (mi: Double, q: Double) {
        switch distance {
        case 0..<7500:      // 5K
            switch level {
            case "beg": return (15, 1); case "int": return (25, 2)
            case "adv": return (35, 3); case "cmp": return (40, 3)
            default: return (0, 0)
            }
        case 7500..<15000:  // 10K
            switch level {
            case "beg": return (20, 1); case "int": return (35, 2)
            case "adv": return (45, 3); case "cmp": return (50, 3)
            default: return (0, 0)
            }
        case 15000..<30000: // Half
            switch level {
            case "beg": return (25, 1); case "int": return (40, 2)
            case "adv": return (50, 3); case "cmp": return (55, 3)
            default: return (0, 0)
            }
        default:            // Marathon
            switch level {
            case "beg": return (30, 1); case "int": return (45, 2)
            case "adv": return (55, 3); case "cmp": return (65, 3)
            default: return (0, 0)
            }
        }
    }
    let baseCaps: [String: Double] = [
        "beg":  8.0, "int":  9.0, "adv": 10.0, "cmp":  8.0,
    ]
    let levels = ["beg", "int", "adv", "cmp"]
    let vdots: [Double] = [30, 35, 40, 45, 50, 52, 54, 56, 58, 60]
    let weeks: [Int] = [8, 12, 18, 24, 36]
    let distances: [Int] = [10000, 21097, 42195]

    for v in vdots {
        let cur = VDOT(value: v)
        for lvlName in levels {
            let baseCap = baseCaps[lvlName]!
            let ceiling = VDOT.adaptationCeiling(baseCap: baseCap, current: cur)
            for w in weeks {
                for d in distances {
                    let p = stimulusProfile(level: lvlName, distance: d)
                    var basePerWeek = 0.005 * p.mi + 0.04 * p.q
                    if lvlName == "cmp" { basePerWeek *= 0.5 }
                    let perWeek = basePerWeek * VDOT.newnessBoost(current: cur)
                    if let projected = cur.realisticOutcome(
                            forDistance: d,
                            planWeeks: w,
                            perWeek: perWeek,
                            adaptationCeiling: ceiling) {
                        print("projection vdot=\(v) lvl=\(lvlName) weeks=\(w) dist=\(d) perWeek=\(String(format: "%.3f", perWeek)) ceiling=\(String(format: "%.2f", ceiling)) seconds=\(projected)")
                    }
                }
            }
        }
    }
}

// phases: for each filtered plan, print the phase split + per-week load target
// and multiplier. Shows how phase durations are derived and how load is balanced.
if mode == "phases" {
    for c in filtered {
        let d = calculatePhaseDurations(config: c.config, totalWeeks: c.weeks)
        let base = d["base"] ?? 0, speed = d["speed"] ?? 0, peak = d["peak"] ?? 0, taper = d["taper"] ?? 0
        print("\n=== \(c.label) (\(c.weeks)w): BASE \(base) | SPEED \(speed) | PEAK \(peak) | TAPER \(taper) ===")
        for w in 0..<c.weeks {
            let (phase, wip) = determinePhaseV3(weekIndex: w, baseDur: base, speedDur: speed, peakDur: peak, taperDur: taper)
            let t = calculateWeeklyTargetsV3(weekInPlan: w, weekInPhase: wip, phase: phase, phaseDurations: d, config: c.config)
            let pname = "\(phase)".uppercased().padding(toLength: 6, withPad: " ", startingAt: 0)
            print("W\(String(format: "%2d", w+1))  \(pname)  load=\(String(format: "%6d", Int(t.load)))  dur=\(String(format: "%4d", Int(t.duration)))min\(t.isDeloading ? "  [deload]" : "")")
        }
    }
}
