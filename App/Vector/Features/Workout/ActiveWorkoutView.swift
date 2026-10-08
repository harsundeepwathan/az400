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
///
/// Layout (Fields): a pinned training-green nav row (collapse, title and
/// elapsed time, Finish), then the exercises in order. The current exercise
/// opens with the training field holding its name, target and the rest
/// ring; the set tables sit on the ground with hairlines.
struct ActiveWorkoutView: View {
    /// Coordinate space of the scroll view, used to tell whether the header ring is on screen.
    static let scrollSpace = "activeWorkoutScroll"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var model
    @FocusState private var focusedField: SetField?
    @State private var detailExercise: ExerciseDetailContext?
    @State private var showsAddExercise = false
    @State private var showsFinishDialog = false
    @State private var restEditorIndex: Int?
    @State private var prPositions: Set<SetPosition> = []
    @State private var ringVisible = true

    /// The compact bar takes over only when the header ring is scrolled away.
    private var showsRestBar: Bool { model.restTimer != nil && !ringVisible }

    var body: some View {
        @Bindable var model = model
        if let workout = model.activeWorkout {
            NavigationStack {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if workout.session.exercises.isEmpty {
                                emptyState
                            }
                            ForEach(Array(workout.session.exercises.enumerated()), id: \.element.id) { index, log in
                                let isCurrent = index == workout.currentExerciseIndex
                                ExerciseLogCard(
                                    index: index,
                                    log: log,
                                    workout: workout,
                                    isCurrent: isCurrent,
                                    focusedField: $focusedField,
                                    prPositions: prPositions,
                                    onShowDetail: { detailExercise = ExerciseDetailContext(exerciseID: log.exerciseID, index: index) },
                                    onEditRest: { restEditorIndex = index },
                                    onRingVisibilityChange: updateRingVisibility
                                )
                                .id(log.id)
                            }
                            if !workout.session.exercises.isEmpty {
                                addExerciseButton
                            }
                        }
                        .padding(.top, Space.xs)
                        .padding(.bottom, Space.xxl)
                    }
                    .coordinateSpace(name: Self.scrollSpace)
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: model.lastCompletion) { _, completion in
                        guard let completion else { return }
                        if completion.isPersonalRecord { prPositions.insert(completion.position) }
                        guard let next = completion.nextFocus, workout.session.exercises.indices.contains(next.exercise) else { return }
                        if next.exercise != completion.position.exercise {
                            withAnimation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion)) {
                                proxy.scrollTo(workout.session.exercises[next.exercise].id, anchor: .top)
                            }
                        }
                    }
                }
                .background(WColor.canvas.ignoresSafeArea())
                // Under the nav row, over the content: the record toast never covers the clock.
                .overlay(alignment: .top) { WorkoutToastHost(toast: $model.toast) }
                .safeAreaInset(edge: .top, spacing: 0) { navRow(workout) }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if showsRestBar {
                        RestTimerBar()
                            .transition(Motion.slide(.bottom, reduceMotion: reduceMotion))
                    }
                }
                .animation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion), value: showsRestBar)
                .toolbar(.hidden, for: .navigationBar)
                .toolbar { keyboardToolbar(workout) }
                .task(id: model.restTimer) {
                    // Fires the foreground "rest over" haptic exactly at the end date,
                    // wherever the countdown is being shown.
                    guard let timer = model.restTimer else { return }
                    let delay = timer.remaining(at: model.now())
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    guard !Task.isCancelled else { return }
                    model.restDidFinish()
                }
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

    /// Only the current exercise's header reports; a stale report from the
    /// previous current exercise (e.g. its onDisappear) is ignored.
    private func updateRingVisibility(_ index: Int, _ visible: Bool) {
        guard model.activeWorkout?.currentExerciseIndex == index, ringVisible != visible else { return }
        ringVisible = visible
    }

    // MARK: Nav row

    /// Custom nav row on the training field: collapse, title over elapsed
    /// time, and Finish, which fills in once every set is done.
    private func navRow(_ workout: ActiveWorkout) -> some View {
        ZStack {
            TimelineView(.periodic(from: workout.session.startedAt, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(workout.session.startedAt)
                VStack(spacing: 0) {
                    Text(workout.session.name)
                        .font(VFont.headline)
                        .foregroundStyle(VColor.textPrimary)
                    Text(Format.clock(elapsed))
                        .font(VFont.caption.monospacedDigit())
                        .foregroundStyle(VColor.textSecondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(workout.session.name)
                .accessibilityValue("Elapsed time \(Format.duration(elapsed)). \(workout.completedSets) of \(workout.totalSets) sets done.")
                .accessibilityAddTraits(.isHeader)
            }
            // Keep the title clear of the side buttons.
            .padding(.horizontal, Size.minTouch * 2)
            HStack(spacing: 0) {
                Button {
                    focusedField = nil
                    model.minimizeWorkout()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(VColor.inkTraining)
                        .frame(width: Size.minTouch, height: Size.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Minimize workout")
                Spacer(minLength: Space.xs)
                finishButton(workout)
            }
        }
        .padding(.horizontal, Space.xs)
        .frame(minHeight: Size.minTouch)
        .background(WColor.canvas.ignoresSafeArea(edges: .top))
    }

    private func finishButton(_ workout: ActiveWorkout) -> some View {
        let prominent = workout.isComplete
        return Button {
            focusedField = nil
            if workout.isComplete {
                model.finishWorkout()
            } else {
                showsFinishDialog = true
            }
        } label: {
            Text("Finish")
                .font(VFont.bodyEmphasized)
                .foregroundStyle(prominent ? VColor.textOnAccent : VColor.inkTraining)
                .padding(.horizontal, prominent ? Space.md : Space.xs)
                .padding(.vertical, Space.xs)
                .background {
                    if prominent {
                        Capsule().fill(VColor.accent)
                    }
                }
                .frame(minHeight: Size.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .animation(Motion.adaptive(Motion.snappy, reduceMotion: reduceMotion), value: prominent)
        .accessibilityHint(prominent ? "Every set is done" : "")
    }

    // MARK: Keyboard

    @ToolbarContentBuilder
    private func keyboardToolbar(_ workout: ActiveWorkout) -> some ToolbarContent {
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

    // MARK: Add exercise

    private var addExerciseButton: some View {
        VStack(spacing: 0) {
            Hairline()
            Button {
                showsAddExercise = true
            } label: {
                Label("Add exercise", systemImage: Icon.add)
            }
            .buttonStyle(.widgetSecondary)
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.xs)
        }
    }

    /// An empty session: the training field with one way forward.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("No exercises yet")
                .font(VFont.fieldTitle)
                .foregroundStyle(VColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("Add the first exercise to start logging sets.")
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary)
            Button {
                showsAddExercise = true
            } label: {
                Label("Add exercise", systemImage: Icon.add)
            }
            .buttonStyle(.widgetPrimary)
            .padding(.top, Space.xs)
        }
        .padding(.horizontal, Space.fieldInset)
        .padding(.top, Space.xs)
        .padding(.bottom, Space.fieldVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VColor.fieldTraining)
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

/// The workout's own toast: a material capsule under the nav row. A personal
/// record reads "New record" with a seal (the model posts it with the trophy
/// symbol; the workout shows records as data, not prizes). The model already
/// fires the success haptic; this announces it for VoiceOver and clears it
/// after 2.5 s.
private struct WorkoutToastHost: View {
    @Binding var toast: ToastMessage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let toast {
                let isRecord = toast.symbol == Icon.trophy
                let title = isRecord ? "New record" : toast.title
                HStack(spacing: Space.xs) {
                    Image(systemName: isRecord ? "checkmark.seal" : toast.symbol)
                        .font(VFont.secondaryEmphasized)
                        .foregroundStyle(VColor.inkTraining)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(VFont.secondaryEmphasized)
                        .foregroundStyle(VColor.textPrimary)
                    if let subtitle = toast.subtitle {
                        Text(subtitle)
                            .font(VFont.secondary)
                            .foregroundStyle(VColor.textSecondary)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)
                .background(.regularMaterial, in: Capsule())
                // Floating chrome is the one place a shadow is allowed.
                .shadow(color: Elevation.floating.shadow.color, radius: Elevation.floating.shadow.radius,
                        y: Elevation.floating.shadow.y)
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.xxs)
                .accessibilityElement(children: .combine)
                .transition(Motion.slide(.top, reduceMotion: reduceMotion))
                .onTapGesture { dismiss() }
                .task(id: toast.id) {
                    let message: String = [title, toast.subtitle].compactMap { $0 }.joined(separator: ". ")
                    AccessibilityNotification.Announcement(message).post()
                    try? await Task.sleep(for: .seconds(2.5))
                    guard !Task.isCancelled else { return }
                    dismiss()
                }
            }
        }
        .animation(Motion.adaptive(Motion.snappy, reduceMotion: reduceMotion), value: toast)
    }

    private func dismiss() {
        withAnimation(Motion.adaptive(Motion.snappy, reduceMotion: reduceMotion)) { toast = nil }
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
