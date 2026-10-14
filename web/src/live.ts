import type { BattleResponse, BoardsResponse, TrainerResponse } from './api/types';

/** Everything the page shows, as last pushed by the app. */
export interface LiveData {
  trainer?: TrainerResponse;
  battle?: BattleResponse;
  boards?: BoardsResponse;
}

/** The data after one `trainer`, `battle` or `boards` event; other event names leave it as is. */
export function applyEvent(data: LiveData, name: string, payload: unknown): LiveData {
  if (payload === null || typeof payload !== 'object') return data;
  switch (name) {
    case 'trainer': return { ...data, trainer: payload as TrainerResponse };
    case 'battle': return { ...data, battle: payload as BattleResponse };
    case 'boards': return { ...data, boards: payload as BoardsResponse };
    default: return data;
  }
}

/** A battle is live from the first snapshot until its outcome is set. */
export function isBattleLive(data: LiveData): boolean {
  const battle = data.battle?.battle;
  return Boolean(battle && battle.outcome === null);
}
