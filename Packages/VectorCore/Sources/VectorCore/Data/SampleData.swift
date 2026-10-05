import Foundation

/// Deterministic pseudo-random generator so sample data and tests are stable.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Realistic history for SwiftUI previews, screenshots and demo mode. The
/// training log is produced by running the real progression engine, so it
/// exercises the same code paths as live use.
public enum SampleData {
    static let startingLoads: [String: Double] = [
        "back-squat": 70, "romanian-deadlift": 70, "leg-press": 120, "leg-curl": 40, "standing-calf-raise": 60,
        "bench-press": 62.5, "barbell-row": 60, "overhead-press": 40, "lat-pulldown": 55, "lateral-raise": 8,
        "ez-bar-curl": 25, "triceps-pushdown": 25, "deadlift": 110, "front-squat": 55, "hip-thrust": 80,
        "walking-lunge": 16, "leg-extension": 45, "incline-db-press": 24, "seated-cable-row": 55,
        "db-shoulder-press": 18, "cable-fly": 12.5, "face-pull": 20, "overhead-triceps-extension": 20,
        "pull-up": 0, "hanging-leg-raise": 0
    ]

    public static func answers() -> OnboardingAnswers {
        OnboardingAnswers(name: "Alex", goal: .buildMuscle, experience: .intermediate, daysPerWeek: 4,
                          equipment: .fullGym, nutritionGoal: .maintain, sex: .male, age: 31,
                          heightCm: 180, weightKg: 77.5, targetWeightKg: 76)
    }

    public static func appData(now: Date = Date(), calendar: Calendar = .current, weeks: Int = 8) -> AppData {
        var rng = SeededGenerator(seed: 42)
        let catalog = ExerciseCatalog.standard
        let plan = PlanGenerator(catalog: catalog, calendar: calendar).generate(from: answers(), now: now)
        var profile = plan.profile
        profile.targets = NutritionTargets(calories: 2300, protein: 150, carbs: 240, fat: 70)
        var program = plan.program
        let engine = ProgressionEngine()

        // Training: four sessions a week on a 1-2-2-2 day rhythm.
        var sessions: [WorkoutSession] = []
        let gaps = [1, 2, 2, 2]
        let today = calendar.startOfDay(for: now)
        var day = calendar.date(byAdding: .day, value: -weeks * 7, to: today)!
        var index = 0
        while true {
            let start = calendar.date(byAdding: .hour, value: 18, to: day)!
            guard calendar.dateComponents([.day], from: day, to: today).day ?? 0 >= 2 else { break }
            let template = program.workouts[index % program.workouts.count]
            var logs: [ExerciseLog] = []
            for item in template.exercises {
                guard let exercise = catalog[item.exerciseID] else { continue }
                let history = engine.history(for: item.exerciseID, in: sessions)
                let rec = engine.recommend(for: exercise, repRange: item.repRange, sets: item.sets, history: history)
                let weight = rec.weight ?? startingLoads[item.exerciseID] ?? 20
                var sets: [SetLog] = []
                for setIndex in 0..<item.sets {
                    let roll = Double.random(in: 0...1, using: &rng)
                    // Later sets fatigue a little more often.
                    let shortfall = roll < 0.9 - Double(setIndex) * 0.05 ? 0 : (roll < 0.97 ? 1 : 2)
                    let reps = max(rec.reps - shortfall, 1)
                    sets.append(SetLog(weight: weight, reps: reps, isCompleted: true,
                                       completedAt: start.addingTimeInterval(Double(logs.count * 600 + setIndex * 150)),
                                       targetReps: rec.reps, targetWeight: rec.weight))
                }
                logs.append(ExerciseLog(exerciseID: item.exerciseID, sets: sets, repRange: item.repRange,
                                        restSeconds: exercise.defaultRestSeconds))
            }
            let minutes = Double(Int.random(in: 52...66, using: &rng))
            sessions.append(WorkoutSession(templateID: template.id, name: template.name, startedAt: start,
                                           endedAt: start.addingTimeInterval(minutes * 60), exercises: logs))
            day = calendar.date(byAdding: .day, value: gaps[index % gaps.count], to: day)!
            index += 1
        }
        program.nextIndex = index % program.workouts.count

        // Nutrition: two weeks of logging, protein on target for the last five days.
        var food: [FoodEntry] = []
        let db = FoodDatabase()
        func add(_ id: String, _ grams: Double, _ meal: MealType, _ date: Date) {
            guard let item = db.food(id: id) else { return }
            food.append(FoodEntry(date: date, meal: meal, name: item.name, foodID: id, grams: grams,
                                  macros: item.macros(grams: grams), source: .search))
        }
        for offset in (1...14).reversed() {
            let date = calendar.date(byAdding: .day, value: -offset, to: today)!
            let hit = offset <= 5
            add("oats", 70, .breakfast, date.addingTimeInterval(8 * 3600))
            add("greek-yogurt", hit ? 250 : 170, .breakfast, date.addingTimeInterval(8 * 3600))
            add("blueberries", 80, .breakfast, date.addingTimeInterval(8 * 3600))
            add("chicken-breast", hit ? 200 : 140, .lunch, date.addingTimeInterval(13 * 3600))
            add("white-rice", 220, .lunch, date.addingTimeInterval(13 * 3600))
            add("broccoli", 120, .lunch, date.addingTimeInterval(13 * 3600))
            add(offset % 2 == 0 ? "salmon" : "beef-mince-5", hit ? 180 : 140, .dinner, date.addingTimeInterval(19 * 3600))
            add(offset % 3 == 0 ? "pasta" : "potato", 250, .dinner, date.addingTimeInterval(19 * 3600))
            add("olive-oil", 10, .dinner, date.addingTimeInterval(19 * 3600))
            add(hit ? "whey" : "banana", hit ? 35 : 118, .snacks, date.addingTimeInterval(16 * 3600))
            add("almonds", 30, .snacks, date.addingTimeInterval(16 * 3600))
        }
        // Today so far: breakfast, lunch and a snack.
        add("oats", 80, .breakfast, today.addingTimeInterval(8 * 3600))
        add("greek-yogurt", 250, .breakfast, today.addingTimeInterval(8 * 3600))
        add("blueberries", 100, .breakfast, today.addingTimeInterval(8 * 3600))
        add("chicken-breast", 190, .lunch, today.addingTimeInterval(13 * 3600))
        add("white-rice", 230, .lunch, today.addingTimeInterval(13 * 3600))
        add("avocado", 80, .lunch, today.addingTimeInterval(13 * 3600))
        add("protein-bar", 60, .snacks, today.addingTimeInterval(16 * 3600))
        add("coffee-latte", 360, .snacks, today.addingTimeInterval(16 * 3600))

        // Body weight: gentle downward trend with daily water noise.
        var weights: [BodyWeightEntry] = []
        for offset in (0..<(weeks * 7)).reversed() {
            let date = calendar.date(byAdding: .day, value: -offset, to: today)!.addingTimeInterval(7 * 3600)
            let trend = 78.6 - Double(weeks * 7 - offset) * 0.022
            let noise = Double.random(in: -0.45...0.45, using: &rng)
            weights.append(BodyWeightEntry(date: date, kilograms: ((trend + noise) * 10).rounded() / 10))
        }

        return AppData(profile: profile, program: program, sessions: sessions, foodEntries: food, bodyWeights: weights)
    }
}
