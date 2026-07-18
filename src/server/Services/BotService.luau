local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

-- Real Humanoid + real physics jumps, not a scripted glide: each hop solves
-- an actual projectile arc (launch velocity from horizontal distance +
-- height delta, under the game's real gravity) and hands that to the
-- HumanoidRootPart, then lets Roblox's own physics carry it through the
-- jump and land it -- same as a player's jump, just aimed by math instead
-- of a keypress. "Easy to beat" now comes from pacing (a reaction pause
-- before each jump) rather than the bot being unable to jump at all.
local BotService = {}

export type BotHandle = {
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	cancelled: boolean,
}

local BOTS_GROUP = "Bots"
local PLAYER_CHARACTERS_GROUP = "PlayerCharacters"

-- Landing on a platform needs the root part solid (CanCollide = true) --
-- there's no separate leg/torso rig to carry that instead -- so "can't push
-- each other" is enforced through collision groups now rather than a blanket
-- CanCollide = false: Bots still collide with the world (Default, unchanged)
-- but never with PlayerCharacters, and vice versa.
local function setupCollisionGroups()
	pcall(function()
		PhysicsService:RegisterCollisionGroup(BOTS_GROUP)
	end)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(PLAYER_CHARACTERS_GROUP)
	end)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(BOTS_GROUP, PLAYER_CHARACTERS_GROUP, false)
	end)
end

local function assignCollisionGroup(instance: Instance, groupName: string)
	if instance:IsA("BasePart") then
		instance.CollisionGroup = groupName
	end
end

local function tagCharacter(character: Model)
	for _, descendant in character:GetDescendants() do
		assignCollisionGroup(descendant, PLAYER_CHARACTERS_GROUP)
	end
	character.DescendantAdded:Connect(function(descendant)
		assignCollisionGroup(descendant, PLAYER_CHARACTERS_GROUP)
	end)
end

local ROOT_SIZE = Vector3.new(2, 2.4, 1)
local ROOT_HALF_HEIGHT = ROOT_SIZE.Y / 2
-- First attempt at "50% faster" bumped WALK_SPEED 18->27 and halved the
-- reaction pause, but adding the run phase (see runToEdge) at the same time
-- ate the whole savings back -- a timed live run came back at ~30s, a wash
-- against the pre-change baseline. Reaction pause is the lever that doesn't
-- cost any realism (it's a decision-making beat, not motion), so most of the
-- real speedup comes from cutting that hard; WALK_SPEED and JUMP_CLEARANCE
-- (less arc height = less air time) each got pushed further too. Re-verified
-- with fresh timed solo runs on two different stages: Stage2 (14 platforms)
-- 30.04s -> 14.74s, Stage3 (16 platforms) 15.03s -- essentially the 50%
-- asked for, and neither run got stuck.
local WALK_SPEED = 34
local JUMP_CLEARANCE = 1.8 -- studs of arc height above the target platform; enough clearance to still land reliably (LANDING_TOLERANCE backstops the rest), less hang-time than before
local REACTION_PAUSE_MIN = 0.2
local REACTION_PAUSE_MAX = 0.4
local LANDING_TOLERANCE = 3 -- studs; if physics didn't land it this close, snap-correct so the race can't get stuck
local EDGE_MARGIN = 0.6 -- studs kept back from a platform's true edge as the run target, so it doesn't look like launching from mid-air
local RUN_TIMEOUT = 3 -- safety cap so a run stuck on weird geometry can't hang the race forever

local function getWaypoints(stageId: string): { BasePart }
	local stagesFolder = Workspace:FindFirstChild("Stages")
	local stageFolder = stagesFolder and stagesFolder:FindFirstChild(stageId)
	if not stageFolder then
		return {}
	end

	local waypoints: { BasePart } = {}
	local start = stageFolder:FindFirstChild("Platform_Start")
	if start and start:IsA("BasePart") then
		table.insert(waypoints, start)
	end

	local i = 1
	while stageFolder:FindFirstChild("Platform_" .. i) do
		local platform = stageFolder["Platform_" .. i]
		if platform:IsA("BasePart") then
			table.insert(waypoints, platform)
		end
		i += 1
	end

	local finish = stageFolder:FindFirstChild("Platform_Finish")
	if finish and finish:IsA("BasePart") then
		table.insert(waypoints, finish)
	end

	return waypoints
end

local function landingPoint(platform: BasePart): Vector3
	return platform.Position + Vector3.new(0, platform.Size.Y / 2 + ROOT_HALF_HEIGHT, 0)
end

-- Point on top of `platform` closest to `targetPosition`'s direction, inset
-- by EDGE_MARGIN so the run target isn't the literal edge. Done in the
-- platform's own object space so this still works if a platform is rotated,
-- not just axis-aligned ones.
local function edgeTowardTarget(platform: BasePart, targetPosition: Vector3): Vector3
	local relative = platform.CFrame:PointToObjectSpace(targetPosition)
	local halfSize = platform.Size / 2
	local marginX = math.min(EDGE_MARGIN, halfSize.X * 0.45)
	local marginZ = math.min(EDGE_MARGIN, halfSize.Z * 0.45)
	local clampedX = math.clamp(relative.X, -halfSize.X + marginX, halfSize.X - marginX)
	local clampedZ = math.clamp(relative.Z, -halfSize.Z + marginZ, halfSize.Z - marginZ)
	return platform.CFrame:PointToWorldSpace(Vector3.new(clampedX, halfSize.Y, clampedZ))
end

-- Actually runs across the current platform toward the takeoff point nearest
-- the next one first, instead of the old behavior of standing still while
-- jumpToward's arc alone covered the *entire* platform-to-platform distance
-- -- which read as teleport-y since the bot never visibly moved on the
-- ground at all. Driven the same way jumpToward drives its arc (direct
-- AssemblyLinearVelocity, polled to an exit condition) rather than
-- Humanoid:MoveTo, since this rig has no legs/animation to benefit from the
-- built-in pathing and direct velocity keeps the pace exactly at WALK_SPEED.
local function runToEdge(bot: BotHandle, currentPlatform: BasePart, targetPlatform: BasePart)
	local root = bot.root
	local takeoff = edgeTowardTarget(currentPlatform, targetPlatform.Position) + Vector3.new(0, ROOT_HALF_HEIGHT, 0)

	local flat = Vector3.new(takeoff.X - root.Position.X, 0, takeoff.Z - root.Position.Z)
	if flat.Magnitude < 1 then
		return
	end
	local direction = flat.Unit
	root.CFrame = CFrame.new(root.Position, root.Position + direction)
	bot.humanoid:ChangeState(Enum.HumanoidStateType.Running)

	local elapsed = 0
	while elapsed < RUN_TIMEOUT and not bot.cancelled do
		local remaining = Vector3.new(takeoff.X - root.Position.X, 0, takeoff.Z - root.Position.Z)
		if remaining.Magnitude < 1.2 then
			break
		end
		root.AssemblyLinearVelocity = Vector3.new(direction.X * WALK_SPEED, root.AssemblyLinearVelocity.Y, direction.Z * WALK_SPEED)
		task.wait(0.05)
		elapsed += 0.05
	end
	root.AssemblyLinearVelocity = Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
end

local function buildModel(spawnPosition: Vector3): (Model, Humanoid, BasePart)
	local model = Instance.new("Model")
	model.Name = "RaceBot"

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = ROOT_SIZE
	root.Material = Enum.Material.ForceField -- built-in scrolling hologram shader, no custom texture needed
	root.Color = Color3.fromRGB(90, 220, 255)
	root.Transparency = 0.25
	root.CanCollide = true
	root.Anchored = false
	root.CFrame = CFrame.new(spawnPosition)
	root.CollisionGroup = BOTS_GROUP
	root.Parent = model

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Shape = Enum.PartType.Ball
	head.Size = Vector3.new(1.3, 1.3, 1.3)
	head.Material = Enum.Material.ForceField
	head.Color = Color3.fromRGB(150, 235, 255)
	head.Transparency = 0.2
	head.CanCollide = false
	head.Anchored = false
	head.CFrame = root.CFrame + Vector3.new(0, ROOT_HALF_HEIGHT + 0.9, 0)
	head.CollisionGroup = BOTS_GROUP
	head.Parent = model

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = head
	weld.Parent = root

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(120, 220, 255)
	light.Range = 12
	light.Brightness = 2
	light.Parent = root

	local nameTag = Instance.new("BillboardGui")
	nameTag.Name = "BotLabel"
	nameTag.Size = UDim2.fromOffset(110, 26)
	nameTag.StudsOffset = Vector3.new(0, 1.3, 0)
	nameTag.AlwaysOnTop = true
	nameTag.Parent = head

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "BOT"
	label.TextColor3 = Color3.fromRGB(150, 235, 255)
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Parent = nameTag

	local humanoid = Instance.new("Humanoid")
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None -- keep only our own BOT tag, not Roblox's default nameplate
	humanoid.WalkSpeed = WALK_SPEED
	humanoid.JumpPower = 50
	humanoid.Parent = model

	model.PrimaryPart = root
	model.Parent = Workspace

	return model, humanoid, root
end

-- Solves the launch velocity of a projectile (under real gravity) that
-- starts at `root`'s position and lands at `target`, then hands that
-- straight to the physics engine -- an actual simulated jump, not a scripted
-- path. Picking the apex from JUMP_CLEARANCE above the *target* height (not
-- a fixed value) is what keeps this reliable across both downhill and
-- steep-uphill hops.
local function jumpToward(bot: BotHandle, target: Vector3)
	local root = bot.root
	local horizontal = Vector3.new(target.X - root.Position.X, 0, target.Z - root.Position.Z)
	local distance = horizontal.Magnitude
	if distance < 0.1 then
		return
	end
	local direction = horizontal.Unit
	local dy = target.Y - root.Position.Y

	local gravity = Workspace.Gravity
	local apexHeight = math.max(dy, 0) + JUMP_CLEARANCE
	local vy0 = math.sqrt(2 * gravity * apexHeight)
	local underSqrt = math.max(vy0 * vy0 - 2 * gravity * dy, 0)
	local airTime = (vy0 + math.sqrt(underSqrt)) / gravity
	local vh = distance / airTime

	-- Face the jump direction before launching -- purely cosmetic (position
	-- is untouched), just keeps it from flying through the air sideways.
	root.CFrame = CFrame.new(root.Position, root.Position + Vector3.new(direction.X, 0, direction.Z))

	bot.humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	root.AssemblyLinearVelocity = Vector3.new(direction.X * vh, vy0, direction.Z * vh)

	task.wait(airTime + 0.15)

	-- Physics doesn't always land pixel-perfect (grazing a platform edge,
	-- clipping a corner) -- if it's not close enough after the computed
	-- flight time, snap it the rest of the way so one bad landing can't
	-- strand the whole race.
	if (Vector3.new(root.Position.X, target.Y, root.Position.Z) - target).Magnitude > LANDING_TOLERANCE then
		root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		root.CFrame = CFrame.new(target)
	end
end

function BotService.SpawnBot(stageId: string): BotHandle?
	local waypoints = getWaypoints(stageId)
	local start = waypoints[1]
	if not start then
		return nil
	end

	local model, humanoid, root = buildModel(landingPoint(start))
	return { model = model, humanoid = humanoid, root = root, cancelled = false }
end

-- Jumps through every waypoint in order, then calls onFinished() -- unless
-- DespawnBot cancelled it first, in which case onFinished is never called.
function BotService.RunBot(bot: BotHandle, stageId: string, onFinished: () -> ())
	local waypoints = getWaypoints(stageId)

	task.spawn(function()
		for i = 2, #waypoints do
			if bot.cancelled then
				return
			end
			task.wait(REACTION_PAUSE_MIN + math.random() * (REACTION_PAUSE_MAX - REACTION_PAUSE_MIN))
			if bot.cancelled then
				return
			end
			runToEdge(bot, waypoints[i - 1], waypoints[i])
			if bot.cancelled then
				return
			end
			jumpToward(bot, landingPoint(waypoints[i]))
		end
		if not bot.cancelled then
			onFinished()
		end
	end)
end

function BotService.DespawnBot(bot: BotHandle?)
	if not bot then
		return
	end
	bot.cancelled = true
	if bot.model and bot.model.Parent then
		bot.model:Destroy()
	end
end

function BotService.Init()
	setupCollisionGroups()

	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(tagCharacter)
		if player.Character then
			tagCharacter(player.Character)
		end
	end)

	for _, player in Players:GetPlayers() do
		player.CharacterAdded:Connect(tagCharacter)
		if player.Character then
			tagCharacter(player.Character)
		end
	end
end

return BotService
