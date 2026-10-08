import SwiftUI
import VectorCore

/// Short, one-question-per-screen onboarding that ends in a personalised
/// plan: the moment the app shows it already knows what to do. It opens on
/// Apple's standard welcome screen; each question is a large title over its
/// answers in a white tile, with a thin blue progress bar on top and Continue
/// pinned to the bottom. No account is asked for.
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
        .widgetCanvas()
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

    /// Back chevron, "Step 2 of 7" and a thin blue progress bar.
    private var topBar: some View {
        let index = Step.questions.firstIndex(of: step) ?? 0
        let count = Step.questions.count
        return VStack(spacing: Space.xs) {
            ZStack {
                Text("Step \(index + 1) of \(count)")
                    .font(.system(.subheadline, weight: .medium).monospacedDigit())
                    .foregroundStyle(WColor.textSecondary)
                HStack {
                    Button {
                        let previous = Step(rawValue: step.rawValue - 1) ?? .welcome
                        go(previous)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(.body, weight: .semibold))
                            .foregroundStyle(WColor.textPrimary)
                            .frame(width: 36, height: 36)
                            .background(WColor.innerStrong, in: Circle())
                            .frame(width: Size.minTouch, height: Size.minTouch)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("Back")
                    Spacer()
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(WColor.track)
                    Capsule().fill(WColor.strong)
                        .frame(width: proxy.size.width * CGFloat(index + 1) / CGFloat(count))
                }
            }
            .frame(height: 6)
            .padding(.horizontal, Space.gutter + 4)
            .animation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion), value: index)
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

/// A question: large title and one-line explanation on the canvas, the
/// answers below (steps put them in a tile), and the primary action pinned
/// to the bottom.
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
                        .font(.system(.largeTitle, weight: .bold))
                        .foregroundStyle(WColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(.body)
                            .foregroundStyle(WColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Space.gutter + 4)
                .padding(.top, Space.lg)
                .padding(.bottom, Space.lg)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Space.lg)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let primaryTitle, let onPrimary {
                WidgetActionBar {
                    Button(primaryTitle, action: onPrimary)
                        .buttonStyle(.widgetPrimary)
                        .disabled(!primaryEnabled)
                }
            }
        }
    }
}

// MARK: - Welcome

/// Apple's standard welcome screen: the app's name, three features with
/// symbols in the app colour, a privacy note, and one Continue.
private struct WelcomeStep: View {
    var onStart: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                (Text("Welcome to\n") + Text("Vector").foregroundColor(WidgetTint.training.ink))
                    .font(.system(.largeTitle, weight: .bold))
                    .foregroundStyle(WColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 72)

                VStack(alignment: .leading, spacing: 28) {
                    feature(Icon.train, "A plan built for you",
                            "Your split, every exercise and the weight to start with, from a few questions.")
                    feature(Icon.nutrition, "Food logging that keeps up",
                            "Search, scan a barcode, or snap a photo of your meal.")
                    feature(Icon.progress, "One clear change a week",
                            "Each week Vector reviews your training, food and weight, and tells you what to adjust and why.")
                }
                .padding(.top, 48)
            }
            .padding(.horizontal, Space.xl)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: Space.xs) {
                Image(systemName: "hand.raised.fill")
                    .font(.title2)
                    .foregroundStyle(WidgetTint.training.ink)
                    .accessibilityHidden(true)
                Text("Your workouts and food logs stay on your iPhone and in iCloud. No account needed to start.")
                    .font(.footnote)
                    .foregroundStyle(WColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Link("See how your data is managed\u{2026}", destination: AppConfig.privacyURL)
                    .font(.footnote)
                    .tint(WidgetTint.training.ink)
                Button("Continue", action: onStart)
                    .buttonStyle(.widgetPrimary)
                    .padding(.top, Space.sm)
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.sm)
            .padding(.bottom, Space.xs)
            .background(WColor.canvas.ignoresSafeArea(edges: .bottom))
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: symbol)
                .font(.system(.title, weight: .regular))
                .foregroundStyle(WidgetTint.training.ink)
                .frame(width: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(WColor.textPrimary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(WColor.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
            TextField("First name", text: $name)
                .font(.system(.title2, weight: .semibold))
                .foregroundStyle(WColor.textPrimary)
                .textContentType(.givenName)
                .submitLabel(.continue)
                .focused($focused)
                .onSubmit { if isValid { onNext() } }
                .padding(.horizontal, Space.md)
                .frame(minHeight: 60)
                .background(WColor.tile, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(focused ? WColor.strong : WColor.edge, lineWidth: focused ? 2 : 1)
                }
                .padding(.horizontal, Space.gutter)
        }
        .onAppear { focused = true }
    }
}

/// Single-select rows in one tile; the chosen row turns soft blue with a check.
private struct ChoiceStep<Option: Hashable & Identifiable>: View {
    var title: String
    var subtitle: String
    var options: [Option]
    var selection: Option
    var label: (Option) -> (String, String, String?)
    var onSelect: (Option) -> Void
    var onContinue: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        StepScaffold(title: title, subtitle: subtitle, primaryTitle: "Continue", onPrimary: onContinue) {
            VStack(spacing: 2) {
                ForEach(options) { option in
                    let (title, detail, symbol) = label(option)
                    WidgetChoiceRow(title: title, detail: detail, symbol: symbol, isSelected: selection == option) {
                        withAnimation(Motion.adaptive(Motion.snappy, reduceMotion: reduceMotion)) { onSelect(option) }
                    }
                }
            }
            .padding(4)
            .widgetSurface()
            .accessibilityElement(children: .contain)
            .sensoryFeedback(.selection, trigger: selection)
        }
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
                            .font(.system(.body, weight: .semibold))
                            .foregroundStyle(isOn ? WColor.onSelected : WColor.textPrimary)
                            .padding(.horizontal, Space.md)
                            .frame(minHeight: Size.minTouch)
                            .background(isOn ? WColor.selected : WColor.tile, in: Capsule())
                            .overlay { Capsule().strokeBorder(isOn ? WColor.onSelected.opacity(0.35) : WColor.edge, lineWidth: 1) }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .padding(.horizontal, Space.gutter)
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
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.xs) {
                    ForEach(2...6, id: \.self) { value in
                        let isSelected = days == value
                        Button {
                            withAnimation(Motion.adaptive(Motion.snappy, reduceMotion: reduceMotion)) { days = value }
                        } label: {
                            Text("\(value)")
                                .font(.system(.title, weight: .bold).monospacedDigit())
                                .foregroundStyle(isSelected ? WColor.onStrong : WColor.textPrimary)
                                .frame(maxWidth: .infinity, minHeight: 68)
                                .background(isSelected ? WColor.strong : WColor.tile,
                                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .strokeBorder(isSelected ? Color.clear : WColor.edge, lineWidth: 1)
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel("\(value) days")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, Space.gutter)

                WidgetSection(title: "\(days) days a week", symbol: "calendar") {
                    Text(description)
                        .font(.body)
                        .foregroundStyle(WColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
            }
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
            VStack(alignment: .leading, spacing: Space.sm) {
                Picker("Units", selection: $answers.unit) {
                    Text("kg").tag(WeightUnit.kilograms)
                    Text("lb").tag(WeightUnit.pounds)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Space.gutter)

                VStack(spacing: 0) {
                    row("Sex") {
                        Picker("Sex", selection: $answers.sex) {
                            Text("Male").tag(BiologicalSex.male)
                            Text("Female").tag(BiologicalSex.female)
                            Text("Prefer not to say").tag(BiologicalSex.unspecified)
                        }
                        .labelsHidden()
                        .tint(WidgetTint.training.ink)
                    }
                    divider
                    row("Age") {
                        Stepper("\(answers.age)", value: $answers.age, in: 14...90)
                            .font(.body.monospacedDigit())
                    }
                    divider
                    row("Height") {
                        Stepper("\(Int(answers.heightCm)) cm", value: $answers.heightCm, in: 130...220, step: 1)
                            .font(.body.monospacedDigit())
                    }
                    divider
                    row("Weight") { weightStepper($answers.weightKg) }
                    divider
                    row("Target weight") { weightStepper($answers.targetWeightKg) }
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, 4)
                .widgetSurface()
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(WColor.divider).frame(height: 1).accessibilityHidden(true)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(title).font(.body).foregroundStyle(WColor.textPrimary)
                Spacer()
                content()
            }
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(.body).foregroundStyle(WColor.textPrimary)
                content()
            }
            .padding(.vertical, Space.xs)
        }
        .frame(minHeight: Size.setRowHeight)
    }

    private func weightStepper(_ value: Binding<Double>) -> some View {
        let step = answers.unit == .kilograms ? 0.5 : WeightUnit.pounds.toKilograms(1)
        return Stepper(Format.weight(value.wrappedValue, unit: answers.unit), value: value, in: 35...250, step: step)
            .font(.body.monospacedDigit())
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
            Text("Building your plan")
                .font(.system(.largeTitle, weight: .bold))
                .foregroundStyle(WColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: Space.md) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(spacing: Space.sm) {
                        Image(systemName: index < visible ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(index < visible ? WidgetTint.training.accent : WColor.quiet)
                            .contentTransition(.symbolEffect(.replace))
                        Text(line)
                            .font(.body)
                            .foregroundStyle(index < visible ? WColor.textPrimary : WColor.textSecondary)
                    }
                }
            }
            .padding(Space.md + 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WColor.tile, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).strokeBorder(WColor.edge, lineWidth: 1) }
            Spacer()
        }
        .padding(.horizontal, Space.gutter)
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

/// The plan reveal: the plan itself as the blue hero tile, the week's
/// workouts, then why.
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
            VStack(alignment: .leading, spacing: 12) {
                WidgetScreenHeader(title: "Your plan",
                                   subtitle: plan.profile.name.isEmpty ? "Here's where you start" : "Here's where you start, \(plan.profile.name)")
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.md)

                WidgetHero(label: "\(plan.program.daysPerWeek) days a week", symbol: Icon.train, spacing: Space.sm) {
                    Text(programName)
                        .font(.system(.largeTitle, weight: .bold))
                        .foregroundStyle(WidgetTint.insight.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    HStack(alignment: .top, spacing: Space.md) {
                        stat(Format.integer(plan.targets.calories), "kcal a day")
                        stat(Format.grams(plan.targets.protein), "protein")
                        stat(Format.grams(plan.targets.carbs), "carbs")
                        stat(Format.grams(plan.targets.fat), "fat")
                    }
                    .padding(.top, Space.xxs)
                    Text(plan.profile.nutritionGoal.title)
                        .font(.subheadline)
                        .foregroundStyle(WidgetTint.insight.textSecondary)
                }
                .accessibilityElement(children: .combine)

                WidgetSection(title: "Your week", symbol: "calendar") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(plan.program.workouts.enumerated()), id: \.offset) { index, workout in
                            HStack {
                                Text(workout.name)
                                    .font(.system(.body, weight: .semibold))
                                    .foregroundStyle(WColor.textPrimary)
                                Spacer(minLength: Space.sm)
                                Text("\(workout.exercises.count) exercises")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(WColor.textSecondary)
                            }
                            .padding(.vertical, 10)
                            if index < plan.program.workouts.count - 1 {
                                Rectangle().fill(WColor.divider).frame(height: 1)
                            }
                        }
                    }
                }

                WidgetSection(title: "Why this plan", symbol: "checkmark.seal") {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        ForEach(Array(plan.rationale.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                                Image(systemName: "checkmark")
                                    .font(.system(.subheadline, weight: .bold))
                                    .foregroundStyle(WidgetTint.training.ink)
                                    .accessibilityHidden(true)
                                Text(line)
                                    .font(.body)
                                    .foregroundStyle(WColor.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .opacity(appeared ? 1 : 0)
            }
            .padding(.bottom, Space.lg)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WidgetActionBar {
                Button("Start my plan", action: onStart)
                    .buttonStyle(.widgetPrimary)
                Text("You can change anything later in Profile.")
                    .font(.footnote)
                    .foregroundStyle(WColor.textSecondary)
            }
        }
        .onAppear {
            withAnimation(Motion.adaptive(Motion.gentle.delay(0.1), reduceMotion: reduceMotion)) { appeared = true }
        }
        .sensoryFeedback(.success, trigger: appeared)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title3, weight: .bold).monospacedDigit())
                .foregroundStyle(WidgetTint.insight.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.footnote)
                .foregroundStyle(WidgetTint.insight.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    OnboardingFlow().environment(AppModel(store: InMemoryStore(), recognizer: DemoMealRecognizer()))
}
