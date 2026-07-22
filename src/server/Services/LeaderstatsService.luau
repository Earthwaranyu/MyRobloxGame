local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local RankTiers = require(Shared.RankTiers)

local PlayerDataService = require(script.Parent.PlayerDataService)

-- Roblox's own built-in player list (Tab / Esc menu) reads whatever's under
-- a "leaderstats" Folder parented directly to the Player -- this is the only
-- stat display that's ALWAYS visible to every other player in the server
-- automatically, unlike the custom Leaderboard/Profile panels elsewhere in
-- this game, which are opt-in (someone has to click a button, or double-click
-- you, to see them).
local LeaderstatsService = {}

local function buildFolder(player: Player): Folder
	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"
	folder.Parent = player

	local rank = Instance.new("StringValue")
	rank.Name = "Rank"
	rank.Value = "..." -- placeholder until the profile finishes loading (see onPlayerAdded)
	rank.Parent = folder

	local wins = Instance.new("IntValue")
	wins.Name = "Wins"
	wins.Parent = folder

	local elo = Instance.new("IntValue")
	elo.Name = "Elo"
	elo.Parent = folder

	return folder
end

-- Pushes the player's CURRENT profile values into their leaderstats -- call
-- this any time Wins/Elo actually change, not just once at load. Elo changes
-- in EloService.ReportMatchResult, but Wins/Losses/WinStreak change
-- separately afterward in MatchService.settleWin, so this is called from
-- settleWin (once both are already final) rather than from EloService, to
-- avoid publishing a stale Wins count.
function LeaderstatsService.Refresh(player: Player)
	local folder = player:FindFirstChild("leaderstats")
	local profile = PlayerDataService.GetProfile(player)
	if not folder or not profile then
		return
	end

	local rank = folder:FindFirstChild("Rank") :: StringValue
	local wins = folder:FindFirstChild("Wins") :: IntValue
	local elo = folder:FindFirstChild("Elo") :: IntValue

	rank.Value = RankTiers.GetRankForElo(profile.Elo)
	wins.Value = profile.Wins
	elo.Value = profile.Elo
end

local function onPlayerAdded(player: Player)
	buildFolder(player)

	-- PlayerDataService.loadProfile is an async DataStore read, so the
	-- profile isn't necessarily ready yet on PlayerAdded -- same
	-- poll-until-ready pattern used by every other Service that needs a
	-- profile right after join (ShopService, OverheadDisplayService,
	-- DailyRewardService, TutorialService all do this identically; there's
	-- no load-complete signal to wait on instead).
	task.spawn(function()
		local attempts = 0
		while not PlayerDataService.GetProfile(player) and attempts < 100 do
			task.wait()
			attempts += 1
		end
		LeaderstatsService.Refresh(player)
	end)
end

function LeaderstatsService.Init()
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return LeaderstatsService
