import Foundation

/// Tombstone keys, one namespace per record type.
public enum Tombstone {
    public static func session(_ id: UUID) -> String { "session:\(id)" }
    public static func food(_ id: UUID) -> String { "food:\(id)" }
    public static func template(_ id: UUID) -> String { "template:\(id)" }
    public static func savedMeal(_ id: UUID) -> String { "meal:\(id)" }
    public static func bodyWeight(_ id: UUID) -> String { "weight:\(id)" }
    public static func exercise(_ id: String) -> String { "exercise:\(id)" }

    /// Tombstones for every record in a document (used by "reset all data").
    public static func all(in data: AppData) -> Set<String> {
        var result = Set<String>()
        data.sessions.forEach { result.insert(session($0.id)) }
        data.foodEntries.forEach { result.insert(food($0.id)) }
        data.customTemplates.forEach { result.insert(template($0.id)) }
        data.savedMeals.forEach { result.insert(savedMeal($0.id)) }
        data.bodyWeights.forEach { result.insert(bodyWeight($0.id)) }
        data.customExercises?.forEach { result.insert(exercise($0.id)) }
        return result
    }
}

/// Merges two copies of the user's data (this device and iCloud) without
/// losing work done offline on either side.
///
/// - Logged records (sessions, food, weigh-ins, templates, saved meals) are
///   unioned by id; a tombstone on either side removes a record everywhere.
///   When both sides have the same record, the newer document's copy wins.
/// - Settings-like fields (profile, program, tier, targets) come from the
///   newer document.
/// - The in-progress workout and rest timer never sync: they belong to the
///   device you're training on.
public enum SyncMerge {
    public static func merge(local: AppData, remote: AppData) -> AppData {
        let localNewer = (local.modifiedAt ?? .distantPast) >= (remote.modifiedAt ?? .distantPast)
        let newer = localNewer ? local : remote
        let older = localNewer ? remote : local
        let tombstones = (local.deletedIDs ?? []).union(remote.deletedIDs ?? [])

        func union<T: Identifiable>(_ newerItems: [T], _ olderItems: [T], key: (T) -> String) -> [T] where T.ID == UUID {
            var seen = Set<UUID>()
            var result: [T] = []
            for item in newerItems + olderItems where !tombstones.contains(key(item)) && seen.insert(item.id).inserted {
                result.append(item)
            }
            return result
        }

        var merged = newer
        merged.sessions = union(newer.sessions, older.sessions, key: { Tombstone.session($0.id) })
            .sorted { $0.startedAt < $1.startedAt }
        merged.foodEntries = union(newer.foodEntries, older.foodEntries, key: { Tombstone.food($0.id) })
            .sorted { $0.date < $1.date }
        merged.customTemplates = union(newer.customTemplates, older.customTemplates, key: { Tombstone.template($0.id) })
        merged.savedMeals = union(newer.savedMeals, older.savedMeals, key: { Tombstone.savedMeal($0.id) })
        merged.bodyWeights = union(newer.bodyWeights, older.bodyWeights, key: { Tombstone.bodyWeight($0.id) })
            .sorted { $0.date < $1.date }
        var exerciseIDs = Set<String>()
        let exercises = ((newer.customExercises ?? []) + (older.customExercises ?? []))
            .filter { !tombstones.contains(Tombstone.exercise($0.id)) && exerciseIDs.insert($0.id).inserted }
        merged.customExercises = exercises.isEmpty ? nil : exercises
        let checkIns = union(newer.checkIns ?? [], older.checkIns ?? [], key: { _ in "" }).sorted { $0.date < $1.date }
        merged.checkIns = checkIns.isEmpty ? nil : checkIns
        merged.scanDates = Array(Set(local.scanDates + remote.scanDates)).sorted()
        merged.dismissedInsightIDs = local.dismissedInsightIDs.union(remote.dismissedInsightIDs)
        merged.lastUpgradeMoment = [local.lastUpgradeMoment, remote.lastUpgradeMoment].compactMap { $0 }.max()
        merged.deletedIDs = tombstones.isEmpty ? nil : tombstones
        merged.activeWorkout = local.activeWorkout
        merged.restTimer = local.restTimer
        merged.modifiedAt = [local.modifiedAt, remote.modifiedAt].compactMap { $0 }.max()
        // A session finished elsewhere may advance the program rotation; the
        // newer document's program already reflects its own sessions.
        if merged.profile == nil { merged.profile = older.profile }
        if merged.program == nil { merged.program = older.program }
        return merged
    }
}
