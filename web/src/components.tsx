import { createSignal, For, Show, type JSX } from 'solid-js';
import { ApiError, DEFAULT_PORT, parsePort } from './api/client';
import { spriteUrl } from './lib/format';
import { app } from './state';

/** PokeTokenBar's egg-and-pulse mark, from assets/icon.svg. */
export function Logo(props: { class?: string }) {
  return (
    <svg class={props.class ?? 'logo'} viewBox="56 52 144 176" aria-hidden="true">
      <g fill="none" stroke="currentColor" stroke-width="12" stroke-linecap="round" stroke-linejoin="round">
        <path d="M128 58 C170 58 194 116 194 156 C194 198 166 222 128 222 C90 222 62 198 62 156 C62 116 86 58 128 58 Z" />
        <path d="M86 150 L106 134 L122 152 L138 132 L154 152 L172 138" />
      </g>
    </svg>
  );
}

/** A pokemon sprite, or an egg when there is no pokemon or the image can't load. */
export function Sprite(props: { speciesNum?: number; shiny?: boolean; alt?: string }) {
  const [broken, setBroken] = createSignal(false);
  return (
    <Show when={props.speciesNum && !broken()} fallback={<span class="egg" role="img" aria-label="Egg">🥚</span>}>
      <img src={spriteUrl(props.speciesNum!, props.shiny)} alt={props.alt ?? ''} loading="lazy" onError={() => setBroken(true)} />
    </Show>
  );
}

export function errorText(err: unknown): string {
  if (err instanceof ApiError) return err.message;
  return err instanceof Error ? err.message : String(err);
}

/** Port field shared by the connection states. */
function PortForm() {
  const [text, setText] = createSignal(String(app.port()));
  const valid = () => parsePort(text()) !== undefined;
  const save = (e: Event) => {
    e.preventDefault();
    const port = parsePort(text());
    if (port) app.setPort(port);
  };
  return (
    <form class="port-form" onSubmit={save}>
      <label class="field">Port
        <input type="text" inputmode="numeric" autocomplete="off" value={text()} aria-invalid={!valid()} onInput={(e) => setText(e.currentTarget.value)} />
      </label>
      <button class="btn primary" type="submit" disabled={!valid()}>Try again</button>
      <Show when={app.port() !== DEFAULT_PORT}>
        <button class="btn ghost" type="button" onClick={() => { setText(String(DEFAULT_PORT)); app.setPort(DEFAULT_PORT); }}>Use {DEFAULT_PORT}</button>
      </Show>
    </form>
  );
}

/** Shown in place of a page that needs the app, while the app isn't answering or hasn't approved this page. */
export function ConnectionGate() {
  const kind = () => app.status().kind;
  return (
    <div class="center gate" role="status" aria-live="polite">
      <Show when={kind() === 'unpaired'}>
        <h2>Waiting for approval</h2>
        <p>Approve this page in the PokeTokenBar prompt on your Mac.</p>
        <p class="note">This page asks again every few seconds. It reads your data from the app on port {app.port()} and nowhere else.</p>
      </Show>
      <Show when={kind() === 'unreachable' || kind() === 'error'}>
        <h2>Can’t reach PokeTokenBar</h2>
        <p>Can’t reach PokeTokenBar on port {app.port()}. Turn on Settings → Trainer page in the app.</p>
        <Show when={app.status().kind === 'error' && app.status().message}><p class="msg err">{app.status().message}</p></Show>
        <PortForm />
        <ul class="note tips">
          <li>Safari may block a secure page from reaching 127.0.0.1. Chrome or Firefox work.</li>
          <li>Chrome may ask to allow access to devices on your local network. Allow it.</li>
        </ul>
      </Show>
      <Show when={kind() === 'connecting'}>
        <h2>Connecting…</h2>
        <p>Looking for PokeTokenBar on port {app.port()}.</p>
      </Show>
    </div>
  );
}

/** Wraps a page that needs app data: the gate until the first snapshot arrives, then the page. */
export function Needs<T>(props: { value: T | undefined; children: (value: NonNullable<T>) => JSX.Element }) {
  return (
    <Show when={props.value as NonNullable<T> | undefined} fallback={<ConnectionGate />}>
      {(value) => props.children(value())}
    </Show>
  );
}

export function Fingerprint(props: { value: string }) {
  return <span class="fp" title="Trainer fingerprint">{props.value}</span>;
}

/** A row of dots, one per team member: fainted ones greyed out, the active one ringed. */
export function TeamDots(props: { states: { fainted: boolean; active: boolean }[] }) {
  return (
    <span class="dots" role="img" aria-label={`${props.states.filter((s) => !s.fainted).length} of ${props.states.length} pokémon left`}>
      <For each={props.states}>{(s) => <i classList={{ fainted: s.fainted, active: s.active }} />}</For>
    </span>
  );
}

export interface StripMon { speciesNum: number; shiny: boolean; name: string; level: number; fainted?: boolean }

/** A team as a row of small sprites, lead first; fainted ones greyed out. */
export function TeamStrip(props: { team: StripMon[]; label: string }) {
  return (
    <ul class="team-strip" aria-label={props.label}>
      <For each={props.team}>
        {(m) => (
          <li classList={{ fainted: Boolean(m.fainted) }} title={`${m.name} · Lv ${m.level}${m.shiny ? ' · shiny' : ''}${m.fainted ? ' · fainted' : ''}`}>
            <Sprite speciesNum={m.speciesNum} shiny={m.shiny} alt={`${m.name}, level ${m.level}${m.fainted ? ', fainted' : ''}`} />
          </li>
        )}
      </For>
    </ul>
  );
}
