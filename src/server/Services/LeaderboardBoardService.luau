local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local RankTiers = require(Shared.RankTiers)

local LeaderboardService = require(script.Parent.LeaderboardService)

-- A physical, always-visible "who's the best" board in the game world --
-- unlike the click-to-open Leaderboard panel (per-stage best times) or the
-- Tab-menu leaderstats (each player's OWN Rank/Wins/Elo, one row per
-- currently-connected player), this is ONE shared object every player in the
-- server can just walk up and read, showing the top players globally by Elo
-- (across everyone who's ever played, online or not).
local LeaderboardBoardService = {}

local BOARD_NAME = "GlobalLeaderboardBoard"
local TOP_COUNT = 10
-- GetSortedAsync reads have a much tighter budget than the SetAsync writes
-- SubmitElo does per match-end (see LeaderboardService), so the board
-- refreshes on its own modest timer instead of re-querying every time
-- anyone's Elo changes.
local REFRESH_INTERVAL = 90

local ROW_HEIGHT = 34

-- Built once via Instance.new (same "server builds it at runtime" idiom
-- OverheadDisplayService already uses for the overhead BillboardGui) rather
-- than requiring it to be hand-placed in Studio first -- Workspace isn't
-- Rojo-synced in this project, so this is the only way the board is
-- guaranteed to exist without a manual placement step first. Idempotent: if
-- it already exists (e.g. someone in Studio has since repositioned/resized
-- it and saved the place), that instance is reused as-is rather than
-- clobbered with a fresh one at the default spot.
local function buildBoard(): BasePart
	local existing = Workspace:FindFirstChild(BOARD_NAME)
	if existing and existing:IsA("BasePart") then
		return existing
	end

	-- Default spot only matters for the very first time this ever runs --
	-- move/rotate it in Studio afterward and save; this function won't touch
	-- it again once BOARD_NAME exists. Offset to the SIDE of spawn (not
	-- straight ahead of it) since spawn->stage is a walking path -- confirmed
	-- live that a straight-ahead placement sits right on top of it.
	local anchor = Workspace:FindFirstChild("SpawnLocation")
	local basePosition = Vector3.new(14, 5, 0)
	if anchor and anchor:IsA("BasePart") then
		basePosition = anchor.Position + Vector3.new(14, 6, -4)
	end

	local part = Instance.new("Part")
	part.Name = BOARD_NAME
	part.Anchored = true
	-- Non-collidable -- this is a display, not an obstacle; a mispositioned
	-- board (see above) should never be able to physically block a player.
	part.CanCollide = false
	part.Size = Vector3.new(10, 12, 1)
	part.Position = basePosition
	part.Color = Color3.fromRGB(20, 21, 30)
	part.Material = Enum.Material.SmoothPlastic
	part.Parent = Workspace

	local surfaceGui = Instance.new("SurfaceGui")
	surfaceGui.Name = "Display"
	surfaceGui.Face = Enum.NormalId.Front
	surfaceGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surfaceGui.PixelsPerStud = 50
	surfaceGui.LightInfluence = 0
	surfaceGui.Parent = part

	local ribbon = Instance.new("Frame")
	ribbon.Name = "Ribbon"
	ribbon.Size = UDim2.new(1, 0, 0, 70)
	ribbon.BackgroundColor3 = Color3.fromRGB(255, 205, 60)
	ribbon.BorderSizePixel = 0
	ribbon.Parent = surfaceGui

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.fromScale(1, 1)
	title.BackgroundTransparency = 1
	title.Text = "TOP PLAYERS"
	title.TextColor3 = Color3.fromRGB(40, 32, 28)
	title.Font = Enum.Font.GothamBlack
	title.TextScaled = true
	title.Parent = ribbon

	local list = Instance.new("Frame")
	list.Name = "List"
	list.Size = UDim2.new(1, -24, 1, -82)
	list.Position = UDim2.fromOffset(12, 78)
	list.BackgroundTransparency = 1
	list.Parent = surfaceGui

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = list

	for i = 1, TOP_COUNT do
		local row = Instance.new("Frame")
		row.Name = "Row" .. i
		row.LayoutOrder = i
		row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
		row.BackgroundColor3 = Color3.fromRGB(34, 36, 50)
		row.BackgroundTransparency = 0.15
		row.BorderSizePixel = 0
		row.Parent = list

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = row

		local rankLabel = Instance.new("TextLabel")
		rankLabel.Name = "Rank"
		rankLabel.Size = UDim2.new(0, 50, 1, 0)
		rankLabel.BackgroundTransparency = 1
		rankLabel.Text = "#" .. i
		rankLabel.TextColor3 = Color3.fromRGB(180, 182, 200)
		rankLabel.Font = Enum.Font.GothamBold
		rankLabel.TextScaled = true
		rankLabel.Parent = row

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Name = "PlayerName"
		nameLabel.Size = UDim2.new(1, -220, 1, 0)
		nameLabel.Position = UDim2.fromOffset(56, 0)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Text = "--"
		nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.Font = Enum.Font.GothamBold
		nameLabel.TextScaled = true
		nameLabel.Parent = row

		local eloLabel = Instance.new("TextLabel")
		eloLabel.Name = "Elo"
		eloLabel.Size = UDim2.new(0, 160, 1, 0)
		eloLabel.Position = UDim2.new(1, -160, 0, 0)
		eloLabel.BackgroundTransparency = 1
		eloLabel.Text = ""
		eloLabel.TextColor3 = Color3.fromRGB(200, 200, 210)
		eloLabel.TextXAlignment = Enum.TextXAlignment.Right
		eloLabel.Font = Enum.Font.Gotham
		eloLabel.TextScaled = true
		eloLabel.Parent = row
	end

	return part
end

local function refresh()
	local board = buildBoard()
	local surfaceGui = board:FindFirstChild("Display")
	local list = surfaceGui and surfaceGui:FindFirstChild("List")
	if not list then
		return
	end

	local entries = LeaderboardService.GetTopElo(TOP_COUNT)

	for i = 1, TOP_COUNT do
		local row = list:FindFirstChild("Row" .. i)
		if not row then
			continue
		end
		local entry = entries[i]
		local nameLabel = row:FindFirstChild("PlayerName") :: TextLabel
		local eloLabel = row:FindFirstChild("Elo") :: TextLabel

		if entry then
			nameLabel.Text = entry.Name
			eloLabel.Text = ("%s · %d"):format(RankTiers.GetRankForElo(entry.Elo), entry.Elo)
			eloLabel.TextColor3 = RankTiers.GetColorForElo(entry.Elo)
		else
			nameLabel.Text = "--"
			eloLabel.Text = ""
		end
	end
end

function LeaderboardBoardService.Init()
	buildBoard() -- exists immediately, even before the first refresh tick below

	task.spawn(function()
		while true do
			refresh()
			task.wait(REFRESH_INTERVAL)
		end
	end)
end

return LeaderboardBoardService
