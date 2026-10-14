import CryptoKit
import Foundation

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
