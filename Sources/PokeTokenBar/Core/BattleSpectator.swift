import Foundation

/// The battle being played right now, for the trainer page to watch. Set by the battle window.
@MainActor @Observable
final class BattleSpectatorHub {
    static let shared = BattleSpectatorHub()
    private(set) var current: BattleSession?
    /// A fresh id per battle shown, so the page can tell a rematch or a new battle apart.
    private(set) var battleId = UUID().uuidString

    func show(_ session: BattleSession) {
        current = session
        battleId = UUID().uuidString
    }

    func clear(_ session: BattleSession) {
        if current === session { current = nil }
    }
}

/// What a spectator sees: the battle window's view of the field, never `BattleState` itself (its RNG
/// would let the page predict the battle). Built from the paced `display`, so it keeps the window's tempo.
struct BattleSpectatorSnapshot: Encodable, Equatable, Sendable {
    enum Kind: String, Encodable, Sendable { case practice, nearby }
    enum Status: String, Encodable, Sendable { case psn, tox, brn, par, slp, frz }

    struct Pokemon: Encodable, Equatable, Sendable {
        let speciesNum: Int
        let appearance: Int
        let name: String
        let level: Int
        let shiny: Bool
        let unownForm: String?
        let hp: Int
        let maxHp: Int
        let status: Status?
        let fainted: Bool
    }

    struct Side: Encodable, Equatable, Sendable {
        let trainer: String
        let isYou: Bool
        let active: Int
        let team: [Pokemon]
    }

    struct Move: Encodable, Equatable, Sendable {
        let name: String
        let type: String
        let pp: Int
        let maxPp: Int
        let usable: Bool
    }

    struct Board: Encodable, Equatable, Sendable {
        let id: String
        let name: String
    }

    let id: String
    let kind: Kind
    let board: Board?
    /// [0] is you.
    let sides: [Side]
    let moves: [Move]
    let message: String
    let log: [String]
    let turn: Int
    let outcome: String?
    /// Unix ms.
    let turnDeadline: Int?

    @MainActor
    static func make(from session: BattleSession, id: String, trainerName: String) -> BattleSpectatorSnapshot {
        let state = session.state, display = session.display
        func side(_ side: BattleSide, trainer: String) -> Side {
            let index = side.rawValue
            let team = state[side].team.enumerated().map { i, combatant -> Pokemon in
                let hp = display.hp[index][i]
                return Pokemon(speciesNum: combatant.pokemon.speciesID,
                               appearance: i == display.active[index] ? combatant.appearance ?? combatant.pokemon.speciesID
                                                                      : combatant.pokemon.speciesID,
                               name: session.name(side, i), level: combatant.pokemon.level, shiny: combatant.pokemon.isShiny,
                               unownForm: combatant.pokemon.unownForm?.rawValue, hp: hp, maxHp: combatant.maxHP,
                               status: display.status[index][i].map(Self.status), fainted: hp == 0)
            }
            return Side(trainer: trainer, isYou: side == session.mySide, active: display.active[index], team: team)
        }
        let mine = state[session.mySide].team[display.active[session.mySide.rawValue]]
        let usable = session.usableMoves
        let moves = mine.moves.enumerated().map { i, move in
            Move(name: session.moveName(move.name), type: session.typeName(move.type),
                 pp: mine.pp[i], maxPp: mine.maxPP[i], usable: usable.contains(i))
        }
        let outcome: String? = switch session.outcome {
        case .won?: "won"
        case .lost?: "lost"
        case .draw?: "draw"
        case .aborted?: "aborted"
        case nil: nil
        }
        return BattleSpectatorSnapshot(
            id: id,
            kind: session.canRematch ? .practice : .nearby,
            board: session.board.map { Board(id: $0.id, name: $0.name) },
            sides: [side(session.mySide, trainer: trainerName),
                    side(session.theirSide, trainer: session.opponentName ?? session.l.battleOpposingTeam)],
            moves: moves,
            message: session.message,
            log: session.log,
            turn: state.turn,
            outcome: outcome,
            turnDeadline: session.turnDeadline.map { Int(($0.timeIntervalSince1970 * 1000).rounded()) })
    }

    static func status(_ status: BattleStatus) -> Status {
        switch status {
        case .burn: return .brn
        case .paralysis: return .par
        case .poison: return .psn
        case .badPoison: return .tox
        case .sleep: return .slp
        case .freeze: return .frz
        }
    }
}
