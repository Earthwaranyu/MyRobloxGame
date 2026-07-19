-- Generic vector icons for panel-navigation tab strips (see Widgets.TabStrip)
-- -- Trails/Points/Pulls/Inventory/Odds, none tied to any specific ability or
-- item. Same self-drawn Frame/rotation technique as AbilityIcons (see its
-- doc comment for why: Creator Store search results are mostly broken/
-- moderated, self-drawn is reliable and copyright-free) -- kept as a
-- separate module since these are unrelated to abilities and used by
-- completely different call sites (Shop/Gacha tab strips, not ability UI).
local CategoryIcons = {}

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

local BUILDERS: { [string]: (Instance, number, Color3) -> () } = {}

-- Trails: a 4-point sparkle (long cross + short diagonal cross).
BUILDERS.Trails = function(parent, s, color)
	bar(parent, s, 26, 4, 20, 20, 0, color)
	bar(parent, s, 4, 26, 20, 20, 0, color)
	bar(parent, s, 14, 3, 20, 20, 45, color)
	bar(parent, s, 14, 3, 20, 20, -45, color)
end

-- Points: a coin -- filled circle with a slightly inset rim ring.
BUILDERS.Points = function(parent, s, color)
	dot(parent, s, 28, 20, 20, color)
	ring(parent, s, 20, 2, 20, 20, Color3.new(1, 1, 1))
end

-- Pulls (gacha): a gift box -- a square body with a cross ribbon.
BUILDERS.Pulls = function(parent, s, color)
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromOffset(20 * s, 22 * s)
	f.Size = UDim2.fromOffset(26 * s, 20 * s)
	f.BackgroundColor3 = color
	f.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4 * s)
	corner.Parent = f
	f.Parent = parent
	bar(parent, s, 26, 5, 20, 22, 0, Color3.new(1, 1, 1))
	bar(parent, s, 5, 20, 20, 22, 0, Color3.new(1, 1, 1))
end

-- Inventory: three stacked bars (a plain, unambiguous "list" glyph).
BUILDERS.Inventory = function(parent, s, color)
	bar(parent, s, 26, 4, 20, 13, 0, color)
	bar(parent, s, 26, 4, 20, 20, 0, color)
	bar(parent, s, 26, 4, 20, 27, 0, color)
end

-- Odds: a small ascending bar chart.
BUILDERS.Odds = function(parent, s, color)
	bar(parent, s, 6, 12, 13, 25, 0, color)
	bar(parent, s, 6, 20, 20, 21, 0, color)
	bar(parent, s, 6, 28, 27, 17, 0, color)
end

function CategoryIcons.Populate(container: Instance, id: string, size: number, color: Color3)
	container:ClearAllChildren()
	local s = size / DESIGN
	local builder = BUILDERS[id]
	if builder then
		builder(container, s, color)
	end
end

function CategoryIcons.Create(id: string, size: number, position: UDim2, color: Color3): Frame
	local holder = Instance.new("Frame")
	holder.Name = "CategoryIcon"
	holder.Size = UDim2.fromOffset(size, size)
	holder.Position = position
	holder.BackgroundTransparency = 1

	CategoryIcons.Populate(holder, id, size, color)

	return holder
end

return CategoryIcons
