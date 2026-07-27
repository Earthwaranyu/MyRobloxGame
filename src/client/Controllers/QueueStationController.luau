local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local QueueModes = require(Shared.QueueModes)
local RemoteNames = require(Shared.RemoteNames)

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
	panel, open, close = Widgets.Modal("CustomQueue", UDim2.fromOffset(340, 260), UDim2.new(0.5, -170, 0.5, -130))
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

	local minusButton = Widgets.Button("-", UDim2.fromOffset(56, 56), UDim2.fromOffset(40, 92), {
		Variant = "Secondary",
		TextSize = 30,
	})
	minusButton.Parent = panel
	minusButton.MouseButton1Click:Connect(function()
		step(-1)
	end)

	local plusButton = Widgets.Button("+", UDim2.fromOffset(56, 56), UDim2.fromOffset(244, 92), {
		Variant = "Secondary",
		TextSize = 30,
	})
	plusButton.Parent = panel
	plusButton.MouseButton1Click:Connect(function()
		step(1)
	end)

	local joinButton = Widgets.Button("JOIN QUEUE", UDim2.fromOffset(220, 50), UDim2.fromOffset(60, 178), {
		TextSize = 20,
	})
	joinButton.Parent = panel
	joinButton.MouseButton1Click:Connect(function()
		closePanel()
		Net.GetRemoteEvent(RemoteNames.RequestQueueMode):FireServer(selected)
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
