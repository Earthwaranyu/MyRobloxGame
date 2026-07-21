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

local function applySprint(player: Player, isSprinting: boolean)
	local userId = player.UserId
	sprintIntent[userId] = isSprinting

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
