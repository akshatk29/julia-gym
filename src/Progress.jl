"""
    Progress

Reads and writes `data/progress.json`. A file on disk rather than localStorage
(§2), so progress survives a browser cache clear and stays greppable.

Every write is atomic — temp file plus rename — and serialized behind a lock, so
a crash mid-write can never leave a truncated file where the player's progress
used to be.
"""
module Progress

using JSON3

export ProgressStore, load_store, snapshot, record_attempt!, save_draft!,
       take_hint!, mark_solution_viewed!, reset!, entry_for, set_solved!,
       blank_entry, migrate!

const LOCK = ReentrantLock()

mutable struct ProgressStore
    path::String
    data::Dict{String,Any}
end

blank_entry() = Dict{String,Any}(
    "solved"          => false,
    # true when the player ticked it off by hand rather than passing the tests
    "manual"          => false,
    "attempts"        => 0,
    "hints_used"      => 0,
    "solution_viewed" => false,
    "draft"           => "",
    "best_ms"         => nothing,
    "solved_at"       => nothing,
)

"""
    load_store(path) -> ProgressStore

Read the progress file, or start empty. A corrupt file is moved aside rather
than deleted — losing progress silently would be worse than a stray backup.
"""
function load_store(path::AbstractString)
    mkpath(dirname(path))
    data = Dict{String,Any}("puzzles" => Dict{String,Any}(), "version" => 1)
    if isfile(path)
        try
            parsed = JSON3.read(read(path, String), Dict{String,Any})
            haskey(parsed, "puzzles") && (data = parsed)
        catch e
            backup = path * ".corrupt-" * string(round(Int, time()))
            @warn "progress.json could not be parsed; keeping a copy and starting fresh." backup exception=e
            try
                mv(path, backup; force = true)
            catch
            end
        end
    end
    haskey(data, "puzzles") || (data["puzzles"] = Dict{String,Any}())
    migrate!(data)
    return ProgressStore(String(path), data)
end

"""
    migrate!(data)

Backfill fields added since the file was written.

A progress file outlives the code that wrote it. Without this, adding a field
to `blank_entry` silently breaks every existing player's file — anything
reading an entry directly gets a `KeyError` on the new key, which is how the
puzzle list started returning 500 for anyone who had played before `manual`
was introduced.
"""
function migrate!(data)
    defaults = blank_entry()
    puzzles = get(data, "puzzles", nothing)
    puzzles isa AbstractDict || return data
    for (_, e) in puzzles
        e isa AbstractDict || continue
        for (k, v) in defaults
            haskey(e, k) || (e[k] = v)
        end
    end
    return data
end

"""
    entry_for(store, id) -> Dict

The record for one puzzle, created on first touch.
"""
function entry_for(store::ProgressStore, id::AbstractString)
    puzzles = store.data["puzzles"]
    haskey(puzzles, id) || (puzzles[id] = blank_entry())
    e = puzzles[id]
    # Tolerate a file written by an older version that lacked a field.
    for (k, v) in blank_entry()
        haskey(e, k) || (e[k] = v)
    end
    return e
end

"""
    persist!(store)

Atomic write: serialize to a temp file in the same directory, fsync-by-rename
over the real one. A same-directory rename is atomic on every filesystem we
care about, so a reader never sees a half-written file.
"""
function persist!(store::ProgressStore)
    dir = dirname(store.path)
    mkpath(dir)
    tmp = joinpath(dir, ".progress.json.tmp-" * string(getpid()))
    open(tmp, "w") do io
        JSON3.pretty(io, store.data)
    end
    mv(tmp, store.path; force = true)
    return
end

"""
    with_store(f, store)

Run `f(store)` under the write lock and persist afterwards.
"""
function with_store(f, store::ProgressStore)
    lock(LOCK) do
        r = f(store)
        persist!(store)
        return r
    end
end

"""
    record_attempt!(store, id; solved, wall_ms, code)

One submission. Counts the attempt, saves the draft, and on the first success
stamps the solve. `best_ms` keeps the fastest successful run.
"""
function record_attempt!(store::ProgressStore, id::AbstractString;
                         solved::Bool, wall_ms::Integer, code::AbstractString)
    with_store(store) do s
        e = entry_for(s, id)
        e["attempts"] = e["attempts"] + 1
        e["draft"] = String(code)
        if solved
            if e["solved"] !== true
                e["solved"] = true
                e["solved_at"] = round(Int, time())
            end
            # Passing the tests supersedes a manual tick: the solve is now real.
            e["manual"] = false
            best = e["best_ms"]
            if best === nothing || wall_ms < best
                e["best_ms"] = Int(wall_ms)
            end
        end
        return e
    end
end

save_draft!(store::ProgressStore, id::AbstractString, code::AbstractString) =
    with_store(store) do s
        entry_for(s, id)["draft"] = String(code)
    end

"""
    take_hint!(store, id, n)

Record that the player has now seen at least `n` hints.
"""
take_hint!(store::ProgressStore, id::AbstractString, n::Integer) =
    with_store(store) do s
        e = entry_for(s, id)
        e["hints_used"] = max(e["hints_used"], Int(n))
        return e
    end

mark_solution_viewed!(store::ProgressStore, id::AbstractString) =
    with_store(store) do s
        entry_for(s, id)["solution_viewed"] = true
    end

"""
    set_solved!(store, id; solved, manual=true)

Mark a puzzle complete or incomplete by hand.

Marking incomplete clears only the completion — attempts, hints and the saved
draft are history and stay put, so ticking a puzzle back to unsolved never
costs the player their work.
"""
function set_solved!(store::ProgressStore, id::AbstractString;
                     solved::Bool, manual::Bool = true)
    with_store(store) do s
        e = entry_for(s, id)
        e["solved"] = solved
        if solved
            e["manual"] = manual
            e["solved_at"] === nothing && (e["solved_at"] = round(Int, time()))
        else
            e["manual"] = false
            e["solved_at"] = nothing
        end
        return e
    end
end

"""
    reset!(store)

Clear everything. The UI confirms before calling this (§7).
"""
reset!(store::ProgressStore) =
    with_store(store) do s
        s.data["puzzles"] = Dict{String,Any}()
    end

"""
    snapshot(store) -> Dict

A read-only copy for the API. Taken under the lock so it can't catch a
half-applied update.
"""
snapshot(store::ProgressStore) = lock(LOCK) do
    deepcopy(store.data)
end

end # module
