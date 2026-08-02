-- Translates on-screen copy through the player's own Translator.
--
-- WHY THIS EXISTS RATHER THAN JUST AutoLocalize: every GuiObject ships with
-- AutoLocalize = true, and Roblox does localize text authored in a place file
-- that way. It does NOT localize text a script assigns at runtime -- measured
-- on this published place, against the real LocalizationService.GameStrings
-- table, with the source locale deliberately set to something other than the
-- player's so a translation genuinely applied:
--
--   Translator:Translate(obj, "TRAIL SHOP")            -> "[[LOCALIZED]]"   works
--   TextLabel.Text = "TRAIL SHOP" -> .ContentText      -> "TRAIL SHOP"      no
--   ...with label.RootLocalizationTable set            -> "TRAIL SHOP"      no
--   ...with ScreenGui.RootLocalizationTable set        -> "TRAIL SHOP"      no
--
-- This whole HUD is built in code, so every string in it falls in that second
-- category. The Translator API is the path that actually works, and this module
-- is the single place it is used.
--
-- Costs nothing until translations exist: an entry with no value for the
-- player's locale (and any string missing from the table entirely) comes back
-- unchanged, confirmed rather than assumed.
local LocalizationService = game:GetService("LocalizationService")
local Players = game:GetService("Players")

local Localization = {}

local translator: Translator? = nil

-- The SOURCE string every localized object was last given.
--
-- Needed because the translator arrives asynchronously: GetTranslatorForPlayerAsync
-- yields, and the HUD is built at startup, so the first pass of every label
-- happens before there is anything to translate with. Re-applying from the
-- source (never from the object's current Text, which may already be a
-- translation) is what makes that safe to run twice.
--
-- Weak-keyed so a destroyed label cannot be kept alive by this table -- the same
-- rule Widgets' own per-button registries follow.
local sources: { [Instance]: string } = setmetatable({}, { __mode = "k" }) :: any

local function translate(object: Instance, source: string): string
	if not translator then
		return source
	end
	-- Translate throws on a malformed entry rather than returning the source, and
	-- a localization fault must never take a HUD label down with it.
	local ok, result = pcall(function()
		return (translator :: Translator):Translate(object, source)
	end)
	return if ok and typeof(result) == "string" and result ~= "" then result else source
end

-- Sets `object.Text` to the localized form of `source`, and remembers the pairing
-- so it can be redone once the translator resolves.
function Localization.Apply(object: TextLabel | TextButton, source: string)
	sources[object] = source
	object.Text = translate(object, source)
end

-- The localized form of a string, for a caller that is not writing it straight
-- onto a TextLabel (a formatted line assembled from parts, for instance).
function Localization.Text(source: string): string
	return translate(Players.LocalPlayer, source)
end

-- What we last wrote onto an object, so the write can be told apart from a
-- caller's. A flag would not survive the round trip: property-changed signals
-- fire DEFERRED in this engine, so any flag set around the assignment is already
-- back to false by the time the signal arrives -- the same trap Widgets.Button's
-- Text sync documents, solved the same way, by comparing values.
local lastWritten: { [Instance]: string } = setmetatable({}, { __mode = "k" }) :: any

-- Keeps a label localized for its whole life, not just at construction.
--
-- Most copy in this HUD is written more than once: the spectate line, the wave
-- clock, every score and placement readout. Those assignments happen at ~74 call
-- sites across the controllers and go straight onto the instance, so localizing
-- only in the constructor would leave all of them in the source language. One
-- hook per label covers every future write instead.
function Localization.Bind(object: TextLabel | TextButton)
	object:GetPropertyChangedSignal("Text"):Connect(function()
		local current = object.Text
		if current == lastWritten[object] then
			-- Our own translation echoing back.
			return
		end
		sources[object] = current
		local translated = translate(object, current)
		if translated ~= current then
			lastWritten[object] = translated
			object.Text = translated
		end
	end)
end

function Localization.Init()
	task.spawn(function()
		local ok, result = pcall(function()
			return LocalizationService:GetTranslatorForPlayerAsync(Players.LocalPlayer)
		end)
		if not ok or not result then
			-- No translator is a perfectly normal outcome (no cloud table yet).
			-- Everything already reads as its source string, so there is nothing
			-- to undo and nothing worth warning about once per session.
			return
		end
		translator = result

		-- Re-run every label built before this point. Without it the entire
		-- startup HUD -- which is nearly all of it -- would stay in the source
		-- language for the whole session.
		for object, source in sources do
			if object.Parent then
				(object :: any).Text = translate(object, source)
			end
		end
	end)
end

return Localization
