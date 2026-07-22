--|| Services

--|| References

--|| Variables

--|| Constants


--|| Types
export type ItemModule = {
	properties: { [string]: any },
	usable: boolean,
	Use: ((...any) -> ())?,
}

--|| MAIN ||--
local ItemsConfig = {}

ItemsConfig.Items = {} :: { [string]: ItemModule }

-- [[ Setup ]] --
for _, itemModule in script:GetChildren() do
	local success, config = pcall(require, itemModule)
	if not success then
		warn(`[ItemsConfig] Failed to load item "{itemModule.Name}"! {config}`)
		continue
	end
	
	ItemsConfig.Items[itemModule.Name:gsub(" ", "")] = config
end

-- [[ Public Functions ]] --

-- Returns true if the item exists in the config and has a usable Use() function.
function ItemsConfig.IsItemUsable(itemName: string): boolean
	local item = ItemsConfig.Items[itemName:gsub(" ", "")]
	if not item then return false end

	return item.usable == true and item.Use ~= nil
end

-- Returns the item module, or nil if not registered.
function ItemsConfig.GetItem(itemName: string): ItemModule?
	return ItemsConfig.Items[itemName:gsub(" ", "")]
end

return ItemsConfig