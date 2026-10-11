import SwiftUI
import KiraCore

/// Review every incoming record before it is saved: new, already imported, matched with an
/// existing record, or needing a decision. Nothing ambiguous is merged without the user.
struct ReconciliationReviewView: View {
    @Environment(FinanceStore.self) private var store
    @State var review: ImportReview
    var onCommitted: () -> Void
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

            let attention = review.items.indices.filter { review.items[$0].needsAttention }
            if !attention.isEmpty {
                Section {
                    ForEach(attention, id: \.self) { index in decisionRow(index) }
                } header: {
                    Text("Check these")
                } footer: {
                    Text("These look like payments already in Kira (for example an Apple Pay tap or a scanned QR). Choose “Same payment” to merge them so they’re counted once.")
                }
            }

            Section("Everything else") {
                ForEach(review.items.indices.filter { !review.items[$0].needsAttention }, id: \.self) { index in
                    let item = review.items[index]
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
        .safeAreaInset(edge: .bottom) {
            Button("Save \(review.newCount + review.mergeCount) transaction\(review.newCount + review.mergeCount == 1 ? "" : "s")") {
                store.commit(review)
                onCommitted()
            }
            .buttonStyle(KiraPrimaryButtonStyle())
            .disabled(review.newCount + review.mergeCount == 0)
            .padding()
            .background(.bar)
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

    @ViewBuilder
    private func decisionRow(_ index: Int) -> some View {
        let item = review.items[index]
        let candidates: [ReconciliationEngine.Candidate] = {
            switch item.disposition {
            case .likelyMatch(let candidate): return [candidate]
            case .ambiguous(let candidates): return candidates
            default: return []
            }
        }()
        VStack(alignment: .leading, spacing: KiraSpacing.s) {
            TransactionRow(record: item.incoming)
            ForEach(candidates, id: \.existingID) { candidate in
                if let existing = store.transaction(candidate.existingID) {
                    Button {
                        review.items[index].decision = .merge(existing.id)
                        Haptics.selection()
                    } label: {
                        HStack(alignment: .top) {
                            Image(systemName: review.items[index].decision == .merge(existing.id) ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(KiraColor.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Same payment as \(existing.displayName) · \(existing.transactionDate.kiraShort)")
                                    .font(.subheadline).foregroundStyle(KiraColor.textPrimary)
                                Text(candidate.reasons.joined(separator: " · ")).font(.caption).foregroundStyle(KiraColor.textSecondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                review.items[index].decision = .keep
                Haptics.selection()
            } label: {
                HStack {
                    Image(systemName: review.items[index].decision == .keep ? "largecircle.fill.circle" : "circle").foregroundStyle(KiraColor.accent)
                    Text("Different payment — keep both").font(.subheadline).foregroundStyle(KiraColor.textPrimary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}
