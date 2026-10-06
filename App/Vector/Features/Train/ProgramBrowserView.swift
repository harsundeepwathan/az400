import SwiftUI
import VectorCore

/// Presentation details for a generated program: which weekdays it trains,
/// its level and a short pitch. The training content itself comes from
/// `PlanGenerator`, so what you browse is exactly what you'll train.
struct ProgramProfile {
    var level: String
    var blurb: String
    var reasons: [String]
    /// 0 = Monday … 6 = Sunday.
    var trainingDays: [Int]

    static func forDays(_ days: Int) -> ProgramProfile {
        switch days {
        case 2:
            ProgramProfile(level: "Beginner friendly",
                           blurb: "Two full-body sessions. Every major muscle twice a week with the least time in the gym.",
                           reasons: ["Hits each muscle twice a week in just two sessions",
                                     "Big compound lifts first, accessories after",
                                     "Easy to keep going through busy weeks"],
                           trainingDays: [0, 3])
        case 3:
            ProgramProfile(level: "Beginner friendly",
                           blurb: "Three full-body days with a rest day between each. A classic for building a strength base.",
                           reasons: ["Each muscle trained three times a week", "A rest day between every session",
                                     "Three squat or hinge variations for balanced legs"],
                           trainingDays: [0, 2, 4])
        case 4:
            ProgramProfile(level: "Intermediate",
                           blurb: "Alternating upper and lower days. The sweet spot of volume and recovery for most lifters.",
                           reasons: ["Each muscle trained twice a week", "Two lower days, one squat-led and one hinge-led",
                                     "Fits Mon/Tue + Thu/Fri with a midweek rest"],
                           trainingDays: [0, 1, 3, 4])
        case 5:
            ProgramProfile(level: "Intermediate",
                           blurb: "A push / pull / legs rotation plus an upper and a lower day, for more weekly volume.",
                           reasons: ["Higher weekly volume for chest, back and shoulders",
                                     "Upper and lower days add a second hit for each muscle",
                                     "Built for 5 days with the weekend split"],
                           trainingDays: [0, 1, 2, 4, 5])
        default:
            ProgramProfile(level: "Advanced",
                           blurb: "Push, pull and legs run twice through. Maximum volume for lifters who recover well.",
                           reasons: ["Each muscle trained twice with dedicated days", "Highest weekly volume of any program here",
                                     "Needs good sleep and nutrition to recover"],
                           trainingDays: [0, 1, 2, 3, 4, 5])
        }
    }
}

private enum ProgramFilter: Hashable, CaseIterable {
    case all, mySchedule, days(Int)

    static var allCases: [ProgramFilter] { [.all, .mySchedule] + (2...6).map { .days($0) } }

    var title: String {
        switch self {
        case .all: "All"
        case .mySchedule: "Fits my schedule"
        case .days(let days): "\(days) days"
        }
    }
}

/// Browse → detail → confirm → switch. Programs are generated for the
/// user's goal and equipment, so every option is already personalised.
struct ProgramBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filter: ProgramFilter = .all
    @State private var path: [Int] = []
    @State private var appeared = false

    private var options: [TrainingProgram] {
        guard let profile = model.profile else { return [] }
        return (2...6).map { days in
            PlanGenerator(catalog: model.catalog, calendar: model.calendar).generate(from: OnboardingAnswers(
                name: profile.name, goal: profile.goal, experience: profile.experience, daysPerWeek: days,
                equipment: profile.equipment, nutritionGoal: profile.nutritionGoal, sex: profile.sex,
                heightCm: profile.heightCm, weightKg: profile.weightKg, targetWeightKg: profile.targetWeightKg
            )).program
        }
    }

    private var filtered: [TrainingProgram] {
        options.filter { program in
            switch filter {
            case .all: true
            case .mySchedule: program.daysPerWeek == model.profile?.daysPerWeek
            case .days(let days): program.daysPerWeek == days
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("Matched to your goal (\(model.profile?.goal.title.lowercased() ?? "")) and equipment (\(model.profile?.equipment.title.lowercased() ?? "")). Your history and PRs carry over whichever you pick.")
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textSecondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.xs) {
                            ForEach(ProgramFilter.allCases, id: \.self) { option in
                                Button {
                                    withAnimation(Motion.snappy) { filter = option }
                                } label: {
                                    Text(option.title)
                                        .font(VFont.captionEmphasized)
                                        .foregroundStyle(filter == option ? VColor.textOnAccent : VColor.textPrimary)
                                        .padding(.horizontal, Space.md)
                                        .frame(minHeight: 36)
                                        .background(filter == option ? VColor.accent : VColor.surface, in: Capsule())
                                        .overlay(Capsule().strokeBorder(filter == option ? .clear : VColor.separator, lineWidth: 1))
                                }
                                .buttonStyle(.pressable)
                                .accessibilityAddTraits(filter == option ? .isSelected : [])
                            }
                        }
                    }
                    .sensoryFeedback(.selection, trigger: filter)

                    if filtered.isEmpty {
                        EmptyStateView(symbol: "line.3.horizontal.decrease", title: "No programs for that filter",
                                       message: "Try another schedule.", actionTitle: "Show all programs") {
                            withAnimation(Motion.snappy) { filter = .all }
                        }
                    }

                    ForEach(Array(filtered.enumerated()), id: \.element.daysPerWeek) { index, program in
                        NavigationLink(value: program.daysPerWeek) {
                            ProgramCard(program: program,
                                        isCurrent: program.daysPerWeek == model.program?.daysPerWeek && program.name == model.program?.name,
                                        matchesSchedule: program.daysPerWeek == model.profile?.daysPerWeek)
                        }
                        .buttonStyle(.pressable)
                        // Cards rise in with a short stagger on appear and on every filter change.
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 16)
                        .animation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion).delay(Double(index) * 0.06), value: appeared)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    }
                }
                .padding(Space.gutter)
                .animation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion), value: filter)
            }
            .screenBackground()
            .navigationTitle("Programs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
            .navigationDestination(for: Int.self) { days in
                if let program = options.first(where: { $0.daysPerWeek == days }) {
                    ProgramDetailView(program: program) { dismiss() }
                }
            }
            .onAppear { appeared = true }
        }
    }
}

private struct ProgramCard: View {
    var program: TrainingProgram
    var isCurrent: Bool
    var matchesSchedule: Bool

    var body: some View {
        let profile = ProgramProfile.forDays(program.daysPerWeek)
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(program.name.components(separatedBy: " — ").first ?? program.name)
                        .font(VFont.headline)
                        .foregroundStyle(VColor.textPrimary)
                        .multilineTextAlignment(.leading)
                    Text("\(program.daysPerWeek) days / week · \(profile.level)")
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textSecondary)
                }
                Spacer()
                if isCurrent {
                    Chip(text: "Current", tint: VColor.accentText, fill: VColor.accentSoft)
                } else if matchesSchedule {
                    Chip(text: "Matches your schedule", tint: VColor.success, fill: VColor.successSoft)
                }
            }
            WeekBar(trainingDays: profile.trainingDays)
            HStack {
                Text(uniqueNames(program).joined(separator: " · "))
                    .font(VFont.caption)
                    .foregroundStyle(VColor.textSecondary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: Icon.chevron)
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(VColor.textTertiary)
            }
        }
        .card()
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(VColor.accentText, lineWidth: 2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func uniqueNames(_ program: TrainingProgram) -> [String] {
        var seen = Set<String>()
        return program.workouts.map(\.name).map { $0.replacingOccurrences(of: #" [AB]$"#, with: "", options: .regularExpression) }
            .filter { seen.insert($0).inserted }
    }
}

/// Seven thin segments, one per weekday; training days are filled.
private struct WeekBar: View {
    var trainingDays: [Int]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { day in
                Capsule()
                    .fill(trainingDays.contains(day) ? VColor.accentText : VColor.surfaceSunken)
                    .frame(height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Trains \(trainingDays.count) days a week")
    }
}

struct ProgramDetailView: View {
    var program: TrainingProgram
    var onSwitched: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded: UUID?
    @State private var confirming = false
    @State private var switched = false
    @State private var scheduleShown = false

    private var profile: ProgramProfile { ProgramProfile.forDays(program.daysPerWeek) }
    private var isCurrent: Bool { model.program?.name == program.name }
    private static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(profile.level)
                            .font(VFont.sectionHeading)
                            .foregroundStyle(VColor.textSecondary)
                        Text(program.name.components(separatedBy: " — ").first ?? program.name)
                            .font(VFont.largeTitle)
                            .foregroundStyle(VColor.textPrimary)
                        Text(profile.blurb)
                            .font(VFont.body)
                            .foregroundStyle(VColor.textSecondary)
                    }

                    HStack(spacing: Space.sm) {
                        MetricCard(label: "Days", value: "\(program.daysPerWeek)")
                        MetricCard(label: "Avg session", value: "\(averageMinutes) min")
                        MetricCard(label: "Sets / week", value: "\(program.workouts.reduce(0) { $0 + $1.totalSets })")
                    }

                    schedule
                    workouts

                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("Why this program").font(VFont.headline).foregroundStyle(VColor.textPrimary)
                        ForEach(profile.reasons, id: \.self) { reason in
                            Label(reason, systemImage: "checkmark")
                                .font(VFont.secondary)
                                .foregroundStyle(VColor.textSecondary)
                        }
                    }
                    .card()
                }
                .padding(.horizontal, Space.gutter)
                .padding(.bottom, 120)
            }
            .screenBackground()
            .safeAreaInset(edge: .bottom) {
                Group {
                    if isCurrent {
                        Label("Your current program", systemImage: Icon.check)
                            .font(VFont.bodyEmphasized)
                            .foregroundStyle(VColor.accentText)
                            .frame(maxWidth: .infinity, minHeight: Size.buttonHeight)
                            .background(VColor.accentSoft, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    } else {
                        PrimaryButton("Switch to this program") { confirming = true }
                    }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.vertical, Space.sm)
                .background(.bar)
            }

            if switched {
                SwitchSuccessView(name: program.name.components(separatedBy: " — ").first ?? program.name,
                                  next: program.workouts.first?.name ?? "")
                    .transition(.opacity)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            expanded = expanded ?? program.workouts.first?.id
            withAnimation(Motion.adaptive(Motion.celebrate, reduceMotion: reduceMotion)) { scheduleShown = true }
        }
        .confirmationDialog("Switch to \(program.name)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Switch Program") { performSwitch() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your workout history and personal records are kept. Your next workout becomes \(program.workouts.first?.name ?? "the first day").")
        }
        .sensoryFeedback(.success, trigger: switched)
    }

    private var averageMinutes: Int {
        guard !program.workouts.isEmpty else { return 0 }
        return program.workouts.reduce(0) { $0 + $1.estimatedMinutes(catalog: model.catalog) } / program.workouts.count
    }

    /// Mon–Sun with each training day labelled; days pop in one after another.
    private var schedule: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Your week").font(VFont.headline).foregroundStyle(VColor.textPrimary)
            HStack(spacing: 6) {
                ForEach(0..<7, id: \.self) { day in
                    let slot = profile.trainingDays.firstIndex(of: day)
                    VStack(spacing: 6) {
                        Text(Self.weekdays[day]).font(VFont.caption).foregroundStyle(VColor.textSecondary)
                        Text(slot.flatMap { program.workouts[safe: $0]?.name } ?? "Rest")
                            .font(.system(.caption2, weight: .bold))
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(slot == nil ? VColor.textTertiary : VColor.accentText)
                            .frame(maxWidth: .infinity, minHeight: 62)
                            .padding(.horizontal, 2)
                            .background(slot == nil ? VColor.surfaceSunken : VColor.accentSoft,
                                        in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                            .scaleEffect(scheduleShown ? 1 : 0.6)
                            .opacity(scheduleShown ? 1 : 0)
                            .animation(Motion.adaptive(Motion.celebrate, reduceMotion: reduceMotion).delay(0.12 + Double(day) * 0.055),
                                       value: scheduleShown)
                    }
                }
            }
        }
        .card()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trains " + profile.trainingDays.enumerated().map { index, day in
            "\(Self.weekdays[day]): \(program.workouts[safe: index]?.name ?? "")"
        }.joined(separator: ", "))
    }

    private var workouts: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader("Workouts")
            VStack(spacing: 0) {
                ForEach(Array(program.workouts.enumerated()), id: \.element.id) { index, template in
                    let isOpen = expanded == template.id
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            withAnimation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion)) {
                                expanded = isOpen ? nil : template.id
                            }
                        } label: {
                            HStack(spacing: Space.sm) {
                                Text("\(index + 1)")
                                    .font(VFont.secondaryEmphasized)
                                    .foregroundStyle(VColor.accentText)
                                    .frame(width: 36, height: 36)
                                    .background(VColor.accentSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(template.name).font(VFont.bodyEmphasized).foregroundStyle(VColor.textPrimary)
                                    Text("\(template.exercises.count) exercises · ~\(template.estimatedMinutes(catalog: model.catalog)) min")
                                        .font(VFont.caption)
                                        .foregroundStyle(VColor.textSecondary)
                                }
                                Spacer()
                                Image(systemName: Icon.chevron)
                                    .font(.system(.footnote, weight: .semibold))
                                    .foregroundStyle(VColor.textTertiary)
                                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                            }
                            .padding(Space.md)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(isOpen ? "Hides exercises" : "Shows exercises")

                        if isOpen {
                            VStack(alignment: .leading, spacing: Space.xs) {
                                ForEach(template.exercises) { item in
                                    HStack(alignment: .firstTextBaseline) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(model.catalog[item.exerciseID]?.name ?? item.exerciseID)
                                                .font(VFont.secondary)
                                                .foregroundStyle(VColor.textPrimary)
                                            Text(model.catalog[item.exerciseID]?.primaryMuscles.map(\.displayName).joined(separator: ", ") ?? "")
                                                .font(VFont.caption)
                                                .foregroundStyle(VColor.textSecondary)
                                        }
                                        Spacer()
                                        Text("\(item.sets) × \(item.repRange.label)")
                                            .font(VFont.dataSecondary)
                                            .foregroundStyle(VColor.textSecondary)
                                    }
                                }
                            }
                            .padding(.leading, 64)
                            .padding(.trailing, Space.md)
                            .padding(.bottom, Space.sm)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .clipped()
                    if index < program.workouts.count - 1 { Hairline(leading: Space.md) }
                }
            }
            .card(padding: 0)
            .sensoryFeedback(.selection, trigger: expanded)
        }
    }

    private func performSwitch() {
        withAnimation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion)) { switched = true }
        Task {
            try? await Task.sleep(for: .seconds(1.3))
            model.replaceProgram(program)
            model.selectedTab = .train
            onSwitched()
        }
    }
}

/// Full-screen confirmation with a drawn checkmark.
private struct SwitchSuccessView: View {
    var name: String
    var next: String
    @State private var drawn: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Space.sm) {
            ZStack {
                Circle().fill(VColor.successSoft).frame(width: 96, height: 96)
                CheckShape()
                    .trim(from: 0, to: drawn)
                    .stroke(VColor.success, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    .frame(width: 40, height: 32)
            }
            Text("You're on \(name)").font(VFont.title).foregroundStyle(VColor.textPrimary)
            Text("Next up: \(next)").font(VFont.secondary).foregroundStyle(VColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VColor.background.ignoresSafeArea())
        .onAppear {
            withAnimation(reduceMotion ? .none : .easeOut(duration: 0.5).delay(0.15)) { drawn = 1 }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

#Preview {
    ProgramBrowserView().environment(AppModel.preview())
}
