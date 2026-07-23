local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local MonetizationService = require(script.Parent.MonetizationService)
local PlayerDataService = require(script.Parent.PlayerDataService)

-- Referral loop: bring a friend into your PARTY -- the one place the game can
-- actually verify "these two chose to play together", since Roblox's native
-- SocialService invite prompt (see InviteFriendsController) gives game code
-- no attribution back for who invited whom -- and race a REAL match together.
-- The instant that friend finishes their very first ranked race or duel
-- (win or lose), both sides get paid. Gated on an actual completed race
-- (not just joining the party) so this can't be farmed by repeatedly
-- inviting-then-cancelling, and gated on the referrer already having a real
-- race under their own belt (see TagPartyReferral) so two brand-new alts
-- can't "refer" each other in a circle.
local ReferralService = {}

local WELCOME_BONUS_POINTS = 200
local REFERRAL_REWARD_POINTS = 300

local referralRewardRemote: RemoteEvent

-- Called from MatchService.Enqueue for every party of 2+ right as it's added
-- to the shared queue. Tags at most one referrer per newcomer (the first
-- veteran party member seen) and never overwrites an existing tag -- first
-- party a newcomer ever queues with wins the credit, so later queuing
-- alongside a DIFFERENT veteran can't steal or re-tag it.
function ReferralService.TagPartyReferral(partyMembers: { Player })
	if #partyMembers < 2 then
		return
	end

	local veteran: Player? = nil
	local newcomers: { Player } = {}
	for _, member in partyMembers do
		local profile = PlayerDataService.GetProfile(member)
		if profile then
			if profile.Wins + profile.Losses > 0 then
				veteran = veteran or member
			elseif profile.ReferredByUserId == 0 then
				table.insert(newcomers, member)
			end
		end
	end

	if not veteran then
		return
	end

	for _, newcomer in newcomers do
		local profile = PlayerDataService.GetProfile(newcomer)
		if profile then
			profile.ReferredByUserId = (veteran :: Player).UserId
		end
	end
end

-- Called from MatchService.settleWin for BOTH the winner and every opponent
-- of a real (points-and-Elo-stakes) race/duel, right where Wins/Losses is
-- finalized -- the one place "Wins + Losses" transitions away from 0, i.e.
-- this player's first real race ever. HasCompletedFirstRace guards the payout
-- to exactly once so a player's second real race never double-pays.
function ReferralService.HandleFirstRealRace(player: Player, profile: { [string]: any })
	if profile.HasCompletedFirstRace then
		return
	end
	profile.HasCompletedFirstRace = true

	local referrerUserId = profile.ReferredByUserId
	if referrerUserId == 0 then
		return
	end

	local newcomerMultiplier = if MonetizationService.HasVIP(player) then MonetizationService.PointsMultiplier else 1
	local newcomerReward = WELCOME_BONUS_POINTS * newcomerMultiplier
	profile.Points += newcomerReward
	referralRewardRemote:FireClient(player, { Role = "New", Reward = newcomerReward })

	local referrer = Players:GetPlayerByUserId(referrerUserId)
	if not referrer then
		return
	end
	local referrerProfile = PlayerDataService.GetProfile(referrer)
	if not referrerProfile then
		return
	end

	local referrerMultiplier = if MonetizationService.HasVIP(referrer) then MonetizationService.PointsMultiplier else 1
	local referrerReward = REFERRAL_REWARD_POINTS * referrerMultiplier
	referrerProfile.Points += referrerReward
	referralRewardRemote:FireClient(referrer, { Role = "Veteran", FriendName = player.Name, Reward = referrerReward })
end

function ReferralService.Init()
	referralRewardRemote = Net.CreateRemoteEvent(RemoteNames.ReferralReward)
end

return ReferralService
