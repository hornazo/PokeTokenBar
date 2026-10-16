import Foundation

/// One finished battle as the trainer page shows it afterwards: the field as it ended and the full log.
struct BattleHistoryEntry: Codable, Equatable, Sendable, Identifiable {
    static let maxLogLines = 400

    let id: String
    /// Unix ms.
    let finishedAt: Int64
    /// The opponent's trainer key and its fingerprint, for nearby battles where they sent a key.
    var opponentKey: String? = nil
    let opponentFingerprint: String?
    let battle: BattleSpectatorSnapshot

    /// Drops what only matters while playing (your move list, the turn timer) and keeps the newest log lines.
    static func make(_ snapshot: BattleSpectatorSnapshot, id: String = UUID().uuidString, finishedAt: Int64,
                     opponentKey: String?) -> BattleHistoryEntry {
        let battle = BattleSpectatorSnapshot(id: id, kind: snapshot.kind, board: snapshot.board, sides: snapshot.sides,
                                             moves: [], message: snapshot.message,
                                             log: Array(snapshot.log.suffix(maxLogLines)), turn: snapshot.turn,
                                             outcome: snapshot.outcome, turnDeadline: nil)
        let key = opponentKey.flatMap { TrainerSigning.publicKey($0) != nil ? $0 : nil }
        return BattleHistoryEntry(id: id, finishedAt: finishedAt, opponentKey: key,
                                  opponentFingerprint: key.map(TrainerSigning.fingerprint), battle: battle)
    }
}

/// Decides when the battle on screen has just finished, so each result is saved once: a practice rematch
/// reuses its session, and the session keeps changing (messages, log) after its outcome is set.
struct BattleHistoryRecorder {
    private var recorded: ObjectIdentifier?

    /// True the first time `session` is seen with an outcome since it last had none.
    mutating func shouldRecord(session: ObjectIdentifier?, finished: Bool) -> Bool {
        guard let session else { return false }
        guard finished else {
            if recorded == session { recorded = nil }
            return false
        }
        guard recorded != session else { return false }
        recorded = session
        return true
    }
}
