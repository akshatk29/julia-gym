function two_sum(nums, target)
    seen = Dict{eltype(nums),Int}()
    for (i, v) in enumerate(nums)
        j = get(seen, target - v, 0)
        j != 0 && return (j, i)
        seen[v] = i
    end
    return nothing
end
