local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Hype = require(Shared.Hype)

-- A flickering flame above the overhead rank plate, showing a live win streak.
--
-- Drawn from Frames rather than an image, the same way MenuIcons/CategoryIcons
-- draw everything else in the game -- self-drawn is reliable and copyright-free,
-- with no downloaded asset that can go missing, get moderated, or infringe.
--
-- The convention this follows (EA FC, CoD ranked) is that a streak flame
-- escalates by COLOUR rather than by growing: the badge stays the same size and
-- shifts orange -> gold -> blue -> violet, so a long streak reads instantly at a
-- distance without the marker swelling to cover the player. The flicker and the
-- rising embers are what make it read as fire at this size; a static teardrop
-- just looks like a leaf.
--
-- Animated per-client off a replicated attribute (see OverheadDisplayService)
-- rather than server-driven: a flicker is a per-frame property change, and
-- replicating that for every player on the server would be enormously wasteful
-- for something purely decorative.
local StreakFlameController = {}

local player = Players.LocalPlayer

-- Matches the streak the hype feed already treats as the first milestone worth
-- announcing, so the flame appears on the same race the server shouts about
-- rather than on some second, unrelated threshold.
local MIN_STREAK = Hype.FirstStreakMilestone

-- Ascending; the last one whose Min is met wins. Deliberately not tied to the
-- announcement milestones (3/5/10/every 5) -- those fire far too often to be
-- worth a colour each, and a badge that keeps changing stops meaning anything.
local TIERS = {
	{ Min = 3, Core = Color3.fromRGB(255, 236, 170), Body = Color3.fromRGB(255, 138, 40) },
	{ Min = 5, Core = Color3.fromRGB(255, 248, 210), Body = Color3.fromRGB(255, 190, 60) },
	{ Min = 10, Core = Color3.fromRGB(224, 244, 255), Body = Color3.fromRGB(80, 176, 255) },
	{ Min = 20, Core = Color3.fromRGB(246, 226, 255), Body = Color3.fromRGB(190, 120, 255) },
}

local BADGE_WIDTH = 84
local BADGE_HEIGHT = 52
local FLAME_SIZE = 34
-- Sits directly above the rank plate, which is at StudsOffset y = 2.6 with a
-- 40px height. Clear of it, and still under the player's own nameplate space.
local STUDS_OFFSET_Y = 4.0

local EMBER_INTERVAL = 0.28
local EMBER_RISE = 22
local EMBER_LIFE = 0.75

type Flame = {
	gui: BillboardGui,
	body: { Frame },
	core: { Frame },
	label: TextLabel,
	emberHolder: Frame,
	-- Per-player phase so a lobby full of streaking players doesn't flicker in
	-- lockstep, which reads as a UI glitch rather than as fire.
	phase: number,
	nextEmber: number,
	tier: number,
}

local flames: { [number]: Flame } = {}

local function tierFor(streak: number): number
	local index = 1
	for i, tier in TIERS do
		if streak >= tier.Min then
			index = i
		end
	end
	return index
end

-- A rounded blob. Stacking three of decreasing size up the badge gives a
-- tapering candle-flame silhouette -- Frames can't draw a real teardrop (UICorner
-- rounds every corner equally), but at this size the taper is what sells it.
local function blob(parent: Instance, diameter: number, cx: number, cy: number, color: Color3): Frame
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromOffset(cx, cy)
	f.Size = UDim2.fromOffset(diameter, diameter)
	f.BackgroundColor3 = color
	f.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = f
	f.Parent = parent
	return f
end

local function buildFlame(head: BasePart, streak: number): Flame
	local tier = tierFor(streak)
	local palette = TIERS[tier]

	local gui = Instance.new("BillboardGui")
	gui.Name = "StreakFlame"
	-- Offset, not Scale: a constant on-screen size, matching the rank plate. In
	-- Scale the badge would be measured in studs and shrink to nothing at the
	-- distance you actually want to spot a streaking player from.
	gui.Size = UDim2.fromOffset(BADGE_WIDTH, BADGE_HEIGHT)
	gui.StudsOffset = Vector3.new(0, STUDS_OFFSET_Y, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 100
	gui.Parent = head

	local emberHolder = Instance.new("Frame")
	emberHolder.Name = "Embers"
	emberHolder.Size = UDim2.fromScale(1, 1)
	emberHolder.BackgroundTransparency = 1
	emberHolder.Parent = gui

	-- Behind the flame so embers rise out from under it.
	local flame = Instance.new("Frame")
	flame.Name = "Flame"
	flame.AnchorPoint = Vector2.new(0.5, 1)
	flame.Position = UDim2.fromOffset(BADGE_WIDTH / 2 - 16, BADGE_HEIGHT - 6)
	flame.Size = UDim2.fromOffset(FLAME_SIZE, FLAME_SIZE)
	flame.BackgroundTransparency = 1
	flame.Parent = gui

	local body = {
		blob(flame, 22, 17, 25, palette.Body),
		blob(flame, 16, 17, 15, palette.Body),
		blob(flame, 9, 17, 7, palette.Body),
	}
	local core = {
		blob(flame, 11, 17, 26, palette.Core),
		blob(flame, 7, 17, 18, palette.Core),
	}

	local label = Instance.new("TextLabel")
	label.Name = "Streak"
	label.AnchorPoint = Vector2.new(0, 0.5)
	label.Position = UDim2.fromOffset(BADGE_WIDTH / 2, BADGE_HEIGHT / 2 + 4)
	label.Size = UDim2.fromOffset(BADGE_WIDTH / 2 - 4, 24)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextSize = 20
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeColor3 = Color3.fromRGB(20, 12, 6)
	label.TextStrokeTransparency = 0.15
	label.Text = tostring(streak)
	label.Parent = gui

	return {
		gui = gui,
		body = body,
		core = core,
		label = label,
		emberHolder = emberHolder,
		phase = math.random() * math.pi * 2,
		nextEmber = 0,
		tier = tier,
	}
end

local function applyTier(flame: Flame, tier: number)
	if flame.tier == tier then
		return
	end
	flame.tier = tier
	local palette = TIERS[tier]
	for _, part in flame.body do
		part.BackgroundColor3 = palette.Body
	end
	for _, part in flame.core do
		part.BackgroundColor3 = palette.Core
	end
end

local function spawnEmber(flame: Flame)
	local palette = TIERS[flame.tier]
	local ember = blob(flame.emberHolder, math.random(3, 5), BADGE_WIDTH / 2 - 16 + math.random(-6, 6), BADGE_HEIGHT - 22, palette.Core)
	ember.ZIndex = 0

	-- Hand-stepped rather than tweened: TweenService would need two tweens plus
	-- a completion callback per ember, several times a second, per streaking
	-- player. This is one lerp on a value that's already being read each frame.
	task.spawn(function()
		local elapsed = 0
		local startY = ember.Position.Y.Offset
		while elapsed < EMBER_LIFE and ember.Parent do
			local dt = RunService.Heartbeat:Wait()
			elapsed += dt
			local t = math.min(1, elapsed / EMBER_LIFE)
			ember.Position = UDim2.fromOffset(ember.Position.X.Offset, startY - EMBER_RISE * t)
			ember.BackgroundTransparency = t
		end
		ember:Destroy()
	end)
end

local function removeFlame(userId: number)
	local flame = flames[userId]
	if not flame then
		return
	end
	flames[userId] = nil
	flame.gui:Destroy()
end

local function syncPlayer(other: Player)
	local userId = other.UserId
	local streak = tonumber(other:GetAttribute("WinStreak")) or 0
	local character = other.Character
	local head = character and character:FindFirstChild("Head")

	if streak < MIN_STREAK or not head then
		removeFlame(userId)
		return
	end

	local flame = flames[userId]
	-- Rebuilt if the character respawned: the old BillboardGui went with the
	-- old head.
	if flame and flame.gui.Parent ~= head then
		removeFlame(userId)
		flame = nil
	end
	if not flame then
		flame = buildFlame(head :: BasePart, streak)
		flames[userId] = flame
	end

	applyTier(flame, tierFor(streak))
	flame.label.Text = tostring(streak)
end

local function watch(other: Player)
	other:GetAttributeChangedSignal("WinStreak"):Connect(function()
		syncPlayer(other)
	end)
	other.CharacterAdded:Connect(function()
		-- The head arrives with the character, but parts can stream in a beat
		-- later; syncPlayer is a no-op until there's a head to hang it on, and
		-- the animation loop below retries.
		syncPlayer(other)
	end)
	syncPlayer(other)
end

function StreakFlameController.Init()
	for _, other in Players:GetPlayers() do
		watch(other)
	end
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(function(other)
		removeFlame(other.UserId)
	end)

	RunService.Heartbeat:Connect(function()
		local now = os.clock()

		-- Cheap sweep for players whose flame should exist but doesn't yet
		-- (character still streaming in) or whose head was replaced. Attribute
		-- and CharacterAdded signals cover the common cases; this catches the
		-- rest without another event to keep in sync.
		for _, other in Players:GetPlayers() do
			local streak = tonumber(other:GetAttribute("WinStreak")) or 0
			local hasFlame = flames[other.UserId] ~= nil
			if (streak >= MIN_STREAK) ~= hasFlame then
				syncPlayer(other)
			end
		end

		for _, flame in flames do
			-- Two sine waves at unrelated speeds, so the flicker never settles
			-- into an obvious repeating beat.
			local t = now * 9 + flame.phase
			local flickerA = math.sin(t)
			local flickerB = math.sin(t * 1.7 + 1.3)

			-- The tip moves most and the base barely at all, which is what makes
			-- it read as a flame rather than a pulsing blob.
			flame.body[3].Position = UDim2.fromOffset(17 + flickerA * 1.6, 7 + flickerB * 1.4)
			flame.body[2].Position = UDim2.fromOffset(17 + flickerA * 0.9, 15 + flickerB * 0.7)
			flame.core[2].Position = UDim2.fromOffset(17 + flickerA * 0.7, 18 + flickerB * 0.5)

			local squash = 1 + flickerA * 0.06
			flame.body[1].Size = UDim2.fromOffset(22, 22 * squash)
			flame.body[2].Size = UDim2.fromOffset(16 * squash, 16)

			if now >= flame.nextEmber then
				flame.nextEmber = now + EMBER_INTERVAL * (0.7 + math.random() * 0.6)
				spawnEmber(flame)
			end
		end
	end)

	-- The local player's own flame is shown too: it's the reward, and hiding it
	-- from the one person it's about would be strange. It sits above their head
	-- in third person and simply isn't in shot in first person.
	if player.Character then
		syncPlayer(player)
	end
end

return StreakFlameController
