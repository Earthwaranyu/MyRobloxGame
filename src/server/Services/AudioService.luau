local SoundService = game:GetService("SoundService")

-- Two SoundGroups every Sound in the game routes through -- whether created
-- client-side for local UI/ambience (Sounds.luau, Ambience.luau) or
-- server-side for a shared/replicated effect (AbilityService's dash whoosh)
-- -- so Settings' volume controls can scale a whole category from one place.
-- SoundGroup.Volume is a normal property a client can locally override for
-- just their own hearing, which is exactly what makes this work correctly
-- even for the dash sound: each player gets their own volume preference for
-- a Sound instance the server/another player actually created.
local AudioService = {}

local function getOrCreateGroup(name: string): SoundGroup
	local group = SoundService:FindFirstChild(name)
	if not group then
		group = Instance.new("SoundGroup")
		group.Name = name
		group.Parent = SoundService
	end
	return group :: SoundGroup
end

function AudioService.Init()
	getOrCreateGroup("Music")
	getOrCreateGroup("SFX")
end

return AudioService
