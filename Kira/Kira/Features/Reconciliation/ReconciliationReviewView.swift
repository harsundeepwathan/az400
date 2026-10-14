import SwiftUI
import KiraCore

/// Review every incoming record before it is saved: new, already imported, matched with an
/// existing record, or needing a decision. Nothing ambiguous is merged without the user.
struct ReconciliationReviewView: View {
    @Environment(FinanceStore.self) private var store
    /// One-time seed: the review is edited locally until the user saves.
    @State private var review: ImportReview
    var onCommitted: () -> Void

    init(review: ImportReview, onCommitted: @escaping () -> Void) {
        _review = State(initialValue: review)
        self.onCommitted = onCommitted
    }
    @State private var showSkipped = false

    var body: some View {
        List {
            Section {
                HStack(spacing: KiraSpacing.l) {
                    stat("\(review.newCount)", "New")
                    stat("\(review.mergeCount)", "Matched")
                    stat("\(review.skipCount)", "Already in Kira")
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                ForEach(review.warnings, id: \.self) { NoticeBanner(tone: .caution, text: $0) }
                if !review.skippedRows.isEmpty {
                    DisclosureGroup("\(review.skippedRows.count) line(s) skipped", isExpanded: $showSkipped) {
                        ForEach(review.skippedRows, id: \.line) { row in
                            Text("Line \(row.line): \(row.reason)").font(.footnote).foregroundStyle(KiraColor.textSecondary)
                        }
                    }
                }
            }

            let attention = review.items.filter(\.needsAttention)
            if !attention.isEmpty {
                Section {
                    // Stable identity: each item is keyed by its incoming record's ID.
                    ForEach(attention) { item in decisionRow(item) }
                } header: {
                    Text("Check these")
                } footer: {
                    Text("These look like payments already in Kira (for example an Apple Pay tap or a scanned QR). Choose “Same payment” to merge them so they’re counted once.")
                }
            }

            Section("Everything else") {
                ForEach(review.items.filter { !$0.needsAttention }) { item in
                    HStack {
                        TransactionRow(record: item.incoming)
                        Text(label(for: item)).font(.caption2.weight(.semibold)).foregroundStyle(KiraColor.textSecondary)
                    }
                    .opacity(item.decision == .skip ? 0.5 : 1)
                }
            }
        }
        .listStyle(.insetGrouped)
        .kiraScreen()
        .navigationTitle(review.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: review.items.map(\.decision))
        // HIG › Sheets: the confirming action sits on the trailing edge of the top toolbar.
        .toolbar {
            ConfirmToolbarItem(title: "Save \(review.newCount + review.mergeCount)", isDisabled: review.newCount + review.mergeCount == 0) {
                store.commit(review)
                onCommitted()
            }
        }
    }

    private func stat(_ value: String, _ title: String) -> some View {
        VStack {
            Text(value).font(.kiraFigure).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(KiraColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func label(for item: ImportReview.Item) -> String {
        switch item.disposition {
        case .exactDuplicate: return "Already imported"
        case .autoMerge: return "Same reference"
        case .new: return "New"
        default: return ""
        }
    }

    private func setDecision(_ decision: ImportReview.Decision, for itemID: UUID) {
        guard let index = review.items.firstIndex(where: { $0.id == itemID }) else { return }
        review.items[index].decision = decision
    }

    private func decisionRow(_ item: ImportReview.Item) -> some View {
        let candidates: [ReconciliationEngine.Candidate] = {
            switch item.disposition {
            case .likelyMatch(let candidate): return [candidate]
            case .ambiguous(let candidates): return candidates
            default: return []
            }
        }()
        // Resolve candidates up front so each ForEach element renders exactly one view.
        let matches = candidates.compactMap { candidate in store.transaction(candidate.existingID).map { (record: $0, candidate: candidate) } }
        return VStack(alignment: .leading, spacing: KiraSpacing.s) {
            TransactionRow(record: item.incoming)
            ForEach(matches, id: \.record.id) { match in
                let isSelected = item.decision == .merge(match.record.id)
                Button {
                    setDecision(.merge(match.record.id), for: item.id)
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(KiraColor.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Same payment as \(match.record.displayName) · \(match.record.transactionDate.kiraShort)")
                                .font(.subheadline).foregroundStyle(KiraColor.textPrimary)
                            Text(match.candidate.reasons.joined(separator: " · ")).font(.caption).foregroundStyle(KiraColor.textSecondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            Button {
                setDecision(.keep, for: item.id)
            } label: {
                HStack {
                    Image(systemName: item.decision == .keep ? "largecircle.fill.circle" : "circle").foregroundStyle(KiraColor.accent)
                    Text("Different payment — keep both").font(.subheadline).foregroundStyle(KiraColor.textPrimary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(item.decision == .keep ? .isSelected : [])
        }
        .padding(.vertical, 4)
    }
}
