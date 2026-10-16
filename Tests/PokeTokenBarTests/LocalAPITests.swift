import CryptoKit
import XCTest
@testable import PokeTokenBar

final class LocalHTTPTests: XCTestCase {
    private let port = 47323
    private let page = "https://trainer.example.com"

    private func request(_ raw: String) -> LocalHTTP.Request {
        guard case .request(let r) = LocalHTTP.parse(Data(raw.utf8)) else {
            XCTFail("expected a request: \(raw)")
            return LocalHTTP.Request(method: "", path: "", headers: [:])
        }
        return r
    }

    private func get(_ path: String = "/v1/trainer", host: String? = "127.0.0.1:47323", origin: String? = nil,
                     method: String = "GET", extra: String = "") -> LocalHTTP.Request {
        var raw = "\(method) \(path) HTTP/1.1\r\n"
        if let host { raw += "Host: \(host)\r\n" }
        if let origin { raw += "Origin: \(origin)\r\n" }
        return request(raw + extra + "\r\n")
    }

    private func route(_ r: LocalHTTP.Request, paired: Set<String> = ["https://trainer.example.com"],
                       asked: inout [String]) -> LocalHTTP.Decision {
        LocalHTTP.route(r, port: port, pairedOrigins: paired) { asked.append($0) }
    }

    private func route(_ r: LocalHTTP.Request, paired: Set<String> = ["https://trainer.example.com"]) -> LocalHTTP.Decision {
        var asked: [String] = []
        return route(r, paired: paired, asked: &asked)
    }

    private func status(_ d: LocalHTTP.Decision) -> Int? {
        if case .respond(let r) = d { return r.status }
        return nil
    }

    private func errorCode(_ d: LocalHTTP.Decision) -> String? {
        guard case .respond(let r) = d, let json = try? JSONSerialization.jsonObject(with: r.body) as? [String: String] else { return nil }
        return json["error"]
    }

    // MARK: Parsing

    func testParsesRequestLineHeadersAndDropsTheQuery() {
        let r = get("/v1/boards?x=1", extra: "X-Thing:  value \r\n")
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/v1/boards")
        XCTAssertEqual(r.header("X-THING"), "value")
        XCTAssertEqual(r.header("host"), "127.0.0.1:47323")
    }

    func testWaitsForTheEndOfTheHeaders() {
        XCTAssertEqual(LocalHTTP.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)), .incomplete)
    }

    func testRejectsGarbageOversizeAndDuplicateHostOrOrigin() {
        func code(_ raw: String) -> Int? {
            if case .invalid(let r) = LocalHTTP.parse(Data(raw.utf8)) { return r.status }
            return nil
        }
        XCTAssertEqual(code("garbage\r\n\r\n"), 400)
        XCTAssertEqual(code("GET nope HTTP/1.1\r\n\r\n"), 400)
        XCTAssertEqual(code("GET / HTTP/1.1\r\nno-colon\r\n\r\n"), 400)
        XCTAssertEqual(code("GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n"), 400)
        XCTAssertEqual(code("GET / HTTP/1.1\r\nOrigin: a\r\nOrigin: b\r\n\r\n"), 400)
        XCTAssertEqual(code("GET / HTTP/1.1\r\n" + String(repeating: "a", count: LocalHTTP.maxRequestSize)), 431)
    }

    // MARK: Guards

    func testHostMustBeThisPortOnLoopback() {
        XCTAssertNotEqual(status(route(get(host: "127.0.0.1:47323"))), 421)
        XCTAssertNotEqual(status(route(get(host: "localhost:47323"))), 421)
        XCTAssertEqual(status(route(get(host: "evil.example.com:47323"))), 421, "DNS rebinding")
        XCTAssertEqual(status(route(get(host: "127.0.0.1:1234"))), 421)
        XCTAssertEqual(status(route(get(host: "127.0.0.1"))), 421)
        XCTAssertEqual(status(route(get(host: nil))), 421)
    }

    func testOnlyPairedOriginsGetCORSAndUnknownOnesAreAskedAbout() {
        var asked: [String] = []
        let refused = route(get(origin: "https://evil.example"), asked: &asked)
        XCTAssertEqual(status(refused), 403)
        XCTAssertEqual(errorCode(refused), "origin_not_paired")
        if case .respond(let r) = refused { XCTAssertNil(r.header("Access-Control-Allow-Origin")) }
        XCTAssertEqual(asked, ["https://evil.example"])

        guard case .serve(.trainer, let headers) = route(get(origin: page), asked: &asked) else { return XCTFail() }
        XCTAssertEqual(headers["Access-Control-Allow-Origin"], page)
        XCTAssertEqual(asked.count, 1, "a paired origin isn't asked about")
    }

    func testRequestsWithoutAnOriginAreServedWithoutCORS() {
        guard case .serve(.boards, let headers) = route(get("/v1/boards")) else { return XCTFail() }
        XCTAssertTrue(headers.isEmpty)
    }

    func testOriginsThatCantBePairedAreRefusedWithoutAsking() {
        var asked: [String] = []
        for origin in ["null", "file://", "https://x.example/path", "ftp://x.example", "not a url"] {
            XCTAssertEqual(errorCode(route(get(origin: origin), asked: &asked)), "origin_not_allowed", origin)
        }
        XCTAssertTrue(asked.isEmpty)
    }

    func testPreflightAllowsGetAndPrivateNetworkForPairedOriginsOnly() {
        let preflight = get(origin: page, method: "OPTIONS", extra: "Access-Control-Request-Private-Network: true\r\nAccess-Control-Request-Headers: cache-control\r\n")
        guard case .respond(let r) = route(preflight) else { return XCTFail() }
        XCTAssertEqual(r.status, 204)
        XCTAssertEqual(r.header("Access-Control-Allow-Private-Network"), "true")
        XCTAssertEqual(r.header("Access-Control-Allow-Methods"), "GET")
        XCTAssertEqual(r.header("Access-Control-Allow-Origin"), page)
        XCTAssertEqual(r.header("Access-Control-Allow-Headers"), "cache-control")
        XCTAssertEqual(status(route(get(origin: "https://evil.example", method: "OPTIONS",
                                        extra: "Access-Control-Request-Private-Network: true\r\n"))), 403)
    }

    func testReadOnlyAndUnknownPaths() {
        XCTAssertEqual(status(route(get(method: "POST"))), 405)
        XCTAssertEqual(status(route(get(origin: page, method: "DELETE"))), 405)
        XCTAssertEqual(status(route(get("/v1/nope"))), 404)
        guard case .stream = route(get("/v1/events", origin: page)) else { return XCTFail() }
    }

    // MARK: Framing

    func testResponsesAndEventsAreFramed() {
        let response = LocalHTTP.withHeaders(.json(200, Data("{}".utf8)), ["Vary": "Origin"]).serialized()
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(text.contains("Cache-Control: no-store\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{}"))
        XCTAssertEqual(String(decoding: LocalHTTP.event("battle", Data("{\"a\":1}\n{}".utf8)), as: UTF8.self),
                       "event: battle\ndata: {\"a\":1}\ndata: {}\n\n")
        let head = String(decoding: LocalHTTP.streamHead(["Access-Control-Allow-Origin": page]), as: UTF8.self)
        XCTAssertTrue(head.contains("Content-Type: text/event-stream\r\n"))
        XCTAssertTrue(head.hasSuffix("Access-Control-Allow-Origin: \(page)\r\n\r\n"))
    }
}

@MainActor
final class LocalAPIPayloadTests: XCTestCase {
    private let code = BoardCode("KANT-0000-0001")!

    func testBoardsNeverCarryTheirCodeAndRankMembers() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
        var replica = BoardReplica(boardId: code.boardId)
        let now = BoardRules.now()
        replica.merge(try BoardRecord.signed(boardId: code.boardId, boardName: "Kanto", displayName: "Ash",
                                             stats: BoardStats(collection: .init(dex: 2, species: 2)),
                                             joinedAt: now, issuedAt: now, left: false, key: key))
        let board = BoardStore.Board(code: code.value, joinedAt: now, replica: replica, lastSyncAt: nil)
        let you = TrainerSigning.encode(key.publicKey)
        let data = LocalAPIPayloads.encode(LocalAPIPayloads.boards([board], you: you, syncEnabled: true))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(code.value))
        XCTAssertFalse(text.contains(code.display))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let boards = try XCTUnwrap(json["boards"] as? [[String: Any]])
        XCTAssertEqual(boards.first?["name"] as? String, "Kanto")
        XCTAssertTrue(boards.first?["lastSyncAt"] is NSNull)
        let member = try XCTUnwrap((boards.first?["members"] as? [[String: Any]])?.first)
        XCTAssertEqual(member["isYou"] as? Bool, true)
        XCTAssertEqual(member["rank"] as? Int, 1)
        XCTAssertEqual((member["score"] as? [String: Int])?["total"], 2)
        XCTAssertEqual((member["fingerprint"] as? String)?.count, 4)
    }

    func testTrainerSendsAnExplicitNullBandWhenNotShared() throws {
        let showcase = TrainerShowcase(pokemon: [], battleTeam: [], battleRecord: BattleRecord(), gameStats: TrainerShowcase.stats([]))
        let data = LocalAPIPayloads.encode(LocalAPIPayloads.trainer(name: "Ash", publicKey: nil, showcase: showcase, aiBand: nil))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(json["aiBand"] is NSNull)
        let shared = LocalAPIPayloads.encode(LocalAPIPayloads.trainer(name: "Ash", publicKey: nil, showcase: showcase, aiBand: .heavy))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: shared) as? [String: Any])?["aiBand"] as? String, "heavy")
    }

    func testDeepLinksOnlyJoinWithAValidCode() {
        XCTAssertEqual(BoardDeepLink.parse(URL(string: "poketokenbar://boards/join?code=kant-0000-0001")!), .join(code))
        XCTAssertNil(BoardDeepLink.parse(URL(string: "poketokenbar://boards/join?code=nope")!))
        XCTAssertNil(BoardDeepLink.parse(URL(string: "poketokenbar://boards/join")!))
        XCTAssertNil(BoardDeepLink.parse(URL(string: "poketokenbar://boards/leave?code=KANT-0000-0001")!))
        XCTAssertNil(BoardDeepLink.parse(URL(string: "https://boards/join?code=KANT-0000-0001")!))
        XCTAssertNil(BoardDeepLink.parse(URL(string: "poketokenbar://boards/join?code=KANT-0000-0001&code=J0HT-0000-0002")!))
    }

    func testBundleDeclaresTheBoardServiceAndURLScheme() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/build-app.sh")
        let plist = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(plist.contains("<string>_\(BoardSyncService.serviceType)._tcp</string>"))
        XCTAssertTrue(plist.contains("<string>_\(BoardSyncService.serviceType)._udp</string>"))
        XCTAssertTrue(plist.contains("<key>CFBundleURLSchemes</key><array><string>poketokenbar</string></array>"))
        let type = BoardSyncService.serviceType
        XCTAssertTrue((1...15).contains(type.count) && type.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" })
    }

    func testOnlyTheSmallerNameInvitesAndNotTooOften() {
        let now = Date()
        XCTAssertTrue(BoardSyncService.shouldInvite(me: "ptb-a", them: "ptb-b", lastSynced: nil, now: now))
        XCTAssertFalse(BoardSyncService.shouldInvite(me: "ptb-b", them: "ptb-a", lastSynced: nil, now: now))
        XCTAssertFalse(BoardSyncService.shouldInvite(me: "ptb-a", them: "ptb-b", lastSynced: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(BoardSyncService.shouldInvite(me: "ptb-a", them: "ptb-b",
                                                     lastSynced: now.addingTimeInterval(-BoardSyncService.resyncInterval), now: now))
    }
}

@MainActor
final class BattleSpectatorTests: XCTestCase {
    private func mon(_ id: String, hp: Int) -> BattlePokemon {
        let tackle = BattleMove(name: "tackle", type: "normal", power: 40, accuracy: nil, pp: 20, priority: 0,
                                damageClass: .physical, target: "selected-pokemon", category: "damage")
        return BattlePokemon(instanceID: id, speciesID: 25, names: ["en": id.capitalized], level: 30, isShiny: id == "red0",
                             unownForm: nil, gender: nil, nature: nil, abilityName: nil, types: ["normal"],
                             stats: BattleStats(hp: hp, attack: 60, defense: 50, specialAttack: 60, specialDefense: 50, speed: 50),
                             moves: [tackle])
    }

    func testSnapshotsFollowTheDisplayAndNeverLeakTheEngineState() async throws {
        let session = BattleSession(myTeam: try BattleTeam(members: [mon("red0", hp: 60), mon("red1", hp: 70)]),
                                    opponentTeam: try BattleTeam(members: [mon("blue0", hp: 55)]),
                                    seed: 7, opponent: CPUOpponent(seed: 3), language: .en, pace: .zero)
        await session.start()
        var snapshots: [BattleSpectatorSnapshot] = []
        while session.outcome == nil, snapshots.count < 200 {
            let s = BattleSpectatorSnapshot.make(from: session, id: "b1", trainerName: "Ash")
            snapshots.append(s)
            for (i, side) in [session.mySide, session.theirSide].enumerated() {
                XCTAssertEqual(s.sides[i].team.map(\.hp), session.display.hp[side.rawValue])
                XCTAssertEqual(s.sides[i].active, session.display.active[side.rawValue])
            }
            XCTAssertEqual(s.message, session.message)
            if session.awaitingReplacement { await session.replace(with: session.switchTargets[0]) } else { await session.choose(.move(0)) }
        }
        let last = BattleSpectatorSnapshot.make(from: session, id: "b1", trainerName: "Ash")
        XCTAssertNotNil(last.outcome)
        XCTAssertEqual(last.kind, .practice)
        XCTAssertEqual(last.sides[0].trainer, "Ash")
        XCTAssertTrue(last.sides[0].isYou)
        XCTAssertTrue(last.sides[0].team[0].shiny)
        XCTAssertEqual(last.log, session.log)
        let json = String(decoding: LocalAPIPayloads.encode(LocalAPIPayloads.Battle(battle: last)), as: UTF8.self)
        for field in ["rng", "seed", "pending", "stages", "volatiles"] { XCTAssertFalse(json.contains("\"\(field)\""), field) }
        XCTAssertEqual(LocalAPIPayloads.encode(LocalAPIPayloads.Battle(battle: nil)), Data("{\"battle\":null}".utf8))
    }

    /// A live battle has no outcome, deadline or board yet; the page needs those as null, not missing.
    func testLiveSnapshotsSendExplicitNulls() throws {
        let session = BattleSession(myTeam: try BattleTeam(members: [mon("red0", hp: 60)]),
                                    opponentTeam: try BattleTeam(members: [mon("blue0", hp: 55)]),
                                    seed: 7, opponent: CPUOpponent(seed: 3), language: .en, pace: .zero)
        let snapshot = BattleSpectatorSnapshot.make(from: session, id: "b1", trainerName: "Ash")
        XCTAssertNil(snapshot.outcome)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: LocalAPIPayloads.encode(LocalAPIPayloads.Battle(battle: snapshot)))
                                 as? [String: Any])
        let battle = try XCTUnwrap(json["battle"] as? [String: Any])
        for key in ["outcome", "turnDeadline", "board"] { XCTAssertTrue(battle[key] is NSNull, key) }
        let pokemon = try XCTUnwrap(((battle["sides"] as? [[String: Any]])?.first?["team"] as? [[String: Any]])?.first)
        for key in ["unownForm", "status"] { XCTAssertTrue(pokemon[key] is NSNull, key) }
        // And it still reads back, for the battle history.
        XCTAssertEqual(try JSONDecoder().decode(BattleSpectatorSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }

    func testBadPoisonIsItsOwnStatus() {
        XCTAssertEqual(BattleSpectatorSnapshot.status(.badPoison), .tox)
        XCTAssertEqual(BattleSpectatorSnapshot.status(.poison), .psn)
    }
}
