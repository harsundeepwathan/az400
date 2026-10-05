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

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            header
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
                }
            }
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
                if index > 0 {
                    Button("Move Up", systemImage: "arrow.up") { model.updateWorkout { $0.moveExercise(from: index, to: index - 1) } }
                }
                if index < workout.session.exercises.count - 1 {
                    Button("Move Down", systemImage: "arrow.down") { model.updateWorkout { $0.moveExercise(from: index, to: index + 1) } }
                }
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

    /// "Previous 80 kg × 8 · Target 82.5 kg × 8".
    private var targetStrip: some View {
        let first = log.sets.first
        return HStack(spacing: Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Previous").font(VFont.caption).foregroundStyle(VColor.textSecondary)
                Text(previous?.summary(unit: model.unit) ?? "—")
                    .font(VFont.secondaryEmphasized.monospacedDigit())
                    .foregroundStyle(VColor.textPrimary)
            }
            if let first, let targetWeight = first.targetWeight, let targetReps = first.targetReps {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 3) {
                        if showsSmartTarget { Image(systemName: Icon.sparkles).imageScale(.small) }
                        Text("Target")
                    }
                    .font(VFont.caption)
                    .foregroundStyle(showsSmartTarget ? VColor.accentText : VColor.textSecondary)
                    Text("\(Format.weight(targetWeight, unit: model.unit)) × \(targetReps)")
                        .font(VFont.secondaryEmphasized.monospacedDigit())
                        .foregroundStyle(VColor.textPrimary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .background(VColor.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func workingSetNumber(_ setIndex: Int) -> String {
        let set = log.sets[setIndex]
        if set.kind == .warmup { return "W" }
        let working = log.sets.prefix(setIndex + 1).filter { $0.kind != .warmup }.count
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

    var body: some View {
        HStack(spacing: Space.xs) {
            Button {
                model.updateWorkout { $0.toggleWarmup(position) }
            } label: {
                Text(number)
                    .font(VFont.secondaryEmphasized.monospacedDigit())
                    .foregroundStyle(set.kind == .warmup ? VColor.warning : VColor.textSecondary)
                    .frame(width: Self.setColumn, height: Size.minTouch)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(set.kind == .warmup ? "Warm-up set" : "Set \(number)")
            .accessibilityHint("Toggles warm-up")

            HStack(spacing: 4) {
                Text(previous)
                    .font(VFont.dataSecondary)
                    .foregroundStyle(VColor.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
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
                model.updateWorkout { $0.toggleWarmup(position) }
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
