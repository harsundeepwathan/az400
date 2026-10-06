import SwiftUI
import VectorCore

struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @State private var showsTargets = false
    @State private var showsResetConfirm = false
    @State private var exportURL: URL?
    @State private var healthConnected = false
    @AppStorage(CloudSyncPreference.key) private var iCloudSync = true

    var body: some View {
        NavigationStack {
            List {
                if let profile = model.profile {
                    Section {
                        HStack(spacing: Space.md) {
                            Text(String(model.firstName.prefix(1)).uppercased())
                                .font(VFont.title)
                                .foregroundStyle(VColor.accentText)
                                .frame(width: 56, height: 56)
                                .background(VColor.accentSoft, in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name.isEmpty ? "Athlete" : profile.name).font(VFont.title3)
                                Text("\(profile.goal.title) · \(profile.experience.title)")
                                    .font(VFont.secondary)
                                    .foregroundStyle(VColor.textSecondary)
                            }
                        }
                        .padding(.vertical, Space.xxs)
                    }

                    Section {
                        if model.isPro {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Vector Pro").font(VFont.bodyEmphasized)
                                    Text("All features unlocked").font(VFont.caption).foregroundStyle(VColor.textSecondary)
                                }
                            } icon: { Image(systemName: "checkmark.seal.fill").foregroundStyle(VColor.accentText) }
                            Link("Manage Subscription", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                        } else {
                            Button {
                                model.presentPaywall(.profile)
                            } label: {
                                HStack(spacing: Space.md) {
                                    IconBadge(symbol: Icon.sparkles, tint: VColor.textOnAccent, fill: VColor.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Upgrade to Pro").font(VFont.bodyEmphasized).foregroundStyle(VColor.textPrimary)
                                        Text("AI coaching, unlimited scans, advanced analytics")
                                            .font(VFont.caption)
                                            .foregroundStyle(VColor.textSecondary)
                                    }
                                }
                            }
                        }
                    }

                    Section("Training") {
                        Picker("Goal", selection: binding(\.goal)) {
                            ForEach(TrainingGoal.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Experience", selection: binding(\.experience)) {
                            ForEach(ExperienceLevel.allCases) { Text($0.title).tag($0) }
                        }
                        Stepper("Days per week: \(profile.daysPerWeek)", value: binding(\.daysPerWeek), in: 2...6)
                        Picker("Equipment", selection: binding(\.equipment)) {
                            ForEach(EquipmentAccess.allCases) { Text($0.title).tag($0) }
                        }
                        Toggle("Rest timer notifications", isOn: binding(\.restTimerNotifications))
                        if !profile.avoidedExerciseIDs.isEmpty {
                            NavigationLink("Avoided exercises (\(profile.avoidedExerciseIDs.count))") { AvoidedExercisesView() }
                        }
                    }

                    Section("Nutrition") {
                        Button {
                            showsTargets = true
                        } label: {
                            HStack {
                                Text("Daily targets").foregroundStyle(VColor.textPrimary)
                                Spacer()
                                Text("\(Format.integer(profile.targets.calories)) kcal · P \(Format.grams(profile.targets.protein))")
                                    .font(VFont.secondary.monospacedDigit())
                                    .foregroundStyle(VColor.textSecondary)
                            }
                        }
                        Picker("Goal", selection: binding(\.nutritionGoal)) {
                            ForEach(NutritionGoal.allCases) { Text($0.title).tag($0) }
                        }
                    }

                    Section("Body") {
                        Picker("Units", selection: binding(\.unit)) {
                            Text("Kilograms").tag(WeightUnit.kilograms)
                            Text("Pounds").tag(WeightUnit.pounds)
                        }
                        Button {
                            model.sheet = .bodyWeight
                        } label: {
                            HStack {
                                Text("Log weigh-in").foregroundStyle(VColor.textPrimary)
                                Spacer()
                                if let latest = model.latestBodyWeight {
                                    Text(Format.weight(latest.kilograms, unit: profile.unit))
                                        .foregroundStyle(VColor.textSecondary)
                                }
                            }
                        }
                        LabeledContent("Target weight", value: Format.weight(profile.targetWeightKg, unit: profile.unit))
                    }

                    Section {
                        Toggle(isOn: $iCloudSync) {
                            Label("iCloud Sync", systemImage: "icloud")
                        }
                        if let synced = model.lastSyncedAt {
                            LabeledContent("Last synced", value: synced.formatted(.relative(presentation: .named)))
                        } else if iCloudSync, model.sync?.isAvailable == false {
                            Text("Sign in to iCloud in Settings to sync between your devices.")
                                .font(VFont.caption)
                                .foregroundStyle(VColor.textSecondary)
                        }
                    } header: {
                        Text("Sync")
                    } footer: {
                        Text("Workouts, food logs and settings sync through your private iCloud account. Changes to this setting apply the next time you open Vector.")
                    }

                    Section {
                        Toggle(isOn: $healthConnected) {
                            Label("Apple Health", systemImage: "heart.fill")
                        }
                        .onChange(of: healthConnected) { _, on in
                            guard on, let health = model.health else { return }
                            Task { try? await health.requestAuthorization() }
                        }
                    } header: {
                        Text("Connections")
                    } footer: {
                        Text("Writes finished workouts to Health and reads body weight. Open Vector on Apple Watch to log sets from your wrist.")
                    }

                    Section("Data") {
                        if let exportURL {
                            ShareLink("Export data (JSON)", item: exportURL)
                        } else {
                            Button("Prepare data export") { exportURL = model.exportData() }
                        }
                        Button("Reset all data", role: .destructive) { showsResetConfirm = true }
                    }

                    #if DEBUG
                    Section("Developer") {
                        Button("Load sample data") { model.loadSampleData() }
                        Toggle("Simulate Pro", isOn: Binding(get: { model.isPro }, set: { model.setTier($0 ? .pro : .free) }))
                        Button("Show paywall") { model.presentPaywall(.profile) }
                    }
                    #endif

                    Section {
                        LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    }
                }
            }
            .navigationTitle("Profile")
            .sheet(isPresented: $showsTargets) { TargetsEditor() }
            .confirmationDialog("Reset all data?", isPresented: $showsResetConfirm, titleVisibility: .visible) {
                Button("Reset Everything", role: .destructive) { model.resetAll() }
            } message: {
                Text("Workouts, food logs and your plan will be permanently deleted from this device.")
            }
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
                                                          goal: profile.nutritionGoal)
                    }
                }
            }
            .navigationTitle("Daily Targets")
            .navigationBarTitleDisplayMode(.inline)
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
        .navigationTitle("Avoided Exercises")
    }
}
