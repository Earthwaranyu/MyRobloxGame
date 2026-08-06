# Hyper Obby (Ranked)

A competitive Roblox obby: players queue in waves, race the same course head-to-head, and move up
an Elo ladder across 8 rank tiers. Around the race sit a gacha ability pool, a cosmetics shop,
per-stage top-100 leaderboards, ghost runs, parties and duels, and 7-language localization.

## Setup

Tools are pinned in `rokit.toml` (Rojo, Selene, StyLua, Luau). Install [Rokit], then:

```bash
rokit install
```

## Working on the game

Scripts live in `src/` and sync into Studio over Rojo:

```bash
rojo serve
```

Then open `game1.rbxl` in Studio and connect the Rojo plugin.

**`src/` and `game1.rbxl` own different things, and the split matters:**

- **`src/`** is every script — `src/shared` → `ReplicatedStorage.Shared`, `src/server` →
  `ServerScriptService.Server`, `src/client` → `StarterPlayer.StarterPlayerScripts.Client` (see
  `default.project.json`). Rojo live-syncs these, so editing a file here updates Studio
  immediately and nothing needs saving in Studio.
- **`game1.rbxl`** is the place: the lobby build and Stages 1–8's hand-placed geometry. Rojo does
  **not** write back to it. Anything built or moved in the Workspace only persists if you save the
  place in Studio.

Stage rooms, decoration, gimmicks and the Stage 5–8 courses are generated at server start from
`src/server/Services/Stage*Service.luau` — those are code, not place content.

## Tests

```bash
./tests/run.sh
```

Runs the pure-logic suite (rating, progression, gacha odds, stage geometry, course determinism)
against the real `src/shared` modules under the standalone Luau CLI — no Studio, no Rojo. Modules
that reach for `Players`, `Workspace` or remotes can't be covered this way and belong in a Studio
session instead.

## Lint and format

```bash
selene src          # must report 0 errors, 0 warnings
stylua --check src  # must report no diffs; `stylua src` to fix
```

CI runs all three on every push and pull request (`.github/workflows/ci.yml`).

## Layout

```
src/shared/       pure modules shared by both sides (Elo, stage layout, catalogs, constants)
src/server/       37 services — matchmaking, data, monetization, stage generation
src/client/       42 controllers plus the widget/theme layer
src/localization/ GameStrings.csv — 7 languages
tests/            headless Luau spec + runner
docs/             design docs and the remaining-work checklist
```

[Rokit]: https://github.com/rojo-rbx/rokit
