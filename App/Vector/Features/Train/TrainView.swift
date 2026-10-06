import SwiftUI
import VectorCore

/// Train tab ("Fields"). A training field runs under the status bar with the
/// large title, the program menu and the next workout: its name at 34 pt,
/// the program line, every exercise with its sets and load, and the one
/// accent capsule ("Start Lower A"). Below it, on the open canvas: Routines
/// (swipe for "Start now", context menu for Edit / Duplicate), the last
/// three sessions, and a push row to the exercise library. No cards.
///
/// The screen is a plain `List` so routine rows get native swipe actions and
/// context menus; every row draws its own hairline so spacing and rules
/// match the canvas screens built on `ScrollView`.
struct TrainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var path = NavigationPath()
    @State private var editing: WorkoutTemplate?
    @State private var showsProgramBrowser = false
    @State private var showsProgramEditor = false

    /// Pushes that aren't model values.
    enum Route: Hashable {
        case history, library
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                TrainHero(path: $path,
                          onBrowsePrograms: { showsProgramBrowser = true },
                          onEditProgram: { showsProgramEditor = true },
                          onCreateWorkout: createWorkout)
                    .fieldRow(VColor.fieldTraining)

                routines
                history
                libraryRow
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            // The training field's colour behind the status bar and in the
            // top overscroll; rows below carry their own ground.
            .background {
                VStack(spacing: 0) {
                    VColor.fieldTraining.frame(height: 600)
                    VColor.ground
                }
                .ignoresSafeArea()
            }
            .toolbar(.hidden, for: .navigationBar)
            .animation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion), value: model.program?.nextIndex)
            .navigationDestination(for: WorkoutTemplate.self) { TemplateDetailView(template: $0) }
            .navigationDestination(for: WorkoutSession.self) { SessionDetailView(session: $0) }
            .navigationDestination(for: ExerciseRoute.self) { route in
                if let exercise = model.catalog[route.id] {
                    ExerciseDetailScreen(exercise: exercise)
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .history: WorkoutHistoryView()
                case .library: ExerciseLibraryView()
                }
            }
            .sheet(item: $editing) { TemplateEditorView(template: $0) }
            .sheet(isPresented: $showsProgramBrowser) { ProgramBrowserView() }
            .sheet(isPresented: $showsProgramEditor) { ProgramEditorView() }
        }
    }

    // MARK: Routines

    private var allRoutines: [WorkoutTemplate] {
        (model.program?.workouts ?? []) + model.customTemplates
    }

    @ViewBuilder private var routines: some View {
        let items = allRoutines
        CanvasSectionTitle("Routines", actionTitle: model.program == nil ? nil : "Edit") { showsProgramEditor = true }
            .padding(.horizontal, Space.fieldInset)
            .padding(.top, Space.md)
            .padding(.bottom, Space.xxs)
            .canvasRow()

        ForEach(Array(items.enumerated()), id: \.element.id) { index, template in
            RoutineRow(template: template, showsRule: index > 0,
                       open: { path.append(template) },
                       onEdit: { editing = template })
                .canvasRow()
        }

        CanvasTextAction(title: "New routine", symbol: Icon.add, action: createWorkout)
            .padding(.horizontal, Space.fieldInset)
            .overlay(alignment: .top) {
                if !items.isEmpty { Hairline().padding(.horizontal, Space.fieldInset) }
            }
            .padding(.bottom, Space.md)
            .canvasRow()
            .accessibilityHint(model.canCreateRoutine ? "Creates a routine" : "You've reached the free routine limit. Opens Vector Pro.")
    }

    // MARK: History

    @ViewBuilder private var history: some View {
        let recent = Array(model.sessions.prefix(3))
        CanvasSectionTitle("History", actionTitle: model.sessions.isEmpty && !model.hasHiddenHistory ? nil : "See all") {
            path.append(Route.history)
        }
        .padding(.horizontal, Space.fieldInset)
        .padding(.top, Space.md)
        .padding(.bottom, Space.xxs)
        .overlay(alignment: .top) { Hairline() }
        .canvasRow()

        if recent.isEmpty {
            Text("Finished workouts appear here with every set you logged.")
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.fieldInset)
                .padding(.bottom, Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .canvasRow()
        }

        ForEach(Array(recent.enumerated()), id: \.element.id) { index, session in
            Button {
                path.append(session)
            } label: {
                SessionRow(session: session, showsChevron: true)
                    .overlay(alignment: .top) { if index > 0 { Hairline() } }
                    .padding(.horizontal, Space.fieldInset)
            }
            .padding(.bottom, index == recent.count - 1 ? Space.md : 0)
            .canvasRow()
        }
    }

    // MARK: Library

    private var libraryRow: some View {
        Button {
            path.append(Route.library)
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: "book")
                    .font(.system(.body))
                    .foregroundStyle(VColor.textSecondary)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                CanvasRow(title: "Exercise library", subtitle: "Search by name, muscle or equipment", showsChevron: true)
            }
            .padding(.horizontal, Space.fieldInset)
            .padding(.vertical, Space.xs)
        }
        .overlay(alignment: .top) { Hairline() }
        .padding(.bottom, Space.xl)
        .canvasRow()
    }

    private func createWorkout() {
        guard model.canCreateRoutine else {
            model.presentPaywall(.routineLimit)
            return
        }
        editing = WorkoutTemplate(name: "New Workout", exercises: [])
    }
}

// MARK: - Hero field

/// The training field at the top of Train: large title and program menu,
/// then the next workout (or the workout in progress, or a program prompt).
private struct TrainHero: View {
    @Binding var path: NavigationPath
    var onBrowsePrograms: () -> Void
    var onEditProgram: () -> Void
    var onCreateWorkout: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CanvasLargeTitle("Train") { menu }
            Group {
                if let workout = model.activeWorkout {
                    inProgress(workout)
                } else if let next = model.nextWorkout {
                    upNext(next)
                } else {
                    noProgram
                }
            }
            .padding(.top, Space.md)
        }
        .padding(.horizontal, Space.fieldInset)
        .padding(.top, Space.xxs)
        .padding(.bottom, Space.fieldVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var menu: some View {
        Menu {
            Button("Browse programs", systemImage: "square.grid.2x2", action: onBrowsePrograms)
            Button("Edit program", systemImage: "slider.horizontal.3", action: onEditProgram)
                .disabled(model.program == nil)
            Divider()
            Button("New routine", systemImage: "plus", action: onCreateWorkout)
            Button("Empty workout", systemImage: "bolt") { model.startEmptyWorkout() }
            Button("Workout history", systemImage: "clock.arrow.circlepath") { path.append(TrainView.Route.history) }
        } label: {
            CanvasMoreMenuLabel()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Program options")
    }

    private func category(_ title: String) -> some View {
        Label(title, systemImage: Icon.train)
            .font(VFont.secondaryEmphasized)
            .foregroundStyle(VColor.inkTraining)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Next workout

    private func upNext(_ template: WorkoutTemplate) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            category("Next workout")
            Text(template.name)
                .font(VFont.largeTitle)
                .foregroundStyle(VColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Text(programLine(template))
                .font(VFont.secondary.monospacedDigit())
                .foregroundStyle(VColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            VStack(spacing: 0) {
                ForEach(Array(template.exercises.enumerated()), id: \.element.id) { index, item in
                    exerciseRow(item, index: index)
                        .overlay(alignment: .top) {
                            // Inset to the text edge, past the thumbnail.
                            if index > 0 { Hairline(leading: ExerciseThumbnail.rowSize + Space.sm) }
                        }
                }
            }
            .padding(.top, Space.sm)

            Button {
                model.startWorkout(template)
            } label: {
                Label("Start \(template.name)", systemImage: "play.fill")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .buttonStyle(.accentCapsule)
            .padding(.top, 18)
        }
    }

    /// "Upper / Lower, 4 days a week · ~41 min"
    private func programLine(_ template: WorkoutTemplate) -> String {
        var parts: [String] = []
        if let program = model.program, let name = model.programShortName {
            parts.append("\(name), \(program.daysPerWeek) days a week")
        }
        parts.append("~\(template.estimatedMinutes(catalog: model.catalog)) min")
        return parts.joined(separator: " · ")
    }

    private func exerciseRow(_ item: ExercisePrescription, index: Int) -> some View {
        let exercise = model.catalog[item.exerciseID]
        let name = exercise?.name ?? item.exerciseID
        let muscles = exercise?.primaryMuscles.map(\.displayName).joined(separator: ", ")
        let load = loadCaption(item, index: index, exercise: exercise)
        return Button {
            path.append(ExerciseRoute(id: item.exerciseID))
        } label: {
            HStack(spacing: Space.sm) {
                if let exercise {
                    ExerciseThumbnail(exercise: exercise, size: ExerciseThumbnail.rowSize)
                } else {
                    ExerciseThumbnailPlaceholder(size: ExerciseThumbnail.rowSize)
                }
                CanvasRow(title: name, subtitle: muscles, value: "\(item.sets) × \(item.repRange.label)",
                          valueCaption: load?.text, minHeight: 50)
            }
            .padding(.vertical, Space.xxs)
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue("\(item.sets) sets of \(item.repRange.label) reps" + (load.map { ", \($0.spoken)" } ?? ""))
        .accessibilityHint("Shows the exercise")
        .accessibilityAddTraits(.isButton)
    }

    /// The load under "3 × 8": the recommended or chosen weight, last
    /// session's weight on the free tier (labelled as such), or bodyweight.
    private func loadCaption(_ item: ExercisePrescription, index: Int, exercise: Exercise?) -> (text: String, spoken: String)? {
        if let load = model.plannedLoad(for: item, at: index) {
            let weight = Format.weight(load.weight, unit: model.unit)
            switch load.source {
            case .chosen: return (weight, "your target \(weight)")
            case .recommended: return (weight, "recommended \(weight)")
            case .lastSession: return ("Last \(weight)", "last time \(weight)")
            }
        }
        if exercise?.equipment == .bodyweight { return ("Bodyweight", "bodyweight") }
        return nil
    }

    // MARK: In progress

    private func inProgress(_ workout: ActiveWorkout) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            category("Workout in progress")
            Text(workout.session.name)
                .font(VFont.largeTitle)
                .foregroundStyle(VColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Text("\(workout.completedSets) of \(workout.totalSets) sets done")
                .font(VFont.secondary.monospacedDigit())
                .foregroundStyle(VColor.textSecondary)
                .padding(.top, 2)
            LinearProgress(progress: workout.progress, tint: VColor.accent, height: 5)
                .padding(.top, Space.sm)
            Button {
                model.resumeWorkout()
            } label: {
                Label("Resume workout", systemImage: "play.fill")
            }
            .buttonStyle(.accentCapsule)
            .padding(.top, 18)
        }
    }

    // MARK: No program

    private var noProgram: some View {
        VStack(alignment: .leading, spacing: 0) {
            category("Program")
            Text("Pick a program")
                .font(VFont.largeTitle)
                .foregroundStyle(VColor.textPrimary)
                .padding(.top, 6)
            Text("Programs are matched to your goal and equipment. Or build your own routine.")
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            Button(action: onBrowsePrograms) {
                Label("Browse programs", systemImage: "square.grid.2x2")
            }
            .buttonStyle(.accentCapsule)
            .padding(.top, 18)
            AdaptiveStack(spacing: Space.xs) {
                Button("Build your own", action: onCreateWorkout)
                    .buttonStyle(.quietCapsule)
                Button("Empty workout") { model.startEmptyWorkout() }
                    .buttonStyle(.quietCapsule)
            }
            .padding(.top, Space.xs)
        }
    }
}

// MARK: - Routine row

/// One routine on the canvas: name, "6 exercises · ~41 min", then "Next" or
/// the last date it was trained. Swipe for "Start now"; long-press for
/// Start, Make next, Edit, Duplicate and Delete.
struct RoutineRow: View {
    var template: WorkoutTemplate
    var showsRule: Bool
    var open: () -> Void
    var onEdit: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: open) {
            CanvasRow(title: template.name,
                      subtitle: "\(template.exercises.count) exercises · ~\(template.estimatedMinutes(catalog: model.catalog)) min",
                      detail: trailing, showsChevron: true)
                .overlay(alignment: .top) { if showsRule { Hairline() } }
                .padding(.horizontal, Space.fieldInset)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                model.startWorkout(template)
            } label: {
                Label("Start now", systemImage: "play.fill")
            }
            .tint(VColor.accent)
        }
        .contextMenu {
            Button("Start workout", systemImage: "play.fill") { model.startWorkout(template) }
            if model.isProgramTemplate(template), model.nextWorkout?.id != template.id {
                Button("Make next", systemImage: "arrow.uturn.up") {
                    withAnimation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion)) { model.makeNext(template) }
                }
            }
            Button("Edit", systemImage: "pencil", action: onEdit)
            Button("Duplicate", systemImage: "plus.square.on.square") { model.duplicate(template) }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                withAnimation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion)) { model.deleteTemplate(template) }
            }
        }
    }

    private var trailing: String? {
        if model.nextWorkout?.id == template.id { return "Next" }
        return model.lastSession(for: template).map { Format.shortDate($0.startedAt, calendar: model.calendar) }
    }
}

// MARK: - List row helpers

private extension View {
    /// A full-bleed row on the plain ground: no insets, no system separator.
    func canvasRow() -> some View {
        fieldRow(VColor.ground)
    }

    /// A full-bleed row with its own background (a field or the ground).
    func fieldRow(_ background: Color) -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(background)
    }
}

#Preview("Train") {
    TrainView().environment(AppModel.preview())
}

#Preview("Train · Dark · Pro") {
    TrainView().environment(AppModel.preview(pro: true)).preferredColorScheme(.dark)
}

#Preview("Train · Empty") {
    TrainView().environment(AppModel.preview(empty: true))
}
