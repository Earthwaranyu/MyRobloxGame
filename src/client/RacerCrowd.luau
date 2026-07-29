-- Draws a little crowd of stylised racers, used as the artwork behind each card
-- in the play-mode picker.
--
-- Self-drawn from Frames for the same reason every other icon in this game is
-- (see MenuIcons): nothing to download, so nothing that can go missing, be
-- moderated, or infringe. It also means the crowd can be tinted per card and
-- laid out for any headcount from one description, instead of needing a
-- separate image per mode.
--
-- The figures are deliberately crude -- head, body, two legs, a lean. At card
-- size they read as "a group of this many runners" instantly, which is the only
-- job. Detail here would fight the label sitting on top of them.
local RacerCrowd = {}

-- Figures are described in a 100x100 space and scaled to whatever the card
-- gives them, so one layout works at any size.
local DESIGN = 100

-- Pixels in, pixels out. Callers do their own scaling, because a figure's limbs
-- shrink with depth while the holder it sits in does not -- mixing the two
-- scales inside here is what silently pushed shrunken figures off-centre.
local function part(parent: Instance, px: number, py: number, w: number, h: number, radius: number, color: Color3, rotation: number?): Frame
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromOffset(px, py)
	f.Size = UDim2.fromOffset(w, h)
	f.Rotation = rotation or 0
	f.BackgroundColor3 = color
	f.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = f
	f.Parent = parent
	return f
end

-- One runner, mid-stride, leaning into the direction of travel.
--
-- `depth` (0 = front, 1 = furthest back) fades and shrinks the figure. That
-- fake depth is what stops five figures in a row from looking like a barcode:
-- the crowd gains a front and a back, and the eye lands on the nearest runner.
local function figure(parent: Instance, scale: number, cx: number, cy: number, color: Color3, depth: number, lean: number)
	local holder = Instance.new("Frame")
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromOffset(cx * scale, cy * scale)
	holder.Size = UDim2.fromOffset(DESIGN * scale, DESIGN * scale)
	holder.BackgroundTransparency = 1
	holder.Rotation = lean
	holder.Parent = parent

	local shrink = 1 - depth * 0.22
	local s = scale * shrink
	local transparency = depth * 0.45

	-- Limbs are described around (0,0) and drawn relative to the middle of the
	-- holder. The OFFSETS shrink with depth but the centre does not, which is
	-- what keeps a distant figure centred on its own spot instead of sliding
	-- toward the holder's top-left corner.
	local centre = DESIGN / 2 * scale
	local function limb(w: number, h: number, x: number, y: number, r: number, rot: number?)
		local f = part(holder, centre + x * s, centre + y * s, w * s, h * s, r * s, color, rot)
		f.BackgroundTransparency = transparency
	end

	-- Torso, head, trailing arm, and two legs caught mid-stride.
	limb(17, 26, 0, -2, 8)
	limb(15, 15, 0, -22, 8)
	limb(7, 18, -11, 0, 4, 22)
	limb(8, 20, -5, 20, 4, 14)
	limb(8, 20, 6, 19, 4, -20)
end

-- Where each figure sits, per headcount. Hand-placed rather than evenly spaced:
-- an even row reads as a queue, whereas a staggered clump with one figure
-- clearly in front reads as a pack mid-race. Values are x, y, depth.
local LAYOUTS: { [number]: { { number } } } = {
	[1] = { { 50, 54, 0 } },
	[2] = { { 34, 56, 0 }, { 68, 48, 0.55 } },
	[3] = { { 30, 58, 0 }, { 54, 46, 0.5 }, { 76, 56, 0.8 } },
	[4] = { { 26, 60, 0 }, { 48, 46, 0.4 }, { 68, 58, 0.7 }, { 86, 46, 0.95 } },
	[5] = { { 22, 60, 0 }, { 42, 46, 0.35 }, { 60, 60, 0.6 }, { 78, 46, 0.8 }, { 93, 59, 1 } },
}

-- Fills `container` with `count` runners, tinted `color`.
--
-- Figures are added back-to-front so the nearest one overlaps the others rather
-- than being cut into by them.
function RacerCrowd.Populate(container: Frame, count: number, color: Color3)
	for _, child in container:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	local layout = LAYOUTS[math.clamp(count, 1, 5)]
	local size = math.min(container.AbsoluteSize.X, container.AbsoluteSize.Y)
	-- AbsoluteSize is 0 for a frame that hasn't been laid out yet (built this
	-- frame, parented but not rendered), so fall back to its offset size.
	if size <= 0 then
		size = math.min(container.Size.X.Offset, container.Size.Y.Offset)
	end
	local scale = size / DESIGN

	local ordered = table.clone(layout)
	table.sort(ordered, function(a, b)
		return a[3] > b[3]
	end)

	for _, spec in ordered do
		local depth = spec[3]
		-- The lean alternates so the pack doesn't look like one figure stamped
		-- repeatedly, and stays slight -- a big tilt reads as falling over.
		figure(container, scale, spec[1], spec[2], color, depth, if depth % 0.4 < 0.2 then -7 else -12)
	end
end

return RacerCrowd
