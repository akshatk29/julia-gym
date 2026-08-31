Write `middle(v)` that returns a new vector with the first and last elements removed.

If the vector has two or fewer elements there is nothing in the middle, so return an empty vector.

## Example

```julia
middle([1, 2, 3, 4, 5])   # [2, 3, 4]
middle([1, 2])            # Int64[]
```

**Julia note:** indexing starts at **1**, not 0, and inside brackets the keyword `end` stands for the last valid index. Slicing with a range that runs backwards — like `3:2` — is not an error; it just gives you nothing back, which is what makes the short-vector case fall out for free.
