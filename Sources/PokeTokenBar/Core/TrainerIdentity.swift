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
@MainActor
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

/// Encodings shared by everything a trainer signs.
enum TrainerSigning {
    /// Unpadded base64url.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ string: String) -> Data? {
        guard string.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    static func encode(_ key: Curve25519.Signing.PublicKey) -> String { base64URL(key.rawRepresentation) }

    static func publicKey(_ encoded: String) -> Curve25519.Signing.PublicKey? {
        guard let raw = decodeBase64URL(encoded), raw.count == 32 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    static func sign(_ message: Data, with key: Curve25519.Signing.PrivateKey) throws -> String {
        base64URL(try key.signature(for: message))
    }

    static func verify(_ signature: String, of message: Data, by publicKey: String) -> Bool {
        guard let key = Self.publicKey(publicKey), let raw = decodeBase64URL(signature), raw.count == 64 else { return false }
        return key.isValidSignature(raw, for: message)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Four Crockford characters from the key's hash, shown next to names so two "Ash" differ.
    static func fingerprint(_ publicKey: String) -> String {
        let digest = Array(SHA256.hash(data: Data(publicKey.utf8)))
        return Crockford.encode(digest.prefix(3)).prefix(4).description
    }
}

/// Crockford base32: no I, L, O or U, so codes read aloud and typed by hand survive.
enum Crockford {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func encode<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        var out = "", buffer = 0, bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(buffer >> bits) & 31])
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    /// Uppercases, drops separators and maps the look-alikes (O→0, I/L→1). nil on any other character.
    static func normalize(_ raw: String) -> String? {
        var out = ""
        for ch in raw.uppercased() where ch != "-" && ch != " " {
            switch ch {
            case "O": out.append("0")
            case "I", "L": out.append("1")
            default:
                guard alphabet.contains(ch) else { return nil }
                out.append(ch)
            }
        }
        return out
    }
}
