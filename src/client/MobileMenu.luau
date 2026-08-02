-- The overflow drawer for HUD buttons that have nowhere to live on a phone.
--
-- THE PROBLEM IT SOLVES: Roblox draws its own touch controls -- the movement
-- thumbstick bottom-left, the jump button bottom-right -- in CoreGui, ABOVE
-- every ScreenGui this game creates. A HUD button underneath one of them is not
-- just visually crowded, it is unpressable, and it steals touches the player
-- meant as "move" or "jump". Three lobby buttons sat squarely in those zones:
-- Settings and SOUND in the bottom-left, Invite Friends in the bottom-right.
--
-- They cannot simply move up. On a 375pt phone the band those controls occupy is
-- ~190pt tall, which leaves room for about four stacked items in the left rail
-- and three in the right -- and both rails are already full (stats pill,
-- leaderboard, inventory / shop, gacha). Three buttons, two slots.
--
-- So on touch they fold behind one button instead. This is the standard mobile
-- pattern for exactly this situation, and it is the only arrangement that still
-- has somewhere to put a fourth secondary button later.
--
-- HOW CONTROLLERS USE IT: build the button exactly as before, then call
-- MobileMenu.Adopt(button, order). On a touch device the button is reparented
-- into the drawer and laid out here; on anything else the call does nothing at
-- all and the button stays exactly where the controller put it. Desktop layout
-- is therefore byte-for-byte what it was.
local Players = game:GetService("Players")

local Responsive = require(script.Parent.Responsive)
local Theme = require(script.Parent.Theme)
local Widgets = require(script.Parent.Widgets)

local MobileMenu = {}

local player = Players.LocalPlayer

-- Reference geometry.
local TOGGLE_SIZE = 44
local TOGGLE_INSET = 10
local SHEET_WIDTH = 210
local SHEET_PAD = 10
local ITEM_HEIGHT = 44
local ITEM_GAP = 8
-- The sheet's own layer. Adopted buttons and their contents are lifted above it
-- -- see liftAbove.
local SHEET_ZINDEX = 2

local toggleButton: TextButton? = nil
local sheet: ScrollingFrame? = nil
local backdrop: TextButton? = nil
local open = false

-- The item whose tap dismissed the drawer, if that is why it is shut -- see
-- MobileMenu.ReopenWhenClosed. nil whenever nothing is pending.
local dismissedBy: TextButton? = nil

export type AdoptOpts = {
	-- Only fold this button away on a PHONE, not on every touch device.
	PhoneOnly: boolean?,
	-- Leave the drawer open when this button is tapped. For an item that acts IN
	-- PLACE rather than opening something -- see the click handler in Adopt.
	KeepOpen: boolean?,
}

type Entry = { Button: TextButton, Order: number, PhoneOnly: boolean, Home: Instance }
local entries: { Entry } = {}

local function layout()
	if not (toggleButton and sheet and backdrop) then
		return
	end

	local size = Responsive.Tap(TOGGLE_SIZE)
	local inset = Responsive.Px(TOGGLE_INSET)
	local viewport = Responsive.ViewportSize()

	-- Slot 0 of the right rail, with Shop and Gacha in slots 1 and 2 beneath it.
	-- Placed by the same RailY the rest of the rail uses rather than by its own
	-- guess: the first version pinned itself to the corner at a hand-picked
	-- inset and, once Tap() floored the rows to 44, it overlapped the Shop
	-- button underneath it on a real phone.
	local toggleX = viewport.X - size - inset
	Widgets.Relayout(toggleButton, UDim2.fromOffset(size, size), UDim2.fromOffset(toggleX, Responsive.RailY(0)))

	local pad = Responsive.Px(SHEET_PAD)
	local itemHeight = Responsive.Tap(ITEM_HEIGHT)
	local gap = Responsive.Px(ITEM_GAP)
	-- Wide enough for however many columns the rows demand (computed below), so
	-- the width has to allow for the worst case rather than a fixed single
	-- column.
	local width = math.min(Responsive.Px(SHEET_WIDTH) * 2 + Responsive.Px(SHEET_PAD), viewport.X - inset * 2)
	-- Clamped and scrolling: the drawer can hold more rows than a 334pt phone
	-- screen has room for, and an unclamped sheet would run its last items off
	-- the bottom -- the exact failure this module exists to prevent. The final
	-- height is set below, once membership is known.
	-- Starts at the very top of the rail, not below the toggle: the drawer needs
	-- every row it can get, and it is drawn above the rail anyway.
	local sheetY = Responsive.RailY(0)
	local available = viewport.Y - Responsive.TouchBand() - sheetY - Responsive.ScreenMargin

	table.sort(entries, function(a, b)
		return a.Order < b.Order
	end)

	-- Membership is decided HERE, on every layout, not once when Adopt was
	-- called. Adopt runs during controller init, where the viewport is often not
	-- known yet -- Tier() then falls back to the reference width and reports
	-- "Desktop", so the phone-only folding silently never happened on an actual
	-- phone. Measured: Inventory and Party were still sitting in the rails on a
	-- 801x334 device that had already been classified as a Phone.
	local isPhone = Responsive.Tier() == "Phone"

	-- How many rows fit, and therefore how many COLUMNS the drawer needs.
	--
	-- A single column of seven 44pt rows is 350pt, which does not fit a 334pt
	-- phone -- so the last three (Inventory, Party, Gacha) were only reachable by
	-- scrolling a small sheet, which is not discoverable: they read as missing.
	-- Columns are the fix; the phone screen is short but very wide.
	local visible = 0
	for _, entry in entries do
		if not entry.PhoneOnly or isPhone then
			visible += 1
		end
	end
	local rowsThatFit = math.max(1, math.floor((available - pad * 2 + gap) / (itemHeight + gap)))
	local columns = math.max(1, math.ceil(visible / rowsThatFit))
	local rows = math.ceil(visible / columns)
	local columnWidth = math.floor((width - pad * 2 - gap * (columns - 1)) / columns)

	local slot = 0
	for _, entry in entries do
		local inDrawer = not entry.PhoneOnly or isPhone
		if inDrawer then
			if entry.Button.Parent ~= sheet then
				entry.Button.Parent = sheet
			end
			local column = math.floor(slot / rows)
			local row = slot % rows
			Widgets.Relayout(
				entry.Button,
				UDim2.fromOffset(columnWidth, itemHeight),
				UDim2.fromOffset(pad + column * (columnWidth + gap), pad + row * (itemHeight + gap))
			)
			slot += 1
		elseif entry.Button.Parent ~= entry.Home then
			-- Released back to the HUD; whatever placed it there originally
			-- (Widgets.BindRail) repositions it on this same viewport change.
			entry.Button.Parent = entry.Home
		end
	end

	-- The sheet is only as tall as the rows actually in it.
	local shown = pad * 2 + rows * itemHeight + math.max(0, rows - 1) * gap
	local height = math.max(itemHeight, math.min(shown, available))
	sheet.Size = UDim2.fromOffset(width, height)

	-- Right edge stops before the toggle, which shares this row. The sheet moved
	-- up to rail slot 0 to gain the height its second column needs, and that put
	-- its top-right corner underneath the ☰ -- hiding whichever item landed
	-- there. Measured: the toggle at x 750..794 over a sheet ending at 793.
	local toggleLeft = viewport.X - Responsive.Tap(TOGGLE_SIZE) - inset
	local right = math.min(viewport.X - inset, toggleLeft - gap)
	sheet.Position = UDim2.fromOffset(Responsive.ClampX(right - width, width), Responsive.ClampY(sheetY, height))
end

-- Raises a button and EVERYTHING inside it above `floor`.
--
-- The subtree matters, not just the button. These ScreenGuis use
-- ZIndexBehavior.Global, where a child does not inherit its parent's ZIndex --
-- so lifting only the button left every label, icon and bevel strip at the
-- default 1, behind the sheet at 2. The drawer opened as a stack of blank
-- coloured pills with no text on any of them, which is exactly how it looked on
-- a real phone: the items were all there and all invisible.
local function liftAbove(instance: Instance, floor: number)
	if instance:IsA("GuiObject") then
		instance.ZIndex = floor + 1
	end
	for _, child in instance:GetDescendants() do
		if child:IsA("GuiObject") then
			child.ZIndex = floor + 2
		end
	end
end

local function setOpen(nowOpen: boolean)
	open = nowOpen
	if sheet then
		sheet.Visible = nowOpen
	end
	if backdrop then
		backdrop.Visible = nowOpen
	end
end

-- Forgets any pending "come back when that panel closes" arrangement.
--
-- Anything that dismisses the drawer for a reason OTHER than drilling into one
-- of its own items has to call this, or the drawer springs back at the worst
-- possible moment -- see ModalAutoCloseController, which force-closes every
-- panel the instant a queued race starts, precisely so the player can see the
-- race they are now in.
local function forgetPendingReopen()
	dismissedBy = nil
end

-- Built lazily on the first Adopt rather than in an Init, so this module has no
-- ordering requirement against the controllers that feed it -- Loader.LoadAll
-- makes no promise about which runs first.
local function ensureBuilt()
	if toggleButton then
		return
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "MobileMenuGui"
	screenGui.ResetOnSpawn = false
	-- Above the ordinary HUD, below the modals the drawer's own buttons open
	-- (Widgets.Modal uses 30), so opening Settings from here puts the panel on
	-- top of the drawer rather than behind it.
	screenGui.DisplayOrder = 25
	screenGui.Parent = player:WaitForChild("PlayerGui")

	-- Full-screen catcher so a tap anywhere else closes the drawer -- the same
	-- affordance Widgets.Modal gives its panels, and the thing whose absence
	-- makes a drawer feel stuck.
	backdrop = Instance.new("TextButton")
	local catcher = backdrop :: TextButton
	catcher.Name = "Backdrop"
	catcher.Size = UDim2.fromScale(1, 1)
	catcher.BackgroundColor3 = Color3.new(0, 0, 0)
	catcher.BackgroundTransparency = 0.5
	catcher.BorderSizePixel = 0
	catcher.Text = ""
	catcher.AutoButtonColor = false
	catcher.Visible = false
	catcher.ZIndex = 1
	catcher.Parent = screenGui
	catcher.MouseButton1Click:Connect(function()
		-- Tapping outside is "I am done with the menu", not "I am drilling into
		-- an item", so nothing should bring it back.
		forgetPendingReopen()
		setOpen(false)
	end)

	sheet = Instance.new("ScrollingFrame")
	local panel = sheet :: ScrollingFrame
	panel.CanvasSize = UDim2.new()
	panel.AutomaticCanvasSize = Enum.AutomaticSize.Y
	panel.ScrollBarThickness = 4
	panel.ScrollingDirection = Enum.ScrollingDirection.Y
	panel.Name = "Sheet"
	panel.BackgroundColor3 = Theme.Candy.PanelFace
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.ZIndex = SHEET_ZINDEX
	panel.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = Theme.Corner.Panel
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Candy.Border
	stroke.Thickness = 4
	stroke.Parent = panel

	toggleButton = Widgets.Button("", UDim2.fromOffset(TOGGLE_SIZE, TOGGLE_SIZE), UDim2.fromOffset(0, 0), {
		Variant = "Secondary",
	})
	local toggle = toggleButton :: TextButton
	toggle.Name = "MobileMenuToggle"
	toggle.ZIndex = SHEET_ZINDEX + 1
	toggle.Parent = screenGui

	-- The three bars are DRAWN, not typed.
	--
	-- This started as a "☰" (U+2630) and came back from a real device as a blank
	-- pill: TextBounds measured 11x22 for a 22pt glyph, i.e. the font substituted
	-- something narrow rather than rendering it. That is the same trap the modal
	-- close button already hit with "✕" -- Roblox's Gotham family has no glyph for
	-- it -- which is why that button draws its X from two rotated Frames. Every
	-- other icon in this game is drawn from primitives for exactly this reason
	-- (see MenuIcons), so a Unicode glyph was the odd one out here.
	local BAR_WIDTH_SHARE = 0.44
	local BAR_THICKNESS_SHARE = 0.075
	local BAR_GAP_SHARE = 0.16
	for index = -1, 1 do
		local bar = Instance.new("Frame")
		bar.Name = ("Bar%d"):format(index + 2)
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Position = UDim2.fromScale(0.5, 0.5 + index * BAR_GAP_SHARE)
		bar.Size = UDim2.fromScale(BAR_WIDTH_SHARE, BAR_THICKNESS_SHARE)
		bar.BackgroundColor3 = toggle.TextColor3
		bar.BorderSizePixel = 0
		bar.ZIndex = toggle.ZIndex + 1
		local barCorner = Instance.new("UICorner")
		barCorner.CornerRadius = UDim.new(1, 0)
		barCorner.Parent = bar
		bar.Parent = toggle
	end
	toggle.MouseButton1Click:Connect(function()
		forgetPendingReopen()
		setOpen(not open)
	end)

	Responsive.Observe(layout)
end

-- Moves `button` into the drawer on touch devices; a no-op everywhere else.
--
-- `order` decides the position in the drawer, so the ordering is decided by the
-- callers collectively rather than by whichever controller happens to load
-- first -- Loader.LoadAll gives no ordering guarantee, and a drawer whose
-- contents shuffle between sessions is its own small bug.
function MobileMenu.Adopt(button: TextButton, order: number, opts: AdoptOpts?)
	if not Responsive.IsTouch() then
		return
	end

	opts = opts or {}

	-- `PhoneOnly` is recorded, not acted on: the tier is unreliable this early
	-- (see layout, which re-decides every time the viewport changes).

	ensureBuilt()
	table.insert(entries, {
		Button = button,
		Order = order,
		PhoneOnly = (opts :: AdoptOpts).PhoneOnly == true,
		Home = button.Parent :: Instance,
	})
	liftAbove(button, SHEET_ZINDEX)

	-- Tapping an item does what the item does AND dismisses the drawer, which is
	-- what a drawer is expected to do. Connected here rather than asked of every
	-- caller, since a caller that forgot would leave the sheet covering the very
	-- panel it just opened.
	--
	-- KeepOpen is the exception, and it exists because that reasoning only holds
	-- for an item that OPENS something. SOUND mutes in place: the whole result of
	-- the tap is the button relabelling itself MUTED, which the player never got
	-- to see because the drawer it lives in vanished at the same moment -- and
	-- unmuting then meant reopening the drawer to press the same button again.
	-- Every other adopted item (Settings, Inventory, Party, Gacha, My Profile,
	-- Invite Friends) puts a panel or a native dialog on screen, so dismissing
	-- the drawer for those is still right.
	if not (opts :: AdoptOpts).KeepOpen then
		button.MouseButton1Click:Connect(function()
			-- Recorded here, where whether the drawer was actually OPEN is still
			-- known, rather than in ReopenWhenClosed. A PhoneOnly item is released
			-- back to the HUD rail on a tablet (see layout), where it is tapped
			-- with no drawer involved at all -- and a reopen armed by that tap
			-- would summon a menu the player never opened.
			dismissedBy = if open then button else nil
			setOpen(false)
		end)
	end

	layout()
end

-- Whether a given button ended up in the drawer. Lets a controller drop
-- decoration that only made sense beside the button in its old position.
function MobileMenu.IsAdopted(button: TextButton): boolean
	for _, entry in entries do
		if entry.Button == button then
			return true
		end
	end
	return false
end

-- Makes the drawer come back once `panel` is dismissed.
--
-- Without this the drawer was a one-way door: tapping Gacha closed the menu and
-- opened the panel, and closing the panel dropped you all the way out to the
-- bare HUD -- so browsing two of the drawer's items meant reopening the drawer
-- in between. That is not how a menu behaves anywhere else; drilling in and
-- coming back should land you where you drilled in FROM.
--
-- Separate from Adopt rather than an AdoptOpts field because of construction
-- order: most controllers adopt their toggle button before they build the panel
-- it opens (SettingsController and InventoryController both do), so the panel
-- does not exist yet at Adopt time. Calling this is optional -- Invite Friends
-- opens a native Roblox prompt with no panel to watch, and SOUND never closes
-- the drawer in the first place.
function MobileMenu.ReopenWhenClosed(button: TextButton, panel: GuiObject)
	if not Responsive.IsTouch() then
		return
	end

	-- Gated on WHICH item dismissed the drawer, not merely on this panel closing:
	-- the same panel can be opened by routes that have nothing to do with the
	-- drawer (the profile card opens on a double-click out in the world), and
	-- those must not summon a menu the player never asked for.
	panel:GetPropertyChangedSignal("Visible"):Connect(function()
		if panel.Visible or dismissedBy ~= button then
			return
		end
		dismissedBy = nil
		setOpen(true)
	end)
end

function MobileMenu.Close()
	forgetPendingReopen()
	setOpen(false)
end

return MobileMenu
