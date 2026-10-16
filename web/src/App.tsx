import { Match, Show, Switch } from 'solid-js';
import { Logo, Needs } from './components';
import { href, route, type Route } from './lib/router';
import { liveBattle } from './live';
import { app } from './state';
import { Battles, BattleView } from './views/Battle';
import { BoardView, Boards } from './views/Boards';
import { Join } from './views/Join';
import { Trainers } from './views/Trainers';
import { PlayerCard } from './views/PlayerCard';

const TABS = [
  { name: 'me', label: 'Me', match: ['me'] },
  { name: 'battle', label: 'Battles', match: ['battle', 'battleView'] },
  { name: 'trainers', label: 'Trainers', match: ['trainers'] },
  { name: 'boards', label: 'Leagues', match: ['boards', 'board'] },
] as const;

/** The current route when it has this name, typed to that route's params. */
function routeOf<N extends Route['name']>(name: N): Extract<Route, { name: N }> | undefined {
  const r = route();
  return r.name === name ? r as Extract<Route, { name: N }> : undefined;
}

export function App() {
  const current = (names: readonly string[]) => names.includes(route().name) ? 'page' : undefined;
  // Pages keep showing the last data when the app goes away, so say so.
  const stale = () => ['unreachable', 'unpaired', 'error'].includes(app.status().kind) && Boolean(app.data().trainer);

  return (
    <>
      <header class="bar">
        <div class="bar-inner">
          <a class="home" href={href('me')}><Logo />PokeTokenBar</a>
          <nav class="tabs" aria-label="Sections">
            {TABS.map((t) => (
              <a href={href(t.name)} aria-current={current(t.match)}>
                {t.label}
                <Show when={t.name === 'battle' && app.battleLive()}>
                  <span class="live-dot" role="img" aria-label="Battle in progress" />
                </Show>
              </a>
            ))}
          </nav>
        </div>
      </header>

      <main>
        <Show when={stale()}>
          <div class="msg err banner" role="alert">
            {app.status().kind === 'unpaired'
              ? 'Approve this page in the PokeTokenBar prompt on your Mac.'
              : `Lost contact with PokeTokenBar on port ${app.port()}. Showing the last data; retrying.`}
          </div>
        </Show>
        <Switch>
          <Match when={routeOf('battle')}>
            <Needs value={app.data().trainer}>
              {() => <Battles live={liveBattle(app.data())} history={app.data().history?.battles ?? []} />}
            </Needs>
          </Match>
          <Match when={routeOf('battleView')}>
            {(r) => (
              <Needs value={app.data().trainer}>
                {() => <BattleView battleId={r().battleId} live={app.data().battle?.battle} history={app.data().history?.battles ?? []} />}
              </Needs>
            )}
          </Match>
          <Match when={routeOf('trainers')}>
            {(r) => <Needs value={app.data().trainers}>{(data) => <Trainers data={data} filter={r().filter} />}</Needs>}
          </Match>
          <Match when={routeOf('boards')}>
            <Needs value={app.data().boards}>{(data) => <Boards data={data} />}</Needs>
          </Match>
          <Match when={routeOf('board')}>
            {(r) => <Needs value={app.data().boards}>{(data) => <BoardView boardId={r().boardId} data={data} />}</Needs>}
          </Match>
          <Match when={routeOf('join')}>{(r) => <Join code={r().code} />}</Match>
          <Match when={routeOf('me')}>
            <Needs value={app.data().trainer}>{(data) => <PlayerCard data={data} />}</Needs>
          </Match>
        </Switch>
      </main>
    </>
  );
}
