//
//  PlanGenerator.swift
//  RunPlan
//
//  Plan generation engine: creates workout plans from configurations.
//

import Foundation

// The rewritten createMarathonPlan function
public func createMarathonPlan(startDate: Date, raceDate: Date, from workouts: [Workout], planId: UUID, config: PlanConfiguration) -> [WorkoutEvent] {
    // Normalize dates to start of day to ensure proper comparison
    let calendar = Calendar.current
    let normalizedStartDate = calendar.startOfDay(for: startDate)
    let normalizedRaceDate = calendar.startOfDay(for: raceDate)

    // Calculate total available weeks
    let components = calendar.dateComponents([.day], from: normalizedStartDate, to: normalizedRaceDate)
    guard let days = components.day, days > 0 else {
        fatalError("Race date must be after start date")
    }

    let totalWeeks = Int(max(1, ceil(Double(days) / 7)))

    // Calculate recommended weeks and determine if we need to skip early weeks
    let recommendedWeeks = config.recommendedWeeks()
    let weeksToSkip = max(0, recommendedWeeks - totalWeeks)

    // Use the longer of totalWeeks or recommendedWeeks for phase duration calculation
    // This ensures proper phase distribution even for short plans
    let planningWeeks = max(totalWeeks, recommendedWeeks)

    // Calculate phase durations based on planning weeks
    let phaseDurations = config.calculatePhaseDurations(totalWeeks: planningWeeks)
    
    // Use calculated phase durations
    let basePhaseDuration = phaseDurations.base
    let speedPhaseDuration = phaseDurations.speed
    let peakPhaseDuration = phaseDurations.peak
    let taperPhaseDuration = phaseDurations.taper
    
    // Filter workouts by subtype
    let intervalWorkouts = workouts.filter { $0.subtype == .intervals || $0.subtype == .pyramidIntervals || $0.subtype == .ladderIntervals }
    let longRunWorkouts = workouts.filter { $0.subtype == .long || $0.subtype == .steadyLong }
    let fartlekWorkouts = workouts.filter { $0.subtype == .fartlek }
    let easyWorkouts = workouts.filter { $0.subtype == .easy }
    let recoveryWorkouts = workouts.filter { $0.subtype == .recovery }
    let progressionWorkouts = workouts.filter { $0.subtype == .progression }
    let qualityWorkouts = workouts.filter { $0.subtype == .threshold }
    
    guard !intervalWorkouts.isEmpty, !longRunWorkouts.isEmpty, !easyWorkouts.isEmpty,
          !qualityWorkouts.isEmpty else {
        fatalError("Not enough workout variety to create a comprehensive plan")
    }
    
    var events: [WorkoutEvent] = []
    
    // Calculate initial base load and duration for progressive overload
    let baseLoad = calculateBaseLoad(for: config.runnerLevel, distance: config.distance)
    let weeklyDuration = config.initialWeeklyDuration
    let longRunInitialDuration = Int.random(in: config.initialLongRunDuration)
    
    var usedWorkoutIds: Set<String> = []
    
    var phase = TrainingPhase.base
    
    var previousWeeksWorkouts: [Int: [(workout: Workout, dayOfWeek: Int)]] = [:]

    // Plan generation based on phases
    // If we need to skip early weeks (short plan), start from weeksToSkip
    // This skips base phase weeks to fit the plan into available time
    for weekIndex in weeksToSkip..<planningWeeks {
        let currentPhaseInfo = determinePhase(weekIndex: weekIndex,
                                            baseDuration: basePhaseDuration,
                                            speedDuration: speedPhaseDuration,
                                            peakDuration: peakPhaseDuration,
                                            taperDuration: taperPhaseDuration)
        
        if (phase != currentPhaseInfo.phase) {
            usedWorkoutIds.removeAll()
            phase = currentPhaseInfo.phase
        }
        
        let weekInPhase = currentPhaseInfo.weekInPhase
        
        // Get number of training days for this week
        let trainingDaysCount = determineTrainingDaysCount(phase: phase, weekInPhase: weekInPhase, config: config)
        
        // Determine which training days to use this week
        let weekTrainingDays = selectTrainingDays(count: trainingDaysCount, preferred: config.trainingDays)
        
        // Calculate training load and duration for this week
        let weeklyTargets = calculateWeeklyTargets(
            phase: phase,
            weekInPhase: weekInPhase,
            weekInPlan: weekIndex,
            baseLoad: baseLoad,
            totalWeeks: totalWeeks,
            initialWeeklyDuration: weeklyDuration,
            initialLongRunDuration: longRunInitialDuration,
            config: config
        )
        
        // Create workouts for this week
        let weekWorkouts = createWeekPlan(
            weekIndex: weekIndex,
            phase: phase,
            weekInPhase: weekInPhase,
            trainingDays: weekTrainingDays,
            longestWorkoutDay: config.longestWorkoutDay,
            targets: weeklyTargets,
            workouts: (
                intervals: intervalWorkouts,
                fartlek: fartlekWorkouts,
                longRuns: longRunWorkouts,
                easy: easyWorkouts,
                recovery: recoveryWorkouts,
                progression: progressionWorkouts,
                quality: qualityWorkouts
            ),
            usedWorkoutIds: &usedWorkoutIds,
            previousWeeksWorkouts: &previousWeeksWorkouts,
            config: config
        )
        
        // Convert plan workouts to workout events with specific dates
        // Adjust weekIndex to account for skipped weeks in the actual calendar
        let actualWeekIndex = weekIndex - weeksToSkip
        let weekStartDate = calendar.date(byAdding: .weekOfYear, value: actualWeekIndex, to: normalizedStartDate)!
        for (workout, dayOfWeek) in weekWorkouts {
            guard let workoutDate = getDateForWeekday(weekStartDate: weekStartDate, weekdayIndex: dayOfWeek) else {
                continue
            }

            // Debug: Print for race week
            if weekIndex == planningWeeks - 1 {
                print("Week \(weekIndex) (actual week \(actualWeekIndex)) workout: \(workout.title) on \(workoutDate) (dayOfWeek: \(dayOfWeek)), raceDate: \(normalizedRaceDate), passes filter: \(workoutDate >= normalizedStartDate && workoutDate < normalizedRaceDate)")
            }

            // Add workouts that are within the plan period (from start to race date)
            // Don't add workouts that fall on or after the race date itself
            if workoutDate >= normalizedStartDate && workoutDate < normalizedRaceDate {
                events.append(WorkoutEvent(workout: workout, planId: planId, date: workoutDate))
            }
        }
    }

    // Add race day event on the actual race date (normalized)
    if let raceWorkout = createRaceWorkout(level: config.runnerLevel, distance: config.distance) {
        events.append(WorkoutEvent(workout: raceWorkout, planId: planId, date: normalizedRaceDate))
    }

    return events.sorted { $0.date < $1.date }
}

public func createRaceWorkout(level: RunnerLevel, distance: Int64) -> Workout? {
    // Create a race day workout with free run configuration
    // The workout can be started on the watch just like a regular free run
    return Workout(
        id: -1, // Special ID for race workout
        title: "Race Day",
        type: WorkoutType.race,
        subtype: .easy, // Default subtype
        trainingType: .distanceBased,
        targetType: .noTarget,
        duration: 0, // Open-ended duration
        distance: distance, // Store the actual race distance
        key: "race_day",
        trainingLoad: 0,
        intervals: [
            WorkoutInterval(
                id: 1,
                type: .free,
                duration: 0,
                distance: 0,
                targetType: .noTarget,
                target: .noRange(noValue: true)
            )
        ],
        workRestRatio: 0,
        workDuration: 0,
        restDuration: 0,
        workDistance: 0,
        restDistance: 0
    )
}

func getDateForWeekday(weekStartDate: Date, weekdayIndex: Int) -> Date? {
    let calendar = Calendar.current
    
    // Get the start of the week based on locale
    guard let localeWeekStart = calendar.date(from:
        calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: weekStartDate)) else {
        return nil
    }
    
    // Handle the special case for Sunday (0)
    if weekdayIndex == 0 {
        // For Sunday, add 7 days to get the next Sunday
        // First, get this week's Sunday
        let thisSunday = calendar.date(
            byAdding: .day,
            value: 1 - calendar.component(.weekday, from: localeWeekStart),
            to: localeWeekStart
        )!
        
        // Then add 7 days to get next Sunday
        return calendar.date(byAdding: .day, value: 7, to: thisSunday)
    } else {
        // For other days, standard conversion
        // Convert 0-based weekdayIndex to calendar's 1-based weekday
        let calendarWeekday = weekdayIndex + 1

        // Calculate days to add to get from locale week start to the desired weekday
        let daysToAdd = calendarWeekday - calendar.component(.weekday, from: localeWeekStart)

        // Calculate the resulting date
        guard let resultDate = calendar.date(byAdding: .day, value: daysToAdd, to: localeWeekStart) else {
            return nil
        }

        // If the result is before our weekStartDate, add 7 days to get the next occurrence
        if resultDate < weekStartDate {
            return calendar.date(byAdding: .day, value: 7, to: resultDate)
        }

        return resultDate
    }
}

func calculateBaseLoad(for level: RunnerLevel, distance: Int64) -> Double {
    switch distance {
    case 0..<10000: // 5K to 10K — competitive not offered, falls through to advanced.
        switch level {
        case .beginner:
            return 4500.0
        case .intermediate:
            return 8000.0
        case .advanced, .competitive:
            return 14000.0
        }
    case 10000..<15000: // 10K to 15K — competitive not offered, falls through to advanced.
        switch level {
        case .beginner:
            return 6500.0
        case .intermediate:
            return 12000.0
        case .advanced, .competitive:
            return 16000.0
        }
    case 15000..<21100: // 15K to Half Marathon
        switch level {
        case .beginner:
            return 10000.0
        case .intermediate:
            return 18000.0
        case .advanced:
            return 21000.0
        case .competitive:
            return 27000.0  // sub-1:30 HM — ~29% above advanced
        }
    default: // Marathon and beyond
        switch level {
        case .beginner:
            return 14000.0
        case .intermediate:
            return 21000.0
        case .advanced:
            return 29000.0
        case .competitive:
            return 38000.0  // sub-3:00 marathon — ~31% above advanced
        }
    }
}

func selectTrainingDays(count: Int, preferred: [Int]) -> [Int] {
    // If we have enough preferred days, use them
    if preferred.count >= count {
        return Array(preferred.prefix(count))
    }
    
    // Otherwise, we need to add additional days
    var selectedDays = preferred
    
    // Get firstWeekday from locale (1 = Sunday, 2 = Monday, etc. in Calendar)
    let firstWeekday = Calendar.current.firstWeekday
    
    // Create an array of all days sorted by preference based on locale
    // This creates a culturally appropriate ordering of days to fill in
    let allDays = (0..<7).map { (($0 + firstWeekday - 1) % 7) }
    
    // Add days that aren't already in our preferred list
    for day in allDays {
        if selectedDays.count >= count {
            break
        }
        
        if !selectedDays.contains(day) {
            selectedDays.append(day)
        }
    }
    
    return selectedDays
}

// Updated helper function to determine the current phase and week within that phase
func determinePhase(weekIndex: Int, baseDuration: Int, speedDuration: Int, peakDuration: Int, taperDuration: Int) -> (phase: TrainingPhase, weekInPhase: Int) {
    var accumulatedWeeks = 0
    
    let totalPlanDuration = baseDuration + speedDuration + peakDuration + taperDuration

    // Check if this is the final week (race week)
    if weekIndex == totalPlanDuration - 1 {
        return (.race, 0) // Race week is always the first and only week of race phase
    }

    // Base phase
    if weekIndex < (accumulatedWeeks + baseDuration) {
        return (.base, weekIndex - accumulatedWeeks)
    }
    accumulatedWeeks += baseDuration
    
    // Speed phase
    if weekIndex < (accumulatedWeeks + speedDuration) {
        return (.speed, weekIndex - accumulatedWeeks)
    }
    accumulatedWeeks += speedDuration
    
    // Peak phase
    if weekIndex < (accumulatedWeeks + peakDuration) {
        return (.peak, weekIndex - accumulatedWeeks)
    }
    accumulatedWeeks += peakDuration
    
    // Taper phase
    return (.taper, weekIndex - accumulatedWeeks)
}

// Adjust training day count based on phase and runner level
func determineTrainingDaysCount(phase: TrainingPhase, weekInPhase: Int, config: PlanConfiguration) -> Int {
    // Base number of training days based on runner level
    let baseTrainingDays = config.trainingDays.count
    
    // Adjust based on phase
    switch phase {
    case .base:
        // Progressive increase in base phase for beginners
        if config.runnerLevel == .beginner && weekInPhase < 4 && config.distance > 10000 {
            return baseTrainingDays - 1
        }
        return baseTrainingDays
        
    case .speed, .peak, .taper:
        // Maintain base training days in these phases
        return baseTrainingDays
        
    case .race:
        // Race week has minimal training
        if config.runnerLevel == .advanced {
            return baseTrainingDays - 1
        }
        return baseTrainingDays
    }
}

// Calculate weekly targets based on phase and progression
func calculateWeeklyTargets(
    phase: TrainingPhase,
    weekInPhase: Int,
    weekInPlan: Int,
    baseLoad: Double,
    totalWeeks: Int,
    initialWeeklyDuration: Int,
    initialLongRunDuration: Int,
    config: PlanConfiguration
) -> (totalLoad: Double, totalDuration: Int, longRunDuration: Int, isDeloading: Bool) {
    // Get the total phases duration for scaling the progression
    let phaseDurations = config.calculatePhaseDurations(totalWeeks: totalWeeks) // Use a standard reference
    
    // Calculate phase progression percentage - how far we are through this phase
    let phaseProgressionPercent: Double
    
    switch phase {
    case .base:
        let phaseDuration = phaseDurations.base
        // If phase is shorter than standard, accelerate progression
        let accelerationFactor = max(1.0, Double(5) / Double(phaseDuration))
        phaseProgressionPercent = Double(weekInPhase) / Double(phaseDuration) * accelerationFactor
        
    case .speed:
        let phaseDuration = phaseDurations.speed
        let accelerationFactor = max(1.0, Double(5) / Double(phaseDuration))
        phaseProgressionPercent = Double(weekInPhase) / Double(phaseDuration) * accelerationFactor
        
    case .peak:
        let phaseDuration = phaseDurations.peak
        let accelerationFactor = max(1.0, Double(8) / Double(phaseDuration))
        phaseProgressionPercent = Double(weekInPhase) / Double(phaseDuration) * accelerationFactor
        
    case .taper:
        let phaseDuration = phaseDurations.taper
        let accelerationFactor = max(1.0, Double(2) / Double(phaseDuration))
        phaseProgressionPercent = Double(weekInPhase) / Double(phaseDuration) * accelerationFactor
        
    case .race:
        phaseProgressionPercent = 1.0
    }
    
    // Ensure progression percentage doesn't exceed 1.0
    let normalizedProgressionPercent = min(1.0, phaseProgressionPercent)
    
    // Base values for load and durations
    var load = baseLoad
    var duration = Double(initialWeeklyDuration)
    var longRunDuration = Double(initialLongRunDuration)

    // Apply progressive overload based on phase and week
    switch phase {
    case .base:
        // Progressive increase throughout base phase
        if normalizedProgressionPercent >= 0.85 {
            // Deload at the end of the phase
            let deloadPercent = Double.random(in: config.phaseFinishDeloadPercent)
            load = load * (1.0 + (0.9 * normalizedProgressionPercent)) * (1.0 - (deloadPercent / 100.0))
            duration = duration * (1.0 + (0.9 * normalizedProgressionPercent)) * (1.0 - (deloadPercent / 100.0))
            longRunDuration = longRunDuration * (1.0 + (0.8 * normalizedProgressionPercent)) * (1.0 - (deloadPercent / 100.0))
        } else {
            // Normal progression
            let increasePercent = Double.random(in: config.weeklyLoadIncreasePercent)
            let progressionFactor = 1.0 + (normalizedProgressionPercent * increasePercent / 100.0 * 5)
            load = load * progressionFactor
            duration = duration * progressionFactor
            longRunDuration = longRunDuration * (1.0 + (normalizedProgressionPercent * increasePercent / 100.0 * 4))
        }

    case .speed:
        // Higher intensity in speed phase
        let basePhaseBoost = 1.35 // more load than base phase
        
        if normalizedProgressionPercent >= 0.85 {
            // Deload at the end of the phase
            let deloadPercent = Double.random(in: config.phaseFinishDeloadPercent)
            load = load * basePhaseBoost * (1.0 + (0.8 * normalizedProgressionPercent)) * (1.0 - (deloadPercent / 100.0))
            duration = duration * basePhaseBoost * (1.0 + (0.7 * normalizedProgressionPercent)) * (1.0 - (deloadPercent / 100.0))
            longRunDuration = longRunDuration * basePhaseBoost * (1.0 + (0.6 * normalizedProgressionPercent)) * (1.0 - (deloadPercent / 100.0))
        } else {
            // Normal progression
            let increasePercent = Double.random(in: config.weeklyLoadIncreasePercent)
            let progressionFactor = 1.0 + (normalizedProgressionPercent * increasePercent / 100.0 * 5)
            load = load * basePhaseBoost * progressionFactor
            duration = duration * basePhaseBoost * progressionFactor
            longRunDuration = longRunDuration * basePhaseBoost * (1.0 + (normalizedProgressionPercent * increasePercent / 100.0 * 4))
        }
        
    case .peak:
        // Highest intensity in peak phase
        let peakPhaseBoost = 1.7 // more load than base phase
        
        if normalizedProgressionPercent >= 0.95 {
            // Deload at the end of the phase
            let deloadPercent = Double.random(in: config.phaseFinishDeloadPercent)
            load = load * peakPhaseBoost * (1.0 + (0.5 * normalizedProgressionPercent)) * (1.0 - (deloadPercent / 100.0))
            duration = duration * peakPhaseBoost * (1.0 + (0.4 * normalizedProgressionPercent)) * (1.0 - (deloadPercent / 100.0))
            longRunDuration = longRunDuration * peakPhaseBoost * (1.0 + (0.3 * normalizedProgressionPercent)) * (1.0 - (deloadPercent / 100.0))
        } else {
            // Progressive overload with smaller increments in peak phase
            let increasePercent = Double.random(in: config.weeklyLoadIncreasePercent.lowerBound...(config.weeklyLoadIncreasePercent.upperBound * 0.7))
            let progressionFactor = 1.0 + (normalizedProgressionPercent * increasePercent / 100.0 * 5)
            load = load * peakPhaseBoost * progressionFactor
            duration = duration * peakPhaseBoost * progressionFactor
            longRunDuration = longRunDuration * peakPhaseBoost * (1.0 + (normalizedProgressionPercent * increasePercent / 100.0 * 4))
        }
        
    case .taper:
        // Tapering phase - reduce load substantially based on progression
        let peakPhaseBoost = 1.7
        let taperReduction = 1.0 - (config.taperDeloadPercent / 100.0)
        let taperProgression = 1.0 - normalizedProgressionPercent
        
        load = load * peakPhaseBoost * taperReduction * (0.9 * taperProgression + 0.1)
        duration = duration * peakPhaseBoost * taperReduction * (0.9 * taperProgression + 0.1)
        longRunDuration = longRunDuration * peakPhaseBoost * taperReduction * (0.8 * taperProgression + 0.2)
        
    case .race:
        // Race week - minimal load
        load = baseLoad * 0.6
        duration = Double(initialWeeklyDuration) * 0.6
        longRunDuration = Double(initialLongRunDuration) * 0.5
    }
    
    // Cap maintenance plan long runs at 90 minutes (1h30m)
    if config.distance == 0 {
        longRunDuration = min(longRunDuration, 90)
    }

    // Return both load and duration
    return (load, Int(duration), Int(longRunDuration), normalizedProgressionPercent >= 0.8)
}

// Helper function for workout selection with adaptive targets
func selectWorkoutByTarget(workoutType: WorkoutType, weekIndex: Int, workouts: [Workout], targetLoad: Double, targetDuration: Int, usedWorkoutIds: inout Set<String>, previousWeeksWorkouts: inout [Int: [(workout: Workout, dayOfWeek: Int)]], targets: (totalLoad: Double, totalDuration: Int, longRunDuration: Int, isDeloading: Bool), ultraIntervals: Bool = false, onlyProgressiveLong: Bool = false) -> Workout {
    guard !workouts.isEmpty else {
        fatalError("No workouts available to select from")
    }

    // Filter workouts based on type and constraints
    let filteredWorkouts: [Workout]
    if workoutType.name == WorkoutType.longRun.name {
        // ALL long runs must be >= 60 minutes
        let minLongRunMinutes = 60
        filteredWorkouts = workouts.filter { workout in
            return workout.duration >= minLongRunMinutes * 60
        }
    } else {
        filteredWorkouts = workouts
    }

    // Use filtered workouts if available, otherwise fall back to all workouts
    let workoutsToUse = filteredWorkouts.isEmpty ? workouts : filteredWorkouts

    // Variables to track progression from previous weeks
    var previousWorkoutData: (workDuration: Int64, restDuration: Int64, workRestRatio: Double)? = nil
    
    // Find previous workouts of same type if we're beyond week 1
    if weekIndex > 1 {
        // First check the immediately preceding week
        if let previousWeekWorkouts = previousWeeksWorkouts[weekIndex - 1] {
            // Look for matching workout type
            for (workout, _) in previousWeekWorkouts where workout.type.name == workoutType.name {
                previousWorkoutData = (workout.workDuration, workout.restDuration, workout.workRestRatio)
                break
            }
        }
        
        // If not found in previous week, check earlier weeks (going backwards)
        if previousWorkoutData == nil {
            for checkWeek in (1..<weekIndex-1).reversed() {
                if let earlierWorkouts = previousWeeksWorkouts[checkWeek] {
                    for (workout, _) in earlierWorkouts where workout.type.name == workoutType.name {
                        previousWorkoutData = (workout.workDuration, workout.restDuration, workout.workRestRatio)
                        break
                    }
                }
                if previousWorkoutData != nil { break }
            }
        }
    }
    
    // Calculate progression targets if we have previous data
    let progressionFactor: Double = targets.isDeloading ? 0.9 : 1.15 // 10% decrease for deload, 10% increase for progression
    
    // Calculate a combined score based on how well each workout matches both load and duration
    let workoutsWithScore = workoutsToUse.map { workout -> (workout: Workout, score: Double) in
        let workoutLoad = Double(workout.trainingLoad)
        let workoutDuration = Double(workout.duration / 60)
        
        // Calculate percentage differences from targets
        let loadDiffPercent = abs(workoutLoad - targetLoad) / targetLoad
        let durationDiffPercent = abs(workoutDuration - Double(targetDuration)) / Double(targetDuration)
        
        // Combined score with weights based on workout type
        var score = loadDiffPercent * 0.5 + durationDiffPercent * 0.5
        
        switch workout.type.name {
        case WorkoutType.progressionRun.name:
            score = loadDiffPercent * 0.8 + durationDiffPercent * 0.2
        case WorkoutType.thresholdRun.name:
            score = loadDiffPercent * 0.6 + durationDiffPercent * 0.4
//        case WorkoutType.intervalRun.name:
//            score = loadDiffPercent * 0.7 + durationDiffPercent * 0.3
        case WorkoutType.longRun.name:
            score = loadDiffPercent * 0.4 + durationDiffPercent * 0.6
        default:
            break
        }
        
        // Strongly penalize reusing workouts
        if usedWorkoutIds.contains(workout.key) {
            return (workout, 1e10) // Effectively exclude already used workouts
        }
        
        // Avoid using zone 5 for intervals by default, only if ultraIntervals
        if workout.type.name == WorkoutType.intervalRun.name && workout.intervals.count > 1 {
            if ultraIntervals  {
                if workout.intervals[1].target == TargetRange.heartRateZone(zone: 4) {
                    return (workout, 1e10)
                }
            }
            else {
                if workout.intervals[1].target == TargetRange.heartRateZone(zone: 5) {
                    return (workout, 1e10)
                }
            }
        }
        
        // Apply progressive overload rules if we have previous data for this workout type
        if let previousData = previousWorkoutData, workout.type.name == workoutType.name {
            // Calculate ideal work/rest ratio based on progression
            let idealWorkRestRatio = previousData.workRestRatio * progressionFactor
            
            // Calculate ideal work and rest durations
            let idealWorkDuration = Double(previousData.workDuration) * (targets.isDeloading ? 1.0 : 1.2)
            let idealRestDuration = Double(previousData.restDuration) * (targets.isDeloading ? 1.1 : 0.90)
            
            // Calculate differences from ideal progression
            let workRestDiffPercent = abs(workout.workRestRatio - idealWorkRestRatio) / idealWorkRestRatio
            let workDurationDiffPercent = abs(Double(workout.workDuration) - idealWorkDuration) / idealWorkDuration
            let restDurationDiffPercent = abs(Double(workout.restDuration) - idealRestDuration) / idealRestDuration
            
            // For interval-type workouts, give significant weight to work/rest progression
            if workout.type.name == WorkoutType.intervalRun.name ||
               workout.type.name == WorkoutType.speedRun.name ||
                workout.type.name == WorkoutType.thresholdRun.name ||
               workout.type.name == WorkoutType.fartlekRun.name {
                // Adjust score based on progression aspects
                let progressionScore = workRestDiffPercent * 0.4 + workDurationDiffPercent * 0.3 + restDurationDiffPercent * 0.3
                
                // Blend original score with progression score
                score = score * 0.4 + progressionScore * 0.6
            }
        }
        
        return (workout, score)
    }
    
    // Find the workout with the lowest score (best match)
    let bestMatch = workoutsWithScore.min { $0.score < $1.score }
    
    if let bestMatchWorkout = bestMatch?.workout {
        usedWorkoutIds.insert(bestMatchWorkout.key)
        return bestMatchWorkout
    }
    
    // Fallback if all workouts have been used (shouldn't happen with normal usage)
    // Reset used workouts for this category and select best match
    let fallbackMatch = workoutsToUse.min { abs(Double($0.trainingLoad) - targetLoad) < abs(Double($1.trainingLoad) - targetLoad) }

    if let fallbackWorkout = fallbackMatch {
        // Remove similar workouts from used set to allow rotation
        usedWorkoutIds.remove(fallbackWorkout.key)
        return fallbackWorkout
    }

    return workoutsToUse[0]
}

// Helper function for week plan creation with improved variety
func createWeekPlan(
    weekIndex: Int,
    phase: TrainingPhase,
    weekInPhase: Int,
    trainingDays: [Int],
    longestWorkoutDay: Int,
    targets: (totalLoad: Double, totalDuration: Int, longRunDuration: Int, isDeloading: Bool),
    workouts: (
        intervals: [Workout],
        fartlek: [Workout],
        longRuns: [Workout],
        easy: [Workout],
        recovery: [Workout],
        progression: [Workout],
        quality: [Workout]
    ),
    usedWorkoutIds: inout Set<String>,
    previousWeeksWorkouts: inout [Int: [(workout: Workout, dayOfWeek: Int)]],
    config: PlanConfiguration
) -> [(workout: Workout, dayOfWeek: Int)] {
    // Sort training days to ensure consistent assignment of workouts
    let sortedTrainingDays = trainingDays.sorted()
    var daysCount = sortedTrainingDays.count
    
    if config.useSeparateDayForLongRun {
        daysCount += 1
    }

    // Get workout distribution with improved variety
    
    var runCounts = determineEnduranceWorkoutTypeDistribution(
        daysCount: daysCount,
        phase: phase,
        weekInPhase: weekInPhase,
        weekIndex: weekIndex,
        runnerLevel: config.runnerLevel,
        distance: config.distance,
        isDeloading: targets.isDeloading
    )

    if config.distance < 10000 {
        runCounts = determineSpeedWorkoutTypeDistribution(
            daysCount: daysCount,
            phase: phase,
            weekInPhase: weekInPhase,
            runnerLevel: config.runnerLevel,
            isDeloading: targets.isDeloading
        )
    }

    // Calculate targets for each workout type
    let totalLoadWithoutLongRun = targets.totalLoad * 0.6
    let totalDurationWithoutLongRun = targets.totalDuration - targets.longRunDuration
    
    // Distribute load proportionally
    let longRunLoad = targets.totalLoad * 0.4
    
    // Use a more balanced load distribution
    let qualityWorkoutCount = max(1, runCounts.totalQualityCount())
    // Calculate balanced quality workout load - more consistent regardless of workout count
    let baseQualityLoad = totalLoadWithoutLongRun * 0.5
    let qualityScalingFactor = pow(0.85, Double(qualityWorkoutCount - 1))
    let qualityLoadPerWorkout = baseQualityLoad * qualityScalingFactor
    
    // Individual load for each workout type
    let intervalRunLoad = qualityLoadPerWorkout * 0.9 // Slightly higher for intervals
    let qualityRunLoad = qualityLoadPerWorkout * 1.1
    let progressionRunLoad = qualityLoadPerWorkout * 0.9
    let fartlekRunLoad = qualityLoadPerWorkout * 1.1
    let easyRunLoad = totalLoadWithoutLongRun * 0.3 / max(1, Double(runCounts.easyRunsCount))

    // Calculate durations with more variety
    let intervalRunDuration = Int(Double(totalDurationWithoutLongRun) * 0.25)
    let qualityRunDuration = Int(Double(totalDurationWithoutLongRun) * 0.3)
    let easyRunDuration = Int(Double(totalDurationWithoutLongRun) * 0.4 / max(1, Double(runCounts.easyRunsCount)))
    let progressionRunDuration = Int(Double(totalDurationWithoutLongRun) * 0.28)
    let fartlekRunDuration = Int(Double(totalDurationWithoutLongRun) * 0.22)
    
    // Generate workouts based on phase and available training days
    var allWorkouts: [Workout] = []
    
    switch phase {
    case .base, .speed, .peak, .taper, .race:
        // Add long run if we have days
//        if daysCount > 0 && runCounts.longRunsCount > 0 {
        for _ in 0..<runCounts.longRunsCount {
            // For 5K beginner/intermediate: only select progressive long runs
            let onlyProgressiveLong = (config.distance == 5000 &&
                                      (config.runnerLevel == .beginner || config.runnerLevel == .intermediate))

            let longRunWorkout = selectWorkoutByTarget(
                workoutType: .longRun,
                weekIndex: weekIndex,
                workouts: workouts.longRuns,
                targetLoad: longRunLoad,
                targetDuration: targets.longRunDuration,
                usedWorkoutIds: &usedWorkoutIds,
                previousWeeksWorkouts: &previousWeeksWorkouts,
                targets: targets,
                onlyProgressiveLong: onlyProgressiveLong
            )
            allWorkouts.append(longRunWorkout)
        }
        
        // Add interval workouts with variety based on week
        for _ in 0..<runCounts.intervalRunsCount {
            // Add random variation to target load (±10%)
//            let variationFactor = 1.0 + Double.random(in: -0.1...0.1)
            let adjustedLoad = intervalRunLoad // * variationFactor
            
            let intervalWorkout = selectWorkoutByTarget(
                workoutType: .intervalRun,
                weekIndex: weekIndex,
                workouts: workouts.intervals,
                targetLoad: adjustedLoad,
                targetDuration: intervalRunDuration,
                usedWorkoutIds: &usedWorkoutIds,
                previousWeeksWorkouts: &previousWeeksWorkouts,
                targets: targets
            )
            allWorkouts.append(intervalWorkout)
        }
        
        // Intervals in zone 5
        for _ in 0..<runCounts.ultraIntervalRunsCount {
            let longRunWorkout = selectWorkoutByTarget(
                workoutType: .intervalRun,
                weekIndex: weekIndex,
                workouts: workouts.intervals,
                targetLoad: intervalRunLoad,
                targetDuration: intervalRunDuration,
                usedWorkoutIds: &usedWorkoutIds,
                previousWeeksWorkouts: &previousWeeksWorkouts,
                targets: targets,
                ultraIntervals: true
            )
            allWorkouts.append(longRunWorkout)
        }
        
        // Add fartlek workouts
        for _ in 0..<runCounts.fartlekRunsCount {
            let variationFactor = 1.0 + Double.random(in: -0.1...0.1)
            let adjustedLoad = fartlekRunLoad * variationFactor
            
            let fartlekWorkout = selectWorkoutByTarget(
                workoutType: .fartlekRun,
                weekIndex: weekIndex,
                workouts: workouts.fartlek,
                targetLoad: adjustedLoad,
                targetDuration: fartlekRunDuration,
                usedWorkoutIds: &usedWorkoutIds,
                previousWeeksWorkouts: &previousWeeksWorkouts,
                targets: targets
            )
            allWorkouts.append(fartlekWorkout)
        }
        
        // Add quality workouts
        for _ in 0..<runCounts.qualityRunsCount {
            let variationFactor = 1.0 + Double.random(in: -0.1...0.1)
            let adjustedLoad = qualityRunLoad * variationFactor
            
            let qualityWorkout = selectWorkoutByTarget(
                workoutType: .thresholdRun,
                weekIndex: weekIndex,
                workouts: workouts.quality,
                targetLoad: adjustedLoad,
                targetDuration: qualityRunDuration,
                usedWorkoutIds: &usedWorkoutIds,
                previousWeeksWorkouts: &previousWeeksWorkouts,
                targets: targets
            )
            allWorkouts.append(qualityWorkout)
        }
        
        // Add progression workouts
        for _ in 0..<runCounts.progressionRunsCount {
            let variationFactor = 1.0 + Double.random(in: -0.1...0.1)
            let adjustedLoad = progressionRunLoad * variationFactor
            
            let progressionWorkout = selectWorkoutByTarget(
                workoutType: .progressionRun,
                weekIndex: weekIndex,
                workouts: workouts.progression,
                targetLoad: adjustedLoad,
                targetDuration: progressionRunDuration,
                usedWorkoutIds: &usedWorkoutIds,
                previousWeeksWorkouts: &previousWeeksWorkouts,
                targets: targets
            )
            allWorkouts.append(progressionWorkout)
        }
        
        // Add easy runs to fill remaining slots
        let remainingDaysCount = max(0, daysCount - allWorkouts.count)
        for _ in 0..<remainingDaysCount {
            // Add some variety to easy runs too
            let variationFactor = 1.0 + Double.random(in: -0.15...0.15)
            let adjustedLoad = easyRunLoad * variationFactor
            
            let easyWorkout = selectWorkoutByTarget(
                workoutType: .easyRun,
                weekIndex: weekIndex,
                workouts: workouts.easy,
                targetLoad: adjustedLoad,
                targetDuration: easyRunDuration,
                usedWorkoutIds: &usedWorkoutIds,
                previousWeeksWorkouts: &previousWeeksWorkouts,
                targets: targets
            )
            allWorkouts.append(easyWorkout)
        }
//    case .race:
//        // Race week - only include very short and easy workouts
//        // No more than 3 training days before race
//        let raceWeekDays = min(sortedTrainingDays.count, 3)
//        
//        for _ in 0..<raceWeekDays {
//            let easyLoad = targets.totalLoad / Double(raceWeekDays)
//            let easyDuration = targets.totalDuration / raceWeekDays
//            
//            let raceWeekWorkout = selectWorkoutByTarget(
//                workoutType: .easyRun,
//                weekIndex: weekIndex,
//                workouts: workouts.easy,
//                targetLoad: easyLoad * 0.5,
//                targetDuration: Int(Double(easyDuration) * 0.5),
//                usedWorkoutIds: &usedWorkoutIds,
//                previousWeeksWorkouts: &previousWeeksWorkouts,
//                targets: targets
//            )
//            allWorkouts.append(raceWeekWorkout)
//        }
    }
    
    // Categorize workouts by type
    var workoutsByCategory: [WorkoutCategory: [Workout]] = [:]
    
    for workout in allWorkouts {
        let category = determineWorkoutCategory(workout: workout)
        if workoutsByCategory[category] == nil {
            workoutsByCategory[category] = []
        }
        workoutsByCategory[category]?.append(workout)
    }
    
    // Strategically distribute workouts
    var weekPlan: [(workout: Workout, dayOfWeek: Int)] = []
    var availableDays = sortedTrainingDays
    
    // Sort long runs by duration
    workoutsByCategory[.longRun]?.sort(by: { $0.duration < $1.duration })
    
    if let longestRun = workoutsByCategory[.longRun]?.first, !availableDays.isEmpty {
//        let lastDay = availableDays.removeLast() // Get the last training day
        weekPlan.append((longestRun, longestWorkoutDay))
        workoutsByCategory[.longRun]?.removeFirst()

        // Remove the long run day from available days to prevent duplicate workouts
        if let index = availableDays.firstIndex(of: longestWorkoutDay) {
            availableDays.remove(at: index)
        }

        // Process additional long runs with spacing between them
        let remainingLongRuns = workoutsByCategory[.longRun] ?? []
        workoutsByCategory[.longRun]?.removeAll()
        
        // Distribute remaining long runs with at least one day in between if possible
        for longRun in remainingLongRuns {
            if availableDays.count >= 3 {
                // Try to keep at least 1 day between long runs if we have enough days
                let index = max(0, availableDays.count - 3)
                let day = availableDays.remove(at: index)
                weekPlan.append((longRun, day))
            } else if !availableDays.isEmpty {
                // If not enough days, place it on any available day
                let day = availableDays.removeFirst()
                weekPlan.append((longRun, day))
            }
        }
    }
    
    // Prepare hard and easy workouts
    var hardWorkouts = (workoutsByCategory[.interval] ?? []) + (workoutsByCategory[.quality] ?? [])
    var easyWorkouts = workoutsByCategory[.easy] ?? []
    
    // Sort hard workouts by intensity
//    hardWorkouts.sort { $0.trainingLoad > $1.trainingLoad }
    
    // Alternate between hard and easy workouts for optimal recovery
    // Use week and phase to vary the pattern
    let patternVariation = (weekIndex + (phase == .speed ? 1 : 0) + (phase == .peak ? 2 : 0)) % 3
    let startWithHard: Bool
    
    if patternVariation == 0 {
        // Standard pattern - alternate starting with hard/easy based on week
        startWithHard = weekIndex % 2 == 0 || hardWorkouts.count > easyWorkouts.count
    } else if patternVariation == 1 {
        // Cluster pattern - try to group similar workouts together if we have enough days
        startWithHard = daysCount >= 4 && hardWorkouts.count > 1
    } else {
        // Balanced pattern - spread evenly
        startWithHard = !hardWorkouts.isEmpty
    }
    
    // Distribute workouts in pattern based on the variation
    while !availableDays.isEmpty && (hardWorkouts.count > 0 || easyWorkouts.count > 0) {
        if startWithHard {
            // Hard workout first, if available
            if !hardWorkouts.isEmpty {
                let workout = hardWorkouts.removeFirst()
                let day = availableDays.removeFirst()
                weekPlan.append((workout, day))
            }
            
            // Easy workout next, if available and we still have days
            if !easyWorkouts.isEmpty && !availableDays.isEmpty {
                let workout = easyWorkouts.removeFirst()
                let day = availableDays.removeFirst()
                weekPlan.append((workout, day))
            }
        } else {
            // Easy workout first, if available
            if !easyWorkouts.isEmpty {
                let workout = easyWorkouts.removeFirst()
                let day = availableDays.removeFirst()
                weekPlan.append((workout, day))
            }
            
            // Hard workout next, if available and we still have days
            if !hardWorkouts.isEmpty && !availableDays.isEmpty {
                let workout = hardWorkouts.removeFirst()
                let day = availableDays.removeFirst()
                weekPlan.append((workout, day))
            }
        }
        
        // Break if we're out of workouts
        if hardWorkouts.isEmpty && easyWorkouts.isEmpty {
            break
        } else if hardWorkouts.isEmpty {
            // Add remaining easy workouts
            while !easyWorkouts.isEmpty && !availableDays.isEmpty {
                let workout = easyWorkouts.removeFirst()
                let day = availableDays.removeFirst()
                weekPlan.append((workout, day))
            }
        } else if easyWorkouts.isEmpty {
            // Add remaining hard workouts with spacing if possible
            if availableDays.count >= hardWorkouts.count * 2 - 1 {
                // We have enough days to space them out
                var daysToUse: [Int] = []
                for i in 0..<hardWorkouts.count {
                    daysToUse.append(availableDays[i * 2])
                }
                
                availableDays = availableDays.filter { !daysToUse.contains($0) }
                
                for i in 0..<hardWorkouts.count {
                    weekPlan.append((hardWorkouts[i], daysToUse[i]))
                }
                hardWorkouts.removeAll()
            } else {
                // Not enough days to space out, just add sequentially
                while !hardWorkouts.isEmpty && !availableDays.isEmpty {
                    let workout = hardWorkouts.removeFirst()
                    let day = availableDays.removeFirst()
                    weekPlan.append((workout, day))
                }
            }
        }
    }
    
    // Add any leftover workouts from other categories (like progression runs)
    let remainingWorkoutCategories = Array(workoutsByCategory.keys).filter { $0 != .longRun && $0 != .interval && $0 != .quality && $0 != .easy }
    
    for category in remainingWorkoutCategories {
        if let workoutsInCategory = workoutsByCategory[category] {
            for workout in workoutsInCategory {
                // Check if this workout is already in the plan
                let isAlreadyPlanned = weekPlan.contains { $0.workout.id == workout.id }
                
                if !isAlreadyPlanned && !availableDays.isEmpty {
                    let day = availableDays.removeFirst()
                    weekPlan.append((workout, day))
                }
            }
        }
    }
    
    // Store previous week workouts
    previousWeeksWorkouts[weekIndex] = weekPlan
    
    // Sort by day of week for easier reading
    return weekPlan.sorted { $0.dayOfWeek < $1.dayOfWeek }
}

// Helper function to determine the workout type category for our distribution algorithm
