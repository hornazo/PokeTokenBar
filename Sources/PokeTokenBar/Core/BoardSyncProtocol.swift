import Foundation

/// What two Macs say to sync boards. Standings are public: each side lists the boards it holds, and both
/// exchange every board either one has. Rows prove their own membership (`BoardRecord.hasValidMembership`),
/// so a Mac without a board's code can hold and pass on its rows but never add a member.
enum BoardSyncMessage: Codable, Sendable, Equatable {
    case hello(version: Int, nonce: String)
    /// Ids of every board we hold, members' and watched ones.
    case boards([String])
    /// For each board either side holds: who we have and how fresh (`publicKey → issuedAt`), and which receipts.
    case digest(boardId: String, records: [String: Int64], receipts: [String])
    /// What the peer lacked, in answer to its digest. The last message per board.
    case rows(boardId: String, records: [BoardRecord], receipts: [BattleReceipt])

    /// 2: boards are public and listed instead of proven.
    static let version = 2
    static let maxSize = 1024 * 1024
    /// Boards one peer may list; well above what a Mac keeps.
    static let maxBoards = 200

    func encoded() throws -> Data { try JSONEncoder().encode(self) }

    static func decode(_ data: Data) throws -> BoardSyncMessage {
        guard data.count <= maxSize else { throw BoardSyncError.protocolViolation }
        return try JSONDecoder().decode(BoardSyncMessage.self, from: data)
    }
}

enum BoardSyncError: Error, Equatable, Sendable {
    case protocolViolation
    case incompatibleVersion(Int)
}

/// One sync with one peer, as a pure state machine: feed it the peer's messages, send what it returns.
/// Both sides run the same steps, so neither waits for the other to go first.
struct BoardSyncSession {
    struct Shared: Equatable {
        var received: (records: [BoardRecord], receipts: [BattleReceipt])?

        static func == (a: Shared, b: Shared) -> Bool { (a.received == nil) == (b.received == nil) }
    }

    private let replicas: [String: BoardReplica]
    private let myNonce: String
    private var theirNonce: String?
    /// Every board either side holds, once both lists are in.
    private(set) var shared: [String: Shared] = [:]
    private var answered: Set<String> = []
    private var gotBoards = false

    /// `replicas` by board id: every board we hold.
    init(replicas: [String: BoardReplica], nonce: String = UUID().uuidString) {
        self.replicas = replicas
        myNonce = nonce
    }

    /// What to send first.
    func start() -> [BoardSyncMessage] { [.hello(version: BoardSyncMessage.version, nonce: myNonce)] }

    /// Every board has been answered both ways (or neither side holds any).
    var isFinished: Bool {
        gotBoards && shared.values.allSatisfy { $0.received != nil } && answered.count == shared.count
    }

    mutating func receive(_ message: BoardSyncMessage) throws -> [BoardSyncMessage] {
        switch message {
        case .hello(let version, let nonce):
            guard version == BoardSyncMessage.version else { throw BoardSyncError.incompatibleVersion(version) }
            guard theirNonce == nil, !nonce.isEmpty, nonce.count <= 64, nonce != myNonce else { throw BoardSyncError.protocolViolation }
            theirNonce = nonce
            return [.boards(replicas.keys.sorted())]

        case .boards(let ids):
            guard theirNonce != nil, !gotBoards, ids.count <= BoardSyncMessage.maxBoards,
                  ids.allSatisfy(Self.isBoardId) else { throw BoardSyncError.protocolViolation }
            gotBoards = true
            for id in Set(replicas.keys).union(ids) { shared[id] = Shared(received: nil) }
            return shared.keys.sorted().map { id in
                let replica = replicas[id] ?? BoardReplica(boardId: id)
                return .digest(boardId: id, records: replica.digest, receipts: Array(replica.receipts.keys).sorted())
            }

        case .digest(let boardId, let theirRecords, let theirReceipts):
            guard shared[boardId] != nil, !answered.contains(boardId) else { throw BoardSyncError.protocolViolation }
            answered.insert(boardId)
            let replica = replicas[boardId] ?? BoardReplica(boardId: boardId)
            let known = Set(theirReceipts)
            let records = replica.records.values
                .filter { mine in theirRecords[mine.publicKey].map { mine.issuedAt > $0 } ?? true }
                .sorted { $0.publicKey < $1.publicKey }
            let receipts = replica.receipts.values.filter { !known.contains($0.battleId) }.sorted { $0.battleId < $1.battleId }
            return [.rows(boardId: boardId, records: records, receipts: receipts)]

        case .rows(let boardId, let records, let receipts):
            guard var entry = shared[boardId], entry.received == nil else { throw BoardSyncError.protocolViolation }
            entry.received = (records, receipts)
            shared[boardId] = entry
            return []
        }
    }

    /// A SHA-256 hex digest, like every board id.
    static func isBoardId(_ id: String) -> Bool {
        id.count == 64 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
