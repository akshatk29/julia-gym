Write `shout_all(words)` that returns a new vector with every word uppercased.

## Example

```julia
shout_all(["hi", "there"])   # ["HI", "THERE"]
```

**Julia note:** a `.` placed before a function's parentheses *broadcasts* it — applies it to each element and collects the results. It works on any function, including ones you write yourself, and it is the idiomatic alternative to writing a loop.
