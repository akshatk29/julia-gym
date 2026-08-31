Write `group_by_initial(words)` that returns a `Dict{Char,Vector{String}}` grouping the words by their first character. Within each group, keep the original order. Skip empty strings.

## Example

```julia
group_by_initial(["ant", "bee", "ape"])
# Dict('a' => ["ant", "ape"], 'b' => ["bee"])
```

**Julia note:** indexing a String gives a `Char` — single quotes, a distinct type from a one-character String. And `get!` is the mutating cousin of `get`: it inserts the default when the key is missing *and* hands back the stored value, so you can push into it directly instead of writing the same three-line if-else every time.
