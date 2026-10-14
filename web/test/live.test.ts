import { describe, expect, it } from 'vitest';
import type { BattleResponse, BattleSnapshot, BoardsResponse, TrainerResponse } from '../src/api/types';
import { applyEvent, isBattleLive, type LiveData } from '../src/live';

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
});
