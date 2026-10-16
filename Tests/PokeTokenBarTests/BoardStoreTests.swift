import CryptoKit
import XCTest
@testable import PokeTokenBar

@MainActor
final class BoardStoreTests: XCTestCase {
    private var dir: URL!
    private var clock: Int64 = 1_760_000_000_000

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("BoardStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store(_ n: UInt8, file: String = "boards.json") -> BoardStore {
        let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: n, count: 32))
        return BoardStore(fileURL: dir.appendingPathComponent(file), identity: TrainerIdentity(load: { key }),
                          now: { [unowned self] in self.clock })
    }

    private let stats = BoardStats(collection: .init(dex: 3, species: 2))

    private func signer(_ n: UInt8) -> Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: n, count: 32))
    }

    func testCreateThenJoinAndSyncNamesTheBoardForTheJoiner() async throws {
        let ash = store(1, file: "a.json"), misty = store(2, file: "m.json")
        let code = try await ash.create(name: "  Kanto crew ", displayName: "Ash", stats: stats)
        XCTAssertEqual(ash.boards.map(\.name), ["Kanto crew"])
        try await misty.join(code: code.display.lowercased(), displayName: "Misty", stats: stats)
        XCTAssertEqual(misty.boards.first?.name, "Board \(code.value.prefix(4))")

        let id = code.boardId
        misty.merge(boardId: id, records: Array(ash.replica(id)!.records.values), receipts: [], from: "peer")
        XCTAssertEqual(misty.board(id)?.name, "Kanto crew")
        XCTAssertEqual(misty.board(id)?.replica.members.count, 2)

        // Misty's next row adopts the real name.
        clock += 1
        await misty.publish(displayName: "Misty", stats: stats)
        let mine = misty.board(id)!.replica.records.values.first { $0.displayName == "Misty" }
        XCTAssertEqual(mine?.boardName, "Kanto crew")
    }

    func testRejectsBadCodesNamesAndDoubleJoins() async throws {
        let ash = store(1)
        do { try await ash.join(code: "nope", displayName: "Ash", stats: stats); XCTFail() } catch {
            XCTAssertEqual(error as? BoardStore.StoreError, .invalidCode)
        }
        do { _ = try await ash.create(name: "   ", displayName: "Ash", stats: stats); XCTFail() } catch {
            XCTAssertEqual(error as? BoardStore.StoreError, .invalidName)
        }
        let code = try await ash.create(name: "Kanto", displayName: "Ash", stats: stats)
        do { try await ash.join(code: code.display, displayName: "Ash", stats: stats); XCTFail() } catch {
            XCTAssertEqual(error as? BoardStore.StoreError, .alreadyJoined)
        }
    }

    func testOneLeagueAtATime() async throws {
        let ash = store(1, file: "a.json"), misty = store(2, file: "m.json")
        let kanto = try await ash.create(name: "Kanto", displayName: "Ash", stats: stats)
        let johto = try await misty.create(name: "Johto", displayName: "Misty", stats: stats)
        do { try await ash.join(code: johto.display, displayName: "Ash", stats: stats); XCTFail() } catch {
            XCTAssertEqual(error as? BoardStore.StoreError, .alreadyJoined)
        }
        do { _ = try await ash.create(name: "Hoenn", displayName: "Ash", stats: stats); XCTFail() } catch {
            XCTAssertEqual(error as? BoardStore.StoreError, .alreadyJoined)
        }
        XCTAssertEqual(ash.boards.map(\.id), [kanto.boardId])

        // Leaving frees the slot even while the tombstone still waits for a sync.
        clock += 1
        await ash.leave(kanto.boardId)
        try await ash.join(code: johto.display, displayName: "Ash", stats: stats)
        XCTAssertEqual(ash.boards.map(\.id), [johto.boardId])
        XCTAssertEqual(Set(ash.codes), [kanto, johto])
    }

    func testWatchesOtherLeaguesAndJoiningOneKeepsItsRows() async throws {
        let ash = store(1, file: "a.json"), watcher = store(2, file: "w.json")
        let kanto = try await ash.create(name: "Kanto", displayName: "Ash", stats: stats)
        watcher.merge(boardId: kanto.boardId, records: Array(ash.replica(kanto.boardId)!.records.values), receipts: [], from: "peer")
        XCTAssertTrue(watcher.boards.isEmpty, "watching isn't membership")
        XCTAssertEqual(watcher.watched.map(\.boardId), [kanto.boardId])
        XCTAssertEqual(watcher.syncReplicas.keys.sorted(), [kanto.boardId])
        XCTAssertEqual(BoardStore(fileURL: dir.appendingPathComponent("w.json"), identity: TrainerIdentity(load: { throw CancellationError() }))
                        .watched.map(\.boardId), [kanto.boardId], "persisted")

        clock += 1
        try await watcher.join(code: kanto.display, displayName: "Misty", stats: stats)
        XCTAssertEqual(watcher.watched, [])
        XCTAssertEqual(watcher.board(kanto.boardId)?.replica.members.map(\.displayName).sorted(), ["Ash", "Misty"])
        XCTAssertEqual(watcher.board(kanto.boardId)?.name, "Kanto")
    }

    func testWatchedLeaguesNeedAValidMemberAndStayUnderTheCap() async throws {
        let watcher = store(2, file: "w.json")
        // Garbage ids, empty pushes and rows for another id are ignored.
        watcher.merge(boardId: "not-an-id", records: [], receipts: [], from: nil)
        let kanto = BoardCode("KANT-0000-0001")!
        watcher.merge(boardId: kanto.boardId, records: [], receipts: [], from: nil)
        let other = try BoardRecord.signed(code: BoardCode("J0HT-0000-0002")!, boardName: "Johto", displayName: "Gold",
                                           stats: stats, joinedAt: 1, issuedAt: 1, left: false, key: signer(3))
        watcher.merge(boardId: kanto.boardId, records: [other], receipts: [], from: nil)
        XCTAssertEqual(watcher.watched, [])

        func wide(_ i: Int) -> BoardCode { BoardCode(String(format: "W%011d", i))! }
        for i in 0..<(BoardStore.watchedCap + 2) {
            let row = try BoardRecord.signed(code: wide(i), boardName: "L\(i)", displayName: "T", stats: stats,
                                             joinedAt: 1, issuedAt: Int64(1_000 + i), left: false, key: signer(3))
            watcher.merge(boardId: wide(i).boardId, records: [row], receipts: [], from: nil)
        }
        XCTAssertEqual(watcher.watched.count, BoardStore.watchedCap)
        XCTAssertEqual(watcher.watched.first?.boardId, wide(BoardStore.watchedCap + 1).boardId, "most recently active first")
        XCTAssertFalse(watcher.watched.contains { $0.boardId == wide(0).boardId || $0.boardId == wide(1).boardId })
    }

    func testALeagueYouLeftIsWatchedOnceTheTombstoneIsOut() async throws {
        let ash = store(1)
        let code = try await ash.create(name: "Kanto", displayName: "Ash", stats: stats)
        clock += 1
        await ash.leave(code.boardId)
        ash.merge(boardId: code.boardId, records: [], receipts: [], from: "peer")
        XCTAssertTrue(ash.codes.isEmpty)
        XCTAssertEqual(ash.watched.map(\.boardId), [], "nobody left in it")
    }

    func testBoardsSavedBeforePublicIdsMoveOverKeepingTheirName() async throws {
        let code = BoardCode("KANT-0000-0001")!
        let legacyRow = """
        {"boardId":"\(code.legacyBoardId)","boardName":"Kanto crew","publicKey":"k","displayName":"Ash",\
        "stats":{"battleRecord":{"draws":0,"losses":0,"wins":0},"collection":{"dex":0,"graduated":0,"shinies":0,"species":0},\
        "levels":{"teamTotal":0,"top":0}},"joinedAt":5,"issuedAt":6,"left":false,"signature":"s"}
        """
        let file = """
        {"version":1,"boards":[{"code":"\(code.value)","joinedAt":5,"syncedWith":["p"],"lastSyncAt":9,
        "replica":{"boardId":"\(code.legacyBoardId)","records":{"k":\(legacyRow)},"receipts":{}}}]}
        """
        try Data(file.utf8).write(to: dir.appendingPathComponent("boards.json"))
        let ash = store(1)
        let board = try XCTUnwrap(ash.boards.first)
        XCTAssertEqual(board.id, code.boardId)
        XCTAssertNotEqual(code.boardId, code.legacyBoardId)
        XCTAssertEqual(board.name, "Kanto crew")
        XCTAssertEqual(board.joinedAt, 5)
        XCTAssertTrue(board.replica.records.isEmpty, "rows without a membership can't come along")
        XCTAssertNil(board.lastSyncAt)

        await ash.publish(displayName: "Ash", stats: stats)
        let mine = try XCTUnwrap(ash.board(code.boardId)?.replica.members.first)
        XCTAssertEqual(mine.boardName, "Kanto crew")
        XCTAssertEqual(mine.joinedAt, 5)
        XCTAssertTrue(mine.isAcceptable(for: code.boardId, now: clock))
    }

    func testPublishSignsOnlyWhenSomethingChanged() async throws {
        let ash = store(1)
        let code = try await ash.create(name: "Kanto", displayName: "Ash", stats: stats)
        let revision = ash.revision
        clock += 1
        await ash.publish(displayName: "Ash", stats: stats)
        XCTAssertEqual(ash.revision, revision)
        clock += 1
        await ash.publish(displayName: "Ash", stats: BoardStats(collection: .init(dex: 4, species: 2)))
        XCTAssertEqual(ash.revision, revision + 1)
        let row = ash.board(code.boardId)!.replica.records.values.first!
        XCTAssertEqual(row.stats.collection.dex, 4)
        XCTAssertEqual(row.joinedAt, ash.board(code.boardId)!.joinedAt, "joinedAt never changes")
    }

    func testLeavingHidesTheBoardUntilOneSyncDeliversTheTombstone() async throws {
        let ash = store(1)
        let code = try await ash.create(name: "Kanto", displayName: "Ash", stats: stats)
        clock += 1
        await ash.leave(code.boardId)
        XCTAssertTrue(ash.boards.isEmpty)
        XCTAssertEqual(ash.codes, [code], "still synced, to deliver the tombstone")
        XCTAssertEqual(ash.replica(code.boardId)?.members.count, 0)
        XCTAssertEqual(ash.replica(code.boardId)?.records.values.first?.left, true)
        ash.merge(boardId: code.boardId, records: [], receipts: [], from: "peer")
        XCTAssertTrue(ash.codes.isEmpty)
    }

    func testPersistsAndReloads() async throws {
        let ash = store(1)
        let code = try await ash.create(name: "Kanto", displayName: "Ash", stats: stats)
        let reloaded = store(1)
        XCTAssertEqual(reloaded.boards, ash.boards)
        XCTAssertEqual(reloaded.codes, [code])
    }
}
