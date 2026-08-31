Write `longest_run(v)` that returns the length of the longest run of consecutive equal elements. An empty vector has a longest run of `0`.

## Example

```julia
longest_run([1, 1, 2, 2, 2, 3])   # 3
longest_run([4])                  # 1
```

**Julia note:** `enumerate(v)` gives you `(index, value)` pairs, which lets a single pass look back at `v[i-1]` without a second loop. Keep two counters — the run you are in and the best you have seen — and the whole thing is one traversal.
