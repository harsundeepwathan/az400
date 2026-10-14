import SwiftUI
import KiraCore

/// Visual budget editor: slider for quick adjustment plus exact amount entry.
struct BudgetEditorView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var totalText = ""
    @State private var rollover: RolloverPolicy = .none
    @State private var allocations: [String: Double] = [:]
    @State private var addingCategory = false
    @State private var error: String?

    private let sliderMax: Double = 5_000

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("RM").foregroundStyle(KiraColor.textSecondary)
                    TextField("5,000", text: $totalText).keyboardType(.decimalPad).font(.kiraFigure).monospacedDigit()
                }
                Picker("Rollover", selection: $rollover) { ForEach(RolloverPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                if let error { Text(error).font(.footnote).foregroundStyle(KiraColor.error) }
            } header: {
                Text("Monthly budget")
            } footer: {
                Text("Transfers, card repayments, e-wallet top-ups and loan principal don’t count against your budget.")
            }

            Section {
                ForEach(allocations.keys.sorted(), id: \.self) { categoryID in
                    VStack(alignment: .leading) {
                        HStack {
                            Label(store.category(categoryID)?.name ?? "Category", systemImage: store.category(categoryID)?.symbol ?? "circle")
                            Spacer()
                            TextField("0", value: Binding(get: { allocations[categoryID] ?? 0 }, set: { allocations[categoryID] = max(0, $0.rounded()) }),
                                      format: .number.precision(.fractionLength(0)))
                                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90).monospacedDigit()
                        }
                        Slider(value: Binding(get: { allocations[categoryID] ?? 0 }, set: { allocations[categoryID] = ($0 / 10).rounded() * 10 }),
                               in: 0...max(sliderMax, allocations[categoryID] ?? 0), step: 10)
                            .accessibilityLabel("\(store.category(categoryID)?.name ?? "Category") budget")
                    }
                    .swipeActions { Button("Remove", role: .destructive) { allocations[categoryID] = nil } }
                }
                Button { addingCategory = true } label: { Label("Add category budget", systemImage: "plus") }
                if let unallocated = unallocated {
                    LabeledContent("Not allocated") { MoneyText(money: unallocated).foregroundStyle(unallocated.isNegative ? KiraColor.error : KiraColor.textSecondary) }
                }
            } header: {
                Text("By category")
            }
        }
        .kiraScreen()
        .navigationTitle("Budget")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            CloseToolbarItem { dismiss() }
            ConfirmToolbarItem(title: "Save", action: save)
        }
        .confirmationDialog("Add category budget", isPresented: $addingCategory) {
            ForEach(store.categories.filter { allocations[$0.id] == nil && $0.id != BuiltInCategory.transfers.id }) { category in
                Button(category.name) { allocations[category.id] = 0 }
            }
        }
        .onAppear(perform: load)
    }

    private var unallocated: Money? {
        guard let total = try? AmountParser().parse(totalText).money else { return nil }
        let allocated = allocations.values.reduce(0, +)
        return total - (Money(major: Decimal(allocated)) ?? .zero())
    }

    private func load() {
        if let budget = store.monthlyBudget {
            totalText = MoneyFormatter(signStyle: .never, spaceAfterSymbol: false, omitZeroMinorUnits: true).string(from: budget.limit).replacingOccurrences(of: "RM", with: "")
            rollover = budget.rollover
        }
        for budget in store.categoryBudgets where budget.period == .monthly {
            if let id = budget.categoryID { allocations[id] = NSDecimalNumber(decimal: budget.limit.decimalValue).doubleValue }
        }
    }

    private func save() {
        let total: Money
        do {
            total = try AmountParser().parse(totalText).money
        } catch {
            self.error = "Enter a budget amount, e.g. 5000."
            return
        }
        var monthly = store.monthlyBudget ?? Budget(limit: total)
        monthly.limit = total
        monthly.rollover = rollover
        store.save(budget: monthly)

        let existing = Dictionary(store.categoryBudgets.compactMap { budget in budget.categoryID.map { ($0, budget) } }, uniquingKeysWith: { first, _ in first })
        for (categoryID, value) in allocations {
            guard let limit = Money(major: Decimal(Int(value.rounded()))) else { continue }
            var budget = existing[categoryID] ?? Budget(categoryID: categoryID, limit: limit)
            budget.limit = limit
            budget.rollover = rollover
            store.save(budget: budget)
        }
        for (categoryID, budget) in existing where allocations[categoryID] == nil {
            store.deleteBudget(budget)
        }
        store.signal(.success)
        dismiss()
    }
}
