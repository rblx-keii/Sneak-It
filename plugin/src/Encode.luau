local Encode = {}

local function encodeUDim(v: UDim): { number }
	return { v.Scale, v.Offset }
end

local function encodeColor3(v: Color3): { number }
	return { v.R, v.G, v.B }
end

-- Encodes a property value, or returns nil if the type is unsupported.
function Encode.property(value: any): any
	local t = typeof(value)

	if t == "boolean" or t == "number" or t == "string" then
		return value
	elseif t == "EnumItem" then
		return value.Name
	elseif t == "Color3" then
		return encodeColor3(value)
	elseif t == "Vector2" then
		return { value.X, value.Y }
	elseif t == "Vector3" then
		return { value.X, value.Y, value.Z }
	elseif t == "CFrame" then
		return { value:GetComponents() }
	elseif t == "Font" then
		return {
			family = value.Family,
			weight = value.Weight.Name,
			style = value.Style.Name,
		}
	elseif t == "UDim" then
		return { UDim = encodeUDim(value) }
	elseif t == "UDim2" then
		return { UDim2 = { encodeUDim(value.X), encodeUDim(value.Y) } }
	elseif t == "Rect" then
		return { Rect = { { value.Min.X, value.Min.Y }, { value.Max.X, value.Max.Y } } }
	elseif t == "NumberRange" then
		return { NumberRange = { value.Min, value.Max } }
	elseif t == "BrickColor" then
		return { BrickColor = value.Number }
	elseif t == "NumberSequence" then
		local keypoints = {}
		for _, kp in value.Keypoints do
			table.insert(keypoints, { time = kp.Time, value = kp.Value, envelope = kp.Envelope })
		end
		return { NumberSequence = { keypoints = keypoints } }
	elseif t == "ColorSequence" then
		local keypoints = {}
		for _, kp in value.Keypoints do
			table.insert(keypoints, { time = kp.Time, color = encodeColor3(kp.Value) })
		end
		return { ColorSequence = { keypoints = keypoints } }
	end

	return nil
end

-- Encodes an attribute value into the explicit { TypeName = value } form
-- required inside the Attributes map, or returns nil if unsupported.
function Encode.attribute(value: any): any
	local t = typeof(value)

	if t == "boolean" then
		return { Bool = value }
	elseif t == "number" then
		return { Float64 = value }
	elseif t == "string" then
		return { String = value }
	elseif t == "Color3" then
		return { Color3 = encodeColor3(value) }
	elseif t == "Vector2" then
		return { Vector2 = { value.X, value.Y } }
	elseif t == "Vector3" then
		return { Vector3 = { value.X, value.Y, value.Z } }
	elseif t == "CFrame" then
		return { CFrame = { value:GetComponents() } }
	elseif t == "UDim" then
		return { UDim = encodeUDim(value) }
	elseif t == "UDim2" then
		return { UDim2 = { encodeUDim(value.X), encodeUDim(value.Y) } }
	elseif t == "Rect" then
		return { Rect = { { value.Min.X, value.Min.Y }, { value.Max.X, value.Max.Y } } }
	elseif t == "NumberRange" then
		return { NumberRange = { value.Min, value.Max } }
	elseif t == "BrickColor" then
		return { BrickColor = value.Number }
	elseif t == "Font" then
		return { Font = { family = value.Family, weight = value.Weight.Name, style = value.Style.Name } }
	elseif t == "NumberSequence" or t == "ColorSequence" then
		return Encode.property(value)
	end

	return nil
end

return Encode
