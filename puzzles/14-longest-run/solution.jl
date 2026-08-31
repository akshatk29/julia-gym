function longest_run(v)
    isempty(v) && return 0
    best = cur = 1
    for i in 2:length(v)
        cur = v[i] == v[i-1] ? cur + 1 : 1
        best = max(best, cur)
    end
    return best
end
