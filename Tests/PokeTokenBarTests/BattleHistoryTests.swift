import CryptoKit
import XCTest
@testable import PokeTokenBar

@MainActor
final class BattleHistoryTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("BattleHistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func mon(_ id: String, hp: Int) -> BattlePokemon {
        let tackle = BattleMove(name: "tackle", type: "normal", power: 40, accuracy: nil, pp: 20, priority: 0,
                                damageClass: .physical, target: "selected-pokemon", category: "damage")
        return BattlePokemon(instanceID: id, speciesID: 25, names: ["en": id.capitalized], level: 30, isShiny: false,
                             unownForm: nil, gender: nil, nature: nil, abilityName: nil, types: ["normal"],
                             stats: BattleStats(hp: hp, attack: 60, defense: 50, specialAttack: 60, specialDefense: 50, speed: 50),
                             moves: [tackle])
    }

    private func finishedPractice() async throws -> BattleSession {
        let session = BattleSession(myTeam: try BattleTeam(members: [mon("red0", hp: 60)]),
                                    opponentTeam: try BattleTeam(members: [mon("blue0", hp: 55)]),
                                    seed: 7, opponent: CPUOpponent(seed: 3), language: .en, pace: .zero)
        await session.start()
        for _ in 0..<200 where session.outcome == nil { await session.choose(.move(0)) }
        XCTAssertNotNil(session.outcome)
        return session
    }

    private func entry(_ id: String, at t: Int64 = 1) -> BattleHistoryEntry {
        let side = BattleSpectatorSnapshot.Side(trainer: "Ash", isYou: true, active: 0, team: [])
        let snapshot = BattleSpectatorSnapshot(id: "live", kind: .practice, board: nil, sides: [side, side], moves: [],
                                               message: "", log: [], turn: 1, outcome: "won", turnDeadline: nil)
        return .make(snapshot, id: id, finishedAt: t, opponentKey: nil)
    }

    func testEntriesKeepTheEndOfTheBattleAndDropWhatOnlyMattersWhilePlaying() async throws {
        let session = try await finishedPractice()
        let live = BattleSpectatorSnapshot.make(from: session, id: "live", trainerName: "Ash")
        let long = BattleSpectatorSnapshot(id: live.id, kind: live.kind, board: BattleSpectatorSnapshot.Board(id: "b", name: "Kanto"),
                                           sides: live.sides, moves: live.moves, message: live.message,
                                           log: (0..<500).map { "line \($0)" }, turn: live.turn, outcome: live.outcome,
                                           turnDeadline: 123)
        XCTAssertFalse(long.moves.isEmpty)

        let key = TrainerSigning.encode(try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 9, count: 32)).publicKey)
        let saved = BattleHistoryEntry.make(long, id: "h1", finishedAt: 42, opponentKey: key)
        XCTAssertEqual(saved.id, "h1")
        XCTAssertEqual(saved.battle.id, "h1")
        XCTAssertEqual(saved.finishedAt, 42)
        XCTAssertEqual(saved.opponentFingerprint, TrainerSigning.fingerprint(key))
        XCTAssertEqual(saved.opponentKey, key)
        XCTAssertEqual(saved.battle.moves, [])
        XCTAssertNil(saved.battle.turnDeadline)
        XCTAssertEqual(saved.battle.log.count, BattleHistoryEntry.maxLogLines)
        XCTAssertEqual(saved.battle.log.last, "line 499")
        XCTAssertEqual(saved.battle.sides, live.sides)
        XCTAssertEqual(saved.battle.board?.name, "Kanto")
        XCTAssertEqual(saved.battle.outcome, live.outcome)

        XCTAssertNil(BattleHistoryEntry.make(long, finishedAt: 1, opponentKey: "not a key").opponentFingerprint)
        XCTAssertNil(BattleHistoryEntry.make(long, finishedAt: 1, opponentKey: "not a key").opponentKey)
        XCTAssertNil(BattleHistoryEntry.make(long, finishedAt: 1, opponentKey: nil).opponentFingerprint)
        XCTAssertNotEqual(BattleHistoryEntry.make(long, finishedAt: 1, opponentKey: nil).id,
                          BattleHistoryEntry.make(long, finishedAt: 1, opponentKey: nil).id)
    }

    func testEachResultIsRecordedOnceAndARematchRecordsAgain() {
        var recorder = BattleHistoryRecorder()
        let first = NSObject(), second = NSObject()
        let a = ObjectIdentifier(first), b = ObjectIdentifier(second)
        XCTAssertFalse(recorder.shouldRecord(session: nil, finished: true))
        XCTAssertFalse(recorder.shouldRecord(session: a, finished: false))
        XCTAssertTrue(recorder.shouldRecord(session: a, finished: true))
        XCTAssertFalse(recorder.shouldRecord(session: a, finished: true), "messages keep changing after the outcome")
        XCTAssertFalse(recorder.shouldRecord(session: nil, finished: false), "window closed")
        XCTAssertFalse(recorder.shouldRecord(session: a, finished: true), "same result seen again")
        XCTAssertFalse(recorder.shouldRecord(session: a, finished: false), "rematch")
        XCTAssertTrue(recorder.shouldRecord(session: a, finished: true))
        XCTAssertTrue(recorder.shouldRecord(session: b, finished: true), "another battle")
        XCTAssertFalse(recorder.shouldRecord(session: b, finished: false))
        XCTAssertFalse(recorder.shouldRecord(session: a, finished: false), "an old session going back to none changes nothing")
        XCTAssertTrue(recorder.shouldRecord(session: b, finished: true))
        withExtendedLifetime((first, second)) {}
    }

    func testStoreKeepsTheNewestFirstUpToTheCapAcrossLaunches() {
        let url = dir.appendingPathComponent("battles.json")
        let store = BattleHistoryStore(fileURL: url)
        XCTAssertEqual(store.entries, [])
        for i in 0..<(BattleHistoryStore.maxEntries + 5) { store.add(entry("b\(i)", at: Int64(i))) }
        XCTAssertEqual(store.entries.count, BattleHistoryStore.maxEntries)
        XCTAssertEqual(store.entries.first?.id, "b\(BattleHistoryStore.maxEntries + 4)")
        XCTAssertEqual(store.entries.last?.id, "b5")
        XCTAssertEqual(store.revision, BattleHistoryStore.maxEntries + 5)

        store.add(entry("b50", at: 999))
        XCTAssertEqual(store.entries.count, BattleHistoryStore.maxEntries)
        XCTAssertEqual(store.entries.filter { $0.id == "b50" }.count, 1)
        XCTAssertEqual(store.entries.first?.finishedAt, 999)

        XCTAssertEqual(BattleHistoryStore(fileURL: url).entries, store.entries)
    }

    func testUnreadableHistoryStartsEmpty() throws {
        let url = dir.appendingPathComponent("battles.json")
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(BattleHistoryStore(fileURL: url).entries, [])
    }

    func testHistoryIsServedAndStreamed() throws {
        let json = String(decoding: LocalAPIPayloads.encode(LocalAPIPayloads.History(battles: [entry("h1")])), as: UTF8.self)
        XCTAssertTrue(json.hasPrefix("{\"battles\":[{"), json)
        XCTAssertTrue(json.contains("\"id\":\"h1\""), json)
        XCTAssertEqual(LocalHTTP.Endpoint(rawValue: "/v1/history"), .history)
        XCTAssertEqual(LocalTrainerServer.eventName(.history), "history")
    }
}
