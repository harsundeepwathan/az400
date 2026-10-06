import SwiftUI
import VectorCore

/// Pre-workout preview: what you'll do and what you should lift.
struct TemplateDetailView: View {
    var template: WorkoutTemplate
    @Environment(AppModel.self) private var model
    @State private var editing: WorkoutTemplate?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("~\(template.estimatedMinutes(catalog: model.catalog)) min · \(template.exercises.count) exercises · \(template.totalSets) sets")
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textSecondary)
                    MuscleChips(muscles: template.primaryMuscles(catalog: model.catalog).map(\.displayName), limit: 5)
                }

                VStack(spacing: 0) {
                    ForEach(Array(template.exercises.enumerated()), id: \.element.id) { index, item in
                        if let exercise = model.catalog[item.exerciseID] {
                            row(exercise: exercise, item: item, index: index)
                            if index < template.exercises.count - 1 { Hairline(leading: 64) }
                        }
                    }
                }
                .card(padding: 0)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.bottom, 120)
        }
        .screenBackground()
        .navigationTitle(template.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { editing = template }
            }
        }
        .safeAreaInset(edge: .bottom) {
            PrimaryButton("Start Workout", symbol: "play.fill") { model.startWorkout(template) }
                .padding(.horizontal, Space.gutter)
                .padding(.vertical, Space.sm)
                .background(.bar)
        }
        .sheet(item: $editing) { TemplateEditorView(template: $0) }
    }

    private func row(exercise: Exercise, item: ExercisePrescription, index: Int) -> some View {
        let rec = model.recommendation(for: exercise.id, repRange: item.repRange, sets: item.sets)
        let showsSmartTarget = model.isPro || index == 0
        return Button {
            model.sheet = .exercise(exercise.id)
        } label: {
            HStack(alignment: .top, spacing: Space.sm) {
                ExerciseThumbnail(exercise: exercise, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(exercise.name).font(VFont.bodyEmphasized).foregroundStyle(VColor.textPrimary)
                    Text("\(item.sets) sets × \(item.repRange.label) reps")
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textSecondary)
                    if let rec, let weight = rec.weight {
                        HStack(spacing: 4) {
                            Image(systemName: showsSmartTarget ? Icon.sparkles : "clock.arrow.circlepath")
                            Text(showsSmartTarget
                                 ? "Target \(Format.weight(weight, unit: model.unit)) × \(rec.reps)"
                                 : "Last: \(model.history(for: exercise.id).first?.summary(unit: model.unit) ?? "—")")
                        }
                        .font(VFont.captionEmphasized.monospacedDigit())
                        .foregroundStyle(showsSmartTarget ? VColor.accentText : VColor.textSecondary)
                    }
                }
                Spacer()
                Image(systemName: Icon.chevron)
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(VColor.textTertiary)
                    .padding(.top, Space.xs)
            }
            .padding(Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Create or edit a workout template.
struct TemplateEditorView: View {
    @State var template: WorkoutTemplate
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showsPicker = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Workout name", text: $template.name)
                        .font(VFont.bodyEmphasized)
                }
                Section {
                    ForEach($template.exercises) { $item in
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(model.catalog[item.exerciseID]?.name ?? item.exerciseID)
                                .font(VFont.bodyEmphasized)
                            HStack {
                                Stepper("\(item.sets) sets", value: $item.sets, in: 1...10)
                                    .font(VFont.secondary)
                            }
                            HStack(spacing: Space.sm) {
                                Stepper("Min \(item.repRange.lower)", value: Binding(
                                    get: { item.repRange.lower },
                                    set: { item.repRange = RepRange($0, max($0, item.repRange.upper)) }
                                ), in: 1...30)
                                Stepper("Max \(item.repRange.upper)", value: Binding(
                                    get: { item.repRange.upper },
                                    set: { item.repRange = RepRange(min($0, item.repRange.lower), $0) }
                                ), in: 1...30)
                            }
                            .font(VFont.secondary)
                        }
                        .padding(.vertical, Space.xxs)
                    }
                    .onDelete { template.exercises.remove(atOffsets: $0) }
                    .onMove { template.exercises.move(fromOffsets: $0, toOffset: $1) }

                    Button {
                        showsPicker = true
                    } label: {
                        Label("Add Exercise", systemImage: "plus.circle.fill")
                            .font(VFont.bodyEmphasized)
                    }
                } header: {
                    Text("Exercises")
                } footer: {
                    Text("Use a fixed rep target (min = max) for linear progression, or a range for double progression.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(template.exercises.isEmpty ? "New Workout" : "Edit Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.save(template)
                        dismiss()
                    }
                    .disabled(template.name.trimmingCharacters(in: .whitespaces).isEmpty || template.exercises.isEmpty)
                }
            }
            .sheet(isPresented: $showsPicker) {
                ExercisePickerView(excluded: Set(template.exercises.map(\.exerciseID))) { exercise in
                    template.exercises.append(ExercisePrescription(
                        exerciseID: exercise.id, sets: 3,
                        repRange: exercise.isCompound ? RepRange(6, 10) : RepRange(10, 15)
                    ))
                }
            }
        }
    }
}

/// Searchable exercise library with muscle filters.
struct ExercisePickerView: View {
    var excluded: Set<String> = []
    var onPick: (Exercise) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var muscle: MuscleGroup?

    private var results: [Exercise] {
        model.catalog.search(query).filter { exercise in
            !excluded.contains(exercise.id) && (muscle.map { exercise.primaryMuscles.contains($0) } ?? true)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.xs) {
                            filterChip(nil, title: "All")
                            ForEach(MuscleGroup.allCases, id: \.self) { filterChip($0, title: $0.displayName) }
                        }
                        .padding(.vertical, Space.xxs)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: Space.md, bottom: 0, trailing: Space.md))
                    .listRowBackground(Color.clear)
                }
                ForEach(results.prefix(150)) { exercise in
                    Button {
                        onPick(exercise)
                        dismiss()
                    } label: {
                        HStack(spacing: Space.sm) {
                            ExerciseThumbnail(exercise: exercise, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(exercise.name).font(VFont.bodyEmphasized).foregroundStyle(VColor.textPrimary)
                                Text(exercise.primaryMuscles.map(\.displayName).joined(separator: ", ") + " · " + exercise.equipment.displayName)
                                    .font(VFont.secondary)
                                    .foregroundStyle(VColor.textSecondary)
                            }
                            Spacer()
                            if model.history(for: exercise.id).isEmpty == false {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(VColor.textTertiary)
                                    .accessibilityLabel("Logged before")
                            }
                        }
                    }
                }
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search exercises")
            .navigationTitle("Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func filterChip(_ value: MuscleGroup?, title: String) -> some View {
        Button {
            withAnimation(Motion.snappy) { muscle = value }
        } label: {
            Text(title)
                .font(VFont.captionEmphasized)
                .foregroundStyle(muscle == value ? VColor.textOnAccent : VColor.textPrimary)
                .padding(.horizontal, Space.sm)
                .frame(minHeight: 32)
                .background(muscle == value ? VColor.accent : VColor.surfaceSunken, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(muscle == value ? .isSelected : [])
    }
}

/// Reorder or remove workouts in the current program.
struct ProgramEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editing: WorkoutTemplate?

    var body: some View {
        NavigationStack {
            List {
                if let program = model.program {
                    Section {
                        ForEach(program.workouts) { template in
                            Button {
                                editing = template
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(template.name).font(VFont.bodyEmphasized).foregroundStyle(VColor.textPrimary)
                                        Text("\(template.exercises.count) exercises").font(VFont.secondary).foregroundStyle(VColor.textSecondary)
                                    }
                                    Spacer()
                                    if template.id == program.nextWorkout?.id {
                                        Chip(text: "Next", tint: VColor.accentText, fill: VColor.accentSoft)
                                    }
                                }
                            }
                        }
                        .onMove { model.moveProgramWorkouts(from: $0, to: $1) }
                        .onDelete { offsets in
                            offsets.map { program.workouts[$0] }.forEach(model.deleteTemplate)
                        }
                    } header: {
                        Text(program.name)
                    } footer: {
                        Text("Drag to change the rotation order. Tap a workout to edit its exercises.")
                    }
                }
            }
            .navigationTitle("Edit Program")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
            .sheet(item: $editing) { TemplateEditorView(template: $0) }
        }
    }
}
