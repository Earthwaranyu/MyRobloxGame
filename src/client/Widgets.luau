-- Shared visual component factory. Keep this the only place that builds raw
-- GuiObjects so every panel/button in the game shares one look and feel.
local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)
local Sounds = require(script.Parent.Sounds)

local Widgets = {}

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

local VARIANT_GRADIENT = {
	Primary = { Theme.Color.AccentA, Theme.Color.AccentB },
	Secondary = { Theme.Color.PanelLight, Theme.Color.Panel },
	Success = { Color3.fromRGB(60, 200, 120), Color3.fromRGB(40, 160, 95) },
	Danger = { Color3.fromRGB(230, 90, 100), Color3.fromRGB(190, 60, 75) },
	Tab = { Theme.Color.PanelLight, Theme.Color.Panel },
}

-- Returns the button plus a setActive(isActive) setter (only meaningful for
-- Variant = "Tab") so callers can restyle a tab's active state without
-- rebuilding it. Instances can't hold custom fields, hence the second value.
function Widgets.Button(text: string, size: UDim2, position: UDim2, opts: ButtonOpts?): (TextButton, (boolean) -> ())
	opts = opts or {}
	local variant = opts.Variant or "Primary"
	local isActiveTab = variant == "Tab" and opts.Active

	local button = Instance.new("TextButton")
	button.Text = text
	button.Size = size
	button.Position = position
	button.BackgroundColor3 = Theme.Color.AccentA
	button.TextColor3 = Theme.Color.TextPrimary
	button.Font = Theme.Font.Heading
	button.TextSize = opts.TextSize or 16
	button.TextScaled = opts.TextSize == nil
	button.AutoButtonColor = false
	button.BorderSizePixel = 0

	local uiSizeConstraint = Instance.new("UITextSizeConstraint")
	uiSizeConstraint.MaxTextSize = opts.TextSize or 20
	uiSizeConstraint.Parent = button

	local corner = Instance.new("UICorner")
	corner.CornerRadius = Theme.Corner.Button
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Color.Stroke
	stroke.Thickness = 1
	stroke.Transparency = 0.5
	stroke.Parent = button

	local gradient = Instance.new("UIGradient")
	local colors = isActiveTab and VARIANT_GRADIENT.Primary or (VARIANT_GRADIENT[variant] or VARIANT_GRADIENT.Primary)
	gradient.Color = ColorSequence.new(colors[1], colors[2])
	gradient.Rotation = 90
	gradient.Parent = button

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = button

	local hovering = false
	local function applyHoverScale()
		local target = if hovering then 1.035 else 1
		TweenService:Create(scale, Theme.Anim.Ease, { Scale = target }):Play()
	end

	button.MouseEnter:Connect(function()
		hovering = true
		applyHoverScale()
		Sounds.Play("Hover")
	end)
	button.MouseLeave:Connect(function()
		hovering = false
		applyHoverScale()
	end)
	button.MouseButton1Down:Connect(function()
		TweenService:Create(scale, TweenInfo.new(0.08), { Scale = 0.96 }):Play()
	end)
	button.MouseButton1Up:Connect(function()
		applyHoverScale()
	end)
	button.MouseButton1Click:Connect(function()
		Sounds.Play("Click")
	end)

	local function setActive(isActive: boolean)
		local activeColors = VARIANT_GRADIENT.Primary
		local inactiveColors = VARIANT_GRADIENT.Secondary
		local target = if isActive then activeColors else inactiveColors
		gradient.Color = ColorSequence.new(target[1], target[2])
		stroke.Transparency = if isActive then 0.15 else 0.5
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
