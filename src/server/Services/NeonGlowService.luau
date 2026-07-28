local CollectionService = game:GetService("CollectionService")

-- Turns emissive parts into real light sources.
--
-- Neon material only makes a surface LOOK bright -- it casts nothing onto its
-- surroundings. Every glowing thing in this game (the queue-room floors, the
-- checkpoint pads, Stage3's night platforms) was therefore a flat glowing
-- sticker: bright in isolation, lighting nothing, leaving the ground beside it
-- exactly as dark as bare ground. A PointLight per emissive part is what turns
-- them into coloured pools of light on the floor and up the walls, which is
-- both what reads as "polished" in a screenshot and what makes a night stage
-- navigable rather than merely dark.
--
-- Tag-driven rather than a Material.Neon sweep: opting a part in has to be a
-- decision, since not every neon surface wants a light (a tiny UI-ish accent
-- glowing at full range would just wash out its neighbours). Lobby queue rooms
-- opt in today (see QueueStationService); the stages can follow by adding the
-- same tag.
local NeonGlowService = {}

NeonGlowService.Tag = "NeonGlow"

local LIGHT_NAME = "NeonGlow"
-- Lights sit ABOVE the surface they belong to, not inside it. A PointLight
-- parented straight to a floor part emits from that part's centre -- i.e. from
-- inside the geometry -- and the floor occludes most of its own light. An
-- attachment lifts the source clear so it actually spills onto the walls.
local LIGHT_HEIGHT = 3
local BRIGHTNESS = 2.4
-- Range scales with the part so a big room floor lights the whole room while a
-- small pad only pools around itself, clamped so neither extreme misbehaves.
local RANGE_MIN, RANGE_MAX = 14, 34

local function attach(part: Instance)
	if not part:IsA("BasePart") then
		return
	end
	if part:FindFirstChild(LIGHT_NAME, true) then
		return
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = LIGHT_NAME .. "Anchor"
	attachment.Position = Vector3.new(0, LIGHT_HEIGHT, 0)
	attachment.Parent = part

	local light = Instance.new("PointLight")
	light.Name = LIGHT_NAME
	-- Taking the colour from the part means a room's light always matches the
	-- floor a player is standing on, including the custom room's violet,
	-- without this service knowing anything about queue modes.
	light.Color = part.Color
	light.Brightness = BRIGHTNESS
	light.Range = math.clamp(math.max(part.Size.X, part.Size.Z) * 1.6, RANGE_MIN, RANGE_MAX)
	-- Shadows off deliberately. Shadow-casting local lights are the expensive
	-- kind, and these are decorative pools on flat floors where the shadows
	-- would add nothing a player would notice -- but would cost frames on the
	-- phones most of this audience plays on.
	light.Shadows = false
	light.Parent = attachment
end

local function detach(part: Instance)
	local anchor = part:FindFirstChild(LIGHT_NAME .. "Anchor")
	if anchor then
		anchor:Destroy()
	end
end

function NeonGlowService.Init()
	for _, part in CollectionService:GetTagged(NeonGlowService.Tag) do
		attach(part)
	end
	-- Queue rooms are built at runtime and re-built on every server start, so
	-- the tag frequently appears AFTER this service has initialised.
	CollectionService:GetInstanceAddedSignal(NeonGlowService.Tag):Connect(attach)
	CollectionService:GetInstanceRemovedSignal(NeonGlowService.Tag):Connect(detach)
end

return NeonGlowService
