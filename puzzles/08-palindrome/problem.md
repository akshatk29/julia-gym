Write `palindrome(s)` that returns `true` when `s` reads the same forwards and backwards, ignoring case, spaces and punctuation.

## Example

```julia
palindrome("A man, a plan, a canal: Panama")   # true
palindrome("hello")                            # false
```

**Julia note:** `filter` takes the predicate first and works on a String as happily as on an array — `filter(isletter, s)` gives you back a String. Functions that ask a yes/no question conventionally end in `?` (`isempty`, `haskey`), though `?` is not legal in a name you define yourself the way `!` is.
