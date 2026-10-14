import CryptoKit
import XCTest
@testable import PokeTokenBar

final class BoardModelTests: XCTestCase {
    private func key(_ n: UInt8) -> Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: n, count: 32))
    }
    private let code = BoardCode("ABCD-EFGH-JKMN")!
    private var boardId: String { code.boardId }
    private let now: Int64 = 1_760_000_000_000

    private func record(_ n: UInt8, name: String = "Ash", joined: Int64 = 1_000, issued: Int64 = 2_000, left: Bool = false,
                        stats: BoardStats = BoardStats(), board: String? = nil, boardName: String = "Kanto") -> BoardRecord {
        try! BoardRecord.signed(boardId: board ?? boardId, boardName: boardName, displayName: name, stats: stats,
                                joinedAt: joined, issuedAt: issued, left: left, key: key(n))
    }

    private func receipt(_ a: UInt8, _ b: UInt8, winner: UInt8?, id: String, at startedAt: Int64,
                         signers: [UInt8]? = nil, board: String? = nil) -> BattleReceipt {
        let ka = TrainerSigning.encode(key(a).publicKey), kb = TrainerSigning.encode(key(b).publicKey)
        var r = BattleReceipt(battleId: id, boardId: board ?? boardId, keys: [ka, kb],
                              winner: winner.map { TrainerSigning.encode(key($0).publicKey) }, startedAt: startedAt)
        for s in signers ?? [a, b] { r.signatures[TrainerSigning.encode(key(s).publicKey)] = try! r.signature(by: key(s)) }
        return r
    }

    // MARK: Codes and identity

    func testCodesNormalizeLookAlikesAndRejectOthers() {
        XCTAssertEqual(BoardCode("abcd-efgh-jkmn")?.value, "ABCDEFGHJKMN")
        XCTAssertEqual(BoardCode("0OIL 0000 0000")?.value, "001100000000")
        XCTAssertNil(BoardCode("ABCD-EFGH-JKMU"))   // U isn't Crockford
        XCTAssertNil(BoardCode("ABCD-EFGH"))
        XCTAssertEqual(code.display, "ABCD-EFGH-JKMN")
        let random = BoardCode.random()
        XCTAssertEqual(BoardCode(random.display), random)
    }

    func testBoardIdAndProofsDependOnTheCodeOnly() {
        XCTAssertEqual(code.boardId, BoardCode("abcdefghjkmn")!.boardId)
        XCTAssertNotEqual(code.boardId, BoardCode("ABCDEFGHJKMP")!.boardId)
        XCTAssertEqual(code.proof("x"), BoardCode("abcd efgh jkmn")!.proof("x"))
        XCTAssertNotEqual(code.proof("x"), code.proof("y"))
    }

    func testFingerprintIsFourStableCrockfordCharacters() {
        let fp = TrainerSigning.fingerprint(TrainerSigning.encode(key(7).publicKey))
        XCTAssertEqual(fp.count, 4)
        XCTAssertEqual(fp, TrainerSigning.fingerprint(TrainerSigning.encode(key(7).publicKey)))
        XCTAssertNotEqual(fp, TrainerSigning.fingerprint(TrainerSigning.encode(key(8).publicKey)))
        XCTAssertTrue(fp.allSatisfy { Crockford.alphabet.contains($0) })
    }

    func testKeychainAccountIsPerStateDirectory() {
        XCTAssertEqual(TrainerKeyStore.account(environment: [:]), "trainer-signing-key")
        let a = TrainerKeyStore.account(environment: ["PTB_STATE_DIR": "/tmp/a"])
        XCTAssertNotEqual(a, TrainerKeyStore.account(environment: ["PTB_STATE_DIR": "/tmp/b"]))
        XCTAssertTrue(a.hasPrefix("trainer-signing-key-"))
    }

    // MARK: Records

    func testRecordMessageIsPinned() {
        let message = BoardRecord.message(boardId: "b", boardName: "Kanto", publicKey: "k", displayName: "Ash",
                                          stats: BoardStats(), joinedAt: 1, issuedAt: 2, left: false)
        XCTAssertEqual(String(decoding: message, as: UTF8.self), """
        PTB-BOARD-RECORD-V1
        {"boardId":"b","boardName":"Kanto","displayName":"Ash","issuedAt":2,"joinedAt":1,"left":false,"publicKey":"k",\
        "stats":{"battleRecord":{"draws":0,"losses":0,"wins":0},"collection":{"dex":0,"graduated":0,"shinies":0,"species":0},\
        "levels":{"teamTotal":0,"top":0}}}
        """)
    }

    func testRecordsSurviveAJSONRoundTripWithTheirSignature() throws {
        let original = record(1, stats: BoardStats(aiBand: .heavy))
        let decoded = try JSONDecoder().decode(BoardRecord.self, from: JSONEncoder().encode(original))
        XCTAssertTrue(decoded.hasValidSignature)
        XCTAssertTrue(decoded.isAcceptable(for: boardId, now: now))
    }

    func testRejectsForgedOutOfBoundsFutureAndForeignRecords() {
        let good = record(1)
        var replica = BoardReplica(boardId: boardId)
        let forged = BoardRecord(boardId: good.boardId, boardName: good.boardName, publicKey: good.publicKey, displayName: "Mallory",
                                 stats: good.stats, joinedAt: good.joinedAt, issuedAt: good.issuedAt, left: false, signature: good.signature)
        XCTAssertFalse(replica.merge(forged, now: now))
        XCTAssertFalse(replica.merge(record(1, stats: BoardStats(levels: .init(teamTotal: 601, top: 100))), now: now))
        XCTAssertFalse(replica.merge(record(1, stats: BoardStats(collection: .init(dex: 1, species: 1, shinies: 2))), now: now))
        XCTAssertFalse(replica.merge(record(1, issued: now + BoardRules.maxClockSkewMs + 1), now: now))
        XCTAssertFalse(replica.merge(record(1, board: BoardCode("ABCDEFGHJKMP")!.boardId), now: now))
        XCTAssertFalse(replica.merge(record(1, joined: 3_000, issued: 2_000), now: now))
        XCTAssertFalse(replica.merge(record(1, name: "   "), now: now))
        XCTAssertFalse(replica.merge(record(1, name: String(repeating: "a", count: 33)), now: now))
        XCTAssertTrue(replica.records.isEmpty)
        XCTAssertTrue(replica.merge(good, now: now))
    }

    func testNewestRowWinsAndTombstonesCanBeUndone() {
        var replica = BoardReplica(boardId: boardId)
        XCTAssertTrue(replica.merge(record(1, name: "Ash", issued: 2_000), now: now))
        XCTAssertFalse(replica.merge(record(1, name: "Old", issued: 1_500), now: now))
        XCTAssertTrue(replica.merge(record(1, issued: 3_000, left: true), now: now))
        XCTAssertTrue(replica.members.isEmpty)
        XCTAssertEqual(replica.name, "Kanto", "a tombstone keeps the board's name")
        XCTAssertTrue(replica.merge(record(1, name: "Back", issued: 4_000), now: now))
        XCTAssertEqual(replica.members.map(\.displayName), ["Back"])
    }

    func testMergeConvergesWhateverTheOrder() {
        let rows = (1...6).flatMap { n in
            [record(UInt8(n), name: "T\(n)", joined: Int64(n), issued: 10), record(UInt8(n), name: "T\(n)b", joined: Int64(n), issued: 20)]
        } + [record(3, issued: 30, left: true), record(4, name: "same-time", joined: 4, issued: 20)]
        let receipts = [receipt(1, 2, winner: 1, id: "b1", at: 5_000), receipt(2, 5, winner: nil, id: "b2", at: 6_000)]
        var reference = BoardReplica(boardId: boardId)
        rows.forEach { reference.merge($0, now: now) }
        receipts.forEach { reference.merge($0, now: now) }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            // Split into two replicas fed in different orders, then merge them into each other.
            let shuffled = rows.shuffled(using: &generator)
            var a = BoardReplica(boardId: boardId), b = BoardReplica(boardId: boardId)
            shuffled.prefix(7).forEach { a.merge($0, now: now) }
            shuffled.dropFirst(7).forEach { b.merge($0, now: now) }
            receipts.shuffled().forEach { a.merge($0, now: now); b.merge($0, now: now) }
            b.records.values.shuffled().forEach { a.merge($0, now: now) }
            a.records.values.shuffled().forEach { b.merge($0, now: now) }
            XCTAssertEqual(a, reference)
            XCTAssertEqual(b, reference)
        }
    }

    func testCapKeepsTheSameEarliestMembersEverywhere() {
        let rows = (1...(BoardRules.memberCap + 1)).map { n in
            try! BoardRecord.signed(boardId: boardId, boardName: "Big", displayName: "T\(n)", stats: BoardStats(),
                                    joinedAt: Int64(n), issuedAt: Int64(n), left: false,
                                    key: Curve25519.Signing.PrivateKey())
        }
        var a = BoardReplica(boardId: boardId), b = BoardReplica(boardId: boardId)
        rows.forEach { a.merge($0, now: now) }
        rows.reversed().forEach { b.merge($0, now: now) }
        XCTAssertEqual(a.members.count, BoardRules.memberCap)
        XCTAssertEqual(a.members.map(\.publicKey), b.members.map(\.publicKey))
        XCTAssertFalse(a.members.contains { $0.displayName == "T\(BoardRules.memberCap + 1)" })
    }

    // MARK: Receipts and scoring

    func testReceiptsNeedBothSignaturesAndAWinnerFromTheBattle() {
        XCTAssertTrue(receipt(1, 2, winner: 1, id: "x", at: 1).isComplete)
        XCTAssertTrue(receipt(1, 2, winner: nil, id: "x", at: 1).isComplete)
        XCTAssertFalse(receipt(1, 2, winner: 1, id: "x", at: 1, signers: [1]).isComplete)
        XCTAssertFalse(receipt(1, 2, winner: 3, id: "x", at: 1).isComplete)
        XCTAssertFalse(receipt(1, 1, winner: 1, id: "x", at: 1, signers: [1]).isComplete)
        var tampered = receipt(1, 2, winner: 1, id: "x", at: 1)
        tampered = BattleReceipt(battleId: "x", boardId: boardId, keys: tampered.keys,
                                 winner: TrainerSigning.encode(key(2).publicKey), startedAt: 1, signatures: tampered.signatures)
        XCTAssertFalse(tampered.isComplete)
        var replica = BoardReplica(boardId: boardId)
        XCTAssertFalse(replica.merge(receipt(1, 2, winner: 1, id: "x", at: 1, board: "other"), now: now))
    }

    func testScoresCountOnlyMembersAndThreeResultsPerPairPerWeek() {
        var replica = BoardReplica(boardId: boardId)
        replica.merge(record(1, name: "Ash", joined: 1,
                             stats: BoardStats(collection: .init(dex: 10, species: 8, shinies: 1, graduated: 3),
                                               levels: .init(teamTotal: 205, top: 60), aiBand: .moderate)), now: now)
        replica.merge(record(2, name: "Misty", joined: 2), now: now)
        let monday: Int64 = 1_760_313_600_000   // 2025-10-13, a Monday (UTC)
        for i in 0..<5 { replica.merge(receipt(1, 2, winner: 1, id: "w\(i)", at: monday + Int64(i) * 1000), now: now + 1_000_000_000) }
        replica.merge(receipt(1, 2, winner: nil, id: "nextweek", at: monday + 7 * 86_400_000), now: now + 1_000_000_000)
        replica.merge(receipt(1, 3, winner: 1, id: "outsider", at: monday), now: now + 1_000_000_000)

        let standings = BoardScoring.standings(replica)
        XCTAssertEqual(standings.map(\.record.displayName), ["Ash", "Misty"])
        let ash = standings[0]
        // 3 counted wins × 3 + draw 1; species 8 + shiny 5 + graduated 6; 205 / 10; moderate = 2.
        XCTAssertEqual(ash.score, BoardScoring.Score(battle: 10, collection: 19, levels: 20, ai: 2))
        XCTAssertEqual(ash.counted, BoardScoring.Counted(wins: 3, draws: 1, losses: 0))
        XCTAssertEqual(standings[1].counted, BoardScoring.Counted(wins: 0, draws: 1, losses: 3))
        XCTAssertEqual(standings[1].score.battle, 1)
    }

    func testEqualTotalsShareARank() {
        var replica = BoardReplica(boardId: boardId)
        replica.merge(record(1, name: "Brock", joined: 1), now: now)
        replica.merge(record(2, name: "Ash", joined: 2), now: now)
        replica.merge(record(3, name: "Misty", joined: 3, stats: BoardStats(collection: .init(dex: 1, species: 1))), now: now)
        let standings = BoardScoring.standings(replica)
        XCTAssertEqual(standings.map(\.record.displayName), ["Misty", "Ash", "Brock"])
        XCTAssertEqual(standings.map(\.rank), [1, 2, 2])
    }

    func testStatsFromTheShowcase() {
        let showcase = TrainerShowcase(
            pokemon: [
                .init(instanceId: "a", speciesNum: 25, species: "Pikachu", form: nil, shiny: true, nature: nil, gender: nil,
                      level: 40, ability: nil, moves: [], caughtAt: nil, status: .graduated),
                .init(instanceId: "b", speciesNum: 25, species: "Pikachu", form: nil, shiny: false, nature: nil, gender: nil,
                      level: 12, ability: nil, moves: [], caughtAt: nil, status: .released),
                .init(instanceId: "c", speciesNum: 1, species: "Bulbasaur", form: nil, shiny: false, nature: nil, gender: nil,
                      level: 55, ability: nil, moves: [], caughtAt: nil, status: .active),
            ],
            battleTeam: ["c", "a", "missing"], battleRecord: BattleRecord(wins: 2, losses: 1, draws: 0),
            gameStats: TrainerShowcase.stats([]))
        let stats = BoardStats(showcase: TrainerShowcase(pokemon: showcase.pokemon, battleTeam: showcase.battleTeam,
                                                          battleRecord: showcase.battleRecord,
                                                          gameStats: TrainerShowcase.stats(showcase.pokemon)),
                               aiBand: nil)
        XCTAssertEqual(stats.collection, .init(dex: 3, species: 2, shinies: 1, graduated: 1))
        XCTAssertEqual(stats.levels, .init(teamTotal: 95, top: 55))
        XCTAssertNil(stats.aiBand)
        XCTAssertEqual(stats.battleRecord.wins, 2)
    }
}
