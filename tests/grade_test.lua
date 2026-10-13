local t = ...
local grade = t.requireTl("gui/pgrace_train_grade/grade.tl")

-- A straight edge rising `rise` metres over `length` metres, starting at height z0.
local function edge(length, z0, rise, reversed)
	return {
		length = length,
		heightAt = function(u) return z0 + rise * u end,
		reversed = reversed or false,
	}
end

local function near(actual, expected, label)
	if actual == nil or math.abs(actual - expected) > 1e-9 then
		error(("%s: expected %s, got %s"):format(label or "near", tostring(expected), tostring(actual)), 2)
	end
end

t.test("averageGrade: flat track is 0", function()
	near(grade.averageGrade({ edge(500, 10, 0) }, 0.8, 200), 0)
end)

t.test("averageGrade: constant 2% on one edge", function()
	-- front at 400 m into a 500 m edge rising 10 m; the vehicle covers 200..400 m
	near(grade.averageGrade({ edge(500, 0, 10) }, 0.8, 200), 0.02)
end)

t.test("averageGrade: constant 2% across three edges", function()
	local segments = {
		edge(100, 4, 2),   -- front edge, 4 m..6 m; front at t = 0.5 (z = 5)
		edge(100, 2, 2),
		edge(100, 0, 2),
	}
	-- 50 m on the front edge, 100 m on the next, 50 m on the last: 200 m, back at z = 1
	near(grade.averageGrade(segments, 0.5, 200), 0.02)
end)

t.test("averageGrade: a crest split evenly averages about 0", function()
	local segments = {
		edge(100, 2, -2),  -- front edge going down from the crest (z 2 -> 0)
		edge(100, 0, 2),   -- the edge behind, climbing to the crest (z 0 -> 2)
	}
	-- front at the bottom of the descent (t = 1, z = 0), back at the start of the climb (z = 0)
	near(grade.averageGrade(segments, 1.0, 200), 0)
end)

t.test("averageGrade: a reversed edge flips the sign", function()
	-- The edge rises 10 m over 500 m in its own direction; travelling it backwards is a 2% descent.
	-- Front at t = 0.2 (100 m into the edge, so 400 m of it lie behind the front).
	near(grade.averageGrade({ edge(500, 0, 10, true) }, 0.2, 200), -0.02)
end)

t.test("averageGrade: a reversed edge behind the front", function()
	-- front edge rises 2 m over 100 m (front at z = 1); the edge behind is travelled backwards and, in its own
	-- direction, falls 2 m, so travelling it climbs. 50 m + 50 m: back at z = -1, rise 2 m over 100 m.
	near(grade.averageGrade({ edge(100, 0, 2), edge(100, 0, -2, true) }, 0.5, 100), 0.02)
end)

t.test("averageGrade: a zero-length edge is skipped", function()
	local segments = {
		edge(100, 4, 2),
		edge(0, 4, 0),     -- zero-length edge at the junction height
		edge(100, 2, 2),
		edge(100, 0, 2),
	}
	near(grade.averageGrade(segments, 0.5, 200), 0.02)
end)

t.test("averageGrade: a path shorter than the vehicle uses what it covers", function()
	-- front at t = 0.5 of a 100 m edge rising 2 m: only 50 m behind the front, 1 m of rise
	near(grade.averageGrade({ edge(100, 0, 2) }, 0.5, 300), 0.02)
end)

t.test("averageGrade: under 1 m covered is nil", function()
	t.eq(grade.averageGrade({ edge(100, 0, 2) }, 0.005, 300), nil)
	t.eq(grade.averageGrade({}, 0.5, 300), nil)
end)

t.test("formatGrade: signs, rounding, dead band, nil", function()
	t.eq(grade.formatGrade(0.018), "+1.8%")
	t.eq(grade.formatGrade(-0.004), "-0.4%")
	t.eq(grade.formatGrade(0.0004), "0.0%")
	t.eq(grade.formatGrade(-0.0004), "0.0%")
	t.eq(grade.formatGrade(0.03456), "+3.5%")
	t.eq(grade.formatGrade(nil), "—")
end)

t.test("iconFor: flat, gentle, steep, both ways", function()
	local base = "::/gui/construction/build_control/symbol_slope_"
	t.eq(grade.iconFor(nil), base .. "0_20.tga")
	t.eq(grade.iconFor(0.0004), base .. "0_20.tga")
	t.eq(grade.iconFor(0.01), base .. "1_20.tga")
	t.eq(grade.iconFor(0.025), base .. "2_20.tga")
	t.eq(grade.iconFor(-0.01), base .. "-1_20.tga")
	t.eq(grade.iconFor(-0.025), base .. "-2_20.tga")
end)
