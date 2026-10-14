import Foundation

/// Weekly AI token band, the only usage figure that ever reaches a board or the trainer page.
enum WeeklyUsageBand: String, Codable, Sendable, CaseIterable {
    case light, moderate, heavy, extreme

    init(weekTokens: Int) {
        switch weekTokens {
        case ..<10_000_000: self = .light
        case ..<100_000_000: self = .moderate
        case ..<1_000_000_000: self = .heavy
        default: self = .extreme
        }
    }

    init(snapshots: [ProviderSnapshot]) {
        self.init(weekTokens: snapshots.reduce(0) { $0 + ($1.weekTotal?.totalTokens ?? 0) })
    }
}

/// What the trainer page shows about the save. Pure: built from `CompanionState`, tested without the app.
struct TrainerShowcase: Encodable, Equatable, Sendable {
    struct Pokemon: Encodable, Equatable, Sendable {
        enum Status: String, Encodable, Sendable { case active, graduated, released }
        let instanceId: String
        let speciesNum: Int
        let species: String
        let form: String?
        let shiny: Bool
        let nature: String?
        let gender: String?
        let level: Int
        let ability: String?
        let moves: [String]
        /// Unix milliseconds.
        let caughtAt: Int?
        let status: Status
    }

    struct GameStats: Codable, Equatable, Sendable {
        let pokemonCount: Int
        let speciesCount: Int
        let shinyCount: Int
        let graduatedCount: Int
        let releasedCount: Int
        let highestLevel: Int
        let totalLevels: Int
    }

    let pokemon: [Pokemon]
    let battleTeam: [String]
    let battleRecord: BattleRecord
    let gameStats: GameStats

    /// `activeName` is the active pokemon's name as the app shows it; dex entries carry their own names.
    static func build(state: CompanionState, activeName: String?) -> TrainerShowcase {
        let pokemon = pokemon(from: state, activeName: activeName)
        let owned = Set(pokemon.map(\.instanceId))
        return TrainerShowcase(pokemon: pokemon,
                               battleTeam: state.battleTeam.filter(owned.contains),
                               battleRecord: state.battleRecord,
                               gameStats: stats(pokemon))
    }

    /// Graduated and released dex entries, then the active pokemon. Entries from before battle profiles
    /// (profile still nil) are skipped until the store migrates them.
    static func pokemon(from state: CompanionState, activeName: String?) -> [Pokemon] {
        var result = state.dex.compactMap { entry -> Pokemon? in
            guard let profile = entry.profile else { return nil }
            let name = entry.names?[entry.finalID].flatMap { state.language.resolveName($0) }
            return make(profile: profile, speciesNum: entry.finalID, name: name, unownForm: entry.unownForm,
                        shiny: entry.isShiny, nature: entry.nature, caughtAt: entry.caughtAt,
                        status: entry.isReleased ? .released : .graduated)
        }
        if let active = state.active, let profile = active.profile {
            result.append(make(profile: profile, speciesNum: active.currentID, name: activeName, unownForm: active.unownForm,
                               shiny: active.isShiny, nature: active.nature, caughtAt: nil, status: .active))
        }
        return result
    }

    private static func make(profile: PokemonProfile, speciesNum: Int, name: String?, unownForm: UnownForm?, shiny: Bool,
                             nature: PokemonNature?, caughtAt: Date?, status: Pokemon.Status) -> Pokemon {
        Pokemon(instanceId: profile.instanceID,
                speciesNum: speciesNum,
                species: name ?? "#\(speciesNum)",
                form: speciesNum == UnownForm.speciesID ? unownForm?.rawValue : nil,
                shiny: shiny,
                nature: nature?.rawValue,
                gender: profile.gender?.rawValue,
                level: profile.level,
                ability: profile.abilityName,
                moves: Array(profile.moves.map(\.name).prefix(4)),
                caughtAt: caughtAt.map { Int(($0.timeIntervalSince1970 * 1000).rounded()) },
                status: status)
    }

    static func stats(_ pokemon: [Pokemon]) -> GameStats {
        GameStats(pokemonCount: pokemon.count,
                  speciesCount: Set(pokemon.map(\.speciesNum)).count,
                  shinyCount: pokemon.filter(\.shiny).count,
                  graduatedCount: pokemon.filter { $0.status == .graduated }.count,
                  releasedCount: pokemon.filter { $0.status == .released }.count,
                  highestLevel: pokemon.map(\.level).max() ?? 0,
                  totalLevels: pokemon.reduce(0) { $0 + $1.level })
    }
}
