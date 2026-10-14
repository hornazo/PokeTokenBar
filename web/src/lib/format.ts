import type { ShowcasePokemon, StatusCondition, TrainerResponse } from '../api/types';

const SPRITE_BASE = (import.meta.env.VITE_PTB_SPRITE_BASE as string | undefined)
  ?? 'https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon';

/** PokéAPI front sprite for a national dex number (96×96 PNG). */
export function spriteUrl(speciesNum: number, shiny = false): string {
  return `${SPRITE_BASE}/${shiny ? 'shiny/' : ''}${speciesNum}.png`;
}

export function fmtDate(ms: number): string {
  return new Date(ms).toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
}

/** Just now → 5 min ago → 3 h ago → 2 d ago → 4 Oct. */
export function relativeTime(ms: number, now = Date.now()): string {
  const mins = Math.max(0, now - ms) / 60000;
  if (mins < 1) return 'just now';
  if (mins < 60) return `${Math.floor(mins)} min ago`;
  const hours = mins / 60;
  if (hours < 24) return `${Math.floor(hours)} h ago`;
  const days = hours / 24;
  if (days < 30) return `${Math.floor(days)} d ago`;
  return fmtDate(ms);
}

/** `thunder-punch` → `Thunder Punch`; Showdown names pass through unchanged. */
export function titleCase(name: string): string {
  return name.split('-').map((w) => (w ? w[0]!.toUpperCase() + w.slice(1) : w)).join(' ');
}

export function plural(n: number, one: string, many = `${one}s`): string {
  return `${n} ${n === 1 ? one : many}`;
}

/** Seconds left until a unix-ms deadline, never below 0. */
export function secondsLeft(deadline: number, now = Date.now()): number {
  return Math.max(0, Math.ceil((deadline - now) / 1000));
}

export type HpTone = 'high' | 'mid' | 'low';

/** The games' bar colors: green above half, yellow above a fifth, red below. */
export function hpTone(hp: number, maxHp: number): HpTone {
  const ratio = maxHp > 0 ? hp / maxHp : 0;
  if (ratio > 0.5) return 'high';
  if (ratio > 0.2) return 'mid';
  return 'low';
}

export function hpPercent(hp: number, maxHp: number): number {
  return maxHp > 0 ? Math.min(100, Math.max(0, Math.round((hp / maxHp) * 100))) : 0;
}

/** Badge text and style for a status. Badly poisoned reads PSN like the games, in a darker color. */
export function statusBadge(status: StatusCondition): { label: string; tone: StatusCondition } {
  switch (status) {
    case 'psn': return { label: 'PSN', tone: 'psn' };
    case 'tox': return { label: 'PSN', tone: 'tox' };
    case 'brn': return { label: 'BRN', tone: 'brn' };
    case 'par': return { label: 'PAR', tone: 'par' };
    case 'slp': return { label: 'SLP', tone: 'slp' };
    case 'frz': return { label: 'FRZ', tone: 'frz' };
  }
}

/** The battle team as pokemon, in slot order; ids that aren't in the showcase are skipped. */
export function battleTeamOf(t: TrainerResponse): ShowcasePokemon[] {
  return t.battleTeam.flatMap((id) => t.pokemon.find((p) => p.instanceId === id) ?? []);
}

/** The pokemon to put on the card: the team lead, else the highest-level active one. */
export function leadPokemon(t: TrainerResponse): ShowcasePokemon | undefined {
  const lead = battleTeamOf(t)[0];
  if (lead) return lead;
  const pool = t.pokemon.filter((p) => p.status === 'active');
  return (pool.length ? pool : t.pokemon).reduce<ShowcasePokemon | undefined>((best, p) => (!best || p.level > best.level ? p : best), undefined);
}

/** The showcase order: highest level first, then dex number. Released pokemon are left out. */
export function showcaseOrder(pokemon: ShowcasePokemon[]): ShowcasePokemon[] {
  return pokemon.filter((p) => p.status !== 'released').sort((a, b) => b.level - a.level || a.speciesNum - b.speciesNum);
}
