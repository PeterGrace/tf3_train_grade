local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl" as EngineReactUtil
local entity_window_util = ug_require "::/gui/entity_window/entity_window_util.tl" as EntityWindowUtil
local gui_react_util = ug_require "::/gui/main/gui_react_util.tl" as GuiReactUtil
local lang_util = ug_require "::/scripts/lang_util.tl" as LangUtil
local grade = ug_require "pgrace_train_grade::/gui/pgrace_train_grade/grade.tl" as PgraceTrainGradeGrade
local vehicle_data = ug_require "pgrace_train_grade::/gui/pgrace_train_grade/vehicle_data.tl" as PgraceTrainGradeVehicleData

local LOG_PREFIX = "[train_grade] "
local WEIGHT_ICON = "::/gui/line_vehicle_mgmt/icons/symbol_weight.tga"

local record StripState
	visible : boolean
	weightText : string
	weightTooltip : string
	gradeText : string
	gradeIcon : string
end

local HIDDEN : StripState = { visible = false, weightText = "", weightTooltip = "", gradeText = "", gradeIcon = grade.iconFor(nil) }

local record EntryParams
	visible : boolean
	icon : string
	text : string
	tooltip : string
end

-- Entities whose read failed; the error is logged once per entity, not on every poll.
-- Intentionally never pruned: it holds one boolean per entity whose read failed.
local reported : {Engine.Entity : boolean} = {}

-- One decimal in the player's number format (decimal comma in German, ...). The base GUI never calls
-- api.util.lang.formatNumber, so fall back to a plain "%.1f" if it's missing or fails.
local function formatOneDecimal(n : number) : string
	local ok, text = pcall(function() : string
		return api.util.lang.formatNumber(n, 1)
	end)
	if ok and text ~= nil then
		return text as string
	end
	return string.format("%.1f", n)
end

local function computeState(entity : Engine.Entity) : StripState
	local ok, readingOrError = pcall(function() : PgraceTrainGradeVehicleData.Reading
		return vehicle_data.read(entity)
	end)
	if not ok then
		if not reported[entity] then
			reported[entity] = true
			debugPrint(LOG_PREFIX .. "read failed for " .. tostring(entity) .. ": " .. tostring(readingOrError))
		end
		return HIDDEN
	end
	local reading = readingOrError as PgraceTrainGradeVehicleData.Reading
	if reading == nil then
		return HIDDEN
	end
	return {
		visible = true,
		weightText = api.util.formatWeight(reading.weight.gross),
		weightTooltip = lang_util.format(_("Empty {empty} · Cargo {cargo}"), {
			empty = api.util.formatWeight(reading.weight.empty),
			cargo = api.util.formatWeight(reading.weight.cargo),
		}),
		gradeText = grade.formatGrade(reading.grade, formatOneDecimal, _("{percent}%")),
		gradeIcon = grade.iconFor(reading.grade),
	}
end

-- One pill, built like a base SpeedIndicator entry; styled by speed_strip.css.lua.
local Entry = react.RegisterRecipe("PgraceTrainGradeStripEntry", function(params : EntryParams) : TreeNodeId
	if not params.visible then
		react.setStyleClasses("invisible")
	end
	return builtin.BoxLayout{
		child = builtin.Component{
			meta = { tooltip = params.tooltip, },
			layout = builtin.BoxLayout{
				orientation = builtin.type.Orientation.Horizontal,
				children = {
					builtin.ImageView{
						meta = { class = "leftmost-icon", },
						path = params.icon,
						scaling = builtin.type.ImageViewScaling.AutoFit,
					},
					gui_react_util.makeHorizontalSpacer(),
					builtin.TextView{
						meta = { class = "font-scale-body", },
						text = params.text,
					},
				},
			},
		},
	}
end)

-- Replaces entity_window_util.SpeedIndicator (vehicle and person windows). The original always renders, in the same
-- place in the tree, so its own state survives our pills showing and hiding.
local SpeedStrip = react.RegisterRecipe("PgraceTrainGradeSpeedStrip", function(entityId : Engine.Entity) : TreeNodeId
	local state = engine_react_util.useStepStateTimer(function() : StripState
		return computeState(entityId)
	end, 0.25)
	local s = state:old()
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			Entry{ visible = s.visible, icon = WEIGHT_ICON, text = s.weightText, tooltip = s.weightTooltip },
			Entry{ visible = s.visible, icon = s.gradeIcon, text = s.gradeText, tooltip = "" },
			react.CallOriginalRecipe(entity_window_util.SpeedIndicator, entityId),
		},
	}
end)

local function doReplace(replacementApi : ReactReplacementApi)
	replacementApi.ReplaceRecipe(entity_window_util.SpeedIndicator, SpeedStrip)
end

debugPrint(LOG_PREFIX .. "script loaded")

return {
	doReplace = doReplace,
}
