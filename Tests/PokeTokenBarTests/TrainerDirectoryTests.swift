import CryptoKit
import XCTest
@testable import PokeTokenBar

@MainActor
final class TrainerDirectoryTests: XCTestCase {
    private var dir: URL!
    private let now: Int64 = 1_760_000_000_000

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("TrainerDirectoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func privateKey(_ n: UInt8) -> Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: n, count: 32))
    }
    private func key(_ n: UInt8) -> String { TrainerSigning.encode(privateKey(n).publicKey) }

    private let code = BoardCode("ABCD-EFGH-JKMN")!

    private func row(_ n: UInt8, _ name: String, joined: Int64, team: [BoardStats.TeamMember] = []) -> BoardRecord {
        try! BoardRecord.signed(boardId: code.boardId, boardName: "Kanto", displayName: name,
                                stats: BoardStats(collection: .init(dex: Int(n), species: Int(n)), team: team),
                                joinedAt: joined, issuedAt: joined, left: false, key: privateKey(n))
    }

    private func battle(_ id: String, vs n: UInt8?, name: String, outcome: String, at t: Int64, species: Int = 25) -> BattleHistoryEntry {
        let mon = BattleSpectatorSnapshot.Pokemon(speciesNum: species, appearance: species, name: "Mon\(species)", level: 30,
                                                  shiny: false, unownForm: nil, hp: 0, maxHp: 50, status: nil, fainted: true)
        let you = BattleSpectatorSnapshot.Side(trainer: "Ash", isYou: true, active: 0, team: [mon])
        let them = BattleSpectatorSnapshot.Side(trainer: name, isYou: false, active: 0, team: [mon])
        let snapshot = BattleSpectatorSnapshot(id: "live", kind: .nearby, board: nil, sides: [you, them], moves: [],
                                               message: "", log: [], turn: 3, outcome: outcome, turnDeadline: nil)
        return .make(snapshot, id: id, finishedAt: t, opponentKey: n.map(key))
    }

    // MARK: Presence and discovery

    func testIdleAfterFiveMinutesWithoutInput() {
        XCTAssertTrue(UserActivity.isActive(idleSeconds: 0))
        XCTAssertTrue(UserActivity.isActive(idleSeconds: 299))
        XCTAssertFalse(UserActivity.isActive(idleSeconds: 300))
        XCTAssertLessThan(TrainerPresence.available, .idle)
        XCTAssertLessThan(TrainerPresence.idle, .away)
    }

    func testDiscoveryInfoCarriesTheKeyAndActivity() {
        let info = NearbyDiscovery.info(version: 4, publicKey: key(1), active: false)
        XCTAssertEqual(info, ["v": "4", "k": key(1), "a": "0"])
        XCTAssertTrue(info.allSatisfy { $0.key.utf8.count + $0.value.utf8.count < 255 }, "one TXT entry each")
        let parsed = NearbyDiscovery.parse(info)
        XCTAssertEqual(parsed.publicKey, key(1))
        XCTAssertFalse(parsed.active)

        XCTAssertEqual(NearbyDiscovery.info(version: 4, publicKey: nil, active: true), ["v": "4", "a": "1"])
        XCTAssertTrue(NearbyDiscovery.parse(["v": "4"]).active, "older builds don't say: assume active")
        XCTAssertNil(NearbyDiscovery.parse(["v": "4"]).publicKey)
        XCTAssertNil(NearbyDiscovery.parse(["k": "not a key"]).publicKey)
        XCTAssertTrue(NearbyDiscovery.parse(nil).active)
    }

    // MARK: The list

    func testMergesLeagueSightingsNearbyAndBattlesWithoutYou() throws {
        var replica = BoardReplica(boardId: code.boardId)
        let pikachu = BoardStats.TeamMember(speciesNum: 25, species: "Pikachu", form: nil, shiny: true, level: 40)
        for record in [row(1, "Ash", joined: 1), row(2, "Misty", joined: 2, team: [pikachu]), row(3, "Brock", joined: 3)] {
            XCTAssertTrue(replica.merge(record, now: now))
        }
        let league = TrainerList.League(id: code.boardId, name: "Kanto", replica: replica)
        let sightings = [TrainerSighting(publicKey: key(3), name: "Brock (old)", lastSeenAt: now - 60_000),
                         TrainerSighting(publicKey: key(4), name: "Gary", lastSeenAt: now - 3_600_000)]
        let nearby = [TrainerList.Nearby(publicKey: key(2), name: "Misty", active: false),
                      TrainerList.Nearby(publicKey: key(5), name: "Erika", active: true)]
        let history = [battle("h3", vs: 2, name: "Misty", outcome: "won", at: now - 10, species: 7),
                       battle("h2", vs: 2, name: "Misty", outcome: "lost", at: now - 20),
                       battle("h1", vs: 6, name: "Sabrina", outcome: "draw", at: now - 30, species: 64),
                       battle("h0", vs: nil, name: "CPU", outcome: "won", at: now - 40)]

        let list = TrainerList.build(you: key(1), league: league, sightings: sightings, nearby: nearby, history: history, now: now)
        XCTAssertEqual(list.map(\.name), ["Erika", "Misty", "Brock", "Gary", "Sabrina"], "away ones by last seen, never seen last")
        XCTAssertFalse(list.contains { $0.publicKey == key(1) }, "never yourself")

        let erika = list[0], misty = list[1], brock = list[2], gary = list[3], sabrina = list[4]
        XCTAssertEqual(erika.presence, .available)
        XCTAssertEqual(erika.lastSeenAt, now)
        XCTAssertNil(erika.league)

        XCTAssertEqual(misty.presence, .idle)
        XCTAssertEqual(misty.league, .init(id: code.boardId, name: "Kanto", rank: 2, points: misty.league?.points ?? -1))
        XCTAssertEqual(misty.team, [pikachu], "the league row's team wins over the last battle")
        XCTAssertEqual(misty.vsYou, .init(wins: 1, losses: 1, draws: 0))
        XCTAssertEqual(misty.lastBattleAt, now - 10)
        XCTAssertEqual(misty.fingerprint, TrainerSigning.fingerprint(key(2)))

        XCTAssertEqual(brock.presence, .away)
        XCTAssertEqual(brock.name, "Brock", "the league row names members")
        XCTAssertEqual(brock.lastSeenAt, now - 60_000)
        XCTAssertNotNil(brock.league)

        XCTAssertEqual(sabrina.team, [.init(speciesNum: 64, species: "Mon64", form: nil, shiny: false, level: 30)],
                       "without a row, the team from the last battle")
        XCTAssertNil(sabrina.lastSeenAt)
        XCTAssertNil(sabrina.league)
        XCTAssertEqual(sabrina.vsYou.draws, 1)

        XCTAssertEqual(gary.lastSeenAt, now - 3_600_000)
        XCTAssertEqual(gary.team, [])
    }

    func testSamePresenceSortsByLeagueRankThenLastSeenAndSkipsCalledOffBattles() {
        var replica = BoardReplica(boardId: code.boardId)
        // Misty out-collects Brock, so she ranks first although she joined later.
        for record in [row(3, "Brock", joined: 1), row(9, "Misty", joined: 2)] { XCTAssertTrue(replica.merge(record, now: now)) }
        let league = TrainerList.League(id: code.boardId, name: "Kanto", replica: replica)
        let sightings = [TrainerSighting(publicKey: key(4), name: "Gary", lastSeenAt: now - 1),
                         TrainerSighting(publicKey: key(3), name: "Brock", lastSeenAt: now - 50)]
        let history = [battle("h1", vs: 4, name: "Gary", outcome: "aborted", at: now - 5)]
        let list = TrainerList.build(you: nil, league: league, sightings: sightings, nearby: [], history: history, now: now)
        XCTAssertEqual(list.map(\.name), ["Misty", "Brock", "Gary"], "members by rank before fresher non-members")
        XCTAssertEqual(list.map(\.league?.rank), [1, 2, nil])
        XCTAssertEqual(list.last?.vsYou, .init(), "a called-off battle isn't a result")
        XCTAssertEqual(list.last?.lastBattleAt, now - 5)
        // Order doesn't depend on input order.
        XCTAssertEqual(TrainerList.build(you: nil, league: league, sightings: sightings.reversed(), nearby: [],
                                         history: history, now: now).map(\.name), list.map(\.name))
    }

    func testWithoutALeagueOrAnythingSeen() {
        XCTAssertEqual(TrainerList.build(you: nil, league: nil, sightings: [], nearby: [], history: [], now: now), [])
    }

    func testEntriesSendExplicitNulls() throws {
        let list = TrainerList.build(you: nil, league: nil, sightings: [], nearby: [], history: [battle("h", vs: 2, name: "M", outcome: "won", at: 1)], now: now)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: LocalAPIPayloads.encode(LocalAPIPayloads.Trainers(trainers: list)))
                                 as? [String: Any])
        let first = try XCTUnwrap((json["trainers"] as? [[String: Any]])?.first)
        for key in ["lastSeenAt", "league"] { XCTAssertTrue(first[key] is NSNull, key) }
        XCTAssertEqual(first["presence"] as? String, "away")
        XCTAssertEqual(LocalHTTP.Endpoint(rawValue: "/v1/trainers"), .trainers)
        XCTAssertEqual(LocalTrainerServer.eventName(.trainers), "trainers")
    }

    // MARK: Sightings

    func testSightingsSaveNewcomersRenamesAndAMinuteLaterOnly() {
        let url = dir.appendingPathComponent("trainers.json")
        let store = TrainerSightingsStore(fileURL: url)
        let misty = TrainerList.Nearby(publicKey: key(2), name: "Misty", active: true)
        store.saw([misty], at: now)
        XCTAssertEqual(store.revision, 1)
        store.saw([misty], at: now + 30_000)
        XCTAssertEqual(store.revision, 1, "still in view: not rewritten yet")
        XCTAssertEqual(store.sightings[key(2)]?.lastSeenAt, now)
        store.saw([TrainerList.Nearby(publicKey: key(2), name: "Misty 2", active: true)], at: now + 31_000)
        XCTAssertEqual(store.revision, 2)
        store.saw([misty], at: now + 31_000 + TrainerSightingsStore.saveInterval)
        XCTAssertEqual(store.revision, 3)
        XCTAssertEqual(store.sightings[key(2)]?.name, "Misty")
        store.saw([misty], at: now + 31_000 + 2 * TrainerSightingsStore.saveInterval)
        XCTAssertEqual(store.revision, 4, "same name, a minute later")
        XCTAssertEqual(store.sightings[key(2)]?.lastSeenAt, now + 31_000 + 2 * TrainerSightingsStore.saveInterval)

        let reloaded = TrainerSightingsStore(fileURL: url)
        XCTAssertEqual(reloaded.sightings, store.sightings)
    }

    func testSightingsKeepTheMostRecentUpToTheCap() {
        let store = TrainerSightingsStore(fileURL: dir.appendingPathComponent("trainers.json"))
        func wide(_ i: Int) -> String {
            var raw = Data(repeating: 7, count: 32)
            raw[0] = UInt8(i & 0xFF)
            raw[1] = UInt8(i >> 8)
            return TrainerSigning.encode(try! Curve25519.Signing.PrivateKey(rawRepresentation: raw).publicKey)
        }
        let total = TrainerSightingsStore.maxEntries + 2
        for i in 0..<total { store.saw([TrainerList.Nearby(publicKey: wide(i), name: "T\(i)", active: true)], at: now + Int64(i)) }
        XCTAssertEqual(store.sightings.count, TrainerSightingsStore.maxEntries)
        XCTAssertNil(store.sightings[wide(0)])
        XCTAssertNil(store.sightings[wide(1)])
        XCTAssertNotNil(store.sightings[wide(2)])
        XCTAssertNotNil(store.sightings[wide(total - 1)])
    }
}
