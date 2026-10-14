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
