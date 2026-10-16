import { describe, expect, it } from 'vitest';
import type { Board, BattleResponse, BattleSnapshot, BoardsResponse, HistoryEntry, HistoryResponse, TrainerEntry, TrainerResponse } from '../src/api/types';
import { applyEvent, filterTrainers, splitLeagues, historyRecord, isBattleLive, liveBattle, pastBattle, type LiveData } from '../src/live';

const trainer = { trainer: { name: 'Ash' } } as TrainerResponse;
const boards: BoardsResponse = { boards: [], syncEnabled: true };
const battle = (outcome: BattleSnapshot['outcome']): BattleResponse => ({ battle: { id: 'b', outcome } as BattleSnapshot });

describe('applyEvent', () => {
  it('stores each event under its own key and keeps the others', () => {
    let d: LiveData = {};
    d = applyEvent(d, 'trainer', trainer);
    d = applyEvent(d, 'boards', boards);
    d = applyEvent(d, 'battle', battle(null));
    expect(d).toEqual({ trainer, boards, battle: battle(null) });
  });

  it('replaces the previous value, without mutating the old state', () => {
    const before: LiveData = { trainer };
    const next = { trainer: { name: 'Gary' } } as TrainerResponse;
    const after = applyEvent(before, 'trainer', next);
    expect(after.trainer).toBe(next);
    expect(before.trainer).toBe(trainer);
  });

  it('ignores unknown event names and non-object payloads', () => {
    const before: LiveData = { trainer };
    expect(applyEvent(before, 'ping', {})).toBe(before);
    expect(applyEvent(before, 'trainer', null)).toBe(before);
    expect(applyEvent(before, 'trainer', 'x')).toBe(before);
  });

  it('keeps a battle response with no battle', () => {
    expect(applyEvent({}, 'battle', { battle: null }).battle).toEqual({ battle: null });
  });
});

describe('isBattleLive', () => {
  it('is true only while a battle has no outcome', () => {
    expect(isBattleLive({})).toBe(false);
    expect(isBattleLive({ battle: { battle: null } })).toBe(false);
    expect(isBattleLive({ battle: battle(null) })).toBe(true);
    expect(isBattleLive({ battle: battle('won') })).toBe(false);
  });

  it('treats a missing outcome as none, as an older app sends it', () => {
    expect(isBattleLive({ battle: { battle: { id: 'b' } as BattleSnapshot } })).toBe(true);
    expect(liveBattle({ battle: { battle: { id: 'b' } as BattleSnapshot } })?.id).toBe('b');
    expect(liveBattle({ battle: battle('lost') })).toBeUndefined();
  });
});

const entry = (id: string, outcome: BattleSnapshot['outcome']): HistoryEntry =>
  ({ id, finishedAt: 1, battle: { id, outcome } as BattleSnapshot });

describe('history', () => {
  const history: HistoryResponse = { battles: [entry('h3', 'won'), entry('h2', 'aborted'), entry('h1', 'lost'), entry('h0', 'won')] };

  it('arrives as its own event', () => {
    expect(applyEvent({ trainer }, 'history', history)).toEqual({ trainer, history });
  });

  it('finds a past battle by id', () => {
    expect(pastBattle({ history }, 'h1')?.battle.outcome).toBe('lost');
    expect(pastBattle({ history }, 'nope')).toBeUndefined();
    expect(pastBattle({}, 'h1')).toBeUndefined();
  });

  it('counts results, leaving out called-off battles', () => {
    expect(historyRecord(history.battles)).toEqual({ wins: 2, losses: 1, draws: 0 });
    expect(historyRecord([])).toEqual({ wins: 0, losses: 0, draws: 0 });
  });
});

const met = (name: string, league: TrainerEntry['league']): TrainerEntry =>
  ({ publicKey: name, fingerprint: 'ABCD', name, presence: 'away', lastSeenAt: null, league, team: [], vsYou: { wins: 0, losses: 0, draws: 0 }, lastBattleAt: null });

describe('trainers', () => {
  const list = [met('Erika', null), met('Misty', { id: 'k', name: 'Kanto', rank: 2, points: 9 }), met('Gary', null)];

  it('arrives as its own event', () => {
    expect(applyEvent({}, 'trainers', { trainers: list }).trainers?.trainers).toBe(list);
  });

  it('filters to your league, keeping the order', () => {
    expect(filterTrainers(list, 'all')).toBe(list);
    expect(filterTrainers(list, 'league').map((t) => t.name)).toEqual(['Misty']);
    expect(filterTrainers([], 'league')).toEqual([]);
  });
});

describe('leagues', () => {
  const league = (id: string, member: boolean) => ({ id, member }) as Board;

  it('splits yours from the watched ones, keeping the order', () => {
    const boards = [league('mine', true), league('w2', false), league('w1', false)];
    expect(splitLeagues(boards)).toEqual({ mine: [boards[0]], watched: [boards[1], boards[2]] });
    expect(splitLeagues([])).toEqual({ mine: [], watched: [] });
  });
});
