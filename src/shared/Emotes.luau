export type EmoteInfo = {
	Id: string,
	Name: string,
	-- Standard Unicode emoji glyphs rendered through a TextLabel -- nothing
	-- to own/moderate/infringe, same reasoning as Sounds.luau's engine-
	-- bundled rbxasset picks. Array order also doubles as the 1-8 keybind
	-- order (see client/Controllers/EmoteController.luau).
	Icon: string,
	RobuxProductId: number?, -- nil = free; placeholder ids need a real Developer Product (see PurchaseService)
}

local Emotes: { EmoteInfo } = {
	{ Id = "ThumbsUp", Name = "Thumbs Up", Icon = "👍" },
	{ Id = "Wave", Name = "Wave", Icon = "👋" },
	{ Id = "Heart", Name = "Heart", Icon = "❤️" },
	{ Id = "Cry", Name = "Cry", Icon = "😢" },
	{ Id = "Cool", Name = "Cool", Icon = "😎", RobuxProductId = 0 },
	{ Id = "LOL", Name = "LOL", Icon = "🤣", RobuxProductId = 0 }, -- the "hilarious one"
	{ Id = "Dance", Name = "Dance", Icon = "💃", RobuxProductId = 0 },
	{ Id = "Poop", Name = "Poop", Icon = "💩", RobuxProductId = 0 },
}

return Emotes
