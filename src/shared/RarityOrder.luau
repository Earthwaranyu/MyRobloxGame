-- Single source of truth for how rarities RANK against each other, the same
-- way RarityColors is the single source of truth for how they look.
--
-- Split out because three separate places need to answer "is this at least as
-- good as an Epic?" and they must never disagree: GachaService's ten-pull
-- floor and its Mythic pity counter (server), and GachaController's
-- best-last reveal ordering (client). The client used to carry a private copy
-- of this table; a tier added to Abilities.luau but missed in that copy would
-- have sorted as rank 0 and revealed FIRST -- burying the best pull of a
-- ten-pull under nine Commons, which is the exact opposite of what the reveal
-- order exists to do.
--
-- Pure data, no Roblox types, so tests/run.sh can assert every rarity in
-- Abilities.luau appears here -- which is what actually stops the next tier
-- from being half-wired.
local RarityOrder = {}

RarityOrder.Rank = {
	Common = 1,
	Rare = 2,
	Epic = 3,
	Legendary = 4,
	Mythic = 5,
}

-- The floor a ten-pull guarantees (see GachaService). Named rather than
-- inlined as `3` so the guarantee reads as "Epic or better" at the call site,
-- and so raising it later is a one-line change here rather than a hunt.
RarityOrder.TenPullFloor = RarityOrder.Rank.Epic

-- Unknown rarities sort below everything rather than erroring: this is used on
-- a reveal path where a nil arithmetic error would break the animation
-- mid-pull. The spec check above is what catches the mistake instead.
function RarityOrder.Of(rarity: string): number
	return RarityOrder.Rank[rarity] or 0
end

return RarityOrder
