import SwiftUI
import VectorCore

/// Every finished workout, newest first, grouped by month.
struct WorkoutHistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDelete: WorkoutSession?

    private var months: [(month: Date, sessions: [WorkoutSession])] {
        let grouped = Dictionary(grouping: model.sessions) { session in
            model.calendar.dateInterval(of: .month, for: session.startedAt)?.start ?? session.startedAt
        }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        List {
            if model.hasHiddenHistory {
                Section {
                    Button {
                        model.presentPaywall(.history)
                    } label: {
                        Label("Older workouts are kept safely. Pro shows your full history.", systemImage: Icon.lock)
                            .font(VFont.secondary)
                    }
                }
            }
            ForEach(months, id: \.month) { group in
                Section(group.month.formatted(.dateTime.month(.wide).year())) {
                    ForEach(group.sessions) { session in
                        NavigationLink(value: session) { SessionRow(session: session) }
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = session }
                            }
                    }
                }
            }
        }
        .overlay {
            if model.sessions.isEmpty {
                ContentUnavailableView("No Workouts Yet", systemImage: "dumbbell",
                                       description: Text("Finished workouts appear here with every set you logged."))
            }
        }
        .navigationTitle("History")
        .confirmationDialog("Delete this workout?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { session in
            Button("Delete Workout", role: .destructive) { model.deleteSession(session) }
        } message: { _ in
            Text("Its sets will no longer count toward your progress and records.")
        }
    }
}

struct SessionRow: View {
    var session: WorkoutSession
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(session.name).font(VFont.bodyEmphasized).foregroundStyle(VColor.textPrimary)
                Spacer()
                Text(session.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .font(VFont.secondary)
                    .foregroundStyle(VColor.textSecondary)
            }
            Text(SessionStats(session: session).line(unit: model.unit))
                .font(VFont.secondary.monospacedDigit())
                .foregroundStyle(VColor.textSecondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// "52 min · 18 sets · 8,450 kg"
struct SessionStats {
    var session: WorkoutSession

    var workingSets: Int { session.exercises.reduce(0) { $0 + $1.completedWorkingSets.count } }

    func line(unit: WeightUnit) -> String {
        var parts = ["\(workingSets) sets", Format.volume(session.volume, unit: unit)]
        if session.endedAt != nil { parts.insert(Format.duration(session.duration), at: 0) }
        return parts.joined(separator: " · ")
    }
}

/// One finished workout: every set as logged, records set that day, notes.
struct SessionDetailView: View {
    var session: WorkoutSession
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDelete = false

    var body: some View {
        let earlier = model.sessions.filter { $0.startedAt < session.startedAt }
        let records = model.analytics.personalRecords(for: session, history: earlier)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    if session.endedAt != nil {
                        MetricTile(title: "Duration", value: Format.duration(session.duration))
                    }
                    MetricTile(title: "Sets", value: "\(SessionStats(session: session).workingSets)")
                    MetricTile(title: "Volume", value: Format.volume(session.volume, unit: model.unit))
                }
                if !records.isEmpty {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Label("\(records.count) personal \(records.count == 1 ? "record" : "records")", systemImage: Icon.trophy)
                            .font(VFont.headline)
                            .foregroundStyle(VColor.textPrimary)
                        ForEach(records) { record in
                            Text("\(record.exerciseName): \(Format.weight(record.weight, unit: model.unit)) × \(record.reps)")
                                .font(VFont.secondary.monospacedDigit())
                                .foregroundStyle(VColor.textSecondary)
                        }
                    }
                    .card()
                }
                ForEach(session.exercises) { log in
                    ExerciseLogSummary(log: log, isPR: records.contains { $0.exerciseID == log.exerciseID })
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.bottom, Space.xl)
        }
        .screenBackground()
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(session.name).font(VFont.headline)
                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(VFont.caption)
                        .foregroundStyle(VColor.textSecondary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Delete Workout", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: Size.minTouch, height: Size.minTouch)
                }
                .accessibilityLabel("Workout options")
            }
        }
        .confirmationDialog("Delete this workout?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete Workout", role: .destructive) {
                model.deleteSession(session)
                dismiss()
            }
        } message: {
            Text("Its sets will no longer count toward your progress and records.")
        }
    }
}

private struct MetricTile: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(VFont.sectionHeading).tracking(0.4).foregroundStyle(VColor.textSecondary)
            Text(value).font(VFont.metricSmall).foregroundStyle(VColor.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Space.sm)
        .accessibilityElement(children: .combine)
    }
}

private struct ExerciseLogSummary: View {
    var log: ExerciseLog
    var isPR: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Button {
                    model.sheet = .exercise(log.exerciseID)
                } label: {
                    Text(model.catalog[log.exerciseID]?.name ?? "Exercise")
                        .font(VFont.title3)
                        .foregroundStyle(VColor.textPrimary)
                }
                .buttonStyle(.plain)
                if log.supersetGroup != nil {
                    Image(systemName: "link").foregroundStyle(VColor.accentText).accessibilityLabel("Superset")
                }
                Spacer()
                if isPR { PRBadge() }
            }
            if !log.note.isEmpty {
                Text(log.note).font(VFont.secondary).foregroundStyle(VColor.textSecondary)
            }
            ForEach(Array(log.sets.enumerated()), id: \.element.id) { index, set in
                HStack {
                    Text(label(set, index: index))
                        .font(VFont.secondaryEmphasized.monospacedDigit())
                        .foregroundStyle(set.kind == .warmup ? VColor.warning : VColor.textSecondary)
                        .frame(width: 28, alignment: .leading)
                    Text(set.weight > 0 ? "\(Format.weight(set.weight, unit: model.unit)) × \(set.reps)" : "\(set.reps) reps")
                        .font(VFont.data)
                        .foregroundStyle(VColor.textPrimary)
                    Spacer()
                    if let rpe = set.rpe {
                        Text("RPE \(Format.rpe(rpe))").font(VFont.caption).foregroundStyle(VColor.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if log.bestEstimatedOneRepMax > 0 {
                Text("Best estimated 1RM \(Format.estimate(log.bestEstimatedOneRepMax, unit: model.unit))")
                    .font(VFont.caption)
                    .foregroundStyle(VColor.textTertiary)
            }
        }
        .card()
    }

    private func label(_ set: SetLog, index: Int) -> String {
        if let badge = set.kind.badge { return badge }
        return "\(log.sets.prefix(index + 1).filter { $0.kind == .working || $0.kind == .failure }.count)"
    }
}
