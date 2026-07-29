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

-- Board geometry, named because the row height is DERIVED from it rather than
-- being its own magic number. A fixed row height only ever fits one particular
-- TOP_COUNT: raising this to 15 would have silently pushed the bottom rows off
-- the board with no error, the same way a fixed tab width hid Stage 4 on the
-- leaderboard panel and a fixed 60px row hid the eighth rank tier.
local BOARD_SIZE = Vector3.new(10, 12, 1)
local PIXELS_PER_STUD = 50
local HEADER_HEIGHT = 70
local LIST_INSET = 12
local ROW_PADDING = 4

local function rowHeight(): number
	local listHeight = BOARD_SIZE.Y * PIXELS_PER_STUD - HEADER_HEIGHT - LIST_INSET * 2
	return math.floor((listHeight - ROW_PADDING * (TOP_COUNT - 1)) / TOP_COUNT)
end
-- GetSortedAsync reads have a much tighter budget than the SetAsync writes
-- SubmitElo does per match-end (see LeaderboardService), so the board
-- refreshes on its own modest timer instead of re-querying every time
-- anyone's Elo changes.
local REFRESH_INTERVAL = 90


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
	-- it again once BOARD_NAME exists.
	--
	-- Ten studs in front of spawn, right of the walkway, paired with the rank
	-- board on the left. This is the FIRST thing on the walk out of spawn --
	-- the rooms now sit past the trophy (see QueueStationService), so a player
	-- reads who is winning and what the ranks mean before choosing a race.
	--
	-- X=+-20 specifically: verified against every straight walk from spawn to
	-- each of the five room doorways, and it is the closest pair to the
	-- walkway that none of them passes through.
	local anchor = Workspace:FindFirstChild("SpawnLocation")
	local basePosition = Vector3.new(20, 8, 30)
	if anchor and anchor:IsA("BasePart") then
		basePosition = anchor.Position + Vector3.new(20, 6, -10)
	end

	-- Faces +Z, back toward spawn, so it is readable head-on as you walk out.
	-- The 180-degree turn is load-bearing: NormalId.Front is the part's LOCAL
	-- -Z face (verified in Studio via Vector3.fromNormalId), so an unrotated
	-- board points its display AWAY from spawn and shows players nothing but a
	-- blank black slab. An earlier comment here claimed Front was +Z and
	-- skipped the rotation, which is exactly how that happened.
	local displayRotation = CFrame.Angles(0, math.rad(180), 0)

	local part = Instance.new("Part")
	part.Name = BOARD_NAME
	part.Anchored = true
	-- Non-collidable -- this is a display, not an obstacle; a mispositioned
	-- board (see above) should never be able to physically block a player.
	part.CanCollide = false
	part.Size = BOARD_SIZE
	part.CFrame = CFrame.new(basePosition) * displayRotation
	part.Color = Color3.fromRGB(20, 21, 30)
	part.Material = Enum.Material.SmoothPlastic
	part.Parent = Workspace

	local surfaceGui = Instance.new("SurfaceGui")
	surfaceGui.Name = "Display"
	surfaceGui.Face = Enum.NormalId.Front
	surfaceGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surfaceGui.PixelsPerStud = PIXELS_PER_STUD
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
	list.Size = UDim2.new(1, -LIST_INSET * 2, 1, -(HEADER_HEIGHT + LIST_INSET * 2))
	list.Position = UDim2.fromOffset(LIST_INSET, HEADER_HEIGHT + LIST_INSET)
	list.BackgroundTransparency = 1
	list.Parent = surfaceGui

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, ROW_PADDING)
	layout.Parent = list

	for i = 1, TOP_COUNT do
		local row = Instance.new("Frame")
		row.Name = "Row" .. i
		row.LayoutOrder = i
		row.Size = UDim2.new(1, 0, 0, rowHeight())
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
