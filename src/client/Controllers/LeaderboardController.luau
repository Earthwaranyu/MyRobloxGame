local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Stages = require(Shared.Stages)

local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)

local LeaderboardController = {}

local player = Players.LocalPlayer

local panel: CanvasGroup
local openPanel: () -> ()
local closePanel: () -> ()
local entriesList: ScrollingFrame
local tabSetters: { [string]: (boolean) -> () } = {}
local scopeSetters: { [string]: (boolean) -> () } = {}

local selectedStageId = Stages[1].Id
local selectedScope = "Global" -- "Global" | "Friends"

local MEDAL_COLOR = {
	[1] = Color3.fromRGB(255, 209, 102),
	[2] = Color3.fromRGB(210, 214, 222),
	[3] = Color3.fromRGB(205, 127, 80),
}

local function formatTime(ms: number): string
	local totalSeconds = ms / 1000
	local minutes = math.floor(totalSeconds / 60)
	local seconds = totalSeconds - minutes * 60
	return ("%d:%05.2f"):format(minutes, seconds)
end

local function buildEntryRow(entry): Frame
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 34)
	row.BackgroundColor3 = if entry.Rank <= 3 then Theme.Color.PanelLight else Theme.Color.Panel
	row.BackgroundTransparency = if entry.Rank % 2 == 0 then 0 else 0.25
	row.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = row

	if MEDAL_COLOR[entry.Rank] then
		local stroke = Instance.new("UIStroke")
		stroke.Color = MEDAL_COLOR[entry.Rank]
		stroke.Thickness = 1.5
		stroke.Transparency = 0.25
		stroke.Parent = row
	end

	local rankLabel = Widgets.Label(("#%d"):format(entry.Rank), UDim2.new(0, 40, 1, 0), UDim2.fromOffset(10, 0), {
		TextSize = 15,
		Color = MEDAL_COLOR[entry.Rank] or Theme.Color.TextSecondary,
	})
	rankLabel.Parent = row

	local nameLabel = Widgets.Label(tostring(entry.Name), UDim2.new(0.5, -50, 1, 0), UDim2.fromOffset(50, 0), {
		TextSize = 15,
	})
	nameLabel.Parent = row

	local timeLabel = Widgets.Label(formatTime(entry.TimeMs), UDim2.new(0.4, -10, 1, 0), UDim2.fromScale(0.6, 0), {
		TextSize = 15,
		Align = Enum.TextXAlignment.Right,
		Color = Theme.Color.TextSecondary,
	})
	timeLabel.Parent = row

	return row
end

local function refreshTabHighlight()
	for stageId, setActive in tabSetters do
		setActive(stageId == selectedStageId)
	end
end

local function refreshScopeHighlight()
	for scope, setActive in scopeSetters do
		setActive(scope == selectedScope)
	end
end

function LeaderboardController.Refresh()
	local friendsOnly = selectedScope == "Friends"
	local entries = Net.GetRemoteFunction(RemoteNames.GetLeaderboard):InvokeServer(selectedStageId, friendsOnly)

	for _, child in entriesList:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end

	if #entries == 0 then
		local emptyText = if friendsOnly
			then "None of your friends have a time here yet."
			else "No times recorded yet."
		local emptyLabel = Widgets.Label(emptyText, UDim2.new(1, -16, 0, 32), UDim2.fromOffset(8, 0), {
			Color = Theme.Color.TextMuted,
			Bold = false,
		})
		emptyLabel.Parent = entriesList
		return
	end

	for _, entry in entries do
		local row = buildEntryRow(entry)
		row.LayoutOrder = entry.Rank
		row.Parent = entriesList
	end
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "LeaderboardGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	-- y = 60 clears Roblox's default top bar (chat/leaderboard/settings icons).
	-- Bigger than it looks like it needs to be: small buttons (~38px tall)
	-- rendered blurry/illegible in testing regardless of color/stroke tweaks
	-- -- confirmed empirically that a taller button + bigger text is what
	-- actually fixes it, not further contrast changes.
	local toggleButton = Widgets.Button("Leaderboard", UDim2.fromOffset(220, 48), UDim2.fromOffset(10, 60))
	toggleButton.Parent = screenGui

	-- Own ScreenGui + backdrop + close-X (see Widgets.Modal) rather than a
	-- bare Widgets.Panel only closable via this one toggle button.
	panel, openPanel, closePanel = Widgets.Modal("Leaderboard", UDim2.fromOffset(360, 454), UDim2.fromOffset(10, 116), {
		DisplayOrder = 30,
	})

	local ribbon = Widgets.Ribbon("LEADERBOARD", UDim2.fromOffset(230, 40), UDim2.new(0.5, 0, 0, -20))
	ribbon.Parent = panel

	-- y=44, not 36 -- the Stage tab row used to start early enough (36) to
	-- graze the bottom-left corner of Widgets.Modal's close-✕ (which spans
	-- 10-42 here), confirmed by an AbsolutePosition/AbsoluteSize scan: the
	-- rightmost tab's top-right corner overlapped the button's bottom-left
	-- by a real 32x6px, not just a harmless bounding-box graze like most of
	-- that scan's other (false-positive) hits.
	local tabRow = Instance.new("Frame")
	tabRow.Size = UDim2.new(1, -16, 0, 30)
	tabRow.Position = UDim2.fromOffset(8, 44)
	tabRow.BackgroundTransparency = 1
	tabRow.Parent = panel

	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.Padding = UDim.new(0, 6)
	tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabLayout.Parent = tabRow

	for i, stage in Stages do
		local tabButton, setActive = Widgets.Button(stage.Name, UDim2.fromOffset(110, 30), UDim2.fromOffset(0, 0), {
			Variant = "Tab",
			TextSize = 15,
		})
		tabButton.Name = "Tab_" .. stage.Id
		tabButton.LayoutOrder = i
		tabButton.Parent = tabRow
		tabSetters[stage.Id] = setActive

		tabButton.MouseButton1Click:Connect(function()
			selectedStageId = stage.Id
			refreshTabHighlight()
			LeaderboardController.Refresh()
		end)
	end
	refreshTabHighlight()

	local scopeRow = Instance.new("Frame")
	scopeRow.Size = UDim2.new(1, -16, 0, 26)
	scopeRow.Position = UDim2.fromOffset(8, 78)
	scopeRow.BackgroundTransparency = 1
	scopeRow.Parent = panel

	local scopeLayout = Instance.new("UIListLayout")
	scopeLayout.FillDirection = Enum.FillDirection.Horizontal
	scopeLayout.Padding = UDim.new(0, 6)
	scopeLayout.SortOrder = Enum.SortOrder.LayoutOrder
	scopeLayout.Parent = scopeRow

	for i, scope in { "Global", "Friends" } do
		local scopeButton, setActive = Widgets.Button(scope, UDim2.fromOffset(90, 26), UDim2.fromOffset(0, 0), {
			Variant = "Tab",
			TextSize = 13,
		})
		scopeButton.LayoutOrder = i
		scopeButton.Parent = scopeRow
		scopeSetters[scope] = setActive

		scopeButton.MouseButton1Click:Connect(function()
			selectedScope = scope
			refreshScopeHighlight()
			LeaderboardController.Refresh()
		end)
	end
	refreshScopeHighlight()

	entriesList = Instance.new("ScrollingFrame")
	entriesList.Size = UDim2.new(1, -16, 1, -116)
	entriesList.Position = UDim2.fromOffset(8, 108)
	entriesList.BackgroundTransparency = 1
	entriesList.BorderSizePixel = 0
	entriesList.CanvasSize = UDim2.new(0, 0, 0, 0)
	entriesList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	entriesList.ScrollBarThickness = 5
	entriesList.ScrollBarImageColor3 = Theme.Color.AccentA
	entriesList.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = entriesList

	toggleButton.MouseButton1Click:Connect(function()
		if panel.Visible then
			closePanel()
		else
			openPanel()
			LeaderboardController.Refresh()
		end
	end)
end

function LeaderboardController.Init()
	buildUI()
end

return LeaderboardController
