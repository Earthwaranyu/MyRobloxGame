local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Abilities = require(Shared.Abilities)
local Net = require(Shared.Net)
local RarityColors = require(Shared.RarityColors)
local RemoteNames = require(Shared.RemoteNames)

local AbilityIcons = require(script.Parent.Parent.AbilityIcons)
local Theme = require(script.Parent.Parent.Theme)
local Widgets = require(script.Parent.Parent.Widgets)
local Sounds = require(script.Parent.Parent.Sounds)

-- "Gacha has insane beautiful animation" -- a single pull gets a CS:GO-style
-- spinning reel (same technique as MapRevealController, just landing on an
-- ability card instead of a stage); a 10-pull runs that exact same reel-spin
-- once per item, back to back (see startSequentialReveal) -- the full
-- ceremony every time, not a shortcut, unless the player owns the Skip
-- Animation gamepass AND has it toggled on in Settings -- unlocking it is
-- still done here (see refreshSkipPurchaseRow), close to the feature it
-- affects, but the ON/OFF preference itself lives in SettingsController
-- alongside every other simple toggle; this file only ever reads profile.
-- SkipGachaAnimationEnabled, it doesn't own that preference.
local GachaController = {}

local player = Players.LocalPlayer

local RARITY_COLOR = RarityColors

-- Ascending, so a 10-pull's reveal order (see startSequentialReveal) can
-- sort by this and save the best pull for last -- the "escalating anticipation"
-- beat that separates a premium gacha reveal from a flat one: a reel/flip
-- that reveals randomly (or worst-first) wastes the one moment the player
-- is most primed to feel something.
local RARITY_RANK = { Common = 1, Rare = 2, Epic = 3, Legendary = 4 }

-- How strong the landing flash (see flashRarity) is per rarity -- 0 means
-- "no flash", scaling up so a Legendary pull visibly hits harder than a
-- Common one instead of every pull getting identical treatment.
local RARITY_FLASH_STRENGTH = { Common = 0, Rare = 0.15, Epic = 0.35, Legendary = 0.55 }
-- Extra beat held on higher rarities so the reveal doesn't just blur past
-- them at the same pace as a Common -- the "sound/light lands, then a beat
-- before moving on" pacing the research called out.
local RARITY_HOLD_SECONDS = { Common = 0, Rare = 0.1, Epic = 0.35, Legendary = 0.7 }

local CARD_WIDTH = 150
local CARD_HEIGHT = 190
local CARD_GAP = 14
local STEP = CARD_WIDTH + CARD_GAP
local TOTAL_CARDS = 24
local WINNING_INDEX = 20
local WINDOW_WIDTH = 560
local SPIN_DURATION = 2.6

-- Main shop panel. Each panel here is its own Widgets.Modal (own ScreenGui +
-- backdrop + close-X), NOT a shared ScreenGui with manual ZIndex juggling --
-- see Widgets.Modal's doc comment for exactly why that broke (rendered as a
-- solid black box) the first time this used a shared "GachaGui" instead.
local panel: CanvasGroup
local openMainPanel: () -> ()
local closeMainPanel: () -> ()
local pointsLabel: TextLabel
local inventoryList: ScrollingFrame
local luckyButton: TextButton
-- Mirrors ShopController's vipOwned -- Active = false alone was assumed to
-- be enough to block the click, but the click handler below fired
-- unconditionally regardless of Active, so a stray/leftover click still
-- re-prompted the purchase every time even once owned. This is what actually
-- made VIP's identical-looking fix work while Lucky's didn't: VIP's handler
-- already had this same explicit ownership check, Lucky's never did.
local luckyOwned = false

-- Drop-rate disclosure (see buildOddsPanel) -- Roblox requires exact odds for
-- any paid randomized virtual item to be shown, as percentages summing to
-- 100%, BEFORE purchase. This is a policy requirement, not a nice-to-have.
local oddsPanel: CanvasGroup
local openOddsPanel: () -> ()

-- Reveal overlay (shared by both a single-pull spin and a 10-pull grid).
local revealPanel: CanvasGroup
local openRevealPanel: () -> ()
local closeRevealPanel: () -> ()
-- Off while a spin (or a 10-pull's sequential run of spins) is actually
-- playing -- see playReveal/showSummary. Without this, an impatient or
-- accidental tap anywhere on screen during the ~30s a 10-pull can take
-- dismissed the whole reveal with no way to see what was actually pulled
-- (the pull itself already happened server-side by the time the animation
-- starts, so nothing was lost mechanically, but the player had no way to
-- FIND OUT what they got short of manually checking the inventory list).
local setRevealClickOutsideEnabled: (boolean) -> ()
local reelWindow: Frame
local reel: Frame
-- Skip Animation's owner never sees the reel at all (see playReveal), which
-- used to mean they never saw WHAT they got either -- the reel's frozen
-- final card was the only place an icon ever showed, and that's exactly the
-- window skipping the animation deletes. This sits in the same space the
-- reel would have occupied and shows one icon per result instead, so
-- skipping the ceremony doesn't also mean losing the "what did I get" payoff.
local resultIconsRow: Frame
local progressLabel: TextLabel
local summaryLabel: TextLabel
local continueButton: TextButton
local flashOverlay: Frame

-- Read from the profile (see PlayerDataService.SkipGachaAnimationEnabled),
-- not tracked/toggled here at all -- SettingsController owns the toggle,
-- this only ever reads whatever the profile says at pull time.
local skipAnimationEnabled = false

-- Whether the gamepass itself is owned (separate from whether it's
-- currently toggled on) -- drives refreshSkipPurchaseRow, which shows the
-- "Unlock Skip" button here only while this is false.
local skipGachaOwned = false
local refreshSkipPurchaseRow: () -> ()

local pullRemote: RemoteFunction
local promptRobuxRemote: RemoteEvent

-- Every gacha-obtainable ability (Dash excluded -- see Abilities.luau),
-- reused both as filler cards in the single-pull reel and nowhere else.
local pool: { Abilities.AbilityInfo } = {}
for _, info in Abilities do
	if info.PullWeight then
		table.insert(pool, info)
	end
end

local function getAbilityById(id: string): Abilities.AbilityInfo?
	for _, info in Abilities do
		if info.Id == id then
			return info
		end
	end
	return nil
end

-- A rarer pull should visibly hit harder, not just show a different color
-- label -- this is the "escalating intensity" beat the reveal-pacing
-- research called out as what separates a premium gacha reveal from a flat
-- one. Common pulls get no flash at all (RARITY_FLASH_STRENGTH.Common == 0)
-- specifically so the contrast sells the rare ones instead of every pull
-- looking equally exciting.
local function flashRarity(rarity: string)
	local strength = RARITY_FLASH_STRENGTH[rarity] or 0
	if strength <= 0 then
		return
	end
	flashOverlay.BackgroundColor3 = RARITY_COLOR[rarity] or Color3.new(1, 1, 1)
	flashOverlay.BackgroundTransparency = 1 - strength
	TweenService:Create(flashOverlay, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
	}):Play()
end

local function buildReelCard(info: Abilities.AbilityInfo, layoutOrder: number): Frame
	local card = Instance.new("Frame")
	card.Size = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT)
	card.Position = UDim2.fromOffset((layoutOrder - 1) * STEP, 0)
	card.BackgroundColor3 = Theme.Color.PanelLight
	card.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = card

	local stroke = Instance.new("UIStroke")
	stroke.Color = RARITY_COLOR[info.Rarity] or Theme.Color.Stroke
	stroke.Thickness = 3
	stroke.Transparency = 0.1
	stroke.Parent = card

	-- Fills the empty space above the name/rarity text -- the card used to
	-- be pure text-on-color, which read fine for rarity but told you nothing
	-- about what the ability actually DOES at a glance (a real player
	-- complaint: "Idk what does sky hop really do"). Icon color matches the
	-- card's own rarity tint rather than a fixed white/black.
	local icon = AbilityIcons.Create(info.Id, 68, UDim2.fromOffset((CARD_WIDTH - 68) / 2, 16), RARITY_COLOR[info.Rarity] or Theme.Color.TextSecondary)
	icon.Parent = card

	local nameLabel = Widgets.Label(info.Name, UDim2.new(1, -12, 0, 60), UDim2.fromOffset(6, 96), {
		TextSize = 18,
		Align = Enum.TextXAlignment.Center,
	})
	nameLabel.TextWrapped = true
	nameLabel.Parent = card

	local rarityLabel = Widgets.Label(info.Rarity:upper(), UDim2.new(1, -12, 0, 18), UDim2.fromOffset(6, 156), {
		TextSize = 13,
		Align = Enum.TextXAlignment.Center,
		Color = RARITY_COLOR[info.Rarity] or Theme.Color.TextSecondary,
	})
	rarityLabel.Parent = card

	return card
end

local function startReelSpin(resultInfo: Abilities.AbilityInfo, onDone: () -> ())
	for _, child in reel:GetChildren() do
		child:Destroy()
	end

	for i = 1, TOTAL_CARDS do
		local info = if i == WINNING_INDEX then resultInfo else pool[math.random(1, #pool)]
		buildReelCard(info, i).Parent = reel
	end

	local targetX = WINDOW_WIDTH / 2 - ((WINNING_INDEX - 1) * STEP + CARD_WIDTH / 2)
	reel.Position = UDim2.fromOffset(0, 0)

	task.spawn(function()
		local elapsed = 0
		while elapsed < SPIN_DURATION do
			local t = elapsed / SPIN_DURATION
			local interval = 0.05 + 0.35 * t * t
			Sounds.Play("Tick")
			task.wait(interval)
			elapsed += interval
		end
	end)

	TweenService:Create(reel, TweenInfo.new(SPIN_DURATION, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
		Position = UDim2.fromOffset(targetX, 0),
	}):Play()

	-- Guaranteed settle regardless of whether the tween itself reports
	-- completion (see Widgets.Open/Close for the same "under heavy frame
	-- scheduling load a Tween can get stuck" concern).
	task.delay(SPIN_DURATION, function()
		reel.Position = UDim2.fromOffset(targetX, 0)
		Sounds.Play("Reveal")
		flashRarity(resultInfo.Rarity)
	end)

	-- Higher rarities hold on the result a beat longer before the summary
	-- appears (see RARITY_HOLD_SECONDS) instead of every pull moving on at
	-- the same pace.
	task.delay(SPIN_DURATION + 0.8 + (RARITY_HOLD_SECONDS[resultInfo.Rarity] or 0), onDone)
end

-- A 10-pull runs the exact same reel-spin as a single pull, once per item,
-- back to back -- players without Skip Animation always get the full
-- ceremony for every pull, not a quick grid-flip shortcut, which is also
-- exactly what makes the Skip Animation gamepass a real time-saver rather
-- than a cosmetic-only purchase. Sorted ascending by rarity so the best pull
-- of the batch is always the LAST spin, same "save the best for last"
-- reasoning as a single reel landing -- just stretched across all 10.
local function startSequentialReveal(results, onDone: () -> ())
	local sortedResults = table.clone(results)
	table.sort(sortedResults, function(a, b)
		return (RARITY_RANK[a.Rarity] or 0) < (RARITY_RANK[b.Rarity] or 0)
	end)

	local total = #sortedResults
	local function playNext(index: number)
		if index > total then
			progressLabel.Visible = false
			onDone()
			return
		end

		progressLabel.Text = ("PULL %d OF %d"):format(index, total)
		progressLabel.Visible = true

		local result = sortedResults[index]
		local info = getAbilityById(result.Id) or pool[1]
		startReelSpin(info, function()
			playNext(index + 1)
		end)
	end

	playNext(1)
end

-- One rarity-tinted icon per result, laid out left to right in pull order --
-- only ever shown for a Skip Animation reveal (see playReveal); the normal
-- reel already leaves its final card's icon on screen through showSummary.
local function populateResultIcons(results)
	for _, child in resultIconsRow:GetChildren() do
		if child.Name == "AbilityIcon" then
			child:Destroy()
		end
	end

	for i, r in results do
		local info = getAbilityById(r.Id) or pool[1]
		local icon = AbilityIcons.Create(info.Id, 44, UDim2.fromOffset(0, 0), RARITY_COLOR[info.Rarity] or Theme.Color.TextSecondary)
		icon.LayoutOrder = i
		icon.Parent = resultIconsRow
	end
end

local function showSummary(results)
	local newNames = {}
	local dupeCount = 0
	local dupeRefund = 0
	for _, r in results do
		if r.IsNew then
			local info = getAbilityById(r.Id)
			table.insert(newNames, (info and info.Name) or r.Id)
		else
			dupeCount += 1
			dupeRefund += r.RefundPoints
		end
	end

	local lines = {}
	if #newNames > 0 then
		table.insert(lines, "New: " .. table.concat(newNames, ", "))
	end
	if dupeCount > 0 then
		table.insert(lines, ("%d duplicate(s) refunded %d points"):format(dupeCount, dupeRefund))
	end
	if #lines == 0 then
		lines = { "Nothing new this time." }
	end

	summaryLabel.Text = table.concat(lines, "\n")
	summaryLabel.Visible = true
	continueButton.Visible = true
	-- The result is on screen and staying there now -- clicking outside is
	-- safe again (equivalent to just clicking Continue).
	setRevealClickOutsideEnabled(true)
end

local function playReveal(results)
	summaryLabel.Visible = false
	continueButton.Visible = false
	progressLabel.Visible = false
	resultIconsRow.Visible = false
	openRevealPanel()

	if skipAnimationEnabled then
		reelWindow.Visible = false
		populateResultIcons(results)
		resultIconsRow.Visible = true
		showSummary(results)
		return
	end

	-- Locked for the duration of the actual spin(s) -- see
	-- setRevealClickOutsideEnabled's declaration for why. showSummary turns
	-- it back on once there's an actual result on screen to look at.
	setRevealClickOutsideEnabled(false)

	reelWindow.Visible = true
	if #results == 1 then
		local info = getAbilityById(results[1].Id) or pool[1]
		startReelSpin(info, function()
			showSummary(results)
		end)
	else
		startSequentialReveal(results, function()
			showSummary(results)
		end)
	end
end

local function buildInventoryRow(info: Abilities.AbilityInfo, profile): Frame
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 58)
	row.BackgroundColor3 = Theme.Color.PanelLight
	row.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = row

	local swatch = Instance.new("Frame")
	swatch.Size = UDim2.new(0, 6, 1, -12)
	swatch.Position = UDim2.fromOffset(6, 6)
	swatch.BackgroundColor3 = RARITY_COLOR[info.Rarity] or Theme.Color.TextMuted
	swatch.BorderSizePixel = 0
	local swatchCorner = Instance.new("UICorner")
	swatchCorner.CornerRadius = UDim.new(1, 0)
	swatchCorner.Parent = swatch
	swatch.Parent = row

	local owned = table.find(profile.OwnedAbilities, info.Id) ~= nil
	local equipped = profile.EquippedAbility == info.Id

	-- Sits in the gap between the rarity swatch and the name text -- same
	-- rationale as the reel card's icon (see buildReelCard), just at
	-- inventory-row scale.
	local icon = AbilityIcons.Create(info.Id, 40, UDim2.fromOffset(16, 9), RARITY_COLOR[info.Rarity] or Theme.Color.TextMuted)
	icon.Parent = row

	local nameLabel = Widgets.Label(info.Name, UDim2.new(0.55, -62, 0, 22), UDim2.fromOffset(64, 6), {
		TextSize = 16,
	})
	nameLabel.Parent = row

	local subText
	if equipped then
		subText = "Equipped"
	elseif owned then
		subText = "Owned"
	elseif info.PullWeight then
		subText = ("%s  ·  %d%% pull odds"):format(info.Rarity, info.PullWeight)
	else
		subText = info.Rarity
	end

	local subLabel = Widgets.Label(subText, UDim2.new(0.55, -62, 0, 18), UDim2.fromOffset(64, 30), {
		TextSize = 13,
		Bold = false,
		Color = if equipped
			then Theme.Color.Success
			elseif owned then Theme.Color.TextSecondary
			else RARITY_COLOR[info.Rarity] or Theme.Color.TextMuted,
	})
	subLabel.Parent = row

	if owned then
		local actionButton = Widgets.Button(if equipped then "Equipped" else "Equip", UDim2.fromScale(0.32, 0.66), UDim2.fromScale(0.65, 0.17), {
			Variant = if equipped then "Success" else "Primary",
			TextSize = 14,
		})
		actionButton.Parent = row
		if equipped then
			actionButton.Active = false
			actionButton.AutoButtonColor = false
		else
			actionButton.MouseButton1Click:Connect(function()
				local success = Net.GetRemoteFunction(RemoteNames.EquipAbility):InvokeServer(info.Id)
				if success then
					GachaController.Refresh()
				end
			end)
		end
	else
		local lockedLabel = Widgets.Label("🔒 Locked", UDim2.fromScale(0.32, 0.66), UDim2.fromScale(0.65, 0.17), {
			TextSize = 14,
			Align = Enum.TextXAlignment.Center,
			Color = Theme.Color.TextMuted,
		})
		lockedLabel.Parent = row
	end

	return row
end

-- Re-checks BOTH gamepasses in one remote call and updates both buttons --
-- called from GachaController.Refresh() (panel open/equip/continue) AND
-- directly from PromptGamePassPurchaseFinished below, so a purchase that
-- completes while the panel is already open updates the button immediately
-- instead of waiting for the next time Refresh() happens to run. Missing
-- that second call site was exactly why "buy Lucky" kept showing even after
-- a successful purchase -- Refresh() alone only reacts to being reopened.
local function refreshMonetizationButtons()
	local status = Net.GetRemoteFunction(RemoteNames.GetMonetizationStatus):InvokeServer()

	skipGachaOwned = (status and status.HasSkipGachaAnimation) or false
	refreshSkipPurchaseRow()

	luckyOwned = (status and status.HasLucky) or false
	if luckyOwned then
		luckyButton.Text = "🍀 Lucky Active — Better Odds"
		luckyButton.Active = false
		luckyButton.AutoButtonColor = false
	else
		luckyButton.Text = "🍀 Get Lucky — Better Odds"
		luckyButton.Active = true
		luckyButton.AutoButtonColor = true
	end
end

function GachaController.Refresh()
	local profile = Net.GetRemoteFunction(RemoteNames.GetProfile):InvokeServer()
	if not profile then
		return
	end

	skipAnimationEnabled = profile.SkipGachaAnimationEnabled or false
	pointsLabel.Text = ("%d points"):format(profile.Points)

	refreshMonetizationButtons()

	for _, child in inventoryList:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	for i, info in Abilities do
		local row = buildInventoryRow(info, profile)
		row.LayoutOrder = i
		row.Parent = inventoryList
	end
end

local function buildMainPanel()
	-- Toggle button lives in its own small ScreenGui at the default
	-- DisplayOrder (0), same layer as every other persistent HUD button
	-- (Shop, Party, Play, ...) -- the PANEL itself is a separate Widgets.
	-- Modal at a much higher DisplayOrder (see below) so it and its own
	-- Odds/Reveal sub-panels always render above the base HUD.
	local toggleGui = Instance.new("ScreenGui")
	toggleGui.Name = "GachaToggleGui"
	toggleGui.ResetOnSpawn = false
	toggleGui.Parent = player:WaitForChild("PlayerGui")

	-- Sits directly below ShopController's toggle button, same X, same
	-- 8px-gap-below-a-48px-button convention used throughout this stack.
	local toggleButton = Widgets.Button("Gacha", UDim2.fromOffset(130, 48), UDim2.new(1, -140, 0, 116))
	toggleButton.Parent = toggleGui

	panel, openMainPanel, closeMainPanel = Widgets.Modal(
		"Gacha",
		UDim2.fromOffset(400, 520),
		UDim2.new(1, -410, 0, 116),
		{ DisplayOrder = 30 }
	)

	local title = Widgets.Label("ABILITY GACHA", UDim2.new(1, -16, 0, 26), UDim2.fromOffset(8, 6), {
		TextSize = 20,
	})
	title.Parent = panel

	pointsLabel = Widgets.Label("", UDim2.new(1, -16, 0, 20), UDim2.fromOffset(8, 36), {
		TextSize = 15,
		Align = Enum.TextXAlignment.Right,
		Color = Theme.Color.Warning,
	})
	pointsLabel.Parent = panel

	luckyButton = Widgets.Button("🍀 Get Lucky — Better Odds", UDim2.new(1, -16, 0, 32), UDim2.fromOffset(8, 60), {
		Variant = "Danger",
		TextSize = 14,
	})
	luckyButton.Parent = panel
	luckyButton.MouseButton1Click:Connect(function()
		if not luckyOwned then
			Net.GetRemoteEvent(RemoteNames.PromptLuckyPurchase):FireServer()
		end
	end)
	local pullOneButton = Widgets.Button("Pull x1 — 1500 pts", UDim2.fromOffset(272, 36), UDim2.fromOffset(8, 98), {
		Variant = "Primary",
		TextSize = 14,
	})
	pullOneButton.Parent = panel
	pullOneButton.MouseButton1Click:Connect(function()
		local success, message = pullRemote:InvokeServer(1)
		if not success then
			pointsLabel.Text = message
		end
	end)

	local robuxOneButton = Widgets.Button("R$", UDim2.fromOffset(96, 36), UDim2.fromOffset(288, 98), {
		Variant = "Secondary",
		TextSize = 14,
	})
	robuxOneButton.Parent = panel
	robuxOneButton.MouseButton1Click:Connect(function()
		promptRobuxRemote:FireServer(1)
	end)

	local pullTenButton = Widgets.Button("Pull x10 — 13500 pts", UDim2.fromOffset(272, 36), UDim2.fromOffset(8, 138), {
		Variant = "Primary",
		TextSize = 14,
	})
	pullTenButton.Parent = panel
	pullTenButton.MouseButton1Click:Connect(function()
		local success, message = pullRemote:InvokeServer(10)
		if not success then
			pointsLabel.Text = message
		end
	end)

	local robuxTenButton = Widgets.Button("R$", UDim2.fromOffset(96, 36), UDim2.fromOffset(288, 138), {
		Variant = "Secondary",
		TextSize = 14,
	})
	robuxTenButton.Parent = panel
	robuxTenButton.MouseButton1Click:Connect(function()
		promptRobuxRemote:FireServer(10)
	end)

	-- Odds is always here; the Skip Animation unlock only shows up while it's
	-- still unowned (see refreshSkipPurchaseRow) -- once owned, ON/OFF lives
	-- in Settings instead (this panel just reads profile.
	-- SkipGachaAnimationEnabled at pull time), so there's nothing left for
	-- this row to show for it and Odds takes the full width back.
	local actionRow = Instance.new("Frame")
	actionRow.Name = "ActionRow"
	actionRow.Size = UDim2.new(1, -16, 0, 32)
	actionRow.Position = UDim2.fromOffset(8, 178)
	actionRow.BackgroundTransparency = 1
	actionRow.Parent = panel

	refreshSkipPurchaseRow = function()
		for _, child in actionRow:GetChildren() do
			child:Destroy()
		end

		local oddsWidth = if skipGachaOwned then 384 else 184
		local oddsButton = Widgets.Button("ℹ️ Odds", UDim2.fromOffset(oddsWidth, 32), UDim2.fromOffset(0, 0), {
			Variant = "Secondary",
			TextSize = 14,
		})
		oddsButton.Parent = actionRow
		oddsButton.MouseButton1Click:Connect(function()
			openOddsPanel()
		end)

		if not skipGachaOwned then
			local buyButton = Widgets.Button("🔓 Unlock Skip", UDim2.fromOffset(192, 32), UDim2.fromOffset(192, 0), {
				Variant = "Secondary",
				TextSize = 13,
			})
			buyButton.Parent = actionRow
			buyButton.MouseButton1Click:Connect(function()
				Net.GetRemoteEvent(RemoteNames.PromptSkipGachaAnimationPurchase):FireServer()
			end)
		end
	end
	refreshSkipPurchaseRow()

	local inventoryHeader = Widgets.Label("YOUR ABILITIES", UDim2.new(1, -16, 0, 20), UDim2.fromOffset(8, 216), {
		TextSize = 13,
		Color = Theme.Color.TextMuted,
	})
	inventoryHeader.Parent = panel

	inventoryList = Instance.new("ScrollingFrame")
	inventoryList.Size = UDim2.new(1, -16, 1, -246)
	inventoryList.Position = UDim2.fromOffset(8, 240)
	inventoryList.BackgroundTransparency = 1
	inventoryList.BorderSizePixel = 0
	inventoryList.CanvasSize = UDim2.new(0, 0, 0, 0)
	inventoryList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	inventoryList.ScrollBarThickness = 5
	inventoryList.ScrollBarImageColor3 = Theme.Color.AccentA
	inventoryList.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = inventoryList

	toggleButton.MouseButton1Click:Connect(function()
		if panel.Visible then
			closeMainPanel()
		else
			openMainPanel()
			GachaController.Refresh()
		end
	end)
end

local function buildOddsRow(info: Abilities.AbilityInfo, layoutOrder: number): Frame
	local row = Instance.new("Frame")
	row.LayoutOrder = layoutOrder
	row.Size = UDim2.new(1, 0, 0, 40)
	row.BackgroundColor3 = Theme.Color.PanelLight
	row.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = row

	local swatch = Instance.new("Frame")
	swatch.Size = UDim2.new(0, 5, 1, -10)
	swatch.Position = UDim2.fromOffset(5, 5)
	swatch.BackgroundColor3 = RARITY_COLOR[info.Rarity] or Theme.Color.TextMuted
	swatch.BorderSizePixel = 0
	local swatchCorner = Instance.new("UICorner")
	swatchCorner.CornerRadius = UDim.new(1, 0)
	swatchCorner.Parent = swatch
	swatch.Parent = row

	local icon = AbilityIcons.Create(info.Id, 24, UDim2.new(0, 14, 0.5, -12), RARITY_COLOR[info.Rarity] or Theme.Color.TextMuted)
	icon.Parent = row

	local nameLabel = Widgets.Label(("%s (%s)"):format(info.Name, info.Rarity), UDim2.new(0.55, -42, 1, 0), UDim2.fromOffset(44, 0), {
		TextSize = 14,
	})
	nameLabel.Parent = row

	local baseOdds = info.PullWeight or 0
	local luckyOdds = info.LuckyPullWeight or baseOdds
	local oddsLabel = Widgets.Label(("%d%%  ·  %d%% w/ Lucky"):format(baseOdds, luckyOdds), UDim2.new(0.45, -10, 1, 0), UDim2.new(0.55, 0, 0, 0), {
		TextSize = 13,
		Align = Enum.TextXAlignment.Right,
		Color = Theme.Color.TextSecondary,
	})
	oddsLabel.Parent = row

	return row
end

-- Roblox's Randomized Virtual Items policy requires exact drop-rate odds
-- (summing to 100%) to be shown BEFORE a paid randomized pull, not just
-- somewhere in the UI after the fact -- this is what the "ℹ️ Odds" button on
-- the main panel opens. Every pool ability's row here sums to 100% in both
-- the base and Lucky-boosted columns by construction (see Abilities.luau).
local function buildOddsPanel()
	-- 312 tall, not 360 -- the panel used to reserve an extra ~50px for a
	-- redundant "Close" button sitting right below the modal's own close-✕
	-- (see Widgets.Modal). Two ways to close the same panel one inch apart
	-- reads as unconsidered, not as an extra convenience.
	oddsPanel, openOddsPanel = Widgets.Modal(
		"GachaOdds",
		UDim2.fromOffset(420, 312),
		UDim2.new(0.5, -210, 0.5, -156),
		{ DisplayOrder = 31 }
	)

	local title = Widgets.Label("DROP RATES", UDim2.new(1, -16, 0, 26), UDim2.fromOffset(8, 8), {
		TextSize = 20,
		Align = Enum.TextXAlignment.Center,
	})
	title.Parent = oddsPanel

	local subtitle = Widgets.Label(
		"Exact odds for every ability pull. Dash is never in the pool -- it's free for everyone.",
		UDim2.new(1, -32, 0, 36),
		UDim2.fromOffset(16, 38),
		{ TextSize = 13, Color = Theme.Color.TextSecondary, Align = Enum.TextXAlignment.Center, Bold = false }
	)
	subtitle.TextWrapped = true
	subtitle.Parent = oddsPanel

	local list = Instance.new("Frame")
	list.Size = UDim2.new(1, -32, 0, 220)
	list.Position = UDim2.fromOffset(16, 82)
	list.BackgroundTransparency = 1
	list.Parent = oddsPanel

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	for i, info in Abilities do
		if info.PullWeight then
			buildOddsRow(info, i).Parent = list
		end
	end

end

local function buildRevealOverlay()
	revealPanel, openRevealPanel, closeRevealPanel, setRevealClickOutsideEnabled = Widgets.Modal(
		"GachaReveal",
		UDim2.fromOffset(640, 380),
		UDim2.new(0.5, -320, 0.5, -190),
		{ DisplayOrder = 32 }
	)

	-- continueButton below explicitly calls GachaController.Refresh() on its
	-- own click, but that was the ONLY path that did -- the modal's built-in
	-- close-X and click-outside-to-close (see Widgets.Modal) both just hide
	-- the panel with no idea GachaController exists, so the main panel's
	-- inventory list kept showing pre-pull ownership (no "Equip" button on
	-- what you just got) until it was manually closed and reopened. Listening
	-- for Visible itself flipping false catches every way this panel can
	-- close -- X, click-outside, and Widgets.CloseAllModals forcing it shut
	-- when a race starts -- in one place instead of chasing each call site.
	revealPanel:GetPropertyChangedSignal("Visible"):Connect(function()
		if not revealPanel.Visible then
			GachaController.Refresh()
		end
	end)

	local title = Widgets.Label("ABILITY PULL", UDim2.new(1, -20, 0, 26), UDim2.fromOffset(10, 10), {
		TextSize = 18,
		Align = Enum.TextXAlignment.Center,
		Color = Theme.Color.TextSecondary,
	})
	title.Parent = revealPanel

	-- Only shown during a 10-pull's sequential reel-spins (see
	-- startSequentialReveal) -- ten full reveals back to back take a while,
	-- so a bare spinning reel with no indication of progress could easily
	-- read as stuck rather than mid-ceremony.
	progressLabel = Widgets.Label("", UDim2.new(1, -20, 0, 16), UDim2.fromOffset(10, 38), {
		TextSize = 13,
		Align = Enum.TextXAlignment.Center,
		Color = Theme.Color.TextMuted,
	})
	progressLabel.Visible = false
	progressLabel.Parent = revealPanel

	reelWindow = Instance.new("Frame")
	reelWindow.Size = UDim2.fromOffset(WINDOW_WIDTH, CARD_HEIGHT)
	reelWindow.Position = UDim2.new(0.5, -WINDOW_WIDTH / 2, 0, 58)
	reelWindow.BackgroundTransparency = 1
	reelWindow.ClipsDescendants = true
	reelWindow.Parent = revealPanel

	local marker = Instance.new("Frame")
	marker.Size = UDim2.new(0, 4, 1, 8)
	marker.Position = UDim2.new(0.5, -2, 0, -4)
	marker.BackgroundColor3 = Theme.Color.Warning
	marker.BorderSizePixel = 0
	marker.ZIndex = 25
	marker.Parent = reelWindow

	reel = Instance.new("Frame")
	reel.Size = UDim2.fromOffset(TOTAL_CARDS * STEP, CARD_HEIGHT)
	reel.BackgroundTransparency = 1
	reel.Parent = reelWindow

	-- Same footprint as reelWindow (see populateResultIcons) -- Skip
	-- Animation swaps straight to this instead of ever showing the reel.
	resultIconsRow = Instance.new("Frame")
	resultIconsRow.Size = UDim2.fromOffset(WINDOW_WIDTH, CARD_HEIGHT)
	resultIconsRow.Position = UDim2.new(0.5, -WINDOW_WIDTH / 2, 0, 58)
	resultIconsRow.BackgroundTransparency = 1
	resultIconsRow.Visible = false
	resultIconsRow.Parent = revealPanel

	local resultIconsLayout = Instance.new("UIListLayout")
	resultIconsLayout.FillDirection = Enum.FillDirection.Horizontal
	resultIconsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	resultIconsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	resultIconsLayout.Padding = UDim.new(0, 8)
	resultIconsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	resultIconsLayout.Parent = resultIconsRow

	-- NOTE on the Y math below: Widgets.Button recenters whatever position/
	-- size it's given around the button's own midpoint (see its doc
	-- comment), but Widgets.Label does NOT -- a label's position is its
	-- literal top-left corner. Mixing the two while eyeballing "should sit
	-- below" spacing is exactly what let summaryLabel (was y=300, height 60,
	-- so spans 300-360) and continueButton (was position 1,-56 + height 40,
	-- which Widgets.Button turns into a CENTER at panelHeight-36 -- i.e. a
	-- span of 324-364) silently overlap by 36px, with the button painting
	-- over the bottom third of the summary text. Recomputed to leave a real
	-- gap between the two spans instead of assuming naive top-left math for
	-- both.
	summaryLabel = Widgets.Label("", UDim2.new(1, -40, 0, 70), UDim2.fromOffset(20, 256), {
		TextSize = 15,
		Align = Enum.TextXAlignment.Center,
	})
	summaryLabel.TextWrapped = true
	summaryLabel.Visible = false
	summaryLabel.Parent = revealPanel

	-- Span 334-374 (computed the same way -- position.Y.Scale*H + offset +
	-- height/2 = the button's actual CENTER), leaving an 8px gap below
	-- summaryLabel's 256-326 span instead of overlapping it.
	continueButton = Widgets.Button("Continue", UDim2.fromOffset(180, 40), UDim2.new(0.5, -90, 1, -46), {
		Variant = "Primary",
		TextSize = 15,
	})
	continueButton.Visible = false
	continueButton.Parent = revealPanel
	continueButton.MouseButton1Click:Connect(function()
		closeRevealPanel()
		GachaController.Refresh()
	end)

	-- Momentary rarity-tinted pulse (see flashRarity) -- covers the whole
	-- panel so every reel landing (single pull or each spin of a 10-pull's
	-- sequential reveal) gets the same treatment. Created LAST (after every
	-- card/label above) so plain creation-order
	-- stacking puts it on top without needing an explicit ZIndex fight; see
	-- Widgets.Modal's doc comment for why an explicit high ZIndex on a
	-- CanvasGroup's content is NOT how you get something to render above
	-- its siblings under ZIndexBehavior.Global. Active = false so it never
	-- eats clicks meant for the cards/buttons underneath.
	flashOverlay = Instance.new("Frame")
	flashOverlay.Name = "RarityFlash"
	flashOverlay.Size = UDim2.fromScale(1, 1)
	flashOverlay.BackgroundColor3 = Color3.new(1, 1, 1)
	flashOverlay.BackgroundTransparency = 1
	flashOverlay.BorderSizePixel = 0
	flashOverlay.Active = false
	flashOverlay.Parent = revealPanel
end

function GachaController.Init()
	pullRemote = Net.GetRemoteFunction(RemoteNames.PullGacha)
	promptRobuxRemote = Net.GetRemoteEvent(RemoteNames.PromptGachaRobuxPurchase)

	buildMainPanel()
	buildOddsPanel()
	buildRevealOverlay()

	-- Initial skipAnimationEnabled value -- SettingsController owns the
	-- toggle itself; this only ever needs to know the CURRENT preference
	-- before the first pull.
	local profile = Net.GetRemoteFunction(RemoteNames.GetProfile):InvokeServer()
	skipAnimationEnabled = (profile and profile.SkipGachaAnimationEnabled) or false

	local status = Net.GetRemoteFunction(RemoteNames.GetMonetizationStatus):InvokeServer()
	skipGachaOwned = (status and status.HasSkipGachaAnimation) or false
	refreshSkipPurchaseRow()

	Net.GetRemoteEvent(RemoteNames.GachaPullResult).OnClientEvent:Connect(playReveal)

	-- NOT MarketplaceService.PromptGamePassPurchaseFinished directly -- that
	-- signal fires independently on the client and on the server, with no
	-- guaranteed ordering against the server updating its own ownedCache (see
	-- MonetizationService's doc comment on statusChangedRemote). Querying
	-- GetMonetizationStatus off the client's own copy of that event was
	-- exactly why "buy Lucky" kept showing even after a successful purchase --
	-- this remote only fires AFTER the server-side cache write, so there's
	-- nothing left to race.
	Net.GetRemoteEvent(RemoteNames.MonetizationStatusChanged).OnClientEvent:Connect(function()
		refreshMonetizationButtons()

		-- Buying Skip Animation auto-enables it server-side (see
		-- MonetizationService) -- re-reading it here too so a pull started
		-- right after that purchase already skips the animation instead of
		-- needing a Settings visit or a panel reopen first.
		local profile = Net.GetRemoteFunction(RemoteNames.GetProfile):InvokeServer()
		skipAnimationEnabled = (profile and profile.SkipGachaAnimationEnabled) or false
	end)
end

return GachaController
