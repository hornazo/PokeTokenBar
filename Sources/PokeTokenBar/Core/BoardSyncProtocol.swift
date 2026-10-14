import Foundation

/// What two Macs say to sync the boards they share. Neither side learns anything about boards the other
/// holds and it doesn't: membership is proven with an HMAC of the code over both sides' fresh nonces.
enum BoardSyncMessage: Codable, Sendable, Equatable {
    case hello(version: Int, nonce: String)
    /// One proof per board held, in random order.
    case proofs([String])
    /// For each shared board: who we have and how fresh (`publicKey → issuedAt`), and which receipts.
    case digest(boardId: String, records: [String: Int64], receipts: [String])
    /// What the peer lacked, in answer to its digest. The last message per shared board.
    case rows(boardId: String, records: [BoardRecord], receipts: [BattleReceipt])

    static let version = 1
    static let maxSize = 1024 * 1024

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
        let code: BoardCode
        var received: (records: [BoardRecord], receipts: [BattleReceipt])?

        static func == (a: Shared, b: Shared) -> Bool { a.code == b.code && (a.received == nil) == (b.received == nil) }
    }

    private let replicas: [String: BoardReplica]
    private let codes: [BoardCode]
    private let myNonce: String
    private var theirNonce: String?
    private(set) var shared: [String: Shared] = [:]
    private var answered: Set<String> = []
    private var provedTo = false
    private var gotProofs = false

    /// `replicas` by board id, for every code in `codes`.
    init(codes: [BoardCode], replicas: [String: BoardReplica], nonce: String = UUID().uuidString) {
        self.codes = codes
        self.replicas = replicas
        myNonce = nonce
    }

    /// What to send first.
    func start() -> [BoardSyncMessage] { [.hello(version: BoardSyncMessage.version, nonce: myNonce)] }

    /// Every shared board has been answered both ways (or there was nothing to share).
    var isFinished: Bool {
        provedTo && gotProofs && shared.values.allSatisfy { $0.received != nil } && answered.count == shared.count
    }

    static func proofContext(prover: String, verifier: String) -> String { "ptb-board-sync|\(prover)|\(verifier)" }

    mutating func receive(_ message: BoardSyncMessage) throws -> [BoardSyncMessage] {
        switch message {
        case .hello(let version, let nonce):
            guard version == BoardSyncMessage.version else { throw BoardSyncError.incompatibleVersion(version) }
            guard theirNonce == nil, !nonce.isEmpty, nonce.count <= 64, nonce != myNonce else { throw BoardSyncError.protocolViolation }
            theirNonce = nonce
            provedTo = true
            let context = Self.proofContext(prover: myNonce, verifier: nonce)
            return [.proofs(codes.map { $0.proof(context) }.shuffled())]

        case .proofs(let proofs):
            guard let theirNonce, !gotProofs, proofs.count <= 200 else { throw BoardSyncError.protocolViolation }
            gotProofs = true
            let theirs = Set(proofs)
            let context = Self.proofContext(prover: theirNonce, verifier: myNonce)
            var out: [BoardSyncMessage] = []
            for code in codes where theirs.contains(code.proof(context)) {
                shared[code.boardId] = Shared(code: code, received: nil)
                let replica = replicas[code.boardId] ?? BoardReplica(boardId: code.boardId)
                out.append(.digest(boardId: code.boardId, records: replica.digest, receipts: Array(replica.receipts.keys).sorted()))
            }
            return out

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
}
