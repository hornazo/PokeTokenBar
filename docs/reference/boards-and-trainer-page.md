---
summary: "Leaderboards replicated between Macs nearby, board-scoped co-signed battles, and the trainer page's loopback API: model, protocols, trust and how to test them."
read_when:
  - Changing BoardModel, BoardStore, BoardSyncProtocol/Service or anything a board record or receipt signs
  - Changing the battle wire protocol (BattleLink) or how a nearby battle ends
  - Changing the local API (LocalHTTP, LocalTrainerServer, TrainerPageCoordinator) or web/
---

# Boards and the trainer page

No server holds any of this. Every member's app keeps a copy of each board it's in, Macs nearby merge
their copies, and a static page reads the app over `127.0.0.1`.

## Boards

- **Code = membership.** The invite code (`XXXX-XXXX-XXXX`, 60 random bits) is the board's secret. The
  board id is `SHA-256("ptb-board:" + code)`; proofs are `HMAC(code-derived key, context)`.
- **Rows.** Each member signs their own row (`BoardRecord`: name, raw stats, `joinedAt`, `issuedAt`,
  `left`) with their trainer key (`TrainerKeyStore`, one per Mac, or per `PTB_STATE_DIR`). The newest
  `issuedAt` per key wins; equal times fall back to the signature. A tombstone (`left`) is undone by a
  newer row. Joiners sign an empty board name; the name shown is the earliest member's non-empty one.
- **Convergence.** Merge is order-independent, so replicas that saw the same rows are identical
  (`testMergeConvergesWhateverTheOrder`). Ranking caps at 100 live members by `(joinedAt, key)`;
  storage caps at 500 rows and 1,000 receipts by total orders.
- **Scores.** Collection, levels and the opt-in AI band are self-reported. Battle points come only from
  receipts both players signed, between current members, at most 3 per pair per ISO week (UTC).
  `battleRecord` is shown but never scored. Weights live in `BoardScoring`; the page shows what the app
  computed.
- **Sync** (`_ptb-board`, separate from battles). Off by default. Each connection: nonces, one HMAC
  proof per board held, then per shared board a digest (`key → issuedAt`, receipt ids) and only the
  rows the other side lacks. Unshared boards never cross the wire. Peers use a random per-run name.
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

## Trust

Signatures prove who said something, not that it's true: an edited save or a modified app can claim any
plausible collection, and two app instances can co-sign each other within the weekly pair limit.
Fingerprints (4 Crockford characters of the key's hash) tell equal names apart. A leaked code can't be
revoked; the fix is a new board.

## Trainer page (local API)

- Loopback only (`127.0.0.1:47323`, setting or `PTB_TRAINER_PORT`), read-only, off by default.
- Guards in `LocalHTTP.route`, in order: `Host` must be this port on loopback (421, DNS rebinding);
  an `Origin` must be one the user allowed (403 `origin_not_paired` and a one-time prompt); `null` and
  odd origins are refused without asking; only GET and OPTIONS (405). Preflights answer
  `Access-Control-Allow-Private-Network`.
- `GET /v1/trainer`, `/v1/battle`, `/v1/boards`, and `/v1/events` (SSE, all three on connect, then on
  change). Shapes mirror `web/src/api/types.ts`. Board codes are never served.
- The battle snapshot mirrors the battle window's paced `display`, never `BattleState` (its RNG).

## Testing

- Unit: `BoardModelTests`, `BoardStoreTests`, `BoardSyncProtocolTests`, `BattleReceiptTests`,
  `LocalAPITests`, `TrainerShowcaseTests`; the pure files are in `scripts/test-gate.sh`.
- Two instances on one Mac, no clicks (debug builds):
  ```bash
  swift build
  defaults write PokeTokenBar trainerPage.enabled -bool true
  defaults write PokeTokenBar boards.syncNearby -bool true
  PTB_STATE_DIR=/tmp/ptb-a PTB_TRAINER_PORT=47323 PTB_DEBUG_BOARD="KANT-0000-0001:Kanto" .build/debug/PokeTokenBar &
  PTB_STATE_DIR=/tmp/ptb-b PTB_TRAINER_PORT=47324 PTB_DEBUG_BOARD="KANT-0000-0001:" .build/debug/PokeTokenBar &
  curl -s http://127.0.0.1:47323/v1/boards | jq '.boards[0].members | length'   # 2 once synced
  defaults delete PokeTokenBar   # afterwards
  ```
- The page: `cd web && npm run mock` (no app) or `npm run dev` against a running app; pair its origin
  when the app asks.
