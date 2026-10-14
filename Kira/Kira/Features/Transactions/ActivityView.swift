import SwiftUI
import KiraCore

/// Full transaction history with search, filters and a review queue.
struct ActivityView: View {
    @Environment(FinanceStore.self) private var store
    @State private var query = ""
    @State private var filter = TransactionFilter()
    @State private var showingFilters = false
    @State private var segment: Segment = .all
    @State private var selected: TransactionRecord?

    enum Segment: String, CaseIterable, Identifiable {
        case all = "All", review = "To review"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Show", selection: $segment) {
                    ForEach(Segment.allCases) { Text(segmentTitle($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                if hasActiveFilter {
                    Section {
                        let summary = store.ledger.summarize(filtered, filter: TransactionFilter())
                        LabeledContent("Spending in view") { MoneyText(money: summary.netSpending, font: .body.weight(.semibold)) }
                        if summary.income.minorUnits > 0 {
                            LabeledContent("Income in view") { MoneyText(money: summary.income) }
                        }
                        Button("Clear filters", role: .destructive) { filter = TransactionFilter(); query = "" }
                    }
                }

                if filtered.isEmpty {
                    Section {
                        EmptyStateView(symbol: segment == .review ? "checkmark.circle" : "magnifyingglass",
                                       title: segment == .review ? "Nothing to review" : "No transactions",
                                       message: segment == .review ? "Pending payments and uncertain imports will appear here." : "Try a different search or filter.")
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(grouped, id: \.day) { group in
                        Section {
                            ForEach(group.records) { record in
                                Button { selected = record } label: { TransactionRow(record: record) }
                                    .buttonStyle(.plain)
                                    .swipeActions(edge: .trailing) {
                                        Button("Delete", role: .destructive) { store.delete([record.id]) }
                                    }
                                    .swipeActions(edge: .leading) {
                                        if record.status == .pending || record.status == .draft {
                                            Button("Confirm") { store.confirm(record) }.tint(KiraColor.accent)
                                        }
                                    }
                            }
                        } header: {
                            Text(group.day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .kiraScreen()
            .navigationTitle("Activity")
            .kiraAddMenu()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingFilters = true } label: {
                        Image(systemName: hasActiveFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Filters")
                }
            }
            .sheet(isPresented: $showingFilters) { FilterSheet(filter: $filter) }
            .sheet(item: $selected) { record in NavigationStack { TransactionDetailView(transactionID: record.id) } }
        }
    }

    private func segmentTitle(_ segment: Segment) -> String {
        segment == .review && !store.needsReview.isEmpty ? "To review (\(store.needsReview.count))" : segment.rawValue
    }

    private var hasActiveFilter: Bool { filter != TransactionFilter() || !query.isEmpty }

    private var filtered: [TransactionRecord] {
        var effective = filter
        effective.merchantQuery = query.isEmpty ? nil : query
        let base = segment == .review ? store.needsReview : store.visibleTransactions
        return base.filter(effective.matches)
    }

    private var grouped: [(day: Date, records: [TransactionRecord])] {
        let calendar = KLCalendar.shared
        let groups = Dictionary(grouping: filtered) { calendar.startOfDay($0.transactionDate) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.transactionDate > $1.transactionDate }) }
    }
}

/// Filters by date range, account, category, payment source and status.
struct FilterSheet: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var filter: TransactionFilter
    @State private var range: RangeOption = .any
    @State private var customStart = Date()
    @State private var customEnd = Date()

    enum RangeOption: String, CaseIterable, Identifiable {
        case any = "Any time", thisMonth = "This month", lastMonth = "Last month", last90 = "Last 90 days", custom = "Custom"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Date") {
                    Picker("Range", selection: $range) { ForEach(RangeOption.allCases) { Text($0.rawValue).tag($0) } }
                    if range == .custom {
                        DatePicker("From", selection: $customStart, displayedComponents: .date)
                        DatePicker("To", selection: $customEnd, in: customStart..., displayedComponents: .date)
                    }
                }
                Section("Account") {
                    multiSelect(store.activeAccounts.map { ($0.id, $0.name) }, selection: Binding(get: { filter.accountIDs }, set: { filter.accountIDs = $0 }))
                }
                Section("Category") {
                    multiSelect(store.categories.map { ($0.id, $0.name) }, selection: Binding(get: { filter.categoryIDs }, set: { filter.categoryIDs = $0 }))
                }
                Section("Payment source") {
                    multiSelect(PaymentChannel.allCases.map { ($0, $0.displayName) }, selection: Binding(get: { filter.channels }, set: { filter.channels = $0 }))
                }
                Section("Status") {
                    multiSelect(TransactionStatus.allCases.filter { $0 != .superseded }.map { ($0, $0.displayName) },
                                selection: Binding(get: { filter.statuses }, set: { filter.statuses = $0 }))
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Reset") { filter = TransactionFilter(); range = .any } }
                ConfirmToolbarItem { applyRange(); dismiss() }
            }
        }
        .presentationDetents([.large])
    }

    private func applyRange() {
        let calendar = KLCalendar.shared
        let now = store.now()
        switch range {
        case .any: filter.dateInterval = nil
        case .thisMonth: filter.dateInterval = calendar.monthInterval(containing: now)
        case .lastMonth: filter.dateInterval = calendar.previousMonthInterval(before: now)
        case .last90: filter.dateInterval = DateInterval(start: calendar.addingDays(-90, to: calendar.startOfDay(now)), end: calendar.addingDays(1, to: calendar.startOfDay(now)))
        case .custom:
            filter.dateInterval = DateInterval(start: calendar.startOfDay(customStart), end: calendar.addingDays(1, to: calendar.startOfDay(max(customEnd, customStart))))
        }
    }

    /// nil selection = no filter on that dimension.
    private func multiSelect<ID: Hashable>(_ options: [(ID, String)], selection: Binding<Set<ID>?>) -> some View {
        ForEach(options, id: \.0) { option in
            let isOn = selection.wrappedValue?.contains(option.0) ?? false
            Button {
                var set = selection.wrappedValue ?? []
                if isOn { set.remove(option.0) } else { set.insert(option.0) }
                selection.wrappedValue = set.isEmpty ? nil : set
                Haptics.selection()
            } label: {
                HStack {
                    Text(option.1).foregroundStyle(KiraColor.textPrimary)
                    Spacer()
                    if isOn { Image(systemName: "checkmark").foregroundStyle(KiraColor.accent) }
                }
            }
            .accessibilityAddTraits(isOn ? .isSelected : [])
        }
    }
}
