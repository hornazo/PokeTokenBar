import CryptoKit
import Foundation

/// A leaderboard shared by a group, replicated in every member's app and synced between Macs nearby.
///
/// Nobody owns the truth: each member signs their own row, rows merge by "newest signature wins", and
/// battle points only come from results both players signed. Any two replicas that saw the same rows
/// end up identical, whatever order they met in. Pure, so the whole model is tested without a network.
enum BoardRules {
    /// Live members a board ranks. Over it, every replica keeps the same ones (see `ranked`).
    static let memberCap = 100
    /// Rows a replica stores at most, tombstones included: a flood guard, well above the cap.
    static let storedRecordCap = 500
    static let storedReceiptCap = 1000
    /// Co-signed results that count per pair of trainers per ISO week.
    static let countedPerPairPerWeek = 3
    static let maxClockSkewMs: Int64 = 10 * 60 * 1000
    static let maxNameLength = 32
    static let codeLength = 12

    static func now() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
}

/// The invite code is the board's secret: whoever holds it can join and sync. 60 random bits.
struct BoardCode: Hashable, Sendable {
    /// Normalized: 12 Crockford characters, no separators.
    let value: String

    init?(_ raw: String) {
        guard let normalized = Crockford.normalize(raw), normalized.count == BoardRules.codeLength else { return nil }
        value = normalized
    }

    static func random() -> BoardCode {
        var bytes = [UInt8](repeating: 0, count: 8)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return BoardCode(String(Crockford.encode(bytes).prefix(BoardRules.codeLength)))!
    }

    /// `XXXX-XXXX-XXXX`.
    var display: String {
        let c = Array(value)
        return [String(c[0..<4]), String(c[4..<8]), String(c[8..<12])].joined(separator: "-")
    }

    /// Public id derived from the secret; reveals nothing about it.
    var boardId: String { TrainerSigning.sha256Hex(Data("ptb-board:\(value)".utf8)) }

    var key: SymmetricKey { SymmetricKey(data: SHA256.hash(data: Data("ptb-board-key:\(value)".utf8))) }

    /// Proof of holding the code, bound to a context so it can't be replayed elsewhere.
    func proof(_ context: String) -> String {
        TrainerSigning.base64URL(Data(HMAC<SHA256>.authenticationCode(for: Data(context.utf8), using: key)))
    }
}

/// What a member publishes about themselves. Raw numbers; scoring happens on read.
struct BoardStats: Codable, Equatable, Sendable {
    struct Collection: Codable, Equatable, Sendable {
        var dex = 0
        var species = 0
        var shinies = 0
        var graduated = 0
    }
    struct Levels: Codable, Equatable, Sendable {
        /// Sum of the battle team's levels (up to 6 × 100).
        var teamTotal = 0
        var top = 0
    }
    /// One battle team slot, as other members see it.
    struct TeamMember: Codable, Equatable, Sendable {
        let speciesNum: Int
        /// In the trainer's own language.
        let species: String
        let form: String?
        let shiny: Bool
        let level: Int

        var isPlausible: Bool {
            (1...1_100).contains(speciesNum) && (1...100).contains(level)
                && (1...BoardRules.maxNameLength).contains(species.count) && (form?.count ?? 0) <= 16
        }
    }

    var collection = Collection()
    var levels = Levels()
    /// Only when the trainer opted in.
    var aiBand: WeeklyUsageBand?
    /// Self-reported and shown, never scored: battle points come from co-signed receipts.
    var battleRecord = BattleRecord()
    /// The battle team in slot order, lead first.
    var team: [TeamMember] = []

    init(collection: Collection = Collection(), levels: Levels = Levels(), aiBand: WeeklyUsageBand? = nil,
         battleRecord: BattleRecord = BattleRecord(), team: [TeamMember] = []) {
        self.collection = collection
        self.levels = levels
        self.aiBand = aiBand
        self.battleRecord = battleRecord
        self.team = team
    }

    private enum CodingKeys: String, CodingKey { case collection, levels, aiBand, battleRecord, team }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collection = try c.decode(Collection.self, forKey: .collection)
        levels = try c.decode(Levels.self, forKey: .levels)
        aiBand = try c.decodeIfPresent(WeeklyUsageBand.self, forKey: .aiBand)
        battleRecord = try c.decode(BattleRecord.self, forKey: .battleRecord)
        team = try c.decodeIfPresent([TeamMember].self, forKey: .team) ?? []
    }

    /// Rows are signed over this encoding: an empty team leaves it out, so rows signed before teams
    /// existed still verify.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(collection, forKey: .collection)
        try c.encode(levels, forKey: .levels)
        try c.encodeIfPresent(aiBand, forKey: .aiBand)
        try c.encode(battleRecord, forKey: .battleRecord)
        if !team.isEmpty { try c.encode(team, forKey: .team) }
    }

    var isPlausible: Bool {
        let c = collection, r = battleRecord
        return [c.dex, c.species, c.shinies, c.graduated, levels.teamTotal, levels.top, r.wins, r.losses, r.draws].allSatisfy { $0 >= 0 }
            && c.dex <= 100_000 && c.species <= 1_100 && c.shinies <= c.dex && c.graduated <= c.dex
            && levels.top <= 100 && levels.teamTotal <= 600
            && r.wins <= 1_000_000 && r.losses <= 1_000_000 && r.draws <= 1_000_000
            && team.count <= 6 && team.allSatisfy(\.isPlausible)
    }
}

/// One member's signed row on one board.
struct BoardRecord: Codable, Equatable, Sendable {
    let boardId: String
    /// The board's name as this member knows it, empty for a joiner that hasn't synced yet; the earliest
    /// member's wins (see `BoardReplica.name`).
    let boardName: String
    let publicKey: String
    let displayName: String
    let stats: BoardStats
    /// Unix ms, chosen when the member first joined and kept on every later row.
    let joinedAt: Int64
    /// Unix ms of this row; the newest row per key wins.
    let issuedAt: Int64
    /// A tombstone: the member left. A later row from the same key rejoins.
    let left: Bool
    let signature: String

    private struct Unsigned: Encodable {
        let boardId, boardName, publicKey, displayName: String
        let stats: BoardStats
        let joinedAt, issuedAt: Int64
        let left: Bool
    }

    static func message(boardId: String, boardName: String, publicKey: String, displayName: String, stats: BoardStats,
                        joinedAt: Int64, issuedAt: Int64, left: Bool) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let body = (try? encoder.encode(Unsigned(boardId: boardId, boardName: boardName, publicKey: publicKey,
                                                 displayName: displayName, stats: stats, joinedAt: joinedAt,
                                                 issuedAt: issuedAt, left: left))) ?? Data()
        return Data("PTB-BOARD-RECORD-V1\n".utf8) + body
    }

    static func signed(boardId: String, boardName: String, displayName: String, stats: BoardStats, joinedAt: Int64,
                       issuedAt: Int64, left: Bool, key: Curve25519.Signing.PrivateKey) throws -> BoardRecord {
        let publicKey = TrainerSigning.encode(key.publicKey)
        let message = message(boardId: boardId, boardName: boardName, publicKey: publicKey, displayName: displayName,
                              stats: stats, joinedAt: joinedAt, issuedAt: issuedAt, left: left)
        return BoardRecord(boardId: boardId, boardName: boardName, publicKey: publicKey, displayName: displayName,
                           stats: stats, joinedAt: joinedAt, issuedAt: issuedAt, left: left,
                           signature: try TrainerSigning.sign(message, with: key))
    }

    var hasValidSignature: Bool {
        TrainerSigning.verify(signature, of: Self.message(boardId: boardId, boardName: boardName, publicKey: publicKey,
                                                          displayName: displayName, stats: stats, joinedAt: joinedAt,
                                                          issuedAt: issuedAt, left: left), by: publicKey)
    }

    /// Everything a replica checks before storing a row it was handed.
    func isAcceptable(for boardId: String, now: Int64) -> Bool {
        self.boardId == boardId
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && displayName.count <= BoardRules.maxNameLength
            && boardName.count <= BoardRules.maxNameLength
            && joinedAt > 0 && joinedAt <= issuedAt && issuedAt <= now + BoardRules.maxClockSkewMs
            && stats.isPlausible
            && hasValidSignature
    }

    /// Newest row wins; identical times fall back to the signature so every replica picks the same one.
    func supersedes(_ other: BoardRecord) -> Bool {
        issuedAt != other.issuedAt ? issuedAt > other.issuedAt : signature > other.signature
    }

    var fingerprint: String { TrainerSigning.fingerprint(publicKey) }
}

/// A battle result both players signed. Only receipts score battle points.
struct BattleReceipt: Codable, Equatable, Sendable {
    /// SHA-256 of both handshake nonces: unique per battle, the same on both Macs.
    let battleId: String
    let boardId: String
    /// The two public keys, sorted.
    let keys: [String]
    /// nil is a draw.
    let winner: String?
    /// Unix ms chosen by the challenger in the handshake and accepted by the other side.
    let startedAt: Int64
    /// publicKey → signature over `message`.
    var signatures: [String: String]

    private struct Unsigned: Encodable {
        let battleId, boardId: String
        let keys: [String]
        let winner: String?
        let startedAt: Int64
    }

    init(battleId: String, boardId: String, keys: [String], winner: String?, startedAt: Int64, signatures: [String: String] = [:]) {
        self.battleId = battleId
        self.boardId = boardId
        self.keys = keys.sorted()
        self.winner = winner
        self.startedAt = startedAt
        self.signatures = signatures
    }

    var message: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let body = (try? encoder.encode(Unsigned(battleId: battleId, boardId: boardId, keys: keys,
                                                 winner: winner, startedAt: startedAt))) ?? Data()
        return Data("PTB-BATTLE-RECEIPT-V1\n".utf8) + body
    }

    func signature(by key: Curve25519.Signing.PrivateKey) throws -> String {
        try TrainerSigning.sign(message, with: key)
    }

    /// Two distinct keys, a winner among them (or a draw), and a valid signature from each.
    var isComplete: Bool {
        keys.count == 2 && keys[0] != keys[1] && keys == keys.sorted()
            && (winner == nil || keys.contains(winner!))
            && keys.allSatisfy { key in signatures[key].map { TrainerSigning.verify($0, of: message, by: key) } ?? false }
    }

    var tieBreak: String { TrainerSigning.sha256Hex(message) }

    func isAcceptable(for boardId: String, now: Int64) -> Bool {
        self.boardId == boardId && startedAt > 0 && startedAt <= now + BoardRules.maxClockSkewMs && isComplete
    }
}

/// One board as one Mac knows it.
struct BoardReplica: Codable, Equatable, Sendable {
    let boardId: String
    /// publicKey → newest valid row.
    private(set) var records: [String: BoardRecord] = [:]
    /// battleId → receipt.
    private(set) var receipts: [String: BattleReceipt] = [:]

    init(boardId: String) {
        self.boardId = boardId
    }

    /// Stores the row if it's valid and newer than what we have. Returns whether anything changed.
    @discardableResult
    mutating func merge(_ record: BoardRecord, now: Int64 = BoardRules.now()) -> Bool {
        guard record.isAcceptable(for: boardId, now: now) else { return false }
        if let current = records[record.publicKey], !record.supersedes(current) { return false }
        records[record.publicKey] = record
        trimRecords()
        return records[record.publicKey] == record
    }

    @discardableResult
    mutating func merge(_ receipt: BattleReceipt, now: Int64 = BoardRules.now()) -> Bool {
        guard receipt.isAcceptable(for: boardId, now: now) else { return false }
        // Only the two players can sign a receipt; if they ever signed two different ones for one battle,
        // every replica keeps the same one.
        if let current = receipts[receipt.battleId], current.tieBreak <= receipt.tieBreak { return false }
        receipts[receipt.battleId] = receipt
        trimReceipts()
        return receipts[receipt.battleId] != nil
    }

    /// Flood guard: keep the earliest-joined rows. A total order, so trimming commutes with merging as long
    /// as members keep their `joinedAt`, which the app always does.
    private mutating func trimRecords() {
        guard records.count > BoardRules.storedRecordCap else { return }
        let keep = records.values.sorted(by: Self.joinOrder).prefix(BoardRules.storedRecordCap)
        records = Dictionary(uniqueKeysWithValues: keep.map { ($0.publicKey, $0) })
    }

    private mutating func trimReceipts() {
        guard receipts.count > BoardRules.storedReceiptCap else { return }
        let keep = receipts.values.sorted { ($0.startedAt, $0.battleId) > ($1.startedAt, $1.battleId) }
            .prefix(BoardRules.storedReceiptCap)
        receipts = Dictionary(uniqueKeysWithValues: keep.map { ($0.battleId, $0) })
    }

    static func joinOrder(_ a: BoardRecord, _ b: BoardRecord) -> Bool {
        (a.joinedAt, a.publicKey) < (b.joinedAt, b.publicKey)
    }

    /// Live members in join order, capped. Every replica holding the same rows picks the same members.
    var members: [BoardRecord] {
        Array(records.values.filter { !$0.left }.sorted(by: Self.joinOrder).prefix(BoardRules.memberCap))
    }

    /// The name from the earliest member that knows it; joiners sign an empty name until they sync.
    var name: String? { records.values.filter { !$0.boardName.isEmpty }.sorted(by: Self.joinOrder).first?.boardName }

    /// `publicKey → issuedAt`, what a peer compares to decide which rows to send.
    var digest: [String: Int64] { records.mapValues(\.issuedAt) }
}

/// Points, from the defaults stated in the README. Collection and levels are self-reported; battle
/// points count co-signed receipts between current members, a few per pair per week.
enum BoardScoring {
    struct Score: Encodable, Equatable, Sendable {
        var battle = 0
        var collection = 0
        var levels = 0
        var ai = 0
        var total: Int { battle + collection + levels + ai }

        private enum CodingKeys: String, CodingKey { case total, battle, collection, levels, ai }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(total, forKey: .total)
            try c.encode(battle, forKey: .battle)
            try c.encode(collection, forKey: .collection)
            try c.encode(levels, forKey: .levels)
            try c.encode(ai, forKey: .ai)
        }
    }

    struct Counted: Codable, Equatable, Sendable {
        var wins = 0
        var draws = 0
        var losses = 0
    }

    struct Standing: Equatable, Sendable {
        let record: BoardRecord
        let score: Score
        let counted: Counted
        /// 1-based; equal totals share a rank.
        let rank: Int
    }

    static let winPoints = 3
    static let drawPoints = 1

    static func aiPoints(_ band: WeeklyUsageBand?) -> Int {
        switch band {
        case nil: return 0
        case .light: return 1
        case .moderate: return 2
        case .heavy: return 3
        case .extreme: return 4
        }
    }

    /// Receipts that score: both keys are current members, and at most `countedPerPairPerWeek` per pair
    /// per ISO week, earliest first.
    static func countedReceipts(_ replica: BoardReplica) -> [BattleReceipt] {
        let members = Set(replica.members.map(\.publicKey))
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var perPairWeek: [String: Int] = [:]
        return replica.receipts.values
            .filter { $0.keys.allSatisfy(members.contains) }
            .sorted { ($0.startedAt, $0.battleId) < ($1.startedAt, $1.battleId) }
            .filter { receipt in
                let date = Date(timeIntervalSince1970: Double(receipt.startedAt) / 1000)
                let week = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
                let bucket = "\(receipt.keys.joined(separator: "|"))@\(week.yearForWeekOfYear ?? 0)-\(week.weekOfYear ?? 0)"
                perPairWeek[bucket, default: 0] += 1
                return perPairWeek[bucket]! <= BoardRules.countedPerPairPerWeek
            }
    }

    static func standings(_ replica: BoardReplica) -> [Standing] {
        var battle: [String: Int] = [:]
        var counted: [String: Counted] = [:]
        for receipt in countedReceipts(replica) {
            if let winner = receipt.winner {
                battle[winner, default: 0] += winPoints
                counted[winner, default: Counted()].wins += 1
                for key in receipt.keys where key != winner { counted[key, default: Counted()].losses += 1 }
            } else {
                for key in receipt.keys {
                    battle[key, default: 0] += drawPoints
                    counted[key, default: Counted()].draws += 1
                }
            }
        }
        let scored = replica.members.map { record -> (BoardRecord, Score) in
            let s = record.stats
            return (record, Score(battle: battle[record.publicKey] ?? 0,
                                  collection: s.collection.species + s.collection.shinies * 5 + s.collection.graduated * 2,
                                  levels: s.levels.teamTotal / 10,
                                  ai: aiPoints(s.aiBand)))
        }
        .sorted { a, b in
            if a.1.total != b.1.total { return a.1.total > b.1.total }
            if a.1.battle != b.1.battle { return a.1.battle > b.1.battle }
            let byName = a.0.displayName.localizedCaseInsensitiveCompare(b.0.displayName)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.0.publicKey < b.0.publicKey
        }
        var result: [Standing] = []
        for (index, (record, score)) in scored.enumerated() {
            let rank = index > 0 && result[index - 1].score.total == score.total ? result[index - 1].rank : index + 1
            result.append(Standing(record: record, score: score, counted: counted[record.publicKey] ?? Counted(), rank: rank))
        }
        return result
    }
}
