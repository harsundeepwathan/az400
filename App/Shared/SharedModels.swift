import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Compiled into both the app and the widget extension.
enum AppGroup {
    static let identifier = "group.app.vector"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

/// Tiny, widget-friendly projection of today's state. The app writes it on
/// every change; widgets only ever read it (they never touch the main store).
struct WidgetSnapshot: Codable, Hashable {
    var nextWorkoutName: String?
    var nextWorkoutDetail: String?
    var caloriesConsumed: Double
    var caloriesTarget: Double
    var proteinConsumed: Double
    var proteinTarget: Double
    var updatedAt: Date

    static let fileName = "widget-snapshot.json"

    static let placeholder = WidgetSnapshot(
        nextWorkoutName: "Lower A", nextWorkoutDetail: "6 exercises · ~55 min",
        caloriesConsumed: 1640, caloriesTarget: 2300, proteinConsumed: 112, proteinTarget: 150, updatedAt: Date()
    )

    static func load() -> WidgetSnapshot? {
        guard let url = AppGroup.containerURL?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        guard let url = AppGroup.containerURL?.appendingPathComponent(Self.fileName),
              let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

#if canImport(ActivityKit) && os(iOS)
/// Live Activity / Dynamic Island payload for an in-progress workout.
struct WorkoutActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var exerciseName: String
        var setLabel: String
        var completedSets: Int
        var totalSets: Int
        /// When non-nil, the activity renders a live rest countdown to this date.
        var restEndsAt: Date?
    }

    var workoutName: String
    var startedAt: Date
}
#endif
