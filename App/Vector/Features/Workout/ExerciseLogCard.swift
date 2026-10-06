import SwiftUI
import VectorCore

/// One exercise inside the active workout: title, previous vs. target, and
/// the set table.
struct ExerciseLogCard: View {
    var index: Int
    var log: ExerciseLog
    var workout: ActiveWorkout
    var focusedField: FocusState<SetField?>.Binding
    var prPositions: Set<SetPosition>
    var onShowDetail: () -> Void
    var onEditRest: () -> Void
    @Environment(AppModel.self) private var model

    private var exercise: Exercise? { model.catalog[log.exerciseID] }
    private var previous: ExercisePerformance? { model.history(for: log.exerciseID).first }
    private var isCurrent: Bool { workout.currentExerciseIndex == index }
    /// Free users get the smart target on the main lift only; the rest of the
    /// time they see last session's numbers. No upsell inside the workout.
    private var showsSmartTarget: Bool { model.isPro || index == 0 }

    @AppStorage("logsEffort") private var logsEffort = true
    @State private var editsNote = false
    @State private var reportsDiscomfort = false

    private var isLinkedToNext: Bool {
        guard let group = log.supersetGroup else { return false }
        return workout.session.exercises[safe: index + 1]?.supersetGroup == group
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if log.supersetGroup != nil {
                Label(isLinkedToNext ? "Superset · next exercise follows without rest" : "Superset · rest after this one",
                      systemImage: "link")
                    .font(VFont.captionEmphasized)
                    .foregroundStyle(VColor.accentText)
            }
            header
            if !log.note.isEmpty || editsNote {
                ExerciseNoteField(index: index, note: log.note, startsFocused: editsNote) { editsNote = false }
            }
            targetStrip
            VStack(spacing: Space.xxs) {
                SetTableHeader(unit: model.unit)
                ForEach(Array(log.sets.enumerated()), id: \.element.id) { setIndex, set in
                    let position = SetPosition(exercise: index, set: setIndex)
                    SetRow(
                        number: workingSetNumber(setIndex),
                        set: set,
                        position: position,
                        previous: previousLabel(setIndex),
                        isFocused: workout.focus == position,
                        isPR: prPositions.contains(position),
                        unit: model.unit,
                        focusedField: focusedField
                    )
                    if logsEffort, set.isCompleted, set.kind != .warmup, set.rpe == nil,
                       model.lastCompletion?.position == position {
                        EffortPicker(position: position)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if model.lastCompletion?.position == position,
                       let feedback = SetFeedback.evaluate(set, next: log.sets[safe: setIndex + 1], restSeconds: log.restSeconds, unit: model.unit) {
                        Text(feedback.text)
                            .font(VFont.caption)
                            .foregroundStyle(feedback.result == .below ? VColor.textSecondary : VColor.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Space.xs)
                            .transition(.opacity)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
            }
            .animation(Motion.snappy, value: model.lastCompletion?.position)
            HStack {
                Button {
                    model.updateWorkout { $0.addSet(toExercise: index) }
                } label: {
                    Label("Add Set", systemImage: "plus")
                        .font(VFont.secondaryEmphasized)
                        .frame(maxWidth: .infinity, minHeight: Size.minTouch)
                }
                .buttonStyle(.plain)
                .foregroundStyle(VColor.accentText)
                .background(VColor.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))

                Button(action: onEditRest) {
                    Label(Format.clock(TimeInterval(log.restSeconds)), systemImage: Icon.timer)
                        .font(VFont.secondaryEmphasized.monospacedDigit())
                        .padding(.horizontal, Space.sm)
                        .frame(minHeight: Size.minTouch)
                }
                .buttonStyle(.plain)
                .foregroundStyle(VColor.textSecondary)
                .background(VColor.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .accessibilityLabel("Rest time \(Format.duration(TimeInterval(log.restSeconds))). Change.")
            }
        }
        .card(padding: Space.md)
        .overlay {
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(isCurrent && !log.isComplete ? VColor.accentText.opacity(0.5) : .clear, lineWidth: 1.5)
        }
        .animation(Motion.smooth, value: isCurrent)
        .sheet(isPresented: $reportsDiscomfort) {
            DiscomfortReportSheet(exerciseID: log.exerciseID, exerciseName: exercise?.name)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Space.xs) {
            Button(action: onShowDetail) {
                HStack(spacing: Space.xs) {
                    Text(exercise?.name ?? log.exerciseID)
                        .font(VFont.title3)
                        .foregroundStyle(VColor.textPrimary)
                        .multilineTextAlignment(.leading)
                    if log.isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(VColor.success)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(minHeight: Size.minTouch)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows history, instructions and alternatives")
            Spacer()
            Menu {
                Button("Exercise Details", systemImage: Icon.info, action: onShowDetail)
                Button("Replace Exercise", systemImage: Icon.swap, action: onShowDetail)
                Button("Rest Time", systemImage: Icon.timer, action: onEditRest)
                Button(log.note.isEmpty ? "Add Note" : "Edit Note", systemImage: "note.text") { editsNote = true }
                if index < workout.session.exercises.count - 1 {
                    Button(isLinkedToNext ? "Unlink Superset" : "Superset with Next", systemImage: isLinkedToNext ? "link.badge.minus" : "link") {
                        withAnimation(Motion.smooth) { model.updateWorkout { $0.toggleSuperset(withNext: index) } }
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
                    withAnimation(Motion.smooth) { model.updateWorkout { $0.removeExercise(at: index) } }
                }
            } label: {
                Image(systemName: Icon.more)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(VColor.textSecondary)
                    .frame(width: Size.minTouch, height: Size.minTouch)
            }
            .accessibilityLabel("Exercise options")
        }
    }

    /// "LAST 80 kg × 8 · TODAY 82.5 kg × 8": what you did, what to beat.
    private var targetStrip: some View {
        let first = log.sets.first { $0.kind != .warmup } ?? log.sets.first
        return HStack(alignment: .top, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(previous.map { "LAST · \(Format.relativeDays(from: $0.date, to: model.now(), calendar: model.calendar).uppercased())" } ?? "LAST")
                    .font(VFont.sectionHeading)
                    .tracking(0.4)
                    .foregroundStyle(VColor.textSecondary)
                Text(lastTopSet ?? "First time")
                    .font(VFont.bodyEmphasized.monospacedDigit())
                    .foregroundStyle(lastTopSet == nil ? VColor.textSecondary : VColor.textPrimary)
            }
            Image(systemName: "arrow.right")
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(VColor.textTertiary)
                .padding(.top, Space.md)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 3) {
                    Text("TODAY")
                    if showsSmartTarget, first?.targetWeight != nil { Image(systemName: Icon.sparkles).imageScale(.small) }
                }
                .font(VFont.sectionHeading)
                .tracking(0.4)
                .foregroundStyle(showsSmartTarget ? VColor.accentText : VColor.textSecondary)
                Text(todayTarget(first))
                    .font(VFont.bodyEmphasized.monospacedDigit())
                    .foregroundStyle(VColor.textPrimary)
            }
            Spacer()
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .background(VColor.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last time \(lastTopSet ?? "not logged"). Today \(todayTarget(first)).")
    }

    private var lastTopSet: String? {
        guard let previous, let top = previous.topSets.first else { return nil }
        return top.weight > 0 ? "\(Format.weight(top.weight, unit: model.unit)) × \(top.reps)" : "\(top.reps) reps"
    }

    /// The target if there is one; otherwise the load to beat with reps left blank.
    private func todayTarget(_ set: SetLog?) -> String {
        guard let set else { return "—" }
        let weight = set.targetWeight ?? set.weight
        let reps = set.targetReps.map(String.init) ?? "__"
        return weight > 0 ? "\(Format.weight(weight, unit: model.unit)) × \(reps)" : "\(reps) reps"
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

private struct SetTableHeader: View {
    var unit: WeightUnit

    var body: some View {
        HStack(spacing: Space.xs) {
            Text("SET").frame(width: SetRow.setColumn)
            Text("PREVIOUS").frame(maxWidth: .infinity, alignment: .leading)
            Text(unit.symbol.uppercased()).frame(width: SetRow.fieldColumn)
            Text("REPS").frame(width: SetRow.fieldColumn)
            Image(systemName: Icon.check).frame(width: SetRow.checkColumn)
        }
        .font(.system(.caption2, weight: .semibold))
        .tracking(0.4)
        .foregroundStyle(VColor.textTertiary)
        .accessibilityHidden(true)
    }
}

/// One set. Weight and reps are inline numeric fields; the check button
/// is the biggest target in the row because it's tapped most.
struct SetRow: View {
    static let setColumn: CGFloat = 32
    static let fieldColumn: CGFloat = 72
    static let checkColumn: CGFloat = 48

    var number: String
    var set: SetLog
    var position: SetPosition
    var previous: String
    var isFocused: Bool
    var isPR: Bool
    var unit: WeightUnit
    var focusedField: FocusState<SetField?>.Binding
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var numberColor: Color {
        switch set.kind {
        case .warmup: VColor.warning
        case .drop: VColor.accentText
        case .working, .failure: VColor.textSecondary
        }
    }

    var body: some View {
        HStack(spacing: Space.xs) {
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
                Button("Delete Set", systemImage: "trash", role: .destructive) {
                    withAnimation(Motion.snappy) { model.updateWorkout { $0.removeSet(position) } }
                }
            } label: {
                VStack(spacing: 0) {
                    Text(number)
                        .font(VFont.secondaryEmphasized.monospacedDigit())
                        .foregroundStyle(numberColor)
                    if set.kind == .failure {
                        Text("F").font(.system(.caption2, weight: .bold)).foregroundStyle(VColor.danger)
                    }
                }
                .frame(width: Self.setColumn, height: Size.minTouch)
            }
            .accessibilityLabel("\(set.kind == .working ? "Set \(number)" : set.kind.title)\(set.rpe.map { ", RPE \(Format.rpe($0))" } ?? "")")
            .accessibilityHint("Set type and effort")

            HStack(spacing: 4) {
                Text(previous)
                    .font(VFont.dataSecondary)
                    .foregroundStyle(VColor.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let rpe = set.rpe {
                    Text("@\(Format.rpe(rpe))")
                        .font(VFont.captionEmphasized.monospacedDigit())
                        .foregroundStyle(VColor.accentText)
                        .accessibilityLabel("RPE \(Format.rpe(rpe))")
                }
                if isPR {
                    PRBadge()
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Previous \(previous)")

            NumericField(
                value: Binding(
                    get: { unit.fromKilograms(set.weight) },
                    set: { value in model.updateWorkout { $0.setWeight(unit.toKilograms(value), at: position) } }
                ),
                allowsDecimal: true,
                isCompleted: set.isCompleted,
                accessibilityName: "Weight in \(unit.symbol)"
            )
            .focused(focusedField, equals: .weight(position))

            NumericField(
                value: Binding(
                    get: { Double(set.reps) },
                    set: { value in model.updateWorkout { $0.setReps(Int(value), at: position) } }
                ),
                allowsDecimal: false,
                isCompleted: set.isCompleted,
                accessibilityName: "Reps"
            )
            .focused(focusedField, equals: .reps(position))

            Button {
                focusedField.wrappedValue = nil
                withAnimation(Motion.adaptive(Motion.celebrate, reduceMotion: reduceMotion)) {
                    if set.isCompleted {
                        model.uncompleteSet(position)
                    } else {
                        model.completeSet(position)
                    }
                }
            } label: {
                Image(systemName: Icon.check)
                    .font(.system(.body, weight: .bold))
                    .foregroundStyle(set.isCompleted ? VColor.textOnAccent : VColor.textSecondary)
                    .frame(width: Self.checkColumn, height: Size.minTouch)
                    .background(set.isCompleted ? VColor.success : VColor.surfaceSunken,
                                in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .symbolEffect(.bounce, value: set.isCompleted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(set.isCompleted ? "Completed. Undo" : "Complete set")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, Space.xxs)
        .background {
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(set.isCompleted ? VColor.successSoft : (isFocused ? VColor.accentSoft.opacity(0.6) : .clear))
        }
        .animation(Motion.snappy, value: set.isCompleted)
        .animation(Motion.celebrate, value: isPR)
        .contextMenu {
            Button(set.kind == .warmup ? "Mark as Working Set" : "Mark as Warm-up", systemImage: "flame") {
                model.updateWorkout { $0.setKind(set.kind == .warmup ? .working : .warmup, at: position) }
            }
            Button(set.kind == .drop ? "Mark as Working Set" : "Mark as Drop Set", systemImage: "arrow.down.right") {
                model.updateWorkout { $0.setKind(set.kind == .drop ? .working : .drop, at: position) }
            }
            Button("Delete Set", systemImage: "trash", role: .destructive) {
                withAnimation(Motion.snappy) { model.updateWorkout { $0.removeSet(position) } }
            }
        }
    }
}

/// Large, centered numeric input with tabular digits.
struct NumericField: View {
    @Binding var value: Double
    var allowsDecimal: Bool
    var isCompleted: Bool
    var accessibilityName: String

    var body: some View {
        TextField(
            "0",
            value: $value,
            format: .number.precision(.fractionLength(0...(allowsDecimal ? 2 : 0))).grouping(.never)
        )
        .keyboardType(allowsDecimal ? .decimalPad : .numberPad)
        .multilineTextAlignment(.center)
        .font(VFont.data)
        .foregroundStyle(isCompleted ? VColor.success : VColor.textPrimary)
        .frame(width: SetRow.fieldColumn, height: Size.minTouch)
        .background(isCompleted ? Color.clear : VColor.surfaceSunken,
                    in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .accessibilityLabel(accessibilityName)
    }
}

/// One-tap effort after a working set. Optional: it disappears on the next
/// set, and logging can be switched off in Profile.
struct EffortPicker: View {
    static let values: [Double] = [6, 6.5, 7, 7.5, 8, 8.5, 9, 9.5, 10]
    private static let quick: [Double] = [6, 7, 8, 9, 10]
    var position: SetPosition
    @Environment(AppModel.self) private var model

    static func rirText(_ rpe: Double) -> String {
        let rir = max(10 - rpe, 0)
        switch rir {
        case 0: return "nothing left"
        case 1: return "1 rep left"
        default: return "\(Format.rpe(rir)) reps left"
        }
    }

    var body: some View {
        HStack(spacing: Space.xs) {
            Text("Effort")
                .font(VFont.caption)
                .foregroundStyle(VColor.textSecondary)
            ForEach(Self.quick, id: \.self) { value in
                Button {
                    model.updateWorkout { $0.setRPE(value, at: position) }
                    Haptics.light()
                } label: {
                    Text(Format.rpe(value))
                        .font(VFont.secondaryEmphasized.monospacedDigit())
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(VColor.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(VColor.textPrimary)
                .frame(minHeight: Size.minTouch)
                .accessibilityLabel("RPE \(Format.rpe(value)), \(Self.rirText(value))")
            }
        }
        .padding(.horizontal, Space.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("How hard was that set?")
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
