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

-- Cycled rather than dragged: Widgets has no slider component, and a tap
-- target that cycles 100 -> 75 -> 50 -> 25 -> Muted needs nothing new to
-- build while still giving real control. Session-only, same as
-- WindEffectEnabled above -- not saved to the profile.
local VOLUME_LEVELS = { 1, 0.75, 0.5, 0.25, 0 }

local function nextVolumeLevel(current: number): number
	for i, level in VOLUME_LEVELS do
		if math.abs(level - current) < 0.01 then
			return VOLUME_LEVELS[(i % #VOLUME_LEVELS) + 1]
		end
	end
	return VOLUME_LEVELS[1]
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
local function buildVolumeRow(panel: CanvasGroup, labelText: string, yOffset: number, groupName: string)
	local rowLabel = Widgets.Label(labelText, UDim2.new(1, -150, 0, 36), UDim2.fromOffset(8, yOffset), {
		TextSize = 16,
		Color = Theme.Color.TextSecondary,
	})
	rowLabel.Parent = panel

	local level = 1
	-- Explicit TextSize -- see windButton's comment: at this button's small
	-- footprint, even defaultTextSize's own >=18 auto threshold still read
	-- soft, and 24px was still visibly soft specifically for "MUTED"/"100%"
	-- (denser multi-character strings need more headroom than "ON"/"OFF" do
	-- at the same size -- see GachaController's Pull/Lucky comment for the
	-- same pattern at a bigger scale). 28px + a 110px-wide button (up from
	-- 90) is the confirmed-crisp combo from testing, and still comfortably
	-- fits "MUTED", the longest string here.
	local volumeButton = Widgets.Button(formatVolume(level), UDim2.fromOffset(110, 36), UDim2.new(1, -120, 0, yOffset), {
		Variant = "Tab",
		Active = true,
		TextSize = 28,
	})
	volumeButton.Parent = panel

	volumeButton.MouseButton1Click:Connect(function()
		level = nextVolumeLevel(level)
		volumeButton.Text = formatVolume(level)
		local group = SoundService:WaitForChild(groupName) :: SoundGroup
		group.Volume = level
	end)
end

-- Only ever shows the ON/OFF toggle, and only once the gamepass is actually
-- owned -- unlocking it happens in the Gacha panel instead (right next to
-- the feature it affects), not here. If it's not owned yet, this row simply
-- doesn't exist rather than showing a disabled/purchasable placeholder.
local function buildSkipGachaRow(panel: CanvasGroup, yOffset: number)
	local rowLabel = Widgets.Label("Skip gacha pull animation", UDim2.new(1, -150, 0, 36), UDim2.fromOffset(8, yOffset), {
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
		rowLabel.Visible = skipGachaOwned
		actionSlot.Visible = skipGachaOwned

		for _, child in actionSlot:GetChildren() do
			child:Destroy()
		end
		if not skipGachaOwned then
			return
		end

		-- Explicit TextSize -- see windButton above.
		local toggleButton, setActive = Widgets.Button(if skipGachaEnabled then "ON" else "OFF", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), {
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
	-- 90) toggle/volume pills needed more room than 320 could fit without
	-- truncating "Wind effect while sprinting"/"Skip gacha pull animation".
	panel, openPanel, closePanel = Widgets.Modal("Settings", UDim2.fromOffset(360, 274), UDim2.new(0, 10, 1, -350), {
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

	buildVolumeRow(panel, "Music volume", 92, "Music")
	buildVolumeRow(panel, "SFX volume", 136, "SFX")
	buildSkipGachaRow(panel, 180)

	local howToPlayButton = Widgets.Button("How to Play", UDim2.new(1, -16, 0, 40), UDim2.fromOffset(8, 224), {
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
