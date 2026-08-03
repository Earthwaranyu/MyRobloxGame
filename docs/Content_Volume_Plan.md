# Content Volume — Research & Plan

Research date: 2026-08-03. Companion to [[Remaining_Work_Checklist]].

---

## 1. The diagnosis: it's not just "too few items"

Before adding anything, the numbers on the existing catalog explain *why* it feels empty.

### The gacha pool is 4 items, and 94% of pulls are near-worthless

`Abilities.luau` — pool is every ability with a `PullWeight`, i.e. everything except the
free `Dash`:

| Ability | Rarity | Base odds | Lucky odds |
|---|---|---|---|
| Sky Hop | Common | 59% | 44% |
| Blink | Rare | 35% | 35% |
| Surge | Epic | 5% | 15% |
| Meteor Dash | Legendary | 1% | 6% |

After ~5 pulls, ~88% of players own both Sky Hop and Blink. From that moment on **94% of
every pull returns `DUPLICATE_REFUND_POINTS = 50` against a `SINGLE_PULL_POINTS_COST = 1500`
spend — a 3.3% return.** That is the content drought, and it arrives within the first
session.

### The grind to the Legendary is ~290 hours

- Win pays `PointsPerWin = 50` + `PointsPerFinish = 15`; every other finisher gets 15.
- In an 8-player field that's an expected **~21 points per race** (0.125 × 65 + 0.875 × 15).
- With `WaveSeconds = 60` plus race time, call it ~2.5 min/race → **~510 points/hour**.
- One pull = 1500 points ≈ **3 hours**. Meteor at 1% needs ~100 pulls expected ≈ **290 hours**.

So the pool is simultaneously *too shallow* (4 items, exhausted in one session) and *too slow*
(the one item worth chasing is functionally unreachable without Robux). Adding items on top of
this curve without fixing the curve just moves the wall further out.

### There is no pity system

`GachaService.rollOne` is a flat weighted roll with no counter — a player can pull 300 times
and never see Meteor. Every mainstream gacha ships a hard guarantee for exactly this reason.

### Only one ability can be equipped at a time

`ProfileSchema.EquippedAbility` is a single slot. So collecting the *whole* pool has no gameplay
value — the moment a player owns the best ability for their playstyle, every further pull is
dead weight regardless of how many items exist. **This is the structural cap on how much a
bigger ability catalog can help**, and it's why the plan below leans on cosmetics and stage
content rather than just "more abilities."

---

## 2. What the research says

**Roblox's own content-cadence guidance** ([Creator Hub](https://create.roblox.com/docs/production/game-design/content-updates)):
- Ship a content update **every two weeks to one month**.
- Spend **fewer than three weeks of effort** on any one cadence release.
- The best cadence content is **art/data-only, requiring minimal programming** — and
  explicitly, *"simple variants on existing assets, like assets with only slight changes to
  color, are ideal because they can be produced quickly on a recurring schedule."*
- Use progression gates, limited-time events, or a season pass so players don't consume the
  content faster than you can make it.

**Gacha depth** ([Mobile Free To Play](https://mobilefreetoplay.com/design-gacha-system/)):
- Depth comes from *modelling* pool size × duplicate handling × rarity, not from a magic count.
- Critically: **duplicates that feed progression create "exponential depth"**, whereas
  duplicates that convert to currency (what this game does) create almost none.
- Pools should **open up over time** rather than shipping at final size — that's what makes a
  gacha feel refreshed.

**The Tower of Hell model** ([Roblox Wiki](https://roblox.fandom.com/wiki/YXceptional_Studios/Tower_of_Hell)):
- 400+ authored sections, procedurally stacked into a new tower every round.
- No static map. **Content freshness with zero ongoing developer updates** — the strongest
  replayability-per-effort ratio in the entire obby genre.

That last one matters most here, because **this project already has the machinery**:
`StageLayout.luau` is a pure, deterministic, headlessly-tested course planner and
`StageBuilderService` turns plans into parts. Stages 5–8 are already generated this way.

---

## 3. The plan

### Phase 0 — Fix the curve before adding content (highest ROI, ~1 day)

Nothing below works until the economy stops destroying value.

- [x] **Add a pity counter.** *Shipped:* `PullsSinceMythic` on the profile, hard guarantee at
      `Constants.Gacha.MythicPityPulls = 100`, with a visible pity bar in the gacha panel.
      Note there is still **no soft pity** — no rate ramp approaching the guarantee — and the
      bar deliberately doesn't draw a "hot zone" it would have to invent. Worth adding later.
- [x] **Ten-pull Epic-or-better floor.** *Shipped:* applied to the last slot, since the reveal
      sorts best-last.
- [ ] **Raise the duplicate refund, or replace it.** 50 points on a 1500-point pull is an
      insult at a 94% hit rate. Either raise it to ~300–400 (20–25%), or better:
- [ ] **Convert duplicates into a second currency** (Shards). This is the "exponential depth"
      lever from the research, and it's what makes a bigger pool actually pay off.
      **Important:** do *not* spend Shards on ability power. `Abilities.luau` states the design
      rule outright — *"keeping the ladder skill-based rather than pay-to-win means at least one
      real mobility tool can never be locked behind luck or Robux."* Levelling abilities would
      break that on a ranked Elo ladder. Spend Shards on **cosmetics instead**: ability effect
      skins, trails, emotes. Same depth, no competitive integrity cost.
- [ ] **Re-tune points-per-hour or pull cost.** 3 hours of play per pull against a 4-item pool
      is punishing. Either raise race payouts or drop `SINGLE_PULL_POINTS_COST`; the target
      should be roughly one pull per 30–45 min of play.

### Phase 1 — Cheap catalog volume (data-only, ~2–3 days total)

Ranked strictly by content-per-hour-of-work. All of these are exactly what Roblox means by
"simple variants on existing assets."

- [ ] **Trails: 4 → 16.** A trail is a `ColorSequence` + two widths — ~12 lines in
      `Trails.luau`, no new code paths at all. This is the cheapest content in the entire
      codebase and the shop tab most obviously starved. Ship them across a price ladder
      (points-only grinders, a few Robux-only, a couple of both).
- [ ] **Emotes: 8 → 16.** An emoji, a name, an optional `RobuxProductId`. `EmoteService`
      needs no changes. Keep the free/paid split at roughly half.
- [ ] **Badges: 1 → 6–8.** `BadgeMilestoneService` documents the exact procedure and the
      detection logic for win streaks and rank promotions **already exists in the codebase** —
      these are dashboard-creation + one line in `BADGE_IDS`. Free profile-page marketing on
      every unlock.
- [ ] **Abilities: 5 → 9, plus the Mythic tier.** `Abilities.luau` already notes *"A Mythic
      tier at 0.1% is planned but not in the pool yet — when it lands, both columns need
      re-summing to 100."* New abilities are parameter variations on the four existing
      `AbilityKind`s (`Dash`/`Hop`/`Blink`/`Speed`), so most need no new dispatch code. Add
      `Mythic` to `RarityColors.luau` at the same time.

Expect Phase 1 to roughly **triple the catalog with no new systems**.

### Phase 2 — Stage content via the generator, not by hand (the big one)

Hand-building Stage 9, 10, 11… does not scale and produces the same ~20-primitive courses that
already look like prototype art. The Tower of Hell approach fits this codebase far better.

- [ ] **Refactor `StageLayout` from whole-course plans into a library of composable SECTIONS**
      (a gap run, a stair climb, a bounce chain, a vanishing bridge, a moving-platform ferry).
      The existing `MaxJumpGap` / `LaunchArcHeight` solvers already guarantee any section is
      physically clearable — that safety net is what makes a section library viable at all, and
      `tests/spec.luau` can validate each section in isolation.
- [ ] **Target ~30–40 sections to start.** Assembled 8–12 per course, that's already more
      distinct courses than the game could ever hand-build, and each new section multiplies
      across every future course.
- [ ] **Give the four `StageGimmickService` gimmicks their own sections** so Bounce/Moving/
      Vanishing/Speed become building blocks rather than one-per-stage flavour.

> ⚠️ **This conflicts with the leaderboards, and you have to pick.** `StageLayout` is
> deliberately deterministic — its own comment says *"times are only comparable if everyone ran
> the same course,"* which is what makes the per-stage top-100 boards meaningful. Randomised
> courses would break that. Three ways out:
> 1. **Fixed ranked / random casual** — ranked queue uses the 8 fixed stages, the bots+practice
>    queue uses randomised assemblies. Preserves the ladder exactly as-is.
> 2. **Seeded daily courses** — one deterministic seed per day, so everyone worldwide races the
>    same course and the board resets daily. Adds a strong daily-return hook.
> 3. **Keep generating fixed stages** — use the section library to author Stages 9–20 as
>    permanent, deterministic courses. Least disruptive, still a big content multiplier.
>
> Option 3 is the safest and still delivers most of the value; option 2 is the most interesting
> for retention.

### Phase 3 — Make the content last

- [ ] **Weekly rotating shop** — surface 3–4 of the 16 trails at a time. Roblox's guidance
      explicitly recommends this to stop players consuming the catalog instantly.
- [ ] **Season pass / limited-time cosmetics** — the profile already tracks
      `TotalPlaySeconds`, `WinStreak`, `BestWinStreak`, `DailyStreak`, `Wins`/`Losses`. A pass
      is mostly UI over data that already exists.

---

## 4. Suggested first commit

Phase 0 + the trails and emotes from Phase 1. That's roughly two days, touches only
`GachaService`, `ProfileSchema`, `Trails.luau`, `Emotes.luau` and `Constants.luau`, is fully
covered by `tests/run.sh`, and it fixes the economics *before* pouring content into them.

## Sources

- [Content updates — Roblox Creator Hub](https://create.roblox.com/docs/production/game-design/content-updates)
- [creator-docs: content-updates.md](https://github.com/Roblox/creator-docs/blob/main/content/en-us/production/game-design/content-updates.md)
- [How To Design A Gacha System — Mobile Free To Play](https://mobilefreetoplay.com/design-gacha-system/)
- [Tower of Hell — Roblox Wiki](https://roblox.fandom.com/wiki/YXceptional_Studios/Tower_of_Hell)
- [How Does Gacha System Monetize Mobile Games — ASO World](https://asoworld.com/blog/how-does-gacha-system-monetize-mobile-games-effectively/)
