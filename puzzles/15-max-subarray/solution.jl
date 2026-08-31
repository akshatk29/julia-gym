function max_subarray(v)
    isempty(v) && return nothing
    best = cur = v[1]
    for i in 2:length(v)
        cur = max(v[i], cur + v[i])
        best = max(best, cur)
    end
    return best
end
