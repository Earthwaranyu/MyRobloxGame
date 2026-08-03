local Workspace = game:GetService("Workspace")

-- A translucent dome over the lobby plaza.
--
-- WHY THIS AND NOT WALLS. The problem being solved is "standing in the lobby
-- you can see the stages", and the first attempt at it built an opaque box
-- around every stage and the lobby. That was wrong twice over: the rooms
-- overlapped each other by up to 341x431 studs (the stages sit as little as 62
-- studs apart, and a room has to clear its own 150-stud scenery field), and it
-- was treating a symptom. The actual cause was view distance -- Weather's Sunny
-- preset ran FogEnd at 6000 studs and the lobby at 4000, across a stage cluster
-- only ~570 studs wide, so the game was explicitly told to draw everything.
--
-- Pulling fog in to ~430-620 per preset is what actually hides the stages from
-- each other, and it costs nothing: fog is already per-weather and per-player
-- (see WeatherService), so each racer gets their own themed horizon.
--
-- Fog cannot do one job though, and that is what this is for. Stage3's slab is
-- only 83 studs from the plaza rim -- far closer than any fog distance that
-- would leave the lobby feeling open rather than claustrophobic. A tinted dome
-- softens what little remains at that range, and reads as a deliberate piece of
-- the lobby rather than a barrier.
--
-- Deliberately NOT collidable and NOT queryable: it is atmosphere, not a cage.
-- Players never reach it (the plaza is 93 studs across inside a 200-stud dome),
-- and leaving it out of raycasts keeps it away from Blink and anything else
-- that probes geometry.
local LobbyDomeService = {}

local DOME_NAME = "LobbyDome"

-- Comfortably outside the plaza rim (93) and the lobby's own tree ring (~102),
-- so nothing the player walks among ever intersects it.
local DOME_RADIUS = 200

-- Glass rather than a flat colour: it catches the skybox and reads as a bright
-- enclosure instead of a grey lid. High transparency because the sky above is
-- the point -- WeatherService's whole Sunny/Night/Stormy split is visible
-- through it, and an opaque dome would throw that away exactly as a ceiling
-- would have.
local DOME_TRANSPARENCY = 0.72

function LobbyDomeService.Start()
	local lobby = Workspace:FindFirstChild("Lobby")
	local baseplate = Workspace:FindFirstChild("Baseplate") :: BasePart?
	if not lobby or not baseplate then
		return
	end

	local existing = Workspace:FindFirstChild(DOME_NAME)
	if existing then
		existing:Destroy()
	end

	-- A full sphere centred on the ground plane: the lower half is buried in
	-- the baseplate, leaving a dome above it. Cheaper and smoother than trying
	-- to build a hemisphere out of parts.
	local groundTop = baseplate.Position.Y + baseplate.Size.Y / 2
	local dome = Instance.new("Part")
	dome.Name = DOME_NAME
	dome.Shape = Enum.PartType.Ball
	dome.Size = Vector3.new(DOME_RADIUS * 2, DOME_RADIUS * 2, DOME_RADIUS * 2)
	dome.Position = Vector3.new(0, groundTop, 0)
	dome.Anchored = true
	dome.CanCollide = false
	dome.CanQuery = false
	dome.CanTouch = false
	dome.CastShadow = false
	dome.Material = Enum.Material.Glass
	dome.Transparency = DOME_TRANSPARENCY
	dome.Color = Color3.fromRGB(196, 224, 246)
	dome.Parent = Workspace
end

return LobbyDomeService
