local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Abilities = require(Shared.Abilities)
local Constants = require(Shared.Constants)
local Net = require(Shared.Net)
local RarityColors = require(Shared.RarityColors)
local RarityOrder = require(Shared.RarityOrder)
local RemoteNames = require(Shared.RemoteNames)

local AbilityIcons = require(script.Parent.Parent.AbilityIcons)
local CategoryIcons = require(script.Parent.Parent.CategoryIcons)
local MobileMenu = require(script.Parent.Parent.MobileMenu)
local Responsive = require(script.Parent.Parent.Responsive)
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

-- The pull rows stack by the height a row actually has, not by its authored y.
--
-- Authored at y = 0 / 38 / 78, which scale to 0 / 27 / 56 on a phone -- while
-- Tap() holds each row at the 44pt touch minimum. Gaps of 27 between 44-tall
-- rows means every row overlapped the one above it: measured, four overlapping
-- pairs, and on screen the two Pull buttons sat on top of each other.
local GACHA_ROW_GAP = 6

-- Where the drop-rates section starts: below the last pull row, derived rather
-- than hard-coded at 162/172/194/218. Those literals were authored against
-- 36pt rows; once Tap() floors every row to 44 on touch the rows grow past them
-- and the divider, heading and subtitle end up inside the skip row.
local function gachaRowY(index: number): number
	-- index is 0-based; row 0 is the Lucky banner, which is shorter.
	local lucky = Responsive.Tap(32)
	if index == 0 then
		return 0
	end
	return lucky + GACHA_ROW_GAP + (index - 1) * (Responsive.Tap(36) + GACHA_ROW_GAP)
end

-- Heading height, named so the subtitle can be placed BELOW it rather than at
-- another hand-picked offset -- the two were 2pt apart and overlapped.
local ODDS_HEADING_H = 20
local ODDS_SUBTITLE_H = 18

-- The pity block: a header line, the bar itself, and a caption under it.
--
-- Sits directly under the pull buttons and ABOVE the drop rates, because it
-- answers a different question than the odds do. Odds tell a player what one
-- pull is worth; the pity bar tells them what the pulls they have ALREADY made
-- are worth -- which is the number that decides whether they pull again now or
-- come back later. Roblox's odds-disclosure requirement is about the former, so
-- nothing here displaces it: the rates still sit in view of the buttons.
local PITY_LABEL_H = 18
local PITY_TRACK_H = 14
local PITY_CAPTION_H = 16

local function pityTop(): number
	return gachaRowY(3) + GACHA_ROW_GAP + Responsive.Tap(32) + Responsive.Px(14)
end

local function pityBlockHeight(): number
	return PITY_LABEL_H + PITY_TRACK_H + PITY_CAPTION_H + Responsive.Px(8)
end

-- Top of the drop-rates block: below the pity block.
local function oddsTop(): number
	return pityTop() + pityBlockHeight() + Responsive.Px(10)
end

-- Reference geometry. Both heights are maximums -- Responsive.PlacePanel clamps
-- them to what the viewport can show.
local GACHA_WIDTH, GACHA_HEIGHT = 400, 520
local REVEAL_WIDTH, REVEAL_HEIGHT = 640, 380

local player = Players.LocalPlayer

local RARITY_COLOR = RarityColors

-- Ascending, so a 10-pull's reveal order (see startSequentialReveal) can
-- sort by this and save the best pull for last -- the "escalating anticipation"
-- beat that separates a premium gacha reveal from a flat one: a reel/flip
-- that reveals randomly (or worst-first) wastes the one moment the player
-- is most primed to feel something.
-- Ranking now lives in Shared/RarityOrder, alongside the ten-pull floor and
-- the pity counter that read the same numbers server-side -- see that module
-- for why a private copy here was a hazard.
local RARITY_RANK = RarityOrder.Rank

-- How strong the landing flash (see flashRarity) is per rarity -- 0 means
-- "no flash", scaling up so a Legendary pull visibly hits harder than a
-- Common one instead of every pull getting identical treatment.
local RARITY_FLASH_STRENGTH = { Common = 0, Rare = 0.15, Epic = 0.35, Legendary = 0.55, Mythic = 0.8 }
-- Extra beat held on higher rarities so the reveal doesn't just blur past
-- them at the same pace as a Common -- the "sound/light lands, then a beat
-- before moving on" pacing the research called out.
local RARITY_HOLD_SECONDS = { Common = 0, Rare = 0.1, Epic = 0.35, Legendary = 0.7, Mythic = 1.2 }

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

-- Pity bar state. `pityCount` is mirrored from the server rather than counted
-- locally: the client never sees a pull it didn't ask for, but it also must not
-- become the authority on a number the server enforces -- it arrives with the
-- profile on open and rides along with every pull result.
local pityCount = 0
local ownsAllMythics = false
-- Which Mythics the player holds, keyed by ability id. Only Mythic ids are
-- ever put in here; it exists purely to answer ownsEveryMythic().
local ownedMythics: { [string]: boolean } = {}
local pityFill: Frame
local pityCountLabel: TextLabel
local pityCaptionLabel: TextLabel
local refreshPityBar: () -> ()

-- Every Mythic in the pool, so the bar can tell "still chasing" apart from
-- "already collected". With a one-item Mythic tier the distinction matters
-- more than it looks: once Phoenix is owned, hitting the guarantee awards a
-- DUPLICATE (a 50-point refund, see GachaService.grantPull), so a bar still
-- promising "guaranteed Mythic" would be promising something the player
-- already has. Built from the same PullWeight gate the server's pool uses.
local MYTHIC_IDS: { string } = {}
for _, info in Abilities do
	if info.PullWeight and RarityOrder.Of(info.Rarity) >= RarityOrder.Rank.Mythic then
		table.insert(MYTHIC_IDS, info.Id)
	end
end

local function ownsEveryMythic(): boolean
	for _, id in MYTHIC_IDS do
		if not ownedMythics[id] then
			return false
		end
	end
	return #MYTHIC_IDS > 0
end
local luckyButton: TextButton
-- Mirrors ShopController's vipOwned -- Active = false alone was assumed to
-- be enough to block the click, but the click handler below fired
-- unconditionally regardless of Active, so a stray/leftover click still
-- re-prompted the purchase every time even once owned. This is what actually
-- made VIP's identical-looking fix work while Lucky's didn't: VIP's handler
-- already had this same explicit ownership check, Lucky's never did.
local luckyOwned = false

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
	local icon = AbilityIcons.Create(
		info.Id,
		68,
		UDim2.fromOffset((CARD_WIDTH - 68) / 2, 16),
		RARITY_COLOR[info.Rarity] or Theme.Color.TextSecondary
	)
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

	-- Measured, not the authored WINDOW_WIDTH: the window now takes its width from
	-- the panel (see buildRevealOverlay), so the landing offset has to come from
	-- the width it actually got or the winning card stops off-centre.
	local windowWidth = reelWindow.AbsoluteSize.X
	if windowWidth <= 0 then
		windowWidth = WINDOW_WIDTH
	end
	local targetX = windowWidth / 2 - ((WINNING_INDEX - 1) * STEP + CARD_WIDTH / 2)
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
		local icon = AbilityIcons.Create(
			info.Id,
			44,
			UDim2.fromOffset(0, 0),
			RARITY_COLOR[info.Rarity] or Theme.Color.TextSecondary
		)
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

-- `pullsSinceMythic` is the server's post-pull count, sent alongside the
-- results (see GachaService.doPulls). Applied immediately rather than after the
-- reveal finishes: the reveal panel covers the bar while it plays, so by the
-- time the player can see it again it is already correct, and a mid-reveal
-- update costs nothing.
local function playReveal(results, pullsSinceMythic: number?)
	if pullsSinceMythic then
		pityCount = pullsSinceMythic
		-- A Mythic in this batch is now owned, whether it was new or a
		-- duplicate -- either way the "still chasing" state may have just
		-- ended, and waiting for the next panel open to notice would leave the
		-- bar promising a guarantee the player has already collected.
		for _, result in results do
			if RarityOrder.Of(result.Rarity) >= RarityOrder.Rank.Mythic then
				ownedMythics[result.Id] = true
			end
		end
		ownsAllMythics = ownsEveryMythic()
		refreshPityBar()
	end

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
		-- Green once active -- see ShopController's VIP button for the same
		-- treatment/reasoning.
		Widgets.SetButtonColors(luckyButton, Theme.Candy.Green.Face, Theme.Candy.Green.Shadow, Color3.new(1, 1, 1))
	else
		luckyButton.Text = "🍀 Get Lucky — Better Odds"
		luckyButton.Active = true
		luckyButton.AutoButtonColor = true
		Widgets.SetButtonColors(luckyButton, Theme.Candy.Red.Face, Theme.Candy.Red.Shadow, Color3.new(1, 1, 1))
	end
end

function refreshPityBar()
	if not pityFill then
		return
	end

	local goal = Constants.Gacha.MythicPityPulls
	local count = math.clamp(pityCount, 0, goal)
	pityFill.Size = UDim2.fromScale(count / goal, 1)
	pityCountLabel.Text = ("%d / %d"):format(count, goal)

	if ownsAllMythics then
		-- Nothing left to chase: say so rather than counting toward a guarantee
		-- that would pay out a duplicate.
		pityCaptionLabel.Text = "Every Mythic collected — pulls now count toward duplicates."
		pityCountLabel.TextColor3 = Theme.Color.TextSecondary
		return
	end

	pityCountLabel.TextColor3 = RarityColors.Mythic
	local remaining = goal - count
	if remaining <= 0 then
		pityCaptionLabel.Text = "Your next pull is a guaranteed Mythic."
	else
		pityCaptionLabel.Text = ("%d %s until a guaranteed Mythic."):format(
			remaining,
			if remaining == 1 then "pull" else "pulls"
		)
	end
end

function GachaController.Refresh()
	local profile = Net.GetRemoteFunction(RemoteNames.GetProfile):InvokeServer()
	if not profile then
		return
	end

	skipAnimationEnabled = profile.SkipGachaAnimationEnabled or false
	pointsLabel.Text = ("%d points"):format(profile.Points)

	pityCount = profile.PullsSinceMythic or 0
	table.clear(ownedMythics)
	for _, id in profile.OwnedAbilities or {} do
		ownedMythics[id] = true
	end
	ownsAllMythics = ownsEveryMythic()
	refreshPityBar()

	refreshMonetizationButtons()
end

-- Odds are whole numbers for every tier except Mythic, which sits at 0.1%
-- (0.6% with Lucky). The old "%d%%" here truncated both of those to a flat
-- "0%" -- an odds screen stating that the rarest item in the game is
-- impossible to obtain, which is worse than showing nothing at all. Whole
-- numbers still print without a pointless ".0" tail, so nothing about the
-- existing four rows changes.
local function formatOdds(weight: number): string
	if weight == math.floor(weight) then
		return ("%d"):format(weight)
	end
	return ("%.1f"):format(weight)
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

	local icon =
		AbilityIcons.Create(info.Id, 24, UDim2.new(0, 14, 0.5, -12), RARITY_COLOR[info.Rarity] or Theme.Color.TextMuted)
	icon.Parent = row

	local nameLabel =
		Widgets.Label(("%s (%s)"):format(info.Name, info.Rarity), UDim2.new(0.55, -42, 1, 0), UDim2.fromOffset(44, 0), {
			TextSize = 14,
		})
	nameLabel.Parent = row

	local baseOdds = info.PullWeight or 0
	local luckyOdds = info.LuckyPullWeight or baseOdds
	local oddsLabel = Widgets.Label(
		("%s%%  ·  %s%% w/ Lucky"):format(formatOdds(baseOdds), formatOdds(luckyOdds)),
		UDim2.new(0.45, -10, 1, 0),
		UDim2.fromScale(0.55, 0),
		{
			TextSize = 13,
			Align = Enum.TextXAlignment.Right,
			Color = Theme.Color.TextSecondary,
		}
	)
	oddsLabel.Parent = row

	return row
end

local function buildMainPanel()
	-- Toggle button lives in its own small ScreenGui at the default
	-- DisplayOrder (0), same layer as every other persistent HUD button
	-- (Shop, Party, Play, ...) -- the PANEL itself is a separate Widgets.
	-- Modal at a much higher DisplayOrder (see below) so it and its own
	-- Reveal sub-panel always render above the base HUD.
	local toggleGui = Instance.new("ScreenGui")
	toggleGui.Name = "GachaToggleGui"
	toggleGui.ResetOnSpawn = false
	toggleGui.Parent = player:WaitForChild("PlayerGui")

	-- Sits directly below ShopController's toggle button, same X, same
	-- 8px-gap-below-a-48px-button convention used throughout this stack.
	local toggleButton = Widgets.Button(
		"Gacha",
		UDim2.fromOffset(Responsive.Px(130), Responsive.Tap(48)),
		UDim2.new(1, -Responsive.Px(140), 0, Responsive.RailY(2)),
		{
			-- Reuses the same "Pulls" gift-box glyph this panel's own tab strip
			-- already draws (see CategoryIcons) -- same concept, no need for a
			-- second icon.
			Icon = function(holder, color)
				CategoryIcons.Populate(holder, "Pulls", holder.Size.X.Offset, color)
			end,
		}
	)
	toggleButton.Parent = toggleGui
	Widgets.BindRail(toggleButton, 130, 48, 2, "Right", 10)
	-- Folded into the drawer on phones only: three rail rows plus the
	-- bottom gameplay cluster do not both fit a 334pt screen.
	MobileMenu.Adopt(toggleButton, 7, { PhoneOnly = true })

	panel, openMainPanel, closeMainPanel = Widgets.Modal(
		"Gacha",
		UDim2.fromOffset(GACHA_WIDTH, GACHA_HEIGHT),
		UDim2.new(1, -410, 0, 116),
		{ DisplayOrder = 30 }
	)

	-- Drilling into this panel from the drawer should come back to the drawer.
	MobileMenu.ReopenWhenClosed(toggleButton, panel)

	-- The worst overflow in the HUD: 261pt of this panel was below the bottom
	-- edge of a phone, which is every pull button on it. The content pane is a
	-- relative-sized ScrollingFrame, so clamping the panel shortens the scroll
	-- window rather than losing rows.
	Responsive.Observe(function()
		local width = math.min(Responsive.Px(GACHA_WIDTH), Responsive.ViewportSize().X - Responsive.ScreenMargin * 2)
		Responsive.PlacePanel(
			panel,
			GACHA_WIDTH,
			GACHA_HEIGHT,
			Responsive.ViewportSize().X - width - Responsive.Px(10),
			Responsive.Px(116)
		)
	end)

	-- Ribbon replaces the old plain title label -- see Widgets.Ribbon. Sits
	-- half-overlapping the panel's own top edge, like a hanging sign.
	local ribbon = Widgets.Ribbon("ABILITY GACHA", UDim2.fromOffset(260, 40), UDim2.new(0.5, 0, 0, -20))
	ribbon.Parent = panel

	pointsLabel = Widgets.Label("", UDim2.new(1, -70, 0, 20), UDim2.fromOffset(8, 26), {
		TextSize = 16,
		Align = Enum.TextXAlignment.Right,
		Color = Theme.Candy.Gold.Face,
	})
	pointsLabel.Parent = panel

	-- One scrolling column, no tab strip. The Odds used to be a second tab
	-- beside Pulls; there is nothing left to switch between now that they sit
	-- under the pull buttons, and the strip's own "Pulls" tab was pointing at
	-- the only page there was.
	-- Scrolls as a whole. Everything in here -- three pull rows, the skip row and
	-- the drop-rates block -- needs about 320pt, against roughly 258 of panel on
	-- a phone. The old fixed frame gave whatever was left to the odds list, which
	-- measured NINE pixels tall: the rates were technically present and in
	-- practice unreadable. Scrolling the panel is what makes them reachable.
	local content = Instance.new("ScrollingFrame")
	content.Name = "Content"
	content.CanvasSize = UDim2.new()
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	content.ScrollBarThickness = 4
	content.ScrollingDirection = Enum.ScrollingDirection.Y
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	-- Below the ✕ rather than under it. 52 was a hand-measured figure against a
	-- 34pt close button; on touch Tap() makes that button 44, so the first thing
	-- in this list (the Lucky banner) had its top corner tucked under the ✕.
	-- Widgets.ModalContentTop is the figure that already knows both cases.
	local contentTop = Widgets.ModalContentTop(8)
	content.Size = UDim2.new(1, -16, 1, -(contentTop + 8))
	content.Position = UDim2.fromOffset(8, contentTop)
	content.BackgroundTransparency = 1
	content.Parent = panel

	-- Explicit TextSize=26 -- player-reported and screenshot-reproduced: white
	-- text at this Danger/Primary variant's normal ~14px functional-text size
	-- renders visibly soft/smeared, while the SAME string in near-black
	-- (Secondary variant, e.g. the R$ buttons next to Pull x1/x10) stays
	-- crisp at that size. Just crossing defaultTextSize's own >=18 threshold
	-- (19-21px here) turned out NOT to be enough on its own either -- still
	-- confirmed soft via screenshot at that size, only reliably crisp from
	-- ~26px up (the same size SPRINT's defaultTextSize already lands on,
	-- confirmed crisp). 26 (not 28) specifically because 28 overflows
	-- "Lucky Active — Better Odds" past this button's width -- see the
	-- TextService margin check done during testing.
	luckyButton = Widgets.Button(
		"🍀 Get Lucky — Better Odds",
		UDim2.new(1, 0, 0, Responsive.Tap(32)),
		UDim2.fromOffset(0, 0),
		{
			Variant = "Danger",
			TextSize = 26,
		}
	)
	luckyButton.Parent = content
	luckyButton.MouseButton1Click:Connect(function()
		if not luckyOwned then
			Net.GetRemoteEvent(RemoteNames.PromptLuckyPurchase):FireServer()
		end
	end)
	-- See luckyButton's comment above -- same explicit crisp-text size.
	local pullOneButton = Widgets.Button(
		"Pull x1 — 1500 pts",
		UDim2.fromOffset(Responsive.Px(272), Responsive.Tap(36)),
		UDim2.fromOffset(0, gachaRowY(1)),
		{
			Variant = "Primary",
			TextSize = 26,
		}
	)
	pullOneButton.Parent = content
	pullOneButton.MouseButton1Click:Connect(function()
		local success, message = pullRemote:InvokeServer(1)
		if not success then
			pointsLabel.Text = message
		end
	end)

	-- R$ was already crisp at 14px (dark text on this Secondary variant's
	-- white fill doesn't show the same softness white text does), but sized
	-- to match pullOneButton's text instead of looking mismatched next to it.
	local robuxOneButton = Widgets.Button(
		"R$",
		UDim2.fromOffset(Responsive.Px(96), Responsive.Tap(36)),
		UDim2.fromOffset(Responsive.Px(280), gachaRowY(1)),
		{
			Variant = "Secondary",
			TextSize = 26,
		}
	)
	robuxOneButton.Parent = content
	robuxOneButton.MouseButton1Click:Connect(function()
		promptRobuxRemote:FireServer(1)
	end)

	local pullTenButton = Widgets.Button(
		"Pull x10 — 13500 pts",
		UDim2.fromOffset(Responsive.Px(272), Responsive.Tap(36)),
		UDim2.fromOffset(0, gachaRowY(2)),
		{
			Variant = "Primary",
			TextSize = 26,
		}
	)
	pullTenButton.Parent = content
	pullTenButton.MouseButton1Click:Connect(function()
		local success, message = pullRemote:InvokeServer(10)
		if not success then
			pointsLabel.Text = message
		end
	end)

	local robuxTenButton = Widgets.Button(
		"R$",
		UDim2.fromOffset(Responsive.Px(96), Responsive.Tap(36)),
		UDim2.fromOffset(Responsive.Px(280), gachaRowY(2)),
		{
			Variant = "Secondary",
			TextSize = 26,
		}
	)
	robuxTenButton.Parent = content
	robuxTenButton.MouseButton1Click:Connect(function()
		promptRobuxRemote:FireServer(10)
	end)

	-- Full width now -- the "ℹ️ Odds" button that used to share this row got
	-- replaced entirely by the Odds tab above, so there's nothing left to
	-- split the row with once Skip Animation is unowned, and nothing to show
	-- at all once it's owned (ON/OFF lives in Settings from then on).
	local skipRow = Instance.new("Frame")
	skipRow.Name = "SkipRow"
	skipRow.Size = UDim2.new(1, 0, 0, Responsive.Tap(32))
	skipRow.Position = UDim2.fromOffset(0, gachaRowY(3) + GACHA_ROW_GAP)
	skipRow.BackgroundTransparency = 1
	skipRow.Parent = content

	refreshSkipPurchaseRow = function()
		for _, child in skipRow:GetChildren() do
			child:Destroy()
		end
		if skipGachaOwned then
			return
		end
		local buyButton = Widgets.Button("🔓 Unlock Skip Animation", UDim2.fromScale(1, 1), UDim2.fromOffset(0, 0), {
			Variant = "Secondary",
			TextSize = 14,
		})
		buyButton.Parent = skipRow
		buyButton.MouseButton1Click:Connect(function()
			Net.GetRemoteEvent(RemoteNames.PromptSkipGachaAnimationPurchase):FireServer()
		end)
	end
	refreshSkipPurchaseRow()

	-- THE PITY BAR.
	--
	-- Genshin famously does NOT show this, and its players built a cottage
	-- industry of third-party trackers to count it by hand -- the request to
	-- surface it in-game is one of that community's most-upvoted ever. The
	-- reason to show it is the oldest rule in interface design (visibility of
	-- system status), and the reason it is worth the panel space is narrower:
	-- a counter a player can watch climb turns a run of bad pulls from a series
	-- of dead ends into progress toward something, which is the difference
	-- between "this is rigged" and "I'm 60 in".
	--
	-- Shown as a COUNT (23 / 100) rather than a percentage, and with the
	-- remaining pulls spelled out underneath. A percentage is the thing players
	-- cannot act on -- "77 more pulls" is a decision, "23%" is trivia.
	--
	-- Deliberately NO "soft pity" hot zone marked on the track, which is the
	-- one flourish the research kept showing: those mark where the rate ramps
	-- up, and this game has no ramp. Drawing a zone that doesn't exist would be
	-- the exact trust problem the bar is here to solve.
	local pityHeader =
		Widgets.Label("MYTHIC PITY", UDim2.new(0.5, 0, 0, PITY_LABEL_H), UDim2.fromOffset(0, pityTop()), {
			TextSize = 13,
			Color = Theme.Color.TextPrimary,
			Align = Enum.TextXAlignment.Left,
		})
	pityHeader.Parent = content

	pityCountLabel = Widgets.Label(
		"",
		UDim2.new(0.5, 0, 0, PITY_LABEL_H),
		UDim2.new(0.5, 0, 0, pityTop()),
		{ TextSize = 13, Color = RarityColors.Mythic, Align = Enum.TextXAlignment.Right }
	)
	pityCountLabel.Parent = content

	local pityTrack = Instance.new("Frame")
	pityTrack.Name = "PityTrack"
	pityTrack.Size = UDim2.new(1, 0, 0, PITY_TRACK_H)
	pityTrack.Position = UDim2.fromOffset(0, pityTop() + PITY_LABEL_H)
	pityTrack.BackgroundColor3 = Theme.Color.PanelLight
	pityTrack.BorderSizePixel = 0
	pityTrack.Parent = content

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(0, PITY_TRACK_H // 2)
	trackCorner.Parent = pityTrack

	pityFill = Instance.new("Frame")
	pityFill.Name = "PityFill"
	pityFill.Size = UDim2.fromScale(0, 1)
	pityFill.BackgroundColor3 = RarityColors.Mythic
	pityFill.BorderSizePixel = 0
	pityFill.Parent = pityTrack

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, PITY_TRACK_H // 2)
	fillCorner.Parent = pityFill

	pityCaptionLabel = Widgets.Label(
		"",
		UDim2.new(1, 0, 0, PITY_CAPTION_H),
		UDim2.fromOffset(0, pityTop() + PITY_LABEL_H + PITY_TRACK_H + Responsive.Px(4)),
		{ TextSize = 12, Color = Theme.Color.TextSecondary, Align = Enum.TextXAlignment.Left, Bold = false }
	)
	pityCaptionLabel.Parent = content
	refreshPityBar()

	-- Roblox's Randomized Virtual Items policy requires exact drop-rate odds
	-- (summing to 100%) to be shown BEFORE a paid randomized pull. On their own
	-- tab that was satisfied only in the letter -- a player could pull without
	-- ever opening it. Here they sit directly under the buttons that spend the
	-- money, in view at the moment of the decision, which is what the rule is
	-- actually for. The pull rows only ever used the top ~150px of a 460px
	-- panel, so this costs no space that was doing anything else.
	local oddsDivider = Instance.new("Frame")
	oddsDivider.Name = "OddsDivider"
	oddsDivider.Size = UDim2.new(1, 0, 0, 1)
	oddsDivider.Position = UDim2.fromOffset(0, oddsTop())
	oddsDivider.BackgroundColor3 = Theme.Color.Stroke
	oddsDivider.BackgroundTransparency = 0.4
	oddsDivider.BorderSizePixel = 0
	oddsDivider.Parent = content

	local oddsHeading =
		Widgets.Label("DROP RATES", UDim2.new(1, 0, 0, 20), UDim2.fromOffset(0, oddsTop() + Responsive.Px(12)), {
			TextSize = 14,
			Color = Theme.Color.TextPrimary,
			Align = Enum.TextXAlignment.Center,
		})
	oddsHeading.Parent = content

	local oddsSubtitle = Widgets.Label(
		"Dash is never in the pool -- it's free for everyone.",
		UDim2.new(1, 0, 0, 18),
		UDim2.fromOffset(0, oddsTop() + Responsive.Px(12) + ODDS_HEADING_H + Responsive.Px(4)),
		{ TextSize = 12, Color = Theme.Color.TextSecondary, Align = Enum.TextXAlignment.Center, Bold = false }
	)
	oddsSubtitle.TextWrapped = true
	oddsSubtitle.Parent = content

	-- Scrolls: one row per pullable ability, so the list grows every time an
	-- ability is added and a fixed frame would quietly cut the newest ones off
	-- the bottom -- exactly the class of bug that hid Stage 4 on the leaderboard.
	-- A plain auto-sized frame, not a ScrollingFrame: `content` scrolls now, and
	-- a scroll inside a scroll is a fight over every drag.
	local oddsList = Instance.new("Frame")
	oddsList.AutomaticSize = Enum.AutomaticSize.Y
	-- Width from the parent, height from AutomaticSize.
	oddsList.Size = UDim2.fromScale(1, 0)
	oddsList.Position = UDim2.fromOffset(0, oddsTop() + Responsive.Px(20) + ODDS_HEADING_H + ODDS_SUBTITLE_H)
	oddsList.BackgroundTransparency = 1
	oddsList.BorderSizePixel = 0
	oddsList.Parent = content

	local oddsLayout = Instance.new("UIListLayout")
	oddsLayout.Padding = UDim.new(0, 6)
	oddsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	oddsLayout.Parent = oddsList

	for i, info in Abilities do
		if info.PullWeight then
			buildOddsRow(info, i).Parent = oddsList
		end
	end

	toggleButton.MouseButton1Click:Connect(function()
		if panel.Visible then
			closeMainPanel()
		else
			openMainPanel()
			GachaController.Refresh()
		end
	end)
end

local function buildRevealOverlay()
	revealPanel, openRevealPanel, closeRevealPanel, setRevealClickOutsideEnabled = Widgets.Modal(
		"GachaReveal",
		UDim2.fromOffset(REVEAL_WIDTH, REVEAL_HEIGHT),
		UDim2.new(0.5, -REVEAL_WIDTH / 2, 0.5, -REVEAL_HEIGHT / 2),
		{ DisplayOrder = 32 }
	)

	-- 640 wide is nearly a phone's entire viewport and 380 is taller than one,
	-- so the reveal -- the payoff for spending points -- was clipped at both
	-- ends on the device most likely to be watching it.
	Responsive.Observe(function()
		local viewport = Responsive.ViewportSize()
		Responsive.CenterPanel(revealPanel, REVEAL_WIDTH, REVEAL_HEIGHT, function(height)
			return (viewport.Y - height) / 2
		end)
	end)

	-- continueButton below explicitly calls GachaController.Refresh() on its
	-- own click, but that was the ONLY path that did -- the modal's built-in
	-- close-X and click-outside-to-close (see Widgets.Modal) both just hide
	-- the panel with no idea GachaController exists, so the main panel's
	-- points/monetization buttons kept showing stale pre-pull values until it
	-- was manually closed and reopened. Listening for Visible itself flipping
	-- false catches every way this panel can close -- X, click-outside, and
	-- Widgets.CloseAllModals forcing it shut when a race starts -- in one
	-- place instead of chasing each call site.
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
	-- Width from the PANEL, not the authored 560.
	--
	-- The reveal panel is clamped to the viewport (min(Px(640), screen)), so on
	-- anything narrower than ~640 the panel shrinks and a fixed 560 window does
	-- not -- measured on a 706x579 tablet, a 560 window inside a 461 panel hung
	-- 49pt out of each side. A CanvasGroup does not clip that away (confirmed by
	-- sampling the hanging title, which renders perfectly well outside its
	-- panel), so the spinning reel simply spilled past the edges of the card it
	-- is supposed to be inside.
	reelWindow.Size = UDim2.new(1, -16, 0, CARD_HEIGHT)
	reelWindow.Position = UDim2.fromOffset(8, 58)
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
	continueButton = Widgets.Button(
		"Continue",
		UDim2.fromOffset(Responsive.Px(180), Responsive.Tap(40)),
		UDim2.new(0.5, -Responsive.Px(180) / 2, 1, -(Responsive.Tap(40) + Responsive.Px(6))),
		{
			Variant = "Primary",
			TextSize = 15,
		}
	)
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
		local latestProfile = Net.GetRemoteFunction(RemoteNames.GetProfile):InvokeServer()
		skipAnimationEnabled = (latestProfile and latestProfile.SkipGachaAnimationEnabled) or false
	end)
end

return GachaController
