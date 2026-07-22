local Hash = {}

local FNV_OFFSET_BASIS = 0x811c9dc5
local FNV_PRIME = 0x01000193

function Hash.fnv1a(text: string): string
	local hash = FNV_OFFSET_BASIS
	for i = 1, #text do
		hash = bit32.bxor(hash, text:byte(i))
		hash = bit32.band(hash * FNV_PRIME, 0xFFFFFFFF)
	end
	return string.format("%08x", hash)
end

return Hash
