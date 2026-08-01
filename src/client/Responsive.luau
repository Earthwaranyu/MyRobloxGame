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
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Responsive = {}

export type Tier = "Phone" | "Tablet" | "Desktop"

-- The viewport width every hand-placed offset in the client was drawn against.
-- Scale() is 1.0 here by construction, so a desktop player sees pixel-identical
-- output to before this module existed -- this is a widening, not a redesign.
local REFERENCE_WIDTH = 1280

-- Bounds on that multiplier, and they are asymmetric on purpose.
--
-- Down to 0.72: below about that, chrome stops being readable at arm's length on
-- a phone faster than it stops fitting -- a HUD that fits and can't be read has
-- not been made responsive. Panels that still overflow at the floor need to
-- reflow (fewer columns, shorter labels), which is a per-panel decision and not
-- something a global multiplier can make.
--
-- Up to only 1.15: a 4K monitor should give you MORE map and MORE race, not a
-- proportionally enormous HUD. Chrome that grows with the screen is the mistake
-- in the other direction.
local MIN_SCALE = 0.72
local MAX_SCALE = 1.15

-- Roblox's own minimum comfortable tap target, and the floor every interactive
-- element is held to on touch regardless of what Scale() would otherwise do to
-- it. Shrinking a 44px button to 32 because the phone is small is precisely
-- backwards: the small screen is the one where it is hit with a thumb.
Responsive.MinTouchTarget = 44

-- Below this width the layout is a phone's: single column, nothing parked
-- beside anything else, chrome at its floor size. Measured in viewport points
-- rather than device pixels, so a retina phone is still a phone.
local PHONE_MAX_WIDTH = 800
local TABLET_MAX_WIDTH = 1100

local function viewportSize(): Vector2
	local camera = Workspace.CurrentCamera
	-- No camera for a frame or two during load. The reference size keeps
	-- anything built in that window at the numbers it was authored with, rather
	-- than at some fraction of a zero viewport.
	if not camera or camera.ViewportSize.X < 1 then
		return Vector2.new(REFERENCE_WIDTH, REFERENCE_WIDTH * 9 / 16)
	end
	return camera.ViewportSize
end

function Responsive.ViewportSize(): Vector2
	return viewportSize()
end

-- True on phones and tablets, and on a Windows touchscreen -- anything where a
-- finger is a plausible pointer. Deliberately NOT "is mobile": a desktop with a
-- touchscreen has the same 44px problem, and a controller-only console has the
-- same problem for a different reason (no pointer at all).
function Responsive.IsTouch(): boolean
	return UserInputService.TouchEnabled
end

function Responsive.Tier(): Tier
	local width = viewportSize().X
	if width <= PHONE_MAX_WIDTH then
		return "Phone"
	elseif width <= TABLET_MAX_WIDTH then
		return "Tablet"
	end
	return "Desktop"
end

-- The layout multiplier. Multiply hand-authored offsets and TextSizes by this
-- rather than wrapping anything in a UIScale -- see the header for why that
-- distinction is the whole point of this module.
function Responsive.Scale(): number
	return math.clamp(viewportSize().X / REFERENCE_WIDTH, MIN_SCALE, MAX_SCALE)
end

-- Scaled offset, rounded to a whole pixel.
--
-- Rounding matters more than it looks: a frame sized to a fractional pixel gets
-- its edge and its stroke antialiased across two rows, which reads as exactly
-- the softness this module exists to avoid. Sizes and positions are integers.
function Responsive.Px(offset: number): number
	return math.round(offset * Responsive.Scale())
end

-- Scaled TextSize, floored at something still legible. Fonts render at integer
-- sizes anyway, so this is the same rounding argument as Px with a floor on it.
local MIN_TEXT_SIZE = 11
function Responsive.Text(size: number): number
	return math.max(MIN_TEXT_SIZE, math.round(size * Responsive.Scale()))
end

-- A tap target's size: scaled like anything else, but never below the touch
-- minimum on a device that is actually touched.
function Responsive.Tap(offset: number): number
	local scaled = Responsive.Px(offset)
	if Responsive.IsTouch() then
		return math.max(Responsive.MinTouchTarget, scaled)
	end
	return scaled
end

-- Air between a panel and the edge of the screen. Small; its job is only to stop
-- a panel's border sitting exactly on the bezel.
Responsive.ScreenMargin = 8

-- Height of the band along the bottom of the screen that Roblox's OWN touch
-- controls occupy -- the movement thumbstick bottom-left, the jump button
-- bottom-right. Zero on anything without a touchscreen.
--
-- Nothing tappable belongs in that band on a phone. It is not a matter of
-- overlap looking untidy: the controls are drawn by CoreGui ABOVE this game's
-- ScreenGuis, so a button under them is not merely obscured, it cannot be
-- pressed at all -- and worse, a button that does catch the touch first eats an
-- input the player meant as "move" or "jump".
--
-- 190 covers the classic thumbstick (a ~120pt circle inset from the corner) with
-- room for the dynamic thumbstick, which has no fixed circle and activates from
-- a larger region of the lower-left. Deliberately generous: being 30pt too
-- cautious costs a little layout room, being 30pt too tight costs a control.
local TOUCH_CONTROL_BAND = 190

function Responsive.TouchBand(): number
	return if Responsive.IsTouch() then TOUCH_CONTROL_BAND else 0
end

-- A panel's height, scaled but never taller than the screen can show.
--
-- The reason this is not just Px(): a panel whose bottom runs off the viewport
-- does not scroll into view, it is simply not rendered -- and every panel in
-- this HUD is positioned from its TOP, so the part that vanishes is the bottom,
-- which is where the buttons are. Several of them (Shop, Gacha, Leaderboard)
-- were 200-260pt past the bottom edge of a phone.
--
-- `top` is where the panel starts, so what is left below it is what it can use.
local MIN_PANEL_HEIGHT = 120
function Responsive.FitHeight(refHeight: number, top: number): number
	local available = viewportSize().Y - top - Responsive.ScreenMargin
	return math.round(math.max(MIN_PANEL_HEIGHT, math.min(Responsive.Px(refHeight), available)))
end

-- Clamps a top edge so a box of this height stays fully on screen. Pairs with
-- FitHeight for panels that are positioned rather than centred.
function Responsive.ClampY(y: number, height: number): number
	local margin = Responsive.ScreenMargin
	local lowest = math.max(margin, viewportSize().Y - height - margin)
	return math.round(math.clamp(y, margin, lowest))
end

-- Clamps a left edge the same way.
function Responsive.ClampX(x: number, width: number): number
	local margin = Responsive.ScreenMargin
	local rightmost = math.max(margin, viewportSize().X - width - margin)
	return math.round(math.clamp(x, margin, rightmost))
end

-- Horizontal keep-out at the bottom corners on touch. The band above is the
-- vertical half of the same story: the thumbstick owns the bottom LEFT corner
-- and the jump button the bottom RIGHT, but the strip between them is clear --
-- which is why PLAY, VS BOTS and DASH can sit low on the screen at all.
--
-- ClearCorners below uses these to say how far in from each edge that clear
-- strip starts, so a button in the lower band can be nudged out of a corner
-- instead of being moved somewhere else entirely.
local TOUCH_CORNER_WIDTH = 190

local function safeLeft(): number
	return if Responsive.IsTouch() then TOUCH_CORNER_WIDTH else 0
end

local function safeRight(): number
	local width = viewportSize().X
	return if Responsive.IsTouch() then width - TOUCH_CORNER_WIDTH else width
end

-- Nudges a box of `width` at `x` out of whichever bottom corner it overlaps,
-- for a control that sits low enough to be in the touch-control band. Returns
-- `x` unchanged on desktop and on anything already clear.
function Responsive.ClearCorners(x: number, width: number): number
	if not Responsive.IsTouch() then
		return x
	end
	local left, right = safeLeft(), safeRight()
	if x < left then
		x = left
	end
	if x + width > right then
		x = right - width
	end
	-- A control wider than the clear strip can't be moved out of both corners;
	-- centring it is the least-bad outcome and keeps it symmetric.
	if x < left then
		x = math.round((left + right - width) / 2)
	end
	return math.round(x)
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
	local margin = Responsive.ScreenMargin
	local width = math.min(Responsive.Px(refWidth), math.round(viewportSize().X - margin * 2))
	local height = Responsive.FitHeight(refHeight, margin)
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
function Responsive.Observe(callback: () -> ()): () -> ()
	callback()

	local connection: RBXScriptConnection? = nil

	local function bind()
		if connection then
			connection:Disconnect()
			connection = nil
		end
		local camera = Workspace.CurrentCamera
		if camera then
			connection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(callback)
		end
	end

	-- The camera is replaced on respawn in some modes, and a connection to the
	-- old one silently stops firing -- the panel then keeps whatever size it had
	-- when the swap happened. Rebinding also re-runs the callback, since the new
	-- camera can come up at a different size than the old one went down at.
	local cameraConnection = Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		bind()
		callback()
	end)
	bind()

	return function()
		if connection then
			connection:Disconnect()
			connection = nil
		end
		cameraConnection:Disconnect()
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
