import CryptoKit
import XCTest
@testable import PokeTokenBar

private func mon(_ id: String, hp: Int = 100, speed: Int = 50) -> BattlePokemon {
    let tackle = BattleMove(name: "tackle", type: "normal", power: 40, accuracy: nil, pp: 20, priority: 0,
                            damageClass: .physical, target: "selected-pokemon", category: "damage")
    return BattlePokemon(instanceID: id, speciesID: 25, names: ["en": id.capitalized], level: 50, isShiny: false,
                         unownForm: nil, gender: nil, nature: nil, abilityName: nil, types: ["normal"],
                         stats: BattleStats(hp: hp, attack: 60, defense: 50, specialAttack: 60, specialDefense: 50, speed: speed),
                         moves: [tackle])
}

private func team(_ tag: String, count: Int = 2) throws -> BattleTeam {
    try BattleTeam(members: (0..<count).map { mon("\(tag)\($0)", hp: 60 + $0 * 7, speed: 40 + $0 * 9) })
}

private let red = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
private let blue = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32))

/// Board-scoped nearby battles: both sides agree on the board in the handshake, and only a result
/// both signed becomes a receipt.
@MainActor
final class BattleReceiptTests: XCTestCase {
    private let kanto = BoardCode("KANT-0000-0001")!
    private let johto = BoardCode("J0HT-0000-0002")!
    private let now: Int64 = 1_760_000_000_000

    private struct Setup {
        let challenger: BattleMatch
        let guest: BattleMatch
        let challengerLink: BattleLink
        let guestLink: BattleLink
    }

    /// The challenger invites for `board`; the guest accepts with whichever of `guestCodes` matches.
    private func handshake(board: BoardCode?, guestCodes: [BoardCode], startedAt: Int64? = nil,
                           guestKey: Curve25519.Signing.PrivateKey? = nil) async throws -> Setup {
        let (left, right) = LoopbackTransport.pair()
        let challengerLink = BattleLink(transport: left), guestLink = BattleLink(transport: right)
        let n = now
        let invite = board.map { BattleBoardInvite.make(for: $0) }
        let challengerScope: BattleScope? = board.map { BattleScope(code: $0, invite: invite!, startedAt: startedAt ?? n) }
        let guestScope: BattleScope? = invite.flatMap { inv in inv.board(in: guestCodes).map { BattleScope(code: $0, invite: inv, startedAt: nil) } }
        let guestPublic = TrainerSigning.encode((guestKey ?? blue).publicKey)
        let redPublic = TrainerSigning.encode(red.publicKey)
        let redTeam = try team("red"), blueTeam = try team("blue")
        async let a = BattleHandshake.run(challengerLink, isChallenger: true, trainer: "Red", team: redTeam, nonce: 11,
                                          publicKey: redPublic, scope: challengerScope, now: n)
        async let b = BattleHandshake.run(guestLink, isChallenger: false, trainer: "Blue", team: blueTeam, nonce: 22,
                                          publicKey: guestPublic, scope: guestScope, now: n)
        let (ma, mb) = try await (a, b)
        return Setup(challenger: ma, guest: mb, challengerLink: challengerLink, guestLink: guestLink)
    }

    func testBothSidesAgreeOnTheBoardAndTheReceipt() async throws {
        let s = try await handshake(board: kanto, guestCodes: [johto, kanto])
        XCTAssertEqual(s.challenger.board, kanto)
        XCTAssertEqual(s.guest.board, kanto)
        XCTAssertEqual(s.challenger.battleId, s.guest.battleId)
        XCTAssertFalse(s.challenger.battleId.isEmpty)
        XCTAssertEqual(s.challenger.startedAt, now)
        XCTAssertEqual(s.guest.startedAt, now)
        XCTAssertEqual(s.challenger.receipt(winner: .a), s.guest.receipt(winner: .a))
        XCTAssertEqual(s.challenger.receipt(winner: .a)?.winner, TrainerSigning.encode(red.publicKey))
        XCTAssertNil(s.challenger.receipt(winner: nil)?.winner)
    }

    func testABoardTheGuestDoesNotHoldIsAFriendlyOnBothSides() async throws {
        let s = try await handshake(board: kanto, guestCodes: [johto])
        XCTAssertNil(s.challenger.board, "no proof from the guest")
        XCTAssertNil(s.guest.board)
        XCTAssertNil(s.challenger.receipt(winner: .a))
    }

    func testAFriendlyHasNoBoard() async throws {
        let s = try await handshake(board: nil, guestCodes: [kanto])
        XCTAssertNil(s.challenger.board)
        XCTAssertNil(s.guest.board)
    }

    func testAStartTimeOutsideTheClockSkewMakesItAFriendlyForTheGuest() async throws {
        let s = try await handshake(board: kanto, guestCodes: [kanto], startedAt: now - BoardRules.maxClockSkewMs - 1)
        XCTAssertNil(s.guest.board)
    }

    func testTheSameKeyOnBothSidesNeverScores() async throws {
        let s = try await handshake(board: kanto, guestCodes: [kanto], guestKey: red)
        XCTAssertNil(s.challenger.board)
        XCTAssertNil(s.guest.board)
    }

    func testAResultOnTheFieldIsCoSignedIdenticallyOnBothSides() async throws {
        let s = try await handshake(board: kanto, guestCodes: [kanto])
        async let a = NearbyBattleService.coSignedReceipt(s.challenger, outcome: .won, link: s.challengerLink, key: red)
        async let b = NearbyBattleService.coSignedReceipt(s.guest, outcome: .lost, link: s.guestLink, key: blue)
        let (ra, rb) = await (a, b)
        let receipt = try XCTUnwrap(ra)
        XCTAssertEqual(receipt, rb)
        XCTAssertTrue(receipt.isComplete)
        XCTAssertEqual(receipt.winner, TrainerSigning.encode(red.publicKey))
        XCTAssertEqual(receipt.boardId, kanto.boardId)
    }

    func testADrawIsCoSignedToo() async throws {
        let s = try await handshake(board: kanto, guestCodes: [kanto])
        async let a = NearbyBattleService.coSignedReceipt(s.challenger, outcome: .draw, link: s.challengerLink, key: red)
        async let b = NearbyBattleService.coSignedReceipt(s.guest, outcome: .draw, link: s.guestLink, key: blue)
        let (ra, rb) = await (a, b)
        XCTAssertNotNil(ra)
        XCTAssertNil(ra?.winner)
        XCTAssertEqual(ra, rb)
    }

    func testOutcomesThatDisagreeNeverVerify() async throws {
        // Both claim the win: each signature covers a different result, so neither receipt completes.
        let s = try await handshake(board: kanto, guestCodes: [kanto])
        async let a = NearbyBattleService.coSignedReceipt(s.challenger, outcome: .won, link: s.challengerLink, key: red)
        async let b = NearbyBattleService.coSignedReceipt(s.guest, outcome: .won, link: s.guestLink, key: blue)
        let (ra, rb) = await (a, b)
        XCTAssertNil(ra)
        XCTAssertNil(rb)
    }

    func testAForfeitCarriesTheLosersSignatureToTheWinner() async throws {
        let s = try await handshake(board: kanto, guestCodes: [kanto])
        let loser = NetworkOpponent(link: s.guestLink)
        loser.forfeitReceipt = { [match = s.guest] in try? match.receipt(winner: .a)?.signature(by: blue) }
        loser.notifyForfeit()
        while s.challengerLink.mailbox.closedWith == nil { await Task.yield() }
        let receipt = await NearbyBattleService.coSignedReceipt(s.challenger, outcome: .won, link: s.challengerLink, key: red)
        XCTAssertEqual(receipt?.isComplete, true)
        // The side that forfeited keeps nothing: its link is closed and it lost.
        s.guestLink.close()
        let none = await NearbyBattleService.coSignedReceipt(s.guest, outcome: .lost, link: s.guestLink, key: blue)
        XCTAssertNil(none)
    }

    func testADisconnectLeavesNothingToCoSign() async throws {
        let s = try await handshake(board: kanto, guestCodes: [kanto])
        s.guestLink.transport.close()
        while s.challengerLink.mailbox.closedWith == nil { await Task.yield() }
        let receipt = await NearbyBattleService.coSignedReceipt(s.challenger, outcome: .won, link: s.challengerLink, key: red)
        XCTAssertNil(receipt)
    }

    func testFriendliesAndAbortsProduceNoReceipt() async throws {
        let friendly = try await handshake(board: nil, guestCodes: [])
        let none = await NearbyBattleService.coSignedReceipt(friendly.challenger, outcome: .won, link: friendly.challengerLink, key: red)
        XCTAssertNil(none)
        let scoped = try await handshake(board: kanto, guestCodes: [kanto])
        let aborted = await NearbyBattleService.coSignedReceipt(scoped.challenger, outcome: .aborted, link: scoped.challengerLink, key: red)
        XCTAssertNil(aborted)
    }

    func testIncomingInvitesShowTheBoardOnlyForOurCodes() {
        let invite = BattleBoardInvite.make(for: kanto)
        XCTAssertEqual(invite.board(in: [johto, kanto]), kanto)
        XCTAssertNil(invite.board(in: [johto]))
        XCTAssertNil(BattleBoardInvite(nonce: invite.nonce, proof: "forged").board(in: [kanto]))
    }
}
