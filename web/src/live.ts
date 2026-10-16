import type { Board, BattleResponse, BattleSnapshot, BoardsResponse, HistoryEntry, HistoryResponse, TrainerEntry, TrainerResponse, TrainersResponse } from './api/types';

/** Everything the page shows, as last pushed by the app. */
export interface LiveData {
  trainer?: TrainerResponse;
  battle?: BattleResponse;
  boards?: BoardsResponse;
  history?: HistoryResponse;
  trainers?: TrainersResponse;
}

/** The data after one `trainer`, `battle`, `boards`, `history` or `trainers` event; other event names leave it as is. */
export function applyEvent(data: LiveData, name: string, payload: unknown): LiveData {
  if (payload === null || typeof payload !== 'object') return data;
  switch (name) {
    case 'trainer': return { ...data, trainer: payload as TrainerResponse };
    case 'battle': return { ...data, battle: payload as BattleResponse };
    case 'boards': return { ...data, boards: payload as BoardsResponse };
    case 'history': return { ...data, history: payload as HistoryResponse };
    case 'trainers': return { ...data, trainers: payload as TrainersResponse };
    default: return data;
  }
}

/** A battle is live from the first snapshot until its outcome is set. */
export function isBattleLive(data: LiveData): boolean {
  const battle = data.battle?.battle;
  return Boolean(battle && battle.outcome == null);
}

/** The battle on screen in the app, while it is still being played. */
export function liveBattle(data: LiveData): BattleSnapshot | undefined {
  return isBattleLive(data) ? data.battle?.battle ?? undefined : undefined;
}

/** A past battle by id. */
export function pastBattle(data: LiveData, id: string): HistoryEntry | undefined {
  return data.history?.battles.find((b) => b.id === id);
}

/** Wins, losses and draws among saved battles; called-off ones don't count. */
export function historyRecord(entries: HistoryEntry[]): { wins: number; losses: number; draws: number } {
  const count = (o: string) => entries.filter((e) => e.battle.outcome === o).length;
  return { wins: count('won'), losses: count('lost'), draws: count('draw') };
}

export type TrainerFilter = 'all' | 'league';

/** Everyone met, or only members of your league, in the app's order. */
export function filterTrainers(trainers: TrainerEntry[], filter: TrainerFilter): TrainerEntry[] {
  return filter === 'league' ? trainers.filter((t) => t.league !== null) : trainers;
}

/** Your leagues and the ones you only watch, each in the app's order. */
export function splitLeagues(boards: Board[]): { mine: Board[]; watched: Board[] } {
  return { mine: boards.filter((b) => b.member), watched: boards.filter((b) => !b.member) };
}
