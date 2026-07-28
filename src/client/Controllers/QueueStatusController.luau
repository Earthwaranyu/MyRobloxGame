local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Constants = require(Shared.Constants)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local MenuIcons = require(script.Parent.Parent.MenuIcons)
local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local Sounds = require(script.Parent.Parent.Sounds)
local MatchStateController = require(script.Parent.MatchStateController)
local PlayButtonController = require(script.Parent.PlayButtonController)

local QueueStatusController = {}

local player = Players.LocalPlayer

local container: Frame
local captionLabel: TextLabel
local numberLabel: TextLabel
local numberScale: UIScale
local goLabel: TextLabel
local goScale: UIScale
local cancelButton: TextButton

-- Server sends the remaining seconds once; ticking down locally avoids
-- relying on the client and server clocks (os.clock()) being in sync. This
-- one ticker is reused for two back-to-back phases of the same flow:
-- "Waiting" while the shared queue matches players (numeric ticker hides for
-- the last Constants.Match.MapRevealSeconds so MapRevealController's
-- case-opening reel can take over), then "PreRace" once the group has been
-- teleported to the chosen stage and is standing there before the race
-- actually starts.
local endTime: number? = nil
local lastShownSecond: number? = nil
local phase: "Waiting" | "PreRace" = "Waiting"

-- Set while the queue is under Constants.Match.MinPlayers, where there is no
-- countdown to tick DOWN yet -- so the big number counts UP from the moment
-- PLAY was pressed instead of sitting blank. Without it that state was a
-- static line of text with no sign the game was still doing anything, which
-- reads like a hang rather than a wait. Mutually exclusive with endTime: the
-- instant a real countdown arrives, that takes the display over.
local waitStartTime: number? = nil

-- After this long with the queue still under MinPlayers, an opt-in "PLAY WITH
-- BOTS" button appears under the clock. Nothing happens automatically -- the
-- player is told the server is quiet and chooses for themselves, rather than
-- being silently converted into an unranked bot race. Without an out, an
-- empty server just counts up forever with no way to leave but Backspace,
-- which reads as a hang.
local BOT_HINT_AFTER_SECONDS = 15

-- Both label colors changed with the move onto a violet panel. Theme.Color's
-- Text* tones are tuned for the dark Panel background and go muddy on candy
-- violet, and the number's old AccentB was violet ON violet -- near invisible
-- once there was a fill behind it. White for the number, and the panel's own
-- light tint for the caption, keeps the size/weight hierarchy without either
-- one fighting the fill. Warning yellow (the bot hint) still reads fine.
local NUMBER_COLOR = Color3.fromRGB(255, 255, 255)
local CAPTION_COLOR = Color3.fromRGB(224, 216, 255)
local hintShown = false
local botButton: TextButton

-- Single owner of the caption's text AND color, so the warning-colored bot
-- hint can never leak into a later phase (its color would otherwise persist
-- into "RACE STARTING IN"). Also clears the hint latch, so a fresh wait can
-- show it again.
local function setCaption(text: string)
	hintShown = false
	captionLabel.Text = text
	captionLabel.TextColor3 = CAPTION_COLOR
	-- The offer only makes sense while a stalled queue is on screen; every
	-- other phase (countdown running, pre-race, hidden) must not show it.
	if botButton then
		botButton.Visible = false
	end
	-- The X cancels MATCHMAKING, so it's shown for every phase this card has
	-- except "PreRace" -- by then you've been teleported onto the stage and
	-- leaving is a different action with different consequences, which
	-- QuitMatchController's own "Leave Match (Backspace)" button already owns
	-- and which appears at exactly that moment. Two competing exits on screen
	-- at once would just make it unclear which one costs you something.
	if cancelButton then
		cancelButton.Visible = phase ~= "PreRace"
	end
end

local function pulse(scale: UIScale)
	scale.Scale = 1.35
	TweenService:Create(scale, Theme.Anim.Pop, { Scale = 1 }):Play()
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "QueueStatusGui"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 5
	screenGui.Parent = player:WaitForChild("PlayerGui")

	-- Top centre, as a bordered card rather than free-floating text.
	--
	-- It used to sit at 22% down the screen with a transparent background, which
	-- put a 72px number straight over the plaza and the queue-room signs -- on a
	-- bright lobby the light text had nothing behind it and simply got lost, and
	-- what a player could read of it competed with the world it was drawn on.
	-- Top centre is the one region of this HUD nothing else claims (the stats
	-- pill and menu buttons are top-LEFT, the play/ability row is bottom), so
	-- the clock gets a lane of its own and the same candy panel treatment --
	-- violet fill, thick white border -- as every other surface in the game.
	container = Instance.new("Frame")
	container.Name = "CountdownContainer"
	container.Size = UDim2.fromOffset(300, 104)
	container.Position = UDim2.new(0.5, -150, 0, 12)
	container.BackgroundColor3 = Theme.Candy.PanelFace
	container.BorderSizePixel = 0
	container.Visible = false
	container.Parent = screenGui

	local containerCorner = Instance.new("UICorner")
	containerCorner.CornerRadius = Theme.Corner.Panel
	containerCorner.Parent = container

	local containerGradient = Instance.new("UIGradient")
	containerGradient.Color = ColorSequence.new(Theme.Candy.PanelFaceLight, Theme.Candy.PanelFace)
	containerGradient.Rotation = 90
	containerGradient.Parent = container

	-- The border is the whole point of the move: it's what separates the card
	-- from whatever happens to be behind it. Same 4px white stroke Widgets.Panel
	-- uses, so this reads as part of the set rather than a one-off.
	local containerStroke = Instance.new("UIStroke")
	containerStroke.Name = "Border"
	containerStroke.Color = Theme.Candy.Border
	containerStroke.Thickness = 4
	containerStroke.Parent = container

	captionLabel = Widgets.Label("WAITING FOR PLAYERS", UDim2.new(1, 0, 0, 20), UDim2.fromOffset(0, 10), {
		TextSize = 16,
		Color = CAPTION_COLOR,
		Align = Enum.TextXAlignment.Center,
	})
	captionLabel.Parent = container

	-- 56, down from 72: the number no longer needs to shout over the scenery
	-- now that it has a panel behind it, and 72 didn't fit the card's height
	-- alongside the caption without crowding both against the border.
	numberLabel = Widgets.Label("", UDim2.new(1, 0, 0, 62), UDim2.fromOffset(0, 32), {
		Font = Theme.Font.Display,
		TextSize = 56,
		Color = NUMBER_COLOR,
		Align = Enum.TextXAlignment.Center,
	})
	numberLabel.TextStrokeTransparency = 0.6
	numberLabel.Parent = container

	numberScale = Instance.new("UIScale")
	numberScale.Parent = numberLabel

	goLabel = Widgets.Label("GO!", UDim2.fromOffset(400, 120), UDim2.new(0.5, -200, 0.3, 0), {
		Font = Theme.Font.Display,
		TextSize = 90,
		Color = Theme.Color.Success,
		Align = Enum.TextXAlignment.Center,
	})
	goLabel.TextStrokeTransparency = 0.5
	goLabel.Visible = false
	goLabel.Parent = screenGui

	goScale = Instance.new("UIScale")
	goScale.Parent = goLabel

	-- Hangs just BELOW the card (container height 104 + a 10px gap), centred on
	-- it -- deliberately outside the panel's fill rather than inside it, so the
	-- card stays purely the clock and the button reads as the offer attached to
	-- it. Hidden until the wait has clearly stalled (see BOT_HINT_AFTER_SECONDS);
	-- PlayButtonController owns the actual swap so its own busy/mode state stays
	-- correct.
	botButton = Widgets.Button("PLAY WITH BOTS", UDim2.fromOffset(240, 44), UDim2.fromOffset(30, 114), {
		Variant = "Secondary",
		TextSize = 17,
		Icon = function(holder, color)
			MenuIcons.Populate(holder, "Bots", color)
		end,
	})
	botButton.Visible = false
	botButton.Parent = container
	botButton.MouseButton1Click:Connect(function()
		botButton.Visible = false
		PlayButtonController.SwitchToBots()
	end)

	-- Red X straddling the card's top-right corner, the standard "close this"
	-- affordance. AnchorPoint centres it ON the corner so it reads as attached
	-- to the border rather than floating inside or outside the card.
	--
	-- Until now the only way out of a queue was Backspace (undiscoverable) or
	-- waiting for the bot hint at 15 seconds -- so a player who queued by
	-- mistake, or changed their mind at second three, had no visible exit at
	-- all. Fires the same QuitMatch remote everything else uses: the server
	-- already handles being quit at this stage (MatchService.QuitMatch pulls
	-- you out of the waiting list and clears queuedTarget), and its reply --
	-- QueueStatusChanged with nil -- is what actually hides this card, so there
	-- is no local guess about whether the cancel took.
	cancelButton = Widgets.Button("✕", UDim2.fromOffset(36, 36), UDim2.fromScale(1, 0), {
		Variant = "Danger",
		TextSize = 20,
	})
	cancelButton.AnchorPoint = Vector2.new(0.5, 0.5)
	cancelButton.Visible = false
	cancelButton.Parent = container
	cancelButton.MouseButton1Click:Connect(function()
		Net.GetRemoteEvent(RemoteNames.QuitMatch):FireServer()
	end)

	RunService.RenderStepped:Connect(function()
		if not endTime then
			if waitStartTime then
				local elapsed = os.clock() - waitStartTime
				-- Stopwatch shape ("0:07"), not a bare number: a lone digit
				-- here would read as a countdown about to hit zero, which is
				-- the opposite of what this is.
				numberLabel.Text = ("%d:%02d"):format(math.floor(elapsed / 60), math.floor(elapsed % 60))
				-- Deliberately no pulse or Tick sound, unlike the countdown
				-- below -- an open-ended wait would turn those into a
				-- metronome that never stops.

				if not hintShown and elapsed >= BOT_HINT_AFTER_SECONDS then
					hintShown = true
					captionLabel.Text = "NO ONE ELSE IS QUEUING"
					captionLabel.TextColor3 = Theme.Color.Warning
					botButton.Visible = true
				end
			end
			return
		end

		local remaining = endTime - os.clock()
		if remaining <= 0 then
			container.Visible = false
			endTime = nil
			lastShownSecond = nil
			return
		end

		if phase == "Waiting" and remaining <= Constants.Match.MapRevealSeconds then
			container.Visible = false
			return
		end

		container.Visible = true
		local shownSecond = math.ceil(remaining)
		numberLabel.Text = tostring(shownSecond)
		if shownSecond ~= lastShownSecond then
			lastShownSecond = shownSecond
			pulse(numberScale)
			Sounds.Play("Tick")
		end
	end)
end

-- Fades goLabel back out. Guaranteed-hide fallback mirrors Widgets.Close: a
-- tween that never reports completion would otherwise leave "GO!" stuck on
-- screen forever.
local function fadeOutGo()
	local fadeTween = TweenService:Create(goLabel, Theme.Anim.Smooth, { TextTransparency = 1 })

	local function hide()
		goLabel.Visible = false
		goLabel.TextTransparency = 0
	end

	fadeTween.Completed:Connect(function(playbackState: Enum.PlaybackState)
		if playbackState == Enum.PlaybackState.Completed then
			hide()
		end
	end)
	fadeTween:Play()

	task.delay(Theme.Anim.Smooth.Time + 0.15, hide)
end

local function flashGo()
	goLabel.Visible = true
	goLabel.TextTransparency = 0
	goScale.Scale = 0.6
	Sounds.Play("Go")

	TweenService:Create(goScale, Theme.Anim.Pop, { Scale = 1.15 }):Play()
	task.delay(0.5, fadeOutGo)
end

function QueueStatusController.Init()
	buildUI()

	local remote = Net.GetRemoteEvent(RemoteNames.QueueStatusChanged)
	remote.OnClientEvent:Connect(function(secondsRemaining: (number | boolean)?)
		if not secondsRemaining then
			endTime = nil
			waitStartTime = nil
			lastShownSecond = nil
			container.Visible = false
			return
		end

		if secondsRemaining == true then
			-- Queued, but MatchService hasn't started a real matching window
			-- yet (below Constants.Match.MinPlayers) -- no countdown to show,
			-- so the elapsed timer takes over until enough players join.
			endTime = nil
			lastShownSecond = nil
			-- Only start the clock the FIRST time: this can arrive more than
			-- once for the same wait (each party member's Enqueue sends one),
			-- and restarting on a repeat would keep resetting the number to
			-- 0:00 in front of a player who has genuinely been waiting.
			-- setCaption lives in here too, not just waitStartTime: it resets
			-- the hint latch, so calling it on a duplicate message would
			-- briefly flip an already-shown bot hint back to "waiting".
			-- Reset the phase, not just the clock: it is left on "PreRace" by the
			-- previous race and nothing else in this branch clears it, so a
			-- second queue in the same session would still be considered
			-- pre-race -- which would keep the cancel X hidden for the entire
			-- wait (see setCaption).
			phase = "Waiting"
			if not waitStartTime then
				waitStartTime = os.clock()
				numberLabel.Text = "0:00"
				setCaption("WAITING FOR PLAYERS...")
			end
			container.Visible = true
			return
		end

		phase = "Waiting"
		setCaption("WAITING FOR PLAYERS")
		endTime = os.clock() + (secondsRemaining :: number)
		waitStartTime = nil
		lastShownSecond = nil
		container.Visible = true
	end)

	local preRaceRemote = Net.GetRemoteEvent(RemoteNames.PreRaceCountdown)
	preRaceRemote.OnClientEvent:Connect(function(secondsRemaining: number)
		phase = "PreRace"
		setCaption("RACE STARTING IN")
		endTime = os.clock() + secondsRemaining
		-- Belt and braces: the queue's own nil/number messages should already
		-- have stopped the wait clock by now, but this state is unambiguously
		-- "past waiting" no matter which path got here.
		waitStartTime = nil
		lastShownSecond = nil
		container.Visible = true
	end)

	MatchStateController.StateChanged:Connect(function(state: string)
		if state == "Racing" then
			flashGo()
		end
	end)
end

return QueueStatusController
