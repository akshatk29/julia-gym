Write `divide_three_ways(a, b)` that returns a 3-tuple: the true quotient, the integer quotient, and the remainder — in that order.

## Example

```julia
divide_three_ways(7, 2)   # (3.5, 3, 1)
divide_three_ways(6, 3)   # (2.0, 2, 0)
```

Look closely at the second one. `6 / 3` is `2.0`, not `2`.

**Julia note:** `/` is *always* floating point, so `6 / 3 === 2.0::Float64`. Integer division is `÷` (`\div`+Tab) or `div`. These are different types, and this puzzle checks types — `2` will not be accepted where `2.0` is expected.
