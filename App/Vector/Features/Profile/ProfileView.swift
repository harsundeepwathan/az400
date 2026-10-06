import SwiftUI
import VectorCore

/// Profile and settings ("Fields"): a settings-shaped screen, so a native
/// inset grouped list. Identity first, then Pro status, then one section per
/// area. Explanations live in section footers.
struct ProfileView: View {
    /// Opened from the avatar on Today (it is no longer a tab).
    var isSheet = false
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showsTargets = false
    @State private var showsResetConfirm = false
    @State private var exportURL: URL?
    @State private var healthConnected = false
    @AppStorage(CloudSyncPreference.key) private var iCloudSync = true
    @AppStorage("logsEffort") private var logsEffort = true

    var body: some View {
        NavigationStack {
            List {
                if let profile = model.profile {
                    identity(profile)
                    proSection
                    trainingSection(profile)
                    nutritionSection(profile)
                    bodySection(profile)
                    syncSection

                    if model.isAccountAvailable {
                        AccountSection()
                    }

                    dataSection

                    #if DEBUG
                    Section("Developer") {
                        Button("Load sample data") { model.loadSampleData() }
                        Toggle("Simulate Pro", isOn: Binding(get: { model.isPro }, set: { model.setTier($0 ? .pro : .free) }))
                        Button("Show paywall") { model.presentPaywall(.profile) }
                    }
                    #endif

                    aboutSection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .tint(VColor.accent)
            .toolbar {
                if isSheet {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .foregroundStyle(VColor.accentText)
                    }
                }
            }
            .sheet(isPresented: $showsTargets) { TargetsEditor() }
            .confirmationDialog("Delete all data?", isPresented: $showsResetConfirm, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) { model.resetAll() }
            } message: {
                Text("Workouts, food logs and your plan will be permanently deleted from this device.")
            }
        }
    }

    // MARK: Identity and Pro

    private func identity(_ profile: UserProfile) -> some View {
        Section {
            NavigationLink {
                PersonalDetailsView()
            } label: {
                HStack(spacing: Space.md) {
                    avatar(profile)
                        .font(VFont.title)
                        .foregroundStyle(VColor.textSecondary)
                        .frame(width: 56, height: 56)
                        .background(VColor.quietFill, in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name.isEmpty ? "Add your name" : profile.name)
                            .font(VFont.title3)
                            .foregroundStyle(VColor.textPrimary)
                        Text("\(profile.goal.title) \u{00B7} \(profile.experience.title)")
                            .font(VFont.secondary)
                            .foregroundStyle(VColor.textSecondary)
                    }
                }
                .padding(.vertical, Space.xxs)
            }
            .accessibilityHint("Edits your name")
        }
    }

    /// Neutral initials; a person symbol when there's no name.
    @ViewBuilder private func avatar(_ profile: UserProfile) -> some View {
        if let first = profile.name.first {
            Text(String(first).uppercased())
        } else {
            Image(systemName: "person.fill")
        }
    }

    private var proSection: some View {
        Section {
            if model.isPro {
                Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                    LabeledContent {
                        Text("Active").foregroundStyle(VColor.textSecondary)
                    } label: {
                        SettingsLabel("Vector Pro", symbol: Icon.recommendation)
                    }
                }
            } else {
                Button {
                    model.presentPaywall(.profile)
                } label: {
                    LabeledContent {
                        Text("Upgrade").foregroundStyle(VColor.accentText)
                    } label: {
                        SettingsLabel("Vector Pro", symbol: Icon.recommendation)
                    }
                }
            }
        } footer: {
            Text(model.isPro
                 ? "Manage or cancel in your Apple ID settings."
                 : "A weekly check-in that decides what to change, with the evidence. Logging stays free.")
        }
    }

    // MARK: Areas

    private func trainingSection(_ profile: UserProfile) -> some View {
        Section {
            Picker(selection: binding(\.daysPerWeek)) {
                ForEach(2...6, id: \.self) { Text("\($0)").tag($0) }
            } label: {
                SettingsLabel("Days per week", symbol: "calendar")
            }
            .pickerStyle(.navigationLink)
            Picker(selection: binding(\.experience)) {
                ForEach(ExperienceLevel.allCases) { Text($0.title).tag($0) }
            } label: {
                SettingsLabel("Experience", symbol: "chart.bar")
            }
            .pickerStyle(.navigationLink)
            Picker(selection: binding(\.equipment)) {
                ForEach(EquipmentAccess.allCases) { Text($0.title).tag($0) }
            } label: {
                SettingsLabel("Equipment", symbol: Icon.train)
            }
            .pickerStyle(.navigationLink)
            Toggle(isOn: binding(\.restTimerNotifications)) {
                SettingsLabel("Rest timer notifications", symbol: "bell")
            }
            Toggle(isOn: $logsEffort) {
                SettingsLabel("Log effort (RPE) after sets", symbol: Icon.timer)
            }
            if !profile.avoidedExerciseIDs.isEmpty {
                NavigationLink {
                    AvoidedExercisesView()
                } label: {
                    LabeledContent {
                        Text("\(profile.avoidedExerciseIDs.count)")
                    } label: {
                        SettingsLabel("Avoided exercises", symbol: "nosign")
                    }
                }
            }
        } header: {
            Text("Training")
        } footer: {
            Text("Effort helps the coach decide when to add weight.")
        }
    }

    private func nutritionSection(_ profile: UserProfile) -> some View {
        Section("Nutrition") {
            Button {
                showsTargets = true
            } label: {
                LabeledContent {
                    HStack(spacing: Space.xs) {
                        Text("\(Format.integer(profile.targets.calories)) kcal")
                            .monospacedDigit()
                        Image(systemName: Icon.chevron)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(VColor.textTertiary)
                            .accessibilityHidden(true)
                    }
                } label: {
                    SettingsLabel("Daily targets", symbol: "target")
                }
            }
            .accessibilityValue("\(Format.integer(profile.targets.calories)) kilocalories, protein \(Format.grams(profile.targets.protein))")
            NavigationLink {
                DietaryPreferencesView()
            } label: {
                LabeledContent {
                    Text(dietLine(profile))
                } label: {
                    SettingsLabel("Dietary preferences", symbol: Icon.nutrition)
                }
            }
        }
    }

    private func dietLine(_ profile: UserProfile) -> String {
        let set = profile.dietaryPreferences ?? []
        return set.isEmpty ? "None" : set.map(\.title).sorted().joined(separator: ", ")
    }

    private func bodySection(_ profile: UserProfile) -> some View {
        Section {
            Picker(selection: Binding(get: { profile.goal }, set: { goal in
                // One goal drives both training and calorie direction.
                model.updateProfile { $0.goal = goal; $0.nutritionGoal = goal.nutritionGoal }
            })) {
                ForEach(TrainingGoal.selectable + (profile.goal == .improveFitness ? [.improveFitness] : [])) {
                    Text($0.title).tag($0)
                }
            } label: {
                SettingsLabel("Goal", symbol: "scope")
            }
            .pickerStyle(.navigationLink)
            Picker(selection: binding(\.unit)) {
                Text("Kilograms").tag(WeightUnit.kilograms)
                Text("Pounds").tag(WeightUnit.pounds)
            } label: {
                SettingsLabel("Units", symbol: "scalemass")
            }
            .pickerStyle(.navigationLink)
            Button {
                model.sheet = .bodyWeight
            } label: {
                LabeledContent {
                    if let latest = model.latestBodyWeight {
                        Text(Format.weight(latest.kilograms, unit: profile.unit)).monospacedDigit()
                    }
                } label: {
                    SettingsLabel("Log weigh-in", symbol: "plus.circle")
                }
            }
            LabeledContent {
                Text(Format.weight(profile.targetWeightKg, unit: profile.unit)).monospacedDigit()
            } label: {
                SettingsLabel("Target weight", symbol: "flag")
            }
        } header: {
            Text("Body")
        } footer: {
            Text("Changing your goal changes the direction of your calorie target.")
        }
    }

    // MARK: Sync

    private var syncSection: some View {
        Section {
            Toggle(isOn: $iCloudSync) {
                SettingsLabel("iCloud sync", symbol: "icloud")
            }
            if let synced = model.lastSyncedAt {
                LabeledContent {
                    Text(synced.formatted(.relative(presentation: .named)))
                } label: {
                    SettingsLabel("Last synced", symbol: "arrow.triangle.2.circlepath")
                }
            } else if iCloudSync, model.sync?.isAvailable == false {
                Text("Sign in to iCloud in Settings to sync between your devices.")
                    .font(VFont.secondary)
                    .foregroundStyle(VColor.textSecondary)
            }
            Toggle(isOn: $healthConnected) {
                SettingsLabel("Apple Health", symbol: "heart")
            }
            .onChange(of: healthConnected) { _, on in
                guard on, let health = model.health else { return }
                Task { try? await health.requestAuthorization() }
            }
        } header: {
            Text("Sync and connections")
        } footer: {
            Text("Workouts, food logs and settings sync through your private iCloud account; changes to sync apply the next time you open Vector. Health receives finished workouts and shares body weight. Open Vector on Apple Watch to log sets from your wrist.")
        }
    }

    // MARK: Data and about

    private var dataSection: some View {
        Section {
            if let exportURL {
                ShareLink(item: exportURL) {
                    SettingsLabel("Export your data (JSON)", symbol: "square.and.arrow.up")
                }
            } else {
                Button {
                    exportURL = model.exportData()
                } label: {
                    SettingsLabel("Prepare data export", symbol: "doc")
                }
            }
            Button(role: .destructive) {
                showsResetConfirm = true
            } label: {
                SettingsLabel("Delete all data", symbol: "trash", tint: VColor.danger)
            }
        } header: {
            Text("Data")
        } footer: {
            Text("Deleting removes workouts, food logs and your plan from this device.")
        }
    }

    private var aboutSection: some View {
        Section {
            Link(destination: AppConfig.privacyURL) {
                SettingsLabel("Privacy policy", symbol: "lock")
            }
            Link(destination: AppConfig.termsURL) {
                SettingsLabel("Terms of use", symbol: "doc.text")
            }
            LabeledContent {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            } label: {
                SettingsLabel("Version", symbol: Icon.info)
            }
        } header: {
            Text("About")
        } footer: {
            Text(SafetyGuidance.scope)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<UserProfile, Value>) -> Binding<Value> {
        // Fall back to the value captured at render time so a reset (which
        // clears the profile) can never crash a binding mid-transition.
        let fallback = model.profile?[keyPath: keyPath]
        return Binding(
            get: { model.profile?[keyPath: keyPath] ?? fallback! },
            set: { value in model.updateProfile { $0[keyPath: keyPath] = value } }
        )
    }
}

/// The identity row's edit screen. Goal and experience live in their own sections.
private struct PersonalDetailsView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""

    var body: some View {
        Form {
            Section {
                TextField("First name", text: $name)
                    .textContentType(.givenName)
                    .submitLabel(.done)
                    .onSubmit(save)
            } header: {
                Text("Name")
            } footer: {
                Text("Used only to greet you in the app.")
            }
        }
        .navigationTitle("Your details")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = model.profile?.name ?? "" }
        .onDisappear(perform: save)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != model.profile?.name else { return }
        model.updateProfile { $0.name = trimmed }
    }
}

private struct TargetsEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var targets = NutritionTargets(calories: 0, protein: 0, carbs: 0, fat: 0)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Calories: \(Format.integer(targets.calories)) kcal", value: $targets.calories, in: 1200...5000, step: 50)
                    Stepper("Protein: \(Format.grams(targets.protein))", value: $targets.protein, in: 40...350, step: 5)
                    Stepper("Carbs: \(Format.grams(targets.carbs))", value: $targets.carbs, in: 20...700, step: 5)
                    Stepper("Fat: \(Format.grams(targets.fat))", value: $targets.fat, in: 20...250, step: 5)
                } footer: {
                    let fromMacros = targets.protein * 4 + targets.carbs * 4 + targets.fat * 9
                    Text("Macros add up to \(Format.integer(fromMacros)) kcal.")
                }
                Section {
                    Button("Recalculate from my profile") {
                        guard let profile = model.profile else { return }
                        let age = model.calendar.component(.year, from: model.now()) - profile.birthYear
                        targets = NutritionEngine.targets(sex: profile.sex, weightKg: model.latestBodyWeight?.kilograms ?? profile.weightKg,
                                                          heightCm: profile.heightCm, age: age, trainingDays: profile.daysPerWeek,
                                                          goal: profile.nutritionGoal, proteinPerKg: profile.goal.proteinPerKg)
                    }
                }
            }
            .navigationTitle("Daily targets")
            .navigationBarTitleDisplayMode(.inline)
            .tint(VColor.accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.updateProfile { $0.targets = targets }
                        dismiss()
                    }
                }
            }
            .onAppear { if let current = model.profile?.targets { targets = current } }
        }
    }
}

private struct DietaryPreferencesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selected = model.profile?.dietaryPreferences ?? []
        List {
            Section {
                ForEach(DietaryPreference.allCases) { preference in
                    Button {
                        model.updateProfile { profile in
                            var set = profile.dietaryPreferences ?? []
                            if set.contains(preference) { set.remove(preference) } else { set.insert(preference) }
                            profile.dietaryPreferences = set
                        }
                    } label: {
                        HStack {
                            Text(preference.title).foregroundStyle(VColor.textPrimary)
                            Spacer()
                            if selected.contains(preference) {
                                Image(systemName: "checkmark").foregroundStyle(VColor.accentText)
                            }
                        }
                    }
                    .accessibilityAddTraits(selected.contains(preference) ? .isSelected : [])
                }
            } footer: {
                Text("The coach only suggests foods that fit. Search always shows every food.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Dietary preferences")
    }
}

private struct AvoidedExercisesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(Array(model.profile?.avoidedExerciseIDs ?? []).sorted(), id: \.self) { id in
                HStack {
                    Text(model.catalog[id]?.name ?? id)
                    Spacer()
                    Button("Allow") { model.toggleAvoided(id) }
                        .buttonStyle(.borderless)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Avoided exercises")
    }
}
