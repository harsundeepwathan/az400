import SwiftUI
import VectorCore

/// Column widths of the set table, shared by the caption row and every set
/// row so the columns line up. Scaled with Dynamic Type and capped so the
/// row still fits a 375 pt screen at accessibility sizes.
struct SetColumns {
    var set: CGFloat
    var weight: CGFloat
    var reps: CGFloat
    var check: CGFloat
}

/// One exercise inside the active workout. The current exercise opens with
/// the training field (name, target, last time, and the rest ring); every
/// other exercise is a plain section on the ground. Below either sits the
/// set table: hairline rows, tabular numbers, one tap to complete.
struct ExerciseLogCard: View {
    var index: Int
    var log: ExerciseLog
    var workout: ActiveWorkout
    var isCurrent: Bool
    var focusedField: FocusState<SetField?>.Binding
    var prPositions: Set<SetPosition>
    var onShowDetail: () -> Void
    var onEditRest: () -> Void
    /// Reports whether the header ring is on screen (current exercise only),
    /// so the compact rest bar can take over when it isn't.
    var onRingVisibilityChange: (Int, Bool) -> Void = { _, _ in }
    @Environment(AppModel.self) private var model

    private var exercise: Exercise? { model.catalog[log.exerciseID] }
    private var previous: ExercisePerformance? { model.history(for: log.exerciseID).first }
    /// Free users get the smart target on the main lift only; the rest of the
    /// time they see last session's numbers. No upsell inside the workout.
    private var showsSmartTarget: Bool { model.isPro || index == 0 }

    @AppStorage("logsEffort") private var logsEffort = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var editsNote = false
    @State private var reportsDiscomfort = false

    @ScaledMetric(relativeTo: .body) private var setColumn: CGFloat = 44
    @ScaledMetric(relativeTo: .title3) private var weightColumn: CGFloat = 76
    @ScaledMetric(relativeTo: .title3) private var repsColumn: CGFloat = 56

    private var columns: SetColumns {
        SetColumns(set: min(setColumn, 60), weight: min(weightColumn, 112), reps: min(repsColumn, 80), check: Size.minTouch)
    }

    private var isLinkedToNext: Bool {
        guard let group = log.supersetGroup else { return false }
        return workout.session.exercises[safe: index + 1]?.supersetGroup == group
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isCurrent {
                currentHeader
            } else {
                plainHeader
            }
            VStack(alignment: .leading, spacing: 0) {
                if !log.note.isEmpty || editsNote {
                    ExerciseNoteField(index: index, note: log.note, startsFocused: editsNote) { editsNote = false }
                        .padding(.top, Space.sm)
                }
                setTable
                footer
            }
            .padding(.horizontal, Space.fieldInset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion), value: isCurrent)
        .sheet(isPresented: $reportsDiscomfort) {
            DiscomfortReportSheet(exerciseID: log.exerciseID, exerciseName: exercise?.name)
        }
    }

    // MARK: Headers

    /// The training field: "Exercise 1 of 6", the name, target and last
    /// time beside the ring, then the rest controls while resting.
    private var currentHeader: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Space.md) {
                    currentInfo
                    ring
                }
            } else {
                HStack(alignment: .center, spacing: Space.md) {
                    currentInfo
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ring
                }
            }
            if model.restTimer != nil {
                RestControls()
                    .transition(Motion.slide(.top, reduceMotion: reduceMotion))
            }
        }
        .padding(.horizontal, Space.fieldInset)
        .padding(.top, Space.xs)
        .padding(.bottom, Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VColor.fieldTraining)
        .animation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion), value: model.restTimer != nil)
        .background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named(ActiveWorkoutView.scrollSpace))
                Color.clear
                    .onAppear { reportVisibility(frame) }
                    .onChange(of: frame.maxY) { _, _ in reportVisibility(frame) }
            }
        }
        .onDisappear { onRingVisibilityChange(index, false) }
        .accessibilityElement(children: .contain)
    }

    private func reportVisibility(_ frame: CGRect) {
        // Visible while the ring and rest controls are mostly below the top edge.
        onRingVisibilityChange(index, frame.maxY > Size.minTouch + Space.xl)
    }

    private var ring: some View {
        WorkoutHeaderRing(setsDone: log.sets.filter(\.isCompleted).count, setsTotal: log.sets.count)
    }

    private var currentInfo: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            supersetLabel
            Text("Exercise \(index + 1) of \(workout.session.exercises.count)")
                .font(VFont.fieldCaption)
                .foregroundStyle(VColor.textSecondary)
                .contentTransition(.numericText())
            Button(action: onShowDetail) {
                Text(exercise?.name ?? log.exerciseID)
                    .font(VFont.fieldTitle)
                    .foregroundStyle(VColor.textPrimary)
                    .multilineTextAlignment(.leading)
                    .frame(minHeight: Size.minTouch, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint("Shows history, instructions and alternatives")
            targetLine(emphasized: true)
        }
    }

    /// Non-current exercise: name with the options menu, then the target line.
    private var plainHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            supersetLabel
            HStack(alignment: .center, spacing: Space.xs) {
                Button(action: onShowDetail) {
                    HStack(spacing: Space.xs) {
                        Text(exercise?.name ?? log.exerciseID)
                            .font(VFont.title)
                            .foregroundStyle(VColor.textPrimary)
                            .multilineTextAlignment(.leading)
                        if log.isComplete {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(VColor.accent)
                                .accessibilityLabel("Done")
                                .transition(.opacity)
                        }
                    }
                    .frame(minHeight: Size.minTouch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHint("Shows history, instructions and alternatives")
                Spacer(minLength: Space.xs)
                optionsMenu
            }
            targetLine(emphasized: false)
        }
        .padding(.horizontal, Space.fieldInset)
        .padding(.top, Space.md)
    }

    @ViewBuilder
    private var supersetLabel: some View {
        if log.supersetGroup != nil {
            Label(isLinkedToNext ? "Superset · next exercise follows without rest" : "Superset · rest after this one",
                  systemImage: "link")
                .font(VFont.captionEmphasized)
                .foregroundStyle(VColor.inkTraining)
        }
    }

    /// "Target 82.5 kg × 8 · last 80 × 8": what to beat, and what you did.
    private func targetLine(emphasized: Bool) -> some View {
        let first = log.sets.first { $0.kind != .warmup } ?? log.sets.first
        let target = todayTarget(first)
        let smart = showsSmartTarget && first?.targetWeight != nil
        let label = previous == nil && first?.targetWeight != nil ? "Suggested start (estimate)" : (showsSmartTarget ? "Target" : "Today")
        let marker: Text = smart
            ? Text(Image(systemName: Icon.recommendation)).foregroundStyle(VColor.inkTraining) + Text(" ")
            : Text("")
        let lead: Text = Text("\(label) ").foregroundStyle(VColor.textSecondary)
        let value: Text = Text(target)
            .fontWeight(emphasized ? .semibold : .regular)
            .foregroundStyle(emphasized ? VColor.textPrimary : VColor.textSecondary)
        let last: Text = Text(" · \(lastTopSet.map { "last \($0)" } ?? "first time")").foregroundStyle(VColor.textSecondary)
        let line: Text = marker + lead + value + last
        return line
            .font(VFont.secondary.monospacedDigit())
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("\(label) \(target). Last time \(lastTopSet ?? "not logged")\(lastDate.map { ", \($0)" } ?? "").")
    }

    private var lastTopSet: String? {
        guard let previous, let top = previous.topSets.first else { return nil }
        return top.weight > 0 ? "\(Format.weight(top.weight, unit: model.unit, includeUnit: false)) × \(top.reps)" : "\(top.reps) reps"
    }

    private var lastDate: String? {
        previous.map { Format.relativeDays(from: $0.date, to: model.now(), calendar: model.calendar).lowercased() }
    }

    /// The target if there is one; otherwise the load to beat with reps left blank.
    private func todayTarget(_ set: SetLog?) -> String {
        guard let set else { return "—" }
        let weight = set.targetWeight ?? set.weight
        let reps = set.targetReps.map(String.init) ?? "__"
        return weight > 0 ? "\(Format.weight(weight, unit: model.unit)) × \(reps)" : "\(reps) reps"
    }

    private var optionsMenu: some View {
        Menu {
            Button("Exercise Details", systemImage: Icon.info, action: onShowDetail)
            Button("Replace Exercise", systemImage: Icon.swap, action: onShowDetail)
            Button("Rest Time", systemImage: Icon.timer, action: onEditRest)
            Button(log.note.isEmpty ? "Add Note" : "Edit Note", systemImage: "note.text") { editsNote = true }
            if index < workout.session.exercises.count - 1 {
                Button(isLinkedToNext ? "Unlink Superset" : "Superset with Next", systemImage: isLinkedToNext ? "link.badge.minus" : "link") {
                    withAnimation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion)) {
                        model.updateWorkout { $0.toggleSuperset(withNext: index) }
                    }
                }
            }
            Button(model.isFavorite(exerciseID: log.exerciseID) ? "Remove from Favourites" : "Add to Favourites",
                   systemImage: model.isFavorite(exerciseID: log.exerciseID) ? "star.slash" : "star") {
                model.toggleFavorite(exerciseID: log.exerciseID)
            }
            if index > 0 {
                Button("Move Up", systemImage: "arrow.up") { model.updateWorkout { $0.moveExercise(from: index, to: index - 1) } }
            }
            if index < workout.session.exercises.count - 1 {
                Button("Move Down", systemImage: "arrow.down") { model.updateWorkout { $0.moveExercise(from: index, to: index + 1) } }
            }
            Button("Report Discomfort", systemImage: "exclamationmark.bubble") { reportsDiscomfort = true }
            Divider()
            Button("Remove Exercise", systemImage: "trash", role: .destructive) {
                withAnimation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion)) {
                    model.updateWorkout { $0.removeExercise(at: index) }
                }
            }
        } label: {
            Image(systemName: Icon.more)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(VColor.textSecondary)
                .frame(width: Size.minTouch, height: Size.minTouch)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("\(exercise?.name ?? "Exercise") options")
    }

    // MARK: Set table

    private var setTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnCaptions
            ForEach(Array(log.sets.enumerated()), id: \.element.id) { setIndex, set in
                let position = SetPosition(exercise: index, set: setIndex)
                let isLast = model.lastCompletion?.position == position
                if setIndex > 0 {
                    Hairline(leading: columns.set)
                }
                SetRow(
                    number: workingSetNumber(setIndex),
                    set: set,
                    position: position,
                    previous: previousLabel(setIndex),
                    isActive: workout.focus == position && !set.isCompleted,
                    isPR: prPositions.contains(position),
                    columns: columns,
                    unit: model.unit,
                    focusedField: focusedField,
                    onDuplicate: { duplicate(position) }
                )
                if logsEffort, isLast, set.isCompleted, set.kind != .warmup {
                    EffortPicker(position: position, setNumber: workingSetNumber(setIndex), rpe: set.rpe)
                        .padding(.leading, columns.set)
                        .padding(.bottom, Space.sm)
                        .transition(Motion.slide(.top, reduceMotion: reduceMotion))
                }
                if isLast,
                   let feedback = SetFeedback.evaluate(set, next: log.sets[safe: setIndex + 1], restSeconds: log.restSeconds, unit: model.unit) {
                    Text(feedback.text)
                        .font(VFont.caption)
                        .foregroundStyle(feedback.result == .below ? VColor.textSecondary : VColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, columns.set)
                        .padding(.bottom, Space.sm)
                        .transition(.opacity)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
        }
        .animation(Motion.adaptive(Motion.snappy, reduceMotion: reduceMotion), value: model.lastCompletion?.position)
    }

    /// Set · Previous · kg · Reps, once per exercise. The current exercise's
    /// options menu sits in the empty check column (its header is the field).
    private var columnCaptions: some View {
        HStack(spacing: 0) {
            Text("Set").frame(width: columns.set, alignment: .leading)
            Text("Previous").frame(maxWidth: .infinity, alignment: .leading)
            Text(model.unit.symbol).frame(width: columns.weight)
            Text("Reps").frame(width: columns.reps)
            Group {
                if isCurrent {
                    optionsMenu
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: columns.check, alignment: .trailing)
        }
        .font(VFont.fieldCaption)
        .foregroundStyle(VColor.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(minHeight: Size.minTouch)
    }

    /// + Add set on the left, this exercise's rest time on the right.
    private var footer: some View {
        HStack(spacing: Space.sm) {
            Button {
                withAnimation(Motion.adaptive(Motion.snappy, reduceMotion: reduceMotion)) {
                    model.updateWorkout { $0.addSet(toExercise: index) }
                }
                Haptics.light()
            } label: {
                Label("Add set", systemImage: Icon.add)
                    .font(VFont.bodyEmphasized)
                    .frame(minHeight: Size.minTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(VColor.accentText)
            Spacer(minLength: Space.xs)
            Button(action: onEditRest) {
                Label(Format.clock(TimeInterval(log.restSeconds)), systemImage: Icon.timer)
                    .font(VFont.secondary.monospacedDigit())
                    .frame(minHeight: Size.minTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(VColor.textSecondary)
            .accessibilityLabel("Rest time \(Format.duration(TimeInterval(log.restSeconds))). Change.")
        }
        .padding(.top, Space.xxs)
        .padding(.bottom, Space.sm)
    }

    private func duplicate(_ position: SetPosition) {
        withAnimation(Motion.adaptive(Motion.snappy, reduceMotion: reduceMotion)) {
            model.updateWorkout { $0.duplicateSet(position) }
        }
        Haptics.light()
    }

    private func workingSetNumber(_ setIndex: Int) -> String {
        let set = log.sets[setIndex]
        if let badge = set.kind.badge, set.kind != .failure { return badge }
        let working = log.sets.prefix(setIndex + 1).filter { $0.kind == .working || $0.kind == .failure }.count
        return "\(working)"
    }

    private func previousLabel(_ setIndex: Int) -> String {
        guard let previous else { return "—" }
        let sets = previous.workingSets
        guard sets.indices.contains(setIndex) else { return "—" }
        let set = sets[setIndex]
        return set.weight > 0 ? "\(Format.weight(set.weight, unit: model.unit, includeUnit: false)) × \(set.reps)" : "\(set.reps)"
    }
}

fileprivate extension ActiveWorkout {
    /// Inserts an unlogged copy of a set right after it (same kind, load and
    /// reps), keeping focus on the set it was on.
    mutating func duplicateSet(_ position: SetPosition) {
        guard session.exercises.indices.contains(position.exercise),
              session.exercises[position.exercise].sets.indices.contains(position.set) else { return }
        let source = session.exercises[position.exercise].sets[position.set]
        let copy = SetLog(kind: source.kind, weight: source.weight, reps: source.reps,
                          targetReps: source.targetReps, targetWeight: source.targetWeight)
        session.exercises[position.exercise].sets.insert(copy, at: position.set + 1)
        if let focus, focus.exercise == position.exercise, focus.set > position.set {
            self.focus = SetPosition(exercise: focus.exercise, set: focus.set + 1)
        } else if focus == nil {
            focus = SetPosition(exercise: position.exercise, set: position.set + 1)
        }
    }
}

/// One set on the ground. The active row gets a 3 pt accent bar at the
/// screen edge and bold values with no fill; done rows read in ink with a
/// filled check; upcoming rows are secondary. The check is the biggest
/// target in the row because it's tapped most.
struct SetRow: View {
    var number: String
    var set: SetLog
    var position: SetPosition
    var previous: String
    var isActive: Bool
    var isPR: Bool
    var columns: SetColumns
    var unit: WeightUnit
    var focusedField: FocusState<SetField?>.Binding
    var onDuplicate: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum RowState { case done, active, upcoming }

    private var state: RowState {
        if set.isCompleted { return .done }
        return isActive ? .active : .upcoming
    }

    private var numberColor: Color {
        switch set.kind {
        case .warmup: VColor.warning
        case .drop: VColor.accentText
        case .working, .failure: state == .upcoming ? VColor.textTertiary : VColor.textSecondary
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            setMenu
                .frame(width: columns.set, alignment: .leading)
            previousColumn
                .frame(maxWidth: .infinity, alignment: .leading)
            SetValueField(
                value: Binding(
                    get: { unit.fromKilograms(set.weight) },
                    set: { value in model.updateWorkout { $0.setWeight(unit.toKilograms(value), at: position) } }
                ),
                allowsDecimal: true,
                font: valueFont,
                color: valueColor,
                isEditing: focusedField.wrappedValue == .weight(position),
                accessibilityName: "Weight in \(unit.symbol)"
            )
            .focused(focusedField, equals: .weight(position))
            .frame(width: columns.weight)
            SetValueField(
                value: Binding(
                    get: { Double(set.reps) },
                    set: { value in model.updateWorkout { $0.setReps(Int(value), at: position) } }
                ),
                allowsDecimal: false,
                font: valueFont,
                color: valueColor,
                isEditing: focusedField.wrappedValue == .reps(position),
                accessibilityName: "Reps"
            )
            .focused(focusedField, equals: .reps(position))
            .frame(width: columns.reps)
            checkButton
                .frame(width: columns.check, alignment: .trailing)
        }
        .frame(minHeight: Size.setRowHeight + Space.xxs)
        .overlay(alignment: .leading) {
            if state == .active {
                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                       bottomTrailingRadius: 2, topTrailingRadius: 2, style: .continuous)
                    .fill(VColor.accent)
                    .frame(width: 3)
                    .padding(.vertical, Space.sm)
                    // Sits at the screen edge, in the field inset.
                    .offset(x: -Space.fieldInset)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .animation(Motion.adaptive(Motion.snappy, reduceMotion: reduceMotion), value: set.isCompleted)
        .animation(Motion.adaptive(Motion.snappy, reduceMotion: reduceMotion), value: isActive)
        .animation(Motion.adaptive(Motion.celebrate, reduceMotion: reduceMotion), value: isPR)
        .contextMenu {
            Button(set.kind == .warmup ? "Mark as Working Set" : "Mark as Warm-up", systemImage: "flame") {
                model.updateWorkout { $0.setKind(set.kind == .warmup ? .working : .warmup, at: position) }
            }
            Button(set.kind == .drop ? "Mark as Working Set" : "Mark as Drop Set", systemImage: "arrow.down.right") {
                model.updateWorkout { $0.setKind(set.kind == .drop ? .working : .drop, at: position) }
            }
            Button("Duplicate Set", systemImage: "plus.square.on.square", action: onDuplicate)
            Button("Delete Set", systemImage: "trash", role: .destructive) { delete() }
        }
    }

    private var valueFont: Font {
        switch state {
        case .active: VFont.fieldStat
        case .done: VFont.fieldStat.weight(.semibold)
        case .upcoming: VFont.fieldStat.weight(.medium)
        }
    }

    private var valueColor: Color {
        state == .upcoming ? VColor.textTertiary : VColor.textPrimary
    }

    private func delete() {
        withAnimation(Motion.adaptive(Motion.snappy, reduceMotion: reduceMotion)) {
            model.updateWorkout { $0.removeSet(position) }
        }
    }

    /// Set number; tap for set type, effort, duplicate and delete.
    private var setMenu: some View {
        Menu {
            Picker("Set Type", selection: Binding(get: { set.kind }, set: { kind in model.updateWorkout { $0.setKind(kind, at: position) } })) {
                ForEach(SetKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Effort (RPE)", selection: Binding(get: { set.rpe }, set: { rpe in model.updateWorkout { $0.setRPE(rpe, at: position) } })) {
                Text("Not logged").tag(Double?.none)
                ForEach(EffortPicker.values, id: \.self) { value in
                    Text("RPE \(Format.rpe(value)) · \(EffortPicker.rirText(value))").tag(Double?.some(value))
                }
            }
            .pickerStyle(.menu)
            Divider()
            Button("Duplicate Set", systemImage: "plus.square.on.square", action: onDuplicate)
            Button("Delete Set", systemImage: "trash", role: .destructive) { delete() }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(number)
                    .font(state == .upcoming ? VFont.body.monospacedDigit() : VFont.bodyEmphasized.monospacedDigit())
                    .foregroundStyle(numberColor)
                if set.kind == .failure {
                    Text("F").font(VFont.captionEmphasized).foregroundStyle(VColor.danger)
                }
            }
            .frame(width: columns.set, height: Size.minTouch, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("\(set.kind == .working ? "Set \(number)" : set.kind.title)\(set.rpe.map { ", RPE \(Format.rpe($0))" } ?? "")")
        .accessibilityHint("Set type, effort, duplicate or delete")
    }

    private var previousColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Space.xxs) {
                Text(previous)
                    .font(VFont.dataSecondary)
                    .foregroundStyle(VColor.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityLabel("Previous \(previous)")
                if let rpe = set.rpe {
                    Text("@\(Format.rpe(rpe))")
                        .font(VFont.captionEmphasized.monospacedDigit())
                        .foregroundStyle(VColor.inkTraining)
                        .accessibilityLabel("RPE \(Format.rpe(rpe))")
                }
            }
            if isPR {
                RecordLabel()
                    .transition(.opacity)
            }
        }
        .padding(.vertical, Space.xxs)
    }

    private var checkButton: some View {
        Button {
            focusedField.wrappedValue = nil
            // Completing a set happens ~20 times a workout: crisp, never bouncy.
            withAnimation(Motion.adaptive(Motion.snappy, reduceMotion: reduceMotion)) {
                if set.isCompleted {
                    model.uncompleteSet(position)
                } else {
                    model.completeSet(position)
                }
            }
        } label: {
            ZStack {
                switch state {
                case .done:
                    Circle().fill(VColor.accent)
                case .active:
                    Circle().strokeBorder(VColor.accent, lineWidth: 2)
                case .upcoming:
                    Circle().strokeBorder(VColor.checkOutline, lineWidth: 1.5)
                }
                if state != .upcoming {
                    Image(systemName: Icon.check)
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(state == .done ? VColor.textOnAccent : VColor.accent)
                        .symbolEffect(.bounce, value: reduceMotion ? false : set.isCompleted)
                }
            }
            .frame(width: 32, height: 32)
            .frame(width: columns.check, height: Size.minTouch, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(set.isCompleted ? "Completed. Undo" : "Complete set")
        .accessibilityHint(set.kind == .working ? "Set \(number)" : set.kind.title)
    }
}

/// Inline numeric input with tabular rounded digits and no well: the row's
/// state sets the weight and colour. A quiet fill appears only while editing.
struct SetValueField: View {
    @Binding var value: Double
    var allowsDecimal: Bool
    var font: Font
    var color: Color
    var isEditing: Bool
    var accessibilityName: String

    var body: some View {
        TextField(
            "0",
            value: $value,
            format: .number.precision(.fractionLength(0...(allowsDecimal ? 2 : 0))).grouping(.never)
        )
        .keyboardType(allowsDecimal ? .decimalPad : .numberPad)
        .multilineTextAlignment(.center)
        .font(font)
        .foregroundStyle(color)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, minHeight: Size.minTouch)
        .background(isEditing ? VColor.quietFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .accessibilityLabel(accessibilityName)
    }
}

/// One-tap effort after a working set: a segmented 6–10 control under the
/// set. Optional: it collapses when the next set is completed, and logging
/// can be switched off in Profile. Half steps stay in the set-number menu.
struct EffortPicker: View {
    static let values: [Double] = [6, 6.5, 7, 7.5, 8, 8.5, 9, 9.5, 10]
    private static let quick: [Double] = [6, 7, 8, 9, 10]
    var position: SetPosition
    var setNumber: String
    var rpe: Double?
    @Environment(AppModel.self) private var model

    static func rirText(_ rpe: Double) -> String {
        let rir = max(10 - rpe, 0)
        switch rir {
        case 0: return "nothing left"
        case 1: return "1 rep left"
        default: return "\(Format.rpe(rir)) reps left"
        }
    }

    private var question: String {
        Int(setNumber) != nil ? "How hard was set \(setNumber)?" : "How hard was that set?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("\(question) Effort (RPE)")
                .font(VFont.fieldCaption)
                .foregroundStyle(VColor.textSecondary)
                .accessibilityHidden(true)
            Picker("\(question) Effort, RPE", selection: Binding<Double?>(
                get: { rpe },
                set: { value in
                    model.updateWorkout { $0.setRPE(value, at: position) }
                    Haptics.light()
                }
            )) {
                ForEach(Self.quick, id: \.self) { value in
                    Text(Format.rpe(value))
                        .accessibilityLabel("RPE \(Format.rpe(value)), \(Self.rirText(value))")
                        .tag(Double?.some(value))
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

/// Inline note for an exercise ("seat 4", "elbows tucked"). Saved when editing ends.
private struct ExerciseNoteField: View {
    var index: Int
    var note: String
    var startsFocused: Bool
    var onEnd: () -> Void
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Note", text: $text, axis: .vertical)
            .font(VFont.secondary)
            .foregroundStyle(VColor.textPrimary)
            .lineLimit(1...4)
            .focused($isFocused)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)
            .background(VColor.warningSoft, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .onAppear {
                text = note
                if startsFocused { isFocused = true }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { save() }
            }
            .onDisappear { save() }
            .accessibilityLabel("Exercise note")
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != note { model.updateWorkout { $0.setNote(trimmed, forExercise: index) } }
        onEnd()
    }
}
