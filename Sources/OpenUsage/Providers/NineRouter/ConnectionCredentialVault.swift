import Foundation

/// The vault a Kitchen connection account reads with: a connection holds no credential of its own, so a read
/// of its id answers with its parent Kitchen account's API key. It never writes: a refused key is replaced on
/// the Kitchen account's page, and a connection has nothing to save or delete.
struct ConnectionCredentialVault: CredentialVault {
    let parentID: UUID
    let parent: any CredentialVault

    func load(_ id: UUID) throws -> AccountCredential? { try parent.load(parentID) }
    func save(_ credential: AccountCredential, for id: UUID) throws {}
    func update(_ credential: AccountCredential, for id: UUID) throws {}
    func delete(_ id: UUID) throws {}
}
