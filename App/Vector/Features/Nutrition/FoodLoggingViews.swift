import SwiftUI
import VectorCore

/// Search → pick → portion → add. Recent foods are one tap.
struct FoodSearchView: View {
    var meal: MealType
    var date: Date
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: FoodItem?
    @State private var selectedMeal: MealType
    @State private var remote: RemoteSearchState = .idle

    enum RemoteSearchState: Equatable {
        case idle, loading, loaded([FoodItem]), failed(String)
    }

    init(meal: MealType, date: Date) {
        self.meal = meal
        self.date = date
        _selectedMeal = State(initialValue: meal)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Meal", selection: $selectedMeal) {
                        ForEach(MealType.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if query.isEmpty && !model.favoriteFoods.isEmpty {
                    Section("Favourites") {
                        ForEach(model.favoriteFoods) { food in
                            Button { selected = food } label: { FoodItemRow(food: food) }
                                .swipeActions(edge: .leading) { favoriteAction(food) }
                        }
                    }
                }
                if query.isEmpty && !model.recentFoods.isEmpty {
                    Section("Recent") {
                        ForEach(model.recentFoods) { entry in
                            Button {
                                logAgain(entry)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name).font(VFont.body).foregroundStyle(VColor.textPrimary)
                                        Text(entry.grams.map { Format.grams($0) } ?? "Quick add")
                                            .font(VFont.caption)
                                            .foregroundStyle(VColor.textSecondary)
                                    }
                                    Spacer()
                                    Text("\(Format.integer(entry.macros.calories)) kcal")
                                        .font(VFont.secondary.monospacedDigit())
                                        .foregroundStyle(VColor.textSecondary)
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(VColor.accentText)
                                        .font(.title3)
                                }
                                .frame(minHeight: Size.minTouch)
                            }
                            .accessibilityLabel("Log \(entry.name) again, \(Format.integer(entry.macros.calories)) calories")
                        }
                    }
                }
                let local = model.foods.search(query)
                if !local.isEmpty {
                    Section("Common foods") {
                        ForEach(local.prefix(query.isEmpty ? 40 : 8)) { food in
                            Button {
                                selected = food
                            } label: {
                                FoodItemRow(food: food)
                            }
                            .swipeActions(edge: .leading) { favoriteAction(food) }
                        }
                    }
                }
                if !query.trimmingCharacters(in: .whitespaces).isEmpty, model.remoteFoods != nil {
                    Section {
                        switch remote {
                        case .idle, .loading:
                            ForEach(0..<3, id: \.self) { _ in
                                FoodItemRow(food: FoodItem(id: "placeholder", name: "Loading product name",
                                                           per100g: .zero, servingName: "1 serving", servingGrams: 100))
                                    .skeleton(true)
                            }
                        case .loaded(let items) where items.isEmpty:
                            noMatch
                        case .loaded(let items):
                            ForEach(items) { food in
                                Button {
                                    selected = food
                                } label: {
                                    FoodItemRow(food: food)
                                }
                                .swipeActions(edge: .leading) { favoriteAction(food) }
                            }
                        case .failed(let message):
                            Label(message, systemImage: "wifi.slash")
                                .font(VFont.secondary)
                                .foregroundStyle(VColor.textSecondary)
                        }
                    } header: {
                        Text("Packaged foods")
                    } footer: {
                        Text("From Open Food Facts, a free, crowd-sourced database. Check the label if numbers look off.")
                    }
                } else if local.isEmpty {
                    Section { noMatch }
                }
            }
            .task(id: query) {
                let trimmed = query.trimmingCharacters(in: .whitespaces)
                guard let client = model.remoteFoods, trimmed.count >= 2 else {
                    remote = .idle
                    return
                }
                remote = .loading
                // Debounce typing so we search once the user pauses.
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                do {
                    let items = try await client.search(trimmed, limit: 25)
                    guard !Task.isCancelled else { return }
                    withAnimation(Motion.smooth) { remote = .loaded(items) }
                } catch RemoteFoodError.offline {
                    remote = .failed("You're offline. Common foods and quick add still work.")
                } catch {
                    remote = .failed("Packaged food search is unavailable right now.")
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search foods")
            .navigationTitle("Log Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.sheet = .barcode(selectedMeal) } label: { Image(systemName: Icon.barcode) }
                        .accessibilityLabel("Scan barcode")
                }
            }
            .sheet(item: $selected) { food in
                PortionEditor(food: food, meal: selectedMeal, date: date) { dismiss() }
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private func favoriteAction(_ food: FoodItem) -> some View {
        let isFavorite = model.isFavorite(food: food)
        return Button(isFavorite ? "Unfavourite" : "Favourite", systemImage: isFavorite ? "star.slash" : "star") {
            model.toggleFavorite(food: food)
        }
        .tint(VColor.warning)
    }

    private var noMatch: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("No match for “\(query)”").font(VFont.bodyEmphasized)
            Text("Quick add the calories instead. You can add macros too.")
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary)
            Button("Quick Add") { model.sheet = .quickAdd(selectedMeal) }
                .buttonStyle(.outlinedCapsule)
        }
        .padding(.vertical, Space.xs)
    }

    private func logAgain(_ entry: FoodEntry) {
        model.log([FoodEntry(date: logDate, meal: selectedMeal, name: entry.name, foodID: entry.foodID,
                             grams: entry.grams, macros: entry.macros, source: entry.source == .aiScan ? .search : entry.source)])
        Haptics.light()
    }

    private var logDate: Date {
        model.calendar.isDate(date, inSameDayAs: model.now()) ? model.now() : date
    }
}

struct FoodItemRow: View {
    var food: FoodItem

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(food.name).font(VFont.body).foregroundStyle(VColor.textPrimary).lineLimit(2)
                Text((food.brand.map { $0 + " · " } ?? "") + "\(food.servingName) (\(Format.grams(food.servingGrams))) · P \(Format.grams(food.macros(grams: food.servingGrams).protein))")
                    .font(VFont.caption)
                    .foregroundStyle(VColor.textSecondary)
            }
            Spacer()
            Text("\(Format.integer(food.macros(grams: food.servingGrams).calories)) kcal")
                .font(VFont.secondary.monospacedDigit())
                .foregroundStyle(VColor.textSecondary)
        }
        .frame(minHeight: Size.minTouch)
    }
}

/// Serving selector with live macro preview. Servings and grams stay in sync.
struct PortionEditor: View {
    var food: FoodItem
    var meal: MealType
    var date: Date
    var onLogged: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var grams: Double

    init(food: FoodItem, meal: MealType, date: Date, onLogged: @escaping () -> Void) {
        self.food = food
        self.meal = meal
        self.date = date
        self.onLogged = onLogged
        _grams = State(initialValue: food.servingGrams)
    }

    var body: some View {
        let macros = food.macros(grams: grams)
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.lg) {
                MacroPreview(macros: macros)
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Portion").font(VFont.headline)
                    HStack(spacing: Space.xs) {
                        ForEach([0.5, 1, 1.5, 2], id: \.self) { multiple in
                            Button(multipleLabel(multiple)) {
                                withAnimation(Motion.snappy) { grams = food.servingGrams * multiple }
                            }
                            .buttonStyle(.quietCapsule)
                            .overlay {
                                if abs(grams - food.servingGrams * multiple) < 0.5 {
                                    Capsule().strokeBorder(VColor.accentText, lineWidth: 2)
                                }
                            }
                            .accessibilityAddTraits(abs(grams - food.servingGrams * multiple) < 0.5 ? .isSelected : [])
                        }
                    }
                    GramsField(grams: $grams)
                }
                Spacer()
                Button("Add to \(meal.displayName)") {
                    model.log([FoodEntry(date: model.calendar.isDate(date, inSameDayAs: model.now()) ? model.now() : date,
                                         meal: meal, name: food.name, foodID: food.id, grams: grams,
                                         macros: macros, source: .search)])
                    dismiss()
                    onLogged()
                }
                .buttonStyle(.accentCapsule)
                .disabled(grams <= 0)
            }
            .padding(Space.gutter)
            .navigationTitle(food.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    let isFavorite = model.isFavorite(food: food)
                    Button {
                        model.toggleFavorite(food: food)
                    } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .foregroundStyle(isFavorite ? VColor.warning : VColor.textSecondary)
                            .symbolEffect(.bounce, value: isFavorite)
                    }
                    .accessibilityLabel(isFavorite ? "Remove from favourites" : "Add to favourites")
                }
            }
        }
    }

    private func multipleLabel(_ multiple: Double) -> String {
        let text = multiple == 0.5 ? "½" : (multiple == 1.5 ? "1½" : "\(Int(multiple))")
        return "\(text) \(food.servingName.replacingOccurrences(of: "1 ", with: ""))"
    }
}

/// Grams input with ±10 g steppers.
struct GramsField: View {
    @Binding var grams: Double

    var body: some View {
        HStack(spacing: Space.xs) {
            Button { grams = max(grams - 10, 0) } label: { Image(systemName: "minus").frame(width: Size.minTouch, height: Size.minTouch) }
                .buttonStyle(.quietCapsule)
                .frame(width: 56)
                .accessibilityLabel("Minus 10 grams")
            HStack(spacing: 4) {
                TextField("0", value: $grams, format: .number.precision(.fractionLength(0)))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(VFont.metricSmall)
                Text("g").font(VFont.secondary).foregroundStyle(VColor.textSecondary)
            }
            .padding(.horizontal, Space.md)
            .frame(maxWidth: .infinity, minHeight: Size.minTouch)
            .background(VColor.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Grams")
            Button { grams += 10 } label: { Image(systemName: "plus").frame(width: Size.minTouch, height: Size.minTouch) }
                .buttonStyle(.quietCapsule)
                .frame(width: 56)
                .accessibilityLabel("Plus 10 grams")
        }
        .sensoryFeedback(.selection, trigger: grams)
    }
}

struct MacroPreview: View {
    var macros: Macros

    var body: some View {
        HStack(spacing: 0) {
            item("Calories", Format.integer(macros.calories), nil)
            item("Protein", Format.grams(macros.protein), VColor.protein)
            item("Carbs", Format.grams(macros.carbs), VColor.carbs)
            item("Fat", Format.grams(macros.fat), VColor.fat)
        }
        .padding(.vertical, Space.sm)
        .background(VColor.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    private func item(_ title: String, _ value: String, _ tint: Color?) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(VFont.metricSmall)
                .foregroundStyle(VColor.textPrimary)
                .contentTransition(.numericText())
            HStack(spacing: 4) {
                if let tint { Circle().fill(tint).frame(width: 6, height: 6) }
                Text(title).font(VFont.caption).foregroundStyle(VColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Calories (and optionally macros) without a database lookup.
struct QuickAddView: View {
    var meal: MealType
    var date: Date
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var calories: Double?
    @State private var protein: Double?
    @State private var carbs: Double?
    @State private var fat: Double?
    @State private var selectedMeal: MealType
    @FocusState private var focused: Bool

    init(meal: MealType, date: Date) {
        self.meal = meal
        self.date = date
        _selectedMeal = State(initialValue: meal)
    }

    private var macroCalories: Double { (protein ?? 0) * 4 + (carbs ?? 0) * 4 + (fat ?? 0) * 9 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Meal", selection: $selectedMeal) {
                        ForEach(MealType.allCases) { Text($0.displayName).tag($0) }
                    }
                    TextField("Name (optional)", text: $name)
                }
                Section {
                    numberRow("Calories", value: $calories, unit: "kcal")
                        .focused($focused)
                } footer: {
                    if calories == nil, macroCalories > 0 {
                        Text("Calories will be calculated from macros: \(Format.integer(macroCalories)) kcal.")
                    }
                }
                Section("Macros (optional)") {
                    numberRow("Protein", value: $protein, unit: "g")
                    numberRow("Carbs", value: $carbs, unit: "g")
                    numberRow("Fat", value: $fat, unit: "g")
                }
            }
            .navigationTitle("Quick Add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let kcal = calories ?? macroCalories
                        model.log([FoodEntry(date: model.calendar.isDate(date, inSameDayAs: model.now()) ? model.now() : date,
                                             meal: selectedMeal, name: name.isEmpty ? "Quick add" : name,
                                             macros: Macros(calories: kcal, protein: protein ?? 0, carbs: carbs ?? 0, fat: fat ?? 0),
                                             source: .quickAdd)])
                        dismiss()
                    }
                    .disabled((calories ?? macroCalories) <= 0)
                }
            }
            .onAppear { focused = true }
        }
    }

    private func numberRow(_ title: String, value: Binding<Double?>, unit: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: value, format: .number.precision(.fractionLength(0...1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(VFont.data)
                .frame(maxWidth: 120)
            Text(unit).foregroundStyle(VColor.textSecondary)
        }
    }
}

/// Edit or delete a logged entry. Grams rescale nutrition proportionally.
struct FoodEntryEditor: View {
    @State var entry: FoodEntry
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var grams: Double = 0
    private let original: FoodEntry

    init(entry: FoodEntry) {
        _entry = State(initialValue: entry)
        _grams = State(initialValue: entry.grams ?? 0)
        original = entry
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.lg) {
                MacroPreview(macros: entry.macros)
                Picker("Meal", selection: $entry.meal) {
                    ForEach(MealType.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                if original.grams != nil {
                    GramsField(grams: $grams)
                        .onChange(of: grams) { _, value in
                            guard let base = original.grams, base > 0 else { return }
                            entry.grams = value
                            entry.macros = original.macros.scaled(by: value / base)
                        }
                }
                Spacer()
                HStack(spacing: Space.sm) {
                    Button(role: .destructive) {
                        model.delete(original)
                        dismiss()
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .font(VFont.bodyEmphasized)
                            .foregroundStyle(VColor.danger)
                            .frame(maxWidth: .infinity, minHeight: Size.buttonHeight)
                            .background(VColor.dangerSoft, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                    Button("Save") {
                        model.update(entry)
                        dismiss()
                    }
                    .buttonStyle(.accentCapsule)
                }
            }
            .padding(Space.gutter)
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct SavedMealsView: View {
    var meal: MealType
    var date: Date
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.savedMeals.isEmpty {
                    ContentUnavailableView {
                        Label("No saved meals yet", systemImage: Icon.meal)
                    } description: {
                        Text("Log a meal you eat often, then choose “Save as Meal” from its + menu to log it in one tap next time.")
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(model.savedMeals) { saved in
                    Button {
                        let logDate = model.calendar.isDate(date, inSameDayAs: model.now()) ? model.now() : date
                        model.log(saved.items.map {
                            FoodEntry(date: logDate, meal: meal, name: $0.name, foodID: $0.foodID, grams: $0.grams,
                                      macros: $0.macros, source: .savedMeal)
                        })
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(saved.name).font(VFont.bodyEmphasized).foregroundStyle(VColor.textPrimary)
                                Text(saved.items.map(\.name).joined(separator: ", "))
                                    .font(VFont.caption)
                                    .foregroundStyle(VColor.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text("\(Format.integer(saved.macros.calories)) kcal")
                                .font(VFont.secondary.monospacedDigit())
                                .foregroundStyle(VColor.textSecondary)
                        }
                    }
                }
                .onDelete { offsets in offsets.map { model.savedMeals[$0] }.forEach(model.deleteSavedMeal) }
            }
            .navigationTitle("Saved Meals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

struct BodyWeightEntryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var value: Double = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: Space.lg) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    TextField("0", value: $value, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.center)
                        .font(VFont.metricHero)
                        .fixedSize()
                    Text(model.unit.symbol).font(VFont.title3).foregroundStyle(VColor.textSecondary)
                }
                HStack(spacing: Space.xs) {
                    ForEach([-0.5, -0.1, 0.1, 0.5], id: \.self) { step in
                        Button(step > 0 ? "+\(step.formatted())" : "\u{2212}\(abs(step).formatted())") { value = max(value + step, 0) }
                            .buttonStyle(.quietCapsule)
                    }
                }
                Button("Save weigh-in") {
                    model.logBodyWeight(model.unit.toKilograms(value))
                    dismiss()
                }
                .buttonStyle(.accentCapsule)
            }
            .padding(Space.gutter)
            .navigationTitle("Body Weight")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                value = model.unit.fromKilograms(model.latestBodyWeight?.kilograms ?? model.profile?.weightKg ?? 70)
                value = (value * 10).rounded() / 10
            }
        }
    }
}
