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

-- Roblox's own touch controls, from its documented geometry rather than guessed
-- constants. The jump button is 70x70 when the screen's minimum axis is 500 or
-- less and 120x120 above that, positioned at
--   {1, -(size * 1.5 - 10), 1, -size - 20}     (small)
--   {1, -(size * 1.5 - 10), 1, -size * 1.75}   (large)
-- which pins both how far up it reaches and how far in from the right edge.
--
-- Using the real formula matters in both directions: the previous guess
-- over-reserved the corners on a phone (190 wide against a real ~105) and
-- UNDER-reserved the band on a tablet (162 against a real 210).
--
-- Sources: "The Correct Way to Design Mobile Buttons" (Roblox DevForum) and the
-- on-screen containers documentation.
LayoutMath.JumpButtonSmall = 70
LayoutMath.JumpButtonLarge = 120
LayoutMath.SmallScreenAxis = 500

local function jumpButtonSize(view: View): number
	local minAxis = math.min(view.Width, view.Height)
	return if minAxis <= LayoutMath.SmallScreenAxis then LayoutMath.JumpButtonSmall else LayoutMath.JumpButtonLarge
end

-- How far in from each bottom edge those controls reach. The strip BETWEEN them
-- is CLEAR -- that is the single most useful thing the documentation says, and
-- the thing the old model got wrong: it banned a full-width band across the
-- bottom, so the action row was pushed up and roughly a third of a phone screen
-- went unused. Only the two corners are actually spoken for.
function LayoutMath.CornerWidth(view: View): number
	return math.round(jumpButtonSize(view) * 1.5)
end

-- A panel clamped smaller than this is not worth showing.
LayoutMath.MinPanelHeight = 120

-- Share of a phone screen a modal should occupy AT LEAST.
--
-- Scaling a modal down by the same factor as the HUD is backwards. Chrome should
-- shrink on a small screen so it stops crowding the game, but a modal IS the
-- screen while it is open -- and the emote picker came out 259x135 on an 801x334
-- phone, a quarter of the display, showing two rows of a grid that had room for
-- five. The device with the least space ended up using the least of it.
--
-- These are floors, not targets: a modal whose reference size is already larger
-- keeps it, and desktop is untouched because the floors only apply on a phone.
LayoutMath.PhonePanelMinWidthShare = 0.72
LayoutMath.PhonePanelMinHeightShare = 0.82

-- The size a panel should actually be drawn at, given its reference size.
function LayoutMath.PanelSize(view: View, refWidth: number, refHeight: number): (number, number)
	local margin = LayoutMath.ScreenMargin
	local maxWidth = view.Width - margin * 2
	local maxHeight = view.Height - margin * 2

	local width = math.min(LayoutMath.Px(view, refWidth), maxWidth)
	local height = math.min(LayoutMath.Px(view, refHeight), maxHeight)

	if LayoutMath.Tier(view) == "Phone" then
		width = math.max(width, math.min(maxWidth, view.Width * LayoutMath.PhonePanelMinWidthShare))
		height = math.max(height, math.min(maxHeight, view.Height * LayoutMath.PhonePanelMinHeightShare))
	end

	return math.round(width), math.round(math.max(LayoutMath.MinPanelHeight, height))
end

-- HUD rows are placed by SLOT, not by scaling their authored y.
--
-- This is the bug that made the first real-device screenshot look broken. Row
-- positions were scaled (y 60 -> 43, y 116 -> 84) while row HEIGHTS were held at
-- the 44pt touch minimum by Tap() -- so the gaps shrank by 28% while the rows
-- did not shrink at all, and every stacked pair in the HUD ended up overlapping.
-- Nine overlapping pairs, measured.
--
-- Deriving each row's y from the height rows ACTUALLY have makes the two agree
-- by construction: whatever Tap() decides a row is, the next row starts below it.
LayoutMath.RailTop = 7
LayoutMath.RailGap = 8
LayoutMath.RailRow = 48

-- y of the nth rail slot, counting from the top of the screen (0-based).
function LayoutMath.RailY(view: View, index: number): number
	local row = LayoutMath.Tap(view, LayoutMath.RailRow)
	return LayoutMath.Px(view, LayoutMath.RailTop) + index * (row + LayoutMath.Px(view, LayoutMath.RailGap))
end

-- x positions for a row of boxes centred as a group, given their widths.
--
-- Exists so three separate controllers can agree on one row. On a phone the
-- screen is WIDE but very short (801x334 measured), so the bottom cluster has to
-- spread sideways rather than stack: three stacked rows plus two rail rows do
-- not fit in 334pt, and the top of the stack collided with the Emotes button.
-- SPRINT / PLAY / DASH share a row instead, and each controller derives its own
-- x from the same call so they cannot drift apart.
function LayoutMath.CenterRow(view: View, widths: { number }, gap: number): { number }
	local total = 0
	for index, width in widths do
		total += width
		if index > 1 then
			total += gap
		end
	end

	local x = math.round((view.Width - total) / 2)
	local positions = {}
	for _, width in widths do
		table.insert(positions, x)
		x += width + gap
	end
	return positions
end

-- y of the nth row up from the bottom (0 = bottom-most), for the PLAY / VS BOTS
-- / SPRINT cluster.
--
-- `rowWidth` decides how far down the row may go, and this is the correction
-- that reclaimed roughly a third of a phone screen. The touch controls occupy
-- the bottom CORNERS, not a full-width strip: a row narrow enough to sit between
-- them can run all the way to the bottom margin, and only a row wide enough to
-- reach into a corner has to stay above them. The previous model kept everything
-- above the band unconditionally, which pushed the whole cluster up and left the
-- bottom of the display empty.
function LayoutMath.BottomRowY(view: View, indexFromBottom: number, rowHeight: number, rowWidth: number?): number
	local gap = LayoutMath.Px(view, LayoutMath.RailGap)
	local margin = LayoutMath.ScreenMargin

	local clearStrip = view.Width - LayoutMath.CornerWidth(view) * 2
	local fitsBetweenControls = rowWidth ~= nil and view.Touch and rowWidth <= clearStrip
	local floorY = if fitsBetweenControls
		then view.Height - margin
		else view.Height - LayoutMath.TouchBand(view) - margin

	return math.round(floorY - (indexFromBottom + 1) * rowHeight - indexFromBottom * gap)
end

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

-- Height thresholds for touch devices, because WIDTH is a bad proxy for how big
-- a phone physically is.
--
-- Measured on the emulator: an iPhone-class device reports 801x334, which the
-- old width-only rule classified as a Tablet by a single point -- so the phone
-- reflows never fired on an actual phone. Width varies enormously with aspect
-- ratio and reported scaling; the SHORT edge is the stable signal. A phone in
-- landscape is 320-450 tall, a tablet 600-800.
LayoutMath.PhoneMaxHeight = 500
LayoutMath.TabletMaxHeight = 800

function LayoutMath.Tier(view: View): Tier
	-- On touch, classify by the short edge. On a mouse device fall back to width,
	-- where a small window is a small window rather than a small device.
	if view.Touch then
		if view.Height <= LayoutMath.PhoneMaxHeight then
			return "Phone"
		elseif view.Height <= LayoutMath.TabletMaxHeight then
			return "Tablet"
		end
		return "Desktop"
	end

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

-- Share of the screen height the control band may claim, whatever the flat
-- figure above says.
--
-- A flat figure is nonsense on a short screen: the emulator reports 334pt of
-- height, where the original 190 was 57% of the display -- so "keep chrome out
-- of the control band" banned more than half the screen and FitHeight had almost
-- nothing to work with. 0.28 of 334 is 94, which matches the measured jump
-- button (top edge 90pt above the bottom) closely.
-- How far up from the bottom the controls reach, in the CORNERS only.
function LayoutMath.TouchBand(view: View): number
	if not view.Touch then
		return 0
	end
	local size = jumpButtonSize(view)
	if size == LayoutMath.JumpButtonSmall then
		return size + 20
	end
	return math.round(size * 1.75)
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
	local corner = LayoutMath.CornerWidth(view)
	local left = corner
	local right = view.Width - corner
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
