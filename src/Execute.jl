"""
    Execute

Spawns one fresh `julia` child per submission and brings back a structured
result. Isolation is the whole point (§2): a submission that loops forever,
floods stdout, or calls `exit()` must not be able to touch the server.

Every player-visible string in here is product copy, not a stack trace passed
through (§12).
"""
module Execute

using JSON3

export run_submission, RunOutcome, TIMEOUT_SECONDS

const SENTINEL        = "__JULIA_GYM_RESULT__"
const TIMEOUT_SECONDS = 5.0
const MAX_CHILD_BYTES = 16 * 1024 * 1024   # the child only writes its result line here
const SIGTERM         = 15
const SIGKILL         = 9

"""
    RunOutcome

`result` holds the runner's parsed JSON when the child completed normally.
When it didn't, `result` is `nothing` and `message` explains why in the
player's terms.
"""
struct RunOutcome
    ok::Bool
    timed_out::Bool
    result::Union{Nothing,Dict{String,Any}}
    message::Union{Nothing,String}
    wall_ms::Int
end

"""
    read_capped(io, limit) -> String

Drain `io` to EOF, retaining at most `limit` bytes. Always drains fully so the
child can never block on a full pipe buffer.
"""
function read_capped(io, limit::Int)
    kept = IOBuffer()
    total = 0
    while !eof(io)
        chunk = readavailable(io)
        isempty(chunk) && break
        total += length(chunk)
        room = limit - kept.size
        room > 0 && write(kept, @view chunk[1:min(room, length(chunk))])
    end
    return String(take!(kept))
end

"""
    kill_group(proc)

`SIGTERM` then `SIGKILL` to the child's *process group*. The child is spawned
detached, so it leads its own group and any grandchild it managed to spawn dies
with it.
"""
function kill_group(proc::Base.Process)
    pid = getpid(proc)
    pid <= 0 && return
    _signal(-pid, SIGTERM)
    # Give it a moment to exit cleanly before the hammer.
    t0 = time()
    while process_running(proc) && (time() - t0) < 0.25
        sleep(0.02)
    end
    process_running(proc) && _signal(-pid, SIGKILL)
    return
end

function _signal(pid::Integer, sig::Integer)
    try
        ccall(:kill, Cint, (Cint, Cint), pid, sig)
    catch
        # Process already reaped; nothing to do.
    end
    return
end

"""
    extract_result(stdout_text) -> Dict or nothing

Pull the runner's JSON off the sentinel line.

Match on a whole *line* that starts with the sentinel, scanning from the end —
not on the last occurrence of the sentinel anywhere in the text. A submission
that prints the sentinel gets that text echoed back inside its own case's
`stdout` field, so the last textual occurrence is routinely the quoted copy
rather than the real prefix. The real line is written by `println` to the
child's untouched stdout, so nothing else can ever share it.
"""
function extract_result(text::AbstractString)
    for line in Iterators.reverse(collect(eachsplit(text, '\n')))
        startswith(line, SENTINEL) || continue
        payload = SubString(line, ncodeunits(SENTINEL) + 1)
        parsed = try
            Dict{String,Any}(JSON3.read(payload, Dict{String,Any}))
        catch
            nothing
        end
        parsed === nothing || return parsed
    end
    return nothing
end

"""
    run_submission(root, puzzle_dir, code; timeout=TIMEOUT_SECONDS) -> RunOutcome

Write `code` to a scratch directory, run `runner.jl` against `puzzle_dir` in a
detached child, and return what came back. The child's working directory is the
scratch dir, never the puzzle dir (§6) — a submission that writes files can't
scribble on the puzzle.
"""
function run_submission(root::AbstractString, puzzle_dir::AbstractString, code::AbstractString;
                        timeout::Real = TIMEOUT_SECONDS)
    scratch = mktempdir(; prefix = "juliagym_")
    try
        subfile = joinpath(scratch, "submission.jl")
        write(subfile, code)

        julia = Base.julia_cmd()[1]
        runner = joinpath(root, "runner.jl")
        # -O0 for the child: the harness gains nothing from LLVM optimization and
        # puzzle-sized inputs don't either, but it cuts child startup from ~1.05s
        # to ~0.74s on every single run. (`--compile=min` is tempting and roughly
        # 3x faster again, but it interprets the *submission* too — measured 29x
        # slower on a 1e6-element scan — so it stays off.)
        base = `$julia --startup-file=no --history-file=no --color=no -O0 $runner $puzzle_dir $subfile`
        cmd = Cmd(base; dir = scratch, detach = true)

        out, err = Pipe(), Pipe()
        t0 = time_ns()
        proc = run(pipeline(cmd; stdout = out, stderr = err); wait = false)
        close(out.in)
        close(err.in)

        out_task = @async read_capped(out, MAX_CHILD_BYTES)
        err_task = @async read_capped(err, MAX_CHILD_BYTES)

        timed_out = Ref(false)
        timer = Timer(float(timeout)) do _
            if process_running(proc)
                timed_out[] = true
                kill_group(proc)
            end
        end

        try
            wait(proc)
        catch
            # A killed process surfaces here; the outcome is decided below.
        finally
            close(timer)
        end

        stdout_text = fetch(out_task)
        stderr_text = fetch(err_task)
        wall_ms = round(Int, (time_ns() - t0) / 1_000_000)

        if timed_out[]
            return RunOutcome(false, true, nothing,
                "Your code ran longer than $(round(Int, timeout)) seconds — likely an infinite loop.",
                wall_ms)
        end

        result = extract_result(stdout_text)
        if result !== nothing
            return RunOutcome(true, false, result, nothing, wall_ms)
        end

        # The child died before it could report. The overwhelmingly common
        # cause is the submission calling exit() — say so, and keep whatever
        # the child managed to print as a hint.
        code_ = try
            proc.exitcode
        catch
            -1
        end
        detail = strip(stderr_text)
        msg = if code_ != 0
            "Your code stopped the whole program before the tests finished — " *
            "usually that means it called `exit()`." *
            (isempty(detail) ? "" : "\n\n" * first(detail, 1000))
        else
            "The run finished but produced no result. This is a bug in Julia Gym, not in your code." *
            (isempty(detail) ? "" : "\n\n" * first(detail, 1000))
        end
        return RunOutcome(false, false, nothing, msg, wall_ms)
    finally
        rm(scratch; recursive = true, force = true)
    end
end

end # module
