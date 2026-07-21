local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Emotes = require(Shared.Emotes)
local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)

-- Clash Royale-style: a round icon bubble pops up above whoever played the
-- emote for a couple seconds, then fades. Purely visual/local -- the server
-- only validates ownership/cooldown and broadcasts who-played-what; every
-- client (including the emoter) builds its own bubble off that.
local EmoteDisplayController = {}

local DISPLAY_SECONDS = 2.2
local FADE_SECONDS = 0.3

local emoteById: { [string]: any } = {}
for _, emote in Emotes do
	emoteById[emote.Id] = emote
end

local INK = Color3.fromRGB(40, 32, 28)
local FACE_YELLOW = Color3.fromRGB(255, 205, 60)
local FACE_YELLOW_STROKE = Color3.fromRGB(215, 155, 40)
local TEAR_BLUE = Color3.fromRGB(90, 170, 235)

local function shape(
	size: UDim2,
	position: UDim2,
	rotation: number,
	color: Color3,
	cornerRadius: UDim,
	parent: Instance
): Frame
	local piece = Instance.new("Frame")
	piece.AnchorPoint = Vector2.new(0.5, 0.5)
	piece.Size = size
	piece.Position = position
	piece.Rotation = rotation
	piece.BackgroundColor3 = color
	piece.BorderSizePixel = 0
	piece.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = cornerRadius
	corner.Parent = piece

	return piece
end

local function pill(size: UDim2, position: UDim2, rotation: number, color: Color3, parent: Instance): Frame
	return shape(size, position, rotation, color, UDim.new(1, 0), parent)
end

-- A pill anchored at one end (`pivot`) instead of its center, extending
-- `length` outward at `angle` -- rotating it then swings it like an arm or
-- leg around the shoulder/hip instead of spinning in place.
local function limb(length: number, thickness: number, pivot: UDim2, angle: number, color: Color3, parent: Instance): Frame
	local piece = Instance.new("Frame")
	piece.AnchorPoint = Vector2.new(0, 0.5)
	piece.Size = UDim2.fromScale(length, thickness)
	piece.Position = pivot
	piece.Rotation = angle
	piece.BackgroundColor3 = color
	piece.BorderSizePixel = 0
	piece.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = piece

	return piece
end

local function faceBase(color: Color3, strokeColor: Color3, parent: Instance): Frame
	local face = Instance.new("Frame")
	face.Size = UDim2.fromScale(1, 1)
	face.BackgroundColor3 = color
	face.BorderSizePixel = 0
	face.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = face

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.4
	stroke.Color = strokeColor
	stroke.Parent = face

	return face
end

-- Loops a piece from (baseX, baseY) out to (baseX+dx, baseY+dy) while fading
-- out, then resets and repeats after `gap` seconds. Covers a tear falling
-- straight down (Cry), a tear flying out sideways (LOL), a glint sweeping
-- sideways (Cool), and a stink line rising straight up (Poop) -- just
-- different (dx, dy, time, gap). `delay` staggers repeated pieces so they
-- don't all animate in lockstep. Returns a stop function that cancels the
-- in-flight tween immediately rather than waiting out its remaining time.
local function loopDrift(
	piece: Frame,
	baseX: number,
	baseY: number,
	dx: number,
	dy: number,
	time: number,
	gap: number,
	delay: number
): () -> ()
	local running = true
	local activeTween: Tween? = nil

	task.delay(delay, function()
		while running do
			piece.Position = UDim2.fromScale(baseX, baseY)
			piece.BackgroundTransparency = 0

			local drift = TweenService:Create(
				piece,
				TweenInfo.new(time, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
				{ Position = UDim2.fromScale(baseX + dx, baseY + dy), BackgroundTransparency = 1 }
			)
			activeTween = drift
			drift:Play()
			drift.Completed:Wait()
			if not running then
				break
			end
			task.wait(gap)
		end
	end)

	return function()
		running = false
		if activeTween then
			activeTween:Cancel()
		end
	end
end

-- Loops a quick blink (squash both eyes' height down and back) on a random
-- 1.6-2.4s interval. Returns a stop function that cancels any in-flight
-- blink immediately.
local function loopBlink(eyes: { Frame }, openSize: UDim2, closedSize: UDim2): () -> ()
	local running = true
	local activeTweens: { Tween } = {}

	task.spawn(function()
		while running do
			task.wait(1.6 + math.random() * 0.8)
			if not running then
				break
			end

			activeTweens = {}
			for _, eye in eyes do
				local close = TweenService:Create(
					eye,
					TweenInfo.new(0.09, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
					{ Size = closedSize }
				)
				table.insert(activeTweens, close)
				close:Play()
			end

			task.wait(0.09)
			if not running then
				break
			end

			for _, eye in eyes do
				TweenService:Create(eye, TweenInfo.new(0.09, Enum.EasingStyle.Sine, Enum.EasingDirection.In), {
					Size = openSize,
				}):Play()
			end
		end
	end)

	return function()
		running = false
		for _, tween in activeTweens do
			tween:Cancel()
		end
	end
end

-- Custom vector faces (original flat-icon art, not the Unicode glyph) for
-- emotes where real per-feature motion reads better than the glyph could.
-- `content` is the square area inside the bubble the glyph would normally
-- occupy; each builder returns a stop function to halt its own loops.
local FaceBuilders: { [string]: (content: Instance) -> () -> () } = {}

local EYE_OPEN = UDim2.fromScale(0.14, 0.20)
local EYE_CLOSED = UDim2.fromScale(0.14, 0.02)

FaceBuilders.Cry = function(content: Instance)
	local face = faceBase(FACE_YELLOW, FACE_YELLOW_STROKE, content)

	local leftEye = pill(EYE_OPEN, UDim2.fromScale(0.32, 0.42), 0, INK, face)
	local rightEye = pill(EYE_OPEN, UDim2.fromScale(0.68, 0.42), 0, INK, face)
	pill(UDim2.fromScale(0.20, 0.045), UDim2.fromScale(0.30, 0.26), 18, INK, face)
	pill(UDim2.fromScale(0.20, 0.045), UDim2.fromScale(0.70, 0.26), -18, INK, face)

	-- Wide open wailing mouth instead of a small closed frown -- reads as
	-- actually crying, not just a bit sad. Trembles gently like a sob.
	local mouth = pill(UDim2.fromScale(0.28, 0.22), UDim2.fromScale(0.5, 0.74), 0, Color3.fromRGB(80, 30, 30), face)
	local sob = TweenService:Create(
		mouth,
		TweenInfo.new(0.32, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Size = UDim2.fromScale(0.28, 0.28) }
	)
	sob:Play()

	local leftTear = pill(UDim2.fromScale(0.11, 0.16), UDim2.fromScale(0.32, 0.56), 0, TEAR_BLUE, face)
	local rightTear = pill(UDim2.fromScale(0.11, 0.16), UDim2.fromScale(0.68, 0.56), 0, TEAR_BLUE, face)

	local stopBlink = loopBlink({ leftEye, rightEye }, EYE_OPEN, EYE_CLOSED)
	local stopTearL = loopDrift(leftTear, 0.32, 0.56, 0, 0.35, 1.3, 0.25, 0)
	local stopTearR = loopDrift(rightTear, 0.68, 0.56, 0, 0.35, 1.3, 0.25, 0.55)

	return function()
		sob:Cancel()
		stopBlink()
		stopTearL()
		stopTearR()
	end
end

FaceBuilders.LOL = function(content: Instance)
	local face = faceBase(FACE_YELLOW, FACE_YELLOW_STROKE, content)

	-- Closed, scrunched-up laughing eyes -- each a small smiling "u" made of
	-- two pieces meeting low in the middle (same curve direction as Cool's
	-- smile below, NOT the frown mouth's chevron -- that read as sad brows).
	pill(UDim2.fromScale(0.11, 0.045), UDim2.fromScale(0.24, 0.40), -25, INK, face)
	pill(UDim2.fromScale(0.11, 0.045), UDim2.fromScale(0.36, 0.40), 25, INK, face)
	pill(UDim2.fromScale(0.11, 0.045), UDim2.fromScale(0.64, 0.40), -25, INK, face)
	pill(UDim2.fromScale(0.11, 0.045), UDim2.fromScale(0.76, 0.40), 25, INK, face)

	local mouth = pill(UDim2.fromScale(0.44, 0.16), UDim2.fromScale(0.5, 0.70), 0, Color3.fromRGB(140, 40, 40), face)
	-- Teeth strip along the top of the open mouth -- without it the mouth
	-- reads as a sad wailing "O" rather than a wide-open laugh.
	pill(UDim2.fromScale(0.38, 0.055), UDim2.fromScale(0.5, 0.62), 0, Color3.fromRGB(255, 255, 255), face)

	local flap = TweenService:Create(
		mouth,
		TweenInfo.new(0.13, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Size = UDim2.fromScale(0.44, 0.26) }
	)
	flap:Play()

	-- Laughing-so-hard-tears-fly-out, not fall straight down like Cry's.
	local leftTear = pill(UDim2.fromScale(0.10, 0.15), UDim2.fromScale(0.16, 0.46), -20, TEAR_BLUE, face)
	local rightTear = pill(UDim2.fromScale(0.10, 0.15), UDim2.fromScale(0.84, 0.46), 20, TEAR_BLUE, face)

	local stopTearL = loopDrift(leftTear, 0.16, 0.46, -0.16, 0.18, 0.9, 0.3, 0)
	local stopTearR = loopDrift(rightTear, 0.84, 0.46, 0.16, 0.18, 0.9, 0.3, 0.4)

	return function()
		flap:Cancel()
		stopTearL()
		stopTearR()
	end
end

FaceBuilders.Cool = function(content: Instance)
	local face = faceBase(FACE_YELLOW, FACE_YELLOW_STROKE, content)

	-- Two separate lenses + a bridge read as glasses; one solid bar just
	-- read as a blindfold.
	local lensColor = Color3.fromRGB(26, 26, 30)
	local lensStroke = Color3.fromRGB(75, 75, 84)
	local lensCorner = UDim.new(0.35, 0)

	local function lens(position: UDim2): Frame
		local piece = shape(UDim2.fromScale(0.28, 0.20), position, 0, lensColor, lensCorner, face)
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 1
		stroke.Color = lensStroke
		stroke.Parent = piece
		return piece
	end

	lens(UDim2.fromScale(0.28, 0.40))
	lens(UDim2.fromScale(0.72, 0.40))
	pill(UDim2.fromScale(0.14, 0.045), UDim2.fromScale(0.5, 0.38), 0, lensColor, face)

	pill(UDim2.fromScale(0.22, 0.06), UDim2.fromScale(0.40, 0.69), -20, INK, face)
	pill(UDim2.fromScale(0.22, 0.06), UDim2.fromScale(0.60, 0.69), 20, INK, face)

	-- A bright streak sweeping across both lenses, like light catching the
	-- glass, then a pause before it sweeps again.
	local glint = pill(UDim2.fromScale(0.05, 0.14), UDim2.fromScale(0.18, 0.40), 25, Color3.fromRGB(230, 230, 238), face)
	local stopGlint = loopDrift(glint, 0.18, 0.40, 0.64, 0, 0.55, 2.2, 0)

	return function()
		stopGlint()
	end
end

FaceBuilders.Dance = function(content: Instance)
	local SKIN = Color3.fromRGB(255, 202, 160)
	local DRESS = Color3.fromRGB(210, 45, 65)
	local HAIR = Color3.fromRGB(50, 32, 26)

	-- Anchored at the bottom-center (feet) so rotating it sways the whole
	-- upper body from the hips, not the bubble itself -- the bubble chrome
	-- (circle/stroke) never moves, only the figure inside it.
	local dancer = Instance.new("Frame")
	dancer.AnchorPoint = Vector2.new(0.5, 1)
	dancer.Size = UDim2.fromScale(0.9, 0.92)
	dancer.Position = UDim2.fromScale(0.5, 0.96)
	dancer.BackgroundTransparency = 1
	dancer.Parent = content

	local skirt = pill(UDim2.fromScale(0.60, 0.34), UDim2.fromScale(0.5, 0.82), 0, DRESS, dancer)
	pill(UDim2.fromScale(0.18, 0.22), UDim2.fromScale(0.5, 0.58), 0, DRESS, dancer)
	pill(UDim2.fromScale(0.09, 0.16), UDim2.fromScale(0.28, 0.95), 25, SKIN, dancer)

	-- Hair cap goes in BEHIND the head (added first, head added after covers
	-- its center) so only a rim shows around the top/sides -- a separate
	-- small bun circle sat disconnected above the head and looked wrong.
	pill(UDim2.fromScale(0.27, 0.27), UDim2.fromScale(0.5, 0.32), 0, HAIR, dancer)
	pill(UDim2.fromScale(0.22, 0.22), UDim2.fromScale(0.5, 0.36), 0, SKIN, dancer)

	-- Small happy face on the head -- dot eyes plus a tiny smile (same
	-- valley-shaped chevron trick as Cool's smile, just scaled way down).
	pill(UDim2.fromScale(0.03, 0.045), UDim2.fromScale(0.465, 0.335), 0, INK, dancer)
	pill(UDim2.fromScale(0.03, 0.045), UDim2.fromScale(0.535, 0.335), 0, INK, dancer)
	pill(UDim2.fromScale(0.05, 0.018), UDim2.fromScale(0.475, 0.395), -20, INK, dancer)
	pill(UDim2.fromScale(0.05, 0.018), UDim2.fromScale(0.525, 0.395), 20, INK, dancer)

	local raisedArm = limb(0.30, 0.09, UDim2.fromScale(0.58, 0.44), -60, SKIN, dancer)
	limb(0.22, 0.09, UDim2.fromScale(0.42, 0.50), 150, SKIN, dancer)

	local BEAT = 0.15 -- 50% faster than the previous 0.22s beat
	dancer.Rotation = -8
	local sway = TweenService:Create(
		dancer,
		TweenInfo.new(BEAT, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Rotation = 8 }
	)
	sway:Play()

	local armSwing = TweenService:Create(
		raisedArm,
		TweenInfo.new(BEAT, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Rotation = -40 }
	)
	armSwing:Play()

	-- Skirt swishes in the same rhythm as the hip sway/arm swing rather than
	-- its own timing, so the whole figure reads as dancing on one beat.
	local swish = TweenService:Create(
		skirt,
		TweenInfo.new(BEAT, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Size = UDim2.fromScale(0.66, 0.34) }
	)
	swish:Play()

	return function()
		sway:Cancel()
		armSwing:Cancel()
		swish:Cancel()
	end
end

FaceBuilders.Poop = function(content: Instance)
	local brown = Color3.fromRGB(150, 100, 60)
	local brownStroke = Color3.fromRGB(110, 72, 42)

	local function lobe(size: UDim2, position: UDim2): Frame
		local piece = pill(size, position, 0, brown, content)
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 1.2
		stroke.Color = brownStroke
		stroke.Parent = piece
		return piece
	end

	lobe(UDim2.fromScale(0.80, 0.50), UDim2.fromScale(0.5, 0.74))
	lobe(UDim2.fromScale(0.62, 0.42), UDim2.fromScale(0.5, 0.48))
	lobe(UDim2.fromScale(0.42, 0.30), UDim2.fromScale(0.5, 0.24))

	local eyeOpen = UDim2.fromScale(0.11, 0.16)
	local eyeClosed = UDim2.fromScale(0.11, 0.02)
	local leftEye = pill(eyeOpen, UDim2.fromScale(0.40, 0.48), 0, INK, content)
	local rightEye = pill(eyeOpen, UDim2.fromScale(0.60, 0.48), 0, INK, content)
	pill(UDim2.fromScale(0.16, 0.045), UDim2.fromScale(0.42, 0.58), -20, INK, content)
	pill(UDim2.fromScale(0.16, 0.045), UDim2.fromScale(0.58, 0.58), 20, INK, content)

	-- Stink lines rising off the top lobe and fading, staggered per line.
	local stinkColor = Color3.fromRGB(210, 225, 210)
	local lineA = pill(UDim2.fromScale(0.05, 0.10), UDim2.fromScale(0.38, 0.10), 20, stinkColor, content)
	local lineB = pill(UDim2.fromScale(0.05, 0.10), UDim2.fromScale(0.5, 0.04), 0, stinkColor, content)
	local lineC = pill(UDim2.fromScale(0.05, 0.10), UDim2.fromScale(0.62, 0.10), -20, stinkColor, content)

	local stopBlink = loopBlink({ leftEye, rightEye }, eyeOpen, eyeClosed)
	local stopLineA = loopDrift(lineA, 0.38, 0.10, -0.03, -0.18, 1.1, 0.4, 0)
	local stopLineB = loopDrift(lineB, 0.5, 0.04, 0, -0.18, 1.1, 0.4, 0.35)
	local stopLineC = loopDrift(lineC, 0.62, 0.10, 0.03, -0.18, 1.1, 0.4, 0.7)

	return function()
		stopBlink()
		stopLineA()
		stopLineB()
		stopLineC()
	end
end

local function showBubble(player: Player, emoteId: string)
	local emote = emoteById[emoteId]
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	if not emote or not head then
		return
	end

	local existing = head:FindFirstChild("EmoteBubble")
	if existing then
		existing:Destroy()
	end

	-- OverheadDisplayService's rank tag sits at StudsOffset 2.6. Both are
	-- fixed-pixel-size BillboardGuis, so being only 1 stud apart made them
	-- visually collide on screen at anything but point-blank range -- the
	-- gap here needs to be generous, not just "technically above it".
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "EmoteBubble"
	billboard.Size = UDim2.fromOffset(56, 56)
	billboard.StudsOffset = Vector3.new(0, 4.9, 0)
	billboard.MaxDistance = 120
	billboard.AlwaysOnTop = true
	billboard.Parent = head

	local circle = Instance.new("Frame")
	circle.Size = UDim2.fromScale(1, 1)
	circle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	circle.BorderSizePixel = 0
	circle.Parent = billboard

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = circle

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = Color3.fromRGB(20, 20, 24)
	stroke.Parent = circle

	-- CanvasGroup (not Frame) so a custom face's several pieces -- or the
	-- plain glyph -- can fade out together with one GroupTransparency tween
	-- instead of the caller needing to know what's inside.
	local content = Instance.new("CanvasGroup")
	content.Size = UDim2.fromScale(0.78, 0.78)
	content.Position = UDim2.fromScale(0.11, 0.11)
	content.BackgroundTransparency = 1
	content.Parent = circle

	local stopFace: (() -> ())? = nil
	local faceBuilder = FaceBuilders[emote.Id]
	if faceBuilder then
		stopFace = faceBuilder(content)
	else
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Text = emote.Icon
		label.TextScaled = true
		label.Font = Enum.Font.GothamBold
		label.Parent = content
	end

	local scale = Instance.new("UIScale")
	scale.Scale = 0.2
	scale.Parent = circle

	TweenService:Create(scale, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1,
	}):Play()

	task.delay(DISPLAY_SECONDS, function()
		if not billboard.Parent then
			return
		end
		if stopFace then
			stopFace()
		end
		TweenService:Create(circle, TweenInfo.new(FADE_SECONDS), { BackgroundTransparency = 1 }):Play()
		TweenService:Create(scale, TweenInfo.new(FADE_SECONDS), { Scale = 0.3 }):Play()
		TweenService:Create(stroke, TweenInfo.new(FADE_SECONDS), { Transparency = 1 }):Play()
		TweenService:Create(content, TweenInfo.new(FADE_SECONDS), { GroupTransparency = 1 }):Play()

		task.delay(FADE_SECONDS + 0.05, function()
			if billboard.Parent then
				billboard:Destroy()
			end
		end)
	end)
end

function EmoteDisplayController.Init()
	local remote = Net.GetRemoteEvent(RemoteNames.EmotePlayed)
	remote.OnClientEvent:Connect(showBubble)
end

return EmoteDisplayController
