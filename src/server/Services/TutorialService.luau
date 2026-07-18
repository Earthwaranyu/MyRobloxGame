local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local PlayerDataService = require(script.Parent.PlayerDataService)

-- Everything else in this game (matchmaking, sprint, emotes, quit-match,
-- rank/elo) is taught by nothing but a screenshot -- fine for a solo
-- playtester who already knows the plan, but a brand-new player dropped into
-- a lobby with a PLAY button, a VS BOTS button, a shop, a leaderboard and no
-- explanation at all is exactly the kind of friction that makes people leave
-- in the first 30 seconds. One dismissible welcome panel, shown exactly once
-- per account (tracked in the profile, same pattern as DailyRewardService),
-- costs nothing and directly targets new-player retention.
local TutorialService = {}

local tutorialRemote: RemoteEvent

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
	if not profile or profile.HasSeenTutorial then
		return
	end

	profile.HasSeenTutorial = true

	-- DailyRewardService also fires on this same PlayerAdded pass; a short
	-- beat lets that small popup show first instead of two panels landing on
	-- top of each other the instant a brand-new player spawns in.
	task.wait(2)
	if player.Parent then
		tutorialRemote:FireClient(player)
	end
end

function TutorialService.Init()
	tutorialRemote = Net.CreateRemoteEvent(RemoteNames.ShowTutorial)

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

return TutorialService
