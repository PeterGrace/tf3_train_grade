-- Pure weight sums (no api.* calls), so tests/weight_test.lua can run them in plain Lua.
global record PgraceTrainGradeWeight
	-- One cargo type on board.
	record CargoLoad
		count : integer
		-- kg per unit (CargoType.weight; unit confirmed by the probe)
		unitWeight : number
	end

	-- Tons.
	record Weight
		gross : number
		empty : number
		cargo : number
	end

	-- emptyKgs: each vehicle part's empty weight in kg.
	sum : function(emptyKgs : {number}, loads : {CargoLoad}) : Weight
end
