import SwiftUI
import VectorCore

/// Review & correct. Portion estimates from photos are the least reliable
/// part of AI calorie tracking, so every correction here is one or two
/// taps: nudge grams, pick an alternative, remove, or add what was missed.
struct ScanReviewView: View {
    @Bindable var session: MealScanSession
    var onClose: () -> Void
    @Environment(AppModel.self) private var model
    @State private var changingItem: RecognizedFood?
    @State private var showsAddFood = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    header
                    disclaimer

                    VStack(spacing: Space.sm) {
                        ForEach(session.items) { item in
                            RecognizedFoodRow(
                                item: item,
                                unit: "g",
                                onGrams: { session.setGrams($0, for: item.id) },
                                onChange: { changingItem = item },
                                onRemove: { session.remove(item.id) }
                            )
                            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                    removal: .opacity.combined(with: .scale(scale: 0.95))))
                        }
                        Button {
                            showsAddFood = true
                        } label: {
                            Label("Add missing food", systemImage: "plus")
                                .font(VFont.secondaryEmphasized)
                                .frame(maxWidth: .infinity, minHeight: Size.minTouch)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(VColor.accentText)
                        .background {
                            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                .strokeBorder(VColor.separator, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        }
                    }

                    totals

                    Picker("Meal", selection: $session.meal) {
                        ForEach(MealType.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.horizontal, Space.gutter)
                .padding(.bottom, 120)
                .animation(Motion.smooth, value: session.items)
            }
            .screenBackground()
            .navigationTitle("Review Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose) }
                ToolbarItem(placement: .primaryAction) { Button("Retake") { session.retake() } }
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryButton("Add Meal · \(Format.integer(session.total.calories)) kcal") { addMeal() }
                    .disabled(session.items.isEmpty)
                    .padding(.horizontal, Space.gutter)
                    .padding(.vertical, Space.sm)
                    .background(.bar)
            }
            .sheet(item: $changingItem) { item in
                ChangeFoodView(item: item) { food in session.replaceFood(food, for: item.id) }
            }
            .sheet(isPresented: $showsAddFood) {
                FoodPickerView { session.add($0) }
            }
            .sensoryFeedback(.success, trigger: session.phase == .review)
        }
    }

    private var header: some View {
        HStack(spacing: Space.md) {
            if let image = session.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(session.items.count) \(session.items.count == 1 ? "item" : "items") found")
                    .font(VFont.headline)
                    .foregroundStyle(VColor.textPrimary)
                Text("Tap a name to correct it, adjust grams to match your portion.")
                    .font(VFont.secondary)
                    .foregroundStyle(VColor.textSecondary)
            }
        }
        .padding(.top, Space.sm)
    }

    private var disclaimer: some View {
        Label {
            Text("AI estimate. Review portions for better accuracy.")
                .font(VFont.secondaryEmphasized)
        } icon: {
            Image(systemName: Icon.sparkles)
        }
        .foregroundStyle(VColor.accentText)
        .padding(Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VColor.accentSoft, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }

    private var totals: some View {
        let total = session.total
        return VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Estimated total").font(VFont.secondary).foregroundStyle(VColor.textSecondary)
                Spacer()
                Text("~\(Format.integer(total.calories)) kcal")
                    .font(VFont.metric)
                    .foregroundStyle(VColor.textPrimary)
                    .contentTransition(.numericText())
            }
            HStack(spacing: 0) {
                macro("Protein", total.protein, VColor.protein)
                macro("Carbs", total.carbs, VColor.carbs)
                macro("Fat", total.fat, VColor.fat)
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }

    private func macro(_ title: String, _ value: Double, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title).font(VFont.caption).foregroundStyle(VColor.textSecondary)
            }
            Text(Format.grams(value))
                .font(VFont.metricSmall)
                .foregroundStyle(VColor.textPrimary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addMeal() {
        let date = model.now()
        model.log(session.items.map {
            FoodEntry(date: date, meal: session.meal, name: $0.food.name, foodID: $0.food.id,
                      grams: $0.grams, macros: $0.macros, source: .aiScan)
        })
        onClose()
    }
}

private struct RecognizedFoodRow: View {
    var item: RecognizedFood
    var unit: String
    var onGrams: (Double) -> Void
    var onChange: () -> Void
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .top) {
                Button(action: onChange) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(item.food.name)
                                .font(VFont.bodyEmphasized)
                                .foregroundStyle(VColor.textPrimary)
                                .multilineTextAlignment(.leading)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(.caption2, weight: .semibold))
                                .foregroundStyle(VColor.textTertiary)
                        }
                        if item.isLowConfidence {
                            Label("Not sure. Please check", systemImage: "questionmark.circle")
                                .font(VFont.captionEmphasized)
                                .foregroundStyle(VColor.warning)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Change food")
                Spacer()
                Text("\(Format.integer(item.macros.calories)) kcal")
                    .font(VFont.data)
                    .foregroundStyle(VColor.textPrimary)
                    .contentTransition(.numericText())
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(.title3))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(VColor.textTertiary)
                        .frame(width: Size.minTouch, height: Size.minTouch)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(item.food.name)")
            }

            HStack(spacing: Space.xs) {
                stepButton(-25)
                Text("~\(Format.integer(item.grams))\(unit)")
                    .font(VFont.secondaryEmphasized.monospacedDigit())
                    .foregroundStyle(VColor.textPrimary)
                    .frame(maxWidth: .infinity)
                    .contentTransition(.numericText())
                    .accessibilityLabel("About \(Format.integer(item.grams)) grams")
                stepButton(25)
            }
            Slider(value: Binding(get: { item.grams }, set: { onGrams(($0 / 5).rounded() * 5) }),
                   in: 0...max(item.grams * 2.5, 300))
                .tint(VColor.accent)
                .accessibilityLabel("Portion size")
                .accessibilityValue("\(Format.integer(item.grams)) grams")
        }
        .card()
        .sensoryFeedback(.selection, trigger: Int(item.grams / 25))
    }

    private func stepButton(_ delta: Double) -> some View {
        Button {
            onGrams(item.grams + delta)
        } label: {
            Text(delta > 0 ? "+\(Int(delta))g" : "\u{2212}\(Int(abs(delta)))g")
                .font(VFont.secondaryEmphasized.monospacedDigit())
                .frame(width: 72, height: Size.minTouch)
                .background(VColor.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(VColor.textPrimary)
    }
}

/// Alternatives the model considered first, then full search.
private struct ChangeFoodView: View {
    var item: RecognizedFood
    var onPick: (FoodItem) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty && !item.alternatives.isEmpty {
                    Section("Did you mean") {
                        ForEach(item.alternatives) { food in
                            Button { pick(food) } label: { FoodItemRow(food: food) }
                        }
                    }
                }
                Section(query.isEmpty ? "All foods" : "Results") {
                    ForEach(model.foods.search(query).prefix(40)) { food in
                        Button { pick(food) } label: { FoodItemRow(food: food) }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search foods")
            .navigationTitle("Change \(item.food.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func pick(_ food: FoodItem) {
        onPick(food)
        dismiss()
    }
}

/// Plain food picker returning a FoodItem.
struct FoodPickerView: View {
    var onPick: (FoodItem) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(model.foods.search(query).prefix(50)) { food in
                Button {
                    onPick(food)
                    dismiss()
                } label: { FoodItemRow(food: food) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search foods")
            .navigationTitle("Add Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
