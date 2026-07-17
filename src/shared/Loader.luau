local Loader = {}

function Loader.LoadAll(container: Instance)
	local modules = {}

	for _, child in container:GetChildren() do
		if child:IsA("ModuleScript") then
			local ok, result = pcall(require, child)
			if ok then
				table.insert(modules, result)
			else
				warn(("Failed to load %s: %s"):format(child:GetFullName(), tostring(result)))
			end
		end
	end

	for _, module in modules do
		if type(module) == "table" and type(module.Init) == "function" then
			module.Init()
		end
	end

	for _, module in modules do
		if type(module) == "table" and type(module.Start) == "function" then
			module.Start()
		end
	end

	return modules
end

return Loader
