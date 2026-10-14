import CryptoKit
import XCTest
@testable import PokeTokenBar

final class BoardSyncProtocolTests: XCTestCase {
    private struct Peer {
        var codes: [BoardCode]
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
        try! BoardRecord.signed(boardId: code.boardId, boardName: "B", displayName: name, stats: BoardStats(),
                                joinedAt: 1, issuedAt: issued, left: false, key: key(n))
    }

    private func replica(_ code: BoardCode, _ rows: [BoardRecord]) -> BoardReplica {
        var r = BoardReplica(boardId: code.boardId)
        rows.forEach { r.merge($0, now: now) }
        return r
    }

    /// Runs both sessions to completion over in-order queues, merges what each received, and returns
    /// the updated peers plus every message that crossed.
    private func sync(_ a: inout Peer, _ b: inout Peer) throws {
        var sa = BoardSyncSession(codes: a.codes, replicas: a.replicas, nonce: "nonce-a")
        var sb = BoardSyncSession(codes: b.codes, replicas: b.replicas, nonce: "nonce-b")
        var toB = sa.start(), toA = sb.start()
        while !toA.isEmpty || !toB.isEmpty {
            let inboxB = toB, inboxA = toA
            toB = []; toA = []
            for m in inboxB { b.sent.append(m); toA += try sb.receive(m) }
            for m in inboxA { a.sent.append(m); toB += try sa.receive(m) }
        }
        XCTAssertTrue(sa.isFinished)
        XCTAssertTrue(sb.isFinished)
        for (id, entry) in sa.shared { entry.received!.records.forEach { _ = a.replicas[id]!.merge($0, now: now) } }
        for (id, entry) in sb.shared { entry.received!.records.forEach { _ = b.replicas[id]!.merge($0, now: now) } }
    }

    func testSyncsSharedBoardsAndNeverMentionsTheOthers() throws {
        var a = Peer(codes: [kanto, johto], replicas: [kanto.boardId: replica(kanto, [row(1, kanto, name: "Ash")]),
                                                        johto.boardId: replica(johto, [row(1, johto, name: "Ash")])])
        var b = Peer(codes: [kanto, hoenn], replicas: [kanto.boardId: replica(kanto, [row(2, kanto, name: "Misty")]),
                                                        hoenn.boardId: replica(hoenn, [row(2, hoenn, name: "Misty")])])
        try sync(&a, &b)
        XCTAssertEqual(Set(a.replicas[kanto.boardId]!.members.map(\.displayName)), ["Ash", "Misty"])
        XCTAssertEqual(a.replicas[kanto.boardId], b.replicas[kanto.boardId])
        XCTAssertEqual(a.replicas[johto.boardId]!.members.count, 1)
        XCTAssertEqual(b.replicas[hoenn.boardId]!.members.count, 1)
        // Nothing that crossed names an unshared board, its id or a code.
        let wire = String(decoding: try JSONEncoder().encode(a.sent + b.sent), as: UTF8.self)
        for secret in [johto.boardId, hoenn.boardId, johto.value, hoenn.value, kanto.value] {
            XCTAssertFalse(wire.contains(secret), secret)
        }
    }

    func testSendsOnlyNewerRows() throws {
        let shared = [row(1, kanto, name: "Ash", issued: 10), row(2, kanto, name: "Misty", issued: 10)]
        var a = Peer(codes: [kanto], replicas: [kanto.boardId: replica(kanto, shared + [row(1, kanto, name: "Ash v2", issued: 20)])])
        var b = Peer(codes: [kanto], replicas: [kanto.boardId: replica(kanto, shared)])
        try sync(&a, &b)
        let rowsFromA = a.sent.compactMap { if case .rows(_, let r, _) = $0 { return r } else { return nil } }.flatMap { $0 }
        let rowsFromB = b.sent.compactMap { if case .rows(_, let r, _) = $0 { return r } else { return nil } }.flatMap { $0 }
        // `sent` records what each side received: A received B's rows (none newer), B received A's update.
        XCTAssertEqual(rowsFromA, [])
        XCTAssertEqual(rowsFromB.map(\.displayName), ["Ash v2"])
        XCTAssertEqual(b.replicas[kanto.boardId]!.members.map(\.displayName).sorted(), ["Ash v2", "Misty"])
    }

    func testGossipReachesATrainerWhoNeverMetTheSource() throws {
        var ash = Peer(codes: [kanto], replicas: [kanto.boardId: replica(kanto, [row(1, kanto, name: "Ash")])])
        var brock = Peer(codes: [kanto], replicas: [kanto.boardId: replica(kanto, [row(2, kanto, name: "Brock")])])
        var misty = Peer(codes: [kanto], replicas: [kanto.boardId: replica(kanto, [row(3, kanto, name: "Misty")])])
        try sync(&ash, &brock)
        try sync(&brock, &misty)
        XCTAssertEqual(misty.replicas[kanto.boardId]!.members.map(\.displayName).sorted(), ["Ash", "Brock", "Misty"])
    }

    func testFinishesAtOnceWhenNothingIsShared() throws {
        var a = Peer(codes: [johto], replicas: [johto.boardId: replica(johto, [])])
        var b = Peer(codes: [hoenn], replicas: [hoenn.boardId: replica(hoenn, [])])
        try sync(&a, &b)
        XCTAssertFalse(a.sent.contains { if case .digest = $0 { return true } else { return false } })
    }

    func testRejectsOutOfOrderUnknownAndRepeatedMessages() {
        var s = BoardSyncSession(codes: [kanto], replicas: [:], nonce: "n")
        XCTAssertThrowsError(try s.receive(.proofs([])))   // before hello
        XCTAssertThrowsError(try s.receive(.hello(version: 99, nonce: "x"))) { error in
            XCTAssertEqual(error as? BoardSyncError, .incompatibleVersion(99))
        }
        XCTAssertThrowsError(try s.receive(.hello(version: BoardSyncMessage.version, nonce: "n")))  // our own nonce echoed
        XCTAssertNoThrow(try s.receive(.hello(version: BoardSyncMessage.version, nonce: "peer")))
        XCTAssertThrowsError(try s.receive(.hello(version: BoardSyncMessage.version, nonce: "again")))
        XCTAssertThrowsError(try s.receive(.digest(boardId: kanto.boardId, records: [:], receipts: [])))  // not proven shared
        XCTAssertThrowsError(try s.receive(.rows(boardId: kanto.boardId, records: [], receipts: [])))
        XCTAssertNoThrow(try s.receive(.proofs([])))
        XCTAssertThrowsError(try s.receive(.proofs([])))
        XCTAssertThrowsError(try BoardSyncMessage.decode(Data(repeating: 0x20, count: BoardSyncMessage.maxSize + 1)))
        XCTAssertThrowsError(try BoardSyncMessage.decode(Data("garbage".utf8)))
    }

    func testAProofFromAnotherSessionDoesNotProveAnything() throws {
        // A replays the proofs B sent in an earlier session; with fresh nonces they don't match.
        var earlier = BoardSyncSession(codes: [kanto], replicas: [:], nonce: "old-b")
        guard case .proofs(let replayed) = try earlier.receive(.hello(version: BoardSyncMessage.version, nonce: "old-a")).first else {
            return XCTFail("expected proofs")
        }
        var victim = BoardSyncSession(codes: [kanto], replicas: [kanto.boardId: replica(kanto, [row(1, kanto, name: "Ash")])], nonce: "new")
        _ = try victim.receive(.hello(version: BoardSyncMessage.version, nonce: "old-b"))
        XCTAssertEqual(try victim.receive(.proofs(replayed)), [])
    }
}
