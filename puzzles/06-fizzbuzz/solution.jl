function fizzbuzz(n)
    out = String[]
    for i in 1:n
        if i % 15 == 0
            push!(out, "FizzBuzz")
        elseif i % 3 == 0
            push!(out, "Fizz")
        elseif i % 5 == 0
            push!(out, "Buzz")
        else
            push!(out, string(i))
        end
    end
    return out
end
