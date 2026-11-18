import Foundation

/// The Kitchen's connection list and daily history, read once and handed to every Kitchen card of the pass:
/// the summary card and each connection card ask for the same answer, and asking the server once per card
/// would multiply its load by the number of connections. An answer is reused for `RefreshSetting.interval`;
/// a failed read is not kept, so the next card asks again.
@MainActor
final class KitchenReadShare {
    private var accounts: (at: Date, task: Task<Result<[KitchenConnection], Error>, Never>)?

    func connections(
        now: Date, read: @escaping @MainActor () async throws -> [KitchenConnection]
    ) async throws -> [KitchenConnection] {
        if let accounts, now.timeIntervalSince(accounts.at) < RefreshSetting.interval {
            return try await accounts.task.value.get()
        }
        let task = Task { await Result { try await read() } }
        accounts = (now, task)
        let result = await task.value
        if case .failure = result { accounts = nil }
        return try result.get()
    }
}
