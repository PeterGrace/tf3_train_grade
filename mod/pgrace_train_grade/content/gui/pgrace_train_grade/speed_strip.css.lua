local color_util = require "::/gui/main/color_util.tl"
local ssu = require "::/gui/main/stylesheetutil.lua"

function data()
	local result = { }

	local a = ssu.makeAdder(result)

	local colorDefault = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/default_colors.gres")).data
	local transparency = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/transparency.gres")).data

	-- Same box as the game's speed readout (entity_window.css.lua, R::SpeedIndicator), one per pill.
	a("R::PgraceTrainGradeStripEntry", {
		backgroundImage1 = {
			fileName = "::/gui/entity_window/icons/card_border.tga",
			horizontal = { 0, 8, 9, 17 },
			vertical = { 0, 8, 9, 17 },
		},
		backgroundColor1 = color_util.withTransparencyRaw(colorDefault.BaseVeryDark, transparency.Low),
		padding = { 1, 1, 1, 1 },
		margin = { 1, 0, 1, 0 },
	})
	a("R::PgraceTrainGradeStripEntry TextView", {
		margin = { 0, 2, 0, 2 },
	})
	a("R::PgraceTrainGradeStripEntry ImageView!leftmost-icon", {
		margin = { 0, 2, 0, 0 },
	})

	return result
end
