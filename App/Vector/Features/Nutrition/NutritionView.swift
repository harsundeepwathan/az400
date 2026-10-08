import SwiftUI
import UIKit
import VectorCore

/// Nutrition (widgets): the large title, add menu and day pager on the
/// canvas; a Calories tile (ring, kcal left, macro bars, protein to go); a
/// Log food tile (Scan meal with an honest caption, then search, barcode and
/// quick add); then each meal as its own tile. The screen is a plain `List`
/// so food rows keep native swipe-to-delete; deleting offers Undo.
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
                    .canvasListRow()

                TileGap()
                LoggingActions(scansRemaining: model.scansRemaining, suggested: suggested,
                               onScan: { openScanner(suggested) })
                    .canvasListRow()

                ForEach(MealType.allCases) { meal in
                    MealSection(meal: meal, day: day,
                                onEdit: { editing = $0 },
                                onDelete: delete,
                                onScan: { openScanner(meal) })
                }

                if let insight = model.visibleInsights.first(where: { $0.category == .nutrition && $0.id != model.dailyInsight?.id }) {
                    InsightCard(insight: insight, isLocked: insight.requiresPro && !model.isPro,
                                onAction: { model.handle($0) }, onUnlock: { model.presentPaywall(.insight) })
                        .padding(.top, Space.sm)
                        .canvasListRow()
                }

                TileGap(height: Space.lg)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .background(WColor.canvas.ignoresSafeArea())
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
            WidgetScreenHeader(title: "Nutrition") { addMenu }
            DayPager(day: $day)
                .padding(.horizontal, 4)
                .padding(.bottom, Space.xs)

            WidgetTile(tint: .calories, title: "Calories", symbol: "flame.fill") {
                HStack(alignment: .center, spacing: Space.md) {
                    ZStack {
                        GradientRing(progress: nutrition.calorieProgress, lineWidth: 12,
                                     colors: [WidgetTint.calories.accent, WidgetTint.calories.accentEnd])
                        VStack(spacing: 0) {
                            Text(Format.integer(abs(remaining)))
                                .font(.system(size: heroSize * 0.55, weight: .bold).monospacedDigit())
                                .foregroundStyle(WColor.textPrimary)
                                .contentTransition(.numericText())
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            if remaining < 0 {
                                Label("over", systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(VColor.warning)
                            } else {
                                Text("kcal left").font(.footnote).foregroundStyle(WColor.textSecondary)
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                    .frame(width: 132, height: 132)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Calories")
                    .accessibilityValue("\(Format.integer(abs(remaining))) \(remaining >= 0 ? "left" : "over"), "
                                        + "\(Format.integer(nutrition.consumed.calories)) eaten of \(Format.integer(nutrition.targets.calories))")

                    VStack(alignment: .leading, spacing: 4) {
                        Text(Format.integer(nutrition.consumed.calories))
                            .font(.system(.title, weight: .bold).monospacedDigit())
                            .foregroundStyle(WColor.textPrimary)
                        Text("eaten of \(Format.integer(nutrition.targets.calories)) kcal")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(WColor.textSecondary)
                        proteinLine(toGo: proteinToGo, isToday: isToday)
                            .padding(.top, Space.xs)
                    }
                    .accessibilityElement(children: .combine)
                }
                .padding(.top, Space.sm)

                VStack(spacing: 14) {
                    WidgetBar(title: "Protein", value: nutrition.consumed.protein, target: nutrition.targets.protein, unit: "g", color: WColor.protein)
                    WidgetBar(title: "Carbs", value: nutrition.consumed.carbs, target: nutrition.targets.carbs, unit: "g", color: WColor.carbs)
                    WidgetBar(title: "Fat", value: nutrition.consumed.fat, target: nutrition.targets.fat, unit: "g", color: WColor.fat)
                }
                .padding(.top, Space.md)
            }
        }
    }

    @ViewBuilder private func proteinLine(toGo: Double, isToday: Bool) -> some View {
        if toGo > 0 {
            (Text("\(Format.integer(toGo)) g protein").font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(WColor.protein)
                + Text(isToday ? " to go today" : " under target").font(.subheadline).foregroundStyle(WColor.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Label("Protein target met", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(WColor.protein)
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
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(WColor.textPrimary)
                .frame(width: 38, height: 38)
                .background(WColor.innerStrong, in: Circle())
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
        WidgetTile(tint: .calories, title: "Log food", symbol: "plus.circle.fill") {
            VStack(spacing: Space.sm) {
                Button(action: onScan) {
                    Label("Scan meal", systemImage: Icon.scan)
                }
                .buttonStyle(.widgetPrimary)
                .accessibilityHint(caption)

                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(WColor.textSecondary)
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
                .padding(.top, Space.xxs)
            }
            .padding(.top, Space.sm)
        }
    }

    @ViewBuilder private var quietActions: some View {
        Button { model.sheet = .foodSearch(suggested) } label: { Label("Search", systemImage: Icon.search) }
            .buttonStyle(.widgetSecondary)
        Button { model.sheet = .barcode(suggested) } label: { Label("Barcode", systemImage: Icon.barcode) }
            .buttonStyle(.widgetSecondary)
        Button { model.sheet = .quickAdd(suggested) } label: { Label("Quick add", systemImage: Icon.add) }
            .buttonStyle(.widgetSecondary)
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
            TileGap()
            header(entries: entries, total: total)
                .padding(.horizontal, Space.fieldInset)
                .padding(.top, Space.md)
                .padding(.bottom, Space.xxs)
                .tileRow(.first)
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
                .padding(.bottom, Space.xs)
                .tileRow(.last)
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
                    .padding(.bottom, entry.id == entries.last?.id ? Space.xs : 0)
                    .tileRow(entry.id == entries.last?.id ? .last : .middle)
                }
            }
        }
    }

    private func header(entries: [FoodEntry], total: Macros) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Text(meal.displayName)
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(WColor.textPrimary)
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
