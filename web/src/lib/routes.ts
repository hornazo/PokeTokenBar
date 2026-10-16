// Pure route parsing, kept apart from the router signal so it can be tested without a browser.

export type Route =
  | { name: 'me' }
  | { name: 'battle' }
  | { name: 'battleView'; battleId: string } // 'live' is the battle being played now
  | { name: 'trainers'; filter: 'all' | 'league' }
  | { name: 'boards' }
  | { name: 'board'; boardId: string }
  | { name: 'join'; code: string };

/** Hash routes, so the build runs on any static host without rewrites. Unknown paths fall back to `me`. */
export function parseRoute(hash: string): Route {
  const [head, a] = hash.replace(/^#\/?/, '').split('/').filter(Boolean).map(decodeURIComponent);
  switch (head) {
    case 'battle': return a ? { name: 'battleView', battleId: a } : { name: 'battle' };
    case 'trainers': return { name: 'trainers', filter: a === 'league' ? 'league' : 'all' };
    case 'boards': return { name: 'boards' };
    case 'board': return a ? { name: 'board', boardId: a } : { name: 'boards' };
    case 'join': return a ? { name: 'join', code: a } : { name: 'boards' };
    default: return { name: 'me' };
  }
}

/** Builds a hash link from path segments, encoding each one. */
export function href(...segments: (string | undefined)[]): string {
  return '#/' + segments.filter((s): s is string => Boolean(s)).map(encodeURIComponent).join('/');
}
