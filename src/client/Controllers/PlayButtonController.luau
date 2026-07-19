local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Signal = require(Shared.Signal)

local Widgets = require(script.Parent.Parent.Widgets)
local MatchStateController = require(script.Parent.MatchStateController)

-- Primary way to enter matchmaking (touching a physical start line still
-- works too for the real-players queue, and feeds the exact same shared
-- queue -- see MatchService). "VS BOTS" and "PRACTICE" are two more
-- independent entry points (MatchService.StartBotMatch /
-- StartPracticeMatch) into the same RequestQueue remote, just with a
-- different mode string, since all three are still fundamentally "start me
-- a race."
local PlayButtonController = {}

-- Exposed so GhostController knows whether the race that's about to start is
-- a practice run (and should fetch/record a ghost) without needing its own
-- copy of this button's click-handling logic.
PlayButtonController.CurrentMode = nil :: string?
PlayButtonController.ModeChanged = Signal.new()

local player = Players.LocalPlayer

local button: TextButton
local botsButton: TextButton
local practiceButton: TextButton
-- True from the moment a queue attempt starts (any button) until the player
-- is actually back in the Lobby state after a race. Deliberately NOT cleared
-- by the QueueStatusChanged(nil) signal alone: that fires the instant the
-- group gets teleported to the chosen stage, but the player is still in
-- "Lobby" state (third-person) for the pre-race countdown that follows, and
-- clicking any button again during that gap would double-queue them.
local busy = false

-- Buttons stay clickable while queued now (previously Active = false, a
-- dead end with no way back out short of the whole StateChanged round-trip
-- from actually starting a race) -- clicking any of them while busy cancels
-- instead of queuing again.
local function refresh()
	if busy then
		button.Text = "CANCEL"
		button.Active = true
		botsButton.Text = "CANCEL"
		botsButton.Active = true
		practiceButton.Text = "CANCEL"
		practiceButton.Active = true
	else
		button.Text = "PLAY"
		button.Active = true
		botsButton.Text = "VS BOTS"
		botsButton.Active = true
		practiceButton.Text = "PRACTICE"
		practiceButton.Active = true
	end
end

local function startQueue(mode: string?)
	if busy then
		return
	end
	busy = true
	PlayButtonController.CurrentMode = mode
	PlayButtonController.ModeChanged:Fire(mode)
	refresh()
	Net.GetRemoteEvent(RemoteNames.RequestQueue):FireServer(mode)
end

-- QuitMatch already handles both "still sitting in the shared queue" and
-- "already teleported to the stage for the pre-race countdown" -- see
-- MatchService.QuitMatch -- so this one remote covers cancelling at any
-- point before the race timer itself actually starts.
local function cancelQueue()
	if not busy then
		return
	end
	Net.GetRemoteEvent(RemoteNames.QuitMatch):FireServer()
	busy = false
	PlayButtonController.CurrentMode = nil
	refresh()
end

local function onButtonClicked(mode: string?)
	if busy then
		cancelQueue()
	else
		startQueue(mode)
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
	button.MouseButton1Click:Connect(function()
		onButtonClicked(nil)
	end)

	-- VS BOTS and PRACTICE share one row just above PLAY, side by side --
	-- both clearly secondary/optional ways to race, not competing with it.
	botsButton = Widgets.Button("VS BOTS", UDim2.fromOffset(145, 44), UDim2.new(0.5, -150, 1, -172), {
		Variant = "Secondary",
		TextSize = 16,
	})
	botsButton.Parent = screenGui
	botsButton.MouseButton1Click:Connect(function()
		onButtonClicked("Bots")
	end)

	practiceButton = Widgets.Button("PRACTICE", UDim2.fromOffset(145, 44), UDim2.new(0.5, 5, 1, -172), {
		Variant = "Secondary",
		TextSize = 16,
	})
	practiceButton.Parent = screenGui
	practiceButton.MouseButton1Click:Connect(function()
		onButtonClicked("Practice")
	end)
end

function PlayButtonController.Init()
	buildUI()
	local visible = MatchStateController.CurrentState == "Lobby"
	button.Visible = visible
	botsButton.Visible = visible
	practiceButton.Visible = visible

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

	-- Fires when a party member's own queue attempt was silently blocked by
	-- MatchService because a DIFFERENT party member (this player) was already
	-- busy -- see MatchService.Enqueue. Without this, that other player's
	-- client would be stuck showing "QUEUED..." forever, since no
	-- QueueStatusChanged/PreRaceCountdown/state change was ever coming for an
	-- attempt the server never actually queued.
	Net.GetRemoteEvent(RemoteNames.QueueRejected).OnClientEvent:Connect(function(busyMemberName: string)
		busy = false
		PlayButtonController.CurrentMode = nil
		refresh()
		button.Text = busyMemberName .. " is busy"
		task.delay(2.5, function()
			if not busy then
				button.Text = "PLAY"
			end
		end)
	end)

	MatchStateController.StateChanged:Connect(function(state: string)
		if state == "Racing" or state == "Spectating" then
			button.Visible = false
			botsButton.Visible = false
			practiceButton.Visible = false
		else
			busy = false
			PlayButtonController.CurrentMode = nil
			refresh()
			button.Visible = true
			botsButton.Visible = true
			practiceButton.Visible = true
		end
	end)
end

return PlayButtonController
