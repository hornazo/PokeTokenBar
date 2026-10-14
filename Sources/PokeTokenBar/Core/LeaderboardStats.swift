import Foundation

extension BoardStats {
    /// What a trainer publishes to their boards, from the same showcase the trainer page shows.
    /// `aiBand` is nil unless the trainer opted in.
    init(showcase: TrainerShowcase, aiBand: WeeklyUsageBand?) {
        let levels = Dictionary(showcase.pokemon.map { ($0.instanceId, $0.level) }, uniquingKeysWith: max)
        let stats = showcase.gameStats
        self.init(collection: Collection(dex: stats.pokemonCount, species: stats.speciesCount,
                                         shinies: stats.shinyCount, graduated: stats.graduatedCount),
                  levels: Levels(teamTotal: showcase.battleTeam.prefix(6).reduce(0) { $0 + (levels[$1] ?? 0) },
                                 top: stats.highestLevel),
                  aiBand: aiBand,
                  battleRecord: showcase.battleRecord)
    }
}
