"""
    Puzzles

Loads `puzzles/*/` at boot and validates every one of them (§4). A puzzle is a
directory — adding one means adding a folder, with no registry to edit.

Validation is not a formality: each puzzle's reference solution is run against
its own tests through the real runner. A puzzle that fails is logged loudly and
skipped, never served broken.
"""
module Puzzles

using JSON3

include("Execute.jl")
using .Execute

export Puzzle, load_puzzles, visible_cases, puzzle_by_id

const REQUIRED_FILES = ["meta.json", "problem.md", "starter.jl", "solution.jl", "tests.jl"]
const TRACKS = ("idioms", "algorithms", "wrangling")

struct Puzzle
    id::String
    title::String
    track::String
    difficulty::Int
    entrypoint::String
    teaches::Vector{String}
    hints::Vector{String}
    dir::String
    problem::String
    starter::String
    solution::String
    order::Int
    visible::Vector{Any}    # sample cases, cached at boot (see validate)
    hidden_count::Int
end

"""
    read_puzzle(dir, order) -> Puzzle

Parse one puzzle directory. Throws with a specific message on anything missing
or malformed; the caller turns that into a skip.
"""
function read_puzzle(dir::AbstractString, order::Int)
    for f in REQUIRED_FILES
        isfile(joinpath(dir, f)) || error("missing required file $f")
    end
    meta = try
        JSON3.read(read(joinpath(dir, "meta.json"), String))
    catch e
        error("meta.json does not parse: " * sprint(showerror, e))
    end

    for k in (:id, :title, :track, :difficulty, :entrypoint)
        haskey(meta, k) || error("meta.json is missing \"$k\"")
    end
    track = String(meta.track)
    if !(track in TRACKS)
        error("track \"$track\" is not one of " * join(TRACKS, ", "))
    end

    return Puzzle(
        String(meta.id),
        String(meta.title),
        track,
        Int(meta.difficulty),
        String(meta.entrypoint),
        haskey(meta, :teaches) ? String.(collect(meta.teaches)) : String[],
        haskey(meta, :hints)   ? String.(collect(meta.hints))   : String[],
        dir,
        read(joinpath(dir, "problem.md"), String),
        read(joinpath(dir, "starter.jl"), String),
        read(joinpath(dir, "solution.jl"), String),
        order,
        Any[],
        0,
    )
end

"""
    with_cases(p, visible, hidden_count) -> Puzzle

Rebuild `p` carrying the case data discovered during validation.
"""
with_cases(p::Puzzle, visible, hidden_count) = Puzzle(
    p.id, p.title, p.track, p.difficulty, p.entrypoint, p.teaches, p.hints,
    p.dir, p.problem, p.starter, p.solution, p.order, visible, hidden_count)

"""
    visible_cases(p) -> Vector

The `case(...)` entries only, for the problem pane. Read straight from the
cache built at boot — hidden cases were filtered out there and never enter this
list, so their expectations cannot reach the browser ahead of a run (§7).
"""
visible_cases(p::Puzzle) = p.visible

"""
    validate(root, p) -> (ok, message, visible, hidden_count)

Run the reference solution against the puzzle's own tests. Also asserts the
starter *fails* — a starter that accidentally passes is a bug (§10, M6), and
catching it at boot beats catching it in the browser.

The solution run already produces every case's rendered input and expectation,
so the sample cases are harvested here rather than recomputed per request.
"""
function validate(root::AbstractString, p::Puzzle)
    bad(msg) = (false, msg, Any[], 0)

    sol = run_submission(root, p.dir, p.solution)
    sol.result === nothing &&
        return bad("reference solution did not run: " * something(sol.message, "unknown failure"))
    sol.result["error"] !== nothing &&
        return bad("reference solution errored: " * String(sol.result["error"]["message"]))
    if !(sol.result["ok"] === true)
        failed = [c["input"] for c in sol.result["cases"] if c["pass"] !== true]
        return bad("reference solution fails its own tests on: " * join(failed, "; "))
    end
    isempty(sol.result["cases"]) && return bad("tests.jl defines no cases")

    starter = run_submission(root, p.dir, p.starter)
    if starter.result !== nothing && starter.result["ok"] === true
        return bad("starter.jl PASSES the tests — the puzzle is already solved")
    end

    cases = sol.result["cases"]
    visible = Any[Dict("input" => c["input"], "expected" => c["expected"])
                  for c in cases if c["hidden"] === false]
    hidden_count = count(c -> c["hidden"] === true, cases)
    return (true, "", visible, hidden_count)
end

"""
    load_puzzles(root; validate_all=true) -> (puzzles, problems)

Glob `puzzles/*/`, sorted by directory name so `01-`, `02-`, … control the
order. Returns the valid puzzles and a list of `(dirname, reason)` for the ones
that were skipped.
"""
function load_puzzles(root::AbstractString; validate_all::Bool = true)
    pdir = joinpath(root, "puzzles")
    isdir(pdir) && return _load(root, pdir, validate_all)
    return (Puzzle[], [("puzzles/", "directory does not exist")])
end

function _load(root, pdir, validate_all)
    dirs = sort(filter(isdir, [joinpath(pdir, d) for d in readdir(pdir)]))
    problems = Tuple{String,String}[]

    # --- Phase 1: parse (cheap, serial) ------------------------------------
    parsed = Tuple{String,Puzzle}[]
    seen = Set{String}()
    for (i, d) in enumerate(dirs)
        name = basename(d)
        local p
        try
            p = read_puzzle(d, i)
        catch e
            msg = e isa ErrorException ? e.msg : sprint(showerror, e)
            @error "Puzzle skipped: $name — $msg"
            push!(problems, (name, msg))
            continue
        end
        if p.id in seen
            msg = "duplicate id \"$(p.id)\""
            @error "Puzzle skipped: $name — $msg"
            push!(problems, (name, msg))
            continue
        end
        push!(seen, p.id)
        push!(parsed, (name, p))
    end

    if !validate_all
        return ([p for (_, p) in parsed], problems)
    end

    # --- Phase 2: validate (two child processes each, so run them in
    # parallel). Serially this is ~2s per puzzle and boot would take half a
    # minute for the full set. ----------------------------------------------
    results = asyncmap(((_, p),) -> validate(root, p), parsed; ntasks = max(4, Sys.CPU_THREADS))

    good = Puzzle[]
    for ((name, p), (ok, why, visible, nhidden)) in zip(parsed, results)
        if !ok
            @error "Puzzle skipped: $name — $why"
            push!(problems, (name, why))
            continue
        end
        push!(good, with_cases(p, visible, nhidden))
    end
    return (good, problems)
end

puzzle_by_id(puzzles, id) = findfirst(p -> p.id == id, puzzles)

end # module
