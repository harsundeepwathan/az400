import Foundation

/// Matches newly captured/imported records against what is already stored so the same payment
/// recorded by a Shortcut, a receipt and a bank statement is counted once.
///
/// Policy: only unambiguous evidence (identical external reference, or an identical import
/// fingerprint) is acted on automatically. Everything else goes to the review queue — Kira never
/// silently merges records that merely look similar.
public struct ReconciliationEngine: Sendable {
    public struct Configuration: Sendable {
        /// Card transactions can post several days after the tap.
        public var dateWindowDays: Int
        /// Candidates below this score are ignored.
        public var minimumScore: Double
        /// Candidates at or above this score are pre-selected in review.
        public var likelyScore: Double

        public init(dateWindowDays: Int = 4, minimumScore: Double = 0.55, likelyScore: Double = 0.8) {
            self.dateWindowDays = dateWindowDays
            self.minimumScore = minimumScore
            self.likelyScore = likelyScore
        }
    }

    public struct Candidate: Equatable, Sendable {
        public let existingID: UUID
        public let score: Double
        public let reasons: [String]
        public let referenceMatch: Bool
    }

    public enum Disposition: Equatable, Sendable {
        /// Same statement row imported before — skip.
        case exactDuplicate(existingID: UUID)
        /// Same external reference — merged automatically.
        case autoMerge(existingID: UUID)
        /// One strong candidate — pre-selected for one-tap confirmation in review.
        case likelyMatch(Candidate)
        /// Several plausible candidates — user must choose.
        case ambiguous([Candidate])
        /// No plausible match — new record.
        case new
    }

    public struct PlanItem: Sendable {
        public let incoming: TransactionRecord
        public let disposition: Disposition
    }

    public var configuration: Configuration
    public var calendar: KLCalendar

    public init(configuration: Configuration = Configuration(), calendar: KLCalendar = .shared) {
        self.configuration = configuration
        self.calendar = calendar
    }

    public func plan(incoming: [TransactionRecord], existing: [TransactionRecord]) -> [PlanItem] {
        let active = existing.filter { $0.status != .superseded }
        let fingerprints = Dictionary(existing.compactMap { record in record.importFingerprint.map { ($0, record.id) } }, uniquingKeysWith: { first, _ in first })
        var claimedByAutoMerge = Set<UUID>()

        return incoming.map { record in
            if let fingerprint = record.importFingerprint, let existingID = fingerprints[fingerprint] {
                return PlanItem(incoming: record, disposition: .exactDuplicate(existingID: existingID))
            }
            let candidates = self.candidates(for: record, in: active).filter { !claimedByAutoMerge.contains($0.existingID) }
            if let referenceMatch = candidates.first(where: \.referenceMatch), candidates.filter(\.referenceMatch).count == 1 {
                claimedByAutoMerge.insert(referenceMatch.existingID)
                return PlanItem(incoming: record, disposition: .autoMerge(existingID: referenceMatch.existingID))
            }
            guard let best = candidates.first else { return PlanItem(incoming: record, disposition: .new) }
            let strong = candidates.filter { $0.score >= configuration.likelyScore }
            if strong.count == 1, best.score >= configuration.likelyScore,
               candidates.count == 1 || candidates[1].score < best.score - 0.15 {
                return PlanItem(incoming: record, disposition: .likelyMatch(best))
            }
            return PlanItem(incoming: record, disposition: .ambiguous(candidates))
        }
    }

    /// Scored candidates, best first.
    public func candidates(for record: TransactionRecord, in existing: [TransactionRecord]) -> [Candidate] {
        existing.compactMap { score(record, against: $0) }
            .filter { $0.score >= configuration.minimumScore || $0.referenceMatch }
            .sorted { $0.score > $1.score }
    }

    func score(_ incoming: TransactionRecord, against existing: TransactionRecord) -> Candidate? {
        guard incoming.id != existing.id, incoming.direction == existing.direction,
              incoming.amount.currency == existing.amount.currency else { return nil }
        if let a = incoming.accountID, let b = existing.accountID, a != b { return nil }
        // Two statement rows from the same import source are distinct transactions, not duplicates.
        if incoming.source.isStatement && existing.source.isStatement && incoming.source == existing.source { return nil }

        var reasons: [String] = []
        var score = 0.0

        let referenceMatch: Bool = {
            guard let a = incoming.externalReference?.uppercased(), let b = existing.externalReference?.uppercased(), a.count >= 6 else { return false }
            return a == b
        }()

        let amountUnknown = incoming.flags.contains(.amountMissing) || existing.flags.contains(.amountMissing)
        if incoming.amount == existing.amount && !amountUnknown {
            score += 0.4; reasons.append("Same amount")
        } else if amountUnknown {
            score += 0.1; reasons.append("Amount not recorded on one side")
        } else if !referenceMatch {
            return nil
        }

        let dates = [incoming.transactionDate, incoming.postingDate].compactMap { $0 }
        let existingDates = [existing.transactionDate, existing.postingDate].compactMap { $0 }
        let distance = dates.flatMap { a in existingDates.map { b in abs(calendar.dayDistance(from: a, to: b)) } }.min() ?? Int.max
        switch distance {
        case 0: score += 0.25; reasons.append("Same day")
        case 1: score += 0.18; reasons.append("1 day apart")
        case let days where days <= configuration.dateWindowDays: score += 0.08; reasons.append("\(days) days apart")
        default: if !referenceMatch { return nil }
        }

        let similarity = TextSimilarity.merchant(incoming.merchant ?? incoming.transactionDescription, existing.merchant ?? existing.transactionDescription)
        let merchantKnown = (incoming.merchant ?? incoming.transactionDescription).count > 1 && (existing.merchant ?? existing.transactionDescription).count > 1
        if merchantKnown {
            score += 0.25 * similarity
            if similarity >= 0.7 { reasons.append("Similar merchant") }
        } else {
            score += 0.1 // unknown merchant neither confirms nor contradicts
        }

        if incoming.accountID != nil && incoming.accountID == existing.accountID { score += 0.1; reasons.append("Same account") }
        else { score += 0.03 }

        if referenceMatch { reasons.insert("Same reference number", at: 0); score = 1.0 }
        return Candidate(existingID: existing.id, score: min(score, 1.0), reasons: reasons, referenceMatch: referenceMatch)
    }

    /// Merges an incoming record into an existing one. The existing record keeps its identity (links,
    /// edits) and receives the more authoritative field values. User choices always survive.
    public func merge(existing: TransactionRecord, incoming: TransactionRecord, now: Date = Date()) -> TransactionRecord {
        let incomingWins = incoming.source.authority >= existing.source.authority
        let authoritative = incomingWins ? incoming : existing
        let other = incomingWins ? existing : incoming
        var merged = existing

        if !authoritative.flags.contains(.amountMissing) { merged.amount = authoritative.amount }
        else if !other.flags.contains(.amountMissing) { merged.amount = other.amount }
        merged.transactionDate = min(existing.transactionDate, incoming.transactionDate)
        merged.postingDate = authoritative.postingDate ?? other.postingDate
        merged.transactionDescription = authoritative.transactionDescription.isEmpty ? other.transactionDescription : authoritative.transactionDescription
        merged.merchant = Self.preferredMerchant(existing, incoming)
        merged.accountID = existing.accountID ?? incoming.accountID
        merged.source = authoritative.source
        merged.externalReference = existing.externalReference ?? incoming.externalReference
        merged.merchantCategoryCode = existing.merchantCategoryCode ?? incoming.merchantCategoryCode
        merged.importFingerprint = incoming.importFingerprint ?? existing.importFingerprint
        // More specific channel wins (Apple Pay / DuitNow QR are more informative than "card"/"other").
        merged.channel = [existing.channel, incoming.channel].first { $0 != .other && $0 != .card } ?? (existing.channel != .other ? existing.channel : incoming.channel)

        // Category: user choice > existing > incoming.
        if existing.categoryIsUserSet {
            merged.categoryID = existing.categoryID; merged.categoryIsUserSet = true
        } else if incoming.categoryIsUserSet {
            merged.categoryID = incoming.categoryID; merged.categoryIsUserSet = true
        } else {
            merged.categoryID = existing.categoryID ?? incoming.categoryID
        }
        // Kind: a user-confirmed existing kind is kept; otherwise statement classification wins.
        merged.kind = existing.categoryIsUserSet ? existing.kind : authoritative.kind

        merged.notes = [existing.notes, incoming.notes].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n").nilIfEmpty
        merged.status = (existing.source.isStatement || incoming.source.isStatement) ? .reconciled : .confirmed
        merged.flags = existing.flags.union(incoming.flags).subtracting([.unconfirmedPayment, .possibleDuplicate, .amountMissing, .merchantMissing])
        if merged.merchant != nil { merged.flags.remove(.merchantMissing) }
        merged.confidence = max(existing.confidence, incoming.confidence)
        merged.updatedAt = now
        return merged
    }

    /// Marks `duplicate` as superseded by `keep` (both already stored). Returns updated pair.
    public func mergeStored(keep: TransactionRecord, duplicate: TransactionRecord, now: Date = Date()) -> (kept: TransactionRecord, superseded: TransactionRecord) {
        let kept = merge(existing: keep, incoming: duplicate, now: now)
        var superseded = duplicate
        superseded.status = .superseded
        superseded.supersededBy = keep.id
        superseded.updatedAt = now
        return (kept, superseded)
    }

    static func preferredMerchant(_ a: TransactionRecord, _ b: TransactionRecord) -> String? {
        // Prefer a human-entered or dictionary-cleaned name over raw statement text.
        let ordered = [a, b].sorted { lhs, rhs in
            func rank(_ record: TransactionRecord) -> Int {
                switch record.source {
                case .manual: return 0
                case .receiptImage, .receiptDocument, .duitNowQR: return 1
                case .appleShortcut: return 2
                default: return 3
                }
            }
            return rank(lhs) < rank(rhs)
        }
        return ordered.compactMap { $0.merchant }.first { !$0.isEmpty }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
