import CryptoKit
import XCTest
@testable import PokeTokenBar

final class BoardSyncProtocolTests: XCTestCase {
    private struct Peer {
        var replicas: [String: BoardReplica]
        var sent: [BoardSyncMessage] = []
    }

    private let kanto = BoardCode("KANT-0000-0001")!
    private let johto = BoardCode("J0HT-0000-0002")!
    private let hoenn = BoardCode("H0EN-0000-0003")!
    private let now: Int64 = 1_760_000_000_000

    private func key(_ n: UInt8) -> Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: n, count: 32))
    }

    private func row(_ n: UInt8, _ code: BoardCode, name: String, issued: Int64 = 10) -> BoardRecord {
        try! BoardRecord.signed(code: code, boardName: "B", displayName: name, stats: BoardStats(),
                                joinedAt: 1, issuedAt: issued, left: false, key: key(n))
    }

    private func replica(_ code: BoardCode, _ rows: [BoardRecord]) -> BoardReplica {
        var r = BoardReplica(boardId: code.boardId)
        rows.forEach { r.merge($0, now: now) }
        return r
    }

    private func names(_ peer: Peer, _ code: BoardCode) -> [String] {
        (peer.replicas[code.boardId]?.members.map(\.displayName) ?? []).sorted()
    }

    /// Runs both sessions to completion over in-order queues, merges what each received (keeping a board
    /// only when a valid row came with it, as the store does), and records every message that crossed.
    private func sync(_ a: inout Peer, _ b: inout Peer) throws {
        var sa = BoardSyncSession(replicas: a.replicas, nonce: "nonce-a")
        var sb = BoardSyncSession(replicas: b.replicas, nonce: "nonce-b")
        var toB = sa.start(), toA = sb.start()
        while !toA.isEmpty || !toB.isEmpty {
            let inboxB = toB, inboxA = toA
            toB = []; toA = []
            for m in inboxB { b.sent.append(m); toA += try sb.receive(m) }
            for m in inboxA { a.sent.append(m); toB += try sa.receive(m) }
        }
        XCTAssertTrue(sa.isFinished)
        XCTAssertTrue(sb.isFinished)
        func merge(_ peer: inout Peer, _ session: BoardSyncSession) {
            for (id, entry) in session.shared {
                var replica = peer.replicas[id] ?? BoardReplica(boardId: id)
                entry.received!.records.forEach { replica.merge($0, now: now) }
                if !replica.records.isEmpty { peer.replicas[id] = replica }
            }
        }
        merge(&a, sa)
        merge(&b, sb)
    }

    func testEveryBoardEitherSideHoldsGoesBothWays() throws {
        var a = Peer(replicas: [kanto.boardId: replica(kanto, [row(1, kanto, name: "Ash")]),
                                johto.boardId: replica(johto, [row(1, johto, name: "Ash")])])
        var b = Peer(replicas: [kanto.boardId: replica(kanto, [row(2, kanto, name: "Misty")]),
                                hoenn.boardId: replica(hoenn, [row(2, hoenn, name: "Misty")])])
        try sync(&a, &b)
        XCTAssertEqual(names(a, kanto), ["Ash", "Misty"])
        XCTAssertEqual(a.replicas, b.replicas)
        XCTAssertEqual(names(a, hoenn), ["Misty"], "watched without the code")
        XCTAssertEqual(names(b, johto), ["Ash"])
        // Standings are public; codes never cross.
        let wire = String(decoding: try JSONEncoder().encode(a.sent + b.sent), as: UTF8.self)
        for code in [kanto, johto, hoenn] { XCTAssertFalse(wire.contains(code.value), code.value) }
    }

    func testAWatcherPassesLeaguesOnWithoutBeingInAny() throws {
        var ash = Peer(replicas: [kanto.boardId: replica(kanto, [row(1, kanto, name: "Ash")])])
        var watcher = Peer(replicas: [:])
        var misty = Peer(replicas: [kanto.boardId: replica(kanto, [row(3, kanto, name: "Misty")])])
        try sync(&ash, &watcher)
        try sync(&watcher, &misty)
        XCTAssertEqual(names(misty, kanto), ["Ash", "Misty"])
        XCTAssertEqual(names(watcher, kanto), ["Ash", "Misty"])
    }

    func testRowsWithoutAMembershipFromTheCodeAreDropped() throws {
        // Mallory has no Kanto code: she signs her own row for Kanto's public id, with a league key she made up,
        // or with Kanto's public key and a membership she signed herself.
        let fake = BoardCode("FAKE-0000-0009")!
        func forged(leagueKey: String, membership: String) throws -> BoardRecord {
            let publicKey = TrainerSigning.encode(key(9).publicKey)
            let message = BoardRecord.message(boardId: kanto.boardId, boardName: "B", publicKey: publicKey, displayName: "Mallory",
                                              stats: BoardStats(), joinedAt: 1, issuedAt: 10, left: false)
            return BoardRecord(boardId: kanto.boardId, boardName: "B", publicKey: publicKey, displayName: "Mallory",
                               stats: BoardStats(), joinedAt: 1, issuedAt: 10, left: false,
                               signature: try TrainerSigning.sign(message, with: key(9)), leagueKey: leagueKey, membership: membership)
        }
        let publicKey = TrainerSigning.encode(key(9).publicKey)
        let ownKey = try forged(leagueKey: fake.leagueKey,
                                membership: try TrainerSigning.sign(BoardRecord.membershipMessage(boardId: kanto.boardId, publicKey: publicKey),
                                                                    with: fake.signingKey))
        let selfSigned = try forged(leagueKey: kanto.leagueKey,
                                    membership: try TrainerSigning.sign(BoardRecord.membershipMessage(boardId: kanto.boardId, publicKey: publicKey),
                                                                        with: key(9)))
        let none = try forged(leagueKey: "", membership: "")
        for row in [ownKey, selfSigned, none] { XCTAssertTrue(row.hasValidSignature) }

        // She can list Kanto and send rows for it, but none of them sticks.
        var ash = Peer(replicas: [kanto.boardId: replica(kanto, [row(1, kanto, name: "Ash")])])
        var sa = BoardSyncSession(replicas: ash.replicas, nonce: "a")
        _ = try sa.receive(.hello(version: BoardSyncMessage.version, nonce: "m"))
        _ = try sa.receive(.boards([kanto.boardId]))
        _ = try sa.receive(.rows(boardId: kanto.boardId, records: [ownKey, selfSigned, none], receipts: []))
        sa.shared[kanto.boardId]!.received!.records.forEach { ash.replicas[kanto.boardId]!.merge($0, now: now) }
        XCTAssertEqual(names(ash, kanto), ["Ash"])
    }

    func testSendsOnlyNewerRows() throws {
        let shared = [row(1, kanto, name: "Ash", issued: 10), row(2, kanto, name: "Misty", issued: 10)]
        var a = Peer(replicas: [kanto.boardId: replica(kanto, shared + [row(1, kanto, name: "Ash v2", issued: 20)])])
        var b = Peer(replicas: [kanto.boardId: replica(kanto, shared)])
        try sync(&a, &b)
        let rowsFromA = a.sent.compactMap { if case .rows(_, let r, _) = $0 { return r } else { return nil } }.flatMap { $0 }
        let rowsFromB = b.sent.compactMap { if case .rows(_, let r, _) = $0 { return r } else { return nil } }.flatMap { $0 }
        // `sent` records what each side received: A received B's rows (none newer), B received A's update.
        XCTAssertEqual(rowsFromA, [])
        XCTAssertEqual(rowsFromB.map(\.displayName), ["Ash v2"])
        XCTAssertEqual(names(b, kanto), ["Ash v2", "Misty"])
    }

    func testFinishesAtOnceWhenNeitherHoldsAnything() throws {
        var a = Peer(replicas: [:]), b = Peer(replicas: [:])
        try sync(&a, &b)
        XCTAssertFalse((a.sent + b.sent).contains { if case .digest = $0 { return true } else { return false } })
    }

    func testRejectsOutOfOrderUnknownOversizedAndRepeatedMessages() {
        var s = BoardSyncSession(replicas: [:], nonce: "n")
        XCTAssertThrowsError(try s.receive(.boards([])))   // before hello
        XCTAssertThrowsError(try s.receive(.hello(version: 1, nonce: "x"))) { error in
            XCTAssertEqual(error as? BoardSyncError, .incompatibleVersion(1), "proof-based peers can't join")
        }
        XCTAssertThrowsError(try s.receive(.hello(version: BoardSyncMessage.version, nonce: "n")))  // our own nonce echoed
        XCTAssertNoThrow(try s.receive(.hello(version: BoardSyncMessage.version, nonce: "peer")))
        XCTAssertThrowsError(try s.receive(.hello(version: BoardSyncMessage.version, nonce: "again")))
        XCTAssertThrowsError(try s.receive(.digest(boardId: kanto.boardId, records: [:], receipts: [])))  // not listed yet
        XCTAssertThrowsError(try s.receive(.rows(boardId: kanto.boardId, records: [], receipts: [])))
        var tooMany = s, badId = s
        XCTAssertThrowsError(try tooMany.receive(.boards((0...BoardSyncMessage.maxBoards).map { _ in kanto.boardId })))
        XCTAssertThrowsError(try badId.receive(.boards(["../not-an-id"])))
        XCTAssertNoThrow(try s.receive(.boards([kanto.boardId])))
        XCTAssertThrowsError(try s.receive(.boards([])))
        XCTAssertNoThrow(try s.receive(.rows(boardId: kanto.boardId, records: [], receipts: [])))
        XCTAssertThrowsError(try s.receive(.rows(boardId: kanto.boardId, records: [], receipts: [])))
        XCTAssertThrowsError(try BoardSyncMessage.decode(Data(repeating: 0x20, count: BoardSyncMessage.maxSize + 1)))
        XCTAssertThrowsError(try BoardSyncMessage.decode(Data("garbage".utf8)))
    }
}
