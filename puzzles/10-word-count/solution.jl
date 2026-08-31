function word_count(text)
    counts = Dict{String,Int}()
    for w in split(text)
        counts[String(w)] = get(counts, String(w), 0) + 1
    end
    return counts
end
