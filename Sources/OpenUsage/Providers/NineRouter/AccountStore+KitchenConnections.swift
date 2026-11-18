import Foundation

extension AccountStore {
    /// Makes the connection accounts of one Kitchen account match the server's active connections: a new
    /// connection is added at the bottom, one the server no longer lists is removed, and a renamed one keeps
    /// its account and takes the new name. The Kitchen account itself, which holds the API key, is never
    /// touched, and a connection account has no credential of its own: it reads with the Kitchen account's key.
    /// Applying the same list twice changes nothing the second time.
    func syncKitchenConnections(of kitchenID: UUID, to connections: [KitchenConnection]) throws {
        guard accounts.contains(where: { $0.id == kitchenID && $0.kind == .ninerouterKitchen && $0.upstream == nil }) else { return }
        try applyConnectionAccounts(of: kitchenID, to: connections.map { ($0.id, $0.name) })
    }
}
