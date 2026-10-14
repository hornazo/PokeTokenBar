import { For, Show } from 'solid-js';
import type { TrainerResponse } from '../api/types';
import { Fingerprint, Sprite } from '../components';
import { battleTeamOf, leadPokemon, plural, showcaseOrder, titleCase } from '../lib/format';

/** The trainer's showcase: lead pokemon, record, battle team, stats and every pokemon they keep. */
export function PlayerCard(props: { data: TrainerResponse }) {
  const lead = () => leadPokemon(props.data);
  const team = () => battleTeamOf(props.data);
  const showcase = () => showcaseOrder(props.data.pokemon);
  const stats = () => props.data.gameStats;
  const record = () => props.data.battleRecord;

  return (
    <div class="card">
      <div class="hero">
        <div class="sprite"><Sprite speciesNum={lead()?.speciesNum} shiny={lead()?.shiny} alt={lead()?.species} /></div>
        <h1 class="trainer-name">{props.data.trainer.name} <Fingerprint value={props.data.trainer.fingerprint} /></h1>
        <h2>
          {lead()?.species ?? 'Egg'}
          <Show when={lead()?.shiny}> <span class="shiny" title="Shiny">✦</span></Show>
        </h2>
        <Show when={lead()}>
          {(mon) => (
            <div class="tags">
              <span class="pill solid">Lv {mon().level}</span>
              <Show when={mon().nature}><span class="pill accent">{mon().nature}</span></Show>
              <Show when={mon().ability}><span class="pill">{titleCase(mon().ability!)}</span></Show>
              <Show when={mon().shiny}><span class="pill legend">Shiny</span></Show>
            </div>
          )}
        </Show>
        <div class="meta" aria-label="Battle record">
          {record().wins} W · {record().losses} L · {record().draws} D
          <Show when={props.data.aiBand}>{(band) => <> · AI use <span class="pill accent">{band()}</span></>}</Show>
        </div>
      </div>

      <div class="section-head"><h3>Battle team</h3><span class="note">{plural(team().length, 'pokémon', 'pokémon')}</span></div>
      <Show when={team().length} fallback={<div class="empty">No battle team picked yet.</div>}>
        <ol class="party">
          <For each={team()}>
            {(mon, i) => (
              <li class="party-slot">
                <span class="mini"><Sprite speciesNum={mon.speciesNum} shiny={mon.shiny} alt={mon.species} /></span>
                <div class="who">
                  <div class="n">
                    {mon.species}<Show when={mon.shiny}> <span class="shiny">✦</span></Show>
                    <Show when={i() === 0}> <span class="pill solid">Lead</span></Show>
                  </div>
                  <div class="moves">{mon.moves.map(titleCase).join(' · ')}</div>
                </div>
                <span class="metric">{mon.level}<small>level</small></span>
              </li>
            )}
          </For>
        </ol>
      </Show>

      <div class="stats">
        <div class="stat"><b>{stats().speciesCount}</b><span>Species</span></div>
        <div class="stat"><b>{stats().pokemonCount}</b><span>Pokémon</span></div>
        <div class="stat"><b>{stats().shinyCount}</b><span>Shiny</span></div>
        <div class="stat"><b>{stats().highestLevel}</b><span>Top level</span></div>
        <div class="stat"><b>{stats().graduatedCount}</b><span>Graduated</span></div>
        <div class="stat"><b>{stats().totalLevels}</b><span>Total levels</span></div>
      </div>

      <div class="section-head"><h3>Pokémon</h3><span class="note">{plural(showcase().length, 'pokémon', 'pokémon')}</span></div>
      <Show when={showcase().length} fallback={<div class="empty">Nothing here yet. Catch some in the app.</div>}>
        <ul class="dex">
          <For each={showcase()}>
            {(p) => (
              <li class="dex-cell" title={[p.nature, p.ability && titleCase(p.ability), p.moves.map(titleCase).join(', ')].filter(Boolean).join(' · ')}>
                <Show when={p.shiny}><i class="dot" /></Show>
                <Sprite speciesNum={p.speciesNum} shiny={p.shiny} alt="" />
                <span>{p.species}</span>
                <span class="lv">Lv {p.level}{p.status === 'graduated' ? ' · graduated' : ''}</span>
              </li>
            )}
          </For>
        </ul>
      </Show>
    </div>
  );
}
