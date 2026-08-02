-- Shared visual component factory. Keep this the only place that builds raw
-- GuiObjects so every panel/button in the game shares one look and feel.
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")

local Responsive = require(script.Parent.Responsive)
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
	-- Named so callers that recolour the ribbon (WaveClockController swaps gold
	-- for red in the last ten seconds) can find the strip and shift it with the
	-- face, instead of the ribbon flattening into a plain pill.
	bevelStrip.Name = "Bevel"
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
	-- this job.) Defaults to 25, comfortably above the base HUD (which sits at
	-- 0-15 across the rest of the game). Pass a bigger value for a modal that
	-- must sit above another modal (e.g. a reveal popup opened from within a
	-- shop panel). The one thing deliberately ABOVE all of these is TutorialGui
	-- (40) -- see the note there.
	DisplayOrder: number?,
	PanelOpts: PanelOpts?,
}

-- Comfortably above anything a caller builds into a panel, so the close button
-- is always on top of the modal's own content. See the note where it is applied.
local MODAL_CLOSE_ZINDEX = 50

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
function Widgets.Modal(
	name: string,
	size: UDim2,
	position: UDim2,
	opts: ModalOpts?
): (CanvasGroup, () -> (), () -> (), (boolean) -> (), ScreenGui)
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
	-- Tap() rather than a flat 34: this one button is shared by every modal in
	-- the game (11 of them), and on touch it is the primary way to dismiss any
	-- of them. It was the single most-repeated sub-44 target in the HUD.
	closeButton.Size = UDim2.fromOffset(Responsive.Tap(34), Responsive.Tap(34))
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.new(1, -10, 0, 10)
	-- Above the panel's own content. These ScreenGuis use ZIndexBehavior.Global,
	-- where a child does NOT inherit its parent's ZIndex -- so the ✕ sat at the
	-- default 1, the same as the scrolling grid a caller builds into the panel
	-- afterwards. Equal ZIndex means later-in-tree wins, so the grid rendered
	-- over the ✕ and swallowed the tap: measured on a phone, the emote modal
	-- could not be closed at all.
	closeButton.ZIndex = MODAL_CLOSE_ZINDEX
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

	-- Scaled with the button: Tap() can push it to 44 on touch, and a 16pt X
	-- adrift in a 44pt disc looks like a rendering fault.
	local closeSize = closeButton.Size.X.Offset
	local barScale = closeSize / 34
	for _, rotation in { 45, -45 } do
		local bar = Instance.new("Frame")
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Position = UDim2.fromScale(0.5, 0.5)
		bar.Size = UDim2.fromOffset(math.round(16 * barScale), math.max(2, 2.5 * barScale))
		bar.Rotation = rotation
		bar.BackgroundColor3 = Color3.new(1, 1, 1)
		bar.BorderSizePixel = 0
		-- Same reasoning as the button itself: children do not inherit ZIndex
		-- under ZIndexBehavior.Global, so the bars need lifting too or the X
		-- disappears behind the panel content the button now sits above.
		bar.ZIndex = MODAL_CLOSE_ZINDEX + 1
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
	-- panel) closes the modal -- one of the three exits every modal should
	-- have alongside the ✕ and whatever toggle button opened it. Can be
	-- switched off at runtime (see setClickOutsideEnabled) for a modal that's
	-- mid-ceremony rather than idly browsable -- e.g. a gacha reveal playing
	-- a ~30s sequence of pulls, where an impatient/accidental tap anywhere on
	-- screen used to dismiss the whole thing with no way back to see the
	-- result. The ✕ still always works either way -- that's a deliberate
	-- exit, not a stray tap.
	--
	-- panel.Active=true does NOT stop this InputBegan from also firing here
	-- on plain (non-GuiButton) panel content -- confirmed in Studio that
	-- Active only sinks clicks for actual TextButton/ImageButton children;
	-- a bare Frame like Widgets.Slider (or even just clicking blank panel
	-- background) still let the click through to the backdrop underneath,
	-- closing Settings the instant you pressed down on the volume slider.
	-- So this now explicitly ignores any press that lands inside the
	-- panel's own rect instead of trusting Active to have already filtered
	-- those out.
	local function isWithinPanel(screenPos: Vector2): boolean
		local topLeft = panel.AbsolutePosition
		local size = panel.AbsoluteSize
		return screenPos.X >= topLeft.X
			and screenPos.X <= topLeft.X + size.X
			and screenPos.Y >= topLeft.Y
			and screenPos.Y <= topLeft.Y + size.Y
	end

	local clickOutsideEnabled = true
	backdrop.InputBegan:Connect(function(input: InputObject)
		if not clickOutsideEnabled then
			return
		end
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			if isWithinPanel(Vector2.new(input.Position.X, input.Position.Y)) then
				return
			end
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
function Widgets.TabStrip(
	tabs: { TabDef },
	position: UDim2,
	opts: { Size: number?, Gap: number? }?
): (Frame, (string) -> (), ((string) -> ()) -> ())
	opts = opts or {}
	local tabSize = Responsive.Tap(opts.Size or 56)
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

-- button -> the opts.Icon draw function it was built with, so
-- Widgets.SetButtonColors can redraw the glyph in the new color (see there
-- for why it has to). Weak-keyed: a destroyed button must not be kept alive
-- by this table.
local ICON_BUILDERS: { [TextButton]: (Instance, Color3) -> () } = setmetatable({}, { __mode = "k" }) :: any

-- The colours a button should wear when it IS enabled, so the disabled styling
-- can be applied and removed without destroying whatever the caller last set
-- (a Tab toggle, or Widgets.SetButtonColors for a cooldown). Weak-keyed like
-- ICON_BUILDERS so a destroyed button doesn't pin an entry here forever.
type ButtonPalette = { Face: Color3, Shadow: Color3, Text: Color3 }
local BUTTON_PALETTE: { [TextButton]: ButtonPalette } = setmetatable({}, { __mode = "k" }) :: any
-- Repaint hooks, so SetButtonColors can go through the same enabled/disabled
-- path the constructor uses instead of poking properties behind its back.
local BUTTON_REPAINT: { [TextButton]: () -> () } = setmetatable({}, { __mode = "k" }) :: any

-- Re-runs a button's text fit against its CURRENT size. Widgets.Relayout calls
-- this: computeLabelTextSize closes over the size the button was BUILT with, so
-- without it a resized button keeps a label fitted for the old width -- which is
-- exactly why "Emotes"/"PRACTICE"/"METEOR DASH" were still rendering as
-- "E..."/"PRA..."/"METEOR..." after the responsive pass resized them.
local BUTTON_REFIT: { [TextButton]: (UDim2) -> () } = setmetatable({}, { __mode = "k" }) :: any

-- How far the bevel strip peeks out along the bottom edge -- big enough to
-- read as "3D depth" at every button size used in the game, small enough to
-- never eat into a short button's text.
local BEVEL_DEPTH = 5

local function lighten(color: Color3, amount: number): Color3
	return color:Lerp(Color3.new(1, 1, 1), amount)
end

local HOVER_SCALE_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- Pressing pushes the button DOWN onto its own bevel, rather than inflating it.
--
-- This used to puff out to 1.22 -- larger than the 1.08 hover -- so a press read
-- as "more hover" instead of as the control being depressed, which is the one
-- thing a press state exists to communicate. Every physical-button convention
-- runs the other way, and the bevel strip below only makes sense as a lip the
-- button sits down into.
--
-- The scale dip is deliberately slight; most of the effect comes from the bevel
-- collapsing, which is what reads as travel rather than as shrinking.
local PRESS_SCALE_INFO = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_SCALE_TARGET = 0.96
-- What the bevel collapses to while held: a sliver, not nothing, so the button
-- still has an edge at the bottom of the press.
local PRESS_BEVEL_DEPTH = 1
local SPARK_COUNT = 6

-- Disabled buttons. A button that can't be used has to LOOK like it, and this
-- is the state the set was missing entirely -- six call sites already set
-- `.Active = false` (inventory/shop "owned" rows, the party invite button, the
-- gacha luck toggle, VIP) and every one of them stayed fully bright and
-- clickable-looking.
--
-- Derived from whatever colours the button currently has rather than being a
-- fixed grey, so a disabled Primary and a disabled Danger still read as related
-- to their enabled selves instead of all collapsing into one anonymous slab.
local DISABLED_DESATURATION = 0.55
local DISABLED_TEXT_FADE = 0.45

local function toGrey(color: Color3, amount: number): Color3
	local luminance = color.R * 0.3 + color.G * 0.59 + color.B * 0.11
	return color:Lerp(Color3.new(luminance, luminance, luminance), amount)
end

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
local function fitTextSize(
	text: string,
	font: Enum.Font,
	maxSize: number,
	availableWidth: number,
	availableHeight: number
): number
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
		ICON_BUILDERS[button] = opts.Icon
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
	-- Set when the label cannot fit alongside the icon even at the smallest
	-- readable size, in which case the icon is dropped so the words survive.
	--
	-- Seen on a real phone: "Emotes" rendered as "E...", "PRACTICE" as "PRA...",
	-- "METEOR DASH" as "METEOR...". Those buttons carry an icon AND a label, and
	-- once the button scales down there is not room for both -- fitTextSize
	-- bottoms out at 10pt and TextTruncate eats the rest. A truncated word plus a
	-- glyph is the worst of the three options: the icon alone would at least be
	-- recognisable, and the word alone certainly is. So the icon yields, since
	-- these labels ("Emotes", "Party", "PRACTICE") are the thing a player reads.
	local iconSuppressed = false

	-- Mutable so Relayout can re-fit against the button's new size; starts as the
	-- size it was constructed with.
	local currentSize = size

	local function computeLabelTextSize(labelText: string): number
		if currentSize.X.Offset <= 0 then
			return maxLabelTextSize
		end

		local height = math.max(currentSize.Y.Offset, 20)
		local withIcon = currentSize.X.Offset - leftInset - rightInset
		local fitted = fitTextSize(labelText, button.Font, maxLabelTextSize, withIcon, height)

		-- Does it actually fit at the size we settled on, or did fitTextSize hit
		-- its floor and give up?
		local bounds = TextService:GetTextSize(labelText, fitted, button.Font, Vector2.new(1000, height))
		if bounds.X <= withIcon or not opts.Icon then
			iconSuppressed = false
			return fitted
		end

		iconSuppressed = true
		return fitTextSize(labelText, button.Font, maxLabelTextSize, currentSize.X.Offset - rightInset * 2, height)
	end

	-- Applies whatever computeLabelTextSize decided about the icon.
	local function applyIconSuppression(labelObject: TextLabel)
		local iconHolder = button:FindFirstChild("Icon")
		if iconHolder and iconHolder:IsA("GuiObject") then
			iconHolder.Visible = not iconSuppressed
		end
		if iconSuppressed then
			labelObject.Position = UDim2.fromOffset(rightInset, 0)
			labelObject.Size = UDim2.new(1, -rightInset * 2, 1, 0)
		else
			labelObject.Position = UDim2.fromOffset(leftInset, 0)
			labelObject.Size = UDim2.new(1, -(leftInset + rightInset), 1, 0)
		end
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
	applyIconSuppression(label)

	BUTTON_REFIT[button] = function(newSize: UDim2)
		currentSize = newSize
		label.TextSize = computeLabelTextSize(label.Text)
		applyIconSuppression(label)
	end

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
		applyIconSuppression(label)
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
	--
	-- The inset IS the pill's corner radius plus a small margin, and
	-- Theme.Corner.Button is UDim.new(1, 0) -- so the radius is half the button's
	-- rendered height. Deriving that from size.Y.Offset only works for a button
	-- sized in OFFSET. A button sized in SCALE (UDim2.fromScale) reports 0 there,
	-- which collapsed the inset to 3 and drew a near-full-width bar straight
	-- across the pill's rounded bottom corners -- the stray horizontal line that
	-- showed up under every Equip/Buy/Unequip button in the shop, inventory and
	-- gacha rows, all of which size their action buttons as a fraction of the row.
	--
	-- AbsoluteSize is the only thing that knows how tall those actually are, so
	-- the inset follows it. The offset-derived value is just the seed for the
	-- frames before the button is parented and laid out (AbsoluteSize is 0 until
	-- then); every later correction, including after Widgets.Relayout, comes
	-- through the signal.
	local bevelInset = math.max(3, size.Y.Offset / 2 + 3)
	local bevelDepth = BEVEL_DEPTH

	local bevelStrip = Instance.new("Frame")
	bevelStrip.Name = "BevelStrip"
	bevelStrip.AnchorPoint = Vector2.new(0.5, 1)
	bevelStrip.Position = UDim2.fromScale(0.5, 1)
	bevelStrip.Size = UDim2.new(1, -bevelInset * 2, 0, bevelDepth)
	bevelStrip.BackgroundColor3 = style.Shadow
	bevelStrip.BorderSizePixel = 0
	bevelStrip.Parent = button

	local bevelCorner = Instance.new("UICorner")
	bevelCorner.CornerRadius = UDim.new(0, 3)
	bevelCorner.Parent = bevelStrip

	button:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		local renderedHeight = button.AbsoluteSize.Y
		if renderedHeight <= 0 then
			return
		end
		bevelInset = renderedHeight / 2 + 3
		bevelStrip.Size = UDim2.new(1, -bevelInset * 2, 0, bevelDepth)
	end)

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

	-- Paints the button from its stored palette, dimmed if it's disabled.
	--
	-- Driven off `button.Active`, which every caller that disables a button
	-- already sets -- so the whole disabled treatment arrives at six existing
	-- call sites with no edits at any of them, exactly like the Label sync above.
	BUTTON_PALETTE[button] = { Face = style.Face, Shadow = style.Shadow, Text = style.Text }

	local function paint()
		local palette = BUTTON_PALETTE[button]
		local enabled = button.Active
		local face = if enabled then palette.Face else toGrey(palette.Face, DISABLED_DESATURATION)
		local shadow = if enabled then palette.Shadow else toGrey(palette.Shadow, DISABLED_DESATURATION)
		local textColor = if enabled then palette.Text else palette.Text:Lerp(face, DISABLED_TEXT_FADE)

		button.BackgroundColor3 = face
		button.TextColor3 = textColor
		bevelStrip.BackgroundColor3 = shadow
		label.TextColor3 = textColor
		-- The white border is what makes a button look "live"; softening it is
		-- most of what separates a disabled button from a merely dark one.
		border.Transparency = if enabled then 0 else 0.55

		-- MenuIcons glyphs are baked Frames, not tinted images, so the icon has
		-- to be redrawn to change colour (same reason SetButtonColors does it).
		local builder = ICON_BUILDERS[button]
		local iconHolder = button:FindFirstChild("Icon")
		if builder and iconHolder then
			builder(iconHolder, textColor)
		end
	end

	BUTTON_REPAINT[button] = paint
	button:GetPropertyChangedSignal("Active"):Connect(paint)
	paint()

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

	-- The bevel is the button's visible thickness, so collapsing it while held is
	-- what makes a press read as travel rather than as the button shrinking.
	-- Reads the CURRENT inset rather than the one captured at construction: the
	-- AbsoluteSize hook above rewrites it whenever the button's rendered height
	-- changes, and a press that tweened back to a stale inset would snap the
	-- strip to the wrong width on the way down.
	local function setBevel(depth: number, info: TweenInfo)
		bevelDepth = depth
		TweenService:Create(bevelStrip, info, {
			Size = UDim2.new(1, -bevelInset * 2, 0, depth),
		}):Play()
	end

	-- MouseEnter/MouseLeave still fire on an inactive button, so every handler
	-- checks rather than trusting Active to have suppressed the event.
	button.MouseEnter:Connect(function()
		if not button.Active then
			return
		end
		hovering = true
		if not pressed then
			settleScale(1.08, HOVER_SCALE_INFO)
		end
		Sounds.Play("Hover")
	end)
	button.MouseLeave:Connect(function()
		hovering = false
		if pressed then
			pressed = false
			setBevel(BEVEL_DEPTH, Theme.Anim.Ease)
		end
		settleScale(1, Theme.Anim.Pop)
	end)
	button.MouseButton1Down:Connect(function()
		if not button.Active then
			return
		end
		pressed = true
		stopScaleTween()
		currentScaleTween = TweenService:Create(scale, PRESS_SCALE_INFO, { Scale = PRESS_SCALE_TARGET })
		currentScaleTween:Play()
		setBevel(PRESS_BEVEL_DEPTH, PRESS_SCALE_INFO)
	end)
	button.MouseButton1Up:Connect(function()
		pressed = false
		setBevel(BEVEL_DEPTH, Theme.Anim.Pop)
		settleScale(if hovering then 1.08 else 1, Theme.Anim.Pop)
	end)
	button.MouseButton1Click:Connect(function()
		if not button.Active then
			return
		end
		Sounds.Play("Click")
		spawnClickSparkles(button, BUTTON_PALETTE[button].Face)
	end)

	local function setActive(isActive: boolean)
		local target = if isActive then VARIANT_STYLE.Primary else VARIANT_STYLE.Secondary
		-- Updates the STORED palette and repaints, rather than writing colours
		-- straight onto the instance. Poking properties directly would paint
		-- over a disabled button's dimming and leave it looking usable, and the
		-- next Active change would then restore the wrong colours.
		BUTTON_PALETTE[button] = { Face = target.Face, Shadow = target.Shadow, Text = target.Text }
		paint()
	end

	return button, setActive
end

-- Keeps a HUD rail button in its slot for the life of the session.
--
-- Scaling a button's size and position at CONSTRUCTION is not enough: those
-- values are computed once, so the button keeps them forever while everything
-- with a layout callback moves around it. Measured on the emulator after a
-- device change -- the Shop toggle had followed the new viewport width while
-- Gacha was still placed for the old one, because neither had any way to be told
-- the screen had changed.
--
-- `side` is "Left" (x measured from the left edge) or "Right" (from the right).
function Widgets.BindRail(
	button: TextButton,
	refWidth: number,
	refHeight: number,
	slot: number,
	side: "Left" | "Right",
	refInset: number
)
	-- The parent the button lives in while it belongs to the rail. MobileMenu can
	-- reparent it into the drawer on a phone, and when it does, the drawer owns
	-- its position -- two layout callbacks writing the same button fight, and
	-- which one wins depends on observer order. Measured: Inventory, Party and
	-- Gacha all landed on top of each other inside the drawer because this kept
	-- placing them at their rail slot after the drawer had already placed them.
	local home = button.Parent

	Responsive.Observe(function()
		if button.Parent ~= home then
			return
		end
		local width = Responsive.Px(refWidth)
		local height = Responsive.Tap(refHeight)
		local inset = Responsive.Px(refInset)
		local x = if side == "Right" then Responsive.ViewportSize().X - width - inset else inset
		Widgets.Relayout(
			button,
			UDim2.fromOffset(width, height),
			UDim2.fromOffset(Responsive.ClampX(x, width), Responsive.RailY(slot))
		)
	end)
end

-- Wraps a panel's existing content in a ScrollingFrame.
--
-- For panels whose content genuinely needs more height than a phone has: the
-- profile card is 509pt of avatar, stats and best-times against a 334pt screen,
-- so clamping the panel alone would just crop it. The panel gets clamped AND the
-- content scrolls inside whatever is left.
--
-- Existing children move across, except the ones that belong to the panel's
-- chrome rather than its content -- the hanging title Ribbon, the close button
-- and the pop-animation UIScale all stay put.
local PANEL_CHROME = { Ribbon = true, CloseButton = true, PopScale = true }

-- `clearCloseButton` (default true) pushes the content below the ✕. Pass false
-- for a panel whose top content is CENTRED -- the profile card leads with a
-- centred avatar that a corner button was never going to cover, and reserving
-- the close button's full height there just left a band of empty panel above it.
function Widgets.MakePanelScrollable(panel: GuiObject, pad: number, clearCloseButton: boolean?): ScrollingFrame
	local existing = panel:FindFirstChild("ContentScroll")
	if existing and existing:IsA("ScrollingFrame") then
		return existing
	end

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "ContentScroll"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollBarThickness = 4
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.Parent = panel

	for _, child in panel:GetChildren() do
		if child ~= scroll and child:IsA("GuiObject") and not PANEL_CHROME[child.Name] then
			child.Parent = scroll
		end
	end

	Responsive.Observe(function()
		local top = if clearCloseButton == false then pad else Widgets.ModalContentTop(pad)
		scroll.Position = UDim2.fromOffset(pad, top)
		scroll.Size = UDim2.new(1, -pad * 2, 1, -(top + pad))
	end)

	return scroll
end

-- The y a modal's content must start at to clear the close button.
--
-- The ✕ is anchored inside the panel's top-right corner (a CanvasGroup clips, so
-- it cannot straddle the edge), which means any content starting above its
-- bottom edge renders underneath it. Measured on a phone: the emote grid, the
-- shop list and the inventory list all had the ✕ sitting on their first row.
function Widgets.ModalContentTop(pad: number): number
	return math.max(pad, Responsive.Tap(34) + pad * 2)
end

-- The width a modal's top-right corner must give up so header content does not
-- run under the close ✕.
--
-- The horizontal counterpart of ModalContentTop, for the panels that put a
-- header BESIDE the ✕ rather than starting their content below it. The button is
-- anchored (1, 0) at x = -10 and is Tap(34) wide -- which on touch is 44, not
-- 34 -- so a header sized against the panel's full width runs straight under it.
-- Measured on a phone: the shop's points readout rendered as "1363 p" with the
-- ✕ sitting on the rest of it.
function Widgets.ModalCloseInset(): number
	return Responsive.Tap(34) + 16
end

-- Reference geometry for the accept/decline toasts below.
local TOAST_WIDTH = 360
local TOAST_HEIGHT = 130
local TOAST_PAD = 10
local TOAST_LABEL_HEIGHT = 44
local TOAST_LABEL_TOP = 12
local TOAST_LABEL_TEXT = 17
local TOAST_BUTTON_HEIGHT = 40
local TOAST_BUTTON_GAP = 20

export type ToastParts = {
	Toast: GuiObject,
	Label: TextLabel,
	Accept: TextButton,
	Decline: TextButton,
	-- 0 is nearest the bottom of the screen; higher stacks upward. Three of these
	-- exist across two controllers (party invite, join request, duel challenge)
	-- and any two can be on screen at once, so the stacking order has to be
	-- decided in one place rather than by each toast guessing an offset.
	StackIndex: number?,
}

-- Lays out a "someone is asking you something" toast: a line of text and an
-- accept/decline pair.
--
-- Shared because there are three of these and all three had the same bug. Each
-- was positioned by a hand-tuned `0.24 scale + N offset` guess that happened to
-- land somewhere sensible on the developer's monitor; on a 375pt phone the duel
-- one resolved to y = 390, entirely below the viewport, so a 1v1 challenge could
-- not be answered at all. The other two cleared the bottom edge but sat with
-- their buttons inside the touch-control band, where Roblox's own thumbstick and
-- jump button are drawn on top and take the press.
--
-- So position is derived rather than guessed: anchored to the bottom of the
-- usable area (above the control band), stacked upward by StackIndex, and
-- clamped to the viewport. A toast asking a question the player cannot answer is
-- worse than no toast.
function Widgets.LayoutToast(parts: ToastParts)
	local toast, label = parts.Toast, parts.Label
	local pad = Responsive.Px(TOAST_PAD)
	local buttonHeight = Responsive.Tap(TOAST_BUTTON_HEIGHT)
	local viewport = Responsive.ViewportSize()

	local width = math.min(Responsive.Px(TOAST_WIDTH), math.round(viewport.X - Responsive.ScreenMargin * 2))
	-- Tall enough to hold a full-size tap target once Tap() has had its say --
	-- otherwise a 44pt button on a phone overflows a proportionally-scaled toast.
	local height = math.max(
		Responsive.Px(TOAST_HEIGHT),
		Responsive.Px(TOAST_LABEL_TOP) + Responsive.Px(TOAST_LABEL_HEIGHT) + buttonHeight + pad * 2
	)

	local stack = parts.StackIndex or 0
	local bottom = viewport.Y - Responsive.TouchBand() - Responsive.ScreenMargin
	local y = Responsive.ClampY(math.round(bottom - height - stack * (height + pad)), height)

	toast.Size = UDim2.fromOffset(width, height)
	toast.Position = UDim2.fromOffset(math.round((viewport.X - width) / 2), y)

	label.Size = UDim2.new(1, -pad * 2, 0, Responsive.Px(TOAST_LABEL_HEIGHT))
	label.Position = UDim2.fromOffset(pad, Responsive.Px(TOAST_LABEL_TOP))
	label.TextSize = Responsive.Text(TOAST_LABEL_TEXT)

	local gap = Responsive.Px(TOAST_BUTTON_GAP)
	local buttonWidth = math.floor((width - pad * 2 - gap) / 2)
	local top = height - buttonHeight - pad
	Widgets.Relayout(parts.Accept, UDim2.fromOffset(buttonWidth, buttonHeight), UDim2.fromOffset(pad, top))
	Widgets.Relayout(
		parts.Decline,
		UDim2.fromOffset(buttonWidth, buttonHeight),
		UDim2.fromOffset(pad + buttonWidth + gap, top)
	)
end

-- Re-sizes and re-positions a button after construction, in the SAME terms the
-- caller built it with (a top-left size/position pair), rather than the terms it
-- is actually stored in.
--
-- This exists because a button is not laid out where you put it. Widgets.Button
-- re-anchors to (0.5, 0.5) so its hover/press UIScale grows symmetrically, and
-- folds half its own size into Position to compensate -- and it bakes its bevel
-- strip's inset from the height it was built at. So a caller that responds to a
-- viewport change by assigning button.Size and button.Position directly gets a
-- button offset by half its size with a bevel strip the wrong width, which is
-- both wrong and a genuinely confusing thing to debug from a screenshot.
--
-- Every one of those details is this module's business, so relayout is too. See
-- Responsive for the callers: the HUD's buttons re-derive their geometry from
-- the viewport, and this is how they apply it.
function Widgets.Relayout(button: TextButton, size: UDim2, position: UDim2)
	button.Size = size
	-- Same conversion Widgets.Button does at construction.
	button.Position = UDim2.new(
		position.X.Scale + size.X.Scale / 2,
		position.X.Offset + size.X.Offset / 2,
		position.Y.Scale + size.Y.Scale / 2,
		position.Y.Offset + size.Y.Offset / 2
	)

	-- The bevel strip is deliberately NOT touched here. Its inset is the pill's
	-- corner radius, i.e. half the button's RENDERED height, and Widgets.Button
	-- keeps it in step with AbsoluteSize -- which covers this resize as well as
	-- the scale-sized buttons a size.Y.Offset never described in the first place.
	-- Recomputing it here too would just fight that, one frame earlier.

	-- The label was fitted to the size the button was BUILT at. Without this a
	-- button that shrank keeps oversized text and truncates it to "PRA..." --
	-- measured on a real phone, and invisible to any check that only reads
	-- geometry.
	local refit = BUTTON_REFIT[button]
	if refit then
		refit(size)
	end
end

-- For a caller that needs to swap a button's full color set at runtime
-- beyond what setActive's Tab on/off toggle covers (e.g. AbilityController's
-- ready/cooldown states, which used to poke button.BackgroundColor3
-- directly) -- keeps the bevel strip in sync with the face color instead of
-- it silently going stale, which is exactly what direct property pokes would
-- do now that the "shadow" is a separate child instead of part of one flat
-- color.
function Widgets.SetButtonColors(button: TextButton, face: Color3, shadow: Color3, text: Color3)
	-- Goes through the button's own repaint where one exists, so a button that
	-- is currently DISABLED keeps its dimming instead of being painted back to
	-- full brightness by a caller that only meant to change its base colours
	-- (AbilityController swaps these on every cooldown tick).
	BUTTON_PALETTE[button] = { Face = face, Shadow = shadow, Text = text }
	local repaint = BUTTON_REPAINT[button]
	if repaint then
		repaint()
		return
	end

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

	-- Redraw the icon in the new text color too. MenuIcons glyphs are baked
	-- Frames, not tinted images -- their color is fixed at draw time -- so
	-- without this an icon keeps whatever color the button's ORIGINAL variant
	-- gave it. That's how the spectate carousel arrows became invisible: built
	-- as Secondary (near-black glyph on a white face), then recolored here to
	-- the dark disabled face, leaving a near-black arrow on a near-black
	-- circle. Only the face and label moved; the arrow stayed put.
	local builder = ICON_BUILDERS[button]
	local iconHolder = button:FindFirstChild("Icon")
	if builder and iconHolder then
		builder(iconHolder, text)
	end
end

-- Draggable horizontal 0-1 slider -- track + proportional fill + a round
-- thumb, matching the reference "volume mixer" look (see SettingsController's
-- Music/SFX volume rows). Clicking anywhere on the (generously-sized, not
-- just the thin visual track) hit area jumps the thumb there directly and
-- starts a drag, rather than requiring a precise grab on a 6px-tall strip.
-- Works with both mouse and touch. Returns the container Frame and a
-- setValue(value) setter for a caller that needs to move it programmatically
-- (e.g. syncing back to a value set elsewhere) without re-firing onChanged.
function Widgets.Slider(
	size: UDim2,
	position: UDim2,
	initial: number,
	onChanged: (number) -> ()
): (Frame, (number) -> ())
	local container = Instance.new("Frame")
	container.Name = "Slider"
	container.Size = size
	container.Position = position
	container.BackgroundTransparency = 1
	container.Active = true

	local THUMB_SIZE = 20

	-- Inset by half the thumb's own size on each side so the thumb's OWN
	-- edges -- not just its center -- stay within the container's bounds at
	-- the 0 and 1 extremes instead of poking out past them.
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0, 0.5)
	track.Position = UDim2.new(0, THUMB_SIZE / 2, 0.5, 0)
	track.Size = UDim2.new(1, -THUMB_SIZE, 0, 6)
	track.BackgroundColor3 = Theme.Candy.PanelShadow
	track.BorderSizePixel = 0
	track.Parent = container

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = Theme.Candy.Green.Face
	fill.BorderSizePixel = 0
	fill.Parent = track

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	-- Child of `track`, not `container` -- its Position is a 0-1 Scale
	-- across the TRACK's own width, so it and `fill` (also sized as a Scale
	-- of the track) can never drift out of sync with each other.
	local thumb = Instance.new("Frame")
	thumb.Name = "Thumb"
	thumb.AnchorPoint = Vector2.new(0.5, 0.5)
	thumb.Size = UDim2.fromOffset(THUMB_SIZE, THUMB_SIZE)
	thumb.BackgroundColor3 = Color3.new(1, 1, 1)
	thumb.BorderSizePixel = 0
	thumb.ZIndex = 2
	thumb.Parent = track

	local thumbCorner = Instance.new("UICorner")
	thumbCorner.CornerRadius = UDim.new(1, 0)
	thumbCorner.Parent = thumb

	local thumbStroke = Instance.new("UIStroke")
	thumbStroke.Color = Theme.Candy.Green.Face
	thumbStroke.Thickness = 3
	thumbStroke.Parent = thumb

	local value = 0
	local function apply(v: number)
		value = math.clamp(v, 0, 1)
		fill.Size = UDim2.new(value, 0, 1, 0)
		thumb.Position = UDim2.new(value, 0, 0.5, 0)
	end
	apply(initial)

	local function isPointerInput(input: InputObject): boolean
		return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
	end

	local function updateFromScreenX(x: number)
		local trackWidth = track.AbsoluteSize.X
		if trackWidth <= 0 then
			return
		end
		apply((x - track.AbsolutePosition.X) / trackWidth)
		onChanged(value)
	end

	local dragging = false
	container.InputBegan:Connect(function(input: InputObject)
		if isPointerInput(input) then
			dragging = true
			updateFromScreenX(input.Position.X)
		end
	end)
	-- Global, not container.InputChanged -- a fast drag routinely moves the
	-- cursor off the (fairly small) container between frames, and a
	-- per-object InputChanged stops firing the moment the cursor leaves its
	-- bounds. Listening globally and gating on `dragging` keeps tracking the
	-- drag anywhere on screen until the button/touch actually lifts.
	UserInputService.InputChanged:Connect(function(input: InputObject)
		if
			dragging
			and (
				input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch
			)
		then
			updateFromScreenX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if isPointerInput(input) then
			dragging = false
		end
	end)

	return container, function(v: number)
		apply(v)
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
