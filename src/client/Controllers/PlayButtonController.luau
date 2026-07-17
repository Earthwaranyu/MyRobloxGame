local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local Widgets = require(script.Parent.Parent.Widgets)
local MatchStateController = require(script.Parent.MatchStateController)

-- Primary way to enter matchmaking (touching a physical start line still
-- works too, and feeds the exact same shared queue -- see MatchService).
local PlayButtonController = {}

local player = Players.LocalPlayer

local button: TextButton
-- True from the moment a queue attempt starts until the player is actually
-- back in the Lobby state after a race. Deliberately NOT cleared by the
-- QueueStatusChanged(nil) signal alone: that fires the instant the group
-- gets teleported to the chosen stage, but the player is still in "Lobby"
-- state (third-person) for the pre-race countdown that follows, and
-- clicking Play again during that gap would double-queue them.
local busy = false

local function refresh()
	if busy then
		button.Text = "QUEUED..."
		button.Active = false
	else
		button.Text = "PLAY"
		button.Active = true
	end
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

	local requestRemote = Net.GetRemoteEvent(RemoteNames.RequestQueue)
	button.MouseButton1Click:Connect(function()
		if busy then
			return
		end
		busy = true
		refresh()
		requestRemote:FireServer()
	end)
end

function PlayButtonController.Init()
	buildUI()
	button.Visible = MatchStateController.CurrentState == "Lobby"

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
		if state == "Racing" then
			button.Visible = false
		else
			busy = false
			refresh()
			button.Visible = true
		end
	end)
end

return PlayButtonController
