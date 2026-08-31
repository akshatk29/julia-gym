#!/usr/bin/env julia
#
# Julia Gym — child process entry point. STDLIB ONLY.
#
#     julia --startup-file=no --history-file=no --color=no runner.jl <puzzle-dir> <submission-file>
#
# Loads the player's submission into a fresh anonymous module, runs the puzzle's
# tests.jl against it, and prints exactly one line to the real stdout:
#
#     __JULIA_GYM_RESULT__{"ok":true,...}
#
# Nothing the submission prints can precede or corrupt that line: the process's
# stdout is redirected into a temp file for the duration, and the sentinel is
# written to the saved original handle.
#
# No packages are loaded here on purpose. Every millisecond in this file is paid
# on every single submission, and JSON3 alone costs more than the whole run.

const SENTINEL   = "__JULIA_GYM_RESULT__"
const MAX_RENDER = 400          # chars per rendered value before truncation
const MAX_STDOUT = 64 * 1024    # bytes captured per §6
const MAX_FRAMES = 12

# ---------------------------------------------------------------------------
# Minimal JSON writer (stdlib-only, encode side only)
# ---------------------------------------------------------------------------

function json_escape(s::AbstractString)
    io = IOBuffer()
    for c in s
        if c == '"'
            write(io, "\\\"")
        elseif c == '\\'
            write(io, "\\\\")
        elseif c == '\n'
            write(io, "\\n")
        elseif c == '\r'
            write(io, "\\r")
        elseif c == '\t'
            write(io, "\\t")
        elseif c == '\b'
            write(io, "\\b")
        elseif c == '\f'
            write(io, "\\f")
        elseif c < ' ' || c == '\u007f'
            write(io, "\\u", lpad(string(UInt32(c); base = 16), 4, '0'))
        else
            write(io, c)
        end
    end
    String(take!(io))
end

json(::Nothing)         = "null"
json(x::Bool)           = x ? "true" : "false"
json(x::Integer)        = string(x)
json(x::AbstractFloat)  = isfinite(x) ? string(x) : "null"
json(x::AbstractString) = "\"" * json_escape(x) * "\""
json(x::Symbol)         = json(String(x))
json(x::AbstractVector) = "[" * join(map(json, x), ",") * "]"
json(x::AbstractDict)   = "{" * join([json(string(k)) * ":" * json(v) for (k, v) in x], ",") * "}"
json(x)                 = json(string(x))

# ---------------------------------------------------------------------------
# Tiny JSON reader — just enough for meta.json, so the child needs no packages
# ---------------------------------------------------------------------------

function parse_json(s::AbstractString)
    i = Ref(1)
    skipws(s, i)
    return parse_value(s, i)
end

function skipws(s, i)
    while i[] <= lastindex(s) && isspace(s[i[]])
        i[] = nextind(s, i[])
    end
end

function parse_value(s, i)
    skipws(s, i)
    i[] > lastindex(s) && error("unexpected end of JSON")
    c = s[i[]]
    c == '{' && return parse_object(s, i)
    c == '[' && return parse_array(s, i)
    c == '"' && return parse_string(s, i)
    startswith(SubString(s, i[]), "true")  && (i[] += 4; return true)
    startswith(SubString(s, i[]), "false") && (i[] += 5; return false)
    startswith(SubString(s, i[]), "null")  && (i[] += 4; return nothing)
    return parse_number(s, i)
end

function parse_object(s, i)
    d = Dict{String,Any}()
    i[] = nextind(s, i[])
    skipws(s, i)
    if s[i[]] == '}'
        i[] = nextind(s, i[])
        return d
    end
    while true
        skipws(s, i)
        k = parse_string(s, i)
        skipws(s, i)
        s[i[]] == ':' || error("expected ':' in object")
        i[] = nextind(s, i[])
        d[k] = parse_value(s, i)
        skipws(s, i)
        c = s[i[]]
        i[] = nextind(s, i[])
        c == ',' && continue
        c == '}' && break
        error("expected ',' or '}' in object")
    end
    return d
end

function parse_array(s, i)
    a = Any[]
    i[] = nextind(s, i[])
    skipws(s, i)
    if s[i[]] == ']'
        i[] = nextind(s, i[])
        return a
    end
    while true
        push!(a, parse_value(s, i))
        skipws(s, i)
        c = s[i[]]
        i[] = nextind(s, i[])
        c == ',' && continue
        c == ']' && break
        error("expected ',' or ']' in array")
    end
    return a
end

function parse_string(s, i)
    s[i[]] == '"' || error("expected string")
    i[] = nextind(s, i[])
    io = IOBuffer()
    while true
        c = s[i[]]
        i[] = nextind(s, i[])
        if c == '"'
            break
        elseif c == '\\'
            e = s[i[]]
            i[] = nextind(s, i[])
            if e == 'n';     write(io, '\n')
            elseif e == 't'; write(io, '\t')
            elseif e == 'r'; write(io, '\r')
            elseif e == 'b'; write(io, '\b')
            elseif e == 'f'; write(io, '\f')
            elseif e == 'u'
                write(io, Char(parse(UInt16, SubString(s, i[], i[] + 3); base = 16)))
                i[] += 4
            else
                write(io, e)
            end
        else
            write(io, c)
        end
    end
    return String(take!(io))
end

function parse_number(s, i)
    start = i[]
    while i[] <= lastindex(s) && (isdigit(s[i[]]) || s[i[]] in "+-.eE")
        i[] = nextind(s, i[])
    end
    txt = SubString(s, start, prevind(s, i[]))
    v = tryparse(Int, txt)
    return v === nothing ? parse(Float64, txt) : v
end

# ---------------------------------------------------------------------------
# Test DSL — what puzzle authors write in tests.jl
# ---------------------------------------------------------------------------

struct TestCase
    args::Tuple
    kwargs::Dict{Symbol,Any}
    hidden::Bool
end

const CASES = TestCase[]

"""
    case(args...; expect, expect_fn, atol, stdout)

A visible test case: shown to the player in the problem pane before they run.
"""
case(args...; kwargs...) = push!(CASES, TestCase(args, Dict{Symbol,Any}(kwargs), false))

"""
    hidden(args...; ...)

Same, but its expectation is never sent to the browser before a run.
"""
hidden(args...; kwargs...) = push!(CASES, TestCase(args, Dict{Symbol,Any}(kwargs), true))

# ---------------------------------------------------------------------------
# Comparison — §4's type strictness lives here
# ---------------------------------------------------------------------------

typename(x) = string(typeof(x))

"""
    matches(got, expected; atol=nothing) -> Bool

Value equality with Julia's type distinctions preserved. `3` and `3.0` are
different answers, and one of the puzzles exists to teach exactly that, so
numbers must agree on `typeof` as well as on `==`.

`atol` relaxes both the value comparison and the type check, since a float
tolerance implies the player is working in floats deliberately.
"""
function matches(got, expected; atol = nothing)
    atol !== nothing && return _approx(got, expected, atol)
    return _strict(got, expected)
end

function _strict(got, expected)
    if expected isa Number && got isa Number
        return typeof(got) === typeof(expected) && got == expected
    elseif expected isa AbstractString && got isa AbstractString
        return String(got) == String(expected)
    elseif expected isa Tuple && got isa Tuple
        length(got) == length(expected) || return false
        return all(_strict(g, e) for (g, e) in zip(got, expected))
    elseif expected isa AbstractArray && got isa AbstractArray
        size(got) == size(expected) || return false
        eltype(got) === eltype(expected) || return false
        return all(_strict(g, e) for (g, e) in zip(got, expected))
    elseif expected isa AbstractDict && got isa AbstractDict
        keytype(got) === keytype(expected) && valtype(got) === valtype(expected) || return false
        length(got) == length(expected) || return false
        for (k, v) in expected
            haskey(got, k) || return false
            _strict(got[k], v) || return false
        end
        return true
    elseif expected isa AbstractSet && got isa AbstractSet
        return eltype(got) === eltype(expected) && got == expected
    elseif expected === nothing
        return got === nothing
    else
        return typeof(got) === typeof(expected) && isequal(got, expected)
    end
end

function _approx(got, expected, atol)
    if expected isa Number && got isa Number
        return isapprox(got, expected; atol = atol)
    elseif (expected isa AbstractArray || expected isa Tuple) &&
           (got isa AbstractArray || got isa Tuple)
        length(got) == length(expected) || return false
        return all(_approx(g, e, atol) for (g, e) in zip(got, expected))
    else
        return _strict(got, expected)
    end
end

"""
    explain_mismatch(got, expected) -> String or nothing

Produces the message for the case where a value is *right* but its type is
wrong — `3` where `3.0` was wanted. That error is the lesson (§4), so it has to
be named explicitly rather than left as two similar-looking values side by side.

Recurses into tuples and arrays, because the mismatch is usually one element of
a returned tuple rather than the whole answer.
"""
function explain_mismatch(got, expected, path::String = "")
    where_ = isempty(path) ? "" : path * ": "
    if got isa Number && expected isa Number
        if typeof(got) !== typeof(expected) && got == expected
            return where_ * "expected $(render(expected))::$(typename(expected)), " *
                            "got $(render(got))::$(typename(got))"
        end
        return nothing
    end
    if (got isa Tuple && expected isa Tuple) ||
       (got isa AbstractArray && expected isa AbstractArray)
        length(got) == length(expected) || return nothing
        for (i, (g, e)) in enumerate(zip(got, expected))
            msg = explain_mismatch(g, e, isempty(path) ? "element $i" : path * ".$i")
            msg !== nothing && return msg
        end
        # Same values and element types, but the containers differ — e.g. a
        # Vector{Float64} of whole numbers where Vector{Int} was wanted.
        if typeof(got) !== typeof(expected) && all(g == e for (g, e) in zip(got, expected))
            return where_ * "expected a $(typename(expected)), got a $(typename(got))"
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

function truncate_value(s::AbstractString)
    length(s) <= MAX_RENDER && return String(s)
    return String(SubString(s, 1, thisind(s, MAX_RENDER))) * " …"
end

function render(x)
    s = try
        repr(x)
    catch
        string(x)
    end
    return truncate_value(s)
end

render_args(args::Tuple) = truncate_value(join(map(repr, args), ", "))

# ---------------------------------------------------------------------------
# Error formatting
# ---------------------------------------------------------------------------

"""
    format_error(err, bt) -> (message, frames)

The exception's real message plus the submission's own stack frames, with the
harness's frames stripped so a `BoundsError` points at the player's line and not
at ours.
"""
function format_error(err, bt)
    msg = try
        sprint(showerror, err)
    catch
        string(typeof(err))
    end
    msg = truncate_value(msg)

    frames = String[]
    try
        for f in stacktrace(bt)
            occursin("submission.jl", String(f.file)) || continue
            push!(frames, "$(f.func) at line $(f.line)")
            length(frames) >= MAX_FRAMES && break
        end
    catch
    end
    return (msg, frames)
end

"""
    clean_parse_error(msg) -> String

Turns Julia's raw parse error into something a player can act on.

The useful part — the offending source with a caret under it — is kept exactly
as Julia produced it. What goes is the wrapper: the `LoadError:` chaining, the
`in expression starting at` trailer, and every mention of `submission.jl`, which
is an internal filename the player has no way to recognise. The position
becomes plain words instead.
"""
function clean_parse_error(msg::AbstractString)
    line = nothing
    col  = nothing
    kept = String[]

    for l in eachsplit(msg, '\n')
        stripped = strip(l)
        # "# Error @ submission.jl:2:1" — take the position, drop the line.
        m = match(r"^#\s*Error\s*@\s*\S*submission\.jl:(\d+)(?::(\d+))?", stripped)
        if m !== nothing
            line = m.captures[1]
            col  = m.captures[2]
            continue
        end
        startswith(stripped, "in expression starting at") && continue
        isempty(kept) && (stripped == "LoadError: ParseError:" ||
                          stripped == "ParseError:" ||
                          startswith(stripped, "LoadError:")) && continue
        push!(kept, String(l))
    end

    while !isempty(kept) && isempty(strip(kept[1]))
        popfirst!(kept)
    end
    while !isempty(kept) && isempty(strip(kept[end]))
        pop!(kept)
    end

    where_ = line === nothing ? "" :
             col === nothing ? " — line $line" : " — line $line, column $col"
    header = "Julia couldn't parse your code$where_:"
    return isempty(kept) ? header : header * "\n\n" * join(kept, "\n")
end

# ---------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# stdout capture
#
# The submission's stdout and stderr are redirected into a pipe that a
# background task drains continuously. Draining matters: if we only read at
# case boundaries, `while true; println("x"); end` would fill the OS pipe
# buffer and block the submission instead of being truncated. The drain task
# keeps the first MAX_STDOUT bytes of each case and throws the rest away, so a
# 100 MB print costs bounded memory and touches no disk at all.
#
# Case boundaries are delimited by writing MARKER to the redirected stdout and
# waiting for the drain task to hand back everything before it.
# ---------------------------------------------------------------------------

const MARKER = "\0\0__JG_CASE_BOUNDARY__\0\0"

"""
    find_sub(haystack, needle) -> index or nothing
"""
function find_sub(hay::Vector{UInt8}, needle::Vector{UInt8})
    n, m = length(hay), length(needle)
    m == 0 && return 1
    n < m && return nothing
    first_byte = needle[1]
    @inbounds for i in 1:(n - m + 1)
        hay[i] == first_byte || continue
        ok = true
        for j in 2:m
            if hay[i + j - 1] != needle[j]
                ok = false
                break
            end
        end
        ok && return i
    end
    return nothing
end

function append_capped!(kept::Vector{UInt8}, src, limit::Int)
    room = limit - length(kept)
    room <= 0 && return
    n = min(room, length(src))
    append!(kept, @view src[1:n])
    return
end

"""
    drain!(io, ch)

Read the capture pipe forever, splitting on MARKER and pushing
`(text, total_bytes)` for each segment onto `ch`. `text` is capped at
MAX_STDOUT; `total_bytes` is the true length, so the caller can tell that
truncation happened.
"""
function drain!(io, ch::Channel)
    marker = Vector{UInt8}(MARKER)
    m = length(marker)
    pending = UInt8[]
    kept = UInt8[]
    total = 0
    while true
        idx = find_sub(pending, marker)
        if idx !== nothing
            append_capped!(kept, @view(pending[1:idx-1]), MAX_STDOUT)
            total += idx - 1
            put!(ch, (String(copy(kept)), total))
            empty!(kept); total = 0
            pending = pending[idx+m:end]
            continue
        end
        # Everything but the last m-1 bytes can't be part of a split marker.
        safe = length(pending) - (m - 1)
        if safe > 0
            append_capped!(kept, @view(pending[1:safe]), MAX_STDOUT)
            total += safe
            deleteat!(pending, 1:safe)
        end
        chunk = try
            readavailable(io)
        catch
            UInt8[]
        end
        if isempty(chunk)                       # EOF: flush the tail and stop
            append_capped!(kept, pending, MAX_STDOUT)
            total += length(pending)
            put!(ch, (String(copy(kept)), total))
            close(ch)
            return
        end
        append!(pending, chunk)
    end
end

"""
    take_output!(ch, task) -> (text, total_bytes)

Close off the current case and collect its output. Returns empty output rather
than hanging if the drain task has died.
"""
function take_output!(ch::Channel, task::Task)
    print(MARKER)          # goes into the redirected stdout, i.e. the pipe
    flush(stdout)
    (istaskdone(task) && !isready(ch)) && return ("", 0)
    return try
        take!(ch)
    catch
        ("", 0)
    end
end

"""
    run_case(fn, tc, ch, drain_task) -> Dict

One case: call the function, capture what it printed, decide pass/fail.
"""
function run_case(fn, tc, ch, drain_task)
    kw        = tc.kwargs
    has_exp   = haskey(kw, :expect)
    expected  = get(kw, :expect, nothing)
    expect_fn = get(kw, :expect_fn, nothing)
    atol      = get(kw, :atol, nothing)
    want_out  = get(kw, :stdout, nothing)

    entry = Dict{String,Any}(
        "hidden"     => tc.hidden,
        "input"      => render_args(tc.args),
        "expected"   => has_exp ? render(expected) :
                        (want_out !== nothing ? render(want_out) : "(custom check)"),
        "got"        => "",
        "pass"       => false,
        "stdout"     => "",
        "truncated"  => false,
        "error"      => nothing,
        "note"       => nothing,
        "elapsed_us" => 0,
    )

    t0 = time_ns()
    local got
    try
        # deepcopy so a mutating submission cannot corrupt a later case's input.
        # invokelatest is required: the submission's methods are defined by
        # include_string at a newer world age than this already-compiled frame,
        # so a direct call raises "method too new to be called from this world".
        got = Base.invokelatest(fn, deepcopy(tc.args)...)
        entry["elapsed_us"] = round(Int, (time_ns() - t0) / 1000)
    catch err
        entry["elapsed_us"] = round(Int, (time_ns() - t0) / 1000)
        msg, frames = format_error(err, catch_backtrace())
        entry["error"] = Dict("kind" => "runtime", "message" => msg, "frames" => frames)
        entry["got"] = "—"
        record_output!(entry, ch, drain_task)
        return entry
    end

    entry["got"] = render(got)
    record_output!(entry, ch, drain_task)

    ok = true
    if expect_fn !== nothing
        ok = try
            Base.invokelatest(expect_fn, got) === true
        catch
            false
        end
    elseif has_exp
        ok = matches(got, expected; atol = atol)
        if !ok
            entry["note"] = explain_mismatch(got, expected)
        end
    end
    if want_out !== nothing
        ok = ok && (rstrip(entry["stdout"], '\n') == rstrip(String(want_out), '\n'))
    end
    entry["pass"] = ok
    return entry
end

function record_output!(entry, ch, drain_task)
    text, total = take_output!(ch, drain_task)
    entry["stdout"] = text
    entry["truncated"] = total > length(codeunits(text))
    return
end

"""
    run_all!(result, puzzle_dir, code, entrypoint, ch, drain_task)

Load the submission, collect the cases, run each one. Writes into `result`.
Called with stdout already redirected into the capture pipe.
"""
function run_all!(result, puzzle_dir, code, entrypoint, ch, drain_task)
    result["ok"]         = false
    result["defined"]    = false
    result["cases"]      = Any[]
    result["error"]      = nothing
    result["compile_ms"] = 0

    # --- 1. Load the submission into a fresh anonymous module ---------------
    sandbox = Module(:Submission)      # std imports on, so Base is available
    t0 = time_ns()
    try
        Base.include_string(sandbox, code, "submission.jl")
    catch err
        msg, frames = format_error(err, catch_backtrace())
        kind = (err isa LoadError || occursin("ParseError", msg) ||
                occursin("ParseError", string(typeof(err)))) ? "syntax" : "load"
        kind == "syntax" && (msg = clean_parse_error(msg))
        result["error"] = Dict("kind" => kind, "message" => msg, "frames" => frames)
        return
    end
    result["compile_ms"] = round(Int, (time_ns() - t0) / 1_000_000)

    # --- 2. Did they define the function we asked for? ----------------------
    # Both the existence check and the lookup run in the latest world: the
    # binding was created by include_string after this frame was compiled, and
    # a direct access emits a "world prior to its definition" warning that
    # would otherwise land in the player's captured output.
    sym = Symbol(entrypoint)
    if !Base.invokelatest(isdefined, sandbox, sym)
        result["error"] = Dict(
            "kind"    => "undefined",
            "message" => "Define a function named $entrypoint — I couldn't find it.",
            "frames"  => String[],
        )
        return
    end
    fn = Base.invokelatest(getfield, sandbox, sym)
    result["defined"] = true

    # --- 3. Collect cases from the puzzle's tests.jl ------------------------
    empty!(CASES)
    try
        Base.include(@__MODULE__, joinpath(puzzle_dir, "tests.jl"))
    catch err
        result["error"] = Dict(
            "kind"    => "puzzle",
            "message" => "This puzzle's tests could not be loaded: " * sprint(showerror, err),
            "frames"  => String[],
        )
        return
    end

    # --- 4. Run them --------------------------------------------------------
    all_pass = true
    for tc in CASES
        entry = run_case(fn, tc, ch, drain_task)
        entry["pass"] || (all_pass = false)
        push!(result["cases"], entry)
    end
    result["ok"] = all_pass && !isempty(CASES)
    return
end

function main()
    if length(ARGS) < 2
        println(stderr, "usage: runner.jl <puzzle-dir> <submission-file>")
        exit(2)
    end
    puzzle_dir, submission_file = ARGS[1], ARGS[2]

    meta       = parse_json(read(joinpath(puzzle_dir, "meta.json"), String))
    entrypoint = String(meta["entrypoint"])
    code       = read(submission_file, String)

    real_stdout = stdout                       # saved before any redirect

    pipe = Pipe()
    Base.link_pipe!(pipe; reader_supports_async = true, writer_supports_async = true)
    ch = Channel{Tuple{String,Int}}(Inf)
    drain_task = @async drain!(pipe.out, ch)

    result = Dict{String,Any}()
    try
        redirect_stdout(pipe.in) do
            redirect_stderr(pipe.in) do
                run_all!(result, puzzle_dir, code, entrypoint, ch, drain_task)
            end
        end
    finally
        try
            close(pipe.in)                     # EOF for the drain task
            wait(drain_task)
        catch
        end
    end

    println(real_stdout, SENTINEL * json(result))
    flush(real_stdout)
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    main()
end
