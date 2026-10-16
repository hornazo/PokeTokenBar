import Foundation

/// Someone this Mac saw nearby, kept so the trainer list remembers them after they leave.
struct TrainerSighting: Codable, Equatable, Sendable {
    let publicKey: String
    var name: String
    /// Unix ms.
    var lastSeenAt: Int64
}

/// One trainer on the page's list: a league member, someone seen nearby, or someone battled.
struct TrainerListEntry: Encodable, Equatable, Sendable {
    struct League: Encodable, Equatable, Sendable {
        let id: String
        let name: String
        let rank: Int
        let points: Int
    }

    /// From your side: your wins against them.
    struct Record: Encodable, Equatable, Sendable {
        var wins = 0
        var losses = 0
        var draws = 0
    }

    let publicKey: String
    let fingerprint: String
    let name: String
    let presence: TrainerPresence
    /// Unix ms; now while they're visible, nil when never seen nearby.
    let lastSeenAt: Int64?
    /// Their place in your league, when they're in it.
    let league: League?
    /// Their battle team: as their league row says, else as it was in your last battle with them.
    let team: [BoardStats.TeamMember]
    let vsYou: Record
    let lastBattleAt: Int64?

    private enum CodingKeys: String, CodingKey {
        case publicKey, fingerprint, name, presence, lastSeenAt, league, team, vsYou, lastBattleAt
    }

    /// Explicit nulls, like the page's types.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(publicKey, forKey: .publicKey)
        try c.encode(fingerprint, forKey: .fingerprint)
        try c.encode(name, forKey: .name)
        try c.encode(presence, forKey: .presence)
        try c.encode(lastSeenAt, forKey: .lastSeenAt)
        try c.encode(league, forKey: .league)
        try c.encode(team, forKey: .team)
        try c.encode(vsYou, forKey: .vsYou)
        try c.encode(lastBattleAt, forKey: .lastBattleAt)
    }
}

/// Everyone this Mac has met, merged from its league, nearby sightings and battle history. Pure.
enum TrainerList {
    struct Nearby: Equatable, Sendable {
        let publicKey: String
        let name: String
        let active: Bool
    }

    struct League {
        let id: String
        let name: String
        let replica: BoardReplica
    }

    static func build(you: String?, league: League?, sightings: [TrainerSighting], nearby: [Nearby],
                      history: [BattleHistoryEntry], now: Int64) -> [TrainerListEntry] {
        let standings = league.map { BoardScoring.standings($0.replica) } ?? []
        let members = Dictionary(standings.map { ($0.record.publicKey, $0) }, uniquingKeysWith: { a, _ in a })
        let seen = Dictionary(sightings.map { ($0.publicKey, $0) }, uniquingKeysWith: { a, b in a.lastSeenAt >= b.lastSeenAt ? a : b })
        let here = Dictionary(nearby.map { ($0.publicKey, $0) }, uniquingKeysWith: { a, _ in a })
        // Newest first, so the first battle found per key is the latest.
        let battles = Dictionary(grouping: history.filter { $0.opponentKey != nil }, by: { $0.opponentKey! })
            .mapValues { $0.sorted { $0.finishedAt > $1.finishedAt } }

        var keys = Set(members.keys).union(seen.keys).union(here.keys).union(battles.keys)
        if let you { keys.remove(you) }

        let entries = keys.map { key -> TrainerListEntry in
            let member = members[key], nearby = here[key], fought = battles[key] ?? []
            let name = nearby?.name ?? member?.record.displayName ?? seen[key]?.name ?? fought.first?.battle.sides.last?.trainer ?? ""
            var record = TrainerListEntry.Record()
            for entry in fought {
                switch entry.battle.outcome {
                case "won": record.wins += 1
                case "lost": record.losses += 1
                case "draw": record.draws += 1
                default: break
                }
            }
            let rowTeam = member?.record.stats.team ?? []
            let team = !rowTeam.isEmpty ? rowTeam : (fought.first?.battle.sides.last?.team ?? []).map {
                BoardStats.TeamMember(speciesNum: $0.speciesNum, species: $0.name, form: $0.unownForm, shiny: $0.shiny, level: $0.level)
            }
            return TrainerListEntry(
                publicKey: key, fingerprint: TrainerSigning.fingerprint(key), name: name,
                presence: nearby.map { $0.active ? .available : .idle } ?? .away,
                lastSeenAt: nearby != nil ? now : seen[key]?.lastSeenAt,
                league: member.flatMap { m in league.map { .init(id: $0.id, name: $0.name, rank: m.rank, points: m.score.total) } },
                team: team, vsYou: record, lastBattleAt: fought.first?.finishedAt)
        }
        return entries.sorted { a, b in
            if a.presence != b.presence { return a.presence < b.presence }
            switch (a.league?.rank, b.league?.rank) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            if (a.lastSeenAt ?? 0) != (b.lastSeenAt ?? 0) { return (a.lastSeenAt ?? 0) > (b.lastSeenAt ?? 0) }
            let byName = a.name.localizedCaseInsensitiveCompare(b.name)
            return byName != .orderedSame ? byName == .orderedAscending : a.publicKey < b.publicKey
        }
    }
}
