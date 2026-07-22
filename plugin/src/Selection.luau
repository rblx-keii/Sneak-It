local SETTING_KEY = "MapifySelection"

local Selection = {}

local selected: { [string]: boolean } = {}

local function load()
	local ok, saved = pcall(function()
		return plugin:GetSetting(SETTING_KEY)
	end)
	if ok and typeof(saved) == "table" then
		for name, value in saved :: { [string]: boolean } do
			if typeof(name) == "string" and typeof(value) == "boolean" then
				selected[name] = value
			end
		end
	end
end

local function save()
	pcall(function()
		plugin:SetSetting(SETTING_KEY, selected)
	end)
end

load()

-- Defaults an unseen name to `true` (checked) the first time it's observed.
function Selection.Get(name: string): boolean
	local value = selected[name]
	if value == nil then
		selected[name] = true
		save()
		return true
	end
	return value
end

function Selection.Set(name: string, value: boolean)
	if selected[name] == value then
		return
	end
	selected[name] = value
	save()
end

function Selection.Toggle(name: string)
	Selection.Set(name, not Selection.Get(name))
end

function Selection.SetAll(names: { string }, value: boolean)
	for _, name in names do
		selected[name] = value
	end
	save()
end

function Selection.IsAllSelected(names: { string }): boolean
	if #names == 0 then
		return false
	end
	for _, name in names do
		if not Selection.Get(name) then
			return false
		end
	end
	return true
end

return Selection
