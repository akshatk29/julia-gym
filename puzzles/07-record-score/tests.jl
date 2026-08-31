case(Dict("ada" => 3), "grace", 5; expect = Dict("ada" => 3, "grace" => 5))
case(Dict{String,Int}(), "ada", 1; expect = Dict("ada" => 1))
hidden(Dict("ada" => 3), "ada", 9;   expect = Dict("ada" => 9))
hidden(Dict("a" => 1, "b" => 2), "c", 3; expect = Dict("a" => 1, "b" => 2, "c" => 3))
