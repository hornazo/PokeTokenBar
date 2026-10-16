// Stand-in for the PokeTokenBar app's local API, for developing the page without the app.
//   node dev/mock-app.mjs [port] [--unpaired]
// Serves /v1/trainer, /v1/battle, /v1/boards, /v1/history, /v1/trainers and /v1/events on 127.0.0.1 with fixture data. A battle
// advances every 1.5 s, ends, is added to the history, and starts again. CORS is open to any Origin: dev only.
import http from 'node:http';

const args = process.argv.slice(2);
const unpaired = args.includes('--unpaired');
const port = Number(args.find((a) => /^\d+$/.test(a)) ?? 47323);
const DAY = 86_400_000;
const now = () => Date.now();

// ---- fixtures ----------------------------------------------------------------------------------------

const mon = (instanceId, speciesNum, species, level, extra = {}) => ({
  instanceId, speciesNum, species, form: null, shiny: false, nature: 'Adamant', gender: 'male', level,
  ability: 'static', moves: ['thunderbolt', 'quick-attack', 'iron-tail', 'volt-tackle'], caughtAt: now() - 30 * DAY, status: 'active', ...extra,
});

const trainer = {
  trainer: { name: 'Carlos', publicKey: 'MCowBQYDK2VwAyEAmockmockmockmockmockmockmockmockmock', fingerprint: '7QK3' },
  pokemon: [
    mon('p1', 25, 'Pikachu', 42),
    mon('p2', 6, 'Charizard', 55, { nature: 'Timid', ability: 'blaze', moves: ['flamethrower', 'air-slash', 'dragon-pulse', 'roost'] }),
    mon('p3', 94, 'Gengar', 48, { nature: 'Modest', ability: 'cursed-body', gender: 'female', moves: ['shadow-ball', 'sludge-bomb', 'thunderbolt', 'hypnosis'] }),
    mon('p4', 130, 'Gyarados', 61, { shiny: true, nature: 'Jolly', ability: 'intimidate', moves: ['waterfall', 'crunch', 'ice-fang', 'dragon-dance'] }),
    mon('p5', 143, 'Snorlax', 37, { nature: 'Careful', ability: 'thick-fat', moves: ['body-slam', 'rest', 'crunch', 'earthquake'] }),
    mon('p6', 1, 'Bulbasaur', 16, { nature: 'Bold', ability: 'overgrow', moves: ['vine-whip', 'tackle', 'growl', 'leech-seed'] }),
    mon('p7', 150, 'Mewtwo', 100, { status: 'graduated', nature: 'Timid', ability: 'pressure', gender: null, moves: ['psystrike', 'aura-sphere', 'shadow-ball', 'recover'] }),
    mon('p8', 19, 'Rattata', 4, { status: 'released', ability: 'run-away', moves: ['tackle', 'tail-whip'] }),
  ],
  battleTeam: ['p1', 'p2', 'p3'],
  battleRecord: { wins: 14, losses: 6, draws: 1 },
  gameStats: { pokemonCount: 8, speciesCount: 8, shinyCount: 1, graduatedCount: 1, releasedCount: 1, highestLevel: 100, totalLevels: 363 },
  aiBand: 'heavy',
};

const TEAMS = [
  [[9, 'Blastoise', 50], [65, 'Alakazam', 52], [130, 'Gyarados', 58, true]],
  [[25, 'Pikachu', 42], [6, 'Charizard', 55], [94, 'Gengar', 48]],
  [[248, 'Tyranitar', 61], [445, 'Garchomp', 57]],
  [[143, 'Snorlax', 37], [131, 'Lapras', 40], [149, 'Dragonite', 55], [59, 'Arcanine', 44], [197, 'Umbreon', 39], [196, 'Espeon', 39]],
  [[133, 'Eevee', 12]],
  [],
];
const teamOf = (n) => TEAMS[n % TEAMS.length].map(([speciesNum, species, level, shiny = false]) => ({ speciesNum, species, form: null, shiny, level }));

const member = (n, name, fingerprint, rank, total, extra = {}) => ({
  publicKey: `MCowBQYDK2VwAyEA${fingerprint}mockmockmockmockmockmock${n}`, fingerprint, displayName: name, isYou: false,
  joinedAt: now() - 40 * DAY, updatedAt: now() - n * 7 * 3_600_000,
  stats: {
    collection: { dex: 40 - n * 6, species: 38 - n * 6, shinies: 3 - Math.min(n, 3), graduated: 4 - Math.min(n, 4) },
    levels: { teamTotal: 280 - n * 30, top: 90 - n * 8 }, aiBand: ['extreme', 'heavy', 'moderate', 'light', null][n % 5],
    battleRecord: { wins: 20 - n * 3, losses: n * 2, draws: 1 },
    ...(teamOf(n).length ? { team: teamOf(n) } : {}),
  },
  score: { total, battle: Math.round(total * 0.45), collection: Math.round(total * 0.3), levels: Math.round(total * 0.2), ai: total - Math.round(total * 0.45) - Math.round(total * 0.3) - Math.round(total * 0.2) },
  rank, counted: { wins: 9 - n, draws: 1, losses: n }, ...extra,
});

const boards = {
  syncEnabled: true,
  boards: [
    {
      id: 'board-madrid', name: 'Madrid office', you: 'MCowBQYDK2VwAyEA7QK3mockmockmockmockmockmock1', lastSyncAt: now() - 25 * 60_000, syncedPeers: 3, member: true,
      members: [
        member(0, 'Lucía', 'M4XA', 1, 1840),
        member(1, 'Carlos', '7QK3', 2, 1520, { isYou: true, publicKey: 'MCowBQYDK2VwAyEA7QK3mockmockmockmockmockmock1' }),
        member(2, 'Dani', 'Z9TE', 3, 1210),
        member(3, 'Marta', 'F2HV', 4, 880),
        member(4, 'Iván', 'C8RS', 4, 880),
        member(5, 'Noa', 'P5WD', 6, 90, { updatedAt: now() - 3 * DAY }),
      ],
    },
    {
      id: 'board-friends', name: 'Weekend friends', you: 'MCowBQYDK2VwAyEA7QK3mockmockmockmockmockmock1', lastSyncAt: now() - 2 * DAY, syncedPeers: 1,
      members: [
        member(0, 'Sam', 'K1JB', 1, 960),
        member(1, 'Carlos', '7QK3', 2, 720, { isYou: true, publicKey: 'MCowBQYDK2VwAyEA7QK3mockmockmockmockmockmock1' }),
        member(2, 'Robin', 'T6NG', 3, 410, { updatedAt: now() - 9 * DAY }),
        member(3, 'Ale', 'G3QM', 4, 130, { updatedAt: now() - 45 * DAY }),
      ],
    },
  ],
};

// ---- the scripted battle -----------------------------------------------------------------------------

const sp = (speciesNum, name, level, maxHp, extra = {}) => ({ speciesNum, appearance: speciesNum, name, level, shiny: false, unownForm: null, hp: maxHp, maxHp, status: null, fainted: false, ...extra });

function newBattle(seq) {
  return {
    id: `battle-${seq}`, kind: 'nearby', board: { id: 'board-madrid', name: 'Madrid office' },
    sides: [
      { trainer: 'Carlos', isYou: true, active: 0, team: [sp(25, 'Pikachu', 42, 110), sp(6, 'Charizard', 55, 160), sp(94, 'Gengar', 48, 130)] },
      { trainer: 'Lucía', isYou: false, active: 0, team: [sp(9, 'Blastoise', 50, 150), sp(65, 'Alakazam', 52, 120), sp(130, 'Gyarados', 58, 170, { shiny: true })] },
    ],
    moves: [
      { name: 'Thunderbolt', type: 'Electric', pp: 15, maxPp: 15, usable: true },
      { name: 'Quick Attack', type: 'Normal', pp: 30, maxPp: 30, usable: true },
      { name: 'Iron Tail', type: 'Steel', pp: 15, maxPp: 15, usable: true },
      { name: 'Volt Tackle', type: 'Electric', pp: 15, maxPp: 15, usable: true },
    ],
    message: 'Lucía wants to battle!', log: ['Lucía wants to battle!', 'Lucía sent out Blastoise!', 'Go! Pikachu!'], turn: 1,
    outcome: null, turnDeadline: now() + 45_000,
  };
}

// Each step edits the battle in place; `use` spends PP on one of your moves.
const hit = (b, side, dmg) => { const m = b.sides[side].team[b.sides[side].active]; m.hp = Math.max(0, m.hp - dmg); if (m.hp === 0) m.fainted = true; };
const use = (b, i) => { b.moves[i].pp = Math.max(0, b.moves[i].pp - 1); b.moves[i].usable = b.moves[i].pp > 0; };
const say = (b, ...lines) => { b.message = lines[lines.length - 1]; b.log.push(...lines); };

const steps = [
  (b) => { b.turn = 2; use(b, 0); hit(b, 1, 70); say(b, 'Pikachu used Thunderbolt!', 'It\'s super effective!'); },
  (b) => { hit(b, 0, 50); say(b, 'Blastoise used Hydro Pump!', 'Pikachu lost half its HP.'); },
  (b) => { b.turn = 3; use(b, 3); hit(b, 1, 60); b.sides[1].team[0].status = 'brn'; say(b, 'Pikachu used Volt Tackle!', 'Blastoise was burned!'); },
  (b) => { hit(b, 1, 20); hit(b, 0, 40); say(b, 'Blastoise used Skull Bash!', 'Blastoise is hurt by its burn!'); },
  (b) => { b.turn = 4; use(b, 0); hit(b, 0, 20); say(b, 'Pikachu fainted!', 'Go! Charizard!'); b.sides[0].active = 1; b.turnDeadline = now() + 45_000; },
  (b) => { b.turn = 5; hit(b, 1, 0); b.sides[1].team[0].hp = 0; b.sides[1].team[0].fainted = true; say(b, 'Charizard used Flamethrower!', 'Blastoise fainted!'); },
  (b) => { b.sides[1].active = 1; b.sides[0].team[1].status = 'par'; say(b, 'Lucía sent out Alakazam!', 'Alakazam used Thunder Wave!', 'Charizard is paralyzed!'); },
  (b) => { b.turn = 6; hit(b, 0, 90); b.sides[0].team[1].status = 'tox'; say(b, 'Alakazam used Psychic!', 'Charizard was badly poisoned!'); },
  (b) => { b.turn = 7; hit(b, 1, 120); say(b, 'Charizard used Air Slash!', 'Alakazam fainted!'); },
  (b) => { b.sides[1].active = 2; say(b, 'Lucía sent out Gyarados!'); },
  (b) => { b.turn = 8; hit(b, 1, 100); hit(b, 0, 30); say(b, 'Charizard used Dragon Pulse!', 'Gyarados used Waterfall!'); },
  (b) => { hit(b, 1, 100); say(b, 'Charizard used Dragon Pulse!', 'Gyarados fainted!'); },
  (b) => { b.outcome = 'won'; b.turnDeadline = null; say(b, 'Lucía has no more pokémon!', 'You won the battle!'); },
  () => {}, () => {}, () => {}, // pause on the result, then restart
];

let seq = 1;
let step = 0;
let battle = newBattle(seq);

// Finished battles, newest first, as the app keeps them: no moves, no deadline.
const past = (id, ago, outcome, opponent, fingerprint, board, team, turn) => {
  const b = newBattle(0);
  b.sides[1].trainer = opponent;
  b.sides[1].team = team.map(([n, name, level]) => sp(n, name, level, 120));
  const loser = outcome === 'won' ? 1 : outcome === 'lost' ? 0 : -1;
  if (loser >= 0) for (const m of b.sides[loser].team) { m.hp = 0; m.fainted = true; }
  b.sides[0].active = loser === 0 ? b.sides[0].team.length - 1 : 0;
  b.sides[1].active = loser === 1 ? b.sides[1].team.length - 1 : 0;
  b.board = board; b.kind = opponent === 'CPU' ? 'practice' : 'nearby';
  return { id, finishedAt: now() - ago, opponentFingerprint: fingerprint,
    battle: { ...b, id, moves: [], turnDeadline: null, turn, outcome, message: b.log.at(-1) } };
};
const madrid = { id: 'board-madrid', name: 'Madrid office' };
const history = { battles: [
  past('h5', 40 * 60_000, 'lost', 'Dani', 'Z9TE', madrid, [[248, 'Tyranitar', 61], [445, 'Garchomp', 57]], 14),
  past('h4', 3 * 3_600_000, 'won', 'Marta', 'F2HV', madrid, [[143, 'Snorlax', 37], [131, 'Lapras', 40], [149, 'Dragonite', 55]], 11),
  past('h3', DAY, 'draw', 'Sam', 'K1JB', null, [[133, 'Eevee', 12]], 6),
  past('h2', 2 * DAY, 'aborted', 'Iván', 'C8RS', madrid, [[59, 'Arcanine', 44]], 3),
  past('h1', 4 * DAY, 'won', 'CPU', null, null, [[19, 'Rattata', 20], [16, 'Pidgey', 18]], 5),
] };

function advance() {
  if (step >= steps.length) {
    history.battles.unshift({ id: `h-${battle.id}`, finishedAt: now(), opponentFingerprint: 'M4XA', battle: { ...structuredClone(battle), id: `h-${battle.id}`, moves: [], turnDeadline: null } });
    history.battles.splice(100);
    for (const res of clients) send(res, 'history', history);
    seq += 1; step = 0; battle = newBattle(seq); return;
  }
  steps[step++](battle);
}

// Everyone met: the Madrid league plus a couple of people only seen or battled.
const presences = ['available', 'idle', 'away', 'available', 'away', 'away'];
const trainers = {
  trainers: [
    ...boards.boards[0].members.filter((m) => !m.isYou).map((m, i) => ({
      publicKey: m.publicKey, fingerprint: m.fingerprint, name: m.displayName, presence: presences[i],
      lastSeenAt: presences[i] === 'away' ? now() - (i + 1) * 5 * 3_600_000 : now(),
      league: { id: 'board-madrid', name: 'Madrid office', rank: m.rank, points: m.score.total },
      team: m.stats.team ?? [], vsYou: { wins: i, losses: 1, draws: 0 }, lastBattleAt: now() - i * DAY,
    })),
    { publicKey: 'MCowSam', fingerprint: 'K1JB', name: 'Sam', presence: 'idle', lastSeenAt: now(), league: null,
      team: [{ speciesNum: 133, species: 'Eevee', form: null, shiny: false, level: 12 }], vsYou: { wins: 0, losses: 0, draws: 1 }, lastBattleAt: now() - DAY },
    { publicKey: 'MCowRobin', fingerprint: 'T6NG', name: 'Robin', presence: 'away', lastSeenAt: now() - 6 * DAY, league: null,
      team: [], vsYou: { wins: 0, losses: 0, draws: 0 }, lastBattleAt: null },
  ].sort((a, b) => ['available', 'idle', 'away'].indexOf(a.presence) - ['available', 'idle', 'away'].indexOf(b.presence)),
};
// The second board becomes one this Mac only watches (one league per trainer), plus another.
boards.boards[1] = { ...boards.boards[1], member: false, lastSyncAt: null, syncedPeers: 0,
  members: boards.boards[1].members.filter((m) => !m.isYou).map((m, i) => ({ ...m, rank: i + 1 })) };
boards.boards.push({ id: 'board-bcn', name: 'Barcelona crew', you: boards.boards[0].you, lastSyncAt: null, syncedPeers: 0, member: false,
  members: [member(0, 'Pau', 'Q7RX', 1, 2210), member(2, 'Jordi', 'V3LK', 2, 1450), member(4, 'Laia', 'N8CB', 3, 300)] });

// ---- server ------------------------------------------------------------------------------------------

const clients = new Set();
const battleBody = () => ({ battle });
const send = (res, name, data) => res.write(`event: ${name}\ndata: ${JSON.stringify(data)}\n\n`);

setInterval(() => { advance(); for (const res of clients) send(res, 'battle', battleBody()); }, 1500);
setInterval(() => { for (const res of clients) res.write(': heartbeat\n\n'); }, 15000);

const server = http.createServer((req, res) => {
  const origin = req.headers.origin;
  res.setHeader('access-control-allow-origin', origin ?? '*');
  res.setHeader('vary', 'Origin');
  res.setHeader('access-control-allow-headers', 'accept, content-type');
  if (req.method === 'OPTIONS') { res.writeHead(204).end(); return; }

  const path = new URL(req.url ?? '/', 'http://127.0.0.1').pathname;
  const json = (status, body) => { res.writeHead(status, { 'content-type': 'application/json' }).end(JSON.stringify(body)); };

  if (unpaired && path.startsWith('/v1/')) {
    json(403, { error: 'origin_not_paired', message: `Allow ${origin ?? 'this page'} to read your PokeTokenBar data?` });
    return;
  }
  switch (path) {
    case '/v1/trainer': return json(200, trainer);
    case '/v1/battle': return json(200, battleBody());
    case '/v1/boards': return json(200, boards);
    case '/v1/history': return json(200, history);
    case '/v1/trainers': return json(200, trainers);
    case '/v1/events':
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive' });
      send(res, 'trainer', trainer);
      send(res, 'battle', battleBody());
      send(res, 'boards', boards);
      send(res, 'history', history);
      send(res, 'trainers', trainers);
      clients.add(res);
      req.on('close', () => clients.delete(res));
      return;
    default: return json(404, { error: 'not_found', message: 'no such endpoint' });
  }
});

server.listen(port, '127.0.0.1', () => {
  console.log(`mock PokeTokenBar API on http://127.0.0.1:${port}${unpaired ? ' (unpaired: answering 403)' : ''}`);
});
