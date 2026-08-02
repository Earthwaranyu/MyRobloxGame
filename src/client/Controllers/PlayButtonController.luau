local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local QueueModes = require(Shared.QueueModes)
local RemoteNames = require(Shared.RemoteNames)
local Signal = require(Shared.Signal)

local MenuIcons = require(script.Parent.Parent.MenuIcons)
local Responsive = require(script.Parent.Parent.Responsive)
local Widgets = require(script.Parent.Parent.Widgets)
local MatchStateController = require(script.Parent.MatchStateController)
local PlayModePickerController = require(script.Parent.PlayModePickerController)

-- Primary way to enter matchmaking (touching a physical start line still
-- works too for the real-players queue, and feeds the exact same shared
-- queue -- see MatchService). "VS BOTS" and "PRACTICE" are two more
-- independent entry points (MatchService.StartBotMatch /
-- StartPracticeMatch) into the same RequestQueue remote, just with a
-- different mode string, since all three are still fundamentally "start me
-- a race."
local PlayButtonController = {}

-- Reference geometry for the bottom cluster. ROW_GAP is 10 because VS BOTS and
-- PRACTICE were authored at -150 and +5 from centre -- 145 wide with 10 between.
-- The old *_BOTTOM offsets are gone: rows are stacked up from the touch-control
-- band by Responsive.BottomRowY, so their distance from the bottom is derived
-- from the heights they actually have rather than hand-set.
-- The phone action row: SPRINT, PLAY and DASH side by side. All three
-- controllers read Responsive.ActionRow, which owns the widths, the gap and the
-- x positions, so none can drift or wander onto the movement pad.
local PLAY_WIDTH, PLAY_HEIGHT = 220, 64
local ROW_WIDTH, ROW_HEIGHT, ROW_GAP = 145, 44, 10

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
-- True only from PreRaceCountdown until the state machine leaves Lobby (see
-- MatchStateController.StateChanged below) -- separate from `busy` because
-- `busy` covers BOTH "waiting in the shared queue" (where "CANCEL" should
-- keep showing, unchanged) and "match found, 8s countdown running" (where it
-- shouldn't -- a match was already found, there's nothing left to cancel
-- finding).
local inPreRace = false

-- Buttons stay clickable while queued now (previously Active = false, a
-- dead end with no way back out short of the whole StateChanged round-trip
-- from actually starting a race) -- clicking any of them while busy cancels
-- instead of queuing again.
local function refresh()
	if inPreRace then
		-- QueueStatusController's own countdown UI has already taken over
		-- the screen at this point -- hide these entirely rather than
		-- relabeling to "CANCEL" a second time right next to it.
		button.Visible = false
		botsButton.Visible = false
		practiceButton.Visible = false
		return
	end

	button.Visible = true
	botsButton.Visible = true
	practiceButton.Visible = true

	if busy then
		-- Spelled out on the primary button only -- the two small secondary
		-- ones have no room for it, and one visible reminder of the key is
		-- enough (see the InputBegan handler in Init).
		button.Text = "CANCEL (BACKSPACE)"
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

-- `target` is the exact race size chosen in the play menu, or nil for the
-- size-agnostic wave queue. Ignored for Bots/Practice, which aren't queues.
local function startQueue(mode: string?, target: number?)
	if busy then
		return
	end
	busy = true
	PlayButtonController.CurrentMode = mode
	PlayButtonController.ModeChanged:Fire(mode)
	refresh()
	Net.GetRemoteEvent(RemoteNames.RequestQueue):FireServer(mode, target)
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
	inPreRace = false
	PlayButtonController.CurrentMode = nil
	refresh()
end

-- Escape hatch from a queue that isn't filling, offered by
-- QueueStatusController once the wait has clearly stalled. Lives here rather
-- than there because this controller owns `busy`/`CurrentMode`: doing the
-- two remote calls from the outside would leave those stale, and the HUD
-- buttons would go back to showing PLAY mid-bot-match.
--
-- `busy` deliberately stays true across the swap -- the player goes straight
-- from the queue into a bot match and is never idle, so there's no window
-- where a stray click could double-queue them. The server does the same:
-- QuitMatch clears its playerBusy flag and StartBotMatch immediately re-sets
-- it, and RemoteEvents from one client arrive in the order they were fired.
function PlayButtonController.SwitchToBots()
	if not busy or inPreRace then
		return
	end
	Net.GetRemoteEvent(RemoteNames.QuitMatch):FireServer()
	PlayButtonController.CurrentMode = "Bots"
	PlayButtonController.ModeChanged:Fire("Bots")
	Net.GetRemoteEvent(RemoteNames.RequestQueue):FireServer("Bots")
	refresh()
end

local function onButtonClicked(mode: string?)
	if busy then
		cancelQueue()
		return
	end

	-- PLAY now asks WHICH race first (see PlayModePickerController) instead of
	-- dropping straight into the size-agnostic queue. VS BOTS and PRACTICE skip
	-- the picker -- neither has a size to choose.
	if mode == nil then
		PlayModePickerController.Open(function(target: number)
			startQueue(nil, if target == QueueModes.AnySize then nil else target)
		end)
		return
	end

	startQueue(mode)
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "PlayButtonGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	button = Widgets.Button("PLAY", UDim2.fromOffset(220, 64), UDim2.new(0.5, -110, 1, -120), {
		TextSize = 28,
		Icon = function(holder, color)
			MenuIcons.Populate(holder, "Play", color)
		end,
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
		Icon = function(holder, color)
			MenuIcons.Populate(holder, "Bots", color)
		end,
	})
	botsButton.Parent = screenGui
	botsButton.MouseButton1Click:Connect(function()
		onButtonClicked("Bots")
	end)

	practiceButton = Widgets.Button("PRACTICE", UDim2.fromOffset(145, 44), UDim2.new(0.5, 5, 1, -172), {
		Variant = "Secondary",
		TextSize = 16,
		Icon = function(holder, color)
			MenuIcons.Populate(holder, "Practice", color)
		end,
	})
	practiceButton.Parent = screenGui
	practiceButton.MouseButton1Click:Connect(function()
		onButtonClicked("Practice")
	end)

	-- This whole cluster sits low enough to be inside the touch-control band, and
	-- the clear strip between the movement pad and the jump button is what makes
	-- that workable. Both rows are nudged into that strip as a GROUP (keeping
	-- their own internal spacing) rather than each button drifting independently
	-- -- VS BOTS used to reach ~27pt into the movement pad, which is enough to
	-- swallow the touch that would have started a walk.
	Responsive.Observe(function()
		local px = Responsive.Px
		local playHeight = Responsive.Tap(PLAY_HEIGHT)
		local rowWidth, rowHeight = px(ROW_WIDTH), Responsive.Tap(ROW_HEIGHT)
		local gap = px(ROW_GAP)
		local viewport = Responsive.ViewportSize()

		-- On a phone PLAY sits between SPRINT and DASH on one row; elsewhere it
		-- keeps its own centred row with those two stacked above.
		local onPhone = Responsive.Tier() == "Phone"
		local playWidth, playX, playRowWidth
		if onPhone then
			-- Second element of the shared phone action row (SPRINT, PLAY, DASH).
			local actionRow = Responsive.ActionRow()
			playWidth, playX, playRowWidth = actionRow.Widths[2], actionRow.Positions[2], actionRow.Total
		else
			playWidth = px(PLAY_WIDTH)
			playRowWidth = playWidth
			playX = Responsive.ClearCorners(math.round((viewport.X - playWidth) / 2), playWidth)
		end
		Widgets.Relayout(
			button,
			UDim2.fromOffset(playWidth, playHeight),
			UDim2.fromOffset(playX, Responsive.BottomRowY(0, playHeight, playRowWidth))
		)

		-- VS BOTS + PRACTICE sit one row above whatever PLAY is on.
		local pairWidth = rowWidth * 2 + gap
		local pairX = Responsive.ClearCorners(math.round((viewport.X - pairWidth) / 2), pairWidth)
		local rowY = Responsive.BottomRowY(1, rowHeight, pairWidth)
		Widgets.Relayout(botsButton, UDim2.fromOffset(rowWidth, rowHeight), UDim2.fromOffset(pairX, rowY))
		Widgets.Relayout(
			practiceButton,
			UDim2.fromOffset(rowWidth, rowHeight),
			UDim2.fromOffset(pairX + rowWidth + gap, rowY)
		)
	end)
end

function PlayButtonController.Init()
	buildUI()
	local visible = MatchStateController.CurrentState == "Lobby"
	button.Visible = visible
	botsButton.Visible = visible
	practiceButton.Visible = visible

	-- Same Backspace = "get me out of here" key QuitMatchController binds for
	-- the race itself (see its comment on why a key, not just a button),
	-- extended backwards to cover the whole queue: waiting for players AND
	-- the map-reveal spin, where the only way out used to be finding and
	-- clicking CANCEL. Deliberately skips inPreRace -- QuitMatchController
	-- owns Backspace from PreRaceCountdown onwards, and both firing QuitMatch
	-- would just be a redundant second remote call.
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed or input.KeyCode ~= Enum.KeyCode.Backspace then
			return
		end
		if busy and not inPreRace then
			cancelQueue()
		end
	end)

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
		inPreRace = true
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
		inPreRace = false
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
			inPreRace = false
			PlayButtonController.CurrentMode = nil
			refresh()
		end
	end)
end

return PlayButtonController
