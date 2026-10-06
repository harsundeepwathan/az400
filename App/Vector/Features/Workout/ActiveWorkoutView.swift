import SwiftUI
import VectorCore

/// Field focus inside the set table. Drives the keyboard toolbar.
enum SetField: Hashable {
    case weight(SetPosition)
    case reps(SetPosition)

    var position: SetPosition {
        switch self {
        case .weight(let position), .reps(let position): position
        }
    }
}

/// The gym-floor screen. Design priorities, in order: one-tap set
/// completion, large targets, zero modal interruptions (no paywalls, no
/// confirmations except finishing), and state that survives anything.
struct ActiveWorkoutView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var model
    @FocusState private var focusedField: SetField?
    @State private var detailExercise: ExerciseDetailContext?
    @State private var showsAddExercise = false
    @State private var showsFinishDialog = false
    @State private var restEditorIndex: Int?
    @State private var prPositions: Set<SetPosition> = []

    var body: some View {
        @Bindable var model = model
        if let workout = model.activeWorkout {
            NavigationStack {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: Space.md) {
                            WorkoutHeader(workout: workout)
                            ForEach(Array(workout.session.exercises.enumerated()), id: \.element.id) { index, log in
                                ExerciseLogCard(
                                    index: index,
                                    log: log,
                                    workout: workout,
                                    focusedField: $focusedField,
                                    prPositions: prPositions,
                                    onShowDetail: { detailExercise = ExerciseDetailContext(exerciseID: log.exerciseID, index: index) },
                                    onEditRest: { restEditorIndex = index }
                                )
                                .id(log.id)
                            }
                            addExerciseButton
                        }
                        .padding(.horizontal, Space.gutter)
                        .padding(.bottom, Space.xxl)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: model.lastCompletion) { _, completion in
                        guard let completion else { return }
                        if completion.isPersonalRecord { prPositions.insert(completion.position) }
                        guard let next = completion.nextFocus, workout.session.exercises.indices.contains(next.exercise) else { return }
                        if next.exercise != completion.position.exercise {
                            withAnimation(Motion.smooth) {
                                proxy.scrollTo(workout.session.exercises[next.exercise].id, anchor: .top)
                            }
                        }
                    }
                }
                .screenBackground()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if model.restTimer != nil {
                        RestTimerBar()
                            .padding(.horizontal, Space.gutter)
                            .padding(.bottom, Space.xs)
                            .transition(Motion.slide(.bottom, reduceMotion: reduceMotion))
                    }
                }
                .animation(Motion.smooth, value: model.restTimer)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar(workout) }
                .overlay(alignment: .top) { ToastHost(toast: $model.toast) }
                .sheet(item: $detailExercise) { context in
                    if let exercise = model.catalog[context.exerciseID] {
                        ExerciseDetailView(exercise: exercise, workoutIndex: context.index)
                    }
                }
                .sheet(isPresented: $showsAddExercise) {
                    ExercisePickerView(excluded: Set(workout.session.exercises.map(\.exerciseID))) { model.addExercise($0) }
                }
                .sheet(item: Binding(get: { restEditorIndex.map(RestEditorContext.init) }, set: { restEditorIndex = $0?.index })) { context in
                    RestDurationPicker(index: context.index)
                        .presentationDetents([.height(320)])
                }
                .confirmationDialog(finishTitle(workout), isPresented: $showsFinishDialog, titleVisibility: .visible) {
                    if workout.completedSets > 0 {
                        Button("Finish Workout") { model.finishWorkout() }
                    }
                    Button("Discard Workout", role: .destructive) { model.discardWorkout() }
                    Button("Keep Training", role: .cancel) {}
                } message: {
                    Text(finishMessage(workout))
                }
            }
            .interactiveDismissDisabled()
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ workout: ActiveWorkout) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                model.minimizeWorkout()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(.body, weight: .semibold))
                    .frame(width: Size.minTouch, height: Size.minTouch)
            }
            .accessibilityLabel("Minimize workout")
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(workout.session.name).font(VFont.headline).foregroundStyle(VColor.textPrimary)
                if !workout.session.exercises.isEmpty {
                    Text("Exercise \(min(workout.currentExerciseIndex + 1, workout.session.exercises.count)) of \(workout.session.exercises.count)")
                        .font(VFont.caption)
                        .foregroundStyle(VColor.textSecondary)
                        .contentTransition(.numericText())
                }
            }
            .accessibilityElement(children: .combine)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Finish") {
                focusedField = nil
                if workout.isComplete {
                    model.finishWorkout()
                } else {
                    showsFinishDialog = true
                }
            }
            .font(VFont.bodyEmphasized)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(workout.isComplete ? VColor.success : VColor.accent)
        }
        ToolbarItemGroup(placement: .keyboard) {
            KeyboardStepper(field: focusedField, workout: workout)
            Spacer()
            Button(nextFieldTitle) { advanceFocus(in: workout) }
                .font(VFont.bodyEmphasized)
        }
    }

    private var nextFieldTitle: String {
        if case .reps = focusedField { return "Done" }
        return "Next"
    }

    private func advanceFocus(in workout: ActiveWorkout) {
        switch focusedField {
        case .weight(let position): focusedField = .reps(position)
        default: focusedField = nil
        }
    }

    private var addExerciseButton: some View {
        Button {
            showsAddExercise = true
        } label: {
            Label("Add Exercise", systemImage: "plus")
        }
        .buttonStyle(.secondary)
        .padding(.top, Space.xs)
    }

    private func finishTitle(_ workout: ActiveWorkout) -> String {
        workout.completedSets == 0 ? "Discard this workout?" : "Finish workout?"
    }

    private func finishMessage(_ workout: ActiveWorkout) -> String {
        let remaining = workout.totalSets - workout.completedSets
        if workout.completedSets == 0 { return "No sets have been completed yet." }
        return "\(remaining) unfinished \(remaining == 1 ? "set" : "sets") won't be saved."
    }
}

struct ExerciseDetailContext: Identifiable {
    var exerciseID: String
    var index: Int?
    var id: String { "\(exerciseID)-\(index ?? -1)" }
}

private struct RestEditorContext: Identifiable {
    var index: Int
    var id: Int { index }
}

/// Elapsed clock and progress, pinned at the top of the session.
private struct WorkoutHeader: View {
    var workout: ActiveWorkout

    var body: some View {
        VStack(spacing: Space.sm) {
            TimelineView(.periodic(from: workout.session.startedAt, by: 1)) { context in
                Text(Format.clock(context.date.timeIntervalSince(workout.session.startedAt), alwaysShowHours: true))
                    .font(VFont.metricHero)
                    .foregroundStyle(VColor.textPrimary)
                    .accessibilityLabel("Elapsed time \(Format.duration(context.date.timeIntervalSince(workout.session.startedAt)))")
            }
            HStack(spacing: Space.sm) {
                LinearProgress(progress: workout.progress, tint: workout.isComplete ? VColor.success : VColor.accent, height: 6)
                Text("\(workout.completedSets)/\(workout.totalSets)")
                    .font(VFont.captionEmphasized.monospacedDigit())
                    .foregroundStyle(VColor.textSecondary)
                    .contentTransition(.numericText())
            }
            HStack {
                Label(Format.volume(workout.session.exercises.reduce(0) { $0 + $1.volume }), systemImage: "scalemass")
                Spacer()
                Label("\(workout.completedSets) sets", systemImage: Icon.check)
            }
            .font(VFont.caption.monospacedDigit())
            .foregroundStyle(VColor.textSecondary)
        }
        .padding(.top, Space.xs)
        .padding(.bottom, Space.xxs)
    }
}

/// −/+ buttons in the keyboard toolbar. Weight steps by the exercise's
/// plate increment; reps step by one.
private struct KeyboardStepper: View {
    var field: SetField?
    var workout: ActiveWorkout
    @Environment(AppModel.self) private var model

    var body: some View {
        if let field, let set = set(at: field.position) {
            HStack(spacing: Space.xs) {
                Button { step(field, set: set, direction: -1) } label: { Image(systemName: "minus").frame(width: Size.minTouch, height: 36) }
                    .accessibilityLabel("Decrease")
                Button { step(field, set: set, direction: 1) } label: { Image(systemName: "plus").frame(width: Size.minTouch, height: 36) }
                    .accessibilityLabel("Increase")
                Text(label(field))
                    .font(VFont.caption)
                    .foregroundStyle(VColor.textSecondary)
            }
            .buttonStyle(.bordered)
        }
    }

    private func set(at position: SetPosition) -> SetLog? {
        workout.session.exercises[safe: position.exercise]?.sets[safe: position.set]
    }

    private func increment(_ position: SetPosition) -> Double {
        let id = workout.session.exercises[position.exercise].exerciseID
        let step = model.catalog[id]?.loadIncrement ?? 2.5
        return step > 0 ? step : 2.5
    }

    private func label(_ field: SetField) -> String {
        switch field {
        case .weight(let position): "±\(Format.weight(increment(position), unit: model.unit))"
        case .reps: "±1 rep"
        }
    }

    private func step(_ field: SetField, set: SetLog, direction: Double) {
        switch field {
        case .weight(let position):
            let value = set.weight + direction * increment(position)
            model.updateWorkout { $0.setWeight(max(value, 0), at: position) }
        case .reps(let position):
            model.updateWorkout { $0.setReps(max(set.reps + Int(direction), 0), at: position) }
        }
        Haptics.light()
    }
}

private struct RestDurationPicker: View {
    var index: Int
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var custom: Int?
    private static let presets = [30, 60, 90, 120, 180]

    var body: some View {
        let log = model.activeWorkout?.session.exercises[safe: index]
        let current = log?.restSeconds ?? 90
        let name = log.flatMap { model.catalog[$0.exerciseID]?.name } ?? "this exercise"
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.xs) {
                    ForEach(Self.presets, id: \.self) { seconds in
                        Button {
                            choose(seconds)
                        } label: {
                            Text(Format.clock(TimeInterval(seconds)))
                                .font(VFont.bodyEmphasized.monospacedDigit())
                                .foregroundStyle(seconds == current ? VColor.textOnAccent : VColor.textPrimary)
                                .frame(maxWidth: .infinity, minHeight: Size.buttonHeight)
                                .background(seconds == current ? VColor.accent : VColor.surfaceSunken,
                                            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel(Format.duration(TimeInterval(seconds)))
                        .accessibilityAddTraits(seconds == current ? .isSelected : [])
                    }
                }
                HStack {
                    Text("Custom").font(VFont.body).foregroundStyle(VColor.textPrimary)
                    Spacer()
                    Stepper(value: Binding(get: { custom ?? current }, set: { custom = $0 }), in: 0...600, step: 15) {
                        Text(Format.clock(TimeInterval(custom ?? current)))
                            .font(VFont.bodyEmphasized.monospacedDigit())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .fixedSize()
                }
                .padding(.horizontal, Space.md)
                .frame(minHeight: Size.buttonHeight)
                .background(VColor.surface, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                Text("Remembered for \(name). Rest starts automatically after each working set, not after warm-ups.")
                    .font(VFont.caption)
                    .foregroundStyle(VColor.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(Space.gutter)
            .navigationTitle("Rest Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let custom { choose(custom) } else { dismiss() }
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: custom)
    }

    private func choose(_ seconds: Int) {
        model.setRest(seconds, forExercise: index)
        dismiss()
    }
}

#Preview {
    let model = AppModel.preview()
    model.startWorkout(model.nextWorkout!)
    return ActiveWorkoutView().environment(model)
}
