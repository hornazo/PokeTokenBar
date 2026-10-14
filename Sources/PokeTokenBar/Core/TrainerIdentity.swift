import CryptoKit
import Foundation
import Security

/// The trainer's Ed25519 key: signs board records and co-signs battle results. Kept in the login
/// Keychain as the app's own item; peers only ever see the public half.
///
/// One key per Mac, except under `PTB_STATE_DIR`: each state directory gets its own key, so two
/// instances on one Mac (QA, the end-to-end run) are two trainers instead of one with two saves.
enum TrainerKeyStore {
    private static let service = "io.github.chattymin.poketokenbar.trainer"

    enum KeyStoreError: Error { case keychain(OSStatus) }

    static func account(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let override = (environment["PTB_STATE_DIR"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !override.isEmpty else { return "trainer-signing-key" }
        let digest = SHA256.hash(data: Data(override.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "trainer-signing-key-\(digest)"
    }

    static func loadOrCreate() throws -> Curve25519.Signing.PrivateKey {
        if let existing = try load() { return existing }
        let key = Curve25519.Signing.PrivateKey()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: key.rawRepresentation,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
        return key
    }

    static func load() throws -> Curve25519.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(),
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = KeychainReader.copyMatching(query, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeyStoreError.keychain(status) }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }
}

/// The trainer's key, loaded once per run off the main thread (the read can sit on a Keychain prompt).
@MainActor @Observable
final class TrainerIdentity {
    static let shared = TrainerIdentity(load: { try TrainerKeyStore.loadOrCreate() })

    private let loader: @Sendable () throws -> Curve25519.Signing.PrivateKey
    private var loading: Task<Curve25519.Signing.PrivateKey, Error>?
    /// Set once the key has loaded; synchronous callers (an invitation being built) use it.
    private(set) var key: Curve25519.Signing.PrivateKey?

    init(load: @escaping @Sendable () throws -> Curve25519.Signing.PrivateKey) {
        loader = load
    }

    func privateKey() async throws -> Curve25519.Signing.PrivateKey {
        if let key { return key }
        let task = loading ?? Task.detached(priority: .userInitiated) { [loader] in try loader() }
        loading = task
        do {
            let loaded = try await task.value
            key = loaded
            return loaded
        } catch {
            loading = nil
            throw error
        }
    }

    var publicKey: String? { key.map { TrainerSigning.encode($0.publicKey) } }
}
