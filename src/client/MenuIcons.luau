-- Self-drawn vector icons for the persistent HUD toggle/action buttons (Shop,
-- Party, Settings, Leaderboard, Emotes, Invite, Play, VS Bots, Practice,
-- Leave Match) -- the reference-image "every button has its own icon" look,
-- applied to Widgets.Button instead of the circular TabStrip tabs CategoryIcons/
-- AbilityIcons already cover. Same self-drawn Frame/rotation technique as
-- those two modules, for the same reason: reliable and copyright-free (no
-- downloaded asset can ever be missing/moderated/infringing). Gacha's toggle
-- reuses CategoryIcons' "Pulls" gift-box glyph directly rather than
-- duplicating it here, since it's the same concept (gacha pulls) already
-- drawn for that panel's own tab strip.
--
-- Also reused by ProfileCardController for its small stat-row icons (Wins/
-- Losses/Ability/Playtime) -- same BUILDERS/Populate mechanism, just at a
-- smaller container size, rather than a second copy of the bar/dot/ring/box
-- primitives for one more consumer.
local MenuIcons = {}

local DESIGN = 40

local function bar(parent: Instance, s: number, w: number, h: number, cx: number, cy: number, rotation: number, color: Color3)
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromOffset(cx * s, cy * s)
	f.Size = UDim2.fromOffset(w * s, h * s)
	f.Rotation = rotation
	f.BackgroundColor3 = color
	f.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = f
	f.Parent = parent
end

local function dot(parent: Instance, s: number, d: number, cx: number, cy: number, color: Color3)
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromOffset(cx * s, cy * s)
	f.Size = UDim2.fromOffset(d * s, d * s)
	f.BackgroundColor3 = color
	f.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = f
	f.Parent = parent
end

local function ring(parent: Instance, s: number, outerD: number, thickness: number, cx: number, cy: number, color: Color3)
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromOffset(cx * s, cy * s)
	f.Size = UDim2.fromOffset(outerD * s, outerD * s)
	f.BackgroundTransparency = 1
	f.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = f
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness * s
	stroke.Parent = f
end

-- Rounded rectangle (solid fill), used for bag/torso/cup shapes that a plain
-- bar/dot can't make. Kept local to this module -- CategoryIcons/AbilityIcons
-- glyphs never needed a rectangle body, only this one does.
local function box(parent: Instance, s: number, w: number, h: number, cx: number, cy: number, radius: number, color: Color3)
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromOffset(cx * s, cy * s)
	f.Size = UDim2.fromOffset(w * s, h * s)
	f.BackgroundColor3 = color
	f.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius * s)
	corner.Parent = f
	f.Parent = parent
end

local BUILDERS: { [string]: (Instance, number, Color3) -> () } = {}

-- Shop: a bag -- solid rounded body with two ring "handles" peeking above it
-- (handles sit clear of the body so they never go same-color-on-same-color
-- invisible against the solid fill).
BUILDERS.Shop = function(parent, s, color)
	box(parent, s, 24, 18, 20, 25, 5, color)
	ring(parent, s, 12, 2.5, 14, 12, color)
	ring(parent, s, 12, 2.5, 26, 12, color)
end

-- Party: two overlapping head-and-shoulders badges -- reads as "friends"
-- without needing a second color for contrast.
BUILDERS.Party = function(parent, s, color)
	dot(parent, s, 11, 14, 13, color)
	box(parent, s, 15, 13, 14, 27, 6, color)
	dot(parent, s, 11, 27, 19, color)
	box(parent, s, 15, 13, 27, 33, 6, color)
end

-- Settings: a chunky gear -- outer ring + inner axle ring + 8 round teeth,
-- round rather than sharp to match the game's "candy" toy-button look.
BUILDERS.Settings = function(parent, s, color)
	ring(parent, s, 20, 5, 20, 20, color)
	ring(parent, s, 8, 2.5, 20, 20, color)
	local teeth = {
		{ 37, 20 }, { 32, 32 }, { 20, 37 }, { 8, 32 },
		{ 3, 20 }, { 8, 8 }, { 20, 3 }, { 32, 8 },
	}
	for _, pos in teeth do
		dot(parent, s, 7, pos[1], pos[2], color)
	end
end

-- Leaderboard: a trophy cup -- solid bowl, two ring handles fused to its
-- sides, a stem and a base bar.
BUILDERS.Leaderboard = function(parent, s, color)
	box(parent, s, 18, 14, 20, 16, 5, color)
	ring(parent, s, 9, 2.5, 8, 15, color)
	ring(parent, s, 9, 2.5, 32, 15, color)
	bar(parent, s, 6, 9, 20, 26, 0, color)
	bar(parent, s, 18, 4, 20, 33, 0, color)
end

-- Emotes: a face -- hollow ring outline (so eyes/mouth drawn inside stay
-- visible against the transparent interior instead of vanishing into a
-- solid same-color fill) with two eye dots and a flat smile bar.
BUILDERS.Emotes = function(parent, s, color)
	ring(parent, s, 30, 3, 20, 20, color)
	dot(parent, s, 4, 13, 16, color)
	dot(parent, s, 4, 27, 16, color)
	bar(parent, s, 14, 3, 20, 27, 0, color)
end

-- Invite Friends: a person badge with a "+" -- the universal add-a-friend
-- glyph.
BUILDERS.Invite = function(parent, s, color)
	dot(parent, s, 12, 15, 13, color)
	box(parent, s, 17, 14, 15, 29, 7, color)
	bar(parent, s, 11, 3, 32, 10, 0, color)
	bar(parent, s, 3, 11, 32, 10, 0, color)
end

-- Play: a bold ">" chevron -- "go/start", the same chevron-from-two-bars
-- technique AbilityIcons uses for Dash.
BUILDERS.Play = function(parent, s, color)
	bar(parent, s, 18, 5, 16, 13, 50, color)
	bar(parent, s, 18, 5, 16, 27, -50, color)
end

-- Spectate carousel arrows: ArrowRight is literally the same ">" chevron as
-- Play (reused directly, not duplicated -- it's the same glyph). ArrowLeft
-- is that same two-bar chevron mirrored across the icon's own center.
BUILDERS.ArrowRight = BUILDERS.Play
BUILDERS.ArrowLeft = function(parent, s, color)
	bar(parent, s, 18, 5, 24, 13, -50, color)
	bar(parent, s, 18, 5, 24, 27, 50, color)
end

-- VS Bots: a robot face -- hollow ring head (same reasoning as Emotes) with
-- an antenna, two eye dots and a mouth bar.
BUILDERS.Bots = function(parent, s, color)
	bar(parent, s, 3, 8, 20, 7, 0, color)
	dot(parent, s, 5, 20, 4, color)
	ring(parent, s, 26, 3, 20, 23, color)
	dot(parent, s, 4, 14, 21, color)
	dot(parent, s, 4, 26, 21, color)
	bar(parent, s, 10, 3, 20, 29, 0, color)
end

-- Practice: a target -- two concentric hollow rings plus a solid bullseye
-- dot, each nested safely inside the previous ring's transparent interior.
BUILDERS.Practice = function(parent, s, color)
	ring(parent, s, 30, 3, 20, 20, color)
	ring(parent, s, 18, 3, 20, 20, color)
	dot(parent, s, 6, 20, 20, color)
end

-- Leave Match: a door jamb with an arrow pointing out through it.
BUILDERS.Exit = function(parent, s, color)
	bar(parent, s, 5, 26, 13, 20, 0, color)
	bar(parent, s, 14, 4, 27, 20, 0, color)
	bar(parent, s, 10, 4, 31, 15, 45, color)
	bar(parent, s, 10, 4, 31, 25, -45, color)
end

-- Wins (profile card): a checkmark -- a short bar and a long bar meeting at
-- the bottom point, same two-bars-at-an-angle technique as Play's chevron.
BUILDERS.Wins = function(parent, s, color)
	bar(parent, s, 9, 5, 14, 22, 45, color)
	bar(parent, s, 18, 5, 25, 17, -55, color)
end

-- Losses (profile card): an X -- two long bars crossed, the same "two bars
-- at right angles" idea as Invite's "+" just rotated 45 degrees.
BUILDERS.Losses = function(parent, s, color)
	bar(parent, s, 26, 4, 20, 20, 45, color)
	bar(parent, s, 26, 4, 20, 20, -45, color)
end

-- Ability (profile card): a lightning bolt -- two parallel diagonal bars
-- offset from each other, reading as a zigzag "S" at this size.
BUILDERS.Ability = function(parent, s, color)
	bar(parent, s, 16, 5, 17, 14, -35, color)
	bar(parent, s, 16, 5, 23, 26, -35, color)
end

-- Playtime (profile card): a clock -- outer ring with an hour hand pointing
-- up and a shorter minute hand pointing right, both anchored at the center.
BUILDERS.Playtime = function(parent, s, color)
	ring(parent, s, 30, 3, 20, 20, color)
	bar(parent, s, 3, 11, 20, 15, 0, color)
	bar(parent, s, 3, 8, 24, 20, 90, color)
end

-- My Profile (HUD button): a single head-and-shoulders badge -- same dot
-- (head) + box (shoulders) pieces as one half of Party, just one centered
-- badge instead of two overlapping ones, and without Invite's "+".
BUILDERS.Profile = function(parent, s, color)
	dot(parent, s, 14, 20, 14, color)
	box(parent, s, 20, 16, 20, 30, 8, color)
end

-- Clears `container` and draws `id`'s glyph sized to container's own Size.X
-- offset (read back from the Frame we just sized, not AbsoluteSize -- that
-- stays correct even before the next render step). `color` is whatever the
-- caller's button text color already is, so the icon always matches.
function MenuIcons.Populate(container: Instance, id: string, color: Color3)
	container:ClearAllChildren()
	local size = (container :: Frame).Size.X.Offset
	local s = size / DESIGN
	local builder = BUILDERS[id]
	if builder then
		builder(container, s, color)
	end
end

return MenuIcons
