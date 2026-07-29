local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Constants = require(Shared.Constants)
local RankTiers = require(Shared.RankTiers)

-- "What Elo do I need for the next rank?" answered in the world, on a board
-- standing beside the global leaderboard so the two read as a pair: that one
-- is who is winning, this one is what the ranks actually mean.
--
-- Elo and rank are shown everywhere in this game -- overhead nameplates, the
-- stats pill, profile cards, the outcome panel -- but the THRESHOLDS were
-- nowhere in the experience at all. A player could see "Bronze 180 elo" all
-- session with no way to learn what Bronze is, or how far Silver is, short of
-- reaching it by accident.
--
-- Every row is generated from RankTiers.Tiers, so this board can never drift
-- out of sync with the values the game actually ranks by -- retune the tiers
-- and the board retunes itself on the next server start, with no edit here.
local RankBoardService = {}

local BOARD_NAME = "RankRequirementBoard"

-- Board geometry, named because the row height is DERIVED from it rather than
-- being its own magic number. A fixed 60px row fitted the seven tiers that
-- happened to exist when this was written and silently overflowed the eighth
-- (adding Iron needed 522px of a 518px list) -- which is exactly the drift the
-- comment above promises can't happen. Rows now divide whatever space there is.
local BOARD_SIZE = Vector3.new(10, 12, 1)
local PIXELS_PER_STUD = 50
local HEADER_HEIGHT = 70
local LIST_INSET = 12
local ROW_PADDING = 6

local function rowHeight(): number
	local listHeight = BOARD_SIZE.Y * PIXELS_PER_STUD - HEADER_HEIGHT - LIST_INSET * 2
	local count = #RankTiers.Tiers
	return math.floor((listHeight - ROW_PADDING * (count - 1)) / count)
end

-- Built at runtime for the same reason LeaderboardBoardService is: Workspace
-- isn't Rojo-synced in this project, so this is the only way the board is
-- guaranteed to exist without a manual placement step. Idempotent -- if it
-- already exists (someone repositioned it in Studio and saved), that instance
-- is left exactly as-is rather than clobbered back to the default spot.
local function buildBoard()
	local existing = Workspace:FindFirstChild(BOARD_NAME)
	if existing then
		return
	end

	-- Mirrors GlobalLeaderboardBoard across the walkway: same height, same Z,
	-- opposite X. The pair stands ten studs in front of spawn, before the
	-- trophy and well before the room doorways, so both are read on the way
	-- out rather than discovered afterwards.
	local anchor = Workspace:FindFirstChild("SpawnLocation")
	local basePosition = Vector3.new(-20, 8, 30)
	if anchor and anchor:IsA("BasePart") then
		basePosition = anchor.Position + Vector3.new(-20, 6, -10)
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
	-- A display, not an obstacle -- same reasoning as the leaderboard board.
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
	ribbon.Size = UDim2.new(1, 0, 0, HEADER_HEIGHT)
	ribbon.BackgroundColor3 = Color3.fromRGB(255, 205, 60)
	ribbon.BorderSizePixel = 0
	ribbon.Parent = surfaceGui

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.fromScale(1, 1)
	title.BackgroundTransparency = 1
	title.Text = "RANKS"
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

	for index, tier in RankTiers.Tiers do
		local row = Instance.new("Frame")
		row.Name = tier.Name
		row.LayoutOrder = index
		row.Size = UDim2.new(1, 0, 0, rowHeight())
		row.BackgroundColor3 = Color3.fromRGB(34, 36, 50)
		row.BackgroundTransparency = 0.15
		row.BorderSizePixel = 0
		row.Parent = list

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = row

		-- The tier's own colour, so the board matches the colour players
		-- already see on nameplates and profile cards rather than teaching a
		-- second, conflicting visual language for the same seven ranks.
		local swatch = Instance.new("Frame")
		swatch.Name = "Swatch"
		swatch.Size = UDim2.new(0, 8, 1, -16)
		swatch.Position = UDim2.fromOffset(10, 8)
		swatch.BackgroundColor3 = tier.Color
		swatch.BorderSizePixel = 0
		local swatchCorner = Instance.new("UICorner")
		swatchCorner.CornerRadius = UDim.new(1, 0)
		swatchCorner.Parent = swatch
		swatch.Parent = row

		-- -220, not -190: the requirement label starts at (1, -180), so -190
		-- left the two frames overlapping by 20px. TextScaled fills whatever
		-- frame it's given, so "Grandmaster" -- the longest name by four
		-- characters -- ran straight into "3000+ elo".
		local nameLabel = Instance.new("TextLabel")
		nameLabel.Name = "RankName"
		nameLabel.Size = UDim2.new(1, -220, 1, 0)
		nameLabel.Position = UDim2.fromOffset(30, 0)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Text = tier.Name
		nameLabel.TextColor3 = tier.Color
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.Font = Enum.Font.GothamBold
		nameLabel.TextScaled = true
		-- Without a cap, TextScaled sizes each row independently: "Bronze"
		-- renders huge and "Grandmaster" small, so the column looks ragged.
		-- Capping means every row shares one size until a name is genuinely
		-- too long to fit, and only that row shrinks.
		local nameSizeCap = Instance.new("UITextSizeConstraint")
		nameSizeCap.MaxTextSize = 30
		nameSizeCap.Parent = nameLabel
		nameLabel.Parent = row

		-- The tier players actually START in is marked as such rather than
		-- showing a threshold, which would imply something to earn your way to.
		-- Keyed off StartingRating, not off the bottom of the table: players
		-- begin mid-ladder now, so the lowest tier is somewhere you FALL to and
		-- wants its real threshold shown like any other.
		local eloLabel = Instance.new("TextLabel")
		eloLabel.Name = "Requirement"
		eloLabel.Size = UDim2.new(0, 170, 1, 0)
		eloLabel.Position = UDim2.new(1, -180, 0, 0)
		eloLabel.BackgroundTransparency = 1
		eloLabel.Text = if tier.Name == RankTiers.GetRankForElo(Constants.Elo.StartingRating)
			then "START"
			else ("%d+ elo"):format(tier.MinElo)
		eloLabel.TextColor3 = Color3.fromRGB(200, 200, 210)
		eloLabel.TextXAlignment = Enum.TextXAlignment.Right
		eloLabel.Font = Enum.Font.Gotham
		eloLabel.TextScaled = true
		local eloSizeCap = Instance.new("UITextSizeConstraint")
		eloSizeCap.MaxTextSize = 26
		eloSizeCap.Parent = eloLabel
		eloLabel.Parent = row
	end
end

function RankBoardService.Init()
	buildBoard()
end

return RankBoardService
