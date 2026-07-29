local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local QueueModes = require(Shared.QueueModes)
local RemoteNames = require(Shared.RemoteNames)

local RacerCrowd = require(script.Parent.Parent.RacerCrowd)
local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local Sounds = require(script.Parent.Parent.Sounds)

-- The play menu: pick a race size instead of only ever taking whatever the
-- shared queue gives you.
--
-- Card-led rather than a list of buttons, following the standard mode-select
-- shape (artwork owns most of the card, label sits along the bottom). The
-- artwork is the point: the number of runners drawn behind each card says how
-- big that race is faster than any label does, so the picker can be read at a
-- glance before a single word is processed.
--
-- Every card feeds a queue that ALREADY EXISTS -- the physical station pads in
-- the lobby use exactly the same per-size queues (see QueueModes.Stations). This
-- is a second door onto them for players who never walk over to the pads, not a
-- parallel matchmaking system.
local PlayModePickerController = {}

local CARD_WIDTH = 148
local CARD_HEIGHT = 196
local CARD_GAP = 12
local PAD = 22
local HEADER = 62

-- Quick Play first and visually distinct: it's the one that always fills,
-- because it takes any size. An exact-size card on a quiet server can wait a
-- long time, so the fast option has to be the obvious default rather than
-- something buried at the end of the row.
local CARDS = {
	{ Target = QueueModes.AnySize, Count = 3, Title = "QUICK PLAY", Blurb = "Any size", Palette = Theme.Candy.Gold, Best = true },
	{ Target = 2, Count = 2, Title = "1 v 1", Blurb = "Duel", Palette = Theme.Candy.Pink },
	{ Target = 3, Count = 3, Title = "3 PLAYERS", Blurb = "Small pack", Palette = Theme.Candy.Teal },
	{ Target = 4, Count = 4, Title = "4 PLAYERS", Blurb = "Full grid", Palette = Theme.Candy.Blue },
	{ Target = 5, Count = 5, Title = "5 PLAYERS", Blurb = "Big race", Palette = Theme.Candy.Green },
}

local PANEL_WIDTH = PAD * 2 + #CARDS * CARD_WIDTH + (#CARDS - 1) * CARD_GAP
local PANEL_HEIGHT = HEADER + CARD_HEIGHT + PAD * 2

local panel: CanvasGroup
local openModal: () -> ()
local closeModal: () -> ()
local onChosen: ((number) -> ())? = nil

-- target -> the card's second line, which shows flavour text when nobody is
-- waiting and the live queue count when somebody is.
local blurbLabels: { [number]: TextLabel } = {}
local blurbText: { [number]: string } = {}
-- Keyed by tostring(target) -- see the broadcast in MatchService for why the
-- wire format can't use the raw numbers.
local queueCounts: { [string]: number } = {}

local IDLE_COLOR = Color3.fromRGB(240, 236, 255)
local WAITING_COLOR = Color3.fromRGB(255, 240, 150)

-- Deliberately reuses the blurb's line rather than adding a third one.
--
-- The card is already carrying a title and a picture; a permanent "0 / 2
-- waiting" on every card would be four lines of furniture saying nothing most
-- of the time. Showing it only when someone is actually queued means the line
-- changing IS the signal -- and it swaps to a warm colour, so a size that's one
-- player short pulls the eye instead of having to be hunted for.
local function refreshCounts()
	for target, label in blurbLabels do
		local count = queueCounts[tostring(target)] or 0
		if count <= 0 then
			label.Text = blurbText[target]
			label.TextColor3 = IDLE_COLOR
		elseif target == QueueModes.AnySize then
			label.Text = if count == 1 then "1 waiting" else ("%d waiting"):format(count)
			label.TextColor3 = WAITING_COLOR
		else
			label.Text = ("%d / %d waiting"):format(count, target)
			label.TextColor3 = WAITING_COLOR
		end
	end
end

-- Builds one card: artwork, a scrim so the label stays readable over it, the
-- title, and a full-card button on top.
local function buildCard(spec, index: number)
	local x = PAD + (index - 1) * (CARD_WIDTH + CARD_GAP)

	local card = Instance.new("Frame")
	card.Name = spec.Title
	card.Size = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT)
	card.Position = UDim2.fromOffset(x, HEADER)
	card.BackgroundColor3 = spec.Palette.Shadow
	card.BorderSizePixel = 0
	card.ClipsDescendants = true
	card.Parent = panel

	local corner = Instance.new("UICorner")
	corner.CornerRadius = Theme.Corner.Card
	corner.Parent = card

	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Candy.Border
	stroke.Thickness = 3
	stroke.Parent = card

	-- Vertical gradient on the face rather than a flat fill: it gives the card
	-- a light source and stops five saturated rectangles side by side from
	-- reading as flat swatches.
	local face = Instance.new("Frame")
	face.Name = "Face"
	face.Size = UDim2.fromScale(1, 1)
	face.BackgroundColor3 = spec.Palette.Face
	face.BorderSizePixel = 0
	face.Parent = card

	local faceCorner = Instance.new("UICorner")
	faceCorner.CornerRadius = Theme.Corner.Card
	faceCorner.Parent = face

	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new(spec.Palette.Face, spec.Palette.Shadow)
	gradient.Parent = face

	-- The artwork. Sits high in the card so the runners aren't cropped by the
	-- label band along the bottom.
	local art = Instance.new("Frame")
	art.Name = "Art"
	art.Size = UDim2.fromOffset(CARD_WIDTH - 12, CARD_WIDTH - 12)
	art.Position = UDim2.fromOffset(6, 14)
	art.BackgroundTransparency = 1
	art.Parent = face
	RacerCrowd.Populate(art, spec.Count, Color3.fromRGB(255, 255, 255))

	-- Darkened band behind the text. Without it the title fights the runners'
	-- legs for the same pixels and both lose.
	local band = Instance.new("Frame")
	band.Name = "Band"
	band.AnchorPoint = Vector2.new(0, 1)
	band.Position = UDim2.fromScale(0, 1)
	band.Size = UDim2.new(1, 0, 0, 58)
	band.BackgroundColor3 = spec.Palette.Shadow
	band.BackgroundTransparency = 0.15
	band.BorderSizePixel = 0
	band.Parent = face

	local title = Widgets.Label(spec.Title, UDim2.new(1, -10, 0, 24), UDim2.fromOffset(5, CARD_HEIGHT - 52), {
		Font = Theme.Font.Display,
		TextSize = 19,
		Align = Enum.TextXAlignment.Center,
		Color = Color3.fromRGB(255, 255, 255),
	})
	title.Parent = face

	local blurb = Widgets.Label(spec.Blurb, UDim2.new(1, -10, 0, 18), UDim2.fromOffset(5, CARD_HEIGHT - 28), {
		Font = Theme.Font.Body,
		TextSize = 14,
		Align = Enum.TextXAlignment.Center,
		Color = Color3.fromRGB(240, 236, 255),
	})
	blurb.Parent = face
	blurbLabels[spec.Target] = blurb
	blurbText[spec.Target] = spec.Blurb

	if spec.Best then
		-- One card gets a flag, because "any size" is otherwise indistinguishable
		-- from the numbered options at a glance despite behaving differently.
		local flag = Instance.new("Frame")
		flag.Name = "Flag"
		flag.AnchorPoint = Vector2.new(0.5, 0)
		flag.Position = UDim2.new(0.5, 0, 0, -2)
		flag.Size = UDim2.fromOffset(96, 22)
		flag.BackgroundColor3 = Theme.Candy.Red.Face
		flag.BorderSizePixel = 0
		flag.Parent = face

		local flagCorner = Instance.new("UICorner")
		flagCorner.CornerRadius = UDim.new(0, 8)
		flagCorner.Parent = flag

		local flagLabel = Widgets.Label("FASTEST", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), {
			Font = Theme.Font.Display,
			TextSize = 12,
			Align = Enum.TextXAlignment.Center,
			Color = Color3.fromRGB(255, 255, 255),
		})
		flagLabel.Parent = flag
	end

	-- The whole card is the button. A small button inside a big picture invites
	-- people to click the picture and have nothing happen.
	local hit = Instance.new("TextButton")
	hit.Name = "Hit"
	hit.Size = UDim2.fromScale(1, 1)
	hit.BackgroundTransparency = 1
	hit.Text = ""
	hit.AutoButtonColor = false
	hit.Parent = card

	local scale = Instance.new("UIScale")
	scale.Parent = card

	hit.MouseEnter:Connect(function()
		TweenService:Create(scale, Theme.Anim.Ease, { Scale = 1.05 }):Play()
		TweenService:Create(stroke, Theme.Anim.Ease, { Thickness = 5 }):Play()
	end)
	hit.MouseLeave:Connect(function()
		TweenService:Create(scale, Theme.Anim.Ease, { Scale = 1 }):Play()
		TweenService:Create(stroke, Theme.Anim.Ease, { Thickness = 3 }):Play()
	end)
	hit.MouseButton1Click:Connect(function()
		Sounds.Play("Click")
		closeModal()
		if onChosen then
			onChosen(spec.Target)
		end
	end)

	return card
end

local function buildUI()
	local screenGui
	panel, openModal, closeModal, _, screenGui = Widgets.Modal(
		"PlayModePicker",
		UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT),
		UDim2.new(0.5, -PANEL_WIDTH / 2, 0.5, -PANEL_HEIGHT / 2),
		{ DisplayOrder = 26 }
	)
	screenGui.Name = "PlayModePickerGui"

	local heading = Widgets.Ribbon("CHOOSE YOUR RACE", UDim2.fromOffset(300, 44), UDim2.new(0.5, 0, 0, -16))
	heading.Parent = panel

	for index, spec in CARDS do
		buildCard(spec, index)
	end
end

-- Opens the picker. `callback` receives the chosen target: an exact race size,
-- or QueueModes.AnySize for Quick Play.
function PlayModePickerController.Open(callback: (number) -> ())
	onChosen = callback
	openModal()
end

function PlayModePickerController.Init()
	buildUI()

	Net.GetRemoteEvent(RemoteNames.QueueCounts).OnClientEvent:Connect(function(counts: { [string]: number })
		queueCounts = counts or {}
		refreshCounts()
	end)
	refreshCounts()
end

return PlayModePickerController
