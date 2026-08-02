-- The shape of a saved player profile, and the one function that turns whatever
-- came back from the DataStore into a usable one.
--
-- SPLIT OUT OF PlayerDataService for the same reason LayoutMath was split out of
-- Responsive: this decides what every player OWNS -- trails and emotes bought
-- with Robux, abilities pulled from the gacha, and the receipt ids that stop a
-- replayed purchase granting twice. It is the highest-consequence logic in the
-- game, and while it lived inside a service that reaches for DataStoreService
-- and Players there was no way to test it at all. Here it is plain table work,
-- so tests/run.sh covers it with no Studio and no DataStore.
--
-- Nothing in this file may touch a Roblox service; that is what keeps it
-- testable, and it is the same rule the rest of src/shared follows.
local Constants = require(script.Parent.Constants)

local ProfileSchema = {}

-- Bumped when the rating SCALE changes, so old saves can be rebased rather than
-- silently reinterpreted against new tier thresholds. Version 1 started players
-- at 0 (on the rating floor); version 2 starts them at Constants.Elo.StartingRating.
ProfileSchema.EloScaleVersion = 2

ProfileSchema.Default = {
	Elo = Constants.Elo.StartingRating,
	EloScaleVersion = ProfileSchema.EloScaleVersion,
	Points = 0,
	OwnedTrails = { "Basic" },
	EquippedTrail = "Basic",
	WinStreak = 0,
	BestWinStreak = 0,
	LastLoginDate = "",
	DailyStreak = 0,
	AwardedBadgeKeys = {},
	OwnedEmotes = {},
	HasSeenTutorial = false,
	-- Ranked-race record only (bot/practice matches deliberately don't touch
	-- these -- see MatchService.PlayerReachedFinish -- since "win rate" here
	-- means the same thing the Elo ladder already means: real opponents only).
	Wins = 0,
	Losses = 0,
	-- Dash is free and owned by everyone by default; anything else here came
	-- from a gacha pull (see GachaService). EquippedAbility is always one of
	-- the ids in this list (enforced by AbilityService.handleEquip).
	OwnedAbilities = { "Dash" },
	EquippedAbility = "Dash",
	-- Guards non-idempotent Robux grants (gacha pulls, points bundles --
	-- see GachaService.GrantRobuxPull and PurchaseService's point-bundle
	-- branch) against MarketplaceService replaying the same receipt twice.
	-- Stored on the profile itself (durable via DataStore) rather than an
	-- in-memory set, since unlike trail/emote grants (which are already
	-- idempotent via a plain ownership check) these consume something
	-- real -- a random roll, or a points balance -- that would double up on
	-- replay otherwise. One shared set keyed by PurchaseId (a globally
	-- unique GUID) works fine across different grant types.
	ProcessedPurchaseIds = {},
	-- Whether gacha pulls skip straight to the result instead of playing the
	-- reveal animation. A per-player preference, not just a session toggle
	-- (see GachaService.SetSkipAnimation), so it doesn't reset every time
	-- someone rejoins -- but only ever true if they actually own the Skip
	-- Animation gamepass, enforced server-side at the point it's set, not
	-- read back out here.
	SkipGachaAnimationEnabled = false,
	-- Wall-clock seconds accumulated across past sessions; the current
	-- session's elapsed time is added on top at read time (see
	-- PlayerDataService.GetLiveTotalPlaySeconds) rather than kept live in this
	-- field, so a server crash only loses the current session, not history.
	TotalPlaySeconds = 0,
	-- Referral loop (see ReferralService). 0 means "no referrer" -- real
	-- Roblox UserIds are always positive, same 0-as-unset convention
	-- MonetizationService's GAMEPASS_IDS uses. Set once, the first time this
	-- player ever queues in a party alongside a veteran member, and never
	-- overwritten after that.
	ReferredByUserId = 0,
	-- Flips true the instant Wins + Losses first leaves 0 (see
	-- ReferralService.HandleFirstRealRace) -- guards the referral payout to
	-- exactly once per player.
	HasCompletedFirstRace = false,
}

-- Every default that is a TABLE has to be copied, not referenced.
--
-- This is the whole reason this function exists, and the bug it replaces was
-- live: the old code did `table.clone(DEFAULT_PROFILE)`, which is a SHALLOW
-- copy, and then filled missing keys with `profile[key] = value` straight off
-- the template. Both hand out the template's own tables.
--
-- So every player in a server who needed a default shared ONE OwnedTrails
-- array, one OwnedAbilities array, one OwnedEmotes array and one
-- ProcessedPurchaseIds set. Reproduced exactly: two fresh players join, Alice
-- buys a trail with Robux, and Bob owns it too -- as does everyone who joins
-- that server afterwards, because `table.insert` had mutated the template
-- itself. All of it then persisted to each player's own DataStore key.
--
-- It survived because it needs TWO players to show up, and Studio testing runs
-- one. That is precisely the class of bug worth a test rather than a comment.
local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, inner in value do
		copy[key] = deepCopy(inner)
	end
	return copy
end

ProfileSchema.DeepCopy = deepCopy

-- Turns a raw DataStore value (or nil, for a player with no save) into a
-- complete profile that shares nothing with the template or with any other
-- profile.
function ProfileSchema.New(data: any?): any
	-- Rebase pre-v2 saves onto the new scale BEFORE the default-fill below,
	-- which would otherwise stamp the current version onto a legacy profile and
	-- make it indistinguishable from an already-migrated one.
	--
	-- A flat shift rather than a rescale: it preserves every player's standing
	-- relative to each other exactly, and lands the old starting point (0) on
	-- the new one. Someone who had climbed to 300 keeps that 300 of progress.
	if data and data.EloScaleVersion == nil then
		data.Elo = math.max(0, tonumber(data.Elo) or 0) + Constants.Elo.StartingRating
		data.EloScaleVersion = ProfileSchema.EloScaleVersion
	end

	local profile = data or {}
	for key, value in ProfileSchema.Default do
		if profile[key] == nil then
			profile[key] = deepCopy(value)
		end
	end
	return profile
end

return ProfileSchema
