--|| Services
local ContextActionService = game:GetService("ContextActionService")

--|| Types
export type ActionConfig = {
	name: string,
	keys: { Enum.KeyCode | Enum.UserInputType },
	priority: number,
	callback: (name: string, state: Enum.UserInputState, input: InputObject) -> Enum.ContextActionResult?,
}

export type ActionHandle = {
	name: string,
	Unbind: (self: ActionHandle) -> (),
	SetEnabled: (self: ActionHandle, state: boolean) -> (),
	UpdatePriority: (self: ActionHandle, priority: number) -> (),
	UpdateKeys: (self: ActionHandle, keys: { Enum.KeyCode | Enum.UserInputType }) -> (),
}

type ActionEntry = {
	config: ActionConfig,
	enabled: boolean,
	handle: ActionHandle,
}

--|| Variables
local _registry: { [string]: ActionEntry } = {}

--|| MAIN ||--
local InputController = {}

-- [[ Private ]] --
local function UnpackKeys(keys: { Enum.KeyCode | Enum.UserInputType }): { any }
	local unpacked = {}
	for _, key in keys do
		table.insert(unpacked, key)
	end
	return unpacked
end

local function BuildCASCallback(entry: ActionEntry): (string, Enum.UserInputState, InputObject) -> Enum.ContextActionResult
	return function(name: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
		if not entry.enabled then
			return Enum.ContextActionResult.Pass
		end

		local result = entry.config.callback(name, state, input)
		return result or Enum.ContextActionResult.Sink
	end
end

local function RegisterWithCAS(entry: ActionEntry)
	local keys = UnpackKeys(entry.config.keys)

	ContextActionService:BindActionAtPriority(
		entry.config.name,
		BuildCASCallback(entry),
		false, -- no auto touch button
		entry.config.priority,
		table.unpack(keys)
	)
end

local function UnregisterFromCAS(name: string)
	ContextActionService:UnbindAction(name)
end

-- [[ ActionHandle Methods ]] --
local ActionHandle = {}
ActionHandle.__index = ActionHandle

function ActionHandle:Unbind()
	InputController.UnbindAction(self.name)
end

function ActionHandle:SetEnabled(state: boolean)
	local entry = _registry[self.name]
	if not entry then return end

	entry.enabled = state
	-- Re-register to rebuild callback closure with updated enabled state
	UnregisterFromCAS(self.name)
	RegisterWithCAS(entry)
end

function ActionHandle:UpdatePriority(priority: number)
	local entry = _registry[self.name]
	if not entry then return end

	entry.config.priority = priority
	UnregisterFromCAS(self.name)
	RegisterWithCAS(entry)
end

function ActionHandle:UpdateKeys(keys: { Enum.KeyCode | Enum.UserInputType })
	local entry = _registry[self.name]
	if not entry then return end

	entry.config.keys = keys
	UnregisterFromCAS(self.name)
	RegisterWithCAS(entry)
end

-- [[ Public ]] --
function InputController.BindAction(config: ActionConfig): ActionHandle
	-- Auto-unbind if name already registered
	if _registry[config.name] then
		InputController.UnbindAction(config.name)
	end

	local handle = setmetatable({
		name = config.name,
	}, ActionHandle) :: ActionHandle

	local entry: ActionEntry = {
		config = config,
		enabled = true,
		handle = handle,
	}

	_registry[config.name] = entry
	RegisterWithCAS(entry)

	return handle
end

function InputController.UnbindAction(name: string)
	if not _registry[name] then return end

	UnregisterFromCAS(name)
	_registry[name] = nil
end

function InputController.IsActionBound(name: string): boolean
	return _registry[name] ~= nil
end

return InputController