import SwiftUI
import VectorCore

/// Short, one-question-per-screen onboarding ("Fields") that ends in a
/// personalised plan: the moment the app shows it already knows what to do.
/// Questions are large titles over full-width selectable rows, with a thin
/// progress bar on top and Continue pinned to the bottom.
struct OnboardingFlow: View {
    @Environment(AppModel.self) private var model
    @State private var answers = OnboardingAnswers(name: "")
    @State private var step: Step = .welcome
    @State private var plan: GeneratedPlan?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Step: Int, CaseIterable {
        case welcome, name, goal, experience, frequency, equipment, nutrition, body, generating, ready

        /// Steps that count toward the progress bar.
        static let questions: [Step] = [.name, .goal, .experience, .frequency, .equipment, .nutrition, .body]
    }

    var body: some View {
        VStack(spacing: 0) {
            if Step.questions.contains(step) {
                topBar
            }
            Group {
                switch step {
                case .welcome: WelcomeStep { go(.name) }
                case .name: NameStep(name: $answers.name) { go(.goal) }
                case .goal:
                    ChoiceStep(title: "What's your main goal?",
                               subtitle: "Vector sets your training and calories from this. You can change it any time.",
                               options: TrainingGoal.selectable, selection: answers.goal,
                               label: { ($0.title, $0.detail, Self.goalSymbol($0)) },
                               onSelect: { answers.goal = $0; answers.nutritionGoal = $0.nutritionGoal },
                               onContinue: { go(.experience) })
                case .experience:
                    ChoiceStep(title: "How experienced are you?", subtitle: "This sets your starting volume and how fast you progress.",
                               options: ExperienceLevel.allCases, selection: answers.experience,
                               label: { ($0.title, $0.detail, nil) },
                               onSelect: { answers.experience = $0 },
                               onContinue: { go(.frequency) })
                case .frequency: FrequencyStep(days: $answers.daysPerWeek) { go(.equipment) }
                case .equipment:
                    ChoiceStep(title: "What equipment do you have?", subtitle: "Every exercise in your plan will match it.",
                               options: EquipmentAccess.allCases, selection: answers.equipment,
                               label: { ($0.title, $0.detail, $0.symbol) },
                               onSelect: { answers.equipment = $0 },
                               onContinue: { go(.nutrition) })
                case .nutrition: DietStep(selection: $answers.dietaryPreferences) { go(.body) }
                case .body: BodyStep(answers: $answers) { generate() }
                case .generating: GeneratingStep()
                case .ready:
                    if let plan {
                        PlanReadyStep(plan: plan) { model.completeOnboarding(with: plan) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(insertion: Motion.slide(.trailing, reduceMotion: reduceMotion),
                                    removal: Motion.slide(.leading, reduceMotion: reduceMotion)))
            .id(step)
        }
        .screenBackground()
        .sensoryFeedback(.selection, trigger: step)
    }

    /// Goal symbols from the design: one per direction of change.
    static func goalSymbol(_ goal: TrainingGoal) -> String {
        switch goal {
        case .buildMuscle: Icon.train
        case .loseFat: "flame"
        case .getStronger: "arrow.up.right"
        case .maintain: "equal.circle"
        case .recomposition: "arrow.left.arrow.right"
        case .improveFitness: "heart"
        }
    }

    /// Back chevron, "Step 2 of 7" and a thin progress bar.
    private var topBar: some View {
        let index = Step.questions.firstIndex(of: step) ?? 0
        let count = Step.questions.count
        return VStack(spacing: Space.xs) {
            ZStack {
                Text("Step \(index + 1) of \(count)")
                    .font(VFont.secondary.monospacedDigit())
                    .foregroundStyle(VColor.textSecondary)
                HStack {
                    Button {
                        let previous = Step(rawValue: step.rawValue - 1) ?? .welcome
                        go(previous)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(.title3, weight: .semibold))
                            .foregroundStyle(VColor.accentText)
                            .frame(width: Size.minTouch, height: Size.minTouch)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                    Spacer()
                }
            }
            ProgressView(value: Double(index + 1), total: Double(count))
                .tint(VColor.accent)
                .padding(.horizontal, Space.fieldInset)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Space.xs)
        .padding(.top, Space.xxs)
    }

    private func go(_ next: Step) {
        withAnimation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion)) { step = next }
    }

    private func generate() {
        go(.generating)
        let answers = answers
        let generator = PlanGenerator(catalog: model.catalog, calendar: model.calendar)
        Task {
            let result = generator.generate(from: answers, now: model.now())
            // A short, honest pause: long enough to register the plan being
            // assembled from their answers, short enough not to feel staged.
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.4 : 1.8))
            plan = result
            go(.ready)
        }
    }
}

// MARK: - Scaffold

/// A question: large title and one-line explanation on the plain ground,
/// the answers below (full width; steps inset their own content), and the
/// primary action pinned to the bottom.
private struct StepScaffold<Content: View>: View {
    var title: String
    var subtitle: String?
    var primaryTitle: String?
    var primaryEnabled = true
    var onPrimary: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(title)
                        .font(VFont.largeTitle)
                        .foregroundStyle(VColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(VFont.body)
                            .foregroundStyle(VColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Space.fieldInset)
                .padding(.top, Space.lg)
                .padding(.bottom, Space.lg)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let primaryTitle, let onPrimary {
                PinnedActionBar {
                    Button(primaryTitle, action: onPrimary)
                        .buttonStyle(.accentCapsule)
                        .disabled(!primaryEnabled)
                }
            }
        }
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    var onStart: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HeroField(spacing: Space.md) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(.title, weight: .bold))
                        .foregroundStyle(VColor.heroTextSecondary)
                        .accessibilityHidden(true)
                    Text("A coach that decides what to change each week, and shows why.")
                        .font(VFont.largeTitle)
                        .foregroundStyle(VColor.heroText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Answer a few questions and Vector builds your training plan and calorie targets.")
                        .font(VFont.body)
                        .foregroundStyle(VColor.heroTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, Space.xl)
                // The field runs up under the status bar and into the overscroll.
                .background { VColor.heroField.padding(.top, -1000) }

                VStack(alignment: .leading, spacing: 0) {
                    feature(Icon.train, tint: VColor.inkTraining, "A program that tells you what to lift next")
                    Hairline(leading: 32 + Space.md)
                    feature(Icon.scan, tint: VColor.inkNutrition, "Log meals from a photo, as an estimate you can edit")
                    Hairline(leading: 32 + Space.md)
                    feature(Icon.progress, tint: VColor.inkBody, "Progress you can see, with the reasons why")
                }
                .padding(.horizontal, Space.fieldInset)
                .padding(.top, Space.md)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PinnedActionBar(spacing: Space.xs) {
                Button("Get started", action: onStart)
                    .buttonStyle(.accentCapsule)
                Text("Takes about a minute. No account needed.")
                    .font(VFont.caption)
                    .foregroundStyle(VColor.textSecondary)
            }
        }
    }

    private func feature(_ symbol: String, tint: Color, _ text: String) -> some View {
        HStack(spacing: Space.md) {
            Image(systemName: symbol)
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            Text(text)
                .font(VFont.body)
                .foregroundStyle(VColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, minHeight: Size.minTouch, alignment: .leading)
    }
}

// MARK: - Questions

private struct NameStep: View {
    @Binding var name: String
    var onNext: () -> Void
    @FocusState private var focused: Bool

    private var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        StepScaffold(title: "What should we call you?", subtitle: "Just a first name is fine.",
                     primaryTitle: "Continue", primaryEnabled: isValid, onPrimary: onNext) {
            VStack(alignment: .leading, spacing: Space.xs) {
                TextField("First name", text: $name)
                    .font(VFont.title)
                    .foregroundStyle(VColor.textPrimary)
                    .textContentType(.givenName)
                    .submitLabel(.continue)
                    .focused($focused)
                    .onSubmit { if isValid { onNext() } }
                    .frame(minHeight: Size.minTouch)
                Rectangle()
                    .fill(focused ? VColor.accent : VColor.separator)
                    .frame(height: focused ? 2 : 0.5)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Space.fieldInset)
        }
        .onAppear { focused = true }
    }
}

/// Single-select, full-width rows. The selected row takes the training
/// field wash and a checkmark; Continue moves on.
private struct ChoiceStep<Option: Hashable & Identifiable>: View {
    var title: String
    var subtitle: String
    var options: [Option]
    var selection: Option
    var label: (Option) -> (String, String, String?)
    var onSelect: (Option) -> Void
    var onContinue: () -> Void

    var body: some View {
        StepScaffold(title: title, subtitle: subtitle, primaryTitle: "Continue", onPrimary: onContinue) {
            VStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    let (title, detail, symbol) = label(option)
                    let isSelected = selection == option
                    row(option: option, title: title, detail: detail, symbol: symbol, isSelected: isSelected)
                    if index < options.count - 1, !isSelected, options[index + 1] != selection {
                        Hairline(leading: symbol == nil ? Space.fieldInset : Space.fieldInset + 32 + Space.md)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .sensoryFeedback(.selection, trigger: selection)
        }
    }

    private func row(option: Option, title: String, detail: String, symbol: String?, isSelected: Bool) -> some View {
        Button {
            onSelect(option)
        } label: {
            HStack(spacing: Space.md) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(isSelected ? VColor.inkTraining : VColor.textSecondary)
                        .frame(width: 32)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(VFont.headline)
                        .foregroundStyle(VColor.textPrimary)
                    Text(detail)
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.sm)
                Image(systemName: "checkmark")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(VColor.accentText)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Space.fieldInset)
            .padding(.vertical, Space.md)
            .frame(maxWidth: .infinity, minHeight: Size.minTouch, alignment: .leading)
            .background {
                if isSelected { VColor.fieldTraining }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Multi-select. Skipping is fine: no preference is a valid answer.
private struct DietStep: View {
    @Binding var selection: Set<DietaryPreference>
    var onNext: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        StepScaffold(title: "Any dietary preferences?", subtitle: "Used for food suggestions. Choose any that apply.",
                     primaryTitle: selection.isEmpty ? "No preferences" : "Continue", onPrimary: onNext) {
            FlowLayout(spacing: Space.xs) {
                ForEach(DietaryPreference.allCases) { preference in
                    let isOn = selection.contains(preference)
                    Button {
                        withAnimation(Motion.adaptive(Motion.snappy, reduceMotion: reduceMotion)) {
                            if isOn { selection.remove(preference) } else { selection.insert(preference) }
                        }
                    } label: {
                        Label(preference.title, systemImage: isOn ? "checkmark" : "plus")
                            .font(VFont.bodyEmphasized)
                            .foregroundStyle(isOn ? VColor.textOnAccent : VColor.textPrimary)
                            .padding(.horizontal, Space.md)
                            .frame(minHeight: Size.minTouch)
                            .background(isOn ? VColor.accent : VColor.quietFill, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .padding(.horizontal, Space.fieldInset)
            .sensoryFeedback(.selection, trigger: selection)
        }
    }
}

private struct FrequencyStep: View {
    @Binding var days: Int
    var onNext: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        StepScaffold(title: "How many days a week can you train?", subtitle: "Be realistic. Consistency beats ambition.",
                     primaryTitle: "Continue", onPrimary: onNext) {
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack(spacing: Space.xs) {
                    ForEach(2...6, id: \.self) { value in
                        let isSelected = days == value
                        Button {
                            withAnimation(Motion.adaptive(Motion.snappy, reduceMotion: reduceMotion)) { days = value }
                        } label: {
                            Text("\(value)")
                                .font(VFont.metric)
                                .foregroundStyle(isSelected ? VColor.textOnAccent : VColor.textPrimary)
                                .frame(maxWidth: .infinity, minHeight: 64)
                                .background(isSelected ? VColor.accent : VColor.quietFill,
                                            in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel("\(value) days")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                Text(description)
                    .font(VFont.body)
                    .foregroundStyle(VColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, Space.fieldInset)
            .sensoryFeedback(.selection, trigger: days)
        }
    }

    private var description: String {
        switch days {
        case 2: "Two full-body sessions. Great for busy weeks."
        case 3: "Three full-body sessions, each muscle trained three times."
        case 4: "An upper / lower split. The sweet spot for most lifters."
        case 5: "Push / pull / legs plus an upper and a lower day."
        default: "Push / pull / legs twice through. For high recovery capacity."
        }
    }
}

private struct BodyStep: View {
    @Binding var answers: OnboardingAnswers
    var onNext: () -> Void

    var body: some View {
        StepScaffold(title: "A few body details", subtitle: "Used only to calculate your calorie and protein targets.",
                     primaryTitle: "Build my plan", onPrimary: onNext) {
            VStack(alignment: .leading, spacing: Space.md) {
                Picker("Units", selection: $answers.unit) {
                    Text("kg").tag(WeightUnit.kilograms)
                    Text("lb").tag(WeightUnit.pounds)
                }
                .pickerStyle(.segmented)

                VStack(spacing: 0) {
                    row("Sex") {
                        Picker("Sex", selection: $answers.sex) {
                            Text("Male").tag(BiologicalSex.male)
                            Text("Female").tag(BiologicalSex.female)
                            Text("Prefer not to say").tag(BiologicalSex.unspecified)
                        }
                        .labelsHidden()
                        .tint(VColor.accentText)
                    }
                    Hairline()
                    row("Age") {
                        Stepper("\(answers.age)", value: $answers.age, in: 14...90)
                            .font(VFont.data)
                    }
                    Hairline()
                    row("Height") {
                        Stepper("\(Int(answers.heightCm)) cm", value: $answers.heightCm, in: 130...220, step: 1)
                            .font(VFont.data)
                    }
                    Hairline()
                    row("Weight") { weightStepper($answers.weightKg) }
                    Hairline()
                    row("Target weight") { weightStepper($answers.targetWeightKg) }
                }
            }
            .padding(.horizontal, Space.fieldInset)
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(title).font(VFont.body).foregroundStyle(VColor.textPrimary)
                Spacer()
                content()
            }
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(VFont.body).foregroundStyle(VColor.textPrimary)
                content()
            }
            .padding(.vertical, Space.xs)
        }
        .frame(minHeight: Size.setRowHeight)
    }

    private func weightStepper(_ value: Binding<Double>) -> some View {
        let step = answers.unit == .kilograms ? 0.5 : WeightUnit.pounds.toKilograms(1)
        return Stepper(Format.weight(value.wrappedValue, unit: answers.unit), value: value, in: 35...250, step: step)
            .font(VFont.data)
    }
}

// MARK: - Plan

private struct GeneratingStep: View {
    @State private var visible = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let lines = ["Choosing your split", "Matching exercises to your equipment", "Setting rep ranges", "Calculating calories and macros"]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Spacer()
            ProgressView().controlSize(.large).tint(VColor.accent)
            Text("Building your plan")
                .font(VFont.largeTitle)
                .foregroundStyle(VColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(spacing: Space.sm) {
                        Image(systemName: index < visible ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(index < visible ? VColor.accentText : VColor.textTertiary)
                            .contentTransition(.symbolEffect(.replace))
                        Text(line)
                            .font(VFont.body)
                            .foregroundStyle(index < visible ? VColor.textPrimary : VColor.textTertiary)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, Space.fieldInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            for index in 1...lines.count {
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 80 : 400))
                withAnimation(Motion.adaptive(Motion.snappy, reduceMotion: reduceMotion)) { visible = index }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: visible)
        .accessibilityElement(children: .combine)
    }
}

/// The plan reveal: the plan itself on the hero field, then why.
private struct PlanReadyStep: View {
    var plan: GeneratedPlan
    var onStart: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var programName: String {
        plan.program.name.components(separatedBy: " — ").first ?? plan.program.name
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HeroField(spacing: Space.sm) {
                    Text(plan.profile.name.isEmpty ? "Here's where you start." : "Here's where you start, \(plan.profile.name).")
                        .font(VFont.title3)
                        .foregroundStyle(VColor.heroTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(programName), \(plan.program.daysPerWeek) days \u{00B7} \(Format.integer(plan.targets.calories)) kcal")
                        .font(VFont.largeTitle)
                        .foregroundStyle(VColor.heroText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityLabel("\(programName), \(plan.program.daysPerWeek) days a week, \(Format.integer(plan.targets.calories)) kilocalories a day")
                    Text("Protein \(Format.grams(plan.targets.protein)) \u{00B7} Carbs \(Format.grams(plan.targets.carbs)) \u{00B7} Fat \(Format.grams(plan.targets.fat)) a day, \(plan.profile.nutritionGoal.title.lowercased())")
                        .font(VFont.secondary.monospacedDigit())
                        .foregroundStyle(VColor.heroTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HeroHairline()
                        .padding(.vertical, Space.xxs)
                    Label(plan.program.workouts.map(\.name).joined(separator: ", "), systemImage: Icon.train)
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.heroTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, Space.xl)
                .background { VColor.heroField.padding(.top, -1000) }

                VStack(alignment: .leading, spacing: 0) {
                    Text("Why this plan")
                        .font(VFont.title)
                        .foregroundStyle(VColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.bottom, Space.xs)
                    ForEach(Array(plan.rationale.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                            Image(systemName: "checkmark")
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(VColor.accentText)
                                .accessibilityHidden(true)
                            Text(line)
                                .font(VFont.body)
                                .foregroundStyle(VColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, Space.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if index < plan.rationale.count - 1 { Hairline() }
                    }
                }
                .padding(.horizontal, Space.fieldInset)
                .padding(.top, Space.lg)
                .opacity(appeared ? 1 : 0)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PinnedActionBar(spacing: Space.xs) {
                Button("Start my plan", action: onStart)
                    .buttonStyle(.accentCapsule)
                Text("You can change anything later in Profile.")
                    .font(VFont.caption)
                    .foregroundStyle(VColor.textSecondary)
            }
        }
        .onAppear {
            withAnimation(Motion.adaptive(Motion.gentle.delay(0.1), reduceMotion: reduceMotion)) { appeared = true }
        }
        .sensoryFeedback(.success, trigger: appeared)
    }
}

#Preview {
    OnboardingFlow().environment(AppModel(store: InMemoryStore(), recognizer: DemoMealRecognizer()))
}
