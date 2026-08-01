local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Constants = require(Shared.Constants)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Stages = require(Shared.Stages)

local Responsive = require(script.Parent.Parent.Responsive)
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
local TOTAL_CARDS = 32
local WINNING_INDEX = 27
local WINDOW_WIDTH = 560
local WINDOW_HEIGHT = 120
local OVERLAY_MARGIN = 40
local TITLE_TOP = 8
local WINDOW_TOP = 36

-- Live metrics for the current viewport, kept in one table because the reel's
-- landing position is derived from ALL of them at once -- targetX is a function
-- of Step, CardWidth and WindowWidth together, and a spin that mixes scaled and
-- unscaled values stops under the wrong card, which is the one failure this
-- animation cannot have. Recomputed by relayout().
local M = {
	CardWidth = CARD_WIDTH,
	CardHeight = CARD_HEIGHT,
	Step = CARD_WIDTH + CARD_GAP,
	WindowWidth = WINDOW_WIDTH,
	WindowHeight = WINDOW_HEIGHT,
}

local CARD_COLOR_POOL = { Theme.Color.AccentA, Theme.Color.Warning, Theme.Color.Success, Theme.Color.Danger, Theme.Color.AccentB }

local DIFFICULTY_COLOR = {
	Easy = Theme.Color.Success,
	Medium = Theme.Color.Warning,
	Hard = Theme.Color.Danger,
}

local overlay: CanvasGroup
local backdrop: Frame
local window: Frame
local reel: Frame

local stageEntries: { { Id: string, Name: string, Color: Color3, Difficulty: string } } = {}
local pendingStageId: string? = nil
local spinning = false
-- Bumped by every queue-status update. A spin is scheduled up to a full wave
-- ahead, so it has to be able to tell "still the booking I was made for" from
-- "superseded" when it finally fires. See the QueueStatusChanged handler.
local spinGeneration = 0

local function getStageEntry(stageId: string)
	for _, entry in stageEntries do
		if entry.Id == stageId then
			return entry
		end
	end
	return nil
end

local function buildCard(entry: { Id: string, Name: string, Color: Color3, Difficulty: string }, layoutOrder: number): Frame
	local px, tx = Responsive.Px, Responsive.Text

	local card = Instance.new("Frame")
	card.Size = UDim2.fromOffset(M.CardWidth, M.CardHeight)
	card.Position = UDim2.fromOffset((layoutOrder - 1) * M.Step, (M.WindowHeight - M.CardHeight) / 2)
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
	bar.Size = UDim2.new(1, 0, 0, px(6))
	bar.BackgroundColor3 = entry.Color
	bar.BorderSizePixel = 0
	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(0, 10)
	barCorner.Parent = bar
	bar.Parent = card

	local label = Widgets.Label(entry.Name, UDim2.new(1, -px(12), 0, px(46)), UDim2.fromOffset(px(6), px(16)), {
		Font = Theme.Font.Heading,
		TextSize = tx(22),
		Align = Enum.TextXAlignment.Center,
	})
	label.Parent = card

	local difficultyLabel = Widgets.Label(entry.Difficulty:upper(), UDim2.new(1, -px(12), 0, px(18)), UDim2.fromOffset(px(6), px(66)), {
		Font = Theme.Font.Body,
		TextSize = tx(13),
		Align = Enum.TextXAlignment.Center,
		Color = DIFFICULTY_COLOR[entry.Difficulty] or Theme.Color.TextSecondary,
	})
	difficultyLabel.Parent = card

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

	local overlayWidth = WINDOW_WIDTH + OVERLAY_MARGIN
	overlay = Widgets.Panel(
		UDim2.fromOffset(overlayWidth, WINDOW_HEIGHT + 70),
		UDim2.new(0.5, -overlayWidth / 2, 0.28, 0)
	)
	overlay.Parent = screenGui

	local title = Widgets.Label("SELECTING MAP", UDim2.new(1, -20, 0, 24), UDim2.fromOffset(10, TITLE_TOP), {
		TextSize = 16,
		Color = Theme.Color.TextSecondary,
		Align = Enum.TextXAlignment.Center,
	})
	title.Parent = overlay

	window = Instance.new("Frame")
	window.Name = "Window"
	window.Size = UDim2.fromOffset(WINDOW_WIDTH, WINDOW_HEIGHT)
	window.Position = UDim2.new(0.5, -WINDOW_WIDTH / 2, 0, WINDOW_TOP)
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
	reel.Size = UDim2.fromOffset(TOTAL_CARDS * M.Step, WINDOW_HEIGHT)
	reel.BackgroundTransparency = 1
	reel.Parent = window

	-- The reel window is 560 wide at reference and the panel around it 600, which
	-- is nearly a phone's whole viewport in landscape -- and unlike most panels
	-- this one is not something you can dismiss and come back to, it plays once
	-- while the race is being decided.
	--
	-- Skipped while a spin is in flight. Every card's position and the tween's
	-- landing point are computed from M together; changing M underneath a running
	-- tween would leave the strip stopping under the wrong card, which is worse
	-- than a reel that finishes at the previous size. A rotation mid-reveal is
	-- rare, and the next spin picks up the new numbers.
	local function relayout()
		if spinning then
			return
		end
		local px = Responsive.Px
		M.CardWidth = px(CARD_WIDTH)
		M.CardHeight = px(CARD_HEIGHT)
		M.Step = px(CARD_WIDTH + CARD_GAP)
		M.WindowWidth = px(WINDOW_WIDTH)
		M.WindowHeight = px(WINDOW_HEIGHT)

		local panelWidth = M.WindowWidth + px(OVERLAY_MARGIN)
		overlay.Size = UDim2.fromOffset(panelWidth, M.WindowHeight + px(70))
		overlay.Position = UDim2.new(0.5, -panelWidth / 2, 0.28, 0)

		title.Size = UDim2.new(1, -px(20), 0, px(24))
		title.Position = UDim2.fromOffset(px(10), px(TITLE_TOP))
		title.TextSize = Responsive.Text(16)

		window.Size = UDim2.fromOffset(M.WindowWidth, M.WindowHeight)
		window.Position = UDim2.new(0.5, -M.WindowWidth / 2, 0, px(WINDOW_TOP))

		marker.Size = UDim2.new(0, px(4), 1, px(8))
		marker.Position = UDim2.new(0.5, -px(4) / 2, 0, -px(4))

		reel.Size = UDim2.fromOffset(TOTAL_CARDS * M.Step, M.WindowHeight)
	end
	Responsive.Observe(relayout)
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

-- Incremented by every spin AND every abort, so the deferred settle/close
-- callbacks below can tell whether they still belong to the spin on screen.
-- Without it, cancelling a spin and immediately starting a real one would let
-- the dead spin's close timer shut the live reel mid-animation.
local spinRun = 0

-- Ends a spin that turned out to have no departure behind it. Safe to call when
-- nothing is spinning.
local function abortSpin()
	if not spinning then
		return
	end
	spinning = false
	spinRun += 1
	Widgets.Close(overlay)
	backdrop.Visible = false
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
	spinRun += 1
	local run = spinRun

	for _, child in reel:GetChildren() do
		child:Destroy()
	end

	for i = 1, TOTAL_CARDS do
		local entry = if i == WINNING_INDEX then winningEntry else stageEntries[math.random(1, #stageEntries)]
		buildCard(entry, i).Parent = reel
	end

	local duration = Constants.Match.MapRevealSeconds
	-- All four terms come from M, so the winning card lands dead under the marker
	-- at any scale. Mixing a scaled Step with an unscaled WindowWidth here would
	-- stop the reel a card or two off.
	local targetX = M.WindowWidth / 2 - ((WINNING_INDEX - 1) * M.Step + M.CardWidth / 2)
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
		if run ~= spinRun then
			return
		end
		reel.Position = UDim2.fromOffset(targetX, 0)
		Sounds.Play("Reveal")
	end)

	task.delay(duration + Constants.Match.MapRevealHoldSeconds, function()
		if run ~= spinRun then
			return
		end
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
			Difficulty = stage.Difficulty,
		})
	end

	buildUI()

	local mapRemote = Net.GetRemoteEvent(RemoteNames.MapSelected)
	mapRemote.OnClientEvent:Connect(function(stageId: string)
		pendingStageId = stageId
	end)

	local queueRemote = Net.GetRemoteEvent(RemoteNames.QueueStatusChanged)
	queueRemote.OnClientEvent:Connect(function(secondsRemaining: (number | boolean)?)
		-- Every status supersedes whatever was scheduled before it. A spin is
		-- booked a whole wave ahead, and plenty can happen in between -- most
		-- often the wave hitting zero WITHOUT enough players and being skipped,
		-- which fires `true` here. Before this, that pending spin still fired:
		-- the reel span up, landed on a map, and nothing happened, because
		-- there was no departure behind it.
		spinGeneration += 1
		local generation = spinGeneration

		-- `true` means "queued, but MatchService.Constants.Match.MinPlayers
		-- hasn't been met yet" (see QueueStatusController) -- the wave reached
		-- zero without enough players and isn't going. A spin in flight is for a
		-- race that will never happen, so close it.
		if secondsRemaining == true then
			abortSpin()
			return
		end

		-- nil is the OPPOSITE case and must not abort. The server sends it at
		-- the moment the race actually starts, so a running spin here is the
		-- successful reveal, mid-flight -- cutting it made the map card vanish
		-- exactly as the player was teleported, which is the one moment the
		-- reveal exists to cover. (It also arrives on a manual cancel, where the
		-- spin simply closes itself a moment later on its own timer.)
		if typeof(secondsRemaining) ~= "number" then
			return
		end

		-- The reel starts when the countdown hits ZERO and runs for
		-- MapRevealSeconds after it, landing exactly as the group is
		-- teleported (MatchService waits for both before teleporting).
		--
		-- It used to start MapRevealSeconds BEFORE zero so the two overlapped
		-- inside one flat window, which meant the countdown number stopped at
		-- 3 and disappeared -- indistinguishable from the timer breaking.
		task.delay(math.max(0, secondsRemaining), function()
			-- Anything newer than this booking wins -- see the generation bump
			-- above.
			if generation ~= spinGeneration then
				return
			end
			startSpin()
		end)
	end)
end

return MapRevealController
