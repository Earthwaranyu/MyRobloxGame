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

local toggleButton: TextButton? = nil
local sheet: Frame? = nil
local backdrop: TextButton? = nil
local open = false

type Entry = { Button: TextButton, Order: number }
local entries: { Entry } = {}

local function layout()
	if not (toggleButton and sheet and backdrop) then
		return
	end

	local size = Responsive.Tap(TOGGLE_SIZE)
	local inset = Responsive.Px(TOGGLE_INSET)
	local viewport = Responsive.ViewportSize()

	-- Top-right corner, above the Shop/Gacha rail rather than below it: that
	-- corner is the only part of the screen with nothing in it at any viewport
	-- size, and being at the top keeps the drawer's whole run clear of the
	-- touch-control band no matter how many items it grows to.
	local toggleX = viewport.X - size - inset
	toggleButton.Size = UDim2.fromOffset(size, size)
	Widgets.Relayout(toggleButton, UDim2.fromOffset(size, size), UDim2.fromOffset(toggleX, inset))

	local pad = Responsive.Px(SHEET_PAD)
	local itemHeight = Responsive.Tap(ITEM_HEIGHT)
	local gap = Responsive.Px(ITEM_GAP)
	local width = math.min(Responsive.Px(SHEET_WIDTH), viewport.X - inset * 2)
	local count = #entries
	local height = pad * 2 + count * itemHeight + math.max(0, count - 1) * gap

	local sheetY = inset + size + gap
	sheet.Size = UDim2.fromOffset(width, height)
	sheet.Position =
		UDim2.fromOffset(Responsive.ClampX(viewport.X - width - inset, width), Responsive.ClampY(sheetY, height))

	table.sort(entries, function(a, b)
		return a.Order < b.Order
	end)
	for index, entry in entries do
		Widgets.Relayout(
			entry.Button,
			UDim2.fromOffset(width - pad * 2, itemHeight),
			UDim2.fromOffset(pad, pad + (index - 1) * (itemHeight + gap))
		)
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
		setOpen(false)
	end)

	sheet = Instance.new("Frame")
	local panel = sheet :: Frame
	panel.Name = "Sheet"
	panel.BackgroundColor3 = Theme.Candy.PanelFace
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.ZIndex = 2
	panel.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = Theme.Corner.Panel
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Candy.Border
	stroke.Thickness = 4
	stroke.Parent = panel

	toggleButton = Widgets.Button("☰", UDim2.fromOffset(TOGGLE_SIZE, TOGGLE_SIZE), UDim2.fromOffset(0, 0), {
		Variant = "Secondary",
		TextSize = 22,
	})
	local toggle = toggleButton :: TextButton
	toggle.Name = "MobileMenuToggle"
	toggle.ZIndex = 3
	toggle.Parent = screenGui
	toggle.MouseButton1Click:Connect(function()
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
function MobileMenu.Adopt(button: TextButton, order: number)
	if not Responsive.IsTouch() then
		return
	end

	ensureBuilt()
	table.insert(entries, { Button = button, Order = order })
	button.Parent = sheet
	button.ZIndex = 3

	-- Tapping an item does what the item does AND dismisses the drawer, which is
	-- what a drawer is expected to do. Connected here rather than asked of every
	-- caller, since a caller that forgot would leave the sheet covering the very
	-- panel it just opened.
	button.MouseButton1Click:Connect(function()
		setOpen(false)
	end)

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

function MobileMenu.Close()
	setOpen(false)
end

return MobileMenu
