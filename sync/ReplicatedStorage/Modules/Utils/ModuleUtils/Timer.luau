--!strict

local RunService = game:GetService("RunService")

-- Assumes Signal is in the same folder as Timer
local Signal = require(script.Parent.Signal)

type CallbackFn = () -> nil
type TimeFn = () -> number

--[=[
	@class Timer
	A high-performance Timer class with Pause/Resume support and drift-correction.
]=]
local Timer = {}
Timer.__index = Timer

export type Timer = typeof(setmetatable(
	{} :: {
		Interval: number,
		UpdateSignal: RBXScriptSignal,
		TimeFunction: () -> number,
		AllowDrift: boolean,
		Tick: Signal.Signal<>,

		_runHandle: RBXScriptConnection?,
		_remainingTime: number?,
		_paused: boolean,
	},
	Timer
))

--[=[
	Creates a new timer instance.
]=]
function Timer.new(interval: number): Timer
	assert(type(interval) == "number", "Interval must be a number")
	assert(interval >= 0, "Interval must be >= 0")

	local self = setmetatable({}, Timer)

	self._runHandle = nil
	self._remainingTime = nil
	self._paused = false

	self.Interval = interval
	self.UpdateSignal = RunService.Heartbeat
	self.TimeFunction = os.clock -- os.clock is generally more precise for timers
	self.AllowDrift = true
	self.Tick = Signal.new()

	return self
end

--[=[
	Simplified one-liner for quick tasks.
]=]
function Timer.simple(
	interval: number,
	callback: CallbackFn,
	startNow: boolean?,
	updateSignal: RBXScriptSignal?,
	timeFn: TimeFn?
)
	local update = updateSignal or RunService.Heartbeat
	local t = timeFn or os.clock
	local nextTick = t() + interval

	if startNow then
		task.defer(callback)
	end

	return update:Connect(function()
		local now = t()
		if now >= nextTick then
			nextTick = now + interval
			task.defer(callback)
		end
	end)
end

function Timer.is(obj: any): boolean
	return type(obj) == "table" and getmetatable(obj) == Timer
end

function Timer._startTimer(self: Timer)
	local t = self.TimeFunction
	-- Resume with remaining time if paused, otherwise start fresh
	local nextTick = t() + (self._remainingTime or self.Interval)

	self._remainingTime = nil
	self._paused = false

	self._runHandle = self.UpdateSignal:Connect(function()
		local now = t()
		if now >= nextTick then
			nextTick = now + self.Interval
			self.Tick:Fire()
		end
	end)
end

function Timer._startTimerNoDrift(self: Timer)
	assert(self.Interval > 0, "Interval must be > 0 for NoDrift")

	local t = self.TimeFunction
	local start = t()
	-- If resuming, offset the start time to maintain the grid
	if self._remainingTime then
		start = t() - (self.Interval - self._remainingTime)
	end

	self._remainingTime = nil
	self._paused = false

	local n = 1
	local nextTick = start + self.Interval

	self._runHandle = self.UpdateSignal:Connect(function()
		local now = t()
		while now >= nextTick do
			n += 1
			nextTick = start + (self.Interval * n)
			self.Tick:Fire()
		end
	end)
end

--[=[
	Starts or Resumes the timer.
]=]
function Timer.Start(self: Timer)
	if self._runHandle then
		return
	end

	if self.AllowDrift then
		self:_startTimer()
	else
		self:_startTimerNoDrift()
	end
end

--[=[
	Fires a tick immediately and starts the timer.
]=]
function Timer.StartNow(self: Timer)
	if self._runHandle then
		return
	end
	self.Tick:Fire()
	self:Start()
end

--[=[
	Pauses the timer and stores the remaining time until the next tick.
]=]
function Timer.Pause(self: Timer)
	if not self._runHandle or self._paused then
		return
	end

	self._paused = true
	self:Stop()
end

--[=[
	Stops the timer and resets the progress.
]=]
function Timer.Stop(self: Timer)
	if not self._runHandle then
		return
	end

	-- If we aren't pausing, clear the remaining time
	if not self._paused then
		self._remainingTime = nil
	end

	self._runHandle:Disconnect()
	self._runHandle = nil
end

--[=[
	Returns whether the timer is active.
]=]
function Timer.IsRunning(self: Timer): boolean
	return self._runHandle ~= nil
end

--[=[
	Cleans up signals and stops connections.
]=]
function Timer.Destroy(self: Timer)
	self:Stop()
	self.Tick:DisconnectAll()
end

return Timer
