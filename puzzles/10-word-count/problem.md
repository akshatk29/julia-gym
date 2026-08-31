Write `word_count(text)` that returns a `Dict{String,Int}` mapping each whitespace-separated word to how many times it appears. Compare words case-sensitively.

## Example

```julia
word_count("the cat the")   # Dict("the" => 2, "cat" => 1)
```

**Julia note:** `split(text)` with no delimiter splits on runs of whitespace and drops the empties, so leading and trailing spaces take care of themselves. `get(d, k, default)` is the idiomatic way to read a key that might be missing — it saves you a `haskey` check on every iteration.
