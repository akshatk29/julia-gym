Write `fizzbuzz(n)` that returns a vector of strings for the numbers 1 through `n`.

A number divisible by 3 becomes `"Fizz"`, by 5 becomes `"Buzz"`, by both becomes `"FizzBuzz"`, and anything else becomes the number itself as a string.

## Example

```julia
fizzbuzz(5)   # ["1", "2", "Fizz", "4", "Buzz"]
```

**Julia note:** this one *returns* rather than prints. A vector of strings has type `Vector{String}`, so a number has to be converted with `string(i)` before it can join them — mixing numbers and strings in one array gives you `Vector{Any}`, which is not the same thing.
