import { For, Show } from 'solid-js';
import type { TrainerEntry, TrainersResponse } from '../api/types';
import { Fingerprint, TeamStrip } from '../components';
import { relativeTime } from '../lib/format';
import { href } from '../lib/router';
import { filterTrainers, type TrainerFilter } from '../live';

const FILTERS: { value: TrainerFilter; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: 'league', label: 'League' },
];

function presenceText(t: TrainerEntry): string {
  if (t.presence === 'available') return 'Available';
  if (t.presence === 'idle') return 'Idle';
  return t.lastSeenAt ? `Seen ${relativeTime(t.lastSeenAt)}` : 'Not seen nearby';
}

/** Everyone this Mac has met, or only your league, with whether they can battle now. */
export function Trainers(props: { data: TrainersResponse; filter: TrainerFilter }) {
  const shown = () => filterTrainers(props.data.trainers, props.filter);
  const available = () => shown().filter((t) => t.presence === 'available').length;
  return (
    <div class="panel wide">
      <div class="page-head">
        <div><div class="eyebrow">Trainers</div><h1>Trainers</h1></div>
        <Show when={shown().length}><span class="note">{available()} available now</span></Show>
      </div>
      <nav class="filters" aria-label="Show">
        <For each={FILTERS}>
          {(f) => (
            <a href={f.value === 'all' ? href('trainers') : href('trainers', f.value)}
               aria-current={props.filter === f.value ? 'page' : undefined}>
              {f.label} <span class="count">{filterTrainers(props.data.trainers, f.value).length}</span>
            </a>
          )}
        </For>
      </nav>
      <Show when={shown().length} fallback={
        <div class="empty">
          {props.filter === 'league'
            ? 'Nobody from your league yet. Members show up once your league syncs with them nearby.'
            : 'Nobody yet. Trainers show up once you see them nearby or battle them, with Visible to trainers nearby on in the app.'}
        </div>
      }>
        <div class="battle-cards">
          <For each={shown()}>{(t) => <TrainerCard trainer={t} />}</For>
        </div>
      </Show>
      <p class="note">Available means they’re visible for battles and used their Mac in the last 5 minutes. Challenges are sent from the app.</p>
    </div>
  );
}

function TrainerCard(props: { trainer: TrainerEntry }) {
  const t = () => props.trainer;
  const battles = () => t().vsYou.wins + t().vsYou.losses + t().vsYou.draws;
  return (
    <section class="battle-card trainer-card" classList={{ live: t().presence === 'available' }} aria-label={t().name}>
      <div class="bc-top">
        <span class={`presence ${t().presence}`}><i aria-hidden="true" />{presenceText(t())}</span>
        <Show when={t().league}>
          {(league) => <a class="pill accent" href={href('board', league().id)}>#{league().rank} · {league().points} pts</a>}
        </Show>
      </div>
      <div class="bc-who">
        <span class="n">{t().name || 'Unnamed trainer'}</span>
        <Fingerprint value={t().fingerprint} />
      </div>
      <Show when={t().team.length} fallback={<div class="note">Team not known yet</div>}>
        <TeamStrip team={t().team.map((m) => ({ ...m, name: m.species }))} label={`${t().name}’s battle team`} />
      </Show>
      <Show when={battles()}>
        <div class="note">
          You {t().vsYou.wins}–{t().vsYou.losses}{t().vsYou.draws ? ` (${t().vsYou.draws} drawn)` : ''}
          <Show when={t().lastBattleAt}>{(at) => <> · last battle {relativeTime(at())}</>}</Show>
        </div>
      </Show>
    </section>
  );
}
