export type SettingKind = "Slider" | "Button"

export type SettingEntry = {
	id: string,
	title: string,
	description: string,
	kind: SettingKind,
	settingKey: string?, -- Slider only
	min: number?, -- Slider only
	max: number?, -- Slider only
	buttonText: string?, -- Button only
	mobileOnly: boolean?,
}

local SettingsConfig: { SettingEntry } = {
	{
		id = "Music",
		title = "Music Volume",
		description = "Adjust background music volume.",
		kind = "Slider",
		settingKey = "music",
		min = 0,
		max = 100,
	},
	{
		id = "SFX",
		title = "SFX Volume",
		description = "Adjust sound effect volume.",
		kind = "Slider",
		settingKey = "sfx",
		min = 0,
		max = 100,
	},
	{
		id = "MobileControls",
		title = "Mobile Controls",
		description = "Customize your on-screen control layout.",
		kind = "Button",
		buttonText = "Edit",
	},
}

return SettingsConfig
