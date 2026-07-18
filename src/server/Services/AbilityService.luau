local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Constants = require(Shared.Constants)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

-- The game's one universal "ability": a short, cooldown-gated dash, free for
-- everyone (see the comment on Constants.Ability for why it's not a
-- pickup/Robux perk). Same server-authoritative shape as MovementService's
-- sprint: the client only ever sends "dash now", never a direction or speed
-- -- the server decides both from its own view of the character, exactly
-- like SetSprintIntent, so a hacked client gains nothing by spamming this
-- beyond what a legitimate press already does (and the cooldown is enforced
-- here, not trusted from the client).
local AbilityService = {}

local DASH_COOLDOWN = Constants.Ability.DashCooldownSeconds
local DASH_SPEED = Constants.Ability.DashSpeed
local DASH_DURATION = Constants.Ability.DashDurationSeconds
local DASH_SOUND_ID = "rbxassetid://9114157695" -- Doppler Whooshes Crackly Airy Bursts 2 (SFX), Pro Sound Effects -- verified via insert_asset before wiring in

local lastDashTime: { [number]: number } = {}

-- Dash direction is "wherever you're currently trying to move", falling back
-- to "wherever you're facing" if standing still -- matches the intuitive
-- read of a tap-to-dash key in basically every game that has one.
local function getDashDirection(character: Model): Vector3?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not root then
		return nil
	end

	local moveDirection = humanoid.MoveDirection
	if moveDirection.Magnitude > 0.1 then
		return moveDirection.Unit
	end
	return root.CFrame.LookVector
end

local function applyDash(root: BasePart, direction: Vector3)
	-- A one-time AssemblyLinearVelocity set gets overridden almost
	-- immediately by the Humanoid's own ground-control physics (a known
	-- Roblox quirk -- see BotService's jumpToward, which sidesteps it by
	-- being airborne). BodyVelocity is a real physics force that keeps
	-- winning against that for as long as it exists, which is what makes
	-- this actually readable as a burst instead of a barely-there twitch.
	-- MaxForce only has X/Z so it never fights gravity or a jump in progress.
	local bodyVelocity = Instance.new("BodyVelocity")
	bodyVelocity.MaxForce = Vector3.new(1e5, 0, 1e5)
	bodyVelocity.Velocity = Vector3.new(direction.X, 0, direction.Z) * DASH_SPEED
	bodyVelocity.Parent = root
	Debris:AddItem(bodyVelocity, DASH_DURATION)

	-- A 3D Sound parented to the root replicates and plays positionally for
	-- free -- nearby players hear a competitor whoosh past without needing a
	-- separate broadcast remote. Routed through the shared "SFX" SoundGroup
	-- (see AudioService) so each client's own SFX volume preference in
	-- Settings applies to it too, not just locally-created UI sounds.
	local sound = Instance.new("Sound")
	sound.SoundId = DASH_SOUND_ID
	sound.Volume = 0.65
	sound.PlaybackSpeed = 1.6 -- the source clip is a lazy 2.3s doppler whoosh; sped up reads as a snappy burst instead
	sound.RollOffMaxDistance = 60
	sound.SoundGroup = SoundService:FindFirstChild("SFX") :: SoundGroup?
	sound.Parent = root
	sound:Play()
	Debris:AddItem(sound, 2)
end

local function onRequestDash(player: Player)
	local userId = player.UserId
	local now = os.clock()
	if lastDashTime[userId] and now - lastDashTime[userId] < DASH_COOLDOWN then
		return
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not character or not root then
		return
	end

	local direction = getDashDirection(character)
	if not direction then
		return
	end

	lastDashTime[userId] = now
	applyDash(root, direction)
end

-- Called by MatchService the instant a race's timer actually starts (not the
-- earlier free-warmup teleport). Using a dash during the 8s pre-race warmup
-- shouldn't cost you it once the clock that actually matters starts -- same
-- "clean slate at race start" idea beginRace already applies to position/
-- checkpoints, just extended to this too.
function AbilityService.ResetDashCooldown(player: Player)
	lastDashTime[player.UserId] = nil
end

function AbilityService.Init()
	local requestDashRemote = Net.CreateRemoteEvent(RemoteNames.RequestDash)
	requestDashRemote.OnServerEvent:Connect(onRequestDash)

	Players.PlayerRemoving:Connect(function(player: Player)
		lastDashTime[player.UserId] = nil
	end)
end

return AbilityService
