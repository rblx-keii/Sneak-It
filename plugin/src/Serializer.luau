local ApiDump = require(script.Parent.ApiDump)
local Encode = require(script.Parent.Encode)

local Serializer = {}

export type Entry = {
	kind: "dir" | "file",
	name: string?, -- dir name
	fileName: string?, -- file name (files only)
	content: string?, -- raw file content (scripts)
	json: any?, -- JSON file content (server pretty-prints)
	initScript: { fileName: string, content: string }?, -- dirs only
	metaJson: any?, -- dirs only -> init.meta.json
	children: { Entry }?,
}

local SCRIPT_SUFFIX: { [string]: string } = {
	LocalScript = ".client.luau",
	Script = ".server.luau",
	ModuleScript = ".luau",
}

local defaultInstanceCache: { [string]: Instance? } = {}
local warnedClasses: { [string]: boolean } = {}

local function getDefaultInstance(className: string): Instance?
	if defaultInstanceCache[className] == nil then
		local ok, inst = pcall(Instance.new, className)
		defaultInstanceCache[className] = if ok then inst else nil
	end
	return defaultInstanceCache[className]
end

-- Collects encoded, non-default properties (including Attributes) for an instance.
-- Returns nil when the table would be empty.
local function collectProperties(inst: Instance): { [string]: any }?
	local props: { [string]: any } = {}
	local count = 0

	local propertyList = ApiDump[inst.ClassName]
	if propertyList then
		local default = getDefaultInstance(inst.ClassName)
		for _, propName in propertyList do
			local ok, value = pcall(function()
				return (inst :: any)[propName]
			end)
			if not ok then
				continue
			end
			if default then
				local okDefault, defaultValue = pcall(function()
					return (default :: any)[propName]
				end)
				if okDefault and value == defaultValue then
					continue
				end
			end
			local encoded = Encode.property(value)
			if encoded ~= nil then
				props[propName] = encoded
				count += 1
			end
		end
	elseif not warnedClasses[inst.ClassName] then
		warnedClasses[inst.ClassName] = true
		warn(`[Mapify] Class "{inst.ClassName}" is not in ApiDump.luau — exporting without properties (rerun tools/generate-api-dump.mjs with it whitelisted)`)
	end

	local encodedAttributes: { [string]: any } = {}
	local attributeCount = 0
	for attrName, attrValue in inst:GetAttributes() do
		local encoded = Encode.attribute(attrValue)
		if encoded ~= nil then
			encodedAttributes[attrName] = encoded
			attributeCount += 1
		end
	end
	if attributeCount > 0 then
		props.Attributes = encodedAttributes
		count += 1
	end

	return if count > 0 then props else nil
end

-- Recursively builds { ClassName, Name?, Properties?, Children? } for inst.
-- Name is omitted at the root since the caller already knows it.
function Serializer.buildTree(inst: Instance, isRoot: boolean): any
	local node: { [string]: any } = { ClassName = inst.ClassName }
	if not isRoot then
		node.Name = inst.Name
	end

	local props = collectProperties(inst)
	if props then
		node.Properties = props
	end

	local children = {}
	for _, child in inst:GetChildren() do
		if child.Archivable then
			table.insert(children, Serializer.buildTree(child, false))
		end
	end
	if #children > 0 then
		node.Children = children
	end

	return node
end

-- ---------------------------------------------------------------------------
-- Entry tree (real Argon file layout)

local WINDOWS_RESERVED: { [string]: boolean } = {
	CON = true, PRN = true, AUX = true, NUL = true,
	COM1 = true, COM2 = true, COM3 = true, COM4 = true, COM5 = true,
	COM6 = true, COM7 = true, COM8 = true, COM9 = true,
	LPT1 = true, LPT2 = true, LPT3 = true, LPT4 = true, LPT5 = true,
	LPT6 = true, LPT7 = true, LPT8 = true, LPT9 = true,
}

local function sanitizeName(name: string): string
	local sanitized = name:gsub('[<>:"/\\|%?%*%c]', "_"):gsub("[%. ]+$", "")
	if sanitized == "" then
		sanitized = "_"
	end
	if WINDOWS_RESERVED[sanitized:upper()] then
		sanitized = "_" .. sanitized
	end
	return sanitized
end

local function subtreeHasScript(inst: Instance): boolean
	for _, descendant in inst:GetDescendants() do
		if SCRIPT_SUFFIX[descendant.ClassName] then
			return true
		end
	end
	return false
end

-- Reserves a unique (case-insensitive, Windows-safe) file/dir name among siblings.
local function reserveName(usedNames: { [string]: boolean }, inst: Instance): string
	local base = sanitizeName(inst.Name)
	local candidate = base
	local suffix = 1
	while usedNames[candidate:lower()] do
		suffix += 1
		candidate = `{base}{suffix}`
		if suffix == 2 then
			warn(`[Mapify] Duplicate sibling name "{inst.Name}" under {if inst.Parent then inst.Parent:GetFullName() else "?"} — exporting as "{candidate}"`)
		end
	end
	usedNames[candidate:lower()] = true
	return candidate
end

local function serializeInstance(inst: Instance, usedNames: { [string]: boolean }): Entry?
	if not inst.Archivable then
		return nil
	end

	local scriptSuffix = SCRIPT_SUFFIX[inst.ClassName]
	if scriptSuffix then
		local name = reserveName(usedNames, inst)
		local source = (inst :: any).Source :: string
		local props = collectProperties(inst)
		if #inst:GetChildren() == 0 then
			if props then
				return {
					kind = "dir",
					name = name,
					initScript = { fileName = "init" .. scriptSuffix, content = source },
					metaJson = { properties = props },
					children = {},
				}
			end
			return { kind = "file", fileName = name .. scriptSuffix, content = source }
		end
		local children = {}
		local childNames: { [string]: boolean } = { ["init"] = true }
		for _, child in inst:GetChildren() do
			local childEntry = serializeInstance(child, childNames)
			if childEntry then
				table.insert(children, childEntry)
			end
		end
		return {
			kind = "dir",
			name = name,
			initScript = { fileName = "init" .. scriptSuffix, content = source },
			metaJson = if props then { properties = props } else nil,
			children = children,
		}
	end

	if inst.ClassName == "Folder" or subtreeHasScript(inst) then
		local name = reserveName(usedNames, inst)
		local children = {}
		local childNames: { [string]: boolean } = { ["init"] = true }
		for _, child in inst:GetChildren() do
			local childEntry = serializeInstance(child, childNames)
			if childEntry then
				table.insert(children, childEntry)
			end
		end
		local props = collectProperties(inst)
		local metaJson = nil
		if inst.ClassName ~= "Folder" then
			metaJson = { className = inst.ClassName, properties = props }
		elseif props then
			metaJson = { properties = props }
		end
		return {
			kind = "dir",
			name = name,
			metaJson = metaJson,
			children = children,
		}
	end

	local name = reserveName(usedNames, inst)
	return {
		kind = "file",
		fileName = name .. ".model.json",
		json = Serializer.buildTree(inst, true),
	}
end

-- Serializes a list of top-level instances into filesystem Entry nodes,
-- 1:1 and in order with `instances` (skips non-Archivable with a nil hole).
-- A shared name-reservation table keeps top-level names unique too.
function Serializer.serialize(instances: { Instance }): { Entry? }
	local entries = {}
	local usedNames: { [string]: boolean } = {}
	for i, inst in instances do
		entries[i] = serializeInstance(inst, usedNames)
	end
	return entries
end

return Serializer
