--!strict

type Signal = {
	Connect: (self: Signal, callback: (...any) -> ()) -> any,
	Wait: (self: Signal) -> ...any,
	DisconnectAll: (self: Signal) -> (),
	Once: (self: Signal, callback: (...any) -> ()) -> any,
	Fire: (self: Signal, ...any) -> (),
}

local Listener = {}
Listener.__index = Listener

export type Listener = typeof(setmetatable(
	{} :: {
		_connection: any?,
		_callback: ((...any) -> ())?,
		_signal: Signal?,
	},
	Listener
))

--[=[
	@class Listener
	Manages a single active connection to a signal.
]=]
function Listener.new(signal: Signal): Listener
	local self = setmetatable({} :: any, Listener)
	self._connection = nil
	self._callback = nil
	self._signal = signal
	return self
end

--[=[
	Subscribes to the signal. If a subscription already exists, 
	it disconnects the old one first.
]=]
function Listener:Subscribe(callback: (...any) -> ())
	if self._connection then
		self:Unsubscribe()
	end

	self._callback = callback

	if self._signal then
		self._connection = self._signal:Connect(function(...)
			if self._callback then
				self._callback(...)
			end
		end)
	end
end

--[=[
	Disconnects the current active connection.
]=]
function Listener:Unsubscribe()
	if self._connection then
		-- Handles both RBXScriptConnection and custom Connection types
		if typeof(self._connection) == "RBXScriptConnection" then
			self._connection:Disconnect()
		else
			self._connection:Disconnect()
		end
		self._connection = nil
	end
	self._callback = nil
end

function Listener:IsConnected(): boolean
	return self._connection ~= nil
end

--[=[
	Cleans up the listener. Compatible with Trove.
]=]
function Listener:Destroy()
	self:Unsubscribe()
	self._signal = nil
	self._callback = nil
	setmetatable(self :: any, nil)
end

return Listener
