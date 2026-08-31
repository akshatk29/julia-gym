Write `greet(name)` that returns a greeting for the given name.

The greeting is the word `Hello`, a comma, a space, the name, and an exclamation mark.

## Example

```julia
greet("Ada")   # "Hello, Ada!"
```

**Julia note:** `$` interpolates a value into a string. Careful at the end of this one — `!` is a legal character *inside* a Julia identifier, so a bare `$` followed by a name followed by `!` reaches for a variable you never defined.
