local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Net)
local RemoteNames = require(Shared.RemoteNames)
local Signal = require(Shared.Signal)

local MenuIcons = require(script.Parent.Parent.MenuIcons)
local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local TutorialController = require(script.Parent.TutorialController)

-- Purely client-side preferences (nothing here needs the server). Other
-- controllers read SettingsController.WindEffectEnabled directly, or listen
-- to Changed for updates -- both are available immediately at require-time,
-- same pattern as MatchStateController/SprintController.
local SettingsController = {}

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
	yOffset: number,
	groupName: string,
	onUserDrag: (() -> ())?
): VolumeRow
	local rowLabel = Widgets.Label(labelText, UDim2.new(1, -88, 0, 20), UDim2.fromOffset(8, yOffset), {
		TextSize = 16,
		Color = Theme.Color.TextSecondary,
	})
	rowLabel.Parent = panel

	-- 70px, not 50: "MUTED" is the widest string formatVolume can return and
	-- was rendering as "MUT..." at 50. Barely reachable before (you had to drag
	-- a slider all the way down); the mute button below makes it a one-tap,
	-- everyday state, so it has to actually fit.
	local valueLabel = Widgets.Label(formatVolume(1), UDim2.fromOffset(70, 20), UDim2.new(1, -78, 0, yOffset), {
		TextSize = 16,
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
		UDim2.new(1, -16, 0, 28),
		UDim2.fromOffset(8, yOffset + 24),
		1,
		function(value)
			applyVolume(value)
			if onUserDrag then
				onUserDrag()
			end
		end
	)
	slider.Parent = panel

	return {
		GetVolume = function()
			return current
		end,
		SetVolume = function(value: number)
			setSliderValue(value)
			applyVolume(value)
		end,
	}
end

-- Always visible, owned or not -- unlike the old behavior (row didn't exist
-- at all until owned), an unowned player now sees it permanently OFF, and
-- tapping it prompts the same purchase flow the Gacha panel's buy row uses
-- (see GachaController.refreshSkipPurchaseRow) instead of only being
-- discoverable there.
local function buildSkipGachaRow(panel: CanvasGroup, yOffset: number)
	local rowLabel =
		Widgets.Label("Skip gacha pull animation", UDim2.new(1, -150, 0, 36), UDim2.fromOffset(8, yOffset), {
			TextSize = 16,
			Color = Theme.Color.TextSecondary,
		})
	rowLabel.Parent = panel

	local actionSlot = Instance.new("Frame")
	actionSlot.Name = "SkipGachaActionSlot"
	actionSlot.Size = UDim2.fromOffset(110, 36)
	actionSlot.Position = UDim2.new(1, -120, 0, yOffset)
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
	panel, openPanel, closePanel = Widgets.Modal("Settings", UDim2.fromOffset(360, 328), UDim2.new(0, 10, 1, -404), {
		DisplayOrder = 30,
	})

	local ribbon = Widgets.Ribbon("SETTINGS", UDim2.fromOffset(200, 40), UDim2.new(0.5, 0, 0, -20))
	ribbon.Parent = panel

	local rowLabel = Widgets.Label("Wind effect while sprinting", UDim2.new(1, -150, 0, 44), UDim2.fromOffset(8, 44), {
		TextSize = 16,
		Color = Theme.Color.TextSecondary,
	})
	rowLabel.Parent = panel

	-- Explicit TextSize + widened button (see buildVolumeRow's comment below
	-- for the full story) -- matches the volume/skip-gacha toggles' sizing so
	-- all the small pill buttons in this panel look consistent.
	local windButton, windSetActive = Widgets.Button("ON", UDim2.fromOffset(110, 36), UDim2.new(1, -120, 0, 44), {
		Variant = "Tab",
		Active = true,
		TextSize = 28,
	})
	windButton.Parent = panel
	windSetActive(true)

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

	musicRow = buildVolumeRow(panel, "Music volume", 96, "Music", onVolumeDragged)
	sfxRow = buildVolumeRow(panel, "SFX volume", 156, "SFX", onVolumeDragged)

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

	buildSkipGachaRow(panel, 216)

	local howToPlayButton = Widgets.Button("How to Play", UDim2.new(1, -16, 0, 40), UDim2.fromOffset(8, 260), {
		Variant = "Secondary",
		TextSize = 16,
	})
	howToPlayButton.Parent = panel
	howToPlayButton.MouseButton1Click:Connect(function()
		TutorialController.Show()
	end)

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
