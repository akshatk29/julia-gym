Write `squares(n)` that returns a vector of the squares of the integers from 1 to `n`.

For `n` of zero or less, return an empty vector.

## Example

```julia
squares(5)   # [1, 4, 9, 16, 25]
```

**Julia note:** a comprehension is written `[expr for x in range]`, and ranges like `1:n` include *both* endpoints — so `1:5` is five numbers, not four. `^` means exponentiation here, not exclusive-or.
