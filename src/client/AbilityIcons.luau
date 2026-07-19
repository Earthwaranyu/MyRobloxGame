-- Self-drawn vector icons for each ability, one per Abilities.Id -- not photo
-- decals. Every "free icon, no copyright" Creator Store search this session
-- came back almost entirely broken (28 of 29 fresh candidates across 5
-- keyword searches failed ContentProvider:GetAssetFetchStatus outright, most
-- likely moderated/removed assets a keyword search can't distinguish from
-- working ones). Drawing icons from Frames/UICorner/rotation instead
-- sidesteps that reliability problem completely (same technique as the
-- close-✕ in Widgets.Modal) and guarantees zero copyright risk since nothing
-- is ever downloaded.
--
-- Keyed by Abilities.Id, not Kind -- Dash and Meteor share Kind="Dash"
-- server-side (see Abilities.luau) but need visibly different glyphs, since
-- "Meteor feels the same as Dash" was a real player complaint about the
-- effects, and a shared icon would undercut the fix that made them distinct.
local AbilityIcons = {}

-- Every glyph is designed on a fixed 40x40 grid, then uniformly scaled --
-- keeps proportions identical whether it's drawn at 24px (inventory row) or
-- 48px (HUD button) instead of hand-tuning coordinates per call site.
local DESIGN = 40

local function bar(parent: Instance, s: number, w: number, h: number, cx: number, cy: number, rotation: number, color: Color3, transparency: number?)
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromOffset(cx * s, cy * s)
	f.Size = UDim2.fromOffset(w * s, h * s)
	f.Rotation = rotation
	f.BackgroundColor3 = color
	f.BackgroundTransparency = transparency or 0
	f.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = f
	f.Parent = parent
end

local function dot(parent: Instance, s: number, d: number, cx: number, cy: number, color: Color3, transparency: number?)
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromOffset(cx * s, cy * s)
	f.Size = UDim2.fromOffset(d * s, d * s)
	f.BackgroundColor3 = color
	f.BackgroundTransparency = transparency or 0
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

local BUILDERS: { [string]: (Instance, number, Color3) -> () } = {}

-- Dash: three ">" chevrons fading toward the tail -- reads as a forward
-- speed-burst, deliberately NOT a single arrow (that's Sky Hop) or a comet
-- (that's Meteor) so the three "Dash-family" abilities stay visually
-- distinct even though Dash and Meteor share Kind="Dash" server-side.
BUILDERS.Dash = function(parent, s, color)
	for i = 0, 2 do
		local vx = 26 - i * 7
		local transparency = i * 0.3
		bar(parent, s, 11, 3, vx - 4, 12, 45, color, transparency)
		bar(parent, s, 11, 3, vx - 4, 28, -45, color, transparency)
	end
end

-- Sky Hop: a single bold upward arrow (shaft + "^" head) -- unmistakably
-- "goes up", the opposite silhouette from Dash's sideways chevrons.
BUILDERS.SkyHop = function(parent, s, color)
	bar(parent, s, 5, 14, 20, 28, 0, color)
	bar(parent, s, 12, 4, 16, 18, -50, color)
	bar(parent, s, 12, 4, 24, 18, 50, color)
end

-- Blink: a warp/target reticle -- a hollow ring plus a smaller solid dot
-- offset to one side, reading as "here -> there" rather than a plain circle.
BUILDERS.Blink = function(parent, s, color)
	ring(parent, s, 22, 2.5, 17, 20, color)
	dot(parent, s, 10, 28, 12, color)
end

-- Surge: a lightning-bolt zigzag built from three offset bars, not a
-- symmetric X (which would read as "cancel/close", already used elsewhere).
BUILDERS.Surge = function(parent, s, color)
	bar(parent, s, 17, 4, 19, 13, -55, color)
	bar(parent, s, 9, 4, 18, 20, 0, color)
	bar(parent, s, 17, 4, 17, 27, -55, color)
end

-- Meteor Dash: a comet -- solid head with a fading diagonal trail of
-- shrinking dots. Distinct from plain Dash's chevrons at a glance, even
-- though both resolve to Kind="Dash" server-side.
BUILDERS.Meteor = function(parent, s, color)
	dot(parent, s, 14, 27, 27, color)
	for i = 1, 3 do
		local d = 10 - i * 2
		local pos = 27 - i * 7
		dot(parent, s, d, pos, pos, color, i * 0.25)
	end
end

-- Clears `container` and draws `id`'s glyph into it at the given pixel size
-- and color. Cheap enough to call on every cooldown-tick redraw (a handful
-- of small Frames), so callers that need the icon to re-tint alongside
-- button text (see AbilityController) can just call this again rather than
-- hand-rolling a separate recolor path.
function AbilityIcons.Populate(container: Instance, id: string, size: number, color: Color3)
	container:ClearAllChildren()
	local s = size / DESIGN
	local builder = BUILDERS[id]
	if builder then
		builder(container, s, color)
	end
end

-- One-shot convenience for call sites that build an icon once and never
-- update it (gacha reel cards, inventory rows, odds rows).
function AbilityIcons.Create(id: string, size: number, position: UDim2, color: Color3): Frame
	local holder = Instance.new("Frame")
	holder.Name = "AbilityIcon"
	holder.Size = UDim2.fromOffset(size, size)
	holder.Position = position
	holder.BackgroundTransparency = 1

	AbilityIcons.Populate(holder, id, size, color)

	return holder
end

return AbilityIcons
