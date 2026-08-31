function top_words(counts, k)
    pairs = collect(counts)
    sorted = sort(pairs; by = p -> (-p.second, p.first))
    return String[p.first for p in sorted[1:min(k, length(sorted))]]
end
