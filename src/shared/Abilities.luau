export type AbilityRarity = "Common" | "Rare" | "Epic" | "Legendary"

-- Every ability the equip system knows about resolves to one of these three
-- effect shapes server-side (see AbilityService) and client-side (see
-- AbilityController) -- keeps the dispatch to one small table per side
-- instead of a new bespoke code path for every ability added later.
-- "Dash" = a horizontal burst, with an optional vertical lift on top
-- (Meteor's "explosive" upward kick reuses the exact same effect as Dash,
-- just with bigger numbers and UpwardBoost set).
export type AbilityKind = "Dash" | "Hop" | "Blink" | "Speed"

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
	DurationSeconds: number?, -- Dash/Meteor burst duration, or Speed's effect duration
	UpwardBoost: number?, -- Dash-kind vertical velocity kick (Hop uses this as its whole effect)
	BlinkDistance: number?, -- Blink teleport distance in studs
}

-- Array (not a dict) so order doubles as inventory/gacha display order --
-- same convention as Emotes.luau. Dash first since it's always owned, then
-- roughly rarity-ascending. Look up by Id with a linear scan (5 entries,
-- same convention every Emotes.luau caller already uses via `for _, e in
-- Emotes`) rather than maintaining a second id-keyed copy of this data.
--
-- Pull odds: Epic/Legendary deliberately rare (5% / 1%) -- Common/Rare split
-- the remaining 94% in the same ~5:3 ratio they always had (59/35). Lucky's
-- column keeps the exact same ABSOLUTE shift off Common it always granted
-- (-15 Common, +10 Epic, +5 Legendary) rather than re-deriving new numbers
-- from scratch, so "Lucky" keeps meaning the same thing it always did, just
-- applied on top of the new base odds. A Mythic tier at 0.1% is planned but
-- not in the pool yet -- when it lands, both columns need re-summing to 100.
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
		PullWeight = 59,
		LuckyPullWeight = 44,
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
}

return Abilities
