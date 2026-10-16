// Shapes of the PokeTokenBar app's local read-only API (`http://127.0.0.1:<port>/v1/...`).

export type AiBand = 'light' | 'moderate' | 'heavy' | 'extreme';
export interface Trainer { name: string; publicKey: string; fingerprint: string } // fingerprint: 4 Crockford chars, show next to names
export interface GameStats { pokemonCount: number; speciesCount: number; shinyCount: number; graduatedCount: number; releasedCount: number; highestLevel: number; totalLevels: number }
export interface ShowcasePokemon {
  instanceId: string; speciesNum: number; species: string; // localized species name
  form?: string | null; shiny: boolean; nature?: string | null; gender?: string | null; level: number;
  ability?: string | null; moves: string[]; caughtAt?: number | null; status: 'active' | 'graduated' | 'released';
}
export interface BattleRecord { wins: number; losses: number; draws: number }
export interface TrainerResponse {
  trainer: Trainer;
  pokemon: ShowcasePokemon[];
  battleTeam: string[];          // instanceIds in slot order; [0] is the lead
  battleRecord: BattleRecord;    // self-reported, all nearby battles
  gameStats: GameStats;
  aiBand: AiBand | null;         // only when the user opted in
}
export type StatusCondition = 'psn' | 'tox' | 'brn' | 'par' | 'slp' | 'frz';
export interface SpectatorPokemon {
  speciesNum: number; appearance: number; // species shown (differs after Transform)
  name: string; level: number; shiny: boolean; unownForm: string | null;
  hp: number; maxHp: number; status: StatusCondition | null; fainted: boolean;
}
export interface SpectatorSide { trainer: string; isYou: boolean; active: number; team: SpectatorPokemon[] }
export interface SpectatorMove { name: string; type: string; pp: number; maxPp: number; usable: boolean }
export interface BattleSnapshot {
  id: string; kind: 'practice' | 'nearby'; board: { id: string; name: string } | null;
  sides: [SpectatorSide, SpectatorSide]; // [0] is you
  moves: SpectatorMove[];                // your active pokemon's moves
  message: string; log: string[]; turn: number;
  outcome: 'won' | 'lost' | 'draw' | 'aborted' | null;
  turnDeadline: number | null;           // unix ms
}
export interface BattleResponse { battle: BattleSnapshot | null }
/** A finished battle: `battle` is the field as it ended, with an empty `moves` and a null `turnDeadline`. */
export interface HistoryEntry { id: string; finishedAt: number; opponentFingerprint?: string | null; battle: BattleSnapshot }
export interface HistoryResponse { battles: HistoryEntry[] } // newest first, up to 100
export interface BoardTeamMember { speciesNum: number; species: string; form?: string | null; shiny: boolean; level: number } // species in that trainer's language
export interface BoardStats {
  collection: { dex: number; species: number; shinies: number; graduated: number }; levels: { teamTotal: number; top: number };
  aiBand?: AiBand | null; battleRecord: BattleRecord;
  team?: BoardTeamMember[]; // battle team in slot order; missing when empty or signed by an older build
}
export interface Score { total: number; battle: number; collection: number; levels: number; ai: number }
export interface BoardMember {
  publicKey: string; fingerprint: string; displayName: string; isYou: boolean;
  joinedAt: number; updatedAt: number; // unix ms; updatedAt = when their latest record was signed
  stats: BoardStats; score: Score; rank: number; // rank 1-based, ties share a rank
  counted: { wins: number; draws: number; losses: number }; // co-signed results that scored
}
export interface Board { id: string; name: string; you: string; members: BoardMember[]; lastSyncAt: number | null; syncedPeers: number }
export interface BoardsResponse { boards: Board[]; syncEnabled: boolean }
/** available: visible for battles and at their Mac in the last 5 minutes. idle: visible, away from the Mac. away: not visible. */
export type Presence = 'available' | 'idle' | 'away';
export interface TrainerEntry {
  publicKey: string; fingerprint: string; name: string; presence: Presence;
  lastSeenAt: number | null;  // unix ms; now while visible, null when never seen nearby
  league: { id: string; name: string; rank: number; points: number } | null; // in your league
  team: BoardTeamMember[];    // their league row's team, else their team in your last battle
  vsYou: BattleRecord;        // your wins, losses and draws against them
  lastBattleAt: number | null;
}
export interface TrainersResponse { trainers: TrainerEntry[] } // available first, then idle, then by last seen
export interface ApiErrorBody { error: string; message: string } // e.g. 403 origin_not_paired, 421 misdirected
