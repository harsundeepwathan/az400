import Foundation
import SwiftUI
import VectorCore

/// Everything the completion screen needs, computed once when the workout ends.
struct WorkoutSummary: Identifiable, Hashable {
    var session: WorkoutSession
    var records: [PersonalRecord]
    var previous: WorkoutSession?
    /// Volume change vs. the last time this template was trained.
    var volumeChange: Double?
    /// Next-session recommendation for the main lift.
    var nextStep: ProgressionRecommendation?
    var id: UUID { session.id }
}

extension AppModel {
    // MARK: Workout lifecycle

    func startWorkout(_ template: WorkoutTemplate, overrides: [String: ProgressionRecommendation] = [:]) {
        if data.activeWorkout == nil {
            var overrides = overrides
            // Targets the athlete accepted or adjusted take priority over defaults.
            for item in template.exercises where overrides[item.exerciseID] == nil {
                guard let target = data.targetOverrides?[item.exerciseID] else { continue }
                overrides[item.exerciseID] = ProgressionRecommendation(
                    exerciseID: item.exerciseID, action: .repeatLoad, weight: target.weight, reps: target.reps,
                    sets: item.sets, reason: "Your chosen target.", evidence: []
                )
            }
            if !isPro {
                // Free tier: the main lift gets the smart recommendation as a taste of
                // Pro; every other exercise is pre-filled with last session's numbers.
                for item in template.exercises.dropFirst() where overrides[item.exerciseID] == nil {
                    guard let last = history(for: item.exerciseID).first else { continue }
                    overrides[item.exerciseID] = ProgressionRecommendation(
                        exerciseID: item.exerciseID, action: .repeatLoad, weight: last.topWeight,
                        reps: last.topSets.first?.reps ?? item.repRange.upper, sets: item.sets,
                        reason: "Matches your last session.", evidence: [Evidence("Last session", last.summary(unit: unit))]
                    )
                }
            }
            let workout = ActiveWorkout.start(template: template, catalog: catalog, history: data.sessions,
                                              overrides: overrides, restPreferences: data.restPreferences ?? [:],
                                              unit: unit, now: now())
            mutate({ $0.activeWorkout = workout; $0.restTimer = nil }, refreshInsights: false)
            track(.workoutStarted, ["source": .string(isProgramTemplate(template) ? "program" : "custom"),
                                    "exercises": .number(Double(template.exercises.count))])
            Task { await notifications?.requestAuthorizationIfNeeded() }
        }
        syncLiveActivity()
        cover = .workout
    }

    func startEmptyWorkout() {
        if data.activeWorkout == nil {
            mutate({ $0.activeWorkout = .empty(name: "Workout", history: $0.sessions, now: now()) }, refreshInsights: false)
            track(.workoutStarted, ["source": "empty", "exercises": 0])
        }
        cover = .workout
    }

    func resumeWorkout() { cover = .workout }

    /// Hides the workout without ending it. A mini player stays above the tab bar.
    func minimizeWorkout() { cover = nil }

    func updateWorkout(_ change: (inout ActiveWorkout) -> Void) {
        guard var workout = data.activeWorkout else { return }
        change(&workout)
        mutate({ $0.activeWorkout = workout }, refreshInsights: false)
        syncLiveActivity()
    }

    /// Completes a set and kicks off everything that should follow it:
    /// focus moves on, rest starts, haptics and PR celebration fire.
    func completeSet(_ position: SetPosition) {
        guard var workout = data.activeWorkout, let result = workout.complete(position, now: now()) else { return }
        let exerciseID = workout.session.exercises[position.exercise].exerciseID
        var timer: RestTimer?
        if !result.finishedWorkout, result.restSeconds > 0 {
            timer = RestTimer(startedAt: now(), duration: TimeInterval(result.restSeconds), exerciseID: exerciseID)
        }
        mutate({ $0.activeWorkout = workout; $0.restTimer = timer }, refreshInsights: false)
        setLastCompletion(result)
        let set = workout.session.exercises[position.exercise].sets[position.set]
        track(.setLogged, ["kind": .string(set.kind.rawValue), "pr": .bool(result.isPersonalRecord),
                           "superset": .bool(workout.session.exercises[position.exercise].supersetGroup != nil)])

        if let timer, data.profile?.restTimerNotifications ?? true {
            let next = result.nextFocus.flatMap { focus -> String? in
                let log = workout.session.exercises[focus.exercise]
                return catalog[log.exerciseID].map { "\($0.name), set \(focus.set + 1)" }
            }
            notifications?.scheduleRestEnd(at: timer.endsAt, nextUp: next)
        }
        if result.isPersonalRecord {
            let set = workout.session.exercises[position.exercise].sets[position.set]
            Haptics.personalRecord()
            showToast(Icon.trophy, "New personal record",
                      subtitle: "\(Format.weight(set.weight, unit: unit)) × \(set.reps) · \(catalog[exerciseID]?.name ?? "")")
        } else {
            Haptics.setCompleted()
        }
        syncLiveActivity()
    }

    func uncompleteSet(_ position: SetPosition) {
        updateWorkout { $0.uncomplete(position) }
    }

    // MARK: Rest timer

    func adjustRest(by seconds: TimeInterval) {
        guard var timer = data.restTimer else { return }
        timer.adjust(by: seconds, now: now())
        mutate({ $0.restTimer = timer }, refreshInsights: false)
        notifications?.scheduleRestEnd(at: timer.endsAt, nextUp: nil)
        syncLiveActivity()
    }

    func skipRest() {
        mutate({ $0.restTimer = nil }, refreshInsights: false)
        notifications?.cancelRest()
        syncLiveActivity()
    }

    func startRest(seconds: Int, exerciseID: String?) {
        let timer = RestTimer(startedAt: now(), duration: TimeInterval(seconds), exerciseID: exerciseID)
        mutate({ $0.restTimer = timer }, refreshInsights: false)
        notifications?.scheduleRestEnd(at: timer.endsAt, nextUp: nil)
        syncLiveActivity()
    }

    /// Called by the timer view when the countdown reaches zero in the foreground.
    func restDidFinish() {
        guard let timer = data.restTimer else { return }
        // Only buzz if the user is actually here as it ends, not when returning
        // to a timer that ran out while the workout was minimized.
        if now().timeIntervalSince(timer.endsAt) < 2 { Haptics.restFinished() }
        mutate({ $0.restTimer = nil }, refreshInsights: false)
        syncLiveActivity()
    }

    // MARK: Finish

    @discardableResult
    func finishWorkout() -> WorkoutSummary? {
        guard let workout = data.activeWorkout else { return nil }
        let session = workout.finished(at: now())
        notifications?.cancelRest()
        liveActivity?.end()

        guard !session.exercises.isEmpty else {
            discardWorkout()
            return nil
        }

        let previous = analytics.previousSession(templateID: session.templateID, before: session.startedAt, in: data.sessions)
        let records = analytics.personalRecords(for: session, history: data.sessions)
        let change = previous.flatMap { $0.volume > 0 ? (session.volume - $0.volume) / $0.volume : nil }

        mutate { data in
            data.sessions.append(session)
            data.activeWorkout = nil
            data.restTimer = nil
            for log in session.exercises { data.targetOverrides?[log.exerciseID] = nil }
            if let templateID = session.templateID { data.program?.advance(past: templateID) }
        }

        var nextStep: ProgressionRecommendation?
        if let main = session.exercises.first, let exercise = catalog[main.exerciseID] {
            let history = progression.history(for: main.exerciseID, in: data.sessions)
            nextStep = progression.recommend(for: exercise, repRange: main.repRange, sets: main.sets.count,
                                             history: history, unit: unit)
        }
        let summary = WorkoutSummary(session: session, records: records, previous: previous,
                                     volumeChange: change, nextStep: nextStep)
        track(.workoutCompleted, [
            "duration_min": .number((session.duration / 60).rounded()),
            "exercises": .number(Double(session.exercises.count)),
            "sets": .number(Double(session.exercises.reduce(0) { $0 + $1.completedWorkingSets.count })),
            "prs": .number(Double(records.count)),
            "rpe_logged": .bool(session.exercises.contains { $0.sets.contains { $0.rpe != nil } })
        ])
        setLastSummary(summary)
        cover = .summary(session.id)
        if let health { Task { try? await health.save(session) } }
        return summary
    }

    func discardWorkout() {
        notifications?.cancelRest()
        liveActivity?.end()
        mutate({ $0.activeWorkout = nil; $0.restTimer = nil }, refreshInsights: false)
        cover = nil
    }

    func deleteSession(_ session: WorkoutSession) {
        mutate { data in
            data.sessions.removeAll { $0.id == session.id }
            data.deletedIDs = (data.deletedIDs ?? []).union([Tombstone.session(session.id)])
        }
    }

    private func syncLiveActivity() {
        liveActivity?.update(workout: data.activeWorkout, restTimer: data.restTimer, catalog: catalog)
    }

    // MARK: Next-session targets

    func target(for exerciseID: String) -> TargetOverride? {
        data.targetOverrides?[exerciseID]
    }

    func setTarget(exerciseID: String, weight: Double, reps: Int) {
        mutate({ data in
            var targets = data.targetOverrides ?? [:]
            targets[exerciseID] = TargetOverride(weight: weight, reps: reps)
            data.targetOverrides = targets
        }, refreshInsights: false)
    }

    func accept(_ recommendation: ProgressionRecommendation) {
        guard let weight = recommendation.weight else { return }
        setTarget(exerciseID: recommendation.exerciseID, weight: weight, reps: recommendation.reps)
        trackProgression(recommendation, accepted: true)
    }

    // MARK: Programs & templates

    func makeNext(_ template: WorkoutTemplate) {
        mutate { data in
            guard let index = data.program?.workouts.firstIndex(where: { $0.id == template.id }) else { return }
            data.program?.nextIndex = index
        }
    }

    var canCreateRoutine: Bool {
        policy.canCreateRoutine(tier: data.tier, existingCustomRoutines: data.customTemplates.count)
    }

    func isProgramTemplate(_ template: WorkoutTemplate) -> Bool {
        data.program?.workouts.contains { $0.id == template.id } ?? false
    }

    func save(_ template: WorkoutTemplate) {
        mutate { data in
            if let index = data.program?.workouts.firstIndex(where: { $0.id == template.id }) {
                data.program?.workouts[index] = template
            } else if let index = data.customTemplates.firstIndex(where: { $0.id == template.id }) {
                data.customTemplates[index] = template
            } else {
                data.customTemplates.append(template)
            }
        }
    }

    func duplicate(_ template: WorkoutTemplate) {
        guard canCreateRoutine else {
            presentPaywall(.routineLimit)
            return
        }
        var copy = template
        copy.id = UUID()
        copy.name = template.name + " (copy)"
        copy.exercises = template.exercises.map { ExercisePrescription(exerciseID: $0.exerciseID, sets: $0.sets,
                                                                       repRange: $0.repRange, restSeconds: $0.restSeconds) }
        mutate { $0.customTemplates.append(copy) }
    }

    func deleteTemplate(_ template: WorkoutTemplate) {
        mutate { data in
            if data.customTemplates.contains(where: { $0.id == template.id }) {
                data.customTemplates.removeAll { $0.id == template.id }
                data.deletedIDs = (data.deletedIDs ?? []).union([Tombstone.template(template.id)])
            }
            if let program = data.program, program.workouts.count > 1,
               let index = program.workouts.firstIndex(where: { $0.id == template.id }) {
                data.program?.workouts.remove(at: index)
                data.program?.nextIndex = min(program.nextIndex, program.workouts.count - 2)
            }
        }
    }

    func moveProgramWorkouts(from source: IndexSet, to destination: Int) {
        mutate { data in
            guard var program = data.program else { return }
            let nextID = program.nextWorkout?.id
            program.workouts.move(fromOffsets: source, toOffset: destination)
            program.nextIndex = program.workouts.firstIndex { $0.id == nextID } ?? 0
            data.program = program
        }
    }

    // MARK: Exercise intelligence

    func alternatives(for exercise: Exercise, excluding: Set<String> = []) -> [Substitution] {
        substitutions.alternatives(
            for: exercise,
            availableEquipment: data.profile?.equipment.available ?? Set(Equipment.allCases),
            avoiding: data.profile?.avoidedExerciseIDs ?? [],
            excluding: excluding,
            limit: isPro ? 8 : 3
        )
    }

    func replaceExercise(at index: Int, with exercise: Exercise) {
        let repRange = data.activeWorkout?.session.exercises[safe: index]?.repRange ?? RepRange(8, 12)
        let sets = data.activeWorkout?.session.exercises[safe: index]?.sets.count ?? 3
        let rec = progression.recommend(for: exercise, repRange: repRange, sets: sets,
                                        history: history(for: exercise.id), unit: unit)
        updateWorkout { $0.replaceExercise(at: index, with: exercise, recommendation: rec, restSeconds: restPreference(for: exercise.id)) }
    }

    func addExercise(_ exercise: Exercise) {
        let rec = progression.recommend(for: exercise, repRange: RepRange(8, 12), sets: 3,
                                        history: history(for: exercise.id), unit: unit)
        updateWorkout { $0.addExercise(exercise, recommendation: rec, restSeconds: restPreference(for: exercise.id)) }
    }

    // MARK: Rest preferences

    func restPreference(for exerciseID: String) -> Int? { data.restPreferences?[exerciseID] }

    /// Changes rest for this exercise now and remembers it for next time.
    func setRest(_ seconds: Int, forExercise index: Int) {
        guard let exerciseID = data.activeWorkout?.session.exercises[safe: index]?.exerciseID else { return }
        updateWorkout { $0.setRest(seconds, forExercise: index) }
        mutate({ data in
            var preferences = data.restPreferences ?? [:]
            preferences[exerciseID] = max(0, min(seconds, 600))
            data.restPreferences = preferences
        }, refreshInsights: false)
    }

    // MARK: Favourite and custom exercises

    func isFavorite(exerciseID: String) -> Bool { data.favoriteExerciseIDs?.contains(exerciseID) ?? false }

    func toggleFavorite(exerciseID: String) {
        mutate({ data in
            var favorites = data.favoriteExerciseIDs ?? []
            if favorites.contains(exerciseID) { favorites.remove(exerciseID) } else { favorites.insert(exerciseID) }
            data.favoriteExerciseIDs = favorites
        }, refreshInsights: false)
        Haptics.light()
    }

    var favoriteExercises: [Exercise] {
        (data.favoriteExerciseIDs ?? []).compactMap { catalog[$0] }.sorted { $0.name < $1.name }
    }

    var customExercises: [Exercise] { data.customExercises ?? [] }

    @discardableResult
    func addCustomExercise(name: String, muscle: MuscleGroup, equipment: Equipment, isCompound: Bool) -> Exercise {
        let exercise = Exercise.custom(name: name, primaryMuscle: muscle, equipment: equipment, isCompound: isCompound)
        mutate({ $0.customExercises = ($0.customExercises ?? []) + [exercise] }, refreshInsights: false)
        return exercise
    }

    /// Only exercises with no logged history can be deleted, so past workouts never lose their names.
    func canDelete(_ exercise: Exercise) -> Bool {
        exercise.isCustom && !data.sessions.contains { $0.exercises.contains { $0.exerciseID == exercise.id } }
            && !(data.activeWorkout?.session.exercises.contains { $0.exerciseID == exercise.id } ?? false)
    }

    func deleteCustomExercise(_ exercise: Exercise) {
        guard canDelete(exercise) else { return }
        mutate({ data in
            data.customExercises?.removeAll { $0.id == exercise.id }
            data.favoriteExerciseIDs?.remove(exercise.id)
            data.deletedIDs = (data.deletedIDs ?? []).union([Tombstone.exercise(exercise.id)])
        }, refreshInsights: false)
    }

    func toggleAvoided(_ exerciseID: String) {
        updateProfile { profile in
            if profile.avoidedExerciseIDs.contains(exerciseID) {
                profile.avoidedExerciseIDs.remove(exerciseID)
            } else {
                profile.avoidedExerciseIDs.insert(exerciseID)
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
