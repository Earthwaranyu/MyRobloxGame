--!nolint
-- Geometry regression sweep for the whole HUD, across every viewport shape.
--
-- HOW TO RUN: start a Play session, then paste this into Studio's command bar
-- with the context set to CLIENT (not Server, not Edit). It prints a per-viewport
-- pass/fail summary and every failure with real numbers.
--
-- WHY IT EXISTS: the same bug kept coming back in different clothes -- content
-- laid out against a reference size the panel does not actually have. It was
-- fixed seven separate times (ProfileCard's 400-wide content in a 577 panel,
-- RaceOutcome's raw row offsets, SpectateController never being made responsive
-- at all, ReferralReward's flat 400x150, QueueStation mixing three coordinate
-- systems, four panels centring against a locally-guessed width, Settings' Px
-- offsets against Tap heights). Every one was caught by hand-writing a throwaway
-- version of this file, and two were missed entirely and reported from a phone
-- instead -- because a sweep only ever catches the properties someone thought to
-- assert that day.
--
-- So the assertions live here now, and each one below names the bug it exists to
-- stop coming back. Adding a check here is what makes a class of bug permanent
-- history rather than something rediscovered next month.
--
-- LIMITS, stated so results are not over-trusted:
--   * Panels are forced visible rather than opened through their controllers, so
--     list content built on open (shop rows, leaderboard entries) is EMPTY here.
--     Row templates are scale-relative, but a populated list is not covered.
--   * Faking the viewport means hit-testing is meaningless (the layout is for a
--     screen the window does not have), so this measures geometry only.
--   * "Centred" is inferred, not declared -- see the CENTRING check.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LayoutMath = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LayoutMath"))

local player = Players.LocalPlayer
local pg = player:WaitForChild("PlayerGui")
local probe = pg:WaitForChild("ResponsiveViewportProbe"):WaitForChild("Probe")

-- Shapes that actually matter: the landscape phone the game is mostly played on,
-- a short wide phone, two tablets, a desktop, and both portrait sizes (where
-- Roblox's movement pad spans the FULL width rather than a corner).
local VIEWPORTS = {
	{ 801, 334 },
	{ 667, 375 },
	{ 706, 579 },
	{ 1280, 720 },
	{ 1920, 1080 },
	{ 375, 667 },
	{ 320, 568 },
}

-- A pixel or two of slack: AnchorPoint(0.5) on an odd size rounds, and chasing
-- that produces noise rather than bugs.
local TOL = 2
local MIN_TAP = LayoutMath.MinTouchTarget

local failures = {}
local checks = 0
-- Panels deferred to the real-viewport pass, so a skip is visible, not silent.
local skipped: { [string]: boolean } = {}

local function fail(viewport: string, message: string)
	table.insert(failures, ("[%s] %s"):format(viewport, message))
end

local function label(object: Instance): string
	local inner = object:FindFirstChild("Label")
	if inner and inner:IsA("TextLabel") and inner.Text ~= "" then
		return inner.Text
	end
	if (object:IsA("TextLabel") or object:IsA("TextButton")) and object.Text ~= "" then
		return object.Text
	end
	return object.Name
end

-- Clipped content is not a bug: a ScrollingFrame and a ClipsDescendants frame
-- (the gacha reel, the map-reveal window) are SUPPOSED to hold oversized
-- children. Only unclipped overflow escapes onto the screen.
local function isClipped(object: Instance, root: Instance): boolean
	local node = object.Parent
	while node and node ~= root do
		if node:IsA("ScrollingFrame") or (node:IsA("GuiObject") and node.ClipsDescendants) then
			return true
		end
		node = node.Parent
	end
	return false
end

-- Every ancestor visible, not just the object -- the first version of this sweep
-- flagged hidden accept/decline toasts as sitting on the movement pad because it
-- only checked the object's own Visible.
local function reachable(object: Instance): boolean
	local node = object
	while node and node ~= pg do
		if node:IsA("GuiObject") and not node.Visible then
			return false
		end
		if node:IsA("ScreenGui") and not node.Enabled then
			return false
		end
		node = node.Parent
	end
	return true
end

local function rect(object: GuiObject): (number, number, number, number)
	local origin = probe.AbsolutePosition
	local p, s = object.AbsolutePosition, object.AbsoluteSize
	return p.X - origin.X, p.Y - origin.Y, s.X, s.Y
end

local function overlaps(a: GuiObject, b: GuiObject): (number, number)
	local ax, ay, aw, ah = rect(a)
	local bx, by, bw, bh = rect(b)
	return math.min(ax + aw, bx + bw) - math.max(ax, bx), math.min(ay + ah, by + bh) - math.max(ay, by)
end

local function sweep(width: number, height: number, faked: boolean)
	local tag = ("%dx%d"):format(width, height)
	local view = { Width = width, Height = height, Touch = UserInputService.TouchEnabled }
	local stripLeft, stripRight = LayoutMath.ClearStrip(view)
	local padTop = LayoutMath.MoveAreaTop(view)
	local band = LayoutMath.TouchBand(view)
	local portrait = height > width
	local margin = LayoutMath.ScreenMargin

	for _, gui in pg:GetChildren() do
		if not gui:IsA("ScreenGui") or gui.Name == "ResponsiveViewportProbe" or gui.Name == "TouchGui" then
			continue
		end

		for _, panel in gui:GetChildren() do
			if not panel:IsA("CanvasGroup") then
				continue
			end

			-- Panels are shown, and normalised, rather than opened through their
			-- controllers. PopScale is left at 0.9 by Widgets.Close, which makes
			-- every measurement 10% small -- that once read as a screen full of
			-- 39pt tap targets that were really 44.
			local scale = panel:FindFirstChild("PopScale")
			local oldScale = scale and (scale :: UIScale).Scale
			if scale then
				(scale :: UIScale).Scale = 1
			end
			local wasVisible, wasAlpha = panel.Visible, panel.GroupTransparency
			panel.Visible, panel.GroupTransparency = true, 0
			for _, scroll in panel:GetDescendants() do
				if scroll:IsA("ScrollingFrame") then
					scroll.CanvasPosition = Vector2.zero
				end
			end
			task.wait(0.12)

			local px, py, pw, ph = rect(panel)
			local name = gui.Name:gsub("ModalGui$", ""):gsub("Gui$", "")

			-- A panel positioned with a SCALE component resolves against the real
			-- ScreenGui, which faking the probe does NOT resize -- so its offsets move
			-- with the fake while its scale stays put, and every measurement mixes two
			-- different screens. RaceHud and MapReveal both do this. They are covered
			-- by the real-viewport pass at the end rather than judged against a lie.
			if faked and (panel.Position.X.Scale ~= 0 or panel.Position.Y.Scale ~= 0) then
				skipped[name] = true
				panel.Visible, panel.GroupTransparency = wasVisible, wasAlpha
				if scale then
					(scale :: UIScale).Scale = oldScale
				end
				continue
			end

			-- FITS: a panel bigger than the screen loses whatever is at its
			-- edges, and PlacePanel's clamp is what is supposed to prevent it.
			checks += 1
			if pw > width - margin + TOL or ph > height - margin + TOL then
				fail(tag, ("%s panel %dx%d exceeds the %dx%d viewport"):format(name, pw, ph, width, height))
			end

			-- ON SCREEN: PlayModePicker sized itself from its own content and
			-- had no clamp at all -- 384 tall on a 334 screen, cut at both ends.
			checks += 1
			if px < -TOL or py < -TOL or px + pw > width + TOL or py + ph > height + TOL then
				fail(tag, ("%s panel off-screen at x %d..%d y %d..%d"):format(name, px, px + pw, py, py + ph))
			end

			-- NO CENTRING CHECK, deliberately.
			--
			-- A first version inferred it: flag a panel that is neither centred nor
			-- hugging an edge. It was wrong in both directions. It produced a dozen
			-- false positives on panels that are right-aligned on purpose (Shop,
			-- Gacha, Spectate) -- and, worse, it would have MISSED the very bug it was
			-- written for: the victory panel, centred against a locally-guessed width,
			-- ended up clamped flush to the right edge, which the "hugs an edge"
			-- exception waves straight through.
			--
			-- Centring intent is not written down anywhere an outside observer can
			-- read, so it cannot be asserted from here without inventing it. It is
			-- checked by eye instead. A check that looks rigorous and is not is worse
			-- than no check, because it gets trusted.

			local ribbon = panel:FindFirstChild("Ribbon")
			-- RIBBON: hangs half above the panel, so a panel pushed to the screen
			-- margin sliced the top off its own title on five panels at once.
			if ribbon and ribbon:IsA("GuiObject") then
				checks += 1
				local _, ry = rect(ribbon)
				if ry < -TOL then
					fail(tag, ("%s title ribbon cut off the top (y=%d)"):format(name, ry))
				end
			end

			local close = panel:FindFirstChild("CloseButton")
			local interactive = {}
			for _, d in panel:GetDescendants() do
				if not (d:IsA("GuiObject") and d.Visible and d.AbsoluteSize.X > 2) then
					continue
				end
				if ribbon and (d == ribbon or d:IsDescendantOf(ribbon)) then
					continue
				end

				-- INSIDE ITS PANEL: a CanvasGroup does NOT clip, so content
				-- placed past its edge simply renders loose on the screen --
				-- that is how the profile card's "This is your profile" line and
				-- the race-result streak line ended up floating outside.
				if not isClipped(d, panel) then
					checks += 1
					local dx, dy, dw, dh = rect(d)
					if dx < px - TOL or dy < py - TOL or dx + dw > px + pw + TOL or dy + dh > py + ph + TOL then
						fail(tag, ("%s: '%s' is outside its panel"):format(name, label(d)))
					end
				end

				if d:IsA("GuiButton") and d ~= close and not isClipped(d, panel) then
					table.insert(interactive, d)

					-- TAP TARGET: the whole reason Responsive.Tap exists.
					if view.Touch then
						checks += 1
						local _, _, dw, dh = rect(d)
						if dw < MIN_TAP - TOL or dh < MIN_TAP - TOL then
							fail(
								tag,
								("%s: '%s' is %dx%d, under the %dpt tap minimum"):format(
									name,
									label(d),
									dw,
									dh,
									MIN_TAP
								)
							)
						end
					end

					-- UNDER THE ✕: the close button wins on ZIndex, so anything
					-- beneath it is unpressable -- that is how a Leaderboard
					-- stage tab closed the panel instead of selecting a stage.
					if close and close:IsA("GuiObject") then
						checks += 1
						local ox, oy = overlaps(d, close)
						if ox > 0 and oy > 0 then
							fail(tag, ("%s: '%s' sits under the close X (%dx%d)"):format(name, label(d), ox, oy))
						end
					end
				end
			end

			-- SIBLING OVERLAP: two controls on top of each other. The race-size
			-- panel had its + button covering the number it adjusts.
			for i = 1, #interactive do
				for j = i + 1, #interactive do
					checks += 1
					local ox, oy = overlaps(interactive[i], interactive[j])
					if ox > TOL and oy > TOL then
						fail(
							tag,
							("%s: '%s' overlaps '%s' by %dx%d"):format(
								name,
								label(interactive[i]),
								label(interactive[j]),
								ox,
								oy
							)
						)
					end
				end
			end

			panel.Visible, panel.GroupTransparency = wasVisible, wasAlpha
			if scale then
				(scale :: UIScale).Scale = oldScale
			end
		end
	end

	-- Persistent HUD buttons against Roblox's OWN touch controls, which are drawn
	-- above every ScreenGui this game creates. A button under one of them is not
	-- merely crowded, it is unpressable -- and one over the movement pad swallows
	-- the touch that would have started a walk. That was the original "I press
	-- sprint and then I can't move".
	for _, gui in pg:GetChildren() do
		if not gui:IsA("ScreenGui") or gui.DisplayOrder > 25 then
			continue
		end
		if gui.Name == "ResponsiveViewportProbe" or gui.Name == "TouchGui" then
			continue
		end
		for _, d in gui:GetDescendants() do
			if not (d:IsA("GuiButton") and reachable(d) and d.AbsoluteSize.X > 0) then
				continue
			end
			local x, y, w, h = rect(d)

			checks += 1
			local onPad = if portrait then (y + h > padTop + TOL) else (x + TOL < stripLeft and y + h > padTop)
			if onPad then
				fail(
					tag,
					("HUD '%s' sits on the movement pad (x %d..%d y %d..%d)"):format(label(d), x, x + w, y, y + h)
				)
			end

			if not portrait then
				checks += 1
				if x + w > stripRight + TOL and y + h > height - band then
					fail(tag, ("HUD '%s' sits under the jump button"):format(label(d)))
				end
			end

			checks += 1
			if x < -TOL or y < -TOL or x + w > width + TOL or y + h > height + TOL then
				fail(tag, ("HUD '%s' is off-screen (x %d..%d y %d..%d)"):format(label(d), x, x + w, y, y + h))
			end

			if view.Touch then
				checks += 1
				if w < MIN_TAP - TOL or h < MIN_TAP - TOL then
					fail(tag, ("HUD '%s' is %dx%d, under the %dpt tap minimum"):format(label(d), w, h, MIN_TAP))
				end
			end
		end
	end
end

-- TEXT FIT: checked once at the real viewport rather than per faked size --
-- TextBounds is measured by the renderer and a faked viewport does not change
-- the font. Catches the "PRACTICE" -> "PRA..." class of bug.
local function sweepText()
	for _, gui in pg:GetChildren() do
		if not gui:IsA("ScreenGui") or gui.Name == "ResponsiveViewportProbe" then
			continue
		end
		for _, d in gui:GetDescendants() do
			if
				(d:IsA("TextLabel") or d:IsA("TextButton"))
				and d.Text ~= ""
				and not d.TextScaled
				and not d.TextWrapped
			then
				local padding = d:FindFirstChildOfClass("UIPadding")
				local available = d.AbsoluteSize.X
					- (if padding then padding.PaddingLeft.Offset + padding.PaddingRight.Offset else 0)
				if available > 2 then
					checks += 1
					if d.TextBounds.X > available + TOL then
						fail("text", ("'%s' needs %dpt but has %dpt"):format(d.Text, d.TextBounds.X, available))
					end
				end
			end
		end
	end
end

local originalSize = probe.Size
for _, v in VIEWPORTS do
	probe.Size = UDim2.fromOffset(v[1], v[2])
	task.wait(0.8) -- Responsive polls at 5Hz; let every observer re-lay-out.
	sweep(v[1], v[2], true)
end
probe.Size = originalSize
task.wait(0.8)
-- The real window: nothing faked, so scale-positioned panels are measured
-- against the screen they are actually laid out for.
sweep(probe.AbsoluteSize.X, probe.AbsoluteSize.Y, false)
sweepText()

local deferred = {}
for name in skipped do
	table.insert(deferred, name)
end
table.sort(deferred)
print(("\nHUD SWEEP: %d assertions across %d viewports + the real one"):format(checks, #VIEWPORTS))
if #deferred > 0 then
	print(("   scale-positioned, checked only at the real viewport: %s"):format(table.concat(deferred, ", ")))
end
if #failures == 0 then
	print("PASS -- no geometry failures")
else
	print(("FAIL -- %d problem(s):"):format(#failures))
	for _, f in failures do
		print("   " .. f)
	end
end
return ("%d assertions, %d failures"):format(checks, #failures)
