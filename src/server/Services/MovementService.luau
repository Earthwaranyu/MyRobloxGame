local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Constants = require(Shared.Constants)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

-- Sole authority over Humanoid.WalkSpeed. Clients used to set this directly
-- (SprintController), which is a classic Roblox speedhack: anything a client
-- sets on its own Humanoid replicates as-is, so a hacked client could just
-- set WalkSpeed to 500 and win every race for free Elo/points. Now the
-- client only ever sends intent ("shift is held or not") and the server
-- decides the actual number.
local MovementService = {}

-- A legitimate shift press/release can't happen faster than this; anything
-- beyond it is either a broken client or a script spamming the remote, so
-- it's dropped rather than acted on.
local MIN_INTENT_INTERVAL = 0.05

local lastIntentTime: { [number]: number } = {}
-- Last-known "is shift held" per player, kept even while a speed override
-- (see ApplySpeedOverride) is in control -- so the override can correctly
-- hand WalkSpeed back to "sprinting" instead of blindly to the base walk
-- speed, if the player toggled sprint while the override was active.
local sprintIntent: { [number]: boolean } = {}
-- Set only while an ability's timed speed effect (e.g. Surge) is running;
-- applySprint checks this and skips writing WalkSpeed live so a sprint
-- toggle mid-effect can't cut the boost short or fight it every frame.
local speedOverrideUntil: { [number]: number } = {}

-- MatchService's speed-hack watchdog (checkPlayerSpeed) flags anyone
-- covering more horizontal distance per second than a normal sprint allows
-- for -- but several legitimate abilities blow well past that on purpose
-- (Surge's WalkSpeed override, Meteor Dash's 85 studs/s burst plus the
-- airborne arc its lift launches afterward, Blink's instant reposition).
-- Without this, using them mid-race reads as a speed-hack and gets
-- "corrected" by snapping back to the last checkpoint -- exactly the "I
-- didn't fall but got sent back anyway" bug this exists to prevent.
-- Grants are per-player deadlines rather than a duration so a fresh grant
-- (e.g. immediately re-dashing) can never shorten an already-active one.
local speedCheckGraceUntil: { [number]: number } = {}

-- seconds is how long from NOW the watchdog should stay quiet for this
-- player -- callers size it to cover their own effect's full legitimate
-- displacement window (burst duration, plus any airtime it launches), not
-- just the instant the effect starts.
function MovementService.GrantSpeedCheckGrace(player: Player, seconds: number)
	local userId = player.UserId
	speedCheckGraceUntil[userId] = math.max(speedCheckGraceUntil[userId] or 0, os.clock() + seconds)
end

function MovementService.IsInSpeedCheckGrace(player: Player): boolean
	local until_ = speedCheckGraceUntil[player.UserId]
	return until_ ~= nil and os.clock() < until_
end

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

-- Players held at a pre-race start line (see MatchService.setFrozen).
--
-- MatchService anchors the root, which is what actually stops a character
-- moving -- but the anchor alone leaves Humanoid.WalkSpeed at its normal 16,
-- so the client's own controller still has a speed to act on and keeps trying
-- to walk. Worse, sprint intent flows straight through applySprint below, so a
-- racer leaning on Shift during the countdown was re-granting themselves 24
-- WalkSpeed against an anchored root. Zeroing speed for the duration removes
-- the input the client is predicting from, and this flag makes the zero stick
-- against any sprint toggle that arrives while it's held.
local frozen: { [number]: boolean } = {}

local function applySprint(player: Player, isSprinting: boolean)
	local userId = player.UserId
	sprintIntent[userId] = isSprinting

	-- Intent is still RECORDED while frozen, deliberately: the countdown ends
	-- with a hand-back to whatever the player is currently holding, so someone
	-- who pressed Shift during the countdown starts the race sprinting rather
	-- than having to release and re-press.
	if frozen[userId] then
		return
	end

	local overrideUntil = speedOverrideUntil[userId]
	if overrideUntil and os.clock() < overrideUntil then
		return
	end

	local humanoid = getHumanoid(player)
	if humanoid then
		humanoid.WalkSpeed = if isSprinting then Constants.SprintSpeed else Constants.WalkSpeed
	end
end

-- Called by AbilityService for a timed speed-changing effect (Surge). Takes
-- over WalkSpeed for durationSeconds regardless of sprint toggles during that
-- window (a power-up should feel uninterruptible), then hands it back to
-- whatever the player's CURRENT sprint intent is -- not necessarily what it
-- was when the override started, since they may have toggled shift mid-effect.
function MovementService.ApplySpeedOverride(player: Player, speed: number, durationSeconds: number)
	local humanoid = getHumanoid(player)
	if not humanoid then
		return
	end

	local userId = player.UserId
	local deadline = os.clock() + durationSeconds
	speedOverrideUntil[userId] = deadline
	humanoid.WalkSpeed = speed
	-- +0.3s buffer past the override's own end -- WalkSpeed reverting is
	-- immediate, but this covers the gap between that revert and the
	-- watchdog's next 1s-interval sample so the boundary tick can't still
	-- get flagged.
	MovementService.GrantSpeedCheckGrace(player, durationSeconds + 0.3)

	task.delay(durationSeconds, function()
		-- Only revert if nothing newer (a second override) has since taken
		-- over -- comparing against the stored deadline rather than a simple
		-- boolean means a stale timer firing early can't cut off a fresher one.
		if speedOverrideUntil[userId] == deadline then
			speedOverrideUntil[userId] = nil
			applySprint(player, sprintIntent[userId] or false)
		end
	end)
end

-- Holds a player at 0 WalkSpeed for a pre-race countdown, and hands speed back
-- to their current sprint intent when released.
--
-- Deliberately lives here rather than in MatchService: this module is the sole
-- authority over Humanoid.WalkSpeed (see the note at the top of the file), and
-- a freeze that wrote the property from outside would be exactly the kind of
-- second writer that authority exists to prevent -- it would also lose every
-- race against a sprint remote arriving a frame later.
--
-- Jump is left alone on purpose. An anchored root cannot jump anyway, and
-- StageLayout solves every gap in the game against Roblox's stock JumpPower of
-- 50 on the stated assumption that nothing in this codebase ever writes it.
function MovementService.SetFrozen(player: Player, isFrozen: boolean)
	local userId = player.UserId
	if isFrozen then
		frozen[userId] = true
		local humanoid = getHumanoid(player)
		if humanoid then
			humanoid.WalkSpeed = 0
		end
	else
		frozen[userId] = nil
		-- Straight back to whatever they're holding now, cancelling any
		-- override the same way ClearSpeedOverride does -- a countdown is
		-- exactly the window in which a stale Surge should not survive.
		speedOverrideUntil[userId] = nil
		applySprint(player, sprintIntent[userId] or false)
	end
end

-- Cancels any in-flight override and snaps WalkSpeed straight back to the
-- player's CURRENT sprint intent. Called by MatchService every time a racer's
-- position is force-reset (fall recovery, quit, finish). A fall in a race is a
-- teleport back to your last checkpoint, not a character respawn, so the
-- CharacterAdded reset below never fires for it -- which is why a Stage4 speed
-- strip's 42 WalkSpeed kept running after you'd been recovered, and followed
-- you back into the lobby if you finished while it was still active.
function MovementService.ClearSpeedOverride(player: Player)
	local userId = player.UserId
	speedOverrideUntil[userId] = nil
	applySprint(player, sprintIntent[userId] or false)
end

function MovementService.Init()
	local sprintIntentRemote = Net.CreateRemoteEvent(RemoteNames.SetSprintIntent)

	sprintIntentRemote.OnServerEvent:Connect(function(player: Player, isSprinting: boolean)
		if typeof(isSprinting) ~= "boolean" then
			return
		end

		local now = os.clock()
		local userId = player.UserId
		if lastIntentTime[userId] and now - lastIntentTime[userId] < MIN_INTENT_INTERVAL then
			return
		end
		lastIntentTime[userId] = now

		applySprint(player, isSprinting)
	end)

	-- Roblox's own default control scheme ALSO binds Shift to toggle Shift
	-- Lock (mouse-locked camera mode) -- both that and SprintController's
	-- sprint binding fire on the same keypress since neither consumes the
	-- input from the other, so on some platforms Shift ends up toggling
	-- Shift Lock instead of (or as well as) sprinting. DevEnableMouseLock
	-- removes Shift Lock as a feature entirely (the keybind AND its UI
	-- toggle icon) -- settable from the server only (a client LocalScript
	-- gets "Insufficient permissions" trying to set this directly), which is
	-- fine here since it's a fixed, game-wide setting, not per-player state.
	local function disableShiftLock(player: Player)
		player.DevEnableMouseLock = false
	end

	Players.PlayerAdded:Connect(function(player: Player)
		disableShiftLock(player)
		player.CharacterAdded:Connect(function()
			speedOverrideUntil[player.UserId] = nil
			applySprint(player, false)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		lastIntentTime[player.UserId] = nil
		sprintIntent[player.UserId] = nil
		speedOverrideUntil[player.UserId] = nil
		speedCheckGraceUntil[player.UserId] = nil
	end)

	for _, player in Players:GetPlayers() do
		disableShiftLock(player)
		player.CharacterAdded:Connect(function()
			speedOverrideUntil[player.UserId] = nil
			applySprint(player, false)
		end)
	end
end

return MovementService
