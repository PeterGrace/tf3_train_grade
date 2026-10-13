local grade : PgraceTrainGradeGrade = {}

local type Segment = PgraceTrainGradeGrade.Segment

local FLAT = 0.0005   -- |grade| below this shows as 0.0%
local STEEP = 0.02    -- 2% and up gets the steep arrow
local ICON_BASE = "::/gui/construction/build_control/symbol_slope_"

function grade.averageGrade(segments : {Segment}, frontT : number, vehicleLength : number) : number
	if #segments == 0 then
		return nil
	end
	local zFront = segments[1].heightAt(frontT)
	local remaining = vehicleLength
	local covered = 0.0
	local zBack = zFront
	for i, seg in ipairs(segments) do
		-- the travel-wise end of this segment's part behind the front, in t
		local tEnd : number
		if i == 1 then
			tEnd = frontT
		elseif seg.reversed then
			tEnd = 0.0
		else
			tEnd = 1.0
		end
		-- metres of this segment behind tEnd (walking against the direction of travel)
		local available : number
		if seg.reversed then
			available = (1.0 - tEnd) * seg.length
		else
			available = tEnd * seg.length
		end
		local step = math.min(available, remaining)
		local tBack : number
		if seg.length <= 0 then
			tBack = tEnd
		elseif seg.reversed then
			tBack = tEnd + step / seg.length
		else
			tBack = tEnd - step / seg.length
		end
		zBack = seg.heightAt(tBack)
		covered = covered + step
		remaining = remaining - step
		if remaining <= 0 then
			break
		end
	end
	if covered < 1.0 then
		return nil
	end
	return (zFront - zBack) / covered
end

function grade.formatGrade(g : number) : string
	if g == nil then
		return "—"
	end
	if math.abs(g) < FLAT then
		return "0.0%"
	end
	return string.format("%+.1f%%", g * 100)
end

function grade.iconFor(g : number) : string
	local level = 0
	if g ~= nil and math.abs(g) >= FLAT then
		level = math.abs(g) >= STEEP and 2 or 1
		if g < 0 then
			level = -level
		end
	end
	return ICON_BASE .. tostring(level) .. "_20.tga"
end

return grade
