// Stand-in for the PokeTokenBar app's local API, for developing the page without the app.
//   node dev/mock-app.mjs [port] [--unpaired]
// Serves /v1/trainer, /v1/battle, /v1/boards and /v1/events on 127.0.0.1 with fixture data. A battle
// advances every 1.5 s, ends, and starts again. CORS is open to any Origin: dev only.
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

const member = (n, name, fingerprint, rank, total, extra = {}) => ({
  publicKey: `MCowBQYDK2VwAyEA${fingerprint}mockmockmockmockmockmock${n}`, fingerprint, displayName: name, isYou: false,
  joinedAt: now() - 40 * DAY, updatedAt: now() - n * 7 * 3_600_000,
  stats: {
    collection: { dex: 40 - n * 6, species: 38 - n * 6, shinies: 3 - Math.min(n, 3), graduated: 4 - Math.min(n, 4) },
    levels: { teamTotal: 280 - n * 30, top: 90 - n * 8 }, aiBand: ['extreme', 'heavy', 'moderate', 'light', null][n % 5],
    battleRecord: { wins: 20 - n * 3, losses: n * 2, draws: 1 },
  },
  score: { total, battle: Math.round(total * 0.45), collection: Math.round(total * 0.3), levels: Math.round(total * 0.2), ai: total - Math.round(total * 0.45) - Math.round(total * 0.3) - Math.round(total * 0.2) },
  rank, counted: { wins: 9 - n, draws: 1, losses: n }, ...extra,
});

const boards = {
  syncEnabled: true,
  boards: [
    {
      id: 'board-madrid', name: 'Madrid office', you: 'MCowBQYDK2VwAyEA7QK3mockmockmockmockmockmock1', lastSyncAt: now() - 25 * 60_000, syncedPeers: 3,
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

function advance() {
  if (step >= steps.length) { seq += 1; step = 0; battle = newBattle(seq); return; }
  steps[step++](battle);
}

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
    case '/v1/events':
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive' });
      send(res, 'trainer', trainer);
      send(res, 'battle', battleBody());
      send(res, 'boards', boards);
      clients.add(res);
      req.on('close', () => clients.delete(res));
      return;
    default: return json(404, { error: 'not_found', message: 'no such endpoint' });
  }
});

server.listen(port, '127.0.0.1', () => {
  console.log(`mock PokeTokenBar API on http://127.0.0.1:${port}${unpaired ? ' (unpaired: answering 403)' : ''}`);
});
