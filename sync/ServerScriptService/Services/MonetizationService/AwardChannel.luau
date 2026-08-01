--[[
	AwardChannel.lua
	Internal utility — not part of the public API.

	Wraps Channel.Manager:InvokeAsync with a configurable timeout. All
	sub-modules call Shared.Invoke instead of touching Channel directly,
	so the timeout logic lives in exactly one place.

	Returns (granted: boolean):
	    true  — handler responded true within the timeout window
	    false — handler responded false, errored, or timed out
	            → caller should return NotProcessedYet so Roblox retries
--]]

--|| References
local Channel = require(script.Parent.Packages.Channel)
local Config  = require(script.Parent.Config)

--|| Constants
local TIMEOUT = Config.AwardTimeoutSeconds or 10

--|| MAIN ||--
local AwardChannel = {}

--- Invokes the named award channel with a timeout.
--- Runs the InvokeAsync in a background thread; the calling thread polls
--- until a result arrives or the timeout elapses.
---
--- @param channelName  string   One of Config.Channels.*
--- @param ...          any      Forwarded to the handler (player, productId, meta)
--- @return             boolean  true = granted, false = retry
function AwardChannel.Invoke(channelName: string, ...: any): boolean
	local granted = false
	local done = false
	local args = { ... }

	task.spawn(function()
		local ok, result = pcall(function()
			return Channel.Manager:InvokeAsync(channelName, table.unpack(args))
		end)

		granted = ok and result == true
		done = true
	end)

	local elapsed = 0
	while not done and elapsed < TIMEOUT do
		elapsed += task.wait()
	end

	if not done then
		warn(
			"[Monetization.AwardChannel] Timed out after",
			TIMEOUT,
			"seconds waiting for handler on channel:",
			channelName
		)
	end

	return granted
end

return AwardChannel