import { createEffect, createSignal, For, onCleanup, Show } from 'solid-js';
import type { BattleSnapshot, SpectatorPokemon, SpectatorSide } from '../api/types';
import { Sprite, TeamDots } from '../components';
import { hpPercent, hpTone, secondsLeft, statusBadge } from '../lib/format';
import { href } from '../lib/router';

const OUTCOME = {
  won: 'You won',
  lost: 'You lost',
  draw: 'It’s a draw',
  aborted: 'Battle called off',
} as const;

function kindLabel(b: BattleSnapshot): string {
  if (b.board) return b.board.name;
  return b.kind === 'practice' ? 'Practice' : 'Friendly';
}

/** Live spectating of the battle running in the app. Read-only. */
export function Battle(props: { battle: BattleSnapshot | null }) {
  return (
    <Show when={props.battle} fallback={
      <div class="center">
        <h2>No battle right now</h2>
        <p>Start one from the Battle tab in PokeTokenBar.</p>
      </div>
    }>
      {(battle) => <Live battle={battle()} />}
    </Show>
  );
}

function Live(props: { battle: BattleSnapshot }) {
  const b = () => props.battle;
  let logEl: HTMLOListElement | undefined;

  // Newest line at the bottom, kept in view as lines arrive.
  createEffect(() => {
    void b().log.length;
    if (logEl) logEl.scrollTop = logEl.scrollHeight;
  });

  return (
    <div class="battle">
      <div class="page-head">
        <div>
          <div class="eyebrow">
            <Show when={b().board} fallback={kindLabel(b())}>
              {(board) => <a href={href('board', board().id)}>{board().name}</a>}
            </Show>
            {' · '}Turn {b().turn}
          </div>
          <h1>{b().sides[0].trainer} vs {b().sides[1].trainer}</h1>
        </div>
        <Show when={b().outcome === null && b().turnDeadline}>{(deadline) => <Timer deadline={deadline()} />}</Show>
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

      <div class="battle-lower">
        <section aria-label="Battle log">
          <h3>Log</h3>
          <ol class="battle-log" ref={logEl} tabindex="0">
            <For each={b().log}>{(line) => <li>{line}</li>}</For>
          </ol>
        </section>
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
