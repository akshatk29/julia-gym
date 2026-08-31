function group_by_initial(words)
    groups = Dict{Char,Vector{String}}()
    for w in words
        isempty(w) && continue
        push!(get!(groups, w[1], String[]), String(w))
    end
    return groups
end
