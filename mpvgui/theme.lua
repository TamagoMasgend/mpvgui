-- Visual constants: ASS colours (BGR!), opacities and sizes.
--
-- Sizes are given in reference units for a 1080p-tall OSD.  layout.lua scales
-- them by (osd_height / 1080) * user_scale, so a 960x540 window renders the
-- bar exactly half as large.
--
-- ASS colours are written as &HBBGGRR&, i.e. blue first.  The digits stored
-- here are the BBGGRR part only (no &H / &), render.lua wraps them.

local theme = {}

theme.ref_height = 1080

theme.color = {
	bar = "1A1A1A", -- #1A1A1A
	button = "2E2E2E", -- #2E2E2E
	track = "3A3A3A", -- #3A3A3A
	buffered = "6E6E6E", -- #6E6E6E
	played = "FFC14F", -- #4FC1FF (accent, blue)
	knob = "F2F2F2", -- #F2F2F2
	text = "F2F2F2",
	text_dim = "A0A0A0",
	accent = "FFC14F", -- #4FC1FF
	hover = "FFC14F",
	panel = "0D0D0D",
	panel_row = "453B2F", -- #2F3B45
	tooltip = "000000",
	muted = "808080",
}

-- Alpha is ASS style: 00 = opaque, FF = fully transparent.
theme.alpha = {
	bar = "1E", -- ~88% opaque
	button = "C0",
	panel = "14",
	tooltip = "30",
	hover = "58",
}

-- Reference sizes at 1080p (multiplied by the layout scale).
theme.bar_height = 76
theme.margin = 14
theme.radius = 18
theme.btn_radius = 12
theme.btn = 52
theme.speed_w = 76
theme.time_w = 200
theme.vol_w = 150
theme.vol_track = 8
theme.seek_track = 8
theme.knob = 14
theme.knob_hover = 18
theme.icon = 26
theme.panel_ratio = 0.35
theme.panel_max = 640
theme.panel_pad = 16
theme.header_h = 52
theme.row_h = 96
theme.title_max_ratio = 0.6

theme.font = {
	label = 28,
	small = 24,
	title = 26,
	row = 26,
	tooltip = 24,
}

return theme
