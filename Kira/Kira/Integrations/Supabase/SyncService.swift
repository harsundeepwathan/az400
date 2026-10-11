import Foundation
import KiraCore

/// Boundary for optional, authenticated cloud sync (Premium). Kira is local-first: the app is
/// fully functional with `DisabledSyncService`, which is the only implementation shipped.
///
/// Requirements for a future Supabase implementation (see docs/SECURITY.md):
/// - Use only the project's anon key + the user's session JWT; never a service-role key.
/// - Store the refresh token in the Keychain (`KeychainStore`), never in UserDefaults.
/// - Rely on the RLS policies in `supabase/migrations/0001_init.sql` for isolation.
/// - Sync encrypted payloads (client-side encryption with a key held in the Keychain) so the
///   server never sees plaintext amounts or merchants.
protocol SyncService: Sendable {
    var isEnabled: Bool { get }
    func push(_ records: [TransactionRecord]) async throws
    func pullChanges(since: Date?) async throws -> [TransactionRecord]
    func deleteRemoteData() async throws
}

struct DisabledSyncService: SyncService {
    var isEnabled: Bool { false }
    func push(_ records: [TransactionRecord]) async throws {}
    func pullChanges(since: Date?) async throws -> [TransactionRecord] { [] }
    func deleteRemoteData() async throws {}
}
