import SwiftUI
import KiraCore

/// Search tab (HIG › Search fields: standard search tab with a landing page). Shows frequent
/// merchants as suggestions before typing, searches as people type, and lets them narrow
/// results with a scope bar.
struct SearchView: View {
    @Environment(FinanceStore.self) private var store
    @State private var query = ""
    @State private var scope: Scope = .all
    @State private var selected: TransactionRecord?

    enum Scope: String, CaseIterable, Identifiable {
        case all = "All", spending = "Spending", income = "Money In"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    suggestions
                } else if results.isEmpty {
                    if #available(iOS 17.0, *) {
                        ContentUnavailableView.search(text: query)
                    }
                } else {
                    Section {
                        let summary = store.ledger.summarize(results, filter: TransactionFilter())
                        LabeledContent("Spent") { MoneyText(money: summary.netSpending, font: .body.weight(.semibold)) }
                        LabeledContent("Matching transactions", value: "\(results.count)")
                    }
                    Section("Results") {
                        ForEach(results) { record in
                            Button { selected = record } label: { TransactionRow(record: record) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Merchants, notes, references")
            .searchScopes($scope) {
                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .sheet(item: $selected) { record in NavigationStack { TransactionDetailView(transactionID: record.id) } }
        }
    }

    @ViewBuilder
    private var suggestions: some View {
        let merchants = AnalyticsEngine(ledger: store.ledger)
            .topMerchants(store.transactions, filter: TransactionFilter(dateInterval: DateInterval(start: KLCalendar.shared.addingDays(-90, to: store.now()), end: store.now())), limit: 6)
        if merchants.isEmpty {
            Text("Search by merchant, description, note or reference number.").foregroundStyle(.secondary)
        } else {
            Section("Frequent merchants") {
                ForEach(merchants) { merchant in
                    Button { query = merchant.displayName } label: {
                        Label { Text(merchant.displayName).foregroundStyle(.primary) } icon: { Image(systemName: "magnifyingglass") }
                    }
                }
            }
        }
    }

    private var results: [TransactionRecord] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        return store.visibleTransactions.filter { record in
            switch scope {
            case .all: break
            case .spending: guard record.direction == .outflow && (record.kind == .expense || record.kind == .fee) else { return false }
            case .income: guard record.direction == .inflow else { return false }
            }
            let haystack = [record.merchant, record.transactionDescription, record.notes, record.externalReference].compactMap { $0 }.joined(separator: " ")
            return haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
