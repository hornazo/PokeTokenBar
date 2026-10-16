import { createEffect, createSignal, For, onCleanup, Show } from 'solid-js';
import type { BattleSnapshot, HistoryEntry, SpectatorPokemon, SpectatorSide } from '../api/types';
import { Fingerprint, Sprite, TeamDots, TeamStrip } from '../components';
import { fmtDate, hpPercent, hpTone, plural, relativeTime, secondsLeft, statusBadge } from '../lib/format';
import { href } from '../lib/router';
import { historyRecord } from '../live';

const OUTCOME = {
  won: 'You won',
  lost: 'You lost',
  draw: 'It’s a draw',
  aborted: 'Battle called off',
} as const;

const SHORT_OUTCOME = { won: 'Won', lost: 'Lost', draw: 'Draw', aborted: 'Called off' } as const;

function kindLabel(b: BattleSnapshot): string {
  if (b.board) return b.board.name;
  return b.kind === 'practice' ? 'Practice' : 'Friendly';
}

/** The battle being played now (if any) and past ones, as cards; each opens on its own page. */
export function Battles(props: { live: BattleSnapshot | undefined; history: HistoryEntry[] }) {
  const record = () => historyRecord(props.history);
  return (
    <div class="panel wide">
      <div class="page-head">
        <div><div class="eyebrow">Battles</div><h1>Battles</h1></div>
        <Show when={props.history.length}>
          <span class="note">{record().wins} won · {record().draws} drawn · {record().losses} lost</span>
        </Show>
      </div>
      <Show when={props.live || props.history.length} fallback={
        <div class="empty">No battles yet. Start one from the Battle tab in PokeTokenBar; finished battles stay here.</div>
      }>
        <div class="battle-cards">
          <Show when={props.live}>{(b) => <BattleCard battle={b()} link={href('battle', 'live')} live />}</Show>
          <For each={props.history}>
            {(e) => <BattleCard battle={e.battle} link={href('battle', e.id)} finishedAt={e.finishedAt} fingerprint={e.opponentFingerprint} />}
          </For>
        </div>
      </Show>
    </div>
  );
}

function BattleCard(props: { battle: BattleSnapshot; link: string; live?: boolean; finishedAt?: number; fingerprint?: string | null }) {
  const b = () => props.battle;
  const strip = (side: SpectatorSide) => side.team.map((p) => ({ ...p, speciesNum: p.appearance }));
  return (
    <a class="battle-card" classList={{ live: props.live }} href={props.link}>
      <div class="bc-top">
        <span class="eyebrow">{kindLabel(b())}</span>
        <Show when={props.live} fallback={
          <Show when={b().outcome}>{(o) => <span class={`pill result ${o()}`}>{SHORT_OUTCOME[o()]}</span>}</Show>
        }>
          <span class="pill solid"><span class="live-dot" aria-hidden="true" /> Live · turn {b().turn}</span>
        </Show>
      </div>
      <div class="bc-who">
        <span class="n">vs {b().sides[1].trainer}</span>
        <Show when={props.fingerprint}>{(fp) => <Fingerprint value={fp()} />}</Show>
      </div>
      <div class="bc-teams">
        <TeamStrip team={strip(b().sides[0])} label={`${b().sides[0].trainer}’s team`} />
        <span class="vs" aria-hidden="true">VS</span>
        <TeamStrip team={strip(b().sides[1])} label={`${b().sides[1].trainer}’s team`} />
      </div>
      <Show when={props.finishedAt}>
        {(at) => <div class="note" title={fmtDate(at())}>{relativeTime(at())} · {plural(b().turn, 'turn')}</div>}
      </Show>
    </a>
  );
}

/** One battle on its own page: the live one (`live`) or a saved one. */
export function BattleView(props: { battleId: string; live: BattleSnapshot | null | undefined; history: HistoryEntry[] }) {
  const entry = () => props.history.find((e) => e.id === props.battleId);
  return (
    <Show when={props.battleId === 'live' ? props.live : entry()?.battle} fallback={
      <div class="center">
        <h2>{props.battleId === 'live' ? 'No battle right now' : 'Battle not found'}</h2>
        <p>
          {props.battleId === 'live' ? 'Start one from the Battle tab in PokeTokenBar. ' : 'This Mac keeps the last 100 battles. '}
          <a href={href('battle')}>All battles</a>
        </p>
      </div>
    }>
      {(battle) => <Field battle={battle()} entry={props.battleId === 'live' ? undefined : entry()} />}
    </Show>
  );
}

function Field(props: { battle: BattleSnapshot; entry?: HistoryEntry }) {
  const b = () => props.battle;
  let logEl: HTMLOListElement | undefined;

  // Newest line at the bottom, kept in view as lines arrive.
  createEffect(() => {
    void b().log.length;
    if (logEl) logEl.scrollTop = logEl.scrollHeight;
  });

  return (
    <div class="battle">
      <a class="back" href={href('battle')}>← Battles</a>
      <div class="page-head">
        <div>
          <div class="eyebrow">
            <Show when={b().board} fallback={kindLabel(b())}>
              {(board) => <a href={href('board', board().id)}>{board().name}</a>}
            </Show>
            {' · '}Turn {b().turn}
            <Show when={props.entry}>{(e) => <>{' · '}{fmtDate(e().finishedAt)}</>}</Show>
          </div>
          <h1>
            {b().sides[0].trainer} vs {b().sides[1].trainer}
            <Show when={props.entry?.opponentFingerprint}>{(fp) => <> <Fingerprint value={fp()} /></>}</Show>
          </h1>
        </div>
        <Show when={b().outcome == null && b().turnDeadline}>{(deadline) => <Timer deadline={deadline()} />}</Show>
      </div>

      <Show when={b().outcome}>
        {(outcome) => <div class={`outcome ${outcome()}`} role="status">{OUTCOME[outcome()]}</div>}
      </Show>

      <div class="field-sides">
        <Side side={b().sides[0]} />
        <span class="vs" aria-hidden="true">VS</span>
        <Side side={b().sides[1]} />
      </div>

      <p class="message" aria-live="polite">{b().message}</p>

      <div class="battle-lower" classList={{ single: Boolean(props.entry) }}>
        <section aria-label="Battle log">
          <h3>Log</h3>
          <ol class="battle-log" ref={logEl} tabindex="0">
            <For each={b().log}>{(line) => <li>{line}</li>}</For>
          </ol>
        </section>
        <Show when={!props.entry}>
          <section aria-label="Your moves">
            <h3>Your moves</h3>
            <ul class="moves-list">
              <For each={b().moves}>
                {(m) => (
                  <li classList={{ unusable: !m.usable }}>
                    <span class="mv">{m.name}</span>
                    <span class="type">{m.type}</span>
                    <span class="pp">{m.pp}/{m.maxPp}</span>
                  </li>
                )}
              </For>
            </ul>
            <p class="note">Moves are picked in the app.</p>
          </section>
        </Show>
      </div>
    </div>
  );
}

function Timer(props: { deadline: number }) {
  const [now, setNow] = createSignal(Date.now());
  const id = setInterval(() => setNow(Date.now()), 250);
  onCleanup(() => clearInterval(id));
  const left = () => secondsLeft(props.deadline, now());
  return <div class="timer" classList={{ urgent: left() <= 10 }} role="timer" aria-label="Turn timer">{left()}s</div>;
}

function Side(props: { side: SpectatorSide }) {
  const active = (): SpectatorPokemon | undefined => props.side.team[props.side.active];
  return (
    <section class="side-card" classList={{ you: props.side.isYou }} aria-label={props.side.trainer}>
      <div class="side-top">
        <span class="trainer">{props.side.trainer}{props.side.isYou ? ' (you)' : ''}</span>
        <TeamDots states={props.side.team.map((p, i) => ({ fainted: p.fainted, active: i === props.side.active }))} />
      </div>
      <Show when={active()}>
        {(mon) => (
          <div class="active-mon" classList={{ fainted: mon().fainted }}>
            <div class="sprite-box"><Sprite speciesNum={mon().appearance} shiny={mon().shiny} alt={mon().name} /></div>
            <div class="info">
              <div class="name">
                {mon().name}{mon().unownForm ? ` ${mon().unownForm}` : ''} <span class="lvl">Lv {mon().level}</span>
                <Show when={mon().status}>
                  {(status) => <span class={`status ${statusBadge(status()).tone}`}>{statusBadge(status()).label}</span>}
                </Show>
              </div>
              <div
                class={`hp ${hpTone(mon().hp, mon().maxHp)}`}
                role="progressbar" aria-label="HP" aria-valuemin="0" aria-valuemax={mon().maxHp} aria-valuenow={mon().hp}
              >
                <i style={{ width: `${hpPercent(mon().hp, mon().maxHp)}%` }} />
              </div>
              <div class="hp-text">{mon().hp}/{mon().maxHp} HP</div>
            </div>
          </div>
        )}
      </Show>
    </section>
  );
}
