import SwiftUI
import KiraCore

/// Inspect a transaction: amount, status, provenance, review flags, and possible duplicates.
struct TransactionDetailView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let transactionID: UUID
    @State private var editing = false
    @State private var confirmingDelete = false

    var body: some View {
        Group {
            if let record = store.transaction(transactionID) {
                content(record)
            } else {
                EmptyStateView(symbol: "questionmark.circle", title: "Transaction not found", message: "It may have been deleted.")
            }
        }
        .kiraScreen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            CloseToolbarItem { dismiss() }
            ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true }.disabled(store.transaction(transactionID) == nil) }
        }
        .sheet(isPresented: $editing) {
            if let record = store.transaction(transactionID) {
                NavigationStack { TransactionEditorView(mode: .edit(record)) }
            }
        }
    }

    private func content(_ record: TransactionRecord) -> some View {
        List {
            Section {
                VStack(spacing: KiraSpacing.s) {
                    CategoryIcon(category: store.category(LedgerCalculator.effectiveCategory(of: record)), size: 56)
                    Text(record.displayName).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                    MoneyText(money: record.signedAmount, style: MoneyFormatter(signStyle: .always), font: .kiraHero)
                        .foregroundStyle(record.direction == .inflow ? KiraColor.accent : KiraColor.textPrimary)
                    StatusBadge(status: record.status)
                    Text(record.transactionDate.formatted(date: .complete, time: .shortened)).font(.footnote).foregroundStyle(KiraColor.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, KiraSpacing.m)
                .listRowBackground(Color.clear)
            }

            if let explanation = statusExplanation(record) {
                Section {
                    NoticeBanner(tone: record.status == .draft ? .caution : .info, text: explanation)
                    if record.status == .draft || record.status == .pending {
                        Button(record.status == .draft ? "I’ve paid — confirm payment" : "Confirm payment") { store.confirm(record) }
                            .disabled(record.flags.contains(.amountMissing))
                        if record.flags.contains(.amountMissing) {
                            Text("Add the amount first (Edit).").font(.footnote).foregroundStyle(KiraColor.textSecondary)
                        }
                    }
                }
                .listRowBackground(KiraColor.surface)
            }

            Section("Details") {
                LabeledContent("Type", value: record.kind.displayName)
                LabeledContent("Category", value: store.category(LedgerCalculator.effectiveCategory(of: record))?.name ?? "Other")
                LabeledContent("Paid with", value: record.channel.displayName)
                if let account = store.account(record.accountID) { LabeledContent("Account", value: account.name) }
                if let posted = record.postingDate { LabeledContent("Posted", value: posted.kiraMedium) }
                if !record.transactionDescription.isEmpty && record.transactionDescription != record.merchant {
                    LabeledContent("Description", value: record.transactionDescription)
                }
                if let reference = record.externalReference { LabeledContent("Reference", value: reference).textSelection(.enabled) }
                if let notes = record.notes { LabeledContent("Notes", value: notes) }
            }
            .listRowBackground(KiraColor.surface)

            Section("Source") {
                LabeledContent("Recorded from", value: record.source.displayName)
                LabeledContent("Confidence", value: PercentFormatter.string(record.confidence))
                if record.kind.isInternalMovement || record.kind == .debtRepayment {
                    Text("Not counted as spending — it moves money between your accounts or pays down a loan.")
                        .font(.footnote).foregroundStyle(KiraColor.textSecondary)
                }
            }
            .listRowBackground(KiraColor.surface)

            let candidates = store.duplicateCandidates(for: record)
            if !candidates.isEmpty && record.status != .superseded {
                Section {
                    ForEach(candidates, id: \.0.id) { pair in
                        let (other, candidate) = pair
                        VStack(alignment: .leading, spacing: 6) {
                            TransactionRow(record: other)
                            Text(candidate.reasons.joined(separator: " · ")).font(.caption).foregroundStyle(KiraColor.textSecondary)
                            Button("Same payment — merge") {
                                let keep = other.source.authority >= record.source.authority ? other : record
                                let duplicate = keep.id == other.id ? record : other
                                store.merge(keep: keep, duplicate: duplicate)
                                if duplicate.id == record.id { dismiss() }
                            }
                            .font(.subheadline.weight(.medium))
                        }
                    }
                } header: {
                    Text("Possible duplicates")
                } footer: {
                    Text("Kira never merges look-alike payments on its own. Merge only if these are the same payment.")
                }
                .listRowBackground(KiraColor.surface)
            }

            Section {
                Button("Delete transaction", role: .destructive) { confirmingDelete = true }
            }
            .listRowBackground(KiraColor.surface)
        }
        .listStyle(.insetGrouped)
        .confirmationDialog("Delete this transaction?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.delete([record.id]); dismiss() }
        }
    }

    private func statusExplanation(_ record: TransactionRecord) -> String? {
        switch record.status {
        case .draft:
            return "Scanned from a QR code. Kira can’t see whether you paid, so this isn’t counted until you confirm it or import the receipt."
        case .pending:
            return record.source == .appleShortcut
                ? "Logged from an Apple Pay tap. A tap isn’t a settled payment — it’s confirmed when it matches a statement or you confirm it."
                : "Not yet confirmed."
        case .reconciled:
            return "Matched with a statement record."
        case .confirmed, .superseded:
            return nil
        }
    }
}
