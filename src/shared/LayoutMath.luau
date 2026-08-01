-- The HUD's responsive geometry, as pure arithmetic.
--
-- Split out of the client's Responsive module so it can be tested. Responsive
-- reads Workspace.CurrentCamera and UserInputService, which means none of it
-- could run under tests/run.sh -- and these functions now decide the size and
-- position of every panel in twenty-odd controllers, so "it looked right on one
-- monitor" is not adequate coverage for them.
--
-- Everything here takes the viewport explicitly as a View rather than reaching
-- for it, which is the whole trick: a test can ask what a 667x375 phone gets
-- without a phone, a camera, or a running game. Responsive is the thin wrapper
-- that fills the View in from the real services.
--
-- Nothing in this file may touch a Roblox service. That is what keeps it
-- testable, and it is the same rule src/shared follows everywhere else.
local LayoutMath = {}

export type View = {
	Width: number,
	Height: number,
	Touch: boolean,
}

-- The viewport width every hand-placed offset in the client was drawn against.
-- Scale() is exactly 1.0 here, so a desktop player sees pixel-identical output
-- to before any of this existed -- a widening, not a redesign.
LayoutMath.ReferenceWidth = 1280

-- Bounds on the multiplier, asymmetric on purpose.
--
-- Down to 0.72: below about that, chrome stops being readable at arm's length on
-- a phone faster than it stops fitting -- a HUD that fits and can't be read has
-- not been made responsive. A panel that still overflows at the floor needs to
-- reflow (fewer columns, shorter labels), which is a per-panel decision a global
-- multiplier cannot make.
--
-- Up to only 1.15: a 4K monitor should give MORE map and MORE race, not a
-- proportionally enormous HUD.
LayoutMath.MinScale = 0.72
LayoutMath.MaxScale = 1.15

-- Fonts render at integer sizes, and below ~11 they stop being readable at
-- arm's length regardless of what the scale says.
LayoutMath.MinTextSize = 11

-- Roblox's minimum comfortable tap target. Every interactive element is held to
-- this on touch no matter what the scale would otherwise do to it: shrinking a
-- button because the screen is small is backwards, since the small screen is the
-- one being hit with a thumb.
LayoutMath.MinTouchTarget = 44

-- Air between a panel and the edge of the screen, so a border never sits
-- exactly on the bezel.
LayoutMath.ScreenMargin = 8

-- The band along the bottom that Roblox's OWN touch controls occupy -- the
-- movement thumbstick bottom-left, the jump button bottom-right.
--
-- Those are drawn by CoreGui, ABOVE every ScreenGui this game creates, so a
-- button underneath one is not merely obscured: it cannot be pressed, and it
-- eats a touch the player meant as "move" or "jump".
--
-- 190 covers the classic thumbstick (a ~120pt circle inset from the corner) with
-- room for the dynamic thumbstick, which has no fixed circle and activates from
-- a larger region. Deliberately generous -- being 30pt too cautious costs a
-- little layout room, being 30pt too tight costs a control.
LayoutMath.TouchControlBand = 190

-- How far in from each bottom edge those controls reach. The strip BETWEEN them
-- is clear, which is why PLAY and DASH can sit low on the screen at all.
LayoutMath.TouchCornerWidth = 190

-- A panel clamped smaller than this is not worth showing.
LayoutMath.MinPanelHeight = 120

LayoutMath.PhoneMaxWidth = 800
LayoutMath.TabletMaxWidth = 1100

-- Smallest viewport worth believing.
--
-- Not paranoia: Workspace.CurrentCamera.ViewportSize genuinely reports (1, 1)
-- in Studio for a window whose real size is 1001x747, and it can stay that way
-- rather than correcting itself. A naive "is it zero?" check does not catch
-- that, and the consequence is silent and total -- a width of 1 clamps straight
-- to MinScale, so the whole desktop HUD renders at phone size and nothing
-- errors. That shipped and was only caught by measuring a running client.
--
-- No real device is narrower than this, so anything below it is a bad read and
-- the caller should fall back rather than lay out against it.
LayoutMath.MinSaneViewport = 160

function LayoutMath.IsSaneViewport(width: number, height: number): boolean
	return width >= LayoutMath.MinSaneViewport and height >= LayoutMath.MinSaneViewport
end

export type Tier = "Phone" | "Tablet" | "Desktop"

function LayoutMath.Tier(view: View): Tier
	if view.Width <= LayoutMath.PhoneMaxWidth then
		return "Phone"
	elseif view.Width <= LayoutMath.TabletMaxWidth then
		return "Tablet"
	end
	return "Desktop"
end

-- The layout multiplier. Callers multiply hand-authored offsets and TextSizes by
-- this rather than wrapping anything in a UIScale -- see Responsive's header for
-- why that distinction is the entire point.
function LayoutMath.Scale(view: View): number
	return math.clamp(view.Width / LayoutMath.ReferenceWidth, LayoutMath.MinScale, LayoutMath.MaxScale)
end

-- Scaled offset, rounded to a whole pixel: a frame sized to a fractional pixel
-- gets its edge and stroke antialiased across two rows, which reads as exactly
-- the softness this whole approach exists to avoid.
function LayoutMath.Px(view: View, offset: number): number
	return math.round(offset * LayoutMath.Scale(view))
end

function LayoutMath.Text(view: View, size: number): number
	return math.max(LayoutMath.MinTextSize, math.round(size * LayoutMath.Scale(view)))
end

function LayoutMath.Tap(view: View, offset: number): number
	local scaled = LayoutMath.Px(view, offset)
	if view.Touch then
		return math.max(LayoutMath.MinTouchTarget, scaled)
	end
	return scaled
end

function LayoutMath.TouchBand(view: View): number
	return if view.Touch then LayoutMath.TouchControlBand else 0
end

-- A panel's height, scaled but never taller than the screen can show.
--
-- Not just Px(): a panel whose bottom runs off the viewport does not scroll into
-- view, it is simply not drawn -- and these panels are positioned from their
-- TOP, so what vanishes is the bottom, which is where the buttons are.
function LayoutMath.FitHeight(view: View, refHeight: number, top: number): number
	local available = view.Height - top - LayoutMath.ScreenMargin
	return math.round(math.max(LayoutMath.MinPanelHeight, math.min(LayoutMath.Px(view, refHeight), available)))
end

-- Clamps a top edge so a box of this height stays fully on screen.
function LayoutMath.ClampY(view: View, y: number, height: number): number
	local margin = LayoutMath.ScreenMargin
	local lowest = math.max(margin, view.Height - height - margin)
	return math.round(math.clamp(y, margin, lowest))
end

function LayoutMath.ClampX(view: View, x: number, width: number): number
	local margin = LayoutMath.ScreenMargin
	local rightmost = math.max(margin, view.Width - width - margin)
	return math.round(math.clamp(x, margin, rightmost))
end

-- Nudges a box out of whichever bottom corner it overlaps, for a control low
-- enough to be inside the touch-control band.
function LayoutMath.ClearCorners(view: View, x: number, width: number): number
	if not view.Touch then
		return x
	end
	local left = LayoutMath.TouchCornerWidth
	local right = view.Width - LayoutMath.TouchCornerWidth
	if x < left then
		x = left
	end
	if x + width > right then
		x = right - width
	end
	-- A box wider than the clear strip cannot be moved out of both corners;
	-- centring is the least-bad outcome and at least keeps it symmetric.
	if x < left then
		x = (left + right - width) / 2
	end
	return math.round(x)
end

return LayoutMath
