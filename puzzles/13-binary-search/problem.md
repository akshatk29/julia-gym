Write `binary_search(v, target)` that finds `target` in the sorted vector `v` and returns its 1-based index, or `nothing` if it is not there.

## Example

```julia
binary_search([1, 3, 5, 7, 9], 7)   # 4
binary_search([1, 3, 5], 4)         # nothing
```

**Julia note:** two traps meet here. Bounds run `1` to `length(v)` inclusive, and the midpoint must use `÷` — `/` returns a `Float64`, and a `Float64` cannot index an array. `nothing` is a real value of type `Nothing`, so returning it is a perfectly ordinary thing to do.
