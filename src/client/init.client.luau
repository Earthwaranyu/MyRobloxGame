local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Loader = require(Shared.Loader)
local Localization = require(script.Localization)

-- Before the controllers, so every label they build at startup is registered
-- with a translator request already in flight (see Localization).
Localization.Init()

Loader.LoadAll(script.Controllers)
