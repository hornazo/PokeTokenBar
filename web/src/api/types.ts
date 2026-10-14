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
export interface BoardStats { collection: { dex: number; species: number; shinies: number; graduated: number }; levels: { teamTotal: number; top: number }; aiBand: AiBand | null; battleRecord: BattleRecord }
export interface Score { total: number; battle: number; collection: number; levels: number; ai: number }
export interface BoardMember {
  publicKey: string; fingerprint: string; displayName: string; isYou: boolean;
  joinedAt: number; updatedAt: number; // unix ms; updatedAt = when their latest record was signed
  stats: BoardStats; score: Score; rank: number; // rank 1-based, ties share a rank
  counted: { wins: number; draws: number; losses: number }; // co-signed results that scored
}
export interface Board { id: string; name: string; you: string; members: BoardMember[]; lastSyncAt: number | null; syncedPeers: number }
export interface BoardsResponse { boards: Board[]; syncEnabled: boolean }
export interface ApiErrorBody { error: string; message: string } // e.g. 403 origin_not_paired, 421 misdirected
