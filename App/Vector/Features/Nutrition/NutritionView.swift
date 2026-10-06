import SwiftUI
import UIKit
import VectorCore

/// Nutrition ("Fields"): the nutrition field is the hero (large title, add
/// menu, day pager, kcal left, calorie and macro bars, protein to go). Then
/// logging on the plain ground (one accent "Scan meal" with an honest
/// caption, three quiet capsules), then the meals as open-canvas sections
/// with hairline rows. The screen is a plain `List` so food rows get native
/// swipe-to-delete; deleting offers Undo for a few seconds.
struct NutritionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var day: Date = Date()
    @State private var editing: FoodEntry?
    /// The last swipe-deleted entry, offered for Undo.
    @State private var deleted: FoodEntry?

    var body: some View {
        let nutrition = model.nutrition(on: day)
        let suggested = MealType.suggested(forHour: model.calendar.component(.hour, from: model.now()))
        NavigationStack {
            List {
                NutritionHero(day: $day, nutrition: nutrition,
                              onScan: { openScanner(suggested) }, suggested: suggested)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(VColor.fieldNutrition)

                LoggingActions(scansRemaining: model.scansRemaining, suggested: suggested,
                               onScan: { openScanner(suggested) })
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(VColor.ground)

                ForEach(MealType.allCases) { meal in
                    MealSection(meal: meal, day: day,
                                onEdit: { editing = $0 },
                                onDelete: delete,
                                onScan: { openScanner(meal) })
                }

                if let insight = model.visibleInsights.first(where: { $0.category == .nutrition && $0.id != model.dailyInsight?.id }) {
                    InsightCard(insight: insight, isLocked: insight.requiresPro && !model.isPro,
                                onAction: { model.handle($0) }, onUnlock: { model.presentPaywall(.insight) })
                        .padding(.horizontal, Space.fieldInset)
                        .padding(.top, Space.xl)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(VColor.ground)
                }

                Color.clear
                    .frame(height: Space.xl)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(VColor.ground)
                    .accessibilityHidden(true)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            // Field colour above, ground below: pulling down past the top shows the
            // field, pushing past the end shows the ground.
            .background {
                VStack(spacing: 0) {
                    VColor.fieldNutrition
                    VColor.ground
                }
                .ignoresSafeArea()
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let deleted {
                    UndoBar(entry: deleted, onUndo: { undo(deleted) }, onDismiss: { dismissUndo() })
                        .padding(.horizontal, Space.gutter)
                        .padding(.bottom, Space.xs)
                        .transition(Motion.slide(.bottom, reduceMotion: reduceMotion))
                }
            }
            .task(id: deleted?.id) {
                guard deleted != nil else { return }
                // Longer with VoiceOver so there's time to reach the button.
                let seconds: Double = UIAccessibility.isVoiceOverRunning ? 10 : 5
                try? await Task.sleep(for: .seconds(seconds))
                if !Task.isCancelled { dismissUndo() }
            }
            .sheet(item: $editing) { entry in
                FoodEntryEditor(entry: entry)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private func openScanner(_ meal: MealType) {
        if model.canScan {
            model.cover = .scanner(meal)
        } else {
            model.presentPaywall(.mealScanQuota)
        }
    }

    private func delete(_ entry: FoodEntry) {
        withAnimation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion)) {
            model.delete(entry)
            deleted = entry
        }
        let message: String = "Deleted \(entry.name). Undo available."
        AccessibilityNotification.Announcement(message).post()
    }

    private func undo(_ entry: FoodEntry) {
        withAnimation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion)) {
            model.restoreFoodEntry(entry)
            deleted = nil
        }
        Haptics.light()
    }

    private func dismissUndo() {
        withAnimation(Motion.adaptive(Motion.snappy, reduceMotion: reduceMotion)) { deleted = nil }
    }
}

// MARK: - Hero field

/// Large title and add menu, the day pager, kcal left, the calorie bar,
/// three macro rows and the protein still to go. Runs up under the status bar.
private struct NutritionHero: View {
    @Binding var day: Date
    var nutrition: DailyNutrition
    var onScan: () -> Void
    var suggested: MealType
    @Environment(AppModel.self) private var model
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize = FieldMetric.heroNumber

    var body: some View {
        let remaining = nutrition.caloriesRemaining
        let isToday = model.calendar.isDate(day, inSameDayAs: model.now())
        let proteinToGo = max(nutrition.targets.protein - nutrition.consumed.protein, 0)

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Space.sm) {
                Text("Nutrition")
                    .font(VFont.largeTitle)
                    .foregroundStyle(VColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.sm)
                addMenu
            }

            DayPager(day: $day)
                .padding(.top, Space.xs)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Text(Format.integer(abs(remaining)))
                        .font(VFont.fieldHero(heroSize))
                        .foregroundStyle(VColor.textPrimary)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if remaining < 0 {
                        Label("kcal over", systemImage: "exclamationmark.triangle.fill")
                            .font(VFont.headline)
                            .foregroundStyle(VColor.warning)
                    } else {
                        Text("kcal left")
                            .font(VFont.headline)
                            .foregroundStyle(VColor.textPrimary)
                    }
                }
                Text("\(Format.integer(nutrition.consumed.calories)) eaten of \(Format.integer(nutrition.targets.calories))")
                    .font(VFont.secondary.monospacedDigit())
                    .foregroundStyle(VColor.textSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Calories")
            .accessibilityValue("\(Format.integer(abs(remaining))) \(remaining >= 0 ? "left" : "over"), "
                                + "\(Format.integer(nutrition.consumed.calories)) eaten of \(Format.integer(nutrition.targets.calories))")
            .padding(.top, Space.sm)

            FieldBar(progress: nutrition.calorieProgress, tint: VColor.calories, height: 8)
                .padding(.top, Space.md)

            VStack(spacing: Space.md) {
                MacroRow(title: "Protein", consumed: nutrition.consumed.protein, target: nutrition.targets.protein, tint: VColor.protein)
                MacroRow(title: "Carbs", consumed: nutrition.consumed.carbs, target: nutrition.targets.carbs, tint: VColor.carbs)
                MacroRow(title: "Fat", consumed: nutrition.consumed.fat, target: nutrition.targets.fat, tint: VColor.fat)
            }
            .padding(.top, Space.md)

            proteinLine(toGo: proteinToGo, isToday: isToday)
                .padding(.top, Space.md)
        }
        .padding(.horizontal, Space.fieldInset)
        .padding(.top, 6)
        .padding(.bottom, Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VColor.fieldNutrition)
    }

    @ViewBuilder private func proteinLine(toGo: Double, isToday: Bool) -> some View {
        if toGo > 0 {
            (Text("\(Format.integer(toGo)) g protein").font(VFont.bodyEmphasized.monospacedDigit()).foregroundStyle(VColor.textPrimary)
                + Text(isToday ? " to go today" : " under target").font(VFont.body).foregroundStyle(VColor.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Label("Protein target met", systemImage: "checkmark.circle.fill")
                .font(VFont.bodyEmphasized)
                .foregroundStyle(VColor.textPrimary)
        }
    }

    /// Every way to log, for the meal that fits the time of day.
    private var addMenu: some View {
        Menu {
            Button("Scan meal", systemImage: Icon.scan, action: onScan)
            Button("Search food", systemImage: Icon.search) { model.sheet = .foodSearch(suggested) }
            Button("Scan barcode", systemImage: Icon.barcode) { model.sheet = .barcode(suggested) }
            Button("Quick add", systemImage: Icon.quickAdd) { model.sheet = .quickAdd(suggested) }
            Button("Saved meals", systemImage: Icon.meal) { model.sheet = .savedMeals(suggested) }
        } label: {
            Image(systemName: Icon.add)
                .font(.system(.title2, weight: .semibold))
                .foregroundStyle(VColor.accentText)
                .frame(width: Size.minTouch, height: Size.minTouch)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Log food")
        .accessibilityHint("Adds to \(suggested.displayName.lowercased())")
    }
}

/// ‹ Today, 5 Oct › with arrows (swiping would fight the scroll).
private struct DayPager: View {
    @Binding var day: Date
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let calendar = model.calendar
        let isToday = calendar.isDate(day, inSameDayAs: model.now())
        HStack {
            Button { shift(-1) } label: {
                Image(systemName: "chevron.left")
                    .frame(width: Size.minTouch, height: Size.minTouch)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(VColor.accentText)
            .accessibilityLabel("Previous day")
            Spacer(minLength: Space.xs)
            Text(title(isToday: isToday))
                .font(VFont.bodyEmphasized)
                .foregroundStyle(VColor.textPrimary)
                .contentTransition(.interpolate)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: Space.xs)
            Button { shift(1) } label: {
                Image(systemName: "chevron.right")
                    .frame(width: Size.minTouch, height: Size.minTouch)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(isToday ? VColor.textTertiary : VColor.accentText)
            .disabled(isToday)
            .accessibilityLabel("Next day")
        }
        .buttonStyle(.plain)
        .font(.system(.body, weight: .semibold))
        .padding(.horizontal, -Space.sm)
        .sensoryFeedback(.selection, trigger: day)
    }

    private func title(isToday: Bool) -> String {
        let short = Format.shortDate(day, calendar: model.calendar)
        if isToday { return "Today, \(short)" }
        if let yesterday = model.calendar.date(byAdding: .day, value: -1, to: model.now()),
           model.calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday, \(short)"
        }
        return Format.longDate(day, calendar: model.calendar)
    }

    private func shift(_ days: Int) {
        withAnimation(Motion.adaptive(Motion.snappy, reduceMotion: reduceMotion)) {
            day = model.calendar.date(byAdding: .day, value: days, to: day) ?? day
        }
    }
}

// MARK: - Logging

/// "Scan meal" (the one filled button) with the honest caption, then three
/// quiet capsules. A full-width hairline closes the block before the meals.
private struct LoggingActions: View {
    var scansRemaining: Int?
    var suggested: MealType
    var onScan: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Space.sm) {
                Button(action: onScan) {
                    Label("Scan meal", systemImage: Icon.scan)
                }
                .buttonStyle(.accentCapsule)
                .accessibilityHint(caption)

                Text(caption)
                    .font(VFont.fieldCaption)
                    .foregroundStyle(VColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)

                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: Space.xs) { quietActions }
                    } else {
                        HStack(spacing: Space.xs) { quietActions }
                    }
                }
                .padding(.top, Space.xs)
            }
            .padding(.horizontal, Space.fieldInset)
            .padding(.top, Space.lg)
            .padding(.bottom, Space.lg)
            RowHairline()
        }
        .background(VColor.ground)
    }

    @ViewBuilder private var quietActions: some View {
        QuickActionButton(title: "Search", symbol: Icon.search, variant: .capsule) { model.sheet = .foodSearch(suggested) }
        QuickActionButton(title: "Barcode", symbol: Icon.barcode, variant: .capsule) { model.sheet = .barcode(suggested) }
        QuickActionButton(title: "Quick add", symbol: Icon.add, variant: .capsule) { model.sheet = .quickAdd(suggested) }
    }

    private var caption: String {
        let honesty = "Photo estimates are approximate. Check them before saving."
        guard let scansRemaining else { return honesty }
        let quota = scansRemaining == 0
            ? "Free scans used this week."
            : "\(scansRemaining) free \(scansRemaining == 1 ? "scan" : "scans") left this week."
        return honesty + " " + quota
    }
}

// MARK: - Meals

/// One meal as list rows: a title row with the kcal total and the meal's
/// menu, hairline food rows (tap to edit, swipe or long-press to delete),
/// or an "Add dinner" text action when empty.
private struct MealSection: View {
    var meal: MealType
    var day: Date
    var onEdit: (FoodEntry) -> Void
    var onDelete: (FoodEntry) -> Void
    var onScan: () -> Void
    @Environment(AppModel.self) private var model
    @State private var savingName = ""
    @State private var showsSavePrompt = false

    var body: some View {
        let entries = model.entries(on: day, meal: meal)
        let total = entries.reduce(Macros.zero) { $0 + $1.macros }
        Section {
            header(entries: entries, total: total)
                .padding(.horizontal, Space.fieldInset)
                .padding(.top, Space.lg)
                .modifier(MealRowStyle())
                .alert("Save meal", isPresented: $showsSavePrompt) {
                    TextField("Name", text: $savingName)
                    Button("Save") { model.saveMeal(named: savingName, entries: entries) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Log these \(entries.count) foods again with one tap.")
                }

            if entries.isEmpty {
                Button {
                    model.sheet = .foodSearch(meal)
                } label: {
                    Label("Add \(meal.displayName.lowercased())", systemImage: Icon.add)
                        .font(VFont.bodyEmphasized)
                        .foregroundStyle(VColor.accentText)
                        .frame(maxWidth: .infinity, minHeight: Size.minTouch, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Space.fieldInset)
                .modifier(MealRowStyle())
            } else {
                ForEach(entries) { entry in
                    Button { onEdit(entry) } label: {
                        VStack(spacing: 0) {
                            FoodEntryRow(entry: entry)
                            if entry.id != entries.last?.id {
                                RowHairline(leading: FoodEntryRow.textInset)
                            }
                        }
                        .padding(.horizontal, Space.fieldInset)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Edit")
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { onDelete(entry) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { onEdit(entry) }
                        Button("Delete", systemImage: "trash", role: .destructive) { onDelete(entry) }
                    }
                    .modifier(MealRowStyle())
                }
            }
        }
    }

    private func header(entries: [FoodEntry], total: Macros) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Text(meal.displayName)
                .font(VFont.canvasTitle)
                .foregroundStyle(VColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Space.xs)
            Text("\(Format.integer(total.calories)) kcal")
                .font(VFont.secondary.monospacedDigit())
                .foregroundStyle(VColor.textSecondary)
                .accessibilityLabel("\(Format.integer(total.calories)) kilocalories")
            mealMenu(entries: entries)
        }
    }

    /// The meal's own actions: every way to log into this meal, copy from
    /// yesterday and save as a meal.
    private func mealMenu(entries: [FoodEntry]) -> some View {
        Menu {
            Button("Search food", systemImage: Icon.search) { model.sheet = .foodSearch(meal) }
            Button("Scan meal", systemImage: Icon.scan, action: onScan)
            Button("Scan barcode", systemImage: Icon.barcode) { model.sheet = .barcode(meal) }
            Button("Quick add", systemImage: Icon.quickAdd) { model.sheet = .quickAdd(meal) }
            Button("Saved meals", systemImage: Icon.meal) { model.sheet = .savedMeals(meal) }
            if let yesterday = model.calendar.date(byAdding: .day, value: -1, to: day),
               !model.entries(on: yesterday, meal: meal).isEmpty {
                Button("Copy from yesterday", systemImage: "doc.on.doc") {
                    model.copyMeal(meal, from: yesterday, to: day)
                }
            }
            if !entries.isEmpty {
                Button("Save as meal", systemImage: "square.and.arrow.down") {
                    savingName = meal.displayName
                    showsSavePrompt = true
                }
            }
        } label: {
            Image(systemName: Icon.more)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(VColor.accentText)
                .frame(width: Size.minTouch, height: Size.minTouch)
                .contentShape(Rectangle())
        }
        .padding(.trailing, -Space.sm)
        .accessibilityLabel("\(meal.displayName) options")
    }
}

/// Open-canvas list row: no system insets, separators or fill.
private struct MealRowStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(VColor.ground)
    }
}

/// A logged food: a thumbnail slot, the name (with a marker for photo
/// estimates) and portion, and the calories on the right.
struct FoodEntryRow: View {
    var entry: FoodEntry

    /// Where the text starts (thumbnail plus spacing), for inset hairlines.
    static let textInset: CGFloat = Size.minTouch + Space.sm

    var body: some View {
        HStack(spacing: Space.sm) {
            FoodThumbnail(source: entry.source)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.name)
                        .font(VFont.body)
                        .foregroundStyle(VColor.textPrimary)
                        .lineLimit(2)
                    if entry.source == .aiScan {
                        Image(systemName: Icon.recommendation)
                            .font(.system(.caption2))
                            .foregroundStyle(VColor.accentText)
                            .accessibilityLabel("Photo estimate")
                    }
                }
                Text(detail)
                    .font(VFont.secondary.monospacedDigit())
                    .foregroundStyle(VColor.textSecondary)
            }
            Spacer(minLength: Space.xs)
            (Text(Format.integer(entry.macros.calories)).font(VFont.data).foregroundStyle(VColor.textPrimary)
                + Text(" kcal").font(VFont.fieldCaption).foregroundStyle(VColor.textSecondary))
                .lineLimit(1)
        }
        .padding(.vertical, Space.sm)
        .frame(minHeight: Size.minTouch)
        .accessibilityElement(children: .combine)
    }

    /// The portion, or the macros for entries without a weight (quick add).
    private var detail: String {
        if let grams = entry.grams { return "\(Format.integer(grams)) g" }
        return "P \(Format.grams(entry.macros.protein))  C \(Format.grams(entry.macros.carbs))  F \(Format.grams(entry.macros.fat))"
    }
}

/// 44 pt rounded slot for a food photo. Until food imagery exists it shows
/// the symbol for how the entry was logged.
struct FoodThumbnail: View {
    var source: FoodEntrySource

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .fill(VColor.quietFill)
            .frame(width: Size.minTouch, height: Size.minTouch)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(VColor.textTertiary)
            }
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch source {
        case .aiScan: Icon.scan
        case .barcode: Icon.barcode
        case .quickAdd: Icon.quickAdd
        case .savedMeal: Icon.meal
        case .search: Icon.nutrition
        }
    }
}

// MARK: - Undo

/// Floating bar after a swipe delete: what was removed and an Undo button.
private struct UndoBar: View {
    var entry: FoodEntry
    var onUndo: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        let shadow = Elevation.floating.shadow
        HStack(spacing: Space.sm) {
            Image(systemName: "trash")
                .foregroundStyle(VColor.textSecondary)
                .accessibilityHidden(true)
            Text("Deleted \(entry.name)")
                .font(VFont.secondaryEmphasized)
                .foregroundStyle(VColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: Space.xs)
            Button("Undo", action: onUndo)
                .buttonStyle(.borderless)
                .font(VFont.secondaryEmphasized)
                .foregroundStyle(VColor.accentText)
                .frame(minWidth: Size.minTouch, minHeight: Size.minTouch)
        }
        .padding(.leading, Space.md)
        .padding(.trailing, Space.xs)
        .background(VColor.surfaceRaised, in: Capsule())
        .shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape, onDismiss)
    }
}

#Preview("Nutrition") {
    NutritionView().environment(AppModel.preview())
}

#Preview("Nutrition · Dark") {
    NutritionView().environment(AppModel.preview(pro: true)).preferredColorScheme(.dark)
}
