import SwiftUI
import VectorCore

/// Pre-workout preview: a training field with the routine's name and what it
/// covers, then every exercise with its sets and the load it will open with.
/// One accent capsule, pinned: "Start <routine>".
struct TemplateDetailView: View {
    var template: WorkoutTemplate
    @Environment(AppModel.self) private var model
    @State private var editing: WorkoutTemplate?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                CanvasSection("Exercises", showsTopRule: false) {
                    VStack(spacing: 0) {
                        ForEach(Array(template.exercises.enumerated()), id: \.element.id) { index, item in
                            if let exercise = model.catalog[item.exerciseID] {
                                row(exercise: exercise, item: item, index: index)
                                    .overlay(alignment: .top) {
                                        if index > 0 { Hairline(leading: ExerciseThumbnail.rowSize + Space.sm) }
                                    }
                            }
                        }
                    }
                }
            }
            .padding(.bottom, Space.xl)
        }
        .screenBackground()
        .navigationTitle(template.name)
        .navigationBarTitleDisplayMode(.inline)
        .fieldTitleInBody()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { editing = template }
                    .tint(VColor.accentText)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                model.startWorkout(template)
            } label: {
                Label(model.activeWorkout == nil ? "Start \(template.name)" : "Resume workout", systemImage: "play.fill")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .buttonStyle(.accentCapsule)
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.sm)
            .background(.bar)
        }
        .sheet(item: $editing) { TemplateEditorView(template: $0) }
    }

    private var hero: some View {
        let muscles = template.primaryMuscles(catalog: model.catalog).prefix(5).map(\.displayName)
        return VStack(alignment: .leading, spacing: 0) {
            Label(model.isProgramTemplate(template) ? (model.programShortName ?? "Program") : "Routine", systemImage: Icon.train)
                .font(VFont.secondaryEmphasized)
                .foregroundStyle(VColor.inkTraining)
            Text(template.name)
                .font(VFont.largeTitle)
                .foregroundStyle(VColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 6)
            Text("~\(template.estimatedMinutes(catalog: model.catalog)) min · \(template.exercises.count) exercises · \(template.totalSets) sets")
                .font(VFont.secondary.monospacedDigit())
                .foregroundStyle(VColor.textSecondary)
                .padding(.top, 2)
            if !muscles.isEmpty {
                Text(muscles.joined(separator: ", "))
                    .font(VFont.secondary)
                    .foregroundStyle(VColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Targets " + muscles.joined(separator: ", "))
            }
        }
        .padding(.horizontal, Space.fieldInset)
        .padding(.top, Space.xs)
        .padding(.bottom, Space.fieldVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fieldHeroBackground(VColor.fieldTraining)
    }

    private func row(exercise: Exercise, item: ExercisePrescription, index: Int) -> some View {
        let load = model.plannedLoad(for: item, at: index)
        let caption: String? = load.map { load in
            let text = "\(Format.weight(load.weight, unit: model.unit)) × \(load.reps)"
            return load.source == .lastSession ? "Last \(text)" : text
        }
        return Button {
            model.sheet = .exercise(exercise.id)
        } label: {
            HStack(spacing: Space.sm) {
                ExerciseThumbnail(exercise: exercise, size: ExerciseThumbnail.rowSize)
                CanvasRow(title: exercise.name,
                          subtitle: exercise.primaryMuscles.map(\.displayName).joined(separator: ", "),
                          value: "\(item.sets) × \(item.repRange.label)",
                          valueCaption: caption ?? (exercise.equipment == .bodyweight ? "Bodyweight" : nil),
                          showsChevron: true)
            }
            .padding(.vertical, Space.xxs)
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(exercise.name)
        .accessibilityValue("\(item.sets) sets of \(item.repRange.label) reps" + (load.map(spoken) ?? ""))
        .accessibilityHint("Shows the exercise")
        .accessibilityAddTraits(.isButton)
    }

    private func spoken(_ load: AppModel.PlannedLoad) -> String {
        let weight = Format.weight(load.weight, unit: model.unit)
        switch load.source {
        case .lastSession: return ", last time \(weight) for \(load.reps)"
        case .recommended: return ", recommended \(weight) for \(load.reps)"
        case .chosen: return ", your target \(weight) for \(load.reps)"
        }
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

/// Exercise picker sheet (templates, active workout): the searchable
/// library; choosing an exercise hands it back and closes the sheet.
struct ExercisePickerView: View {
    var excluded: Set<String> = []
    var onPick: (Exercise) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ExerciseCatalogList(excluded: excluded, onPick: { exercise in
                onPick(exercise)
                dismiss()
            })
            .navigationTitle("Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

/// The exercise library pushed from Train: the same searchable list, but a
/// row opens the exercise instead of picking it.
struct ExerciseLibraryView: View {
    var body: some View {
        ExerciseCatalogList(excluded: [], onPick: nil)
            .navigationTitle("Exercise library")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Searchable exercise list with muscle filters, favourites, recents and
/// custom exercises. With `onPick` a row picks; without, a row pushes the
/// exercise detail (`ExerciseRoute`), so the host stack must register it.
struct ExerciseCatalogList: View {
    var excluded: Set<String> = []
    var onPick: ((Exercise) -> Void)?
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var muscle: MuscleGroup?
    @State private var showsCreate = false

    private var isBrowsing: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty && muscle == nil }

    private func available(_ exercises: [Exercise]) -> [Exercise] {
        exercises.filter { !excluded.contains($0.id) }
    }

    private var results: [Exercise] {
        model.catalog.search(query).filter { exercise in
            !excluded.contains(exercise.id) && (muscle.map { exercise.primaryMuscles.contains($0) } ?? true)
        }
    }

    var body: some View {
        // Computed once per render, not per row.
        let logged = Set(model.sessions.flatMap { $0.exercises.map(\.exerciseID) })
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
            if isBrowsing {
                let favorites = available(model.favoriteExercises)
                if !favorites.isEmpty {
                    Section("Favourites") { ForEach(favorites) { row($0, logged: logged) } }
                }
                let recent = available(model.recentExerciseIDs.compactMap { model.catalog[$0] })
                if !recent.isEmpty {
                    Section("Recent") { ForEach(recent.prefix(8)) { row($0, logged: logged) } }
                }
                let custom = available(model.customExercises)
                if !custom.isEmpty {
                    Section("My Exercises") { ForEach(custom) { row($0, logged: logged) } }
                }
            }
            Section {
                ForEach(results.prefix(150)) { row($0, logged: logged) }
            } header: {
                if isBrowsing { Text("All Exercises") }
            }
            if results.isEmpty {
                ContentUnavailableView {
                    Label("No Results for \u{201C}\(query)\u{201D}", systemImage: Icon.search)
                } description: {
                    Text("Create it as your own exercise. Its history and progression work like any other.")
                } actions: {
                    Button("Create \u{201C}\(query)\u{201D}") { showsCreate = true }
                        .buttonStyle(.accentCapsule)
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search exercises")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Exercise", systemImage: Icon.add) { showsCreate = true }
            }
        }
        .sheet(isPresented: $showsCreate) {
            CustomExerciseSheet(initialName: query) { exercise in
                onPick?(exercise)
            }
        }
    }

    @ViewBuilder
    private func row(_ exercise: Exercise, logged: Set<String>) -> some View {
        Group {
            if let onPick {
                Button {
                    onPick(exercise)
                } label: {
                    rowLabel(exercise, logged: logged)
                }
            } else {
                NavigationLink(value: ExerciseRoute(id: exercise.id)) {
                    rowLabel(exercise, logged: logged)
                }
            }
        }
        .swipeActions(edge: .leading) {
            let isFavorite = model.isFavorite(exerciseID: exercise.id)
            Button(isFavorite ? "Unfavourite" : "Favourite", systemImage: isFavorite ? "star.slash" : "star") {
                model.toggleFavorite(exerciseID: exercise.id)
            }
            .tint(VColor.warning)
        }
        .swipeActions(edge: .trailing) {
            if model.canDelete(exercise) {
                Button("Delete", systemImage: "trash", role: .destructive) { model.deleteCustomExercise(exercise) }
            }
        }
        .accessibilityAction(named: model.isFavorite(exerciseID: exercise.id) ? "Remove from favourites" : "Add to favourites") {
            model.toggleFavorite(exerciseID: exercise.id)
        }
    }

    private func rowLabel(_ exercise: Exercise, logged: Set<String>) -> some View {
        HStack(spacing: Space.sm) {
            ExerciseThumbnail(exercise: exercise, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name).font(VFont.body).foregroundStyle(VColor.textPrimary)
                Text(exercise.primaryMuscles.map(\.displayName).joined(separator: ", ") + " · " + exercise.equipment.displayName)
                    .font(VFont.fieldCaption)
                    .foregroundStyle(VColor.textSecondary)
            }
            Spacer()
            if model.isFavorite(exerciseID: exercise.id) {
                Image(systemName: "star.fill")
                    .foregroundStyle(VColor.warning)
                    .accessibilityLabel("Favourite")
            }
            if logged.contains(exercise.id) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(VColor.textTertiary)
                    .accessibilityLabel("Logged before")
            }
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
                .frame(minHeight: Size.minTouch)
                .background(muscle == value ? VColor.accent : VColor.quietFill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(muscle == value ? .isSelected : [])
    }
}

/// Create an exercise that isn't in the library. Three questions, sensible defaults.
struct CustomExerciseSheet: View {
    var initialName = ""
    var onCreate: (Exercise) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var muscle: MuscleGroup = .chest
    @State private var equipment: Equipment = .dumbbell
    @State private var isCompound = false

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var duplicate: Exercise? {
        model.catalog.all.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                } footer: {
                    if let duplicate {
                        Text("\(duplicate.name) is already in the library.")
                    }
                }
                Section {
                    Picker("Main muscle", selection: $muscle) {
                        ForEach(MuscleGroup.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Picker("Equipment", selection: $equipment) {
                        ForEach(Equipment.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Toggle("Compound movement", isOn: $isCompound)
                } footer: {
                    Text(isCompound ? "Compound lifts default to 2:00 rest." : "Isolation exercises default to 1:30 rest. You can change rest during a workout.")
                }
            }
            .navigationTitle("New Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let exercise = model.addCustomExercise(name: trimmed, muscle: muscle, equipment: equipment, isCompound: isCompound)
                        dismiss()
                        onCreate(exercise)
                    }
                    .disabled(trimmed.isEmpty || duplicate != nil)
                }
            }
            .onAppear { if name.isEmpty { name = initialName } }
        }
        .presentationDetents([.medium, .large])
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
