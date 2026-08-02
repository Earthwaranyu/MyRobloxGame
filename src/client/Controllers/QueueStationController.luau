local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local QueueModes = require(Shared.QueueModes)
local RemoteNames = require(Shared.RemoteNames)

local Responsive = require(script.Parent.Parent.Responsive)
local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)

-- The CUSTOM lobby station's size picker. Every other station carries its own
-- fixed size, so stepping on it queues immediately (see QueueStationService);
-- this one has to ask first.
--
-- A stepper rather than a text box: the valid range is small and contiguous,
-- and a text field would need its own validation, an on-screen keyboard on
-- mobile, and a way to reject "abc". Two buttons and a number can only ever
-- produce a legal value.
local QueueStationController = {}

local STATION_WIDTH, STATION_HEIGHT = 340, 260

local panel: CanvasGroup
local openPanel: () -> ()
local closePanel: () -> ()
local valueLabel: TextLabel

local selected = QueueModes.CustomMin

local function refresh()
	valueLabel.Text = tostring(selected)
end

local function step(delta: number)
	selected = math.clamp(selected + delta, QueueModes.CustomMin, QueueModes.CustomMax)
	refresh()
end

local function buildUI()
	local open, close
	panel, open, close = Widgets.Modal(
		"CustomQueue",
		UDim2.fromOffset(STATION_WIDTH, STATION_HEIGHT),
		UDim2.new(0.5, -STATION_WIDTH / 2, 0.5, -STATION_HEIGHT / 2)
	)
	openPanel, closePanel = open, close

	local title = Widgets.Label("CUSTOM RACE SIZE", UDim2.new(1, -24, 0, 30), UDim2.fromOffset(12, 18), {
		Font = Theme.Font.Display,
		TextSize = 22,
		Align = Enum.TextXAlignment.Center,
	})
	title.Parent = panel

	local hint = Widgets.Label(
		("How many racers? (%d-%d)"):format(QueueModes.CustomMin, QueueModes.CustomMax),
		UDim2.new(1, -24, 0, 20),
		UDim2.fromOffset(12, 52),
		{
			TextSize = 14,
			Color = Theme.Color.TextSecondary,
			Align = Enum.TextXAlignment.Center,
		}
	)
	hint.Parent = panel

	valueLabel = Widgets.Label("", UDim2.fromOffset(120, 76), UDim2.fromOffset(110, 82), {
		Font = Theme.Font.Display,
		TextSize = 64,
		Color = Theme.Color.AccentB,
		Align = Enum.TextXAlignment.Center,
	})
	valueLabel.Parent = panel

	local minusButton = Widgets.Button("-", UDim2.fromOffset(56, 56), UDim2.fromOffset(0, 0), {
		Variant = "Secondary",
		TextSize = 30,
	})
	minusButton.Parent = panel
	minusButton.MouseButton1Click:Connect(function()
		step(-1)
	end)

	local plusButton = Widgets.Button("+", UDim2.fromOffset(56, 56), UDim2.fromOffset(0, 0), {
		Variant = "Secondary",
		TextSize = 30,
	})
	plusButton.Parent = panel
	plusButton.MouseButton1Click:Connect(function()
		step(1)
	end)

	local joinButton = Widgets.Button("JOIN QUEUE", UDim2.fromOffset(220, 50), UDim2.fromOffset(0, 0), {
		TextSize = 20,
	})
	joinButton.Parent = panel
	joinButton.MouseButton1Click:Connect(function()
		closePanel()
		Net.GetRemoteEvent(RemoteNames.RequestQueueMode):FireServer(selected)
	end)

	-- Everything on this panel is laid out from the width it ACTUALLY gets, and
	-- stacked from a cursor.
	--
	-- It used to mix three coordinate systems against a panel that is none of
	-- them: the value label sat at a raw x of 110 (centred for the authored 340),
	-- the steppers at Px(40)/Px(244), and their sizes at Tap(56). PanelSize floors
	-- a phone panel to 72% of the viewport -- 577, not 340 -- so on a phone the +
	-- button landed at x 176-232 straight on top of the value label at 110-230.
	-- That is the reported overlap, and no amount of nudging the constants fixes
	-- it while they are anchored to a width the panel does not have.
	--
	-- Centred on the panel's own 0.5 line, so the stepper row stays a group at
	-- any width. See Responsive.CenterPanel for why the panel's own x could not
	-- be derived from a locally-measured width either.
	Responsive.Observe(function()
		local px, tap = Responsive.Px, Responsive.Tap
		local viewport = Responsive.ViewportSize()
		-- Lifted clear of the touch band: the steppers and JOIN QUEUE sit in the
		-- panel's lower half, which on a phone reaches the movement pad.
		Responsive.CenterPanel(panel, STATION_WIDTH, STATION_HEIGHT, function(height)
			return (viewport.Y - Responsive.TouchBand() - height) / 2
		end)

		local pad = px(12)
		local gap = px(8)
		local titleHeight, hintHeight = px(30), px(20)
		local stepper = tap(56)
		local valueWidth, valueHeight = px(120), px(76)
		local rowHeight = math.max(stepper, valueHeight)
		local joinHeight = tap(50)

		local y = px(18)
		title.Size = UDim2.new(1, -pad * 2, 0, titleHeight)
		title.Position = UDim2.fromOffset(pad, y)
		title.TextSize = Responsive.Text(22)

		y += titleHeight + gap
		hint.Size = UDim2.new(1, -pad * 2, 0, hintHeight)
		hint.Position = UDim2.fromOffset(pad, y)
		hint.TextSize = Responsive.Text(14)

		y += hintHeight + gap
		-- The number is centred; each stepper sits half a gap out from it.
		local half = math.round(valueWidth / 2)
		valueLabel.Size = UDim2.fromOffset(valueWidth, valueHeight)
		valueLabel.Position = UDim2.new(0.5, -half, 0, y + math.round((rowHeight - valueHeight) / 2))
		valueLabel.TextSize = Responsive.Text(64)

		local stepY = y + math.round((rowHeight - stepper) / 2)
		Widgets.Relayout(
			minusButton,
			UDim2.fromOffset(stepper, stepper),
			UDim2.new(0.5, -(half + gap + stepper), 0, stepY)
		)
		Widgets.Relayout(plusButton, UDim2.fromOffset(stepper, stepper), UDim2.new(0.5, half + gap, 0, stepY))

		y += rowHeight + gap
		local joinWidth = math.min(px(220), panel.AbsoluteSize.X - pad * 2)
		Widgets.Relayout(
			joinButton,
			UDim2.fromOffset(joinWidth, joinHeight),
			UDim2.new(0.5, -math.round(joinWidth / 2), 0, y)
		)
	end)
end

function QueueStationController.Init()
	buildUI()
	refresh()

	-- The server both raises and dismisses this: the picker belongs to the
	-- custom room, so walking out (or the room's size being settled by
	-- somebody else first) has to take it off the screen. Leaving it up would
	-- let a player queue for a room they're no longer standing in.
	Net.GetRemoteEvent(RemoteNames.OpenCustomQueuePicker).OnClientEvent:Connect(function(shouldOpen: boolean?)
		if shouldOpen == false then
			closePanel()
		else
			openPanel()
		end
	end)
end

return QueueStationController
