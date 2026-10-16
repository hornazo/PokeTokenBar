---
summary: "Leagues (boards) replicated between Macs nearby, board-scoped co-signed battles, battle history, presence, and the trainer page's loopback API: model, protocols, trust and how to test them."
read_when:
  - Changing BoardModel, BoardStore, BoardSyncProtocol/Service or anything a board record or receipt signs
  - Changing the battle wire protocol (BattleLink) or how a nearby battle ends
  - Changing the local API (LocalHTTP, LocalTrainerServer, TrainerPageCoordinator) or web/
  - Changing what nearby discovery advertises (NearbyDiscovery, presence) or the trainer list
---

# Boards and the trainer page

No server holds any of this. Every app keeps a copy of its own board and of every other board it has
seen, Macs nearby merge their copies, and a static page reads the app over `127.0.0.1`. Standings are
public; only joining needs the code. The UI calls a board a league; code, files and
the `_ptb-board` service keep the board name.

## Boards

- **One league per trainer.** `BoardStore.create`/`join` refuse while you're in one (`.alreadyJoined`);
  leaving frees the slot even before the tombstone is delivered. A save from before the rule may hold
  several boards; nothing merges or drops them.
- **Code = membership.** The invite code (`XXXX-XXXX-XXXX`, 60 random bits) is the board's secret. It
  derives an Ed25519 board key (`BoardCode.signingKey`, seed `SHA-256("ptb-board-sign:" + code)`); the
  board id is `SHA-256("ptb-board-v2:" + public board key)` (pinned in `testLeagueKeyAndIdArePinned`).
  Every row carries the public board key and a membership: the board key's signature over the member's
  key. Any Mac checks both against the board id, so holding rows without the code can't add a member.
  Battle invites still prove the code with `HMAC(code-derived key, context)`.
- **Watched boards.** Boards we're not in are kept read-only (`BoardStore.watched`) once a valid member
  row arrives: at most 50, the most recently active first. Joining one keeps its rows; a board we left
  becomes watched once its tombstone is out.
- **Moving old saves.** Boards saved under the code-only id (`legacyBoardId`) move to the public id on
  load with an empty replica and their name carried over; our row is re-signed on the next publish,
  other members' rows come back when they run a build that signs memberships.
- **Rows.** Each member signs their own row (`BoardRecord`: name, raw stats including the battle team,
  `joinedAt`, `issuedAt`, `left`) with their trainer key (`TrainerKeyStore`, one per Mac, or per `PTB_STATE_DIR`). The newest
  `issuedAt` per key wins; equal times fall back to the signature. A tombstone (`left`) is undone by a
  newer row. Joiners sign an empty board name; the name shown is the earliest member's non-empty one.
  `BoardStats` leaves `team` out of its encoding when empty, so rows signed before teams existed still
  verify; older builds drop rows that carry a team.
- **Convergence.** Merge is order-independent, so replicas that saw the same rows are identical
  (`testMergeConvergesWhateverTheOrder`). Ranking caps at 100 live members by `(joinedAt, key)`;
  storage caps at 500 rows and 1,000 receipts by total orders.
- **Scores.** Collection, levels and the opt-in AI band are self-reported. Battle points come only from
  receipts both players signed, between current members, at most 3 per pair per ISO week (UTC).
  `battleRecord` is shown but never scored. Weights live in `BoardScoring`; the page shows what the app
  computed.
- **Sync** (`_ptb-board`, separate from battles, version 2). Off by default; runs without a league too.
  Each connection: nonces, each side lists the board ids it holds (200 at most), then for every board
  either side holds a digest (`key → issuedAt`, receipt ids) and only the rows the other side lacks.
  Version 1 peers (proof-based, private boards) are refused. Peers use a random per-run name.
- **Leaving** signs a tombstone and hides the board; it keeps syncing until one completed exchange has
  carried the tombstone, then it's forgotten.

## Board-scoped battles (wire protocol v4)

- The invitation context is `.invite(version, trainer, board?)`; the board part is a nonce plus a proof
  of holding the code. The accepting side shows the board name only if it holds that code.
- The handshake adds `.identity(publicKey, startedAt?, boardProof?)`. The challenger only scores the
  battle if the other side proves the same code bound to the invite nonce and its own key; the
  accepting side only if `startedAt` is within 10 minutes of its clock. Same key on both sides never
  scores.
- At the end both sides sign the same receipt (`battleId` = hash of both nonces) and exchange
  signatures. A forfeit carries the forfeiting side's signature; a disconnect, timeout, desync or a
  friendly leaves no receipt.
- Any change to these messages bumps `BattleWireMessage.protocolVersion` (pinned in
  `BattleMechanicsTests`), as for engine rules.

## Battle history, presence and trainers met

- **History.** `TrainerPageCoordinator` saves each battle shown in the battle window once it has an
  outcome (`BattleHistoryRecorder`; a practice rematch records again) to `battles.json`: the final
  spectator snapshot without moves or timer, the newest 400 log lines, the opponent's key. Newest 100 kept.
- **Presence.** While visible for battles, discovery info carries `k` (trainer key) and `a` (`1` when
  the user had keyboard or mouse input in the last 5 minutes, checked every 30 s). Discovery info is fixed
  per advertiser and a browser reports a peer ID only once, so a change restarts advertising and browsing
  under a new peer ID (`NearbyBattleService.advertise`), waiting while a challenge or battle is on;
  `found` keeps one entry per key. The app marks idle trainers in the nearby list.
- **Trainers met.** `TrainerSightingsStore` (`trainers.json`, 300 newest) remembers keys seen nearby.
  `TrainerList.build` merges them with league rows and history: presence (available, idle, away),
  league rank, team (league row, else your last battle with them) and your record against them.

## Trust

Signatures prove who said something, not that it's true: an edited save or a modified app can claim any
plausible collection, and two app instances can co-sign each other within the weekly pair limit.
Fingerprints (4 Crockford characters of the key's hash) tell equal names apart. A leaked code can't be
revoked; the fix is a new board. Every board's members, stats and teams reach anyone nearby with sync on.
Anyone can mint valid boards of their own, so a peer can fill the 50 watched slots with fake ones; the
most recently active stay.

## Trainer page (local API)

- Loopback only (`127.0.0.1:47323`, setting or `PTB_TRAINER_PORT`), read-only, off by default.
- Guards in `LocalHTTP.route`, in order: `Host` must be this port on loopback (421, DNS rebinding);
  an `Origin` must be one the user allowed (403 `origin_not_paired` and a one-time prompt); `null` and
  odd origins are refused without asking; only GET and OPTIONS (405). Preflights answer
  `Access-Control-Allow-Private-Network`.
- `GET /v1/trainer`, `/v1/battle`, `/v1/boards`, `/v1/history`, `/v1/trainers`, and `/v1/events` (SSE,
  every endpoint's event on connect, then on change). Shapes mirror `web/src/api/types.ts`; fields typed
  `T | null` there are encoded as explicit nulls. Board codes are never served.
- The battle snapshot mirrors the battle window's paced `display`, never `BattleState` (its RNG).

## Testing

- Unit: `BoardModelTests`, `BoardStoreTests`, `BoardSyncProtocolTests`, `BattleReceiptTests`,
  `LocalAPITests`, `TrainerShowcaseTests`, `BattleHistoryTests`, `TrainerDirectoryTests`; the pure files
  are in `scripts/test-gate.sh`.
- Two instances on one Mac, no clicks (debug builds). Pick ports other than an installed app's 47323.
  `PTB_DEBUG_VISIBLE=1` makes an instance visible for battles at launch; `PTB_DEBUG_IDLE` forces its
  presence (`1` idle, `0` active, or a file path: idle while the file exists).
  ```bash
  swift build
  defaults write PokeTokenBar trainerPage.enabled -bool true
  defaults write PokeTokenBar boards.syncNearby -bool true
  PTB_STATE_DIR=/tmp/ptb-a PTB_TRAINER_PORT=47325 PTB_DEBUG_BOARD="KANT-0000-0001:Kanto" PTB_DEBUG_VISIBLE=1 PTB_DEBUG_IDLE=/tmp/a-idle .build/debug/PokeTokenBar &
  PTB_STATE_DIR=/tmp/ptb-b PTB_TRAINER_PORT=47326 PTB_DEBUG_BOARD="KANT-0000-0001:" PTB_DEBUG_VISIBLE=1 .build/debug/PokeTokenBar &
  curl -s http://127.0.0.1:47325/v1/boards | jq '.boards[0].members | length'   # 2 once synced
  curl -s http://127.0.0.1:47326/v1/trainers | jq '.trainers[].presence'          # touch /tmp/a-idle → idle within 30 s
  defaults delete PokeTokenBar   # afterwards
  ```
- The page: `cd web && npm run mock` (no app) or `npm run dev` against a running app; pair its origin
  when the app asks.
