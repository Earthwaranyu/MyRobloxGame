local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Signal = require(Shared.Signal)

local MenuIcons = require(script.Parent.Parent.MenuIcons)
local MobileMenu = require(script.Parent.Parent.MobileMenu)
local Responsive = require(script.Parent.Parent.Responsive)
local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local TutorialController = require(script.Parent.TutorialController)

-- Purely client-side preferences (nothing here needs the server). Other
-- controllers read SettingsController.WindEffectEnabled directly, or listen
-- to Changed for updates -- both are available immediately at require-time,
-- same pattern as MatchStateController/SprintController.
local SettingsController = {}

-- Reference geometry for the panel.
local PANEL_WIDTH = 360
local PANEL_HEIGHT = 328

-- Rows are STACKED, not placed at hand-written y offsets.
--
-- The hand-written offsets are what put the ON pill under the close ✕ and the
-- OFF pill on top of the How to Play button. Every row's y was a scaled Px()
-- offset while its height was a Tap() one, and those two do not move together:
-- on a phone Px(36) is 26 but Tap(36) is 44, so a row authored as 36 tall
-- rendered 44 tall while the next row's y had only advanced by 26. Three rows
-- deep that is an 18pt overlap, which is exactly what the screenshot showed.
--
-- So each row now reports the height it ACTUALLY occupies and the next one
-- starts below it. A row can be as tall as Tap() insists without ever reaching
-- into its neighbour.
local ROW_GAP = 8
-- Every interactive pill in this panel: the wind toggle, the skip-gacha
-- toggle/buy button. Tap()'d at use, so this is the reference height.
local TOGGLE_HEIGHT = 36
local TOGGLE_WIDTH = 110
-- Gap between a toggle's right edge and the panel's, and how much room the
-- label beside it has to give up.
local TOGGLE_INSET = 10

-- A row's builder returns this: how tall it is, and how to place it once the
-- cursor above it is known.
type Row = { Height: number, Place: (y: number) -> () }

SettingsController.WindEffectEnabled = true
SettingsController.Changed = Signal.new()

local player = Players.LocalPlayer

local panel: CanvasGroup
local openPanel: () -> ()
local closePanel: () -> ()

-- Skip-gacha-animation preference: unlike Wind/volume above, this one IS
-- server-persisted (see PlayerDataService.SkipGachaAnimationEnabled) and
-- gated by actually owning the gamepass -- GachaController just trusts
-- whatever the profile says rather than re-checking ownership itself.
local skipGachaOwned = false
local skipGachaEnabled = false
local refreshSkipGachaRow: () -> ()

local function setWindEffect(enabled: boolean, windSetActive: (boolean) -> ())
	SettingsController.WindEffectEnabled = enabled
	windSetActive(enabled)
	SettingsController.Changed:Fire("WindEffect", enabled)
end

-- No "%" suffix -- isolated via A/B testing that Gotham's "%" glyph
-- specifically renders soft/smeared at these button sizes (confirmed across
-- GothamBlack, GothamBold, AND regular Gotham, and independent of the
-- overall TextSize/button-width fixes applied elsewhere in this file, e.g.
-- "100%" stayed blurry while the bare "100" right next to it was crisp) --
-- a genuine Roblox font-rendering quirk with that one character, not
-- something fixable via size/weight/stroke. The row's own label ("Music
-- volume") already gives the number its meaning.
local function formatVolume(level: number): string
	if level <= 0 then
		return "MUTED"
	end
	return tostring(math.floor(level * 100 + 0.5))
end

-- groupName is the SoundGroup AudioService creates server-side ("Music" or
-- "SFX"); setting its Volume locally only changes what THIS client hears,
-- same as any other client-side property override of a replicated instance.
-- Draggable Widgets.Slider (reference: a mobile OS volume-mixer slider) with
-- a live percentage readout next to the row label, replacing the old
-- click-to-cycle button now that Widgets actually has a slider component.
-- Returns a handle so the "Mute all sounds" button below can drive this row
-- (and its slider thumb, and the SoundGroup) rather than silently desyncing
-- from it -- a mute that leaves the slider sitting at 100 is worse than no
-- mute at all. onUserDrag fires only for an actual drag, never for a
-- programmatic SetVolume, so restoring levels on unmute can't recursively
-- re-trigger the mute bookkeeping.
type VolumeRow = {
	GetVolume: () -> number,
	SetVolume: (value: number) -> (),
}

local function buildVolumeRow(
	panel: CanvasGroup,
	labelText: string,
	groupName: string,
	onUserDrag: (() -> ())?
): (VolumeRow, Row)
	local px, tx = Responsive.Px, Responsive.Text

	local labelHeight = px(20)
	-- Tap(), not Px(): the slider's container IS its drag target, and a 20pt
	-- strip is not one on a phone. Widgets.Slider centres the visible track in
	-- whatever height it is given, so a taller container is a bigger grab area
	-- and an identical look.
	local trackHeight = Responsive.Tap(28)

	local rowLabel = Widgets.Label(labelText, UDim2.new(1, -px(88), 0, labelHeight), UDim2.fromOffset(px(8), 0), {
		TextSize = tx(16),
		Color = Theme.Color.TextSecondary,
	})
	rowLabel.Parent = panel

	-- 70px, not 50: "MUTED" is the widest string formatVolume can return and
	-- was rendering as "MUT..." at 50. Barely reachable before (you had to drag
	-- a slider all the way down); the mute button below makes it a one-tap,
	-- everyday state, so it has to actually fit.
	local valueLabel =
		Widgets.Label(formatVolume(1), UDim2.fromOffset(px(70), labelHeight), UDim2.new(1, -px(78), 0, 0), {
			TextSize = tx(16),
			Align = Enum.TextXAlignment.Right,
			Color = Theme.Color.TextSecondary,
		})
	valueLabel.Parent = panel

	local current = 1

	local function applyVolume(value: number)
		current = value
		valueLabel.Text = formatVolume(value)
		local group = SoundService:WaitForChild(groupName) :: SoundGroup
		group.Volume = value
	end

	local slider, setSliderValue = Widgets.Slider(
		UDim2.new(1, -px(16), 0, trackHeight),
		UDim2.fromOffset(px(8), 0),
		1,
		function(value)
			applyVolume(value)
			if onUserDrag then
				onUserDrag()
			end
		end
	)
	slider.Parent = panel

	local row: Row = {
		Height = labelHeight + trackHeight,
		Place = function(y: number)
			rowLabel.Position = UDim2.fromOffset(px(8), y)
			valueLabel.Position = UDim2.new(1, -px(78), 0, y)
			slider.Position = UDim2.fromOffset(px(8), y + labelHeight)
		end,
	}

	return {
		GetVolume = function()
			return current
		end,
		SetVolume = function(value: number)
			setSliderValue(value)
			applyVolume(value)
		end,
	},
		row
end

-- Always visible, owned or not -- unlike the old behavior (row didn't exist
-- at all until owned), an unowned player now sees it permanently OFF, and
-- tapping it prompts the same purchase flow the Gacha panel's buy row uses
-- (see GachaController.refreshSkipPurchaseRow) instead of only being
-- discoverable there.
local function buildSkipGachaRow(panel: CanvasGroup): Row
	local height = Responsive.Tap(TOGGLE_HEIGHT)
	local toggleWidth = Responsive.Px(TOGGLE_WIDTH)
	local slotRight = toggleWidth + Responsive.Px(TOGGLE_INSET)

	local rowLabel = Widgets.Label(
		"Skip gacha pull animation",
		UDim2.new(1, -(slotRight + Responsive.Px(16)), 0, height),
		UDim2.fromOffset(Responsive.Px(8), 0),
		{
			TextSize = Responsive.Text(16),
			Color = Theme.Color.TextSecondary,
		}
	)
	rowLabel.Parent = panel

	local actionSlot = Instance.new("Frame")
	actionSlot.Name = "SkipGachaActionSlot"
	actionSlot.Size = UDim2.fromOffset(toggleWidth, height)
	actionSlot.Position = UDim2.new(1, -slotRight, 0, 0)
	actionSlot.BackgroundTransparency = 1
	actionSlot.Parent = panel

	refreshSkipGachaRow = function()
		for _, child in actionSlot:GetChildren() do
			child:Destroy()
		end

		if not skipGachaOwned then
			-- Permanently-OFF-looking button (Active=false gives it the same
			-- muted "off" tab styling the real toggle uses) that prompts the
			-- gamepass purchase instead of toggling anything -- there's
			-- nothing to toggle until it's owned.
			local buyButton, setActive = Widgets.Button("OFF", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), {
				Variant = "Tab",
				Active = false,
				TextSize = 28,
			})
			buyButton.Parent = actionSlot
			setActive(false)
			buyButton.MouseButton1Click:Connect(function()
				Net.GetRemoteEvent(RemoteNames.PromptSkipGachaAnimationPurchase):FireServer()
			end)
			return
		end

		-- Explicit TextSize -- see windButton above.
		local toggleButton, setActive =
			Widgets.Button(if skipGachaEnabled then "ON" else "OFF", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), {
				Variant = "Tab",
				Active = skipGachaEnabled,
				TextSize = 28,
			})
		toggleButton.Parent = actionSlot
		setActive(skipGachaEnabled)

		toggleButton.MouseButton1Click:Connect(function()
			local requested = not skipGachaEnabled
			local actual = Net.GetRemoteFunction(RemoteNames.SetSkipGachaAnimation):InvokeServer(requested)
			skipGachaEnabled = actual
			toggleButton.Text = if actual then "ON" else "OFF"
			setActive(actual)
		end)
	end

	return {
		Height = height,
		Place = function(y: number)
			rowLabel.Position = UDim2.fromOffset(Responsive.Px(8), y)
			actionSlot.Position = UDim2.new(1, -slotRight, 0, y)
		end,
	}
end

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "SettingsGui"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	-- See LeaderboardController for why this is taller than it looks like it
	-- needs to be.
	local toggleButton = Widgets.Button("Settings", UDim2.fromOffset(150, 48), UDim2.new(0, 10, 1, -68), {
		Icon = function(holder, color)
			MenuIcons.Populate(holder, "Settings", color)
		end,
	})
	toggleButton.Parent = screenGui
	-- Bottom-left is where Roblox draws the movement thumbstick, so on a phone
	-- this button was unpressable. See MobileMenu -- no-op on desktop.
	MobileMenu.Adopt(toggleButton, 1)

	-- Own ScreenGui + backdrop + close-X (see Widgets.Modal) rather than a
	-- bare Widgets.Panel only closable via this one toggle button.
	-- Widened from 320 -- the row labels plus the now-bigger (110px, up from
	-- 90) toggle pills needed more room than 320 could fit without truncating
	-- "Wind effect while sprinting"/"Skip gacha pull animation". Taller than
	-- before too (274 -> 320) -- the volume rows grew from one line to two
	-- (label+value, then the slider below it) to fit Widgets.Slider. Grew
	-- again (320 -> 372) for a "Mute all sounds" row, then back down (372 ->
	-- 328) when that row moved out to its own one-tap HUD button above the
	-- Settings toggle -- muting is something you want mid-race, not four
	-- clicks deep. The Y offset moves with every height change so the panel's
	-- BOTTOM edge stays put just above the toggle button.
	panel, openPanel, closePanel =
		Widgets.Modal("Settings", UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT), UDim2.new(0, 10, 1, -404), {
			DisplayOrder = 30,
		})

	-- Drilling into this panel from the drawer should come back to the drawer.
	MobileMenu.ReopenWhenClosed(toggleButton, panel)

	-- That "bottom edge stays put just above the toggle button" placement is a
	-- desktop assumption: it resolves to y = -29 on a 375pt phone, clipping the
	-- panel's top -- and once the toggle moves into the drawer there is no
	-- button down there to sit above anyway. Clamped to the viewport instead,
	-- and centred rather than pinned to the bottom-left once it no longer has a
	-- toggle to hang off.
	local function layoutPanel()
		local viewport = Responsive.ViewportSize()
		local width, height = Responsive.PlacePanel(panel, PANEL_WIDTH, PANEL_HEIGHT, 0, 0)
		local x = if MobileMenu.IsAdopted(toggleButton) then math.round((viewport.X - width) / 2) else Responsive.Px(10)
		panel.Position = UDim2.fromOffset(
			Responsive.ClampX(x, width),
			Responsive.ClampY(math.round((viewport.Y - height) / 2), height)
		)
	end
	Responsive.Observe(layoutPanel)

	local ribbon = Widgets.Ribbon(
		"SETTINGS",
		UDim2.fromOffset(Responsive.Px(200), Responsive.Px(40)),
		UDim2.new(0.5, 0, 0, -Responsive.Px(20))
	)
	ribbon.Parent = panel

	local windHeight = Responsive.Tap(TOGGLE_HEIGHT)
	local windToggleWidth = Responsive.Px(TOGGLE_WIDTH)
	local windSlotRight = windToggleWidth + Responsive.Px(TOGGLE_INSET)

	local rowLabel = Widgets.Label(
		"Wind effect while sprinting",
		UDim2.new(1, -(windSlotRight + Responsive.Px(16)), 0, windHeight),
		UDim2.fromOffset(Responsive.Px(8), 0),
		{
			TextSize = Responsive.Text(16),
			Color = Theme.Color.TextSecondary,
		}
	)
	rowLabel.Parent = panel

	-- Explicit TextSize + widened button (see buildVolumeRow's comment below
	-- for the full story) -- matches the volume/skip-gacha toggles' sizing so
	-- all the small pill buttons in this panel look consistent.
	local windButton, windSetActive =
		Widgets.Button("ON", UDim2.fromOffset(windToggleWidth, windHeight), UDim2.new(1, -windSlotRight, 0, 0), {
			Variant = "Tab",
			Active = true,
			TextSize = 28,
		})
	windButton.Parent = panel
	windSetActive(true)

	local windRow: Row = {
		Height = windHeight,
		Place = function(y: number)
			rowLabel.Position = UDim2.fromOffset(Responsive.Px(8), y)
			Widgets.Relayout(
				windButton,
				UDim2.fromOffset(windToggleWidth, windHeight),
				UDim2.new(1, -windSlotRight, 0, y)
			)
		end,
	}

	windButton.MouseButton1Click:Connect(function()
		local enabled = not SettingsController.WindEffectEnabled
		windButton.Text = if enabled then "ON" else "OFF"
		setWindEffect(enabled, windSetActive)
	end)

	-- One switch for "silence the game" -- the two sliders together are the
	-- fine-grained control, this is the one you actually reach for. Remembers
	-- the levels it muted so unmuting restores exactly what you had, rather
	-- than dumping both categories back to 100.
	local muted = false
	local premuteMusic, premuteSfx = 1, 1
	local muteButton: TextButton
	local muteSetActive: (boolean) -> ()
	local musicRow: VolumeRow
	local sfxRow: VolumeRow

	local function refreshMuteButton()
		muteButton.Text = if muted then "MUTED" else "SOUND"
		-- The glyph is redrawn (not tinted) on every colour change, so the
		-- struck-through speaker has to be re-supplied here rather than set
		-- once at build time -- see Widgets.SetButtonColors.
		muteSetActive(muted)
		local iconHolder = muteButton:FindFirstChild("Icon")
		if iconHolder then
			MenuIcons.Populate(iconHolder, if muted then "SoundOff" else "Sound", muteButton.TextColor3)
		end
	end

	-- One tap, always reachable, directly above Settings. Muting used to be a
	-- row inside the Settings modal, which meant opening a panel mid-race just
	-- to silence the game -- the one moment you are least able to go looking
	-- for it. The volume sliders stay in the panel; this is only the on/off.
	muteButton, muteSetActive = Widgets.Button("SOUND", UDim2.fromOffset(150, 48), UDim2.new(0, 10, 1, -124), {
		Variant = "Tab",
		Active = false,
		TextSize = 18,
		Icon = function(holder, color)
			MenuIcons.Populate(holder, "Sound", color)
		end,
	})
	muteButton.Parent = screenGui
	MobileMenu.Adopt(muteButton, 2, { KeepOpen = true })
	muteSetActive(false)

	-- Dragging either slider by hand is an explicit statement about what you
	-- want to hear, so it takes the button out of "muted" -- otherwise the
	-- button would still read ON over an audible game, and the next tap would
	-- restore stale levels on top of the ones just chosen.
	local function onVolumeDragged()
		if muted then
			muted = false
			refreshMuteButton()
		end
	end

	local musicLayout: Row
	local sfxLayout: Row
	musicRow, musicLayout = buildVolumeRow(panel, "Music volume", "Music", onVolumeDragged)
	sfxRow, sfxLayout = buildVolumeRow(panel, "SFX volume", "SFX", onVolumeDragged)

	muteButton.MouseButton1Click:Connect(function()
		muted = not muted
		if muted then
			premuteMusic = musicRow.GetVolume()
			premuteSfx = sfxRow.GetVolume()
			musicRow.SetVolume(0)
			sfxRow.SetVolume(0)
		else
			-- Muting from already-silent sliders would otherwise restore to 0
			-- and look like the button did nothing at all.
			musicRow.SetVolume(if premuteMusic > 0 then premuteMusic else 1)
			sfxRow.SetVolume(if premuteSfx > 0 then premuteSfx else 1)
		end
		refreshMuteButton()
	end)

	local skipGachaLayout = buildSkipGachaRow(panel)

	local howToPlayHeight = Responsive.Tap(40)
	local howToPlayButton = Widgets.Button(
		"How to Play",
		UDim2.new(1, -Responsive.Px(16), 0, howToPlayHeight),
		UDim2.fromOffset(Responsive.Px(8), 0),
		{
			Variant = "Secondary",
			TextSize = 16,
		}
	)
	howToPlayButton.Parent = panel
	howToPlayButton.MouseButton1Click:Connect(function()
		-- Settings gets out of the way first. This is a navigation step, not a
		-- setting: the tutorial is a full panel in its own right, and leaving
		-- Settings open behind it means its backdrop is still dimming the thing
		-- the player just asked to read, with two ✕s on screen and no clue which
		-- one goes back. Show() clears the mobile drawer for the same reason --
		-- see the note there.
		closePanel()
		TutorialController.Show()
	end)

	local howToPlayRow: Row = {
		Height = howToPlayHeight,
		Place = function(y: number)
			Widgets.Relayout(
				howToPlayButton,
				UDim2.new(1, -Responsive.Px(16), 0, howToPlayHeight),
				UDim2.fromOffset(Responsive.Px(8), y)
			)
		end,
	}

	-- The stacking pass. Every row starts below the one above it, so no amount
	-- of Tap() inflating a row's height can push it into its neighbour.
	--
	-- The whole stack also starts below the close ✕ rather than beside it. The
	-- ✕ is anchored inside the panel's top-right corner and the first row's ON
	-- toggle is anchored to the same corner, so on touch -- where Tap() makes
	-- the ✕ 44pt, not 34 -- they were drawn on top of each other. Widgets.
	-- ModalContentTop is the same "start below the chrome" figure every other
	-- modal in the game uses.
	--
	-- Then the content scrolls: at full touch sizing the rows come to roughly
	-- 280pt inside a panel that a 334pt phone clamps to 274, and a row that does
	-- not fit is simply not drawn rather than scrolled to.
	Widgets.MakePanelScrollable(panel, Responsive.Px(8))
	local rows: { Row } = { windRow, musicLayout, sfxLayout, skipGachaLayout, howToPlayRow }
	local cursor = 0
	for index, row in rows do
		row.Place(cursor)
		cursor += row.Height
		if index < #rows then
			cursor += Responsive.Px(ROW_GAP)
		end
	end

	toggleButton.MouseButton1Click:Connect(function()
		-- panel.Visible (not a separately-tracked bool) is the source of
		-- truth here -- it stays correct even when the panel was closed via
		-- the backdrop/✕ instead of this button (see Widgets.Modal).
		if panel.Visible then
			closePanel()
		else
			openPanel()
			-- Re-checked on every open, not just once at Init -- Monetization
			-- Service's own ownership check is itself asynchronous
			-- server-side, so if it hadn't resolved yet the very first time
			-- Init() asked, this row would otherwise stay hidden forever for
			-- someone who already owns the gamepass.
			local status = Net.GetRemoteFunction(RemoteNames.GetMonetizationStatus):InvokeServer()
			skipGachaOwned = (status and status.HasSkipGachaAnimation) or false
			refreshSkipGachaRow()
		end
	end)
end

function SettingsController.Init()
	buildUI()

	local status = Net.GetRemoteFunction(RemoteNames.GetMonetizationStatus):InvokeServer()
	skipGachaOwned = (status and status.HasSkipGachaAnimation) or false

	local profile = Net.GetRemoteFunction(RemoteNames.GetProfile):InvokeServer()
	skipGachaEnabled = (profile and profile.SkipGachaAnimationEnabled) or false

	refreshSkipGachaRow()

	-- NOT MarketplaceService.PromptGamePassPurchaseFinished directly -- that
	-- fires independently on the client and the server, with no guaranteed
	-- ordering against the server actually updating its own ownedCache (see
	-- MonetizationService's doc comment on statusChangedRemote). This remote
	-- only fires AFTER that cache write, so the re-query below can never read
	-- a stale "not owned" result.
	Net.GetRemoteEvent(RemoteNames.MonetizationStatusChanged).OnClientEvent:Connect(function()
		local newStatus = Net.GetRemoteFunction(RemoteNames.GetMonetizationStatus):InvokeServer()
		skipGachaOwned = (newStatus and newStatus.HasSkipGachaAnimation) or false

		-- Buying Skip Animation auto-enables it server-side (see
		-- MonetizationService) -- re-reading the profile here too, not just
		-- ownership, means the toggle shows ON immediately instead of only
		-- after Settings is closed and reopened.
		local newProfile = Net.GetRemoteFunction(RemoteNames.GetProfile):InvokeServer()
		skipGachaEnabled = (newProfile and newProfile.SkipGachaAnimationEnabled) or false

		refreshSkipGachaRow()
	end)
end

return SettingsController
