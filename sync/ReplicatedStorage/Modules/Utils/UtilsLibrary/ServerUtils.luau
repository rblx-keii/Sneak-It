local ServerUtil = {}

--[[
	Returns true if the server is a User-Owned Private Server (VIP Server).
	Returns false if it is a Public Server or a Developer-Reserved Server.
]]
function ServerUtil.IsServerPrivate(): boolean
	if game.PrivateServerId ~= "" then
		-- If there is a PrivateServerId and an OwnerId > 0, it's a paid VIP server.
		if game.PrivateServerOwnerId > 0 then
			return true
		end
	end

	return false
end

return ServerUtil