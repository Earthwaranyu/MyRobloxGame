local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local Widgets = require(script.Parent.Parent.Widgets)
local MatchStateController = require(script.Parent.MatchStateController)

-- Primary way to enter matchmaking (touching a physical start line still
-- works too for the real-players queue, and feeds the exact same shared
-- queue -- see MatchService). "VS BOTS" is a second, independent entry
-- point into MatchService.StartBotMatch -- same RequestQueue remote, just
-- an extra boolean, since it's still fundamentally "start me a race."
local PlayButtonController = {}

local player = Players.LocalPlayer

local button: TextButton
local botsButton: TextButton
-- True from the moment a queue attempt starts (either button) until the
-- player is actually back in the Lobby state after a race. Deliberately NOT
-- cleared by the QueueStatusChanged(nil) signal alone: that fires the
-- instant the group gets teleported to the chosen stage, but the player is
-- still in "Lobby" state (third-person) for the pre-race countdown that
-- follows, and clicking either button again during that gap would
-- double-queue them.
local busy = false

local function refresh()
	if busy then
		button.Text = "QUEUED..."
		button.Active = false
		botsButton.Text = "QUEUED..."
		botsButton.Active = false
	else
		button.Text = "PLAY"
		button.Active = true
		botsButton.Text = "VS BOTS"
		botsButton.Active = true
	end
end

local function startQueue(vsBots: boolean)
	if busy then
		return
	end
	busy = true
	refresh()
	Net.GetRemoteEvent(RemoteNames.RequestQueue):FireServer(vsBots)
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "PlayButtonGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	button = Widgets.Button("PLAY", UDim2.fromOffset(220, 64), UDim2.new(0.5, -110, 1, -120), {
		TextSize = 28,
	})
	button.Parent = screenGui
	button.MouseButton1Click:Connect(function()
		startQueue(false)
	end)

	-- Sits just above PLAY, same width family but a touch smaller -- a
	-- clearly secondary/optional way to race, not competing with it.
	botsButton = Widgets.Button("VS BOTS", UDim2.fromOffset(190, 44), UDim2.new(0.5, -95, 1, -172), {
		Variant = "Secondary",
		TextSize = 18,
	})
	botsButton.Parent = screenGui
	botsButton.MouseButton1Click:Connect(function()
		startQueue(true)
	end)
end

function PlayButtonController.Init()
	buildUI()
	local visible = MatchStateController.CurrentState == "Lobby"
	button.Visible = visible
	botsButton.Visible = visible

	local queueRemote = Net.GetRemoteEvent(RemoteNames.QueueStatusChanged)
	queueRemote.OnClientEvent:Connect(function(secondsRemaining: number?)
		if secondsRemaining then
			busy = true
			refresh()
		end
	end)

	local preRaceRemote = Net.GetRemoteEvent(RemoteNames.PreRaceCountdown)
	preRaceRemote.OnClientEvent:Connect(function()
		busy = true
		refresh()
	end)

	MatchStateController.StateChanged:Connect(function(state: string)
		if state == "Racing" or state == "Spectating" then
			button.Visible = false
			botsButton.Visible = false
		else
			busy = false
			refresh()
			button.Visible = true
			botsButton.Visible = true
		end
	end)
end

return PlayButtonController
