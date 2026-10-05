import ActivityKit
import SwiftUI
import WidgetKit

@main
struct VectorWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        WorkoutLiveActivity()
    }
}

// MARK: - Today widget

struct TodayEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry { TodayEntry(date: Date(), snapshot: .placeholder) }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(TodayEntry(date: Date(), snapshot: WidgetSnapshot.load() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let entry = TodayEntry(date: Date(), snapshot: WidgetSnapshot.load() ?? .placeholder)
        // The app reloads timelines on every change; this is just a safety refresh.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(3600))))
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "VectorToday", provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("Your next workout and today's calories.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

private let widgetAccent = Color(red: 0.12, green: 0.38, blue: 1.0)

struct TodayWidgetView: View {
    var entry: TodayEntry
    @Environment(\.widgetFamily) private var family

    private var calorieProgress: Double {
        entry.snapshot.caloriesTarget > 0 ? min(entry.snapshot.caloriesConsumed / entry.snapshot.caloriesTarget, 1) : 0
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: calorieProgress) {
                Image(systemName: "flame")
            } currentValueLabel: {
                Text("\(Int(entry.snapshot.caloriesTarget - entry.snapshot.caloriesConsumed))")
            }
            .gaugeStyle(.accessoryCircular)
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text(entry.snapshot.nextWorkoutName ?? "Rest day").font(.headline)
                Text("\(Int(entry.snapshot.caloriesConsumed)) / \(Int(entry.snapshot.caloriesTarget)) kcal")
                    .font(.caption)
            }
        case .systemMedium:
            HStack(spacing: 16) {
                workout
                Divider()
                nutrition
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                workout
                Spacer(minLength: 0)
                ProgressView(value: calorieProgress).tint(widgetAccent)
                Text("\(Int(max(entry.snapshot.caloriesTarget - entry.snapshot.caloriesConsumed, 0))) kcal left")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
        }
    }

    private var workout: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NEXT").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(entry.snapshot.nextWorkoutName ?? "Rest day")
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail = entry.snapshot.nextWorkoutDetail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(URL(string: "vector://workout"))
    }

    private var nutrition: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TODAY").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text("\(Int(entry.snapshot.caloriesConsumed))")
                .font(.title2.weight(.bold))
                .monospacedDigit()
            + Text(" / \(Int(entry.snapshot.caloriesTarget)) kcal").font(.caption).foregroundStyle(.secondary)
            ProgressView(value: calorieProgress).tint(widgetAccent)
            Text("Protein \(Int(entry.snapshot.proteinConsumed)) / \(Int(entry.snapshot.proteinTarget))g")
                .font(.caption)
                .monospacedDigit()
            Link(destination: URL(string: "vector://scan")!) {
                Label("Scan Meal", systemImage: "camera.viewfinder")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(widgetAccent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Live Activity & Dynamic Island

struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            LockScreenWorkoutView(context: context)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "vector://workout"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.exerciseName).font(.headline).lineLimit(1)
                        Text(context.state.setLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    restOrElapsed(context, large: true)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: Double(context.state.completedSets), total: Double(max(context.state.totalSets, 1)))
                        .tint(widgetAccent)
                }
            } compactLeading: {
                Image(systemName: "dumbbell.fill").foregroundStyle(widgetAccent)
            } compactTrailing: {
                restOrElapsed(context, large: false)
            } minimal: {
                Image(systemName: context.state.restEndsAt == nil ? "dumbbell.fill" : "timer")
                    .foregroundStyle(widgetAccent)
            }
            .widgetURL(URL(string: "vector://workout"))
        }
    }

    @ViewBuilder
    private func restOrElapsed(_ context: ActivityViewContext<WorkoutActivityAttributes>, large: Bool) -> some View {
        if let end = context.state.restEndsAt, end > Date() {
            Text(timerInterval: Date()...end, countsDown: true)
                .font(large ? .title2.weight(.bold) : .caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(widgetAccent)
                .frame(maxWidth: large ? nil : 44)
        } else {
            Text(context.attributes.startedAt, style: .timer)
                .font(large ? .title3.weight(.semibold) : .caption)
                .monospacedDigit()
                .frame(maxWidth: large ? nil : 52)
        }
    }
}

private struct LockScreenWorkoutView: View {
    var context: ActivityViewContext<WorkoutActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(context.attributes.workoutName.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(context.attributes.startedAt, style: .timer)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.exerciseName).font(.title3.weight(.bold)).foregroundStyle(.white)
                    Text(context.state.setLabel).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                if let end = context.state.restEndsAt, end > Date() {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("REST").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.6))
                        Text(timerInterval: Date()...end, countsDown: true)
                            .font(.title.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(widgetAccent)
                    }
                }
            }
            ProgressView(value: Double(context.state.completedSets), total: Double(max(context.state.totalSets, 1)))
                .tint(widgetAccent)
        }
    }
}
