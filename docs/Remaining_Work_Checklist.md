# Remaining Work — Hyper Obby (Ranked)

Audit date: 2026-08-03 · Place `83986182626217` · 25,699 lines of Luau · 38 services / 45 controllers · 209/209 headless tests passing

The design docs (`Game_Overview`, `Core_Mechanics`) are **fully implemented**. Every feature listed
there exists in code: matchmaking waves, Elo + 8 rank tiers, gacha with Lucky/Skip gamepasses,
abilities + inventory, trails shop, emotes, party/duel/profile-card, sprint, per-stage top-100
leaderboards, ghost runs, weather + ambience, bots, referrals, hype feed, 7-language localization.

What's left is **polish, content volume, and launch operations** — not core features.

---

## 1. Code hygiene (half a day)

- [ ] Run `stylua src` — 11 files currently fail `stylua --check`
      (`MatchService`, `BotService`, `AbilityService`, `LeaderboardBoardService`, `Stages`,
      `Hype`, `CategoryIcons`, `AbilityIcons`, `RacerCrowd`, `StreakFlameController`, `MenuIcons`)
- [ ] Clear the 13 `selene` warnings (0 errors):
      - dead locals: `GhostService.luau:2` (`Players`), `GhostController.luau:35-36`
        (`ghostRoot`/`ghostHead`), `PartyController.luau:48` (`requestJoinRemote` — the remote is
        actually fired from `ProfileCardController`, so this one is genuinely vestigial)
      - `UDim2.new` → `UDim2.fromScale` in `GachaController`, `ShopController`
      - shadowed `panel` (`SettingsController`), `profile` (`GachaController`), `size`
- [ ] Replace the boilerplate `README.md` (still the Rojo 7.7.0 template) with real setup steps:
      `rokit install`, `rojo serve`, `./tests/run.sh`, how `game1.rbxl` relates to `src/`
- [ ] Add CI (`.github/workflows`) running `./tests/run.sh` + `selene src` + `stylua --check src`
- [ ] Resolve the dirty tree: `docs/Viral Roblox Game Checklist.pdf` is deleted but unstaged,
      `docs/.DS_Store` is untracked — add `.DS_Store` to `.gitignore`
- [ ] Consider splitting `MatchService.luau` (2,721 lines — 2.5× the next largest file); the
      queue/wave loop, the race session, and the anti-cheat watchdog are three separable concerns

## 2. Gaps from the viral checklist PDF

Two items the PDF flagged are **now done** and should be marked resolved: #7 Analytics
(`TelemetryService` wraps `AnalyticsService` with onboarding + match funnels and economy events)
and #10 Localization (`GameStrings.csv`, 176 rows × 7 languages).

Still open:

- [ ] **#2 Rebirth / Prestige** — nothing in the codebase (`grep -i rebirth|prestige` is empty).
      Once a player hits Grandmaster and owns all 5 abilities there is no further goal. Suggested
      shape: reset Elo + points for a permanent currency that survives (e.g. Prestige Shards),
      surface the prestige level on the overhead display next to rank
- [ ] **#4 Premium payout / session length** — no AFK zone, no time-based reward. Cheapest win:
      a playtime-tick reward using the `TotalPlaySeconds` field already on the profile
- [ ] **#5 FTUE polish** — `TutorialService` shows exactly one dismissible panel, once per account.
      That's the floor, not the target. Watch the onboarding funnel in the dashboard after launch
      and fix wherever the drop is, rather than guessing now
- [ ] **#8 Creator incentives** — no chat tag, VIP role, or influencer cosmetic exists
- [ ] **#11 R15 enforcement** — could not verify from code; the avatar type is a Creator Dashboard
      setting, not a script property. **Check Game Settings → Avatar → Avatar Type is R15
      (not R6, not Player Choice)** — R6 makes the game ineligible for the U.S. 18+ DevEx rate

## 3. Content volume — the biggest real gap

The systems are built; there is very little *in* them.

- [ ] **Trails: 4 total** (`Basic`, `Flame`, `Rainbow`, `Galaxy`), only 1 buyable with Robux.
      A cosmetic shop with 3 purchasable items won't sustain a store tab
- [ ] **Abilities: 5** (`Dash`, `SkyHop`, `Blink`, `Surge`, `Meteor`). The gacha is the game's main
      monetization loop and a player pulls the whole pool almost immediately — this is the single
      highest-leverage content addition
- [ ] **Emotes: 8** (4 free, 4 paid)
- [ ] **Badges: 1 live** (`FirstWin`). `BadgeMilestoneService` documents exactly how to add more —
      create on the dashboard, drop the id in `BADGE_IDS`. Win streaks and rank promotions are
      obvious candidates and are already detected in code
- [ ] **Stage visuals.** Stage1–4 in the place file are ~20 untextured `Part` primitives each
      (`Platform_1..14`, `Checkpoint_4/8/12`, `VoidZone`); Stage5–8 are generated at server start.
      `StageDecorationService` applies a per-weather color palette on top, which is the only thing
      separating them visually. For an obby competing on the Discover page this reads as prototype
      art
- [ ] **Lobby.** 148 descendants: part-based trees (trunk + 3 foliage blocks), flag banners, a
      plaza floor, one procedural trophy. The design doc calls for a "very beautiful lobby" and
      this is the first thing every new player sees — it directly drives the Qualified Play
      Through Rate the PDF warns about

## 4. Launch operations (outside the codebase)

- [ ] Verify every live id still resolves via `GetProductInfo` — `MonetizationService` already
      carries a comment about one gamepass id (`3610509225`) that never resolved and had to be
      replaced. Check all 4 gamepasses (VIP, Lucky, SkipGachaAnimation), the 4 point bundles,
      the Galaxy trail, the 4 paid emotes, and the gacha 1×/10× products
- [ ] Confirm **Studio → Game Settings → Security → Enable Studio Access to API Services** is on,
      and that DataStores work on the published place — `LeaderboardService.getStore()` returns
      `nil` when API access is off, which silently disables every leaderboard
- [ ] Store page: icon, thumbnails, description, genre, age rating, and 7-language store metadata
      to match the in-game localization
- [ ] Multi-player playtest with real accounts. The wave clock (`WaveSeconds = 60`) and the 8-player
      queue cap have only been exercised solo/with bots as far as the repo shows — queue fill,
      spectate, party, and duel all behave differently with real humans
- [ ] Watch D1 retention and QPTR in the dashboard for the first week; the onboarding funnel is
      already instrumented, so the data will be there

---

## Suggested order

1. Section 1 (hygiene) — mechanical, unblocks a clean CI baseline
2. Section 4's first two boxes (product ids, API access) — these are *silent* failures in
   production; the game looks fine and just quietly earns nothing / shows empty leaderboards
3. Lobby + stage art — highest impact on whether anyone stays past 30 seconds
4. Abilities and trails content — feeds the gacha and shop loops that are already built
5. Prestige system — matters only once players actually reach the current ceiling
