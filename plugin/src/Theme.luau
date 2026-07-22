local Theme = {}

Theme.Color = {
	Bg = Color3.fromRGB(22, 22, 27),
	Card = Color3.fromRGB(34, 34, 41),
	Input = Color3.fromRGB(43, 43, 52),
	InputHover = Color3.fromRGB(52, 52, 62),
	Border = Color3.fromRGB(52, 52, 61),
	Text = Color3.fromRGB(240, 240, 245),
	TextDim = Color3.fromRGB(150, 150, 163),
	TextFaint = Color3.fromRGB(100, 100, 113),
	Accent = Color3.fromRGB(124, 108, 235),
	AccentLight = Color3.fromRGB(150, 137, 245),
	AccentDark = Color3.fromRGB(103, 88, 214),
	Error = Color3.fromRGB(224, 108, 100),
	-- Pure white, for text sitting directly on the accent gradient (the one
	-- primary call-to-action) — Text itself is a near-white tuned for the
	-- dark Card/Input backgrounds, not for use over a saturated fill.
	OnAccent = Color3.fromRGB(255, 255, 255),
}

Theme.Radius = {
	Card = UDim.new(0, 10),
	Input = UDim.new(0, 8),
	Pill = UDim.new(0, 6),
	Check = UDim.new(0, 4),
}

Theme.Font = {
	Title = Enum.Font.GothamBlack,
	Bold = Enum.Font.GothamBold,
	Medium = Enum.Font.GothamMedium,
	Regular = Enum.Font.Gotham,
	Italic = Font.new(Font.fromEnum(Enum.Font.Gotham).Family, Enum.FontWeight.Regular, Enum.FontStyle.Italic),
}

function Theme.Round(instance: Instance, radius: UDim)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = radius
	corner.Parent = instance
end

function Theme.Stroke(instance: Instance, color: Color3?, thickness: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color or Theme.Color.Border
	stroke.Thickness = thickness or 1
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = instance
	return stroke
end

-- Two-stop vertical gradient, used sparingly on the one primary call-to-action.
function Theme.Gradient(instance: Instance, top: Color3, bottom: Color3)
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(top, bottom)
	gradient.Rotation = 90
	gradient.Parent = instance
	return gradient
end

function Theme.Hover(button: GuiButton, baseColor: Color3, hoverColor: Color3)
	button.MouseEnter:Connect(function()
		button.BackgroundColor3 = hoverColor
	end)
	button.MouseLeave:Connect(function()
		button.BackgroundColor3 = baseColor
	end)
end

return Theme
