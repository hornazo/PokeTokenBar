import XCTest
@testable import PokeTokenBar

final class TrainerShowcaseTests: XCTestCase {
    private func profile(_ id: String, level: Int, moves: [String] = ["tackle"]) -> PokemonProfile {
        var p = PokemonProfile.generate(seed: 42, instanceID: id)
        p.level = level
        p.gender = .female
        p.abilityName = "static"
        p.moves = moves.map { PokemonKnownMove(name: $0, learnedAtLevel: 1) }
        return p
    }

    private func state(active: MonState? = nil, dex: [DexEntry] = [], team: [String] = []) -> CompanionState {
        var s = CompanionState()
        s.active = active
        s.dex = dex
        s.battleTeam = team
        s.battleRecord = BattleRecord(wins: 3, losses: 1, draws: 0)
        return s
    }

    func testMapsGraduatedReleasedAndActivePokemon() {
        let caught = Date(timeIntervalSince1970: 1_700_000_000.5)
        let graduated = DexEntry(baseID: 172, finalID: 26, chainOrder: [172, 25, 26], rarity: .common,
                                 caughtAt: caught, isShiny: true, nature: .timid,
                                 profile: profile("grad", level: 80, moves: ["thunderbolt", "quick-attack", "a", "b", "c"]),
                                 names: [26: ["en": "Raichu", "ko": "라이츄"]])
        let released = DexEntry(baseID: 1, finalID: 2, chainOrder: [1, 2, 3], rarity: .common, caughtAt: nil,
                                profile: profile("rel", level: 20), releasedAt: Date())
        var active = MonState(baseID: 4, pathIDs: [4, 5], plannedPathIDs: [4, 5, 6], stageIndex: 1,
                              usedAtStage: 0, rarity: .common, totalForms: 3)
        active.profile = profile("act", level: 30)
        active.nature = .bold

        let showcase = TrainerShowcase.build(state: state(active: active, dex: [graduated, released], team: ["act", "gone", "grad"]),
                                             activeName: "Charmeleon")

        XCTAssertEqual(showcase.pokemon.map(\.instanceId), ["grad", "rel", "act"])
        XCTAssertEqual(showcase.pokemon.map(\.speciesNum), [26, 2, 5], "final species for dex entries, current stage for the active one")
        XCTAssertEqual(showcase.pokemon.map(\.species), ["Raichu", "#2", "Charmeleon"])
        XCTAssertEqual(showcase.pokemon.map(\.status), [.graduated, .released, .active])
        XCTAssertEqual(showcase.pokemon[0].moves.count, 4)
        XCTAssertEqual(showcase.pokemon[0].caughtAt, 1_700_000_000_500)
        XCTAssertEqual(showcase.pokemon[0].nature, "timid")
        XCTAssertEqual(showcase.pokemon[0].gender, "female")
        XCTAssertTrue(showcase.pokemon[0].shiny)
        XCTAssertNil(showcase.pokemon[2].caughtAt)
        XCTAssertEqual(showcase.battleTeam, ["act", "grad"], "team slots that no longer exist are dropped")
        XCTAssertEqual(showcase.battleRecord.wins, 3)
        XCTAssertEqual(showcase.gameStats, .init(pokemonCount: 3, speciesCount: 3, shinyCount: 1, graduatedCount: 1,
                                                 releasedCount: 1, highestLevel: 80, totalLevels: 130))
    }

    func testSkipsPreProfileEntriesAndEggs() {
        let legacy = DexEntry(baseID: 1, finalID: 3, chainOrder: [1, 2, 3], rarity: .common, caughtAt: nil)
        let showcase = TrainerShowcase.build(state: state(dex: [legacy]), activeName: nil)
        XCTAssertTrue(showcase.pokemon.isEmpty)
        XCTAssertEqual(showcase.gameStats.highestLevel, 0)
    }

    func testSendsTheUnownLetterOnlyForUnown() {
        let unown = DexEntry(baseID: 201, finalID: 201, chainOrder: [201], rarity: .rare, caughtAt: nil,
                             profile: profile("u", level: 10), unownForm: .exclamation)
        XCTAssertEqual(TrainerShowcase.build(state: state(dex: [unown]), activeName: nil).pokemon.first?.form, "exclamation")
    }

    func testWeeklyBandBoundaries() {
        XCTAssertEqual(WeeklyUsageBand(weekTokens: 0), .light)
        XCTAssertEqual(WeeklyUsageBand(weekTokens: 9_999_999), .light)
        XCTAssertEqual(WeeklyUsageBand(weekTokens: 10_000_000), .moderate)
        XCTAssertEqual(WeeklyUsageBand(weekTokens: 100_000_000), .heavy)
        XCTAssertEqual(WeeklyUsageBand(weekTokens: 1_000_000_000), .extreme)
    }
}
