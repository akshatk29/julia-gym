Write `record_score!(scores, player, points)` that stores `points` under `player` in the `scores` dictionary, replacing any previous value, and returns the dictionary.

## Example

```julia
d = Dict("ada" => 3)
record_score!(d, "grace", 5)   # Dict("ada" => 3, "grace" => 5)
d                              # the SAME dict, now changed
```

**Julia note:** the trailing `!` is a convention, not syntax — it tells a reader that the function modifies its arguments in place. Julia's own `push!`, `sort!` and `empty!` follow it. Honour the convention: change the dictionary you were handed and give that same one back.
