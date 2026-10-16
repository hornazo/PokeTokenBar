import { createSignal, For, Show } from 'solid-js';
import type { Board, BoardMember, BoardsResponse } from '../api/types';
import { Fingerprint, TeamStrip } from '../components';
import { plural, relativeTime } from '../lib/format';
import { href } from '../lib/router';
import { splitLeagues } from '../live';

const you = (board: Board) => board.members.find((m) => m.isYou);

/** Your league, then every other league this Mac has seen nearby. With only your own, it opens directly. */
export function Boards(props: { data: BoardsResponse }) {
  const split = () => splitLeagues(props.data.boards);
  return (
    <Show when={split().mine.length === 1 && !split().watched.length ? split().mine[0] : undefined}
          fallback={<BoardList data={props.data} />}>
      {(only) => <BoardView boardId={only().id} data={props.data} />}
    </Show>
  );
}

function BoardList(props: { data: BoardsResponse }) {
  const split = () => splitLeagues(props.data.boards);
  return (
    <div class="panel wide">
      <div class="page-head"><div><div class="eyebrow">Leagues</div><h1>Leagues</h1></div></div>
      <p class="note sync-note">
        {props.data.syncEnabled
          ? 'Sync is on: leagues update when trainers meet nearby. Every league’s standings are public; joining one needs its code.'
          : 'Sync is off, so this only shows what this Mac already has. Turn it on in the app.'}
      </p>
      <h3 class="section-title">Your league</h3>
      <Show when={split().mine.length} fallback={
        <div class="empty">
          You’re not in a league yet. Create or join one in the app, under Battle → League. You can be in one league at a time.
        </div>
      }>
        <LeagueRows boards={split().mine} />
      </Show>
      <h3 class="section-title">Other leagues</h3>
      <Show when={split().watched.length} fallback={
        <div class="empty">None seen yet. Other leagues show up once this Mac syncs with trainers nearby.</div>
      }>
        <LeagueRows boards={split().watched} />
      </Show>
    </div>
  );
}

function LeagueRows(props: { boards: Board[] }) {
  return (
    <div class="team-list">
      <For each={props.boards}>
        {(board) => (
          <a class="team-row" href={href('board', board.id)}>
            <span class="name">{board.name}</span>
            <Show when={you(board)}>{(me) => <span class="badge">Rank {me().rank}</span>}</Show>
            <Show when={!board.member && board.members[0]}>{(top) => <span class="count">Leader: {top().displayName}</span>}</Show>
            <span class="count">{plural(board.members.length, 'member')}</span>
          </a>
        )}
      </For>
    </div>
  );
}

export function BoardView(props: { boardId: string; data: BoardsResponse }) {
  const board = () => props.data.boards.find((b) => b.id === props.boardId);
  return (
    <Show when={board()} fallback={
      <div class="center">
        <h2>League not found</h2>
        <p>This Mac isn’t in a league with that id. <a href={href('boards')}>Your league</a></p>
      </div>
    }>
      {(b) => (
        <div class="panel wide">
          <Show when={props.data.boards.length > 1}><a class="back" href={href('boards')}>← Leagues</a></Show>
          <div class="page-head">
            <div><div class="eyebrow">{b().member ? 'Your league' : 'Watching'} · {plural(b().members.length, 'member')}</div><h1>{b().name}</h1></div>
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
          <p class="note">
            {b().member ? '' : 'You’re watching this league; joining it needs its code from a member. '}
            {props.data.syncEnabled ? 'The league updates when trainers meet nearby. ' : 'Sync is off in the app, so this only shows what this Mac already has. '}
            A battle score only moves when both trainers sign the result.
          </p>
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
            <Show when={m().stats.team?.length}>
              <TeamStrip team={(m().stats.team ?? []).map((t) => ({ ...t, name: t.species }))} label={`${m().displayName}’s battle team`} />
            </Show>
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
