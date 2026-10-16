import Foundation

extension BoardStats {
    /// What a trainer publishes to their boards, from the same showcase the trainer page shows.
    /// `aiBand` is nil unless the trainer opted in.
    init(showcase: TrainerShowcase, aiBand: WeeklyUsageBand?) {
        let byId = Dictionary(showcase.pokemon.map { ($0.instanceId, $0) }, uniquingKeysWith: { a, _ in a })
        let team = showcase.battleTeam.prefix(6).compactMap { byId[$0] }
        let stats = showcase.gameStats
        self.init(collection: Collection(dex: stats.pokemonCount, species: stats.speciesCount,
                                         shinies: stats.shinyCount, graduated: stats.graduatedCount),
                  levels: Levels(teamTotal: team.reduce(0) { $0 + $1.level }, top: stats.highestLevel),
                  aiBand: aiBand,
                  battleRecord: showcase.battleRecord,
                  team: team.map { TeamMember(speciesNum: $0.speciesNum, species: String($0.species.prefix(BoardRules.maxNameLength)),
                                              form: $0.form.map { String($0.prefix(16)) }, shiny: $0.shiny, level: $0.level) }
                      .filter(\.isPlausible))
    }
}
