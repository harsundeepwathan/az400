import SwiftUI
import VectorCore

/// Short, one-question-per-screen onboarding that ends in a personalised
/// plan: the "aha" moment where the app shows it already knows what to do.
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
                    ChoiceStep(title: "What's your main goal?", subtitle: "We'll tune your training and nutrition around it.",
                               options: TrainingGoal.selectable, selection: answers.goal,
                               label: { ($0.title, $0.detail, $0.symbol) }) {
                        answers.goal = $0
                        answers.nutritionGoal = $0.nutritionGoal
                        go(.experience)
                    }
                case .experience:
                    ChoiceStep(title: "How experienced are you?", subtitle: "This sets your starting volume and progression speed.",
                               options: ExperienceLevel.allCases, selection: answers.experience,
                               label: { ($0.title, $0.detail, nil) }) { answers.experience = $0; go(.frequency) }
                case .frequency: FrequencyStep(days: $answers.daysPerWeek) { go(.equipment) }
                case .equipment:
                    ChoiceStep(title: "What equipment do you have?", subtitle: "Every exercise in your plan will match it.",
                               options: EquipmentAccess.allCases, selection: answers.equipment,
                               label: { ($0.title, $0.detail, $0.symbol) }) { answers.equipment = $0; go(.nutrition) }
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
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(step)
        }
        .screenBackground()
        .sensoryFeedback(.selection, trigger: step)
    }

    private var topBar: some View {
        let index = Step.questions.firstIndex(of: step) ?? 0
        return HStack(spacing: Space.sm) {
            Button {
                let previous = Step(rawValue: step.rawValue - 1) ?? .welcome
                withAnimation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion)) { step = previous }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(.body, weight: .semibold))
                    .frame(width: Size.minTouch, height: Size.minTouch)
            }
            .foregroundStyle(VColor.textPrimary)
            .accessibilityLabel("Back")
            LinearProgress(progress: Double(index + 1) / Double(Step.questions.count), height: 4)
            Text("\(index + 1)/\(Step.questions.count)")
                .font(VFont.caption.monospacedDigit())
                .foregroundStyle(VColor.textSecondary)
                .frame(width: 32)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.xs)
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

// MARK: - Steps

private struct StepScaffold<Content: View>: View {
    var title: String
    var subtitle: String?
    var primaryTitle: String?
    var primaryEnabled = true
    var onPrimary: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title)
                    .font(VFont.largeTitle)
                    .foregroundStyle(VColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle).font(VFont.body).foregroundStyle(VColor.textSecondary)
                }
            }
            .padding(.top, Space.lg)
            ScrollView { content }
                .scrollBounceBehavior(.basedOnSize)
            if let primaryTitle, let onPrimary {
                Button(primaryTitle, action: onPrimary)
                    .buttonStyle(.primary)
                    .disabled(!primaryEnabled)
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, Space.md)
    }
}

private struct WelcomeStep: View {
    var onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(VColor.textOnAccent)
                .frame(width: 72, height: 72)
                .background(VColor.accent, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Train smarter.\nEat with intent.\nSee the progress.")
                    .font(.system(.largeTitle, weight: .heavy))
                    .foregroundStyle(VColor.textPrimary)
                Text("Vector is your intelligent training and nutrition companion. Answer a few questions and we'll build your plan.")
                    .font(VFont.body)
                    .foregroundStyle(VColor.textSecondary)
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                feature("dumbbell", "A program that tells you what to lift next")
                feature(Icon.scan, "Log meals from a photo in seconds")
                feature(Icon.progress, "Progress you can see, with the reasons why")
            }
            .padding(.top, Space.xs)
            Spacer()
            PrimaryButton("Get Started", action: onStart)
            Text("Takes about a minute. No account needed.")
                .font(VFont.caption)
                .foregroundStyle(VColor.textSecondary)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, Space.md)
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: Space.sm) {
            IconBadge(symbol: symbol, size: 32)
            Text(text).font(VFont.secondaryEmphasized).foregroundStyle(VColor.textPrimary)
        }
    }
}

private struct NameStep: View {
    @Binding var name: String
    var onNext: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        StepScaffold(title: "What should we call you?", subtitle: "Just a first name is fine.",
                     primaryTitle: "Continue", primaryEnabled: !name.trimmingCharacters(in: .whitespaces).isEmpty,
                     onPrimary: onNext) {
            TextField("First name", text: $name)
                .font(VFont.title)
                .textContentType(.givenName)
                .submitLabel(.continue)
                .focused($focused)
                .onSubmit { if !name.trimmingCharacters(in: .whitespaces).isEmpty { onNext() } }
                .padding(Space.md)
                .background(VColor.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .onAppear { focused = true }
    }
}

/// Single-select list of option cards. Selecting advances automatically.
private struct ChoiceStep<Option: Hashable & Identifiable>: View {
    var title: String
    var subtitle: String
    var options: [Option]
    var selection: Option
    var label: (Option) -> (String, String, String?)
    var onSelect: (Option) -> Void
    @State private var tapped: Option?

    var body: some View {
        StepScaffold(title: title, subtitle: subtitle) {
            VStack(spacing: Space.sm) {
                ForEach(options) { option in
                    let (title, detail, symbol) = label(option)
                    let isSelected = (tapped ?? selection) == option
                    Button {
                        tapped = option
                        Task {
                            try? await Task.sleep(for: .milliseconds(220))
                            onSelect(option)
                        }
                    } label: {
                        HStack(spacing: Space.md) {
                            if let symbol {
                                IconBadge(symbol: symbol,
                                          tint: isSelected ? VColor.textOnAccent : VColor.accentText,
                                          fill: isSelected ? VColor.accent : VColor.accentSoft, size: 40)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title).font(VFont.bodyEmphasized).foregroundStyle(VColor.textPrimary)
                                Text(detail).font(VFont.secondary).foregroundStyle(VColor.textSecondary)
                            }
                            Spacer()
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? VColor.accentText : VColor.separator)
                        }
                        .padding(Space.md)
                        .background(VColor.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                .strokeBorder(isSelected ? VColor.accentText : .clear, lineWidth: 2)
                        }
                    }
                    .buttonStyle(.pressable)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .sensoryFeedback(.selection, trigger: tapped)
        }
    }
}

/// Multi-select. Skipping is fine: no preference is a valid answer.
private struct DietStep: View {
    @Binding var selection: Set<DietaryPreference>
    var onNext: () -> Void

    var body: some View {
        StepScaffold(title: "Any dietary preferences?", subtitle: "Used for food suggestions. Choose any that apply.",
                     primaryTitle: selection.isEmpty ? "No preferences" : "Continue", onPrimary: onNext) {
            FlowLayout(spacing: Space.xs) {
                ForEach(DietaryPreference.allCases) { preference in
                    let isOn = selection.contains(preference)
                    Button {
                        withAnimation(Motion.snappy) {
                            if isOn { selection.remove(preference) } else { selection.insert(preference) }
                        }
                    } label: {
                        Label(preference.title, systemImage: isOn ? "checkmark" : "plus")
                            .font(VFont.bodyEmphasized)
                            .foregroundStyle(isOn ? VColor.textOnAccent : VColor.textPrimary)
                            .padding(.horizontal, Space.md)
                            .frame(minHeight: Size.minTouch)
                            .background(isOn ? VColor.accent : VColor.surface, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .sensoryFeedback(.selection, trigger: selection)
        }
    }
}

private struct FrequencyStep: View {
    @Binding var days: Int
    var onNext: () -> Void

    var body: some View {
        StepScaffold(title: "How many days a week can you train?", subtitle: "Be realistic. Consistency beats ambition.",
                     primaryTitle: "Continue", onPrimary: onNext) {
            VStack(spacing: Space.lg) {
                HStack(spacing: Space.xs) {
                    ForEach(2...6, id: \.self) { value in
                        Button {
                            withAnimation(Motion.snappy) { days = value }
                        } label: {
                            Text("\(value)")
                                .font(VFont.metric)
                                .foregroundStyle(days == value ? VColor.textOnAccent : VColor.textPrimary)
                                .frame(maxWidth: .infinity, minHeight: 72)
                                .background(days == value ? VColor.accent : VColor.surface,
                                            in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel("\(value) days")
                        .accessibilityAddTraits(days == value ? .isSelected : [])
                    }
                }
                Text(description)
                    .font(VFont.secondary)
                    .foregroundStyle(VColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
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
                     primaryTitle: "Build My Plan", onPrimary: onNext) {
            VStack(spacing: Space.md) {
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
                    }
                    Hairline(leading: Space.md)
                    row("Age") {
                        Stepper("\(answers.age)", value: $answers.age, in: 14...90)
                            .font(VFont.data)
                    }
                    Hairline(leading: Space.md)
                    row("Height") {
                        Stepper("\(Int(answers.heightCm)) cm", value: $answers.heightCm, in: 130...220, step: 1)
                            .font(VFont.data)
                    }
                    Hairline(leading: Space.md)
                    row("Weight") { weightStepper($answers.weightKg) }
                    Hairline(leading: Space.md)
                    row("Target weight") { weightStepper($answers.targetWeightKg) }
                }
                .background(VColor.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(VFont.body).foregroundStyle(VColor.textPrimary)
            Spacer()
            content()
        }
        .padding(.horizontal, Space.md)
        .frame(minHeight: 52)
    }

    private func weightStepper(_ value: Binding<Double>) -> some View {
        let step = answers.unit == .kilograms ? 0.5 : WeightUnit.pounds.toKilograms(1)
        return Stepper(Format.weight(value.wrappedValue, unit: answers.unit), value: value, in: 35...250, step: step)
            .font(VFont.data)
    }
}

private struct GeneratingStep: View {
    @State private var visible = 0
    private let lines = ["Choosing your split", "Matching exercises to your equipment", "Setting rep ranges", "Calculating calories & macros"]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Spacer()
            ProgressView().controlSize(.large).tint(VColor.accentText)
            Text("Building your plan")
                .font(VFont.largeTitle)
                .foregroundStyle(VColor.textPrimary)
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(spacing: Space.sm) {
                        Image(systemName: index < visible ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(index < visible ? VColor.success : VColor.separator)
                            .contentTransition(.symbolEffect(.replace))
                        Text(line)
                            .font(VFont.body)
                            .foregroundStyle(index < visible ? VColor.textPrimary : VColor.textTertiary)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, Space.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            for index in 1...lines.count {
                try? await Task.sleep(for: .milliseconds(400))
                withAnimation(Motion.snappy) { visible = index }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: visible)
        .accessibilityElement(children: .combine)
    }
}

private struct PlanReadyStep: View {
    var plan: GeneratedPlan
    var onStart: () -> Void
    @Environment(AppModel.self) private var model
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Here's where you start, \(plan.profile.name.isEmpty ? "athlete" : plan.profile.name).")
                            .font(VFont.largeTitle)
                            .foregroundStyle(VColor.textPrimary)
                    }
                    .padding(.top, Space.xl)

                    VStack(alignment: .leading, spacing: Space.md) {
                        planRow(symbol: Icon.train, title: "Training", value: plan.program.name.components(separatedBy: " — ").first ?? plan.program.name,
                                detail: "\(plan.program.daysPerWeek) days / week · \(plan.program.workouts.map(\.name).joined(separator: ", "))")
                        Hairline()
                        planRow(symbol: Icon.flame, title: "Calories", value: "\(Format.integer(plan.targets.calories)) kcal",
                                detail: "per day · \(plan.profile.nutritionGoal.title.lowercased())")
                        Hairline()
                        planRow(symbol: "bolt.heart", title: "Protein", value: Format.grams(plan.targets.protein),
                                detail: "Carbs \(Format.grams(plan.targets.carbs)) · Fat \(Format.grams(plan.targets.fat))")
                    }
                    .card(padding: Space.lg)
                    .scaleEffect(appeared ? 1 : 0.96)
                    .opacity(appeared ? 1 : 0)

                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("Why this plan").font(VFont.headline).foregroundStyle(VColor.textPrimary)
                        ForEach(plan.rationale, id: \.self) { line in
                            Label(line, systemImage: "checkmark")
                                .font(VFont.secondary)
                                .foregroundStyle(VColor.textSecondary)
                        }
                    }
                    .opacity(appeared ? 1 : 0)
                }
            }
            PrimaryButton("Start My Plan", action: onStart)
            Text("You can change anything later in Profile.")
                .font(VFont.caption)
                .foregroundStyle(VColor.textSecondary)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, Space.md)
        .onAppear { withAnimation(Motion.celebrate.delay(0.1)) { appeared = true } }
        .sensoryFeedback(.success, trigger: appeared)
    }

    private func planRow(symbol: String, title: String, value: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            IconBadge(symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(VFont.caption).foregroundStyle(VColor.textSecondary)
                Text(value).font(VFont.title3).foregroundStyle(VColor.textPrimary)
                Text(detail).font(VFont.secondary).foregroundStyle(VColor.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    OnboardingFlow().environment(AppModel(store: InMemoryStore(), recognizer: DemoMealRecognizer()))
}
