-- Shared visual component factory. Keep this the only place that builds raw
-- GuiObjects so every panel/button in the game shares one look and feel.
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)
local Sounds = require(script.Parent.Sounds)

local Widgets = {}

-- Every modal ever created (see Widgets.Modal), so something outside this
-- module can force them all shut at once -- see Widgets.CloseAllModals.
-- Weak-keyed so a modal whose ScreenGui gets destroyed can still be GC'd.
local activeModals: { [CanvasGroup]: () -> () } = setmetatable({}, { __mode = "k" }) :: any

-- Closes every currently-open modal panel (Shop, Gacha, Party, Settings,
-- Emotes, Leaderboard, ProfileCard, ...) in one shot. Used by
-- ModalAutoCloseController when a queued race actually starts -- leaving
-- ANY of these open across that transition covers the player's screen right
-- as the race they're now supposed to be playing begins, with no way to see
-- (or react to) it short of manually finding the ✕.
function Widgets.CloseAllModals()
	for panel, close in activeModals do
		if panel.Visible then
			close()
		end
	end
end

export type PanelOpts = {
	Color: Color3?,
	StrokeColor: Color3?,
	CornerRadius: UDim?,
}

export type ButtonOpts = {
	Variant: ("Primary" | "Secondary" | "Success" | "Danger" | "Tab")?,
	Active: boolean?,
	TextSize: number?,
}

export type LabelOpts = {
	Color: Color3?,
	Font: Enum.Font?,
	TextSize: number?,
	Align: Enum.TextXAlignment?,
	Bold: boolean?,
}

-- Panels are CanvasGroups so Widgets.Open/Close can fade every descendant
-- (text, rows, icons) as one unit instead of tweening each child.
function Widgets.Panel(size: UDim2, position: UDim2, opts: PanelOpts?): CanvasGroup
	opts = opts or {}

	local frame = Instance.new("CanvasGroup")
	frame.Size = size
	frame.Position = position
	frame.BackgroundColor3 = opts.Color or Theme.Color.Panel
	frame.BorderSizePixel = 0
	frame.Visible = false

	local corner = Instance.new("UICorner")
	corner.CornerRadius = opts.CornerRadius or Theme.Corner.Panel
	corner.Parent = frame

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(Theme.Color.PanelLight, Theme.Color.Panel)
	gradient.Rotation = 90
	gradient.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Name = "Border"
	stroke.Color = opts.StrokeColor or Theme.Color.Stroke
	stroke.Thickness = 1.5
	stroke.Transparency = 0.35
	stroke.Parent = frame

	local scale = Instance.new("UIScale")
	scale.Name = "PopScale"
	scale.Scale = 1
	scale.Parent = frame

	return frame
end

export type ModalOpts = {
	-- ScreenGui.DisplayOrder for this modal's OWN ScreenGui. Every other
	-- ScreenGui in the game (HUD buttons, other modals) lives at its own
	-- DisplayOrder -- this is the ONLY thing that reliably controls stacking
	-- BETWEEN ScreenGuis. (See the postmortem below for why ZIndex can't do
	-- this job.) Defaults to 25, comfortably above the base HUD (which sits
	-- at 0-20 across the rest of the game) but below the biggest
	-- single-moment interrupts like TutorialGui (20)... actually higher, see
	-- default below -- pass a bigger value for a modal that must sit above
	-- another modal (e.g. a reveal popup opened from within a shop panel).
	DisplayOrder: number?,
	PanelOpts: PanelOpts?,
}

-- A fully self-contained modal: its own ScreenGui, a dimmed click-outside-to-
-- close backdrop, the panel itself, and a close-✕ pinned to its top-right
-- corner. Returns (panel, open, close, setClickOutsideEnabled) -- callers
-- build their own content into `panel` same as a raw Widgets.Panel, then
-- call open()/close() instead of Widgets.Open/Close directly (this also
-- flips the backdrop). setClickOutsideEnabled(false) is for a modal that's
-- mid-ceremony rather than idly browsable (see its own doc comment below);
-- most callers never need to touch it.
--
-- Why every modal in the game should go through this instead of building its
-- own backdrop+panel by hand (as GachaController's gacha/odds/reveal panels
-- used to): every ScreenGui here has ZIndexBehavior.Global, which compares
-- EVERY element in a ScreenGui's tree by its own absolute ZIndex -- a
-- CanvasGroup child does NOT inherit or get "boosted" by its container's
-- ZIndex. Setting a high ZIndex on the panel container while its actual
-- content (labels, buttons) stays at the default ZIndex does nothing -- the
-- content is still only ZIndex 1, so anything else in the SAME ScreenGui at
-- ZIndex 2+ (like a backdrop) renders ON TOP of it, which looked exactly
-- like "the panel is a solid black box." And separately, ZIndex never
-- crosses ScreenGui boundaries at all -- only DisplayOrder does, which is
-- why a modal needs its OWN ScreenGui in the first place (so it can sit
-- above whatever DisplayOrder the base HUD's buttons happen to use) rather
-- than trying to out-ZIndex them from inside a shared ScreenGui.
function Widgets.Modal(name: string, size: UDim2, position: UDim2, opts: ModalOpts?): (CanvasGroup, () -> (), () -> (), (boolean) -> ())
	opts = opts or {}

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = name .. "ModalGui"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = opts.DisplayOrder or 25
	screenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
	backdrop.BackgroundTransparency = 0.45
	backdrop.BorderSizePixel = 0
	backdrop.Visible = false
	backdrop.Parent = screenGui

	local panel = Widgets.Panel(size, position, opts.PanelOpts)
	-- Frame/CanvasGroup.Active defaults to false, meaning by default a click
	-- on the panel's own background (not one of its buttons) would fall
	-- through to the backdrop underneath and immediately close the modal --
	-- Active = true makes the panel itself absorb that click instead, so
	-- only genuinely clicking OUTSIDE the panel triggers the backdrop.
	panel.Active = true
	panel.Parent = screenGui

	-- Drawn from two crossed bars, not a text glyph -- a Unicode "✕" here
	-- used to silently render as a missing-glyph box, since Roblox's Gotham
	-- family doesn't have that particular symbol. Drawing the icon instead
	-- of hoping a font supports it also means it exactly matches the game's
	-- own red (Theme.Color.Danger, the same red already used for Leave
	-- Party/Decline elsewhere) rather than whatever red an emoji font ships.
	local closeButton = Instance.new("TextButton")
	closeButton.Name = "CloseButton"
	closeButton.Text = ""
	closeButton.AutoButtonColor = false
	closeButton.BackgroundColor3 = Theme.Color.Danger
	closeButton.BorderSizePixel = 0
	closeButton.Size = UDim2.fromOffset(32, 32)
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.new(1, -10, 0, 10)
	closeButton.Parent = panel

	local closeButtonCorner = Instance.new("UICorner")
	closeButtonCorner.CornerRadius = UDim.new(1, 0)
	closeButtonCorner.Parent = closeButton

	local closeScale = Instance.new("UIScale")
	closeScale.Parent = closeButton

	for _, rotation in { 45, -45 } do
		local bar = Instance.new("Frame")
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Position = UDim2.fromScale(0.5, 0.5)
		bar.Size = UDim2.fromOffset(16, 2.5)
		bar.Rotation = rotation
		bar.BackgroundColor3 = Color3.new(1, 1, 1)
		bar.BorderSizePixel = 0
		local barCorner = Instance.new("UICorner")
		barCorner.CornerRadius = UDim.new(1, 0)
		barCorner.Parent = bar
		bar.Parent = closeButton
	end

	local function close()
		Widgets.Close(panel)
		backdrop.Visible = false
	end

	local function open()
		backdrop.Visible = true
		Widgets.Open(panel)
	end

	-- Same hover-pop/press-squish personality every other button in the
	-- game has (see Widgets.Button) -- a static icon button next to
	-- everything else's bounce reads as an afterthought, not part of the
	-- same design.
	closeButton.MouseEnter:Connect(function()
		TweenService:Create(closeScale, Theme.Anim.Pop, { Scale = 1.12 }):Play()
		Sounds.Play("Hover")
	end)
	closeButton.MouseLeave:Connect(function()
		TweenService:Create(closeScale, Theme.Anim.Pop, { Scale = 1 }):Play()
	end)
	closeButton.MouseButton1Down:Connect(function()
		TweenService:Create(closeScale, TweenInfo.new(0.08, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Scale = 0.85,
		}):Play()
	end)
	closeButton.MouseButton1Up:Connect(function()
		TweenService:Create(closeScale, Theme.Anim.Pop, { Scale = 1.12 }):Play()
	end)
	closeButton.MouseButton1Click:Connect(function()
		Sounds.Play("Click")
		close()
	end)

	-- Click/tap ANYWHERE the backdrop is still visible (i.e. outside the
	-- panel, since the panel sits on top of it and now absorbs its own
	-- clicks) closes the modal -- one of the three exits every modal should
	-- have alongside the ✕ and whatever toggle button opened it. Can be
	-- switched off at runtime (see setClickOutsideEnabled) for a modal that's
	-- mid-ceremony rather than idly browsable -- e.g. a gacha reveal playing
	-- a ~30s sequence of pulls, where an impatient/accidental tap anywhere on
	-- screen used to dismiss the whole thing with no way back to see the
	-- result. The ✕ still always works either way -- that's a deliberate
	-- exit, not a stray tap.
	local clickOutsideEnabled = true
	backdrop.InputBegan:Connect(function(input: InputObject)
		if not clickOutsideEnabled then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			close()
		end
	end)

	local function setClickOutsideEnabled(enabled: boolean)
		clickOutsideEnabled = enabled
	end

	activeModals[panel] = close

	return panel, open, close, setClickOutsideEnabled
end

-- Open/Close can be called back-to-back (e.g. a race that finishes almost
-- instantly). Without cancelling the previous tween, two tweens end up
-- racing on the same GroupTransparency property and the loser's leftover
-- value can stick, leaving the panel invisible despite Visible = true.
-- Weak-keyed so panels can still be garbage collected.
local activeTween: { [Instance]: Tween } = setmetatable({}, { __mode = "k" }) :: any

local function takeOverTween(panel: Instance, tween: Tween)
	local previous = activeTween[panel]
	if previous then
		previous:Cancel()
	end
	activeTween[panel] = tween
end

-- Pops + fades a panel built by Widgets.Panel into view. The tween drives the
-- visible animation, but a delayed fallback force-applies the end state
-- regardless of whether the tween ever reports completion -- under heavy
-- frame-scheduling load a Tween's PlaybackState can get stuck at "Playing"
-- forever without ever stepping the property, which would otherwise leave
-- the panel permanently invisible despite Visible == true.
function Widgets.Open(panel: CanvasGroup)
	local scale = panel:FindFirstChild("PopScale") :: UIScale
	panel.Visible = true
	panel.GroupTransparency = 1
	if scale then
		scale.Scale = 0.9
	end

	local tween = TweenService:Create(panel, Theme.Anim.Smooth, { GroupTransparency = 0 })
	takeOverTween(panel, tween)
	tween:Play()
	if scale then
		TweenService:Create(scale, Theme.Anim.Pop, { Scale = 1 }):Play()
	end

	task.delay(Theme.Anim.Smooth.Time + 0.15, function()
		if activeTween[panel] == tween then
			panel.GroupTransparency = 0
		end
	end)
end

-- Fades + shrinks a panel built by Widgets.Panel, then hides it. See
-- Widgets.Open for why this also force-applies the end state on a delay.
function Widgets.Close(panel: CanvasGroup)
	local scale = panel:FindFirstChild("PopScale") :: UIScale
	local tween = TweenService:Create(panel, Theme.Anim.Ease, { GroupTransparency = 1 })
	takeOverTween(panel, tween)
	if scale then
		TweenService:Create(scale, Theme.Anim.Ease, { Scale = 0.9 }):Play()
	end

	local function hide()
		panel.GroupTransparency = 1
		panel.Visible = false
	end

	tween.Completed:Connect(function(playbackState: Enum.PlaybackState)
		if playbackState == Enum.PlaybackState.Completed and activeTween[panel] == tween then
			hide()
		end
	end)
	tween:Play()

	task.delay(Theme.Anim.Ease.Time + 0.15, function()
		if activeTween[panel] == tween then
			hide()
		end
	end)
end

function Widgets.Label(text: string, size: UDim2, position: UDim2, opts: LabelOpts?): TextLabel
	opts = opts or {}

	local label = Instance.new("TextLabel")
	label.Text = text
	label.Size = size
	label.Position = position
	label.BackgroundTransparency = 1
	label.TextColor3 = opts.Color or Theme.Color.TextPrimary
	label.Font = opts.Font or (if opts.Bold == false then Theme.Font.Body else Theme.Font.Heading)
	label.TextSize = opts.TextSize or 18
	label.TextXAlignment = opts.Align or Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	return label
end

-- Kept flat and plain on purpose: an earlier chunky-gradient/multi-stroke
-- version kept coming back blurry/hard-to-read in testing no matter which
-- color combination was tried, so this strips it down to the simplest thing
-- that can't introduce a rendering artifact -- one solid color, one text
-- color, nothing layered on top. "Cartoony" now comes entirely from the
-- shape (full-pill corners) and the squish/bounce motion, not the paint job.
local WHITE = Color3.fromRGB(255, 255, 255)
local NEAR_BLACK = Color3.fromRGB(24, 24, 28)

local VARIANT_STYLE = {
	Primary = { Color = Color3.fromRGB(20, 20, 24), Text = WHITE },
	Secondary = { Color = WHITE, Text = NEAR_BLACK },
	Success = { Color = Color3.fromRGB(45, 175, 100), Text = WHITE },
	Danger = { Color = Color3.fromRGB(210, 70, 80), Text = WHITE },
}
VARIANT_STYLE.Tab = VARIANT_STYLE.Secondary

local function lighten(color: Color3, amount: number): Color3
	return color:Lerp(Color3.new(1, 1, 1), amount)
end

local HOVER_SCALE_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
-- Squishy toy feel: pressing puffs the button OUT bigger, not smaller.
local PRESS_SCALE_INFO = TweenInfo.new(0.09, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local PRESS_SCALE_TARGET = 1.22
local SPARK_COUNT = 6

-- Tiny burst of dots flying out from the button's center on a successful
-- click -- pure "juice", no gameplay meaning, just makes tapping it feel fun.
local function spawnClickSparkles(button: TextButton, color: Color3)
	for i = 1, SPARK_COUNT do
		local spark = Instance.new("Frame")
		spark.AnchorPoint = Vector2.new(0.5, 0.5)
		spark.Position = UDim2.fromScale(0.5, 0.5)
		spark.Size = UDim2.fromOffset(7, 7)
		spark.BackgroundColor3 = if i % 2 == 0 then Color3.new(1, 1, 1) else lighten(color, 0.3)
		spark.BorderSizePixel = 0
		spark.ZIndex = 20
		spark.Parent = button

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = spark

		local angle = (i - 1) / SPARK_COUNT * math.pi * 2 + math.random() * 0.5
		local dist = 24 + math.random() * 14
		local targetPos = UDim2.fromScale(0.5, 0.5) + UDim2.fromOffset(math.cos(angle) * dist, math.sin(angle) * dist)

		TweenService:Create(spark, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = targetPos,
			Size = UDim2.fromOffset(1, 1),
			BackgroundTransparency = 1,
		}):Play()

		task.delay(0.5, function()
			spark:Destroy()
		end)
	end
end

-- TextScaled recomputes glyph size continuously against the button's actual
-- render bounds, which came out visibly blurry/soft compared to a fixed
-- TextSize (confirmed by screenshot: PLAY, which always passed a fixed
-- TextSize, stayed crisp while TextScaled buttons didn't). So every button
-- now gets a fixed pixel size -- explicit via opts.TextSize, or derived from
-- the button's offset height when the caller didn't specify one.
local function defaultTextSize(size: UDim2): number
	if size.Y.Offset > 0 then
		return math.clamp(math.floor(size.Y.Offset * 0.6), 16, 34)
	end
	return 19
end

-- Returns the button plus a setActive(isActive) setter (only meaningful for
-- Variant = "Tab") so callers can restyle a tab's active state without
-- rebuilding it. Instances can't hold custom fields, hence the second value.
function Widgets.Button(text: string, size: UDim2, position: UDim2, opts: ButtonOpts?): (TextButton, (boolean) -> ())
	opts = opts or {}
	local variant = opts.Variant or "Primary"
	local isActiveTab = variant == "Tab" and opts.Active

	local style = isActiveTab and VARIANT_STYLE.Primary or (VARIANT_STYLE[variant] or VARIANT_STYLE.Primary)

	local button = Instance.new("TextButton")
	button.Text = text
	button.Size = size
	button.BackgroundColor3 = style.Color
	button.TextColor3 = style.Text
	button.Font = Theme.Font.Button
	button.TextSize = opts.TextSize or defaultTextSize(size)
	button.TextScaled = false
	button.TextTruncate = Enum.TextTruncate.AtEnd
	button.AutoButtonColor = false
	button.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = Theme.Corner.Button
	corner.Parent = button

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = button

	-- Re-anchor to center so UIScale grows/shrinks the button symmetrically
	-- instead of ballooning out from the top-left corner. This keeps the
	-- exact same on-screen placement the caller asked for via `position`.
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	local originalPosition = UDim2.new(
		position.X.Scale + size.X.Scale / 2,
		position.X.Offset + size.X.Offset / 2,
		position.Y.Scale + size.Y.Scale / 2,
		position.Y.Offset + size.Y.Offset / 2
	)
	button.Position = originalPosition

	local hovering = false
	local pressed = false
	local currentScaleTween: Tween? = nil

	-- Text rendered at a non-1.0 UIScale comes out visibly blurry (confirmed:
	-- a continuous idle "breathing" pulse used to live here and made every
	-- button's label look permanently smeared), so the button now sits dead
	-- still -- exactly Scale = 1 -- whenever it isn't actively being
	-- hovered/pressed. Hover/press bumps are brief and settle back to 1, so
	-- any blur during those is momentary rather than constant.
	local function stopScaleTween()
		if currentScaleTween then
			currentScaleTween:Cancel()
			currentScaleTween = nil
		end
	end

	local function settleScale(targetScale: number, info: TweenInfo)
		stopScaleTween()
		currentScaleTween = TweenService:Create(scale, info, { Scale = targetScale })
		currentScaleTween:Play()
	end

	button.MouseEnter:Connect(function()
		hovering = true
		if not pressed then
			settleScale(1.08, HOVER_SCALE_INFO)
		end
		Sounds.Play("Hover")
	end)
	button.MouseLeave:Connect(function()
		hovering = false
		pressed = false
		settleScale(1, Theme.Anim.Pop)
	end)
	button.MouseButton1Down:Connect(function()
		pressed = true
		stopScaleTween()
		currentScaleTween = TweenService:Create(scale, PRESS_SCALE_INFO, { Scale = PRESS_SCALE_TARGET })
		currentScaleTween:Play()
	end)
	button.MouseButton1Up:Connect(function()
		pressed = false
		settleScale(if hovering then 1.08 else 1, Theme.Anim.Pop)
	end)
	button.MouseButton1Click:Connect(function()
		Sounds.Play("Click")
		spawnClickSparkles(button, style.Color)
	end)

	local function setActive(isActive: boolean)
		local target = if isActive then VARIANT_STYLE.Primary else VARIANT_STYLE.Secondary
		button.BackgroundColor3 = target.Color
		button.TextColor3 = target.Text
	end

	return button, setActive
end

-- Small rounded chip, e.g. "Gold  1240 elo" in a corner HUD.
function Widgets.StatPill(size: UDim2, position: UDim2): Frame
	local pill = Instance.new("Frame")
	pill.Size = size
	pill.Position = position
	pill.BackgroundColor3 = Theme.Color.Panel
	pill.BackgroundTransparency = 0.1
	pill.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = Theme.Corner.Pill
	corner.Parent = pill

	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Color.Stroke
	stroke.Thickness = 1
	stroke.Transparency = 0.4
	stroke.Parent = pill

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = pill

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 12)
	padding.PaddingRight = UDim.new(0, 12)
	padding.Parent = pill

	return pill
end

return Widgets
