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
                Button {
                    model.presentPaywall(.history)
                } label: {
                    Label("Older workouts are kept safely. Pro shows your full history.", systemImage: Icon.lock)
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.accentText)
                        .frame(maxWidth: .infinity, minHeight: Size.minTouch, alignment: .leading)
                }
                .listRowBackground(VColor.ground)
                .listRowSeparator(.hidden)
            }
            ForEach(months, id: \.month) { group in
                Section {
                    ForEach(group.sessions) { session in
                        NavigationLink(value: session) { SessionRow(session: session) }
                            .listRowBackground(VColor.ground)
                            .listRowSeparatorTint(VColor.separator)
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = session }
                            }
                    }
                } header: {
                    Text(group.month.formatted(.dateTime.month(.wide).year()))
                        .font(VFont.title3.weight(.bold))
                        .foregroundStyle(VColor.textPrimary)
                        .textCase(nil)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .screenBackground()
        .overlay {
            if model.sessions.isEmpty && !model.hasHiddenHistory {
                ContentUnavailableView("No Workouts Yet", systemImage: Icon.train,
                                       description: Text("Finished workouts appear here with every set you logged."))
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog("Delete this workout?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { session in
            Button("Delete Workout", role: .destructive) { model.deleteSession(session) }
        } message: { _ in
            Text("Its sets will no longer count toward your progress and records.")
        }
    }
}

/// One finished workout as a canvas row: name, "Sat 3 Oct · 54 min", then
/// the session volume in bold tabular figures.
struct SessionRow: View {
    var session: WorkoutSession
    var showsChevron = false
    @Environment(AppModel.self) private var model

    var body: some View {
        let stats = SessionStats(session: session)
        CanvasRow(title: session.name,
                  subtitle: stats.dateLine,
                  value: Format.volume(session.volume, unit: model.unit),
                  valueCaption: "\(stats.workingSets) sets",
                  showsChevron: showsChevron)
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

    /// "Sat 3 Oct · 54 min"
    var dateLine: String {
        let date = session.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return session.endedAt == nil ? date : "\(date) · \(Format.duration(session.duration))"
    }
}

/// One finished workout: a training field with the name, date and a stat
/// line, then records set that day and every exercise as logged, as canvas
/// sections separated by hairlines.
struct SessionDetailView: View {
    var session: WorkoutSession
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDelete = false

    var body: some View {
        let earlier = model.sessions.filter { $0.startedAt < session.startedAt }
        let records = model.analytics.personalRecords(for: session, history: earlier)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                if !records.isEmpty {
                    CanvasSection(records.count == 1 ? "Personal record" : "\(records.count) personal records", showsTopRule: false) {
                        VStack(spacing: 0) {
                            ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                                HStack(spacing: Space.sm) {
                                    Image(systemName: Icon.trophy)
                                        .foregroundStyle(VColor.accentText)
                                        .accessibilityHidden(true)
                                    CanvasRow(title: record.exerciseName,
                                              value: "\(Format.weight(record.weight, unit: model.unit)) × \(record.reps)")
                                }
                                .overlay(alignment: .top) { if index > 0 { Hairline() } }
                            }
                        }
                    }
                }
                ForEach(Array(session.exercises.enumerated()), id: \.element.id) { index, log in
                    ExerciseLogSummary(log: log, isPR: records.contains { $0.exerciseID == log.exerciseID },
                                       showsTopRule: index > 0 || !records.isEmpty)
                }
            }
            .padding(.bottom, Space.xl)
        }
        .screenBackground()
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
        .fieldTitleInBody()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Delete Workout", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                } label: {
                    CanvasMoreMenuLabel()
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

    private var hero: some View {
        let stats = SessionStats(session: session)
        var line: [CanvasStatLine.Stat] = []
        if session.endedAt != nil { line.append(.init(value: Format.duration(session.duration), label: "")) }
        line.append(.init(value: "\(stats.workingSets)", label: stats.workingSets == 1 ? "set" : "sets"))
        line.append(.init(value: Format.volume(session.volume, unit: model.unit, includeUnit: false), label: model.unit.symbol))
        return VStack(alignment: .leading, spacing: 0) {
            Label(session.startedAt.formatted(date: .complete, time: .shortened), systemImage: Icon.train)
                .font(VFont.secondaryEmphasized)
                .foregroundStyle(VColor.inkTraining)
                .fixedSize(horizontal: false, vertical: true)
            Text(session.name)
                .font(VFont.largeTitle)
                .foregroundStyle(VColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 6)
            CanvasStatLine(stats: line)
                .padding(.top, Space.sm)
        }
        .padding(.horizontal, Space.fieldInset)
        .padding(.top, Space.xs)
        .padding(.bottom, Space.fieldVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fieldHeroBackground(VColor.fieldTraining)
    }
}

/// One exercise as logged: name (opens the exercise), note, every set as a
/// hairline row with its RPE, and the session's estimated max.
private struct ExerciseLogSummary: View {
    var log: ExerciseLog
    var isPR: Bool
    var showsTopRule: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        CanvasSection(showsTopRule: showsTopRule) {
            HStack(alignment: .center, spacing: Space.xs) {
                Button {
                    model.sheet = .exercise(log.exerciseID)
                } label: {
                    Text(model.catalog[log.exerciseID]?.name ?? "Exercise")
                        .font(VFont.title3.weight(.bold))
                        .foregroundStyle(VColor.textPrimary)
                        .multilineTextAlignment(.leading)
                        .frame(minHeight: Size.minTouch, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHint("Shows the exercise")
                if log.supersetGroup != nil {
                    Image(systemName: "link").foregroundStyle(VColor.accentText).accessibilityLabel("Superset")
                }
                Spacer(minLength: Space.xs)
                if isPR { PRBadge() }
            }
            if !log.note.isEmpty {
                Text(log.note)
                    .font(VFont.secondary)
                    .foregroundStyle(VColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(Array(log.sets.enumerated()), id: \.element.id) { index, set in
                    HStack(spacing: Space.sm) {
                        Text(label(set, index: index))
                            .font(VFont.secondaryEmphasized.monospacedDigit())
                            .foregroundStyle(set.kind == .warmup ? VColor.warning : VColor.textSecondary)
                            .frame(minWidth: 28, alignment: .leading)
                            .accessibilityLabel(set.kind == .warmup ? "Warm-up" : "Set \(label(set, index: index))")
                        Text(set.weight > 0 ? "\(Format.weight(set.weight, unit: model.unit)) × \(set.reps)" : "\(set.reps) reps")
                            .font(VFont.data)
                            .foregroundStyle(VColor.textPrimary)
                        Spacer(minLength: Space.xs)
                        if let rpe = set.rpe {
                            Text("RPE \(Format.rpe(rpe))")
                                .font(VFont.fieldCaption.monospacedDigit())
                                .foregroundStyle(VColor.textSecondary)
                        }
                    }
                    .frame(minHeight: Size.minTouch)
                    .overlay(alignment: .top) { if index > 0 { Hairline() } }
                    .accessibilityElement(children: .combine)
                }
            }
            if log.bestEstimatedOneRepMax > 0 {
                Text("Estimated max \(Format.estimate(log.bestEstimatedOneRepMax, unit: model.unit)). An estimate, not a tested lift.")
                    .font(VFont.fieldCaption)
                    .foregroundStyle(VColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.xxs)
            }
        }
    }

    private func label(_ set: SetLog, index: Int) -> String {
        if let badge = set.kind.badge { return badge }
        return "\(log.sets.prefix(index + 1).filter { $0.kind == .working || $0.kind == .failure }.count)"
    }
}
