Write `max_subarray(v)` that returns the largest sum obtainable from any contiguous, non-empty slice of `v`. Return `nothing` for an empty vector.

## Example

```julia
max_subarray([-2, 1, -3, 4, -1, 2, 1, -5, 4])   # 6
max_subarray([-3, -1, -2])                      # -1
```

**Julia note:** `max` compares its arguments while `maximum` reduces a collection — a distinction worth keeping straight. Seed your accumulators from the first element rather than from zero: a vector of all negatives has a negative answer, and starting at 0 silently invents an empty slice that the question did not allow.
