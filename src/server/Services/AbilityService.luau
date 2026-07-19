local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Abilities = require(Shared.Abilities)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

local MovementService = require(script.Parent.MovementService)
local PlayerDataService = require(script.Parent.PlayerDataService)

-- Equip-one-of-many: every player always owns Dash for free (see
-- Abilities.luau) and can additionally own whatever they've won from the
-- gacha (see GachaService), but only ever has ONE equipped at a time
-- (profile.EquippedAbility). Same server-authoritative shape throughout as
-- the old Dash-only version: the client only ever sends "use my ability
-- now", never a direction/speed/target -- the server looks up which ability
-- that actually is and decides everything about its effect, so a hacked
-- client gains nothing beyond what a legitimate press already does.
local AbilityService = {}

-- Doppler Whooshes Crackly Airy Bursts 2 (SFX), Pro Sound Effects -- verified
-- via insert_asset before wiring in. Covers Dash/Blink/Speed; Hop gets its
-- own sound below since a burst-whoosh doesn't read as "jump" the way a
-- spring/boing does -- see the module comment on WHOOSH_KINDS.
local ABILITY_SOUND_ID = "rbxassetid://9114157695"
-- "Cartoon Spring Bounce Sound" by MysteryMilo (free) -- verified via
-- insert_asset before wiring in, same discipline as ABILITY_SOUND_ID above.
local HOP_SOUND_ID = "rbxassetid://6075441854"
local BLINK_CLEARANCE = 3 -- Blink stops this many studs short of whatever its raycast hits, so it can't clip a character partway into a wall

local lastAbilityUseTime: { [number]: number } = {}
local abilityEquippedRemote: RemoteEvent

local function getAbilityById(id: string): Abilities.AbilityInfo?
	for _, info in Abilities do
		if info.Id == id then
			return info
		end
	end
	return nil
end

local DEFAULT_ABILITY = assert(getAbilityById("Dash"), "Abilities.luau must define Dash")

local function getEquippedAbility(player: Player): Abilities.AbilityInfo
	local profile = PlayerDataService.GetProfile(player)
	local id = profile and profile.EquippedAbility
	return (id and getAbilityById(id)) or DEFAULT_ABILITY
end

-- Ability direction is "wherever you're currently trying to move", falling
-- back to "wherever you're facing" if standing still -- matches the
-- intuitive read of a tap-to-activate key in basically every game that has
-- one. Used by Dash and Blink; Hop and Surge don't need a direction at all.
local function getAbilityDirection(character: Model): Vector3?
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

-- A rarer pull already reads as a bigger deal visually (see
-- AbilityController's rarity-tinted flash) -- Hop gets a genuinely different
-- SOUND on top of that, not just a louder whoosh, because "what did that
-- ability just do" was the actual player-facing confusion: a burst-whoosh
-- reads as "moved forward," which is exactly the wrong cue for an ability
-- that's entirely vertical.
local function playAbilitySound(root: BasePart, kind: Abilities.AbilityKind)
	-- A 3D Sound parented to the root replicates and plays positionally for
	-- free -- nearby players hear a competitor's ability go off without
	-- needing a separate broadcast remote. Routed through the shared "SFX"
	-- SoundGroup (see AudioService) so each client's own SFX volume
	-- preference in Settings applies to it too, not just locally-created UI
	-- sounds.
	local sound = Instance.new("Sound")
	if kind == "Hop" then
		sound.SoundId = HOP_SOUND_ID
		sound.PlaybackSpeed = 1 -- the spring/boing clip already reads right at its native pace
	else
		sound.SoundId = ABILITY_SOUND_ID
		sound.PlaybackSpeed = 1.6 -- the source clip is a lazy 2.3s doppler whoosh; sped up reads as a snappy burst instead
	end
	sound.Volume = 0.65
	sound.RollOffMaxDistance = 60
	sound.SoundGroup = SoundService:FindFirstChild("SFX") :: SoundGroup?
	sound.Parent = root
	sound:Play()
	Debris:AddItem(sound, 2)
end

-- Dash and Meteor both resolve here (Kind == "Dash") -- Meteor is just bigger
-- numbers plus a non-nil UpwardBoost. MaxForce only gets a Y component when
-- there's actual lift to apply, so plain Dash still never fights gravity or
-- a jump in progress (see the BodyVelocity-vs-AssemblyLinearVelocity
-- reasoning below in applyHopEffect).
local function applyDashEffect(root: BasePart, direction: Vector3, info: Abilities.AbilityInfo)
	local hasLift = (info.UpwardBoost or 0) > 0

	local bodyVelocity = Instance.new("BodyVelocity")
	bodyVelocity.MaxForce = Vector3.new(1e5, if hasLift then 1e5 else 0, 1e5)
	bodyVelocity.Velocity = Vector3.new(direction.X, 0, direction.Z) * (info.Speed or 0) + Vector3.new(0, info.UpwardBoost or 0, 0)
	bodyVelocity.Parent = root
	Debris:AddItem(bodyVelocity, info.DurationSeconds or 0.18)

	playAbilitySound(root, info.Kind)
end

-- A one-time AssemblyLinearVelocity set gets overridden almost immediately by
-- the Humanoid's own grounded-state physics -- ChangeState to Jumping first
-- (same trick BotService.jumpToward uses) so the engine treats this as an
-- actual jump in progress instead of stomping the velocity back to zero next
-- physics step.
local function applyHopEffect(humanoid: Humanoid, root: BasePart, info: Abilities.AbilityInfo)
	humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	local velocity = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(velocity.X, info.UpwardBoost or 0, velocity.Z)
	playAbilitySound(root, info.Kind)
end

-- Raycasts along the blink direction so blinking into a wall stops short of
-- it instead of clipping through -- the one ability here that isn't a pure
-- velocity nudge, since a teleport has no travel time for collision to
-- naturally stop it the way the others' brief bursts do.
local function applyBlinkEffect(character: Model, root: BasePart, direction: Vector3, info: Abilities.AbilityInfo)
	local distance = info.BlinkDistance or 20
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { character }

	local result = Workspace:Raycast(root.Position, direction * distance, raycastParams)
	local travel = if result then math.max(0, result.Distance - BLINK_CLEARANCE) else distance

	root.CFrame += direction * travel
	-- Post-teleport momentum is zeroed horizontally (carrying pre-blink speed
	-- into the new spot would read as an unintended slide) but vertical speed
	-- is kept so blinking mid-fall still keeps falling naturally.
	root.AssemblyLinearVelocity = Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
	playAbilitySound(root, info.Kind)
end

local function onRequestAbility(player: Player)
	local userId = player.UserId
	local info = getEquippedAbility(player)

	local now = os.clock()
	if lastAbilityUseTime[userId] and now - lastAbilityUseTime[userId] < info.CooldownSeconds then
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not character or not humanoid or not root then
		return
	end

	if info.Kind == "Speed" then
		lastAbilityUseTime[userId] = now
		MovementService.ApplySpeedOverride(player, info.Speed or 0, info.DurationSeconds or 0)
		return
	end

	if info.Kind == "Hop" then
		lastAbilityUseTime[userId] = now
		applyHopEffect(humanoid, root, info)
		return
	end

	-- Dash and Blink both need a direction to fire in; no direction (e.g. no
	-- Humanoid, though already checked above) means nothing to do.
	local direction = getAbilityDirection(character)
	if not direction then
		return
	end
	lastAbilityUseTime[userId] = now

	if info.Kind == "Blink" then
		applyBlinkEffect(character, root, direction, info)
	else
		applyDashEffect(root, direction, info)
	end
end

local function handleEquip(player: Player, abilityId: string): (boolean, string)
	local profile = PlayerDataService.GetProfile(player)
	if not profile then
		return false, "Profile not loaded"
	end
	if not getAbilityById(abilityId) then
		return false, "Unknown ability"
	end
	if not table.find(profile.OwnedAbilities, abilityId) then
		return false, "Not owned"
	end

	profile.EquippedAbility = abilityId
	abilityEquippedRemote:FireClient(player, abilityId)
	return true, "Equipped"
end

-- Called by MatchService the instant a race's timer actually starts (not the
-- earlier free-warmup teleport). Using an ability during the pre-race
-- warmup shouldn't cost you it once the clock that actually matters starts --
-- same "clean slate at race start" idea beginRace already applies to
-- position/checkpoints, just extended to this too.
function AbilityService.ResetCooldown(player: Player)
	lastAbilityUseTime[player.UserId] = nil
end

function AbilityService.Init()
	local requestAbilityRemote = Net.CreateRemoteEvent(RemoteNames.RequestAbility)
	requestAbilityRemote.OnServerEvent:Connect(onRequestAbility)

	abilityEquippedRemote = Net.CreateRemoteEvent(RemoteNames.AbilityEquipped)

	local equipAbilityRemote = Net.CreateRemoteFunction(RemoteNames.EquipAbility)
	equipAbilityRemote.OnServerInvoke = function(player: Player, abilityId: string)
		return handleEquip(player, abilityId)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		lastAbilityUseTime[player.UserId] = nil
	end)
end

return AbilityService
