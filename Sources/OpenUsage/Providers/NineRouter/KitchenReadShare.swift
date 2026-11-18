import Foundation

/// The Kitchen's connection list, read once and handed to every Kitchen card of the pass: the summary card
/// and each connection card ask for the same answer, and asking the server once per card would multiply its
/// load by the number of connections. An answer is reused for `RefreshSetting.interval`; a failed read is not
/// kept, so the next card asks again.
@MainActor
final class KitchenReadShare {
    private var current: (at: Date, task: Task<[KitchenConnection], Error>)?

    func connections(
        now: Date, read: @escaping @MainActor () async throws -> [KitchenConnection]
    ) async throws -> [KitchenConnection] {
        if let current, now.timeIntervalSince(current.at) < RefreshSetting.interval {
            return try await current.task.value
        }
        let task = Task { try await read() }
        current = (now, task)
        do {
            return try await task.value
        } catch {
            if current?.task == task { current = nil }
            throw error
        }
    }
}
