# PokeTokenBar Trainer (web)

A static page that shows your PokeTokenBar trainer card, live battles and leaderboards. It runs in your own browser and reads everything from the app's local API on `http://127.0.0.1:<port>` (default 47323). There's no server behind it, and the page only renders what the app computes.

Turn on Settings → Trainer page in the app first. Without it the page shows a "Can't reach PokeTokenBar" state.

## Run it

```bash
npm install
npm run dev     # http://localhost:5173
npm run check   # typecheck, tests, build
```

`npm run mock` serves fixture data on `127.0.0.1:47323` for development without the app: two boards, a trainer, and a battle that advances every 1.5 s, ends and restarts. `npm run mock -- 5000` picks another port, and `--unpaired` makes it answer `403 origin_not_paired` to try the approval state.

## Host it

`npm run build` writes static files to `dist/`. Put them on any static host, for example GitHub Pages. Routes are hash-based (`#/me`, `#/battle`, `#/boards`, `#/board/<id>`, `#/join/<code>`), so no rewrites are needed, and asset paths are relative, so a sub-path works.

| Variable | Default | |
|---|---|---|
| `VITE_PTB_LOCAL_PORT` | `47323` | Port the page tries first, read at build time. |
| `VITE_PTB_SPRITE_BASE` | PokéAPI sprites on GitHub | Base URL for `{n}.png` and `shiny/{n}.png` sprites, to self-host them. |

## Port

If you changed the port in the app, type it in the port field on the "Can't reach" screen. The page keeps it in `localStorage` (`ptb.port`).

## Pairing

The first time a hosted page asks, the app shows "Allow https://… to read your PokeTokenBar data?" on your Mac. Until you approve, the page shows "Approve this page in the PokeTokenBar prompt on your Mac" and asks again every few seconds.

## Browsers

Chrome may ask to allow access to devices on your local network the first time. Allow it. Safari may block a secure page from reaching `127.0.0.1`; use Chrome or Firefox if the page can't connect even though the app is running.

## Boards

Joining a board happens in the app. A `#/join/<code>` link opens `poketokenbar://boards/join?code=<code>`, and the app asks you to confirm. Board data is replicated between Macs by the app when members meet nearby with sync on, so the page can lag behind.
