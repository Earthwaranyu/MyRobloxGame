export type AbilityRarity = "Common" | "Rare" | "Epic" | "Legendary" | "Mythic"

-- Every ability the equip system knows about resolves to one of these effect
-- shapes server-side (see AbilityService) and client-side (see
-- AbilityController) -- keeps the dispatch to one small table per side
-- instead of a new bespoke code path for every ability added later.
-- "Dash" = a horizontal burst, with an optional vertical lift on top
-- (Meteor's "explosive" upward kick reuses the exact same effect as Dash,
-- just with bigger numbers and UpwardBoost set).
-- "Recover" is the odd one out: it's the only kind that moves a player
-- BACKWARD, and the only one gated on being airborne (see Phoenix).
export type AbilityKind = "Dash" | "Hop" | "Blink" | "Speed" | "Recover"

export type AbilityInfo = {
	Id: string,
	Name: string,
	Description: string,
	Rarity: AbilityRarity,
	Kind: AbilityKind,
	CooldownSeconds: number,
	-- nil for Dash only: the one ability everyone owns for free by default,
	-- and the one ability that never comes out of a gacha pull (see
	-- GachaService's pull pool, which is every OTHER entry here).
	PullWeight: number?,
	-- Pull weight used instead of PullWeight for players who own the "Lucky"
	-- gamepass (see MonetizationService.HasLucky) -- nil means "no change".
	-- All four gacha-pool weights (both columns) sum to 100 so each is
	-- directly a percentage.
	LuckyPullWeight: number?,

	-- Kind-specific gameplay numbers; only the ones relevant to Kind are set.
	Speed: number?, -- Dash/Meteor horizontal burst speed, or Speed's WalkSpeed during the effect
	DurationSeconds: number?, -- Dash/Meteor burst duration, Speed's effect duration, or Recover's settle duration
	UpwardBoost: number?, -- Dash-kind vertical velocity kick (Hop uses this as its whole effect; Recover as its landing settle)
	BlinkDistance: number?, -- Blink teleport distance in studs
}

-- Array (not a dict) so order doubles as inventory/gacha display order --
-- same convention as Emotes.luau. Dash first since it's always owned, then
-- roughly rarity-ascending. Look up by Id with a linear scan (5 entries,
-- same convention every Emotes.luau caller already uses via `for _, e in
-- Emotes`) rather than maintaining a second id-keyed copy of this data.
--
-- Pull odds: Epic/Legendary/Mythic deliberately rare (5% / 1% / 0.1%) --
-- Common/Rare split the rest in the same ~5:3 ratio they always had. Lucky's
-- column keeps the exact same ABSOLUTE shift off Common it always granted
-- (-15 Common, +10 Epic, +5 Legendary, and now +0.5 Mythic -- the same 6x
-- multiplier Lucky already applied to Legendary) rather than re-deriving new
-- numbers from scratch, so "Lucky" keeps meaning the same thing it always
-- did. Mythic's 0.1 comes off Common in BOTH columns, so both still sum to
-- exactly 100 and each weight stays directly readable as a percentage --
-- tests/spec.luau asserts that, because a pool that doesn't sum to 100 makes
-- the odds screen (GachaController) quietly lie to players.
--
-- At 0.1% the EXPECTED wait for Phoenix is 1000 pulls, which nobody will ever
-- reach by rolling alone -- so the pity counter and the ten-pull Epic+ floor
-- in GachaService are what actually govern how a Mythic is obtained. The
-- headline rate is the flex; the guarantee is the real acquisition path.
local Abilities: { AbilityInfo } = {
	-- The original free-for-everyone ability: keeping the ladder skill-based
	-- rather than pay-to-win means at least one real mobility tool can never
	-- be locked behind luck or Robux. Every other ability below IS gacha-only.
	{
		Id = "Dash",
		Name = "Dash",
		Description = "A quick burst in whichever direction you're moving (or facing, if standing still). Free for everyone.",
		Rarity = "Common",
		Kind = "Dash",
		CooldownSeconds = 4,
		Speed = 55,
		DurationSeconds = 0.18,
	},
	{
		Id = "SkyHop",
		Name = "Sky Hop",
		Description = "A powerful upward leap -- clears tall gaps a normal jump can't.",
		Rarity = "Common",
		Kind = "Hop",
		CooldownSeconds = 5,
		-- Roblox's default jump velocity is ~53 studs/s (JumpHeight 7.2 under
		-- standard gravity) -- the old value of 62 here was only ~17% above
		-- that, which read as "basically a normal jump" rather than a
		-- distinct ability. This is closer to double, so the extra height is
		-- actually obvious.
		UpwardBoost = 95,
		-- 58.9/43.4 rather than the round 59/44 these were before Phoenix:
		-- Mythic's 0.1 / 0.6 is taken off Common in both columns so the totals
		-- stay at exactly 100. Common is the right place to take it from --
		-- it's the only tier where a tenth of a percent is invisible.
		PullWeight = 58.9,
		LuckyPullWeight = 43.4,
	},
	{
		Id = "Blink",
		Name = "Blink",
		Description = "Instantly teleport a short distance in whichever direction you're facing.",
		Rarity = "Rare",
		Kind = "Blink",
		CooldownSeconds = 6,
		BlinkDistance = 24,
		PullWeight = 35,
		LuckyPullWeight = 35,
	},
	{
		Id = "Surge",
		Name = "Surge",
		Description = "A few seconds of speed well beyond a normal sprint.",
		Rarity = "Epic",
		Kind = "Speed",
		CooldownSeconds = 10,
		Speed = 40,
		DurationSeconds = 2.5,
		PullWeight = 5,
		LuckyPullWeight = 15,
	},
	{
		Id = "Meteor",
		Name = "Meteor Dash",
		Description = "An explosive dash with lift behind it -- clears huge gaps in one burst.",
		Rarity = "Legendary",
		Kind = "Dash",
		CooldownSeconds = 12,
		-- Deliberately a big step up from Dash's 55/0.18/no-lift, not a
		-- marginal one -- the Legendary-tier flash (see AbilityController's
		-- RARITY_FLASH_INTENSITY) sells the moment, but the underlying feel
		-- needs to actually be different too, not just brighter.
		Speed = 85,
		DurationSeconds = 0.24,
		UpwardBoost = 35,
		PullWeight = 1,
		LuckyPullWeight = 6,
	},
	-- The only ability that undoes a mistake instead of granting movement,
	-- and the reason it can sit at the top of the rarity ladder without
	-- turning the Elo ladder pay-to-win.
	--
	-- Every other ability makes its owner faster, which on a ranked ladder
	-- means the best-equipped player wins more -- exactly what the Dash
	-- comment above exists to push back on. Phoenix's value instead scales
	-- INVERSELY with skill: a racer who never misses a jump gets nothing from
	-- it at all, and the better someone gets, the less it does for them. So
	-- however rare or expensive it is, it cannot buy anyone a place at the top
	-- of the ladder -- which is what makes a 0.1% gameplay item defensible
	-- here when a 0.1% speed boost would not be.
	--
	-- Deliberately grants NO horizontal burst and only a token upward settle.
	-- StageService sizes its checkpoint capture volume off the tallest launch
	-- in the game and tests/spec.luau reports only ~6.7 studs of headroom over
	-- it -- an ability that flung players higher than Meteor would let them
	-- sail clean over checkpoints and silently lose their save point. The
	-- settle here arcs ~3.5 studs, which is nowhere near that ceiling, and the
	-- spec asserts it stays there.
	{
		Id = "Phoenix",
		Name = "Phoenix",
		Description = "Falling? Burn back to the last ground you stood on. Only usable in mid-air.",
		Rarity = "Mythic",
		Kind = "Recover",
		-- The longest cooldown in the game by some margin: this erases a
		-- mistake outright, so being able to do it repeatedly through one
		-- tricky section would flatten that section for whoever owns it.
		CooldownSeconds = 20,
		-- The landing settle, not a launch -- just enough upward push that a
		-- racer arrives ON the platform rather than clipping into its lip.
		UpwardBoost = 18,
		DurationSeconds = 0.15,
		PullWeight = 0.1,
		LuckyPullWeight = 0.6,
	},
}

return Abilities
