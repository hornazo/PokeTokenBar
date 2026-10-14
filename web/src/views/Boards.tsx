import { createSignal, For, Show } from 'solid-js';
import type { Board, BoardMember, BoardsResponse } from '../api/types';
import { Fingerprint } from '../components';
import { plural, relativeTime } from '../lib/format';
import { href } from '../lib/router';

const you = (board: Board) => board.members.find((m) => m.isYou);

export function Boards(props: { data: BoardsResponse }) {
  return (
    <div class="panel wide">
      <div class="page-head"><div><div class="eyebrow">Leaderboards</div><h1>Boards</h1></div></div>
      <p class="note sync-note">
        {props.data.syncEnabled
          ? 'Sync is on: boards update when members meet nearby.'
          : 'Sync is off, so boards only show what this Mac already has. Turn it on in the app.'}
      </p>
      <Show when={props.data.boards.length} fallback={
        <div class="empty">
          No boards yet. Create or join one in the app, under Battle → Boards. Boards sync with trainers nearby.
        </div>
      }>
        <div class="team-list">
          <For each={props.data.boards}>
            {(board) => (
              <a class="team-row" href={href('board', board.id)}>
                <span class="name">{board.name}</span>
                <Show when={you(board)}>{(me) => <span class="badge">Rank {me().rank}</span>}</Show>
                <span class="count">{plural(board.members.length, 'member')}</span>
              </a>
            )}
          </For>
        </div>
      </Show>
    </div>
  );
}

export function BoardView(props: { boardId: string; data: BoardsResponse }) {
  const board = () => props.data.boards.find((b) => b.id === props.boardId);
  return (
    <Show when={board()} fallback={
      <div class="center">
        <h2>Board not found</h2>
        <p>This Mac doesn’t have a board with that id. <a href={href('boards')}>Back to boards</a></p>
      </div>
    }>
      {(b) => (
        <div class="panel wide">
          <a class="back" href={href('boards')}>← Boards</a>
          <div class="page-head">
            <div><div class="eyebrow">{plural(b().members.length, 'member')}</div><h1>{b().name}</h1></div>
            <Show when={b().lastSyncAt}>{(at) => <span class="note">Last sync {relativeTime(at())}</span>}</Show>
          </div>
          <div class="table-wrap">
            <table class="ranking">
              <thead>
                <tr><th scope="col" class="r">#</th><th scope="col">Trainer</th><th scope="col" class="num">Points</th><th scope="col" class="num">W · D · L</th><th scope="col"><span class="sr-only">Breakdown</span></th></tr>
              </thead>
              <For each={b().members}>{(m) => <Row member={m} />}</For>
            </table>
          </div>
          <p class="note">Boards update when members meet nearby with sync on. A score only moves when both trainers sign the result.</p>
        </div>
      )}
    </Show>
  );
}

function Row(props: { member: BoardMember }) {
  const [open, setOpen] = createSignal(false);
  const m = () => props.member;
  const detailId = () => `breakdown-${m().publicKey.slice(0, 12)}`;
  return (
    <tbody classList={{ me: m().isYou }}>
      <tr aria-current={m().isYou ? 'true' : undefined}>
        <td class="r rank">{m().rank}</td>
        <td>
          <div class="who">
            <div class="n">{m().displayName} <Fingerprint value={m().fingerprint} /><Show when={m().isYou}> <span class="pill accent">You</span></Show></div>
            <div class="p">updated {relativeTime(m().updatedAt)}</div>
          </div>
        </td>
        <td class="num"><b>{m().score.total}</b></td>
        <td class="num">{m().counted.wins} · {m().counted.draws} · {m().counted.losses}</td>
        <td class="toggle">
          <button type="button" class="link" aria-expanded={open()} aria-controls={detailId()} onClick={() => setOpen(!open())}>
            {open() ? 'Hide' : 'Breakdown'}
          </button>
        </td>
      </tr>
      <Show when={open()}>
        <tr class="detail" id={detailId()}>
          <td colspan="5">
            <dl class="breakdown">
              <div><dt>Battle</dt><dd>{m().score.battle}</dd></div>
              <div><dt>Collection</dt><dd>{m().score.collection}</dd></div>
              <div><dt>Levels</dt><dd>{m().score.levels}</dd></div>
              <div><dt>AI</dt><dd>{m().score.ai}</dd></div>
            </dl>
            <p class="note">
              {m().stats.collection.species} species, {m().stats.collection.shinies} shiny, top level {m().stats.levels.top}
              <Show when={m().stats.aiBand}>{(band) => <>, AI use {band()}</>}</Show>
            </p>
          </td>
        </tr>
      </Show>
    </tbody>
  );
}
