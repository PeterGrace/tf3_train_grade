local t = ...
local weight = t.requireTl("gui/pgrace_train_grade/weight.tl")

t.test("sum: empty train has no cargo weight", function()
	local w = weight.sum({ 80000, 20000, 20000 }, {})
	t.eq(w.empty, 120, "empty")
	t.eq(w.cargo, 0, "cargo")
	t.eq(w.gross, 120, "gross")
end)

t.test("sum: mixed cargo adds up", function()
	local w = weight.sum({ 50000, 25000 }, {
		{ count = 30, unitWeight = 1000 },   -- 30 t
		{ count = 10, unitWeight = 500 },    -- 5 t
	})
	t.eq(w.empty, 75, "empty")
	t.eq(w.cargo, 35, "cargo")
	t.eq(w.gross, 110, "gross")
end)

t.test("sum: zero counts add nothing", function()
	local w = weight.sum({ 1000 }, { { count = 0, unitWeight = 1000 } })
	t.eq(w.cargo, 0, "cargo")
	t.eq(w.gross, 1, "gross")
end)
