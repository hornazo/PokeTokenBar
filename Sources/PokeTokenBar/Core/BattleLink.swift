import CryptoKit
import Foundation

/// Everything two peers say to each other. Only choices travel after the handshake: both sides run the
/// same deterministic engine, and every choice carries a digest of the state it was made in.
enum BattleWireMessage: Codable, Sendable, Equatable {
    /// The invitation's context: who challenges, and for which board (a friendly when nil).
    case invite(protocolVersion: Int, trainer: String, board: BattleBoardInvite?)
    case hello(protocolVersion: Int, trainer: String)
    case team(BattleTeam)
    case nonce(UInt64)
    /// After the nonces: the trainer's board key, the challenger's start time for a board battle, and the
    /// accepting side's proof that it holds that board's code.
    case identity(publicKey: String, startedAt: Int64?, boardProof: String?)
    case action(turn: Int, action: BattleAction, digest: String)
    /// No digest: when both sides replace, each applies the two picks in its own order. The next
    /// action's digest covers the result.
    case replacement(turn: Int, index: Int)
    /// Carries the forfeiting side's signature on the result of a board battle, so the winner can keep it.
    case forfeit(receipt: String?)
    /// Each side's signature on the result of a board battle that ended on the field.
    case receipt(signature: String)

    static let protocolVersion = 4
    static let maxSize = 256 * 1024

    func encoded() throws -> Data { try JSONEncoder().encode(self) }

    static func decode(_ data: Data) throws -> BattleWireMessage {
        guard data.count <= maxSize else { throw BattleLinkError.protocolViolation }
        return try JSONDecoder().decode(BattleWireMessage.self, from: data)
    }
}

enum BattleLinkError: Error, Equatable, Sendable {
    /// The peer is gone: closed the app, walked out of range, or stopped answering.
    case disconnected
    case timedOut
    case peerForfeited
    /// Nobody's fault as far as we can tell, so no winner: the states diverged or a message made no sense.
    case desync
    case protocolViolation
    case incompatibleVersion(Int)

    var abortsWithoutWinner: Bool {
        switch self {
        case .desync, .protocolViolation, .incompatibleVersion: return true
        case .disconnected, .timedOut, .peerForfeited: return false
        }
    }
}

extension BattleState {
    /// Sorted-key JSON of the full state, including the RNG, so any divergence changes the digest.
    var digest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// A connected, ordered, reliable pipe to one peer.
@MainActor
protocol BattleTransport: AnyObject {
    var onReceive: ((Data) -> Void)? { get set }
    var onDisconnect: (() -> Void)? { get set }
    func send(_ data: Data) throws
    func close()
}

/// In-process pair for tests and for exercising the full protocol without a network.
@MainActor
final class LoopbackTransport: BattleTransport {
    var onReceive: ((Data) -> Void)?
    var onDisconnect: (() -> Void)?
    private weak var peer: LoopbackTransport?
    private var isOpen = true

    static func pair() -> (LoopbackTransport, LoopbackTransport) {
        let a = LoopbackTransport(), b = LoopbackTransport()
        a.peer = b
        b.peer = a
        return (a, b)
    }

    /// Delivered later on the main queue, which keeps order — like a real transport, and unlike `Task`.
    func send(_ data: Data) throws {
        guard isOpen, let peer, peer.isOpen else { throw BattleLinkError.disconnected }
        let box = UncheckedPeer(peer: peer)
        DispatchQueue.main.async { MainActor.assumeIsolated { box.peer.onReceive?(data) } }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        guard let peer else { return }
        let box = UncheckedPeer(peer: peer)
        DispatchQueue.main.async { MainActor.assumeIsolated { box.peer.closeFromPeer() } }
    }

    private func closeFromPeer() {
        guard isOpen else { return }
        isOpen = false
        onDisconnect?()
    }
}

private struct UncheckedPeer: @unchecked Sendable {
    let peer: LoopbackTransport
}

/// Buffers messages that arrive before anyone asks for them; one waiter at a time, each with its own timeout.
@MainActor
final class BattleMailbox {
    private var buffer: [BattleWireMessage] = []
    private var waiter: (id: Int, continuation: CheckedContinuation<BattleWireMessage, Error>)?
    private var nextID = 0
    private(set) var closedWith: BattleLinkError?

    func deliver(_ message: BattleWireMessage) {
        guard closedWith == nil else { return }
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: message)
        } else {
            buffer.append(message)
        }
    }

    func close(_ error: BattleLinkError) {
        guard closedWith == nil else { return }
        closedWith = error
        buffer.removeAll()
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(throwing: error)
        }
    }

    func next(timeout: Duration) async throws -> BattleWireMessage {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if let closedWith { throw closedWith }
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            waiter = (id, continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.expire(id)
            }
        }
    }

    private func expire(_ id: Int) {
        guard let waiter, waiter.id == id else { return }
        self.waiter = nil
        waiter.continuation.resume(throwing: BattleLinkError.timedOut)
    }
}

/// One battle's worth of conversation with a peer, on top of any transport.
@MainActor
final class BattleLink {
    let transport: any BattleTransport
    let mailbox = BattleMailbox()
    /// Fires once when the peer forfeits or disappears, so a player who is still thinking hears it at once.
    var onInterrupt: ((BattleLinkError) -> Void)?
    /// The peer's signature on our win, when it forfeited a board battle.
    private(set) var peerForfeitReceipt: String?

    init(transport: any BattleTransport) {
        self.transport = transport
        transport.onReceive = { [weak self] data in self?.receive(data) }
        transport.onDisconnect = { [weak self] in self?.interrupt(.disconnected) }
    }

    func send(_ message: BattleWireMessage) throws {
        guard mailbox.closedWith == nil else { throw mailbox.closedWith ?? .disconnected }
        try transport.send(try message.encoded())
    }

    func next(timeout: Duration) async throws -> BattleWireMessage {
        try await mailbox.next(timeout: timeout)
    }

    func close() {
        mailbox.close(.disconnected)
        transport.close()
    }

    private func receive(_ data: Data) {
        guard let message = try? BattleWireMessage.decode(data) else { return interrupt(.protocolViolation) }
        if case .forfeit(let receipt) = message {
            peerForfeitReceipt = receipt
            return interrupt(.peerForfeited)
        }
        mailbox.deliver(message)
    }

    private func interrupt(_ error: BattleLinkError) {
        guard mailbox.closedWith == nil else { return }
        mailbox.close(error)
        onInterrupt?(error)
    }
}

/// A challenge for a board: a fresh nonce and the challenger's proof of holding the board's code.
struct BattleBoardInvite: Codable, Sendable, Equatable {
    let nonce: String
    let proof: String

    static func make(for code: BoardCode, nonce: String = UUID().uuidString) -> BattleBoardInvite {
        BattleBoardInvite(nonce: nonce, proof: code.proof("ptb-battle-invite|\(nonce)"))
    }

    /// The code among ours that this invite was made for, if any.
    func board(in codes: [BoardCode]) -> BoardCode? {
        codes.first { $0.proof("ptb-battle-invite|\(nonce)") == proof }
    }

    static func acceptProof(_ code: BoardCode, nonce: String, acceptingKey: String) -> String {
        code.proof("ptb-battle-accept|\(nonce)|\(acceptingKey)")
    }
}

/// The board a battle is fought for, as one side sees it before the handshake.
struct BattleScope: Sendable, Equatable {
    let code: BoardCode
    let invite: BattleBoardInvite
    /// Set by the challenger; the accepting side learns it in the handshake.
    let startedAt: Int64?
}

/// What both sides agree on before turn one.
struct BattleMatch: Sendable, Equatable {
    let mySide: BattleSide
    let myTeam: BattleTeam
    let opponentTeam: BattleTeam
    let opponentName: String
    let seed: UInt64
    /// SHA-256 of both nonces in challenger order: the same on both Macs, unique per battle.
    var battleId = ""
    var myKey: String?
    var opponentKey: String?
    /// The board both sides proved they hold and agreed on; nil for a friendly.
    var board: BoardCode?
    var startedAt: Int64?

    /// The unsigned result of a finished board battle, identical on both sides.
    func receipt(winner: BattleSide?) -> BattleReceipt? {
        guard let board, let myKey, let opponentKey, let startedAt, myKey != opponentKey else { return nil }
        let key: (BattleSide) -> String = { $0 == mySide ? myKey : opponentKey }
        return BattleReceipt(battleId: battleId, boardId: board.boardId, keys: [myKey, opponentKey],
                             winner: winner.map(key), startedAt: startedAt)
    }
}

enum BattleHandshake {
    static let timeout: Duration = .seconds(20)

    /// The challenger plays side `.a` on both machines; the seed mixes both nonces in that fixed order.
    /// Not tamper-proof — a peer could wait for our nonce before sending its own — which is acceptable
    /// because nothing is at stake in a battle.
    ///
    /// `publicKey` is the trainer's board key (nil when it couldn't be loaded: the battle is then a
    /// friendly). With a `scope`, the battle counts for that board only if the other side proves it
    /// holds the same code, and the challenger's start time is within the clock skew boards allow.
    @MainActor
    static func run(_ link: BattleLink, isChallenger: Bool, trainer: String, team: BattleTeam,
                    nonce: UInt64, publicKey: String? = nil, scope: BattleScope? = nil,
                    now: Int64 = BoardRules.now()) async throws -> BattleMatch {
        try link.send(.hello(protocolVersion: BattleWireMessage.protocolVersion, trainer: trainer))
        try link.send(.team(team))
        try link.send(.nonce(nonce))
        let proof = publicKey.flatMap { key in
            isChallenger ? nil : scope.map { BattleBoardInvite.acceptProof($0.code, nonce: $0.invite.nonce, acceptingKey: key) }
        }
        try link.send(.identity(publicKey: publicKey ?? "", startedAt: isChallenger ? scope?.startedAt : nil, boardProof: proof))

        guard case .hello(let version, let peerName) = try await link.next(timeout: timeout) else {
            throw BattleLinkError.protocolViolation
        }
        guard version == BattleWireMessage.protocolVersion else { throw BattleLinkError.incompatibleVersion(version) }
        guard case .team(let peerTeam) = try await link.next(timeout: timeout) else { throw BattleLinkError.protocolViolation }
        guard case .nonce(let peerNonce) = try await link.next(timeout: timeout) else { throw BattleLinkError.protocolViolation }
        guard case .identity(let peerKey, let peerStart, let peerProof) = try await link.next(timeout: timeout) else {
            throw BattleLinkError.protocolViolation
        }

        let (first, second) = isChallenger ? (nonce, peerNonce) : (peerNonce, nonce)
        var mixer = BattleRNG(seed: first ^ (second &* 0x9E37_79B9_7F4A_7C15))
        var match = BattleMatch(mySide: isChallenger ? .a : .b, myTeam: team, opponentTeam: peerTeam,
                                opponentName: String(peerName.prefix(BattleTrainer.maxNameLength)), seed: mixer.next())
        match.battleId = TrainerSigning.sha256Hex(Data("\(first):\(second)".utf8))
        let opponentKey = TrainerSigning.publicKey(peerKey) != nil ? peerKey : nil
        match.myKey = publicKey
        match.opponentKey = opponentKey
        if let scope, let publicKey, let opponentKey, publicKey != opponentKey {
            if isChallenger {
                // The other side proves it holds the code, bound to our invite and its own key.
                if peerProof == BattleBoardInvite.acceptProof(scope.code, nonce: scope.invite.nonce, acceptingKey: opponentKey) {
                    match.board = scope.code
                    match.startedAt = scope.startedAt
                }
            } else if let peerStart, abs(peerStart - now) <= BoardRules.maxClockSkewMs {
                match.board = scope.code
                match.startedAt = peerStart
            }
        }
        return match
    }
}

enum BattleTrainer {
    static let maxNameLength = 24
    static let defaultsKey = "battleTrainerName"

    static func sanitized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isNewline && !($0.unicodeScalars.first?.properties.generalCategory == .control) }
        return String(trimmed.prefix(maxNameLength))
    }

    /// Never the Mac's name or the user's real name: this is shown to strangers nearby.
    static func defaultName(random: UInt64 = UInt64.random(in: 0...UInt64.max)) -> String {
        "Trainer \(1000 + random % 9000)"
    }
}

/// The remote player, speaking through a `BattleLink`.
@MainActor
final class NetworkOpponent: BattleOpponent {
    let link: BattleLink
    /// Longer than the peer's own turn timer, so a slow but present player is not declared gone.
    let patience: Duration
    /// Our signature on the peer's win, sent with a forfeit of a board battle.
    var forfeitReceipt: (() -> String?)?

    init(link: BattleLink, patience: Duration = .seconds(90)) {
        self.link = link
        self.patience = patience
    }

    func exchange(_ mine: BattleAction, in state: BattleState, side: BattleSide) async throws -> BattleAction {
        let digest = state.digest
        try link.send(.action(turn: state.turn, action: mine, digest: digest))
        guard case .action(let turn, let theirs, let theirDigest) = try await link.next(timeout: patience) else {
            throw BattleLinkError.protocolViolation
        }
        guard turn == state.turn, theirDigest == digest else { throw BattleLinkError.desync }
        return theirs
    }

    func sendReplacement(_ index: Int, in state: BattleState) async throws {
        try link.send(.replacement(turn: state.turn, index: index))
    }

    func replacement(in state: BattleState, side: BattleSide) async throws -> Int {
        guard case .replacement(let turn, let index) = try await link.next(timeout: patience) else {
            throw BattleLinkError.protocolViolation
        }
        guard turn == state.turn else { throw BattleLinkError.desync }
        return index
    }

    func notifyForfeit() { try? link.send(.forfeit(receipt: forfeitReceipt?())) }
    func close() { link.close() }
}
