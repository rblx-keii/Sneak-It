--|| Types
type HandlerCallback = (...any) -> ...any

export type Channel = {
	_name: string,
	_handler: HandlerCallback?,
	SetHandler: (self: Channel, callback: HandlerCallback) -> (),
	Invoke: (self: Channel, ...any) -> ...any,
	InvokeAsync: (self: Channel, ...any) -> ...any,
	Clear: (self: Channel) -> (),
	Destroy: (self: Channel) -> (),
}

export type ChannelManager = {
	_registry: { [string]: Channel },
	SetHandler: (self: ChannelManager, name: string, callback: HandlerCallback) -> (),
	Invoke: (self: ChannelManager, name: string, ...any) -> ...any,
	InvokeAsync: (self: ChannelManager, name: string, ...any) -> ...any,
	GetChannel: (self: ChannelManager, name: string) -> Channel?,
}

--|| MAIN ||--
local Channel = {}
Channel.__index = Channel

--|| Manager ||--
local Manager: ChannelManager = {} :: ChannelManager
Manager._registry = {}

-- [[ Channel Instance Methods ]] --

--- Registers the one handler for this Channel.
--- Warns if a handler is being overwritten.
function Channel:SetHandler(callback: HandlerCallback)
	if self._handler then
		warn("[Channel] Handler for \"" .. self._name .. "\" is being overwritten!")
	end
	self._handler = callback
end

--- Calls the registered handler and returns its result.
--- Errors loudly if no handler has been set, and wraps the call
--- in pcall to give a clear error pointing to the channel name.
function Channel:Invoke(...: any): ...any
	if not self._handler then
		error("[Channel] No handler set for \"" .. self._name .. "\". Did you forget to call :SetHandler()?", 2)
	end

	local results = { pcall(self._handler, ...) }
	local success = table.remove(results, 1)

	if not success then
		error("[Channel] Exception in handler for \"" .. self._name .. "\": " .. tostring(results[1]), 2)
	end

	return table.unpack(results)
end

--- Yields until a handler is registered, then invokes it.
--- Use this when script execution order is not guaranteed.
--- Warns every 10 seconds if the handler is still not registered.
function Channel:InvokeAsync(...: any): ...any
	local elapsed = 0

	while not self._handler do
		local dt = task.wait()
		elapsed += dt

		if elapsed >= 10 then
			warn(`[Channel] Handler still not set for "{self._name}" after 10 seconds.`)
			elapsed = 0
		end
	end

	return self:Invoke(...)
end

--- Unregisters the handler. Useful for cleanup.
function Channel:Clear()
	self._handler = nil
end

--- Clears the handler and removes this Channel from the Manager registry.
--- Call this when the Channel is no longer needed (e.g. round cleanup).
function Channel:Destroy()
	self:Clear()
	Manager._registry[self._name] = nil
	setmetatable(self, nil)
end

-- [[ Manager Methods ]] --

--- Sets a handler on a Channel by name.
--- Auto-creates the Channel if it doesn't exist yet.
function Manager:SetHandler(name: string, callback: HandlerCallback)
	local channel = self._registry[name]
	if not channel then
		channel = Channel.new(name)
		self._registry[name] = channel
	end
	channel:SetHandler(callback)
end

--- Invokes a Channel by name and returns the result.
--- Auto-creates the Channel if it doesn't exist yet.
function Manager:Invoke(name: string, ...: any): ...any
	local channel = self._registry[name] or Channel.new(name)
	return channel:Invoke(...)
end

--- Yields until the Channel has a handler, then invokes it.
--- Auto-creates the Channel if it doesn't exist yet.
function Manager:InvokeAsync(name: string, ...: any): ...any
	local channel = self._registry[name] or Channel.new(name)
	return channel:InvokeAsync(...)
end

--- Returns the raw Channel instance registered under a name.
function Manager:GetChannel(name: string): Channel?
	return self._registry[name]
end

-- [[ Constructor ]] --

--- Creates a new Channel instance and registers it under the given name.
function Channel.new(name: string): Channel
	assert(type(name) == "string" and #name > 0, "[Channel] Name must be a non-empty string.")

	if Manager._registry[name] then
		warn("[Channel] A Channel with the name \"" .. name .. "\" already exists. Returning existing instance.")
		return Manager._registry[name]
	end

	local self: Channel = setmetatable({
		_name = name,
		_handler = nil,
	}, Channel) :: any

	Manager._registry[name] = self

	return self
end

Channel.Manager = Manager

return Channel