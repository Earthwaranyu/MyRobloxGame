local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Constants = require(Shared.Constants)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Stages = require(Shared.Stages)

local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local Sounds = require(script.Parent.Parent.Sounds)

-- CS:GO-style case-opening reel: server rolls the stage and tells us
-- immediately (MapSelected), but we don't reveal it right away. Instead we
-- build a long strip of stage cards, put the real answer at a fixed index
-- near the end, and tween the strip so that card ends up under the center
-- marker right as the countdown reaches 0.
local MapRevealController = {}

local player = Players.LocalPlayer

local CARD_WIDTH = 160
local CARD_HEIGHT = 100
local CARD_GAP = 14
local STEP = CARD_WIDTH + CARD_GAP
local TOTAL_CARDS = 32
local WINNING_INDEX = 27
local WINDOW_WIDTH = 560
local WINDOW_HEIGHT = 120

local CARD_COLOR_POOL = { Theme.Color.AccentA, Theme.Color.Warning, Theme.Color.Success, Theme.Color.Danger, Theme.Color.AccentB }

local overlay: CanvasGroup
local backdrop: Frame
local window: Frame
local reel: Frame

local stageEntries: { { Id: string, Name: string, Color: Color3 } } = {}
local pendingStageId: string? = nil
local spinning = false

local function getStageEntry(stageId: string)
	for _, entry in stageEntries do
		if entry.Id == stageId then
			return entry
		end
	end
	return nil
end

local function buildCard(entry: { Id: string, Name: string, Color: Color3 }, layoutOrder: number): Frame
	local card = Instance.new("Frame")
	card.Size = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT)
	card.Position = UDim2.fromOffset((layoutOrder - 1) * STEP, (WINDOW_HEIGHT - CARD_HEIGHT) / 2)
	card.BackgroundColor3 = Theme.Color.PanelLight
	card.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = card

	local stroke = Instance.new("UIStroke")
	stroke.Color = entry.Color
	stroke.Thickness = 2
	stroke.Transparency = 0.15
	stroke.Parent = card

	local bar = Instance.new("Frame")
	bar.Size = UDim2.new(1, 0, 0, 6)
	bar.BackgroundColor3 = entry.Color
	bar.BorderSizePixel = 0
	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(0, 10)
	barCorner.Parent = bar
	bar.Parent = card

	local label = Widgets.Label(entry.Name, UDim2.new(1, -12, 1, -18), UDim2.fromOffset(6, 14), {
		Font = Theme.Font.Heading,
		TextSize = 22,
		Align = Enum.TextXAlignment.Center,
	})
	label.Parent = card

	return card
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "MapRevealGui"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 8
	screenGui.Parent = player:WaitForChild("PlayerGui")

	backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
	backdrop.BackgroundTransparency = 0.45
	backdrop.BorderSizePixel = 0
	backdrop.Visible = false
	backdrop.Parent = screenGui

	local overlayWidth = WINDOW_WIDTH + 40
	overlay = Widgets.Panel(UDim2.fromOffset(overlayWidth, WINDOW_HEIGHT + 70), UDim2.new(0.5, -overlayWidth / 2, 0.28, 0))
	overlay.Parent = screenGui

	local title = Widgets.Label("SELECTING MAP", UDim2.new(1, -20, 0, 24), UDim2.fromOffset(10, 8), {
		TextSize = 16,
		Color = Theme.Color.TextSecondary,
		Align = Enum.TextXAlignment.Center,
	})
	title.Parent = overlay

	window = Instance.new("Frame")
	window.Name = "Window"
	window.Size = UDim2.fromOffset(WINDOW_WIDTH, WINDOW_HEIGHT)
	window.Position = UDim2.new(0.5, -WINDOW_WIDTH / 2, 0, 36)
	window.BackgroundTransparency = 1
	window.ClipsDescendants = true
	window.Parent = overlay

	local marker = Instance.new("Frame")
	marker.Name = "Marker"
	marker.Size = UDim2.new(0, 4, 1, 8)
	marker.Position = UDim2.new(0.5, -2, 0, -4)
	marker.BackgroundColor3 = Theme.Color.Warning
	marker.BorderSizePixel = 0
	marker.ZIndex = 5
	marker.Parent = window

	reel = Instance.new("Frame")
	reel.Name = "Reel"
	reel.Size = UDim2.fromOffset(TOTAL_CARDS * STEP, WINDOW_HEIGHT)
	reel.BackgroundTransparency = 1
	reel.Parent = window
end

-- Plays a burst of ticks that slow down over the spin duration, roughly
-- tracking the tween's ease-out curve, for a CS:GO-style spinning feel.
local function playSpinTicks(duration: number)
	task.spawn(function()
		local elapsed = 0
		while elapsed < duration and spinning do
			local t = elapsed / duration
			local interval = 0.05 + 0.35 * t * t
			Sounds.Play("Tick")
			task.wait(interval)
			elapsed += interval
		end
	end)
end

local function startSpin()
	if spinning or not pendingStageId then
		return
	end
	local winningEntry = getStageEntry(pendingStageId)
	if not winningEntry then
		return
	end
	spinning = true

	for _, child in reel:GetChildren() do
		child:Destroy()
	end

	for i = 1, TOTAL_CARDS do
		local entry = if i == WINNING_INDEX then winningEntry else stageEntries[math.random(1, #stageEntries)]
		buildCard(entry, i).Parent = reel
	end

	local duration = Constants.Match.MapRevealSeconds
	local targetX = WINDOW_WIDTH / 2 - ((WINNING_INDEX - 1) * STEP + CARD_WIDTH / 2)
	reel.Position = UDim2.fromOffset(0, 0)

	backdrop.Visible = true
	Widgets.Open(overlay)
	playSpinTicks(duration)

	local tween = TweenService:Create(reel, TweenInfo.new(duration, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
		Position = UDim2.fromOffset(targetX, 0),
	})
	tween:Play()

	-- Guaranteed settle + close regardless of whether the tween itself
	-- reports completion (see Widgets.Open/Close for why that can't be
	-- assumed under heavy frame-scheduling load).
	task.delay(duration, function()
		reel.Position = UDim2.fromOffset(targetX, 0)
		Sounds.Play("Reveal")
	end)

	task.delay(duration + 0.6, function()
		Widgets.Close(overlay)
		backdrop.Visible = false
		spinning = false
	end)
end

function MapRevealController.Init()
	for i, stage in Stages do
		table.insert(stageEntries, {
			Id = stage.Id,
			Name = stage.Name,
			Color = CARD_COLOR_POOL[(i - 1) % #CARD_COLOR_POOL + 1],
		})
	end

	buildUI()

	local mapRemote = Net.GetRemoteEvent(RemoteNames.MapSelected)
	mapRemote.OnClientEvent:Connect(function(stageId: string)
		pendingStageId = stageId
	end)

	local queueRemote = Net.GetRemoteEvent(RemoteNames.QueueStatusChanged)
	queueRemote.OnClientEvent:Connect(function(secondsRemaining: number?)
		if not secondsRemaining then
			return
		end

		local spinDelay = math.max(0, secondsRemaining - Constants.Match.MapRevealSeconds)
		task.delay(spinDelay, startSpin)
	end)
end

return MapRevealController
