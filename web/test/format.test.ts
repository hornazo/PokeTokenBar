import { describe, expect, it } from 'vitest';
import type { ShowcasePokemon, TrainerResponse } from '../src/api/types';
import { battleTeamOf, hpPercent, hpTone, leadPokemon, relativeTime, secondsLeft, showcaseOrder, statusBadge, titleCase } from '../src/lib/format';
import { href, parseRoute } from '../src/lib/routes';

const mon = (instanceId: string, speciesNum: number, species: string, level: number, extra: Partial<ShowcasePokemon> = {}): ShowcasePokemon =>
  ({ instanceId, speciesNum, species, shiny: false, level, moves: [], status: 'active', ...extra });
const trainer = (pokemon: ShowcasePokemon[], battleTeam: string[]): TrainerResponse => ({
  trainer: { name: 'Ash', publicKey: 'k', fingerprint: 'AB12' }, pokemon, battleTeam,
  battleRecord: { wins: 0, losses: 0, draws: 0 },
  gameStats: { pokemonCount: 0, speciesCount: 0, shinyCount: 0, graduatedCount: 0, releasedCount: 0, highestLevel: 0, totalLevels: 0 },
  aiBand: null,
});

describe('relativeTime', () => {
  const now = new Date(2026, 9, 14, 12, 0).getTime();
  it('says how long ago', () => {
    expect(relativeTime(now - 20_000, now)).toBe('just now');
    expect(relativeTime(now + 5_000, now)).toBe('just now');
    expect(relativeTime(now - 5 * 60_000, now)).toBe('5 min ago');
    expect(relativeTime(now - 3 * 3_600_000, now)).toBe('3 h ago');
    expect(relativeTime(now - 2 * 86_400_000, now)).toBe('2 d ago');
    expect(relativeTime(now - 29 * 86_400_000, now)).toBe('29 d ago');
  });
  it('falls back to a date after a month', () => {
    expect(relativeTime(now - 40 * 86_400_000, now)).toBe(new Date(now - 40 * 86_400_000).toLocaleDateString(undefined, { day: 'numeric', month: 'short' }));
  });
});

describe('HP bar', () => {
  it('is green above half, yellow above a fifth, red below', () => {
    expect(hpTone(100, 100)).toBe('high');
    expect(hpTone(51, 100)).toBe('high');
    expect(hpTone(50, 100)).toBe('mid');
    expect(hpTone(21, 100)).toBe('mid');
    expect(hpTone(20, 100)).toBe('low');
    expect(hpTone(0, 100)).toBe('low');
    expect(hpTone(0, 0)).toBe('low');
  });
  it('clamps the width to 0–100%', () => {
    expect([hpPercent(50, 200), hpPercent(300, 200), hpPercent(-5, 200), hpPercent(1, 0)]).toEqual([25, 100, 0, 0]);
  });
});

describe('status badges', () => {
  it('shows badly poisoned as PSN in its own darker tone', () => {
    expect(statusBadge('psn')).toEqual({ label: 'PSN', tone: 'psn' });
    expect(statusBadge('tox')).toEqual({ label: 'PSN', tone: 'tox' });
    expect((['brn', 'par', 'slp', 'frz'] as const).map((s) => statusBadge(s).label)).toEqual(['BRN', 'PAR', 'SLP', 'FRZ']);
  });
});

describe('turn timer', () => {
  it('counts whole seconds up and stops at 0', () => {
    expect(secondsLeft(10_500, 10_000)).toBe(1);
    expect(secondsLeft(40_000, 10_000)).toBe(30);
    expect(secondsLeft(5_000, 10_000)).toBe(0);
  });
});

describe('trainer card', () => {
  const pokemon = [mon('a', 25, 'Pikachu', 30), mon('b', 6, 'Charizard', 80, { status: 'graduated' }), mon('c', 1, 'Bulbasaur', 40), mon('d', 4, 'Charmander', 90, { status: 'released' })];

  it('leads with the first battle team slot, else the highest-level active pokemon', () => {
    expect(leadPokemon(trainer(pokemon, ['a']))?.instanceId).toBe('a');
    expect(leadPokemon(trainer(pokemon, []))?.instanceId).toBe('c');
    expect(leadPokemon(trainer([mon('b', 6, 'Charizard', 80, { status: 'graduated' })], []))?.instanceId).toBe('b');
    expect(leadPokemon(trainer([], []))).toBeUndefined();
  });

  it('keeps team slot order and skips unknown ids', () => {
    expect(battleTeamOf(trainer(pokemon, ['c', 'zz', 'a'])).map((p) => p.instanceId)).toEqual(['c', 'a']);
  });

  it('orders the showcase by level and leaves released pokemon out', () => {
    expect(showcaseOrder(pokemon).map((p) => p.instanceId)).toEqual(['b', 'c', 'a']);
  });

  it('title-cases PokéAPI names', () => {
    expect(titleCase('swift-swim')).toBe('Swift Swim');
    expect(titleCase('Thunderbolt')).toBe('Thunderbolt');
  });
});

describe('routes', () => {
  it('parses hash routes and round-trips encoded ids', () => {
    expect(parseRoute('')).toEqual({ name: 'me' });
    expect(parseRoute('#/me')).toEqual({ name: 'me' });
    expect(parseRoute('#/battle')).toEqual({ name: 'battle' });
    expect(parseRoute('#/boards')).toEqual({ name: 'boards' });
    expect(parseRoute(href('board', 'b/1'))).toEqual({ name: 'board', boardId: 'b/1' });
    expect(parseRoute('#/join/ABCD-EFGH-JKMN')).toEqual({ name: 'join', code: 'ABCD-EFGH-JKMN' });
    expect(parseRoute('#/board')).toEqual({ name: 'boards' });
    expect(parseRoute('#/nope')).toEqual({ name: 'me' });
  });
});
