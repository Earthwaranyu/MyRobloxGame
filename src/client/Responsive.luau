-- One place that knows how big the screen is, so the HUD stops being built for
-- exactly one of them.
--
-- WHAT WAS WRONG: every panel in the client was laid out in raw pixel offsets
-- against a single developer monitor -- 41 controllers, and not one reference to
-- ViewportSize, TouchEnabled or UIAspectRatioConstraint between them. Theme's
-- top-centre lane is the clearest case: a 300px card and a 264px tab, fixed. On
-- a 1920-wide desktop that card is 15% of the screen; on a phone held in
-- landscape at 667 points it is 45% of it, with the Leave Match button beside it
-- pushed off the edge entirely. This is a platform that skews heavily mobile.
--
-- WHY THIS SCALES NUMBERS INSTEAD OF INSTALLING A UIScale, which is the usual
-- one-line fix for exactly this problem: a UIScale resamples what it scales, and
-- text through it comes out visibly blurry at any factor that isn't 1.0. That is
-- not a theory -- Widgets.Button carries the scar (see the comment at its
-- scale-tween: a continuous idle "breathing" pulse made every button label look
-- permanently smeared, and the fix was to pin the button at exactly 1.0 whenever
-- it isn't briefly animating). A global UIScale layer would put every device
-- that isn't the reference size into that state permanently, which trades a
-- layout bug for a legibility bug on the same devices.
--
-- So Scale() is a multiplier applied to the offsets and TextSizes THEMSELVES, at
-- build time. The geometry changes; nothing is resampled; every glyph is still
-- rendered at its own native size. UIScale stays what it is here -- an animation
-- tool that returns to 1.
--
-- WHERE THE ARITHMETIC LIVES: in Shared.LayoutMath, which takes the viewport as
-- a plain table and touches no Roblox service. This module is the wrapper that
-- fills that table in from the camera and UserInputService. The split exists so
-- the geometry can be tested headlessly (tests/run.sh) -- it decides the size
-- and position of every panel in twenty-odd controllers, and "it looked right on
-- one monitor" is not coverage for that.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LayoutMath = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LayoutMath"))

local Responsive = {}

export type Tier = LayoutMath.Tier

Responsive.MinTouchTarget = LayoutMath.MinTouchTarget
Responsive.ScreenMargin = LayoutMath.ScreenMargin

-- A full-screen, fully transparent Frame whose AbsoluteSize IS the area the GUI
-- system lays out into.
--
-- This exists because Workspace.CurrentCamera.ViewportSize cannot be trusted.
-- Measured on a running client: it reported (1, 1) for a window that was really
-- 1001x747, and stayed there. A width of 1 clamps straight to MinScale, so every
-- responsive panel in the game rendered at phone size on a desktop -- silently,
-- with nothing thrown and nothing to see in a log. Reading the size off a real
-- GuiObject asks the same subsystem that will position the panels, so it cannot
-- disagree with them.
--
-- The probe deliberately does NOT set IgnoreGuiInset, so it measures the same
-- area the game's own ScreenGuis lay out into -- everything here uses the
-- default, inset-respecting behaviour. Measured on a running client, the two
-- differ by the topbar: 1285x747 ignoring the inset versus 1285x689 with it. A
-- probe that reported 747 would let FitHeight clear a panel that then overflows
-- the 689 its ScreenGui actually has, which is the same class of "clamped
-- against the wrong number" bug this module exists to fix.
local probeFrame: Frame? = nil

local function ensureProbe(): Frame?
	if probeFrame and probeFrame.Parent then
		return probeFrame
	end

	local player = Players.LocalPlayer
	local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ResponsiveViewportProbe"
	screenGui.ResetOnSpawn = false
	-- Behind everything. It draws nothing, but it stays enabled: a disabled
	-- ScreenGui is not laid out, and an AbsoluteSize that never updates is worse
	-- than no probe at all.
	screenGui.DisplayOrder = -1000
	screenGui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Probe"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Active = false
	frame.Parent = screenGui

	probeFrame = frame
	return frame
end

local function viewportSize(): Vector2
	local probe = ensureProbe()
	if probe then
		local size = probe.AbsoluteSize
		if LayoutMath.IsSaneViewport(size.X, size.Y) then
			return size
		end
	end

	-- Fallback for the frames before PlayerGui exists.
	local camera = Workspace.CurrentCamera
	if camera and LayoutMath.IsSaneViewport(camera.ViewportSize.X, camera.ViewportSize.Y) then
		return camera.ViewportSize
	end

	-- Last resort: the reference size, so anything built in that window keeps
	-- the numbers it was authored with rather than being pinned to MinScale by a
	-- bad read -- which is the exact failure this whole block exists to prevent.
	return Vector2.new(LayoutMath.ReferenceWidth, LayoutMath.ReferenceWidth * 9 / 16)
end

-- The one place the Roblox services are read. Everything below is LayoutMath
-- with this table handed to it.
local function view(): LayoutMath.View
	local size = viewportSize()
	return { Width = size.X, Height = size.Y, Touch = UserInputService.TouchEnabled }
end

function Responsive.ViewportSize(): Vector2
	return viewportSize()
end

-- True on phones and tablets, and on a Windows touchscreen -- anything where a
-- finger is a plausible pointer. Deliberately NOT "is mobile": a desktop with a
-- touchscreen has the same 44pt problem.
function Responsive.IsTouch(): boolean
	return UserInputService.TouchEnabled
end

function Responsive.Tier(): LayoutMath.Tier
	return LayoutMath.Tier(view())
end

function Responsive.Scale(): number
	return LayoutMath.Scale(view())
end

function Responsive.Px(offset: number): number
	return LayoutMath.Px(view(), offset)
end

function Responsive.Text(size: number): number
	return LayoutMath.Text(view(), size)
end

function Responsive.Tap(offset: number): number
	return LayoutMath.Tap(view(), offset)
end

-- How much of the bottom edge Roblox's own touch controls actually occupy,
-- MEASURED rather than assumed.
--
-- The constant in LayoutMath is a fallback estimate, and measuring showed it was
-- badly wrong: on an 801x334 phone the real jump button is 70x70 at y=244, so
-- the genuine keep-out is 90pt -- while the estimate reserved 127 and the
-- original flat figure would have reserved 190. That difference is most of why
-- the HUD bunched into the top half with 40% of the screen left empty.
--
-- Roblox builds these into PlayerGui.TouchGui, so they can simply be read. The
-- estimate stays for the frames before that exists.
function Responsive.TouchBand(): number
	local estimate = LayoutMath.TouchBand(view())
	if estimate <= 0 then
		return 0
	end

	local player = Players.LocalPlayer
	local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
	local touchGui = playerGui and playerGui:FindFirstChild("TouchGui")
	local frame = touchGui and touchGui:FindFirstChild("TouchControlFrame")
	if not (frame and frame:IsA("GuiObject")) then
		return estimate
	end

	-- The JUMP BUTTON specifically, by name -- not the topmost of everything
	-- under TouchControlFrame. Scanning all descendants picks up layout
	-- containers that span most of the screen: measured, that returned a top
	-- edge of y=111 on a 579-tall viewport, i.e. a "band" of 467pt covering 80%
	-- of the display. The jump button is the one control that is always present,
	-- always visible, and actually bounded.
	local jump: GuiObject? = nil
	for _, control in frame:GetDescendants() do
		if control.Name == "JumpButton" and control:IsA("GuiObject") then
			jump = control
			break
		end
	end
	if not (jump and jump.Visible and jump.AbsoluteSize.Y > 0) then
		return estimate
	end

	-- Measured from the button's top edge to the bottom of the screen, and never
	-- allowed to exceed the estimate -- a bad reading should cost layout room,
	-- never hand a control's area back to the HUD.
	local viewportHeight = viewportSize().Y
	local top = jump.AbsolutePosition.Y - frame.AbsolutePosition.Y
	return math.round(math.clamp(viewportHeight - top, 0, estimate))
end

function Responsive.FitHeight(refHeight: number, top: number): number
	return LayoutMath.FitHeight(view(), refHeight, top)
end

function Responsive.ClampY(y: number, height: number): number
	return LayoutMath.ClampY(view(), y, height)
end

function Responsive.ClampX(x: number, width: number): number
	return LayoutMath.ClampX(view(), x, width)
end

function Responsive.ClearCorners(x: number, width: number): number
	return LayoutMath.ClearCorners(view(), x, width)
end

-- y of the nth HUD rail slot from the top (0-based). Rows derive their position
-- from the height rows actually have, so a Tap() floor can never close the gap
-- between two of them -- see LayoutMath.RailY.
function Responsive.RailY(index: number): number
	return LayoutMath.RailY(view(), index)
end

-- y of the nth row up from the bottom of the usable area (0 = bottom-most).
-- `rowWidth` lets a row that fits between the touch controls sit at the actual
-- bottom of the screen rather than above them -- see LayoutMath.BottomRowY.
function Responsive.BottomRowY(indexFromBottom: number, rowHeight: number, rowWidth: number?): number
	return LayoutMath.BottomRowY(view(), indexFromBottom, rowHeight, rowWidth)
end

-- x positions for a row of boxes centred as a group -- see LayoutMath.CenterRow.
function Responsive.CenterRow(widths: { number }, gap: number): { number }
	return LayoutMath.CenterRow(view(), widths, gap)
end

-- Sizes and places a panel so the whole of it is on screen, and reports the size
-- it settled on.
--
-- `x` and `y` are the top-left the caller WANTS, already in pixels -- the anchor
-- differs per panel (some hug the right edge, some the left, some centre) and
-- that is the caller's business. What is not the caller's business, and what
-- every one of them got wrong, is the clamping: six panels in this HUD ran off
-- the bottom of a phone by 27 to 261pt, which does not scroll into view, it
-- simply is not drawn.
--
-- Works because each of these panels sizes its content area RELATIVE to itself
-- (`UDim2.new(1, -16, 1, -60)` and friends, over a ScrollingFrame), so a shorter
-- panel means a shorter scroll window rather than clipped content.
function Responsive.PlacePanel(
	gui: GuiObject,
	refWidth: number,
	refHeight: number,
	x: number,
	y: number
): (number, number)
	local width, height = LayoutMath.PanelSize(view(), refWidth, refHeight)
	gui.Size = UDim2.fromOffset(width, height)
	gui.Position = UDim2.fromOffset(Responsive.ClampX(x, width), Responsive.ClampY(y, height))
	return width, height
end

-- Runs `callback` immediately, then again whenever the viewport changes size --
-- a phone rotating, a desktop window being dragged, a device with a dynamic
-- safe area. Returns a disconnect function.
--
-- Immediately, not just on change, because every call site would otherwise have
-- to duplicate the initial layout pass, and the one that forgets is the one that
-- looks broken until the player happens to rotate their phone.
-- ONE binding for every observer, rather than one binding each.
--
-- The per-caller version had a hole with teeth: it bound to the probe's
-- AbsoluteSize at the moment Observe was called, and if the probe did not exist
-- yet (PlayerGui not populated when that controller happened to initialise) it
-- silently bound nothing. That caller then never heard about a resize again --
-- and the camera fallback cannot cover it, because the camera's ViewportSize is
-- the broken value that never changes. Measured: the mobile drawer was still
-- positioned for a 1001-wide window long after the viewport had become
-- something else, while every other panel had followed along.
--
-- A single dispatcher retried until the probe exists fixes it for everyone at
-- once, and means a controller's position in load order stops mattering.
local observers: { [number]: () -> () } = {}
local nextObserverId = 0
local dispatcherStarted = false
local lastSize: Vector2? = nil

local function fireAll()
	for _, callback in observers do
		-- One controller's layout error must not stop the rest from updating.
		local ok, err = pcall(callback)
		if not ok then
			warn("Responsive: layout callback failed -- " .. tostring(err))
		end
	end
end

local function startDispatcher()
	if dispatcherStarted then
		return
	end
	dispatcherStarted = true

	-- Polled rather than driven by GetPropertyChangedSignal("AbsoluteSize").
	--
	-- That signal is the obvious choice and it is what this used to do, but it
	-- proved unreliable in practice: measured on a running client, forcing the
	-- probe to a new size updated AbsoluteSize correctly while no observer ever
	-- fired, leaving every panel laid out for the previous viewport. A missed
	-- resize is silent and total -- the HUD simply stays the wrong size -- which
	-- is too expensive a failure to accept for an event that fires a handful of
	-- times in a session.
	--
	-- Comparing the value directly cannot miss a change for any reason. At 5Hz
	-- over a Vector2 compare the cost is nil, and fireAll only does real work on
	-- the rare frame where the number actually moved.
	task.spawn(function()
		while true do
			local probe = ensureProbe()
			if probe then
				local size = probe.AbsoluteSize
				if LayoutMath.IsSaneViewport(size.X, size.Y) and size ~= lastSize then
					lastSize = size
					fireAll()
				end
			end
			task.wait(0.2)
		end
	end)
end

function Responsive.Observe(callback: () -> ()): () -> ()
	callback()

	nextObserverId += 1
	local id = nextObserverId
	observers[id] = callback
	startDispatcher()

	return function()
		observers[id] = nil
	end
end

-- The top-centre HUD lane at the current scale.
--
-- Theme.TopLane holds the reference numbers (it is a design-token module and
-- should not know what a viewport is); this is those numbers at the size they
-- should actually be drawn. The four controllers that share the lane --
-- WaveClock, QueueStatus, RaceHud and QuitMatch -- read it from here, so they
-- still agree with each other at every screen size, which was the entire reason
-- the lane got centralised in the first place.
function Responsive.Lane(theme: { TopLane: { [string]: number } }): { [string]: number }
	local lane = {}
	for key, value in theme.TopLane do
		lane[key] = Responsive.Px(value)
	end
	return lane
end

return Responsive
