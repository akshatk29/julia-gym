function binary_search(v, target)
    lo, hi = 1, length(v)
    while lo <= hi
        mid = (lo + hi) ÷ 2
        if v[mid] == target
            return mid
        elseif v[mid] < target
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return nothing
end
