local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

-- Keeps only the nearest handful of NeonGlowService's lights switched on.
--
-- Local lights are the expensive part of Roblox lighting, and this game is
-- played mostly on phones. The lobby alone has one per queue room, and once
-- the stages opt in Stage3 adds eighteen more -- all of which the engine would
-- happily try to evaluate at once. Since a player can only ever SEE a few at a
-- time, the ones behind them or across the plaza are pure cost.
--
-- Runs on the client, against the CAMERA rather than the character: what
-- matters is what's on screen, and while spectating (or during the pre-race
-- countdown) the camera can be nowhere near the player's own body.
local NeonGlowController = {}

local TAG = "NeonGlow"
local LIGHT_NAME = "NeonGlow"
-- Comfortably more than are visible at once in the lobby, low enough that a
-- fully lit stage stays cheap.
local MAX_ACTIVE = 8
-- Lights don't move and neither does the camera very fast, so this doesn't
-- need to be per-frame -- it's a visibility budget, not an animation.
local REFRESH_INTERVAL = 0.4

local function collectLights(): { PointLight }
	local lights = {}
	for _, part in CollectionService:GetTagged(TAG) do
		local light = part:FindFirstChild(LIGHT_NAME, true)
		if light and light:IsA("PointLight") then
			table.insert(lights, light)
		end
	end
	return lights
end

local function refresh()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local origin = camera.CFrame.Position

	local lights = collectLights()
	if #lights <= MAX_ACTIVE then
		-- Nothing to budget: switching them all on costs less than sorting.
		for _, light in lights do
			light.Enabled = true
		end
		return
	end

	local ranked = {}
	for _, light in lights do
		local part = light:FindFirstAncestorWhichIsA("BasePart")
		if part then
			table.insert(ranked, { light = light, distance = (part.Position - origin).Magnitude })
		end
	end
	table.sort(ranked, function(a, b)
		return a.distance < b.distance
	end)

	for index, entry in ranked do
		entry.light.Enabled = index <= MAX_ACTIVE
	end
end

function NeonGlowController.Init()
	task.spawn(function()
		while true do
			-- Guarded: a light being destroyed mid-pass (a queue room rebuilt,
			-- a stage torn down) must not take the loop down with it.
			pcall(refresh)
			task.wait(REFRESH_INTERVAL)
		end
	end)

	-- One immediate pass so the lobby is lit on the first frame rather than up
	-- to REFRESH_INTERVAL later.
	RunService.Heartbeat:Wait()
	pcall(refresh)
end

return NeonGlowController
