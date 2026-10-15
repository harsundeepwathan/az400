import SwiftUI
import KiraCore

/// Recurring commitments, loans and expected income. Loan principal is shown as debt cash
/// outflow, separate from spending categories.
struct CommitmentsView: View {
    @Environment(FinanceStore.self) private var store
    @State private var editingCommitment: Commitment?
    @State private var editingIncome: IncomeSource?
    @State private var showingPayroll = false

    var body: some View {
        List {
            Section {
                ForEach(store.incomes) { income in
                    Button { editingIncome = income } label: {
                        LabeledContent { MoneyText(money: income.expectedNet) } label: {
                            VStack(alignment: .leading) {
                                Text(income.name)
                                Text("\(income.type.displayName) · \(Self.describe(income.recurrence))").font(.caption).foregroundStyle(KiraColor.textSecondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in offsets.map { store.incomes[$0] }.forEach(store.deleteIncome) }
                Button { editingIncome = IncomeSource(name: "", type: .basicSalary, expectedNet: .zero(), recurrence: .monthly(day: 25), startDate: Date()) } label: {
                    Label("Add income", systemImage: "plus")
                }
                Button { showingPayroll = true } label: { Label("Payslip estimator (EPF, SOCSO, EIS)", systemImage: "doc.plaintext") }
            } header: { Text("Income") }

            Section {
                ForEach(store.commitments) { commitment in
                    Button { editingCommitment = commitment } label: { CommitmentRow(commitment: commitment, showAnalytics: store.gate.isAvailable(.debtAnalytics)) }
                        .buttonStyle(.plain)
                }
                .onDelete { offsets in offsets.map { store.commitments[$0] }.forEach(store.deleteCommitment) }
                Button { editingCommitment = Commitment(name: "", type: .rent, amount: .zero(), recurrence: .monthly(day: 1), startDate: Date()) } label: {
                    Label("Add commitment", systemImage: "plus")
                }
            } header: { Text("Commitments") } footer: {
                Text("Loan instalments reduce what you owe. Kira reports them as debt repayments, not spending.")
            }
        }
        .listStyle(.insetGrouped)
        .kiraScreen()
        .navigationTitle("Commitments")
        .sheet(item: $editingCommitment) { commitment in NavigationStack { CommitmentEditorView(commitment: commitment) } }
        .sheet(item: $editingIncome) { income in NavigationStack { IncomeEditorView(income: income) } }
        .sheet(isPresented: $showingPayroll) { NavigationStack { PayrollEstimatorView() } }
    }

    static func describe(_ recurrence: Recurrence) -> String {
        switch recurrence {
        case .monthly(let day): return "Monthly on day \(day)"
        case .weekly(let weekday): return "Weekly on \(Calendar.current.weekdaySymbols[(weekday - 1 + 7) % 7])"
        case .yearly(let month, let day): return "Yearly on \(day) \(Calendar.current.shortMonthSymbols[(month - 1 + 12) % 12])"
        case .everyMonths(let months, let day): return "Every \(months) months on day \(day)"
        case .once(let date): return "Once on \(date.kiraMedium)"
        }
    }
}

private struct CommitmentRow: View {
    let commitment: Commitment
    let showAnalytics: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent { MoneyText(money: commitment.amount) } label: {
                VStack(alignment: .leading) {
                    Text(commitment.name)
                    Text("\(commitment.type.displayName) · \(CommitmentsView.describe(commitment.recurrence))").font(.caption).foregroundStyle(KiraColor.textSecondary)
                }
            }
            if let terms = commitment.debtTerms {
                if showAnalytics {
                    let outstanding = LoanCalculator.outstanding(terms, asOf: Date())
                    let remaining = LoanCalculator.remainingMonths(terms, asOf: Date())
                    Text("Owed ~\(outstanding.formatted) · \(remaining) months left · \(terms.method == .flatRate ? "flat" : "reducing") rate \(NSDecimalNumber(decimal: terms.annualRate * 100).stringValue)%")
                        .font(.caption).foregroundStyle(KiraColor.textSecondary)
                    if terms.statedOutstanding == nil {
                        Text("Estimated from loan terms — enter your lender’s figure for accuracy.").font(.caption2).foregroundStyle(KiraColor.textSecondary)
                    }
                } else {
                    Text("Loan analytics are part of Kira Premium.").font(.caption).foregroundStyle(KiraColor.textSecondary)
                }
            }
        }
    }
}

struct CommitmentEditorView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// One-time seed: edits stay local until Save.
    @State private var commitment: Commitment
    @State private var amountText = ""
    @State private var day = 1
    @State private var isLoan = false
    @State private var principalText = ""
    @State private var rateText = ""
    @State private var tenure = 60
    @State private var method: InterestMethod = .reducingBalance
    @State private var outstandingText = ""
    @State private var error: String?

    init(commitment: Commitment) {
        _commitment = State(initialValue: commitment)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name (e.g. Rent, Myvi loan)", text: $commitment.name)
                Picker("Type", selection: $commitment.type) { ForEach(CommitmentType.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                TextField("Monthly amount (RM)", text: $amountText).keyboardType(.decimalPad)
                Stepper("Due on day \(day)", value: $day, in: 1...31)
                Picker("Paid from", selection: $commitment.accountID) {
                    Text("Not specified").tag(UUID?.none)
                    ForEach(store.activeAccounts) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            if commitment.type.isDebt {
                Section {
                    Toggle("Track loan details", isOn: $isLoan)
                    if isLoan {
                        TextField("Original amount financed (RM)", text: $principalText).keyboardType(.decimalPad)
                        TextField("Interest / profit rate % p.a.", text: $rateText).keyboardType(.decimalPad)
                        Stepper("Tenure: \(tenure) months", value: $tenure, in: 1...420)
                        DatePicker("First instalment", selection: $commitment.startDate, displayedComponents: .date)
                        Picker("Rate type", selection: $method) {
                            Text("Reducing balance").tag(InterestMethod.reducingBalance)
                            Text("Flat rate (hire purchase)").tag(InterestMethod.flatRate)
                        }
                        TextField("Outstanding per lender (optional)", text: $outstandingText).keyboardType(.decimalPad)
                    }
                } footer: {
                    Text("Car financing in Malaysia usually uses a flat rate. Check your loan agreement.")
                }
            }
            if let error { Section { Text(error).foregroundStyle(KiraColor.error) } }
        }
        .kiraScreen()
        .navigationTitle(commitment.name.isEmpty ? "New commitment" : commitment.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            CloseToolbarItem { dismiss() }
            ConfirmToolbarItem(title: "Save", action: save)
        }
        .onAppear(perform: load)
    }

    private func plain(_ money: Money) -> String {
        MoneyFormatter(signStyle: .never, spaceAfterSymbol: false).string(from: money).replacingOccurrences(of: "RM", with: "")
    }

    private func load() {
        if !commitment.amount.isZero { amountText = plain(commitment.amount) }
        if case .monthly(let d) = commitment.recurrence { day = d }
        if let terms = commitment.debtTerms {
            isLoan = true
            principalText = plain(terms.principal)
            rateText = NSDecimalNumber(decimal: terms.annualRate * 100).stringValue
            tenure = terms.tenureMonths
            method = terms.method
            outstandingText = terms.statedOutstanding.map(plain) ?? ""
        }
    }

    private func save() {
        guard !commitment.name.trimmingCharacters(in: .whitespaces).isEmpty else { error = "Give this commitment a name."; return }
        guard let amount = try? AmountParser().parse(amountText).money, !amount.isZero else { error = "Enter the monthly amount."; return }
        commitment.amount = amount
        commitment.recurrence = .monthly(day: day)
        if isLoan && commitment.type.isDebt {
            guard let principal = try? AmountParser().parse(principalText).money,
                  let rate = Decimal(string: rateText.replacingOccurrences(of: "%", with: ""), locale: Locale(identifier: "en_US_POSIX")),
                  rate >= 0, rate < 100 else { error = "Check the loan amount and rate."; return }
            commitment.debtTerms = DebtTerms(principal: principal, annualRate: rate / 100, tenureMonths: tenure, method: method,
                                             startDate: commitment.startDate, statedOutstanding: try? AmountParser().parse(outstandingText).money)
        } else {
            commitment.debtTerms = nil
        }
        store.save(commitment: commitment)
        store.signal(.success)
        dismiss()
    }
}

struct IncomeEditorView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// One-time seed: edits stay local until Save.
    @State private var income: IncomeSource
    @State private var amountText = ""
    @State private var day = 25
    @State private var error: String?

    init(income: IncomeSource) {
        _income = State(initialValue: income)
    }

    var body: some View {
        Form {
            TextField("Name (e.g. Salary)", text: $income.name)
            Picker("Type", selection: $income.type) { ForEach(IncomeType.allCases, id: \.self) { Text($0.displayName).tag($0) } }
            TextField("Amount received after deductions (RM)", text: $amountText).keyboardType(.decimalPad)
            Stepper("Usually arrives on day \(day)", value: $day, in: 1...31)
            Picker("Paid into", selection: $income.accountID) {
                Text("Not specified").tag(UUID?.none)
                ForEach(store.activeAccounts) { Text($0.name).tag(Optional($0.id)) }
            }
            if let error { Text(error).foregroundStyle(KiraColor.error) }
        }
        .kiraScreen()
        .navigationTitle("Income")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            CloseToolbarItem { dismiss() }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard !income.name.isEmpty, let amount = try? AmountParser().parse(amountText).money, !amount.isZero else { error = "Enter a name and amount."; return }
                    income.expectedNet = amount
                    income.recurrence = .monthly(day: day)
                    store.save(income: income)
                    dismiss()
                }
            }
        }
        .onAppear {
            if !income.expectedNet.isZero { amountText = MoneyFormatter(signStyle: .never, spaceAfterSymbol: false).string(from: income.expectedNet).replacingOccurrences(of: "RM", with: "") }
            if case .monthly(let d) = income.recurrence { day = d }
        }
    }
}

/// Advisory payslip estimate. PCB/MTD is entered from the payslip, never computed.
struct PayrollEstimatorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var basicText = ""
    @State private var additionalText = ""
    @State private var pcbText = ""

    var body: some View {
        let rules = StatutoryRuleSet.malaysiaReference2024
        let basic = (try? AmountParser().parse(basicText).money) ?? .zero()
        let additional = (try? AmountParser().parse(additionalText).money) ?? .zero()
        let pcb = try? AmountParser().parse(pcbText).money
        let estimate = PayrollEstimator.estimate(basic: basic, additional: additional, rules: rules, overrides: PayslipOverrides(pcb: pcb))
        Form {
            Section("Monthly pay") {
                TextField("Basic salary (RM)", text: $basicText).keyboardType(.decimalPad)
                TextField("Allowances / additional (RM)", text: $additionalText).keyboardType(.decimalPad)
                TextField("PCB/MTD from your payslip (RM)", text: $pcbText).keyboardType(.decimalPad)
            }
            Section("Estimated deductions") {
                LabeledContent("EPF / KWSP (employee)") { MoneyText(money: estimate.epf) }
                LabeledContent("SOCSO / PERKESO") { MoneyText(money: estimate.socso) }
                LabeledContent("EIS") { MoneyText(money: estimate.eis) }
                LabeledContent("PCB / MTD") { MoneyText(money: estimate.pcb) }
                LabeledContent("Estimated take-home") { MoneyText(money: estimate.net, font: .body.weight(.semibold)) }
            }
            Section {
                NoticeBanner(tone: .caution, text: "Estimate only, using “\(rules.name)”. Official contributions use wage-band tables that change over time. Your payslip is the source of truth.")
                Text(rules.source).font(.caption).foregroundStyle(KiraColor.textSecondary)
            }
        }
        .kiraScreen()
        .navigationTitle("Payslip estimate")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ConfirmToolbarItem { dismiss() } }
    }
}
