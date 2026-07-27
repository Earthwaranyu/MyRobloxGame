local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Stages = require(Shared.Stages)
local MovementService = require(script.Parent.MovementService)

-- Until now all four stages were the same static "jump from platform to
-- platform" course with only a color/weather reskin (StageDecorationService).
-- Nothing MOVED, so once you'd cleared one stage you'd effectively cleared
-- them all -- no reason to replay, nothing clip-worthy. This bolts one
-- signature, animated mechanic onto each stage, purely by animating /
-- augmenting the platforms that already exist in the Workspace (it never
-- needs to know the hand-built geometry ahead of time):
--
--   Stage1 (Sunny/Easy)   Bounce    launch pads -- playful, hard to fail
--   Stage2 (Stormy/Med)   Moving    platforms slide; jump when they line up
--   Stage3 (Night/Hard)   Vanishing platforms fade then drop on a cycle
--   Stage4 (Windy/Med)    Speed     floor strips granting a forward surge
--
-- Everything is server-authoritative (pads set velocity / call
-- MovementService), so it replicates to every client and can't be spoofed.
-- Functional markers (StartLine/FinishLine/Checkpoint/SpawnLocation) are
-- never touched, mirroring StageDecorationService, and the first & last
-- platform of every stage are left solid & still so players always have safe
-- footing to start from and land on at the finish.
local StageGimmickService = {}

-- Straight up, deliberately: the pad only buys you air, and you steer with
-- your own run. Adding a forward kick stacked on top of the walk speed a
-- player is already holding and shot them clean over the next platform.
-- Tuned against Stage1's real geometry (flat, gaps up to ~14 studs): ~17
-- studs of rise, roughly a second of hang time, which a walking player
-- converts into just over one gap.
local BOUNCE_UP = 55 -- studs/s upward impulse
local BOUNCE_COOLDOWN = 0.4
local BOUNCE_THRUST = 0.12 -- seconds the launch constraint stays alive

local SPEED_BOOST = 42 -- WalkSpeed while on a speed strip
local SPEED_DURATION = 1.5
local SPEED_COOLDOWN = 0.5

local MOVE_AMPLITUDE_FACTOR = 0.6 -- of the platform's smaller horizontal side
local MOVE_PERIOD = 3 -- seconds for a full slide out-and-back

-- Vanishing cycle: solid, then a blinking warning, then gone, then back.
local VANISH_SOLID = 2.2
local VANISH_WARN = 0.9
local VANISH_GONE = 1.4

local function isPlatform(part: Instance): boolean
	return part:IsA("BasePart") and part.Name:match("^Platform") ~= nil
end

-- Gather a stage's platforms sorted along the course (the horizontal axis
-- they're most spread out on) so "every other platform" reads as an even
-- rhythm down the track rather than a random scatter.
local function sortedPlatforms(stageFolder: Folder): { BasePart }
	local platforms: { BasePart } = {}
	for _, child in stageFolder:GetChildren() do
		if isPlatform(child) then
			table.insert(platforms, child :: BasePart)
		end
	end
	if #platforms < 2 then
		return platforms
	end

	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, p in platforms do
		minX, maxX = math.min(minX, p.Position.X), math.max(maxX, p.Position.X)
		minZ, maxZ = math.min(minZ, p.Position.Z), math.max(maxZ, p.Position.Z)
	end

	local axisX = (maxX - minX) >= (maxZ - minZ)
	table.sort(platforms, function(a, b)
		return (if axisX then a.Position.X else a.Position.Z) < (if axisX then b.Position.X else b.Position.Z)
	end)
	return platforms
end

-- Horizontal unit vector pointing from the start platform toward the finish;
-- used to work out which way the moving platforms should slide across it.
local function courseDirection(platforms: { BasePart }): Vector3
	local first, last = platforms[1], platforms[#platforms]
	local delta = last.Position - first.Position
	local flat = Vector3.new(delta.X, 0, delta.Z)
	if flat.Magnitude < 0.1 then
		return Vector3.new(0, 0, -1)
	end
	return flat.Unit
end

-- Platforms we animate/augment: every other one, never the first or last.
local function targetPlatforms(platforms: { BasePart }): { BasePart }
	local targets: { BasePart } = {}
	for i = 2, #platforms - 1, 2 do
		table.insert(targets, platforms[i])
	end
	return targets
end

local function makePad(platform: BasePart, name: string, color: Color3): BasePart
	local pad = Instance.new("Part")
	pad.Name = name
	pad.Anchored = true
	pad.CanCollide = false
	pad.Material = Enum.Material.Neon
	pad.Color = color
	pad.Transparency = 0.15
	pad.Size = Vector3.new(platform.Size.X * 0.85, 0.4, platform.Size.Z * 0.85)
	pad.CFrame = platform.CFrame * CFrame.new(0, platform.Size.Y / 2 + 0.2, 0)
	pad.Parent = platform
	return pad
end

local function onPlayerTouch(part: BasePart, handler: (Player, BasePart) -> ())
	part.Touched:Connect(function(hit)
		local character = hit.Parent
		local player = character and Players:GetPlayerFromCharacter(character)
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if player and root and root:IsA("BasePart") then
			handler(player, root :: BasePart)
		end
	end)
end

-- The character's root is network-owned by its client, so a server write to
-- AssemblyLinearVelocity is thrown away the moment the client's next physics
-- frame replicates back. A short-lived LinearVelocity constraint replicates as
-- an *instance* instead, so the owning client simulates the launch itself --
-- while the server still decides who gets launched, and how hard.
local function launch(root: BasePart, velocity: Vector3)
	local attachment = Instance.new("Attachment")
	attachment.Name = "BounceAttachment"
	attachment.Parent = root

	local mover = Instance.new("LinearVelocity")
	mover.Attachment0 = attachment
	mover.RelativeTo = Enum.ActuatorRelativeTo.World
	mover.MaxForce = math.huge
	mover.VectorVelocity = velocity
	mover.Parent = root

	task.delay(BOUNCE_THRUST, function()
		mover:Destroy()
		attachment:Destroy()
	end)
end

local function applyBounce(platforms: { BasePart })
	local cooldownUntil: { [Instance]: number } = {}
	for _, platform in targetPlatforms(platforms) do
		local pad = makePad(platform, "BouncePad", Color3.fromRGB(255, 214, 90))
		onPlayerTouch(pad, function(_player, root)
			local now = os.clock()
			if cooldownUntil[root] and now < cooldownUntil[root] then
				return
			end
			cooldownUntil[root] = now + BOUNCE_COOLDOWN
			launch(root, Vector3.new(root.AssemblyLinearVelocity.X, BOUNCE_UP, root.AssemblyLinearVelocity.Z))
		end)
	end
end

-- Speed strips used to be a flat cyan square, which made them essentially
-- indistinguishable from a checkpoint pad -- same material, same shape, same
-- near-identical colour (see StageDecorationService for the full comparison
-- and the split those two now follow). This builds the other half of that
-- split: the Mario Kart dash-panel look, which is the most widely understood
-- "run over this to go fast" signifier there is.
--
--   * ORANGE, not cyan -- as far from the checkpoints' green as the colour
--     wheel allows, and the one pairing that stays separable under every
--     common form of colour blindness.
--   * A STRIP, not a square -- elongated along the course, so its own shape
--     tells you which way it's sending you before you touch it.
--   * SCROLLING CHEVRONS -- motion is what makes it unmistakable at running
--     speed, and it's the single cue no checkpoint ever has (those are
--     deliberately, completely static).
local SPEED_COLOR = Color3.fromRGB(255, 138, 30)
local CHEVRON_COLOR = Color3.fromRGB(255, 250, 235)
local CHEVRONS_PER_STRIP = 3
local CHEVRON_SCROLL_SPEED = 9 -- studs/s, forward along the course
local CHEVRON_HALF_ANGLE = math.rad(52) -- shallow enough to read flat-on
local CHEVRON_BAR_THICKNESS = 0.34

type Chevron = { a: BasePart, b: BasePart, slot: number }
-- `travel` is how far the chevron TIP can slide and still leave the bars
-- trailing behind it inside the strip -- i.e. the strip's length minus the
-- depth one chevron occupies. Scrolling over the raw length instead let each
-- chevron overhang the trailing edge by its own depth (measured: bars reaching
-- 3.18 studs out on a strip only 2.68 studs long from the centre).
type Strip = {
	origin: CFrame,
	length: number,
	depth: number,
	travel: number,
	spacing: number,
	chevrons: { Chevron },
}

local activeStrips: { Strip } = {}
local chevronLoopStarted = false

-- Chevrons ride ON the strip's own surface, so everything below is expressed
-- in the strip's local space: local -Z is "down the course" (CFrame.lookAt
-- points LookVector, i.e. -Z, at the target), local X is across it.
local function buildChevron(strip: BasePart, width: number): Chevron
	-- Two bars meeting at a point, forming a ">" aimed down the course. Half
	-- the chevron's span is barLength * sin(angle), so solve for the bar
	-- length that makes the chevron exactly as wide as the strip.
	local barLength = (width / 2) / math.sin(CHEVRON_HALF_ANGLE)
	local size = Vector3.new(CHEVRON_BAR_THICKNESS, 0.12, barLength)

	local function makeBar(): BasePart
		local bar = Instance.new("Part")
		bar.Name = "Chevron"
		bar.Anchored = true
		bar.CanCollide = false
		-- Purely decorative: must never shadow the strip's own Touched or
		-- block a raycast.
		bar.CanTouch = false
		bar.CanQuery = false
		bar.Material = Enum.Material.Neon
		bar.Color = CHEVRON_COLOR
		bar.Size = size
		bar.Parent = strip
		return bar
	end

	return { a = makeBar(), b = makeBar(), slot = 0 }
end

-- Puts one chevron's tip at `tipZ` in the strip's local space, with its two
-- bars trailing diagonally back off it (+Z is behind, since local -Z is the
-- way the strip throws you).
local function positionChevron(chevron: Chevron, origin: CFrame, tipZ: number)
	local barLength = chevron.a.Size.Z
	local halfSpan = math.sin(CHEVRON_HALF_ANGLE) * barLength / 2
	local backZ = math.cos(CHEVRON_HALF_ANGLE) * barLength / 2

	chevron.a.CFrame = origin * CFrame.new(halfSpan, 0, tipZ + backZ) * CFrame.Angles(0, CHEVRON_HALF_ANGLE, 0)
	chevron.b.CFrame = origin * CFrame.new(-halfSpan, 0, tipZ + backZ) * CFrame.Angles(0, -CHEVRON_HALF_ANGLE, 0)
end

local function startChevronLoop()
	if chevronLoopStarted then
		return
	end
	chevronLoopStarted = true

	RunService.Heartbeat:Connect(function()
		-- One shared phase for every strip on the stage, so the whole run
		-- pulses in step rather than looking like unrelated flickering.
		local phase = (os.clock() * CHEVRON_SCROLL_SPEED)
		for _, strip in activeStrips do
			-- Rearmost tip position that still leaves a whole chevron on the
			-- strip; each one slides forward from here and the one that
			-- reaches the front edge wraps back to it.
			local rearTipZ = strip.length / 2 - strip.depth
			for _, chevron in strip.chevrons do
				local distance = (chevron.slot * strip.spacing + phase) % strip.travel
				positionChevron(chevron, strip.origin, rearTipZ - distance)
			end
		end
	end)
end

local function makeSpeedStrip(platform: BasePart, direction: Vector3): BasePart
	local base = math.min(platform.Size.X, platform.Size.Z)
	local length = base * 0.95
	local width = base * 0.6

	local top = platform.Position + Vector3.new(0, platform.Size.Y / 2 + 0.2, 0)
	-- Oriented by the course, NOT by the platform -- the strip has to point
	-- where it actually throws you, whatever angle the platform sits at.
	local origin = CFrame.lookAt(top, top + direction)

	local strip = Instance.new("Part")
	strip.Name = "SpeedStrip"
	strip.Anchored = true
	strip.CanCollide = false
	strip.Material = Enum.Material.Neon
	strip.Color = SPEED_COLOR
	strip.Transparency = 0.15
	strip.Size = Vector3.new(width, 0.4, length)
	strip.CFrame = origin
	strip.Parent = platform

	local chevrons: { Chevron } = {}
	for i = 1, CHEVRONS_PER_STRIP do
		local chevron = buildChevron(strip, width * 0.8)
		chevron.slot = i - 1
		table.insert(chevrons, chevron)
	end

	-- How much of the strip's length one chevron eats up, tip to tail.
	local depth = math.cos(CHEVRON_HALF_ANGLE) * chevrons[1].a.Size.Z
	local travel = length - depth

	table.insert(activeStrips, {
		-- Slightly proud of the strip so the chevrons don't z-fight with it.
		origin = origin * CFrame.new(0, 0.22, 0),
		length = length,
		depth = depth,
		travel = travel,
		spacing = travel / CHEVRONS_PER_STRIP,
		chevrons = chevrons,
	})
	startChevronLoop()

	return strip
end

local function applySpeed(platforms: { BasePart }, direction: Vector3)
	local cooldownUntil: { [number]: number } = {}
	for _, platform in targetPlatforms(platforms) do
		local strip = makeSpeedStrip(platform, direction)
		onPlayerTouch(strip, function(player, _root)
			local now = os.clock()
			if cooldownUntil[player.UserId] and now < cooldownUntil[player.UserId] then
				return
			end
			cooldownUntil[player.UserId] = now + SPEED_COOLDOWN
			MovementService.ApplySpeedOverride(player, SPEED_BOOST, SPEED_DURATION)
		end)
	end
end

local function applyVanishing(platforms: { BasePart })
	for index, platform in targetPlatforms(platforms) do
		local baseColor = platform.Color
		-- Stagger each platform's cycle so a whole row never disappears at
		-- once -- there's always a path, it just shifts.
		local phase = (index % 3) * ((VANISH_SOLID + VANISH_WARN + VANISH_GONE) / 3)
		task.spawn(function()
			task.wait(phase)
			while platform.Parent do
				platform.Transparency = 0
				platform.CanCollide = true
				platform.Color = baseColor
				task.wait(VANISH_SOLID)

				-- Warning blink so a fall always feels fair, not cheap.
				local blinkEnd = os.clock() + VANISH_WARN
				while os.clock() < blinkEnd and platform.Parent do
					platform.Color = Color3.fromRGB(255, 80, 80)
					task.wait(0.15)
					platform.Color = baseColor
					task.wait(0.15)
				end

				platform.Transparency = 0.8
				platform.CanCollide = false
				task.wait(VANISH_GONE)
			end
		end)
	end
end

local function applyMoving(platforms: { BasePart }, direction: Vector3)
	-- Slide perpendicular to the course so platforms open and close the gap
	-- you're jumping across -- a timing puzzle rather than a conveyor.
	local sideways = Vector3.new(-direction.Z, 0, direction.X)
	local moving: { { part: BasePart, origin: Vector3, amp: number, phase: number } } = {}
	for index, platform in targetPlatforms(platforms) do
		local amp = math.min(platform.Size.X, platform.Size.Z) * MOVE_AMPLITUDE_FACTOR
		table.insert(moving, {
			part = platform,
			origin = platform.Position,
			amp = amp,
			phase = (index % 2) * math.pi, -- alternate direction so neighbours mirror
		})
	end

	if #moving == 0 then
		return
	end

	-- Runs for the server's lifetime -- the platforms should never stop moving.
	RunService.Heartbeat:Connect(function()
		local t = os.clock() * (2 * math.pi / MOVE_PERIOD)
		for _, m in moving do
			if m.part.Parent then
				local offset = sideways * (math.sin(t + m.phase) * m.amp)
				m.part.CFrame = CFrame.new(m.origin + offset) * (m.part.CFrame - m.part.CFrame.Position)
			end
		end
	end)
end

local function decorateStage(stageFolder: Folder, gimmick: string)
	if stageFolder:GetAttribute("GimmickApplied") then
		return
	end
	stageFolder:SetAttribute("GimmickApplied", true)

	local platforms = sortedPlatforms(stageFolder)
	if #platforms < 3 then
		return -- too short to carve out safe start/finish footing
	end
	local direction = courseDirection(platforms)

	if gimmick == "Bounce" then
		applyBounce(platforms)
	elseif gimmick == "Speed" then
		applySpeed(platforms, direction)
	elseif gimmick == "Vanishing" then
		applyVanishing(platforms)
	elseif gimmick == "Moving" then
		applyMoving(platforms, direction)
	end
end

function StageGimmickService.Init()
	local stagesFolder = Workspace:FindFirstChild("Stages")
	if not stagesFolder then
		return
	end

	for _, stage in Stages do
		local stageFolder = stagesFolder:FindFirstChild(stage.Id)
		if stageFolder and stageFolder:IsA("Folder") then
			decorateStage(stageFolder, stage.Gimmick)
		end
	end
end

return StageGimmickService
