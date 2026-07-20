-- Shared visual component factory. Keep this the only place that builds raw
-- GuiObjects so every panel/button in the game shares one look and feel.
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local TextService = game:GetService("TextService")

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
	-- Optional leading glyph (see MenuIcons) -- the reference-image "every
	-- button has its own icon" treatment for a HUD toggle/action button.
	-- Receives an icon holder Frame and the button's own text color, so a
	-- caller just does `MenuIcons.Populate(holder, "Shop", color)`.
	Icon: ((Instance, Color3) -> ())?,
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
-- Candy panel: bright violet fill, thick white border -- the same "toy"
-- material every button uses (see VARIANT_STYLE below), just bigger. opts.
-- Color/StrokeColor still override it for a caller that genuinely needs a
-- different tone (none currently do, kept for flexibility).
function Widgets.Panel(size: UDim2, position: UDim2, opts: PanelOpts?): CanvasGroup
	opts = opts or {}

	local frame = Instance.new("CanvasGroup")
	frame.Size = size
	frame.Position = position
	frame.BackgroundColor3 = opts.Color or Theme.Candy.PanelFace
	frame.BorderSizePixel = 0
	frame.Visible = false

	local corner = Instance.new("UICorner")
	corner.CornerRadius = opts.CornerRadius or Theme.Corner.Panel
	corner.Parent = frame

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(Theme.Candy.PanelFaceLight, Theme.Candy.PanelFace)
	gradient.Rotation = 90
	gradient.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Name = "Border"
	stroke.Color = opts.StrokeColor or Theme.Candy.Border
	stroke.Thickness = 4
	stroke.Parent = frame

	local scale = Instance.new("UIScale")
	scale.Name = "PopScale"
	scale.Scale = 1
	scale.Parent = frame

	return frame
end

-- Banner-style panel title -- a gold rounded bar with the same bevel-strip/
-- white-border candy treatment as everything else, sat across a panel's top
-- edge (callers typically position it slightly ABOVE the panel's own top,
-- like a hanging sign, e.g. y = panel's y minus half the ribbon's height).
-- A plain Widgets.Label still works fine for anything that doesn't want the
-- banner treatment -- this is additive, not a replacement.
function Widgets.Ribbon(text: string, size: UDim2, position: UDim2): Frame
	local ribbon = Instance.new("Frame")
	ribbon.Name = "Ribbon"
	ribbon.AnchorPoint = Vector2.new(0.5, 0)
	ribbon.Size = size
	ribbon.Position = position
	ribbon.BackgroundColor3 = Theme.Candy.Gold.Face
	ribbon.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = ribbon

	local border = Instance.new("UIStroke")
	border.Color = Theme.Candy.Border
	border.Thickness = 3
	border.Parent = ribbon

	local bevelMask = Instance.new("Frame")
	bevelMask.Size = UDim2.fromScale(1, 1)
	bevelMask.BackgroundTransparency = 1
	bevelMask.ClipsDescendants = true
	bevelMask.Parent = ribbon

	local bevelMaskCorner = Instance.new("UICorner")
	bevelMaskCorner.CornerRadius = UDim.new(1, 0)
	bevelMaskCorner.Parent = bevelMask

	local bevelStrip = Instance.new("Frame")
	bevelStrip.AnchorPoint = Vector2.new(0.5, 1)
	bevelStrip.Position = UDim2.fromScale(0.5, 1)
	bevelStrip.Size = UDim2.new(1, 0, 0, 6)
	bevelStrip.BackgroundColor3 = Theme.Candy.Gold.Shadow
	bevelStrip.BorderSizePixel = 0
	bevelStrip.Parent = bevelMask

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = text
	label.Font = Theme.Font.Button
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeColor3 = Theme.Candy.TextOutline
	label.TextStrokeTransparency = 0
	label.TextSize = 20
	label.Parent = ribbon

	return ribbon
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
function Widgets.Modal(name: string, size: UDim2, position: UDim2, opts: ModalOpts?): (CanvasGroup, () -> (), () -> (), (boolean) -> (), ScreenGui)
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
	closeButton.BackgroundColor3 = Theme.Candy.Red.Face
	closeButton.BorderSizePixel = 0
	closeButton.Size = UDim2.fromOffset(34, 34)
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.new(1, -10, 0, 10)
	closeButton.Parent = panel

	local closeButtonCorner = Instance.new("UICorner")
	closeButtonCorner.CornerRadius = UDim.new(1, 0)
	closeButtonCorner.Parent = closeButton

	-- Same thick white ring every candy button/panel has (see Widgets.Button/
	-- Panel) -- a bare flat circle here would read as an afterthought next to
	-- everything else's border treatment.
	local closeButtonBorder = Instance.new("UIStroke")
	closeButtonBorder.Color = Theme.Candy.Border
	closeButtonBorder.Thickness = 2.5
	closeButtonBorder.Parent = closeButton

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

	-- 5th return (screenGui) is for a caller that needs to place something
	-- OUTSIDE the panel's own rectangle but still at this modal's stacking
	-- layer -- e.g. a Widgets.TabStrip sitting to the panel's left (see
	-- GachaController). `panel` itself won't work as that parent: it's a
	-- CanvasGroup, which clips its own descendants to its own bounds by
	-- design (that's what makes Widgets.Open/Close's single fade-as-one-unit
	-- trick work), so anything positioned outside the panel's rectangle as
	-- its child would just be invisible. Most callers only need the first
	-- four values and can ignore this one.
	return panel, open, close, setClickOutsideEnabled, screenGui
end

export type TabDef = {
	Id: string,
	BuildIcon: ((Instance, Color3) -> ())?,
}

-- Left-side vertical strip of circular candy tab buttons -- the reference
-- image's category strip (Pets/Passes/Wins/Boosts), used to switch between
-- a panel's internal sections (see GachaController/ShopController). This
-- widget only owns the STRIP's look and which tab is highlighted -- it has
-- no idea what "selecting a tab" should show, that's entirely on the
-- caller via onSelected. Meant to sit immediately to the LEFT of a
-- Widgets.Modal panel, positioned by the caller like anything else here.
function Widgets.TabStrip(tabs: { TabDef }, position: UDim2, opts: { Size: number?, Gap: number? }?): (Frame, (string) -> (), ((string) -> ()) -> ())
	opts = opts or {}
	local tabSize = opts.Size or 56
	local gap = opts.Gap or 10

	local strip = Instance.new("Frame")
	strip.Name = "TabStrip"
	strip.Size = UDim2.fromOffset(tabSize, math.max(0, #tabs * tabSize + (#tabs - 1) * gap))
	strip.Position = position
	strip.BackgroundTransparency = 1

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, gap)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = strip

	local buttons: { [string]: TextButton } = {}
	local strokes: { [string]: UIStroke } = {}
	local selected: string? = nil
	local onSelectHandlers: { (string) -> () } = {}

	local function applyHighlight()
		for id, btn in buttons do
			local isSelected = id == selected
			local style = if isSelected then Theme.Candy.Gold else Theme.Candy.PurpleDeep
			btn.BackgroundColor3 = style.Face
			strokes[id].Thickness = if isSelected then 4 else 2.5
		end
	end

	local function selectTab(id: string)
		if selected == id or not buttons[id] then
			return
		end
		selected = id
		applyHighlight()
		for _, handler in onSelectHandlers do
			handler(id)
		end
	end

	for i, tab in tabs do
		local btn = Instance.new("TextButton")
		btn.Name = "Tab_" .. tab.Id
		btn.LayoutOrder = i
		btn.Size = UDim2.fromOffset(tabSize, tabSize)
		btn.Text = ""
		btn.AutoButtonColor = false
		btn.BackgroundColor3 = Theme.Candy.PurpleDeep.Face
		btn.BorderSizePixel = 0
		btn.Parent = strip

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = btn

		local stroke = Instance.new("UIStroke")
		stroke.Color = Theme.Candy.Border
		stroke.Thickness = 2.5
		stroke.Parent = btn

		local iconHolder = Instance.new("Frame")
		iconHolder.Size = UDim2.fromScale(0.62, 0.62)
		iconHolder.Position = UDim2.fromScale(0.19, 0.19)
		iconHolder.BackgroundTransparency = 1
		iconHolder.Parent = btn

		if tab.BuildIcon then
			tab.BuildIcon(iconHolder, Color3.new(1, 1, 1))
		end

		buttons[tab.Id] = btn
		strokes[tab.Id] = stroke

		btn.MouseEnter:Connect(function()
			Sounds.Play("Hover")
		end)
		btn.MouseButton1Click:Connect(function()
			Sounds.Play("Click")
			selectTab(tab.Id)
		end)
	end

	if tabs[1] then
		selected = tabs[1].Id
		applyHighlight()
	end

	local function onSelected(handler: (string) -> ())
		table.insert(onSelectHandlers, handler)
	end

	return strip, selectTab, onSelected
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

-- Chunky "candy" look: a bright face color, a darker same-hue bevel strip
-- peeking out along the bottom edge (the classic mobile-game 3D-button
-- look), and a thick white outer border -- see Theme.Candy for the
-- Face/Shadow pairs every variant maps to below. An earlier chunky-gradient/
-- multi-stroke attempt kept coming back blurry/hard-to-read in testing, but
-- that was a multi-color-GRADIENT-on-text problem specifically -- a single
-- solid face color plus a native TextStrokeColor3 outline (not a second
-- layered label) stays exactly as crisp as the old flat style did.
local WHITE = Color3.fromRGB(255, 255, 255)
local NEAR_BLACK = Color3.fromRGB(24, 24, 28)

local VARIANT_STYLE = {
	Primary = { Face = Theme.Candy.Purple.Face, Shadow = Theme.Candy.Purple.Shadow, Text = WHITE },
	Secondary = { Face = Theme.Candy.White.Face, Shadow = Theme.Candy.White.Shadow, Text = NEAR_BLACK },
	Success = { Face = Theme.Candy.Green.Face, Shadow = Theme.Candy.Green.Shadow, Text = WHITE },
	Danger = { Face = Theme.Candy.Red.Face, Shadow = Theme.Candy.Red.Shadow, Text = WHITE },
}
VARIANT_STYLE.Tab = VARIANT_STYLE.Secondary

-- How far the bevel strip peeks out along the bottom edge -- big enough to
-- read as "3D depth" at every button size used in the game, small enough to
-- never eat into a short button's text.
local BEVEL_DEPTH = 5

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

-- Shrinks downward from maxSize until `text` fits `availableWidth` at that
-- font, floor 10px. Used by the icon+label path below -- an icon button's
-- label has less width to work with than the same button's bare centered
-- Text did, and hand-tuning a per-button width/position for every affected
-- HUD button (several sit only px away from a hand-placed neighbor) is far
-- more brittle than just letting the label ask "does this fit?" directly.
local function fitTextSize(text: string, font: Enum.Font, maxSize: number, availableWidth: number, availableHeight: number): number
	local size = maxSize
	while size > 10 do
		local bounds = TextService:GetTextSize(text, size, font, Vector2.new(1000, availableHeight))
		if bounds.X <= availableWidth then
			return size
		end
		size -= 1
	end
	return 10
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
	local effectiveTextSize = opts.TextSize or defaultTextSize(size)
	button.Size = size
	button.BackgroundColor3 = style.Face
	button.TextColor3 = style.Text
	-- GothamBlack (the heaviest cut) reads fine at the ~19px+ sizes most
	-- buttons use, but confirmed via screenshot that smaller explicit sizes
	-- (opts.TextSize = 13-14, used by denser rows like the gacha pull
	-- buttons) came out visibly mushy with it -- GothamBold is one step
	-- lighter and stays legible at that size instead.
	button.Font = if effectiveTextSize >= 18 then Theme.Font.Button else Theme.Font.Heading
	button.TextSize = effectiveTextSize
	button.TextScaled = false
	button.TextTruncate = Enum.TextTruncate.AtEnd
	-- Native text outline (not a second layered label) -- keeps the "candy"
	-- text look at zero extra render cost and zero risk of drifting out of
	-- sync with whatever the caller sets button.Text to later. Confirmed via
	-- screenshot that ANY visible stroke at this button's normal 14-16px
	-- functional-text sizes (e.g. "Pull x1 — 1500 pts") made the text look
	-- soft/muddy, while the same stroke at a bigger 20px+ size (Widgets.
	-- Ribbon's banner text) stayed crisp -- legibility on functional UI text
	-- wins over the decorative outline, so smaller text gets none at all.
	button.TextStrokeColor3 = Theme.Candy.TextOutline
	button.TextStrokeTransparency = if effectiveTextSize >= 18 then 0.35 else 1
	button.AutoButtonColor = false
	button.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = Theme.Corner.Button
	corner.Parent = button

	local border = Instance.new("UIStroke")
	border.Name = "CandyBorder"
	border.Color = Theme.Candy.Border
	border.Thickness = 3
	border.Parent = button

	-- EVERY button's visible label is a separate child TextLabel, NOT
	-- button.Text itself -- confirmed via extensive same-frame A/B screenshot
	-- testing that Roblox's native TextButton.Text renders measurably
	-- softer/blurrier than the IDENTICAL string (same size/font/stroke/
	-- color) in a plain TextLabel, especially visible on longer multi-word
	-- strings (e.g. "Pull x1 — 1500 pts") -- independent of TextSize, font
	-- weight, stroke, or contrast, all of which were tried first. A
	-- side-by-side clone of a real button next to a Label-based version of
	-- the exact same string, captured in the same screenshot, showed the
	-- Label version crisp and the native-Text version still soft. So this
	-- isn't opt-in per button -- ALL of them get the Label now.
	--
	-- button.Text is kept driving the label via GetPropertyChangedSignal so
	-- callers that mutate button.Text after creation (QuitMatchController's
	-- Leave/Stop Watching swap, PlayButtonController's PLAY/CANCEL/"<name>
	-- is busy" swap, SettingsController's ON/OFF toggles, ...) keep working
	-- completely unchanged, with no edits needed at any call site.
	local iconSize = 0
	local iconInset = 0
	if opts.Icon then
		iconSize = math.clamp(math.floor(size.Y.Offset * 0.5), 16, 28)
		iconInset = size.Y.Offset * 0.32

		local iconHolder = Instance.new("Frame")
		iconHolder.Name = "Icon"
		iconHolder.AnchorPoint = Vector2.new(0, 0.5)
		iconHolder.Position = UDim2.new(0, iconInset, 0.5, 0)
		iconHolder.Size = UDim2.fromOffset(iconSize, iconSize)
		iconHolder.BackgroundTransparency = 1
		iconHolder.Parent = button

		opts.Icon(iconHolder, style.Text)
	end

	local leftInset = if opts.Icon then iconInset + iconSize + 6 else 0
	local rightInset = iconInset
	local maxLabelTextSize = button.TextSize

	-- Scale-sized buttons (e.g. the gacha/shop row action buttons, sized via
	-- UDim2.fromScale) have no usable size.X.Offset here -- AbsoluteSize
	-- isn't resolved yet since the button isn't parented/laid out at this
	-- point in the constructor. Skip the shrink-to-fit for those (same as
	-- before this change: rely on TextTruncate as the overflow safety net)
	-- rather than feeding fitTextSize a bogus ~0 width, which would floor
	-- every one of those buttons' text down to 10px.
	local function computeLabelTextSize(labelText: string): number
		if size.X.Offset <= 0 then
			return maxLabelTextSize
		end
		local availableWidth = size.X.Offset - leftInset - rightInset
		return fitTextSize(labelText, button.Font, maxLabelTextSize, availableWidth, math.max(size.Y.Offset, 20))
	end

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromOffset(leftInset, 0)
	label.Size = UDim2.new(1, -(leftInset + rightInset), 1, 0)
	label.Font = button.Font
	label.TextColor3 = button.TextColor3
	label.TextScaled = false
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.TextStrokeColor3 = button.TextStrokeColor3
	label.TextStrokeTransparency = button.TextStrokeTransparency
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.Text = button.Text
	label.TextSize = computeLabelTextSize(button.Text)
	label.Parent = button

	button.Text = ""
	-- A naive "set a syncing flag, clear button.Text, reset the flag" guard
	-- does NOT work here: PropertyChangedSignal fires DEFERRED in this
	-- engine (next resumption step, not immediately), so the flag is already
	-- back to false by the time the signal from OUR OWN `button.Text = ""`
	-- below actually fires -- that self-triggered firing then re-entered
	-- this handler with newText = "" and overwrote the label with an empty
	-- string (confirmed via screenshot: AbilityController's DASH button,
	-- which updates button.Text every 0.1s on a cooldown, went completely
	-- blank). Checking newText == "" instead sidesteps the deferred-timing
	-- problem entirely: no caller in this codebase ever intentionally sets
	-- button.Text to a literal empty string, so treating an empty incoming
	-- value as "that's our own clear echoing back" is safe and needs no
	-- synchronous flag at all.
	button:GetPropertyChangedSignal("Text"):Connect(function()
		local newText = button.Text
		if newText == "" then
			return
		end
		label.Text = newText
		label.TextSize = computeLabelTextSize(newText)
		button.Text = ""
	end)

	-- Bevel strip: a same-hue-darker rounded rectangle sitting along the
	-- button's bottom edge, so it reads as a 3D drop-shadow lip. Originally
	-- built as a full-width strip confined by a ClipsDescendants mask (so it
	-- couldn't poke out past the pill's rounded corners) -- but every button
	-- built that way came out with visibly garbled/muddy text specifically
	-- when the button sat inside a CanvasGroup panel (confirmed via
	-- screenshot: identical buttons on the plain-ScreenGui base HUD, outside
	-- any CanvasGroup, stayed crisp). That combination -- a ClipsDescendants
	-- frame nested inside a CanvasGroup -- reproduced consistently enough to
	-- treat as a real engine quirk, not a fluke, so this avoids
	-- ClipsDescendants entirely: the strip is inset from both edges by the
	-- pill's own corner radius (+ a few px margin) so it naturally sits
	-- within the rounded silhouette without ever needing to be clipped to it.
	local buttonHeightPx = size.Y.Offset
	local bevelInset = buttonHeightPx / 2 + 3

	local bevelStrip = Instance.new("Frame")
	bevelStrip.Name = "BevelStrip"
	bevelStrip.AnchorPoint = Vector2.new(0.5, 1)
	bevelStrip.Position = UDim2.fromScale(0.5, 1)
	bevelStrip.Size = UDim2.new(1, -bevelInset * 2, 0, BEVEL_DEPTH)
	bevelStrip.BackgroundColor3 = style.Shadow
	bevelStrip.BorderSizePixel = 0
	bevelStrip.Parent = button

	local bevelCorner = Instance.new("UICorner")
	bevelCorner.CornerRadius = UDim.new(0, 3)
	bevelCorner.Parent = bevelStrip

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
		spawnClickSparkles(button, style.Face)
	end)

	local function setActive(isActive: boolean)
		local target = if isActive then VARIANT_STYLE.Primary else VARIANT_STYLE.Secondary
		button.BackgroundColor3 = target.Face
		button.TextColor3 = target.Text
		bevelStrip.BackgroundColor3 = target.Shadow
		if label then
			label.TextColor3 = target.Text
		end
	end

	return button, setActive
end

-- For a caller that needs to swap a button's full color set at runtime
-- beyond what setActive's Tab on/off toggle covers (e.g. AbilityController's
-- ready/cooldown states, which used to poke button.BackgroundColor3
-- directly) -- keeps the bevel strip in sync with the face color instead of
-- it silently going stale, which is exactly what direct property pokes would
-- do now that the "shadow" is a separate child instead of part of one flat
-- color.
function Widgets.SetButtonColors(button: TextButton, face: Color3, shadow: Color3, text: Color3)
	button.BackgroundColor3 = face
	button.TextColor3 = text
	local strip = button:FindFirstChild("BevelStrip")
	if strip then
		(strip :: Frame).BackgroundColor3 = shadow
	end
	local label = button:FindFirstChild("Label")
	if label then
		(label :: TextLabel).TextColor3 = text
	end
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
