Write `top_words(counts, k)` that takes a `Dict{String,Int}` and returns the `k` most frequent words as a `Vector{String}`, most frequent first. Break ties alphabetically. If there are fewer than `k` words, return all of them.

## Example

```julia
top_words(Dict("a" => 3, "b" => 1, "c" => 3), 2)   # ["a", "c"]
```

**Julia note:** `sort` takes a `by` keyword — a function mapping each element to the value to compare. Returning a *tuple* from `by` sorts by the first component and uses the rest to break ties, which is how you get "count descending, then name ascending" out of a single ascending sort.
