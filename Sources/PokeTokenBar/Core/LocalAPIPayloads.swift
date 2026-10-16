import Foundation

/// Response bodies of the local API, matching `web/src/api/types.ts`. Pure: built from values, so the
/// shapes are tested without the app.
enum LocalAPIPayloads {
    struct Trainer: Encodable {
        struct Identity: Encodable {
            let name: String
            let publicKey: String
            let fingerprint: String
        }
        let trainer: Identity
        let pokemon: [TrainerShowcase.Pokemon]
        let battleTeam: [String]
        let battleRecord: BattleRecord
        let gameStats: TrainerShowcase.GameStats
        let aiBand: WeeklyUsageBand?

        private enum CodingKeys: String, CodingKey { case trainer, pokemon, battleTeam, battleRecord, gameStats, aiBand }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(trainer, forKey: .trainer)
            try c.encode(pokemon, forKey: .pokemon)
            try c.encode(battleTeam, forKey: .battleTeam)
            try c.encode(battleRecord, forKey: .battleRecord)
            try c.encode(gameStats, forKey: .gameStats)
            try c.encode(aiBand, forKey: .aiBand)   // explicit null: the page tells "not shared" from missing
        }
    }

    struct Battle: Encodable {
        let battle: BattleSpectatorSnapshot?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(battle, forKey: .battle)
        }
        private enum CodingKeys: String, CodingKey { case battle }
    }

    /// Everyone this Mac has met, available ones first.
    struct Trainers: Encodable {
        let trainers: [TrainerListEntry]
    }

    /// Finished battles, newest first.
    struct History: Encodable {
        let battles: [BattleHistoryEntry]
    }

    struct Member: Encodable {
        let publicKey: String
        let fingerprint: String
        let displayName: String
        let isYou: Bool
        let joinedAt: Int64
        let updatedAt: Int64
        let stats: BoardStats
        let score: BoardScoring.Score
        let rank: Int
        let counted: BoardScoring.Counted
    }

    struct Board: Encodable {
        let id: String
        let name: String
        let you: String
        let members: [Member]
        let lastSyncAt: Int64?
        let syncedPeers: Int
        /// False for a league we only watch.
        let member: Bool

        private enum CodingKeys: String, CodingKey { case id, name, you, members, lastSyncAt, syncedPeers, member }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(you, forKey: .you)
            try c.encode(members, forKey: .members)
            try c.encode(lastSyncAt, forKey: .lastSyncAt)
            try c.encode(syncedPeers, forKey: .syncedPeers)
            try c.encode(member, forKey: .member)
        }
    }

    struct Boards: Encodable {
        let boards: [Board]
        let syncEnabled: Bool
    }

    static func trainer(name: String, publicKey: String?, showcase: TrainerShowcase, aiBand: WeeklyUsageBand?) -> Trainer {
        Trainer(trainer: .init(name: name, publicKey: publicKey ?? "", fingerprint: publicKey.map(TrainerSigning.fingerprint) ?? ""),
                pokemon: showcase.pokemon, battleTeam: showcase.battleTeam, battleRecord: showcase.battleRecord,
                gameStats: showcase.gameStats, aiBand: aiBand)
    }

    /// Your leagues first, then the ones you watch, most recently active first. Never includes a board's
    /// code: the page only shows boards, it can't hand them out.
    static func boards(_ boards: [BoardStore.Board], watched: [BoardReplica] = [], you: String?, syncEnabled: Bool) -> Boards {
        func members(_ replica: BoardReplica) -> [Member] {
            BoardScoring.standings(replica).map { standing in
                Member(publicKey: standing.record.publicKey, fingerprint: standing.record.fingerprint,
                       displayName: standing.record.displayName, isYou: standing.record.publicKey == you,
                       joinedAt: standing.record.joinedAt, updatedAt: standing.record.issuedAt, stats: standing.record.stats,
                       score: standing.score, rank: standing.rank, counted: standing.counted)
            }
        }
        let mine = boards.map { board in
            Board(id: board.id, name: board.name, you: you ?? "", members: members(board.replica),
                  lastSyncAt: board.lastSyncAt, syncedPeers: board.syncedWith.count, member: true)
        }
        let others = watched.map { replica in
            Board(id: replica.boardId, name: replica.name ?? "League \(replica.boardId.prefix(4).uppercased())", you: you ?? "",
                  members: members(replica), lastSyncAt: nil, syncedPeers: 0, member: false)
        }
        return Boards(boards: mine + others, syncEnabled: syncEnabled)
    }

    static func encode(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }
}
