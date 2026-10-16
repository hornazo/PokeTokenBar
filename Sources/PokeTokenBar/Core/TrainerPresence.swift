import Foundation

/// Whether a trainer can be challenged now: visible nearby and at their Mac, visible but away from it, or
/// not visible at all.
enum TrainerPresence: String, Codable, Sendable, Comparable {
    case available, idle, away

    static func < (a: TrainerPresence, b: TrainerPresence) -> Bool { a.order < b.order }
    private var order: Int { self == .available ? 0 : self == .idle ? 1 : 2 }
}

enum UserActivity {
    /// No keyboard or mouse input for this long counts as idle.
    static let idleAfter: TimeInterval = 5 * 60

    static func isActive(idleSeconds: TimeInterval) -> Bool { idleSeconds < idleAfter }
}

/// What a Mac visible for battles advertises next to the protocol version: its trainer key, so the others
/// can tell who it is across runs, and whether its user is at the keyboard.
enum NearbyDiscovery {
    static let keyKey = "k"
    static let activeKey = "a"

    static func info(version: Int, publicKey: String?, active: Bool) -> [String: String] {
        var info = [NearbyBattle.versionKey: String(version), activeKey: active ? "1" : "0"]
        if let publicKey { info[keyKey] = publicKey }
        return info
    }

    /// An unknown or malformed key is dropped; a peer that doesn't say counts as active.
    static func parse(_ info: [String: String]?) -> (publicKey: String?, active: Bool) {
        let key = info?[keyKey].flatMap { TrainerSigning.publicKey($0) != nil ? $0 : nil }
        return (key, info?[activeKey] != "0")
    }
}
