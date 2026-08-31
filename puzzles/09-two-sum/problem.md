Write `two_sum(nums, target)` that finds the two positions whose values add up to `target`, and returns them as a tuple in increasing order. Return `nothing` if no pair works.

Exactly one pair will match when a pair exists.

## Example

```julia
two_sum([2, 7, 11, 15], 9)   # (1, 2)
two_sum([1, 2], 99)          # nothing
```

**Julia note:** positions here are Julia positions, which start at **1**. A solution ported from a 0-indexed language will be right about *which* elements pair up and wrong about what to call them.
