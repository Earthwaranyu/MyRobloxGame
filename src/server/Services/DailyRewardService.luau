local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local MonetizationService = require(script.Parent.MonetizationService)
local PlayerDataService = require(script.Parent.PlayerDataService)

-- Classic retention loop: log in today, get a small bonus; log in again
-- tomorrow, get a bigger one. On Roblox specifically this matters beyond
-- just the player's own habit -- concurrent players and session frequency
-- feed straight into the discovery/recommendation algorithm, so anything
-- that reliably pulls people back tomorrow is also a growth lever today.
local DAILY_REWARD_CAP_DAYS = 7
local BASE_REWARD = 20
local REWARD_STEP = 15

local DailyRewardService = {}

local dailyRewardRemote: RemoteEvent

local function today(): string
	return os.date("!%Y-%m-%d")
end

local function yesterday(): string
	return os.date("!%Y-%m-%d", os.time() - 24 * 60 * 60)
end

-- Returns { Streak, Reward } if a reward was just granted, nil if today's
-- was already claimed (e.g. rejoining the same day).
local function applyDailyReward(player: Player, profile: { [string]: any }): { Streak: number, Reward: number }?
	local todayStr = today()
	if profile.LastLoginDate == todayStr then
		return nil
	end

	profile.DailyStreak = if profile.LastLoginDate == yesterday() then (profile.DailyStreak or 0) + 1 else 1
	profile.LastLoginDate = todayStr

	local cappedStreak = math.min(profile.DailyStreak, DAILY_REWARD_CAP_DAYS)
	local multiplier = if MonetizationService.HasVIP(player) then MonetizationService.PointsMultiplier else 1
	local reward = (BASE_REWARD + (cappedStreak - 1) * REWARD_STEP) * multiplier
	profile.Points += reward

	return { Streak = profile.DailyStreak, Reward = reward }
end

local function waitForProfile(player: Player)
	local attempts = 0
	while not PlayerDataService.GetProfile(player) and attempts < 100 and player.Parent do
		task.wait()
		attempts += 1
	end
	return PlayerDataService.GetProfile(player)
end

local function onPlayerAdded(player: Player)
	local profile = waitForProfile(player)
	if not profile then
		return
	end

	local reward = applyDailyReward(player, profile)
	if reward then
		dailyRewardRemote:FireClient(player, reward)
	end
end

function DailyRewardService.Init()
	dailyRewardRemote = Net.CreateRemoteEvent(RemoteNames.DailyReward)

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

return DailyRewardService
