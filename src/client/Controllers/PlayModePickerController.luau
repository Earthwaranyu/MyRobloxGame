local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local QueueModes = require(Shared.QueueModes)
local RemoteNames = require(Shared.RemoteNames)

local RacerCrowd = require(script.Parent.Parent.RacerCrowd)
local Responsive = require(script.Parent.Parent.Responsive)
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
-- The card treatment is claymorphic -- a saturated face, a COLOURED drop shadow
-- rather than a black one, and a bright inner highlight along the top edge.
-- Colour-matched shadows are what make cards read as solid objects sitting above
-- the panel instead of rectangles printed on it; a grey shadow under a pink card
-- just looks like dirt. Every layer is Frames and gradients, so there is still
-- nothing downloaded and nothing that can infringe.
--
-- Every card feeds a queue that ALREADY EXISTS -- the physical station pads in
-- the lobby use exactly the same per-size queues (see QueueModes.Stations). This
-- is a second door onto them for players who never walk over to the pads, not a
-- parallel matchmaking system.
local PlayModePickerController = {}

local CARD_WIDTH = 148
local CARD_HEIGHT = 196
local CARD_GAP = 14
local PAD = 24
local HEADER = 66
-- How far the card floats above its own shadow. Small, but it is the whole
-- difference between "object sitting on the panel" and "flat sticker".
local SHADOW_DROP = 7
local HOVER_LIFT = 8

-- Quick Play first and visually distinct: it's the one that always fills,
-- because it takes any size. An exact-size card on a quiet server can wait a
-- long time, so the fast option has to be the obvious default rather than
-- something buried at the end of the row.
local CARDS = {
	{
		Target = QueueModes.AnySize,
		Count = 3,
		Title = "QUICK PLAY",
		Blurb = "Any size",
		Palette = Theme.Candy.Gold,
		Best = true,
	},
	{ Target = 2, Count = 2, Title = "1 v 1", Blurb = "Duel", Palette = Theme.Candy.Pink },
	{ Target = 3, Count = 3, Title = "3 PLAYERS", Blurb = "Small pack", Palette = Theme.Candy.Teal },
	{ Target = 4, Count = 4, Title = "4 PLAYERS", Blurb = "Full grid", Palette = Theme.Candy.Blue },
	{ Target = 5, Count = 5, Title = "5 PLAYERS", Blurb = "Big race", Palette = Theme.Candy.Green },
}

local HEADING_WIDTH, HEADING_HEIGHT = 320, 46

-- Live metrics, recomputed from the viewport by relayout() below and read by
-- buildCard. Everything inside a card is measured off CardWidth/CardHeight, so
-- these two are all that has to change for the whole card to scale.
--
-- WHY THIS PANEL IS THE HARD ONE: five 148-wide cards plus gaps and padding is
-- 844 points across at reference, wider than a phone's entire viewport in
-- landscape, and this is the only panel in the game whose SIZE comes from its
-- own content rather than from Responsive.PlacePanel -- so nothing clamps it and
-- it has to get its own reflow right. See the column rule in relayout(): the row
-- wraps only when it genuinely cannot fit across, because on a phone in
-- landscape height is the scarce axis and every wrap costs a whole row.
local M = {
	CardWidth = CARD_WIDTH,
	CardHeight = CARD_HEIGHT,
	CardGap = CARD_GAP,
	Pad = PAD,
	Header = HEADER,
	ShadowDrop = SHADOW_DROP,
	HoverLift = HOVER_LIFT,
	Columns = #CARDS,
	PanelWidth = PAD * 2 + #CARDS * CARD_WIDTH + (#CARDS - 1) * CARD_GAP,
	PanelHeight = HEADER + CARD_HEIGHT + SHADOW_DROP + PAD * 2,
}

-- Where card `index` sits, in panel coordinates, for the current column count.
local function cardOrigin(index: number): (number, number)
	local column = (index - 1) % M.Columns
	local row = math.floor((index - 1) / M.Columns)
	return M.Pad + column * (M.CardWidth + M.CardGap), M.Header + row * (M.CardHeight + M.ShadowDrop + M.CardGap)
end

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
-- Card holders in row order, for the staggered entrance.
local holders: { Frame } = {}

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

local function rounded(parent: Instance, name: string, zIndex: number, radius: UDim?): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BorderSizePixel = 0
	f.ZIndex = zIndex
	f.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = radius or Theme.Corner.Card
	corner.Parent = f
	return f
end

local function buildCard(spec, index: number)
	local x, y = cardOrigin(index)
	-- Shorthands: every literal below is a reference-size offset, and the card is
	-- rebuilt (not tweened) when the viewport changes, so applying the scale here
	-- at build time is enough -- see relayout().
	local px, tx = Responsive.Px, Responsive.Text

	-- The holder carries position and hover motion; the card inside never moves
	-- on its own. Keeping them separate is what lets the shadow sit OUTSIDE the
	-- card's clipping mask -- otherwise there can be no drop shadow at all.
	local holder = Instance.new("Frame")
	holder.Name = spec.Title
	holder.Size = UDim2.fromOffset(M.CardWidth, M.CardHeight)
	holder.Position = UDim2.fromOffset(x, y)
	holder.BackgroundTransparency = 1
	holder.Parent = panel

	local holderScale = Instance.new("UIScale")
	holderScale.Parent = holder

	-- Claymorphic drop shadow: the card's OWN dark tone, not black, offset
	-- straight down and inset slightly so it reads as contact shadow rather than
	-- a second card peeking out from behind.
	local shadow = rounded(holder, "Shadow", 0)
	shadow.Size = UDim2.new(1, -px(6), 1, 0)
	shadow.Position = UDim2.fromOffset(px(3), M.ShadowDrop)
	shadow.BackgroundColor3 = spec.Palette.Shadow
	shadow.BackgroundTransparency = 0.35

	local card = rounded(holder, "Card", 1)
	card.Size = UDim2.fromScale(1, 1)
	card.BackgroundColor3 = spec.Palette.Face
	card.ClipsDescendants = true

	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Candy.Border
	stroke.Thickness = 3
	stroke.Parent = card

	-- Light at the top, the palette's own shadow at the bottom. Gives the card a
	-- light source, so five saturated rectangles side by side stop reading as
	-- flat swatches.
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, spec.Palette.Face:Lerp(Color3.new(1, 1, 1), 0.25)),
		ColorSequenceKeypoint.new(0.55, spec.Palette.Face),
		ColorSequenceKeypoint.new(1, spec.Palette.Shadow),
	})
	gradient.Parent = card

	-- Soft pool of light behind the runners. An ellipse with a transparency
	-- gradient rather than a true radial -- close enough at this size, and it
	-- lifts the figures off the face instead of leaving them sitting flat.
	local spotlight = rounded(card, "Spotlight", 2, UDim.new(1, 0))
	spotlight.AnchorPoint = Vector2.new(0.5, 0.5)
	spotlight.Position = UDim2.fromOffset(M.CardWidth / 2, px(84))
	spotlight.Size = UDim2.fromOffset(M.CardWidth + px(20), px(110))
	spotlight.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	local spotGradient = Instance.new("UIGradient")
	spotGradient.Rotation = 90
	spotGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0.82),
		NumberSequenceKeypoint.new(1, 1),
	})
	spotGradient.Parent = spotlight

	-- The headcount as a big ghosted numeral behind everything: a second,
	-- instant read at a distance where the runners blur together, and it fills
	-- what was otherwise dead space in the upper corner.
	local watermark = Instance.new("TextLabel")
	watermark.Name = "Watermark"
	watermark.BackgroundTransparency = 1
	watermark.Size = UDim2.fromOffset(px(96), px(96))
	watermark.Position = UDim2.fromOffset(M.CardWidth - px(72), -px(14))
	watermark.Font = Theme.Font.Display
	watermark.Text = if spec.Target == QueueModes.AnySize then "?" else tostring(spec.Target)
	watermark.TextSize = tx(86)
	watermark.TextColor3 = Color3.fromRGB(255, 255, 255)
	watermark.TextTransparency = 0.86
	watermark.ZIndex = 3
	watermark.Parent = card

	-- Contact shadow under the pack, so the runners stand on something.
	local ground = rounded(card, "Ground", 4, UDim.new(1, 0))
	ground.AnchorPoint = Vector2.new(0.5, 0.5)
	ground.Position = UDim2.fromOffset(M.CardWidth / 2, px(118))
	ground.Size = UDim2.fromOffset(M.CardWidth - px(34), px(16))
	ground.BackgroundColor3 = spec.Palette.Shadow
	ground.BackgroundTransparency = 0.45

	local art = Instance.new("Frame")
	art.Name = "Art"
	art.Size = UDim2.fromOffset(M.CardWidth - px(12), M.CardWidth - px(12))
	art.Position = UDim2.fromOffset(px(6), px(14))
	art.BackgroundTransparency = 1
	art.ZIndex = 5
	art.Parent = card
	RacerCrowd.Populate(art, spec.Count, Color3.fromRGB(255, 255, 255))
	-- Every limb inherits the artwork's layer, so the figures sit above the
	-- spotlight and watermark but below the label band.
	for _, d in art:GetDescendants() do
		if d:IsA("Frame") then
			d.ZIndex = 5
		end
	end

	-- Label band, fading UP into the artwork rather than cutting across it with
	-- a hard edge -- that hard edge was the most obviously unfinished part of
	-- the first version.
	local band = Instance.new("Frame")
	band.Name = "Band"
	band.AnchorPoint = Vector2.new(0, 1)
	band.Position = UDim2.fromScale(0, 1)
	band.Size = UDim2.new(1, 0, 0, px(78))
	band.BackgroundColor3 = spec.Palette.Shadow
	band.BorderSizePixel = 0
	band.ZIndex = 6
	band.Parent = card
	local bandGradient = Instance.new("UIGradient")
	bandGradient.Rotation = 90
	bandGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.45, 0.25),
		NumberSequenceKeypoint.new(1, 0.05),
	})
	bandGradient.Parent = band

	local title =
		Widgets.Label(spec.Title, UDim2.new(1, -px(10), 0, px(24)), UDim2.fromOffset(px(5), M.CardHeight - px(54)), {
			Font = Theme.Font.Display,
			TextSize = tx(19),
			Align = Enum.TextXAlignment.Center,
			Color = Color3.fromRGB(255, 255, 255),
		})
	title.ZIndex = 7
	title.TextStrokeColor3 = Theme.Candy.TextOutline
	title.TextStrokeTransparency = 0.4
	title.Parent = card

	local blurb =
		Widgets.Label(spec.Blurb, UDim2.new(1, -px(10), 0, px(18)), UDim2.fromOffset(px(5), M.CardHeight - px(30)), {
			Font = Theme.Font.Body,
			TextSize = tx(14),
			Align = Enum.TextXAlignment.Center,
			Color = IDLE_COLOR,
		})
	blurb.ZIndex = 7
	blurb.Parent = card
	blurbLabels[spec.Target] = blurb
	blurbText[spec.Target] = spec.Blurb

	-- Inner highlight along the top edge -- the "bright rim" half of the clay
	-- look. Without it the card's top edge and its white border merge into one
	-- flat line and the whole thing deflates.
	local rim = rounded(card, "Rim", 8, UDim.new(0, 10))
	rim.Size = UDim2.new(1, -px(16), 0, px(5))
	rim.Position = UDim2.fromOffset(px(8), px(5))
	rim.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	rim.BackgroundTransparency = 0.62

	-- Diagonal gloss sweep across the upper corner, clipped by the card so it
	-- reads as light falling on a surface rather than as a stripe.
	local gloss = Instance.new("Frame")
	gloss.Name = "Gloss"
	gloss.AnchorPoint = Vector2.new(0.5, 0.5)
	gloss.Position = UDim2.fromOffset(px(22), px(34))
	gloss.Size = UDim2.fromOffset(px(58), px(240))
	gloss.Rotation = 28
	gloss.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	gloss.BorderSizePixel = 0
	gloss.ZIndex = 9
	gloss.Parent = card
	local glossGradient = Instance.new("UIGradient")
	glossGradient.Rotation = 90
	glossGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0.88),
		NumberSequenceKeypoint.new(1, 1),
	})
	glossGradient.Parent = gloss

	if spec.Best then
		-- One card gets a flag, because "any size" is otherwise indistinguishable
		-- from the numbered options at a glance despite behaving differently.
		local flag = rounded(card, "Flag", 10, UDim.new(0, 8))
		flag.AnchorPoint = Vector2.new(0.5, 0)
		flag.Position = UDim2.fromScale(0.5, 0)
		flag.Size = UDim2.fromOffset(px(98), px(24))
		flag.BackgroundColor3 = Theme.Candy.Red.Face

		local flagStroke = Instance.new("UIStroke")
		flagStroke.Color = Theme.Candy.Border
		flagStroke.Thickness = 2
		flagStroke.Parent = flag

		local flagLabel = Widgets.Label("FASTEST", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), {
			Font = Theme.Font.Display,
			TextSize = tx(12),
			Align = Enum.TextXAlignment.Center,
			Color = Color3.fromRGB(255, 255, 255),
		})
		flagLabel.ZIndex = 11
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
	hit.ZIndex = 20
	hit.Parent = holder

	-- Hover lifts the card AND drops its shadow further away. Moving both is
	-- what sells it as height rather than as the card simply getting bigger.
	hit.MouseEnter:Connect(function()
		TweenService:Create(holderScale, Theme.Anim.Ease, { Scale = 1.06 }):Play()
		TweenService:Create(holder, Theme.Anim.Ease, { Position = UDim2.fromOffset(x, y - M.HoverLift) }):Play()
		TweenService:Create(shadow, Theme.Anim.Ease, {
			Position = UDim2.fromOffset(px(3), M.ShadowDrop + M.HoverLift),
			BackgroundTransparency = 0.2,
		}):Play()
		TweenService:Create(stroke, Theme.Anim.Ease, { Thickness = 5 }):Play()
	end)
	hit.MouseLeave:Connect(function()
		TweenService:Create(holderScale, Theme.Anim.Ease, { Scale = 1 }):Play()
		TweenService:Create(holder, Theme.Anim.Ease, { Position = UDim2.fromOffset(x, y) }):Play()
		TweenService:Create(shadow, Theme.Anim.Ease, {
			Position = UDim2.fromOffset(px(3), M.ShadowDrop),
			BackgroundTransparency = 0.35,
		}):Play()
		TweenService:Create(stroke, Theme.Anim.Ease, { Thickness = 3 }):Play()
	end)
	hit.MouseButton1Click:Connect(function()
		Sounds.Play("Click")
		closeModal()
		if onChosen then
			onChosen(spec.Target)
		end
	end)

	holders[index] = holder
	return holder
end

local function buildUI()
	local screenGui
	panel, openModal, closeModal, _, screenGui = Widgets.Modal(
		"PlayModePicker",
		UDim2.fromOffset(M.PanelWidth, M.PanelHeight),
		UDim2.new(0.5, -M.PanelWidth / 2, 0.5, -M.PanelHeight / 2),
		{ DisplayOrder = 26 }
	)
	screenGui.Name = "PlayModePickerGui"

	local heading = Widgets.Ribbon(
		"CHOOSE YOUR RACE",
		UDim2.fromOffset(HEADING_WIDTH, HEADING_HEIGHT),
		UDim2.new(0.5, 0, 0, -HEADING_HEIGHT / 2)
	)
	heading.ZIndex = 30
	heading.Parent = panel

	-- Cards are REBUILT rather than re-measured on a viewport change.
	--
	-- A card is ~20 nested frames whose every offset is derived from CardWidth,
	-- so a relayout pass would be a second, parallel copy of buildCard that has
	-- to be kept in step with it -- the exact duplication that put the lane's
	-- numbers out of sync in the first place. Rebuilding keeps one description of
	-- what a card is. It costs a few frames on an event that fires when a player
	-- rotates their phone or drags a window, and never during a race.
	local function relayout()
		local px = Responsive.Px
		M.CardWidth = px(CARD_WIDTH)
		M.CardHeight = px(CARD_HEIGHT)
		M.CardGap = px(CARD_GAP)
		M.Pad = px(PAD)
		-- The header band has to clear the modal's close ✕ with real air, not by a
		-- pixel. The ✕ is anchored 10pt inside the panel's top-right corner and is
		-- Tap(34) tall -- 44 on touch, not the 34 the reference header was drawn
		-- against -- so at the scale floor Px(66) is only 48 and the ✕ reached 6pt
		-- PAST the header, onto the top-right corner of the last card.
		--
		-- The margin passed here is the panel's own PAD rather than a token 8:
		-- clearing by 2pt is arithmetically correct and still reads as the button
		-- sitting on the card, because the ✕ is a circle whose corner comes closer
		-- than its bounding box does. Widgets.ModalContentTop is the same "start
		-- below the chrome" figure every other modal in the game uses.
		M.Header = math.max(px(HEADER), Widgets.ModalContentTop(px(PAD)))
		M.ShadowDrop = px(SHADOW_DROP)
		M.HoverLift = px(HOVER_LIFT)
		-- As many columns as the viewport is actually wide enough for, most first.
		--
		-- NOT "three on a phone", which is what this used to say. Wrapping to
		-- fewer columns buys no card width whatsoever -- CardWidth is Px(CARD_WIDTH)
		-- regardless of how many columns there are -- so all a wrap does is add a
		-- ROW. Measured on the shape a phone actually reports in landscape
		-- (801x334): three columns put the panel at 384pt tall against 334pt of
		-- screen, cutting 25pt off the top and 25 off the bottom and taking the
		-- hanging heading entirely off-screen, while five columns fit across in
		-- 609 of the 785 available and need only one row.
		--
		-- Height is the scarce axis on a phone in landscape, and MORE columns is
		-- what buys it. Fewer columns only ever earns its keep when the row
		-- genuinely does not fit across, which is what this loop tests.
		local maxWidth = Responsive.ViewportSize().X - Responsive.ScreenMargin * 2
		M.Columns = 1
		for columns = #CARDS, 1, -1 do
			if M.Pad * 2 + columns * M.CardWidth + (columns - 1) * M.CardGap <= maxWidth then
				M.Columns = columns
				break
			end
		end

		local rows = math.ceil(#CARDS / M.Columns)
		-- Everything in the card band that is NOT card: the gaps between rows and
		-- the shadow the bottom row floats above.
		local bandExtras = (rows - 1) * (M.ShadowDrop + M.CardGap) + M.ShadowDrop
		local function measure()
			M.PanelWidth = M.Pad * 2 + M.Columns * M.CardWidth + (M.Columns - 1) * M.CardGap
			M.PanelHeight = M.Header + rows * M.CardHeight + bandExtras + M.Pad * 2
		end
		measure()

		local headingHeight = px(HEADING_HEIGHT)
		local viewport = Responsive.ViewportSize()

		-- When the grid still does not fit, the CARDS shrink.
		--
		-- Nothing else can give: the column count is already capped by the width,
		-- so a narrow, tall screen genuinely needs three rows of card. Measured at
		-- 320x568 -- two columns, three rows -- that came to 570pt against 568 of
		-- screen. Shrinking is safe because every offset inside a card is derived
		-- from CardWidth/CardHeight (see buildCard), and the cards are rebuilt from
		-- scratch on every layout pass anyway.
		local available = viewport.Y - Responsive.ScreenMargin * 2 - math.ceil(headingHeight / 2)
		if M.PanelHeight > available then
			local room = available - M.Header - M.Pad * 2 - bandExtras
			local fitted = math.floor(room / rows)
			if fitted >= 64 then
				M.CardWidth = math.max(64, math.floor(M.CardWidth * (fitted / M.CardHeight)))
				M.CardHeight = fitted
				measure()
			end
		end

		panel.Size = UDim2.fromOffset(M.PanelWidth, M.PanelHeight)
		-- Centred, but never above the room the heading needs. The heading hangs
		-- HALF above the panel's own top edge, so a panel placed at the screen
		-- margin would still have half its title off-screen -- and this panel
		-- sizes itself from its content, so unlike every other one here it has no
		-- PlacePanel clamping it. Overflowing the bottom is survivable (the cards
		-- are still readable and reachable); losing the top is not.
		panel.Position = UDim2.fromOffset(
			Responsive.ClampX(math.round((viewport.X - M.PanelWidth) / 2), M.PanelWidth),
			math.max(
				Responsive.ScreenMargin + math.ceil(headingHeight / 2),
				math.round((viewport.Y - M.PanelHeight) / 2)
			)
		)

		heading.Size = UDim2.fromOffset(px(HEADING_WIDTH), headingHeight)
		heading.Position = UDim2.new(0.5, 0, 0, -headingHeight / 2)

		for _, holder in holders do
			holder:Destroy()
		end
		table.clear(holders)
		table.clear(blurbLabels)
		table.clear(blurbText)

		for index, spec in CARDS do
			buildCard(spec, index)
		end
		-- The rebuilt blurbs come back with their flavour text; the live queue
		-- counts have to be written onto them again.
		refreshCounts()
	end
	Responsive.Observe(relayout)
end

-- Cards pop in left to right rather than all at once. Everything appearing on
-- one frame reads as a screenshot; a 40ms stagger reads as the menu dealing them
-- out, and costs nothing.
local function playEntrance()
	for index, holder in holders do
		local holderScale = holder:FindFirstChildOfClass("UIScale")
		if holderScale then
			holderScale.Scale = 0.86
			task.delay((index - 1) * 0.04, function()
				TweenService:Create(holderScale, Theme.Anim.Pop, { Scale = 1 }):Play()
			end)
		end
	end
end

-- Opens the picker. `callback` receives the chosen target: an exact race size,
-- or QueueModes.AnySize for Quick Play.
function PlayModePickerController.Open(callback: (number) -> ())
	onChosen = callback
	openModal()
	playEntrance()
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
