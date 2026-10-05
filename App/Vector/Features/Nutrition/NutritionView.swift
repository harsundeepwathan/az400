import SwiftUI
import VectorCore

struct NutritionView: View {
    @Environment(AppModel.self) private var model
    @State private var day: Date = Date()
    @State private var editing: FoodEntry?

    var body: some View {
        let nutrition = model.nutrition(on: day)
        let suggested = MealType.suggested(forHour: model.calendar.component(.hour, from: model.now()))
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    DayPager(day: $day)

                    VStack(alignment: .leading, spacing: Space.md) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(nutrition.caloriesRemaining >= 0 ? "Calories remaining" : "Over target")
                                    .font(VFont.secondary)
                                    .foregroundStyle(VColor.textSecondary)
                                Text(Format.integer(abs(nutrition.caloriesRemaining)))
                                    .font(VFont.metricHero)
                                    .foregroundStyle(nutrition.caloriesRemaining >= 0 ? VColor.textPrimary : VColor.warning)
                                    .contentTransition(.numericText())
                            }
                            Spacer()
                            Text("\(Format.integer(nutrition.consumed.calories)) / \(Format.integer(nutrition.targets.calories)) kcal")
                                .font(VFont.dataSecondary)
                                .foregroundStyle(VColor.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                        HStack(spacing: 0) {
                            MacroRing(title: "Protein", consumed: nutrition.consumed.protein, target: nutrition.targets.protein, unit: "g", tint: VColor.protein)
                                .frame(maxWidth: .infinity)
                            MacroRing(title: "Carbs", consumed: nutrition.consumed.carbs, target: nutrition.targets.carbs, unit: "g", tint: VColor.carbs)
                                .frame(maxWidth: .infinity)
                            MacroRing(title: "Fat", consumed: nutrition.consumed.fat, target: nutrition.targets.fat, unit: "g", tint: VColor.fat)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .card(padding: Space.lg)

                    ScanMealBanner(scansRemaining: model.scansRemaining) {
                        openScanner(suggested)
                    }

                    HStack(spacing: Space.xs) {
                        QuickActionButton(title: "Search", symbol: Icon.search) { model.sheet = .foodSearch(suggested) }
                        QuickActionButton(title: "Barcode", symbol: Icon.barcode) { model.sheet = .barcode(suggested) }
                        QuickActionButton(title: "Quick Add", symbol: Icon.quickAdd) { model.sheet = .quickAdd(suggested) }
                        QuickActionButton(title: "Meals", symbol: Icon.meal) { model.sheet = .savedMeals(suggested) }
                    }

                    ForEach(MealType.allCases) { meal in
                        MealSection(meal: meal, day: day, onEdit: { editing = $0 }, onScan: { openScanner(meal) })
                    }

                    if let insight = model.visibleInsights.first(where: { $0.category == .nutrition && $0.id != model.dailyInsight?.id }) {
                        InsightCard(insight: insight, isLocked: insight.requiresPro && !model.isPro,
                                    onAction: { model.handle($0) }, onUnlock: { model.presentPaywall(.insight) })
                    }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.bottom, Space.xl)
            }
            .screenBackground()
            .navigationTitle("Nutrition")
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
}

/// ‹ Today › with swipe-free arrows (swipes conflict with scrolling).
private struct DayPager: View {
    @Binding var day: Date
    @Environment(AppModel.self) private var model

    var body: some View {
        let calendar = model.calendar
        let isToday = calendar.isDate(day, inSameDayAs: model.now())
        HStack {
            Button { shift(-1) } label: {
                Image(systemName: "chevron.left").frame(width: Size.minTouch, height: Size.minTouch)
            }
            .accessibilityLabel("Previous day")
            Spacer()
            Text(isToday ? "Today" : Format.longDate(day, calendar: calendar))
                .font(VFont.secondaryEmphasized)
                .foregroundStyle(VColor.textPrimary)
                .contentTransition(.interpolate)
            Spacer()
            Button { shift(1) } label: {
                Image(systemName: "chevron.right").frame(width: Size.minTouch, height: Size.minTouch)
            }
            .disabled(isToday)
            .accessibilityLabel("Next day")
        }
        .font(.system(.body, weight: .semibold))
        .foregroundStyle(VColor.accentText)
        .sensoryFeedback(.selection, trigger: day)
    }

    private func shift(_ days: Int) {
        withAnimation(Motion.snappy) {
            day = model.calendar.date(byAdding: .day, value: days, to: day) ?? day
        }
    }
}

/// The prominent camera CTA.
private struct ScanMealBanner: View {
    var scansRemaining: Int?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.md) {
                Image(systemName: Icon.scan)
                    .font(.system(.title2, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scan Meal").font(VFont.headline)
                    Text(subtitle).font(VFont.secondary).opacity(0.85)
                }
                Spacer()
                Image(systemName: Icon.chevron).font(.system(.footnote, weight: .bold))
            }
            .foregroundStyle(VColor.textOnAccent)
            .padding(Space.md)
            .background(VColor.accent, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        }
        .buttonStyle(.pressable)
        .accessibilityHint(subtitle)
    }

    private var subtitle: String {
        guard let scansRemaining else { return "Snap a photo, review, done" }
        return scansRemaining == 0 ? "Free scans used this week" : "\(scansRemaining) free \(scansRemaining == 1 ? "scan" : "scans") left this week"
    }
}

/// A meal with its entries, totals, and add actions.
private struct MealSection: View {
    var meal: MealType
    var day: Date
    var onEdit: (FoodEntry) -> Void
    var onScan: () -> Void
    @Environment(AppModel.self) private var model
    @State private var savingName = ""
    @State private var showsSavePrompt = false

    var body: some View {
        let entries = model.entries(on: day, meal: meal)
        let total = entries.reduce(Macros.zero) { $0 + $1.macros }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.sm) {
                Image(systemName: meal.symbol)
                    .foregroundStyle(VColor.textSecondary)
                    .frame(width: 22)
                Text(meal.displayName)
                    .font(VFont.headline)
                    .foregroundStyle(VColor.textPrimary)
                Spacer()
                if !entries.isEmpty {
                    Text("\(Format.integer(total.calories)) kcal")
                        .font(VFont.secondaryEmphasized.monospacedDigit())
                        .foregroundStyle(VColor.textPrimary)
                }
                Menu {
                    Button("Search Food", systemImage: Icon.search) { model.sheet = .foodSearch(meal) }
                    Button("Scan Meal", systemImage: Icon.scan, action: onScan)
                    Button("Quick Add", systemImage: Icon.quickAdd) { model.sheet = .quickAdd(meal) }
                    Button("Saved Meals", systemImage: Icon.meal) { model.sheet = .savedMeals(meal) }
                    if let yesterday = model.calendar.date(byAdding: .day, value: -1, to: day),
                       !model.entries(on: yesterday, meal: meal).isEmpty {
                        Button("Copy from Yesterday", systemImage: "doc.on.doc") {
                            model.copyMeal(meal, from: yesterday, to: day)
                        }
                    }
                    if !entries.isEmpty {
                        Button("Save as Meal", systemImage: "square.and.arrow.down") {
                            savingName = meal.displayName
                            showsSavePrompt = true
                        }
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(.title3))
                        .foregroundStyle(VColor.accentText)
                        .frame(width: Size.minTouch, height: Size.minTouch)
                }
                .accessibilityLabel("Add to \(meal.displayName)")
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.xxs)

            if entries.isEmpty {
                Button {
                    model.sheet = .foodSearch(meal)
                } label: {
                    Text("Add \(meal.displayName.lowercased())")
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: Size.minTouch, alignment: .leading)
                        .padding(.horizontal, Space.md)
                }
                .buttonStyle(.plain)
                .padding(.bottom, Space.xxs)
            } else {
                Hairline(leading: Space.md)
                ForEach(entries) { entry in
                    FoodEntryRow(entry: entry)
                        .contentShape(Rectangle())
                        .onTapGesture { onEdit(entry) }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { onEdit(entry) }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                withAnimation(Motion.smooth) { model.delete(entry) }
                            }
                        }
                    if entry.id != entries.last?.id { Hairline(leading: Space.md) }
                }
                macroFooter(total)
            }
        }
        .card(padding: 0)
        .alert("Save meal", isPresented: $showsSavePrompt) {
            TextField("Name", text: $savingName)
            Button("Save") { model.saveMeal(named: savingName, entries: entries) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Log these \(entries.count) foods again with one tap.")
        }
    }

    private func macroFooter(_ total: Macros) -> some View {
        HStack(spacing: Space.md) {
            macro("P", total.protein, VColor.protein)
            macro("C", total.carbs, VColor.carbs)
            macro("F", total.fat, VColor.fat)
            Spacer()
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.xs)
        .background(VColor.surfaceSunken.opacity(0.5))
        .accessibilityElement(children: .combine)
    }

    private func macro(_ letter: String, _ value: Double, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text("\(letter) \(Format.grams(value))")
                .font(VFont.caption.monospacedDigit())
                .foregroundStyle(VColor.textSecondary)
        }
    }
}

struct FoodEntryRow: View {
    var entry: FoodEntry

    var body: some View {
        HStack(spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.name)
                        .font(VFont.body)
                        .foregroundStyle(VColor.textPrimary)
                        .lineLimit(1)
                    if entry.source == .aiScan {
                        Image(systemName: Icon.sparkles)
                            .font(.system(.caption2))
                            .foregroundStyle(VColor.accentText)
                            .accessibilityLabel("AI estimate")
                    }
                }
                Text(detail)
                    .font(VFont.caption.monospacedDigit())
                    .foregroundStyle(VColor.textSecondary)
            }
            Spacer()
            Text(Format.integer(entry.macros.calories))
                .font(VFont.data)
                .foregroundStyle(VColor.textPrimary)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let grams = entry.grams.map { Format.grams($0) + " · " } ?? ""
        return grams + "P \(Format.grams(entry.macros.protein))  C \(Format.grams(entry.macros.carbs))  F \(Format.grams(entry.macros.fat))"
    }
}

#Preview {
    NutritionView().environment(AppModel.preview())
}
