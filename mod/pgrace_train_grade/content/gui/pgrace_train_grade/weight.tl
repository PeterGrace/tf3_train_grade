local weight : PgraceTrainGradeWeight = {}

local KG_PER_TON = 1000

function weight.sum(emptyKgs : {number}, loads : {PgraceTrainGradeWeight.CargoLoad}) : PgraceTrainGradeWeight.Weight
	local emptyKg = 0.0
	for _, kg in ipairs(emptyKgs) do
		emptyKg = emptyKg + kg
	end
	local cargoKg = 0.0
	for _, load in ipairs(loads) do
		cargoKg = cargoKg + load.count * load.unitWeight
	end
	local empty = emptyKg / KG_PER_TON
	local cargo = cargoKg / KG_PER_TON
	return { gross = empty + cargo, empty = empty, cargo = cargo }
end

return weight
