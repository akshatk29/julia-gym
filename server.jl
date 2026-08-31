#!/usr/bin/env julia
#
# Julia Gym — entry point.
#
#     julia --project=. server.jl [--port 8080] [--no-validate]
#                                 [--data PATH] [--keep-alive]
#
#   --data PATH   progress file to use, instead of data/progress.json. Point
#                 tests and experiments at a throwaway path so they cannot
#                 touch a real player's solves and drafts.
#   --keep-alive  never shut down when the browser goes away.
#
const ROOT = @__DIR__

include(joinpath(ROOT, "setup.jl"))               # ensure_deps / vendor_assets / vendor_complete
include(joinpath(ROOT, "src", "Router.jl"))
include(joinpath(ROOT, "src", "Puzzles.jl"))      # brings Execute with it
include(joinpath(ROOT, "src", "Progress.jl"))

using .Router
using .Puzzles
using .Puzzles.Execute
using .Progress
using HTTP, JSON3

const PUBLIC          = joinpath(ROOT, "public")
const DEFAULT_PROGRESS = joinpath(ROOT, "data", "progress.json")
const MAX_CODE_BYTES   = 256 * 1024

# --- Shutting down with the browser ---------------------------------------
# Closing the game should stop the server, so nobody has to remember to Ctrl-C
# it. Two signals, because neither alone is trustworthy:
#
#   * A "goodbye" the page sends as it unloads. Prompt, but not guaranteed —
#     a crash or a force-quit sends nothing.
#
#   * A heartbeat, as a backstop for exactly those cases. It cannot be the
#     primary signal: browsers throttle timers in background tabs to roughly
#     once a minute, so a short heartbeat deadline would shut the game down
#     merely because the player switched tabs. Hence the long deadline here
#     and the short one after a goodbye.
#
# The watchdog only arms after the *first* heartbeat. Until a browser has
# actually connected there is nothing to miss, so starting the server and
# poking it with curl never trips it, and neither does a slow first page load.
const HEARTBEAT_GRACE = 120.0    # silence that means the browser is really gone
const GOODBYE_GRACE   = 5.0      # after an explicit goodbye — long enough that a
                                 # reload's fresh page can check back in first
const LAST_SEEN       = Ref(0.0)
const LEAVING_AT      = Ref(0.0) # 0 when nobody has said goodbye
const WATCHDOG_ARMED  = Ref(false)

# Loaded at boot, replaced never. A puzzle set that changes under a running
# server would make the ids in progress.json ambiguous.
const STATE = Dict{Symbol,Any}()

# One run at a time (§6). The Run button also disables client-side, but the
# server is where it's enforced.
const RUN_LOCK    = ReentrantLock()
const RUN_ACTIVE  = Ref(false)

# ---------------------------------------------------------------------------
# Responses
# ---------------------------------------------------------------------------

const JSON_HEADERS = ["Content-Type" => "application/json; charset=utf-8",
                      "Cache-Control" => "no-store"]

json_ok(x)              = (200, JSON_HEADERS, JSON3.write(x))
json_err(status, msg)   = (status, JSON_HEADERS, JSON3.write(Dict("error" => msg)))

"""
    body_json(req) -> Dict

Parse a request body, or throw an ArgumentError the caller turns into a 400.
"""
function body_json(req::HTTP.Request)
    raw = String(req.body)
    isempty(raw) && throw(ArgumentError("request body is empty"))
    length(raw) > MAX_CODE_BYTES && throw(ArgumentError("request body is too large"))
    return JSON3.read(raw, Dict{String,Any})
end

query_params(target) = HTTP.queryparams(HTTP.URI(target))

# ---------------------------------------------------------------------------
# Serialization — the only place puzzle data becomes JSON.
#
# Nothing here reads p.solution. The reference solution has exactly one exit
# from this process: the gated /solution endpoint below (§7).
# ---------------------------------------------------------------------------

"""
    puzzle_summary(p, entry) -> Dict

The list view. No problem text, no cases, no solution.
"""
puzzle_summary(p::Puzzle, entry) = Dict(
    "id"         => p.id,
    "title"      => p.title,
    "track"      => p.track,
    "difficulty" => p.difficulty,
    "order"      => p.order,
    "solved"     => entry["solved"],
    "attempts"   => entry["attempts"],
    "hints_used" => entry["hints_used"],
    "best_ms"    => entry["best_ms"],
    "manual"     => entry["manual"] === true,
    # The three-dot mark is for a puzzle solved by passing its tests unaided —
    # not one ticked off by hand.
    "clean"      => entry["solved"] === true &&
                    entry["manual"] !== true &&
                    entry["hints_used"] == 0 &&
                    entry["solution_viewed"] !== true,
)

"""
    puzzle_detail(p, entry) -> Dict

The problem pane. Sample cases only; hidden cases are a count. `hint_count`
tells the UI how many hints exist without revealing any of them.
"""
puzzle_detail(p::Puzzle, entry) = Dict(
    "id"           => p.id,
    "title"        => p.title,
    "track"        => p.track,
    "difficulty"   => p.difficulty,
    "entrypoint"   => p.entrypoint,
    "teaches"      => p.teaches,
    "problem"      => p.problem,
    "starter"      => p.starter,
    "cases"        => visible_cases(p),
    "hidden_count" => p.hidden_count,
    "hint_count"   => length(p.hints),
    "solved"       => entry["solved"],
    "manual"       => entry["manual"] === true,
    "attempts"     => entry["attempts"],
    "hints_used"   => entry["hints_used"],
    "solution_viewed" => entry["solution_viewed"],
    "draft"        => entry["draft"],
)

"""
    public_result(outcome) -> Dict

The runner's result, with every hidden case's expectation stripped out. The
player sees pass/fail and the input for a hidden case, never what was wanted
(§4) — otherwise the hidden cases are just visible cases with extra steps.
"""
function public_result(outcome::RunOutcome)
    if outcome.result === nothing
        return Dict(
            "ok" => false, "defined" => false, "cases" => [],
            "timed_out" => outcome.timed_out,
            "error" => Dict("kind" => outcome.timed_out ? "timeout" : "aborted",
                            "message" => something(outcome.message, "The run failed."),
                            "frames" => String[]),
            "wall_ms" => outcome.wall_ms,
        )
    end
    r = outcome.result
    cases = map(r["cases"]) do c
        d = Dict{String,Any}(
            "hidden"     => c["hidden"],
            "input"      => c["input"],
            "got"        => c["got"],
            "pass"       => c["pass"],
            "stdout"     => c["stdout"],
            "truncated"  => c["truncated"],
            "error"      => c["error"],
            "note"       => c["note"],
            "elapsed_us" => c["elapsed_us"],
        )
        # Expectations for hidden cases stay on the server.
        d["expected"] = c["hidden"] === true ? nothing : c["expected"]
        d
    end
    return Dict(
        "ok" => r["ok"], "defined" => r["defined"], "cases" => cases,
        "error" => r["error"], "compile_ms" => r["compile_ms"],
        "timed_out" => false, "wall_ms" => outcome.wall_ms,
    )
end

# ---------------------------------------------------------------------------
# Browser watchdog
# ---------------------------------------------------------------------------

"""
    start_watchdog()

Poll for a missing heartbeat and shut the server down when the page is gone.

The grace period matters: a reload, a hard refresh, or a moment of a busy main
thread all interrupt the heartbeat briefly, and none of them mean the player
has left. Ten seconds is long enough to ride those out and short enough that
closing the tab feels like quitting the app.
"""
function start_watchdog()
    @async begin
        while true
            sleep(1.0)
            WATCHDOG_ARMED[] || continue
            now = time()
            silent = now - LAST_SEEN[]

            # An explicit goodbye, with no page checking back in afterwards.
            # The wait matters: a reload fires the same goodbye, and the new
            # page needs a moment to load and send its first heartbeat. Another
            # open tab counts too — its heartbeat cancels the departure.
            said_bye = LEAVING_AT[] > 0 &&
                       (now - LEAVING_AT[]) > GOODBYE_GRACE &&
                       silent > GOODBYE_GRACE

            if said_bye || silent > HEARTBEAT_GRACE
                println()
                println("  Browser closed — shutting down.")
                flush(stdout)
                exit(0)
            end
        end
    end
    return
end

"""
    api_goodbye(req)

Sent by the page as it unloads, via `navigator.sendBeacon`. Not a command to
exit — just a note that it is leaving, which the watchdog acts on only if
nothing checks back in.
"""
function api_goodbye(_)
    LEAVING_AT[] = time()
    return json_ok(Dict("ok" => true))
end

"""
    api_heartbeat(req)

Called by the open page every few seconds. The first one arms the watchdog.
"""
function api_heartbeat(_)
    LAST_SEEN[]  = time()
    LEAVING_AT[] = 0.0          # someone is here; cancel any pending departure
    if !WATCHDOG_ARMED[]
        WATCHDOG_ARMED[] = true
        println("  Browser connected.")
        flush(stdout)
    end
    return json_ok(Dict("ok" => true, "grace_s" => HEARTBEAT_GRACE))
end

# ---------------------------------------------------------------------------
# Endpoints (§7)
# ---------------------------------------------------------------------------

function api_puzzles(_)
    store = STATE[:store]
    snap = snapshot(store)["puzzles"]
    entry(id) = get(snap, id, Progress.blank_entry())
    return json_ok(Dict(
        "puzzles" => [puzzle_summary(p, entry(p.id)) for p in STATE[:puzzles]],
        "skipped" => [Dict("dir" => d, "reason" => r) for (d, r) in STATE[:problems]],
    ))
end

function find_puzzle(id)
    i = puzzle_by_id(STATE[:puzzles], id)
    i === nothing ? nothing : STATE[:puzzles][i]
end

function api_puzzle(_, id)
    p = find_puzzle(id)
    p === nothing && return json_err(404, "No puzzle with id \"$id\".")
    return json_ok(puzzle_detail(p, entry_for(STATE[:store], id)))
end

function api_hint(req, id)
    p = find_puzzle(id)
    p === nothing && return json_err(404, "No puzzle with id \"$id\".")
    q = query_params(req.target)
    n = try
        parse(Int, get(q, "n", "1"))
    catch
        return json_err(400, "Hint number must be an integer.")
    end
    if n < 1 || n > length(p.hints)
        return json_err(404, "This puzzle has $(length(p.hints)) hints.")
    end
    take_hint!(STATE[:store], id, n)
    return json_ok(Dict("n" => n, "total" => length(p.hints), "hint" => p.hints[n],
                        "remaining" => length(p.hints) - n))
end

"""
    api_solution(req, id)

The one endpoint that returns `solution.jl`. It records that it was viewed, so
the progress rail can tell a clean solve from an assisted one (§8).
"""
function api_solution(_, id)
    p = find_puzzle(id)
    p === nothing && return json_err(404, "No puzzle with id \"$id\".")
    mark_solution_viewed!(STATE[:store], id)
    return json_ok(Dict("id" => id, "solution" => p.solution))
end

function api_run(req)
    local payload
    try
        payload = body_json(req)
    catch e
        return json_err(400, "Could not read the request: " * sprint(showerror, e))
    end
    id   = get(payload, "puzzle", "")
    code = get(payload, "code", "")
    (id isa AbstractString && !isempty(id)) || return json_err(400, "Which puzzle? \"puzzle\" is required.")
    code isa AbstractString || return json_err(400, "\"code\" must be a string.")

    p = find_puzzle(id)
    p === nothing && return json_err(404, "No puzzle with id \"$id\".")

    # One at a time. Reject rather than queue: a queued run would leave the
    # player staring at a spinner with no idea they're second in line.
    claimed = lock(RUN_LOCK) do
        RUN_ACTIVE[] ? false : (RUN_ACTIVE[] = true; true)
    end
    claimed || return json_err(409, "A run is already in flight. Wait for it to finish.")

    try
        outcome = run_submission(ROOT, p.dir, code)
        solved = outcome.result !== nothing && outcome.result["ok"] === true
        record_attempt!(STATE[:store], id; solved = solved, wall_ms = outcome.wall_ms, code = code)
        result = public_result(outcome)
        result["solved"] = solved
        return json_ok(result)
    finally
        lock(RUN_LOCK) do
            RUN_ACTIVE[] = false
        end
    end
end

"""
    api_status(req, id)

Mark a puzzle complete or incomplete by hand.

A manual completion is recorded as `manual`, so it is never mistaken for a
verified one: the rail fills the dot, but the three-dot mark stays reserved for
a puzzle actually solved by passing its tests unaided.
"""
function api_status(req, id)
    find_puzzle(id) === nothing && return json_err(404, "No puzzle with id \"$id\".")
    local payload
    try
        payload = body_json(req)
    catch e
        return json_err(400, "Could not read the request: " * sprint(showerror, e))
    end
    solved = get(payload, "solved", nothing)
    solved isa Bool || return json_err(400, "\"solved\" must be true or false.")
    set_solved!(STATE[:store], id; solved = solved, manual = true)
    return json_ok(Dict("id" => id, "solved" => solved, "manual" => solved))
end

function api_draft(req, id)
    find_puzzle(id) === nothing && return json_err(404, "No puzzle with id \"$id\".")
    local payload
    try
        payload = body_json(req)
    catch e
        return json_err(400, "Could not read the request: " * sprint(showerror, e))
    end
    code = get(payload, "code", "")
    code isa AbstractString || return json_err(400, "\"code\" must be a string.")
    save_draft!(STATE[:store], id, code)
    return json_ok(Dict("saved" => true))
end

api_progress(_) = json_ok(snapshot(STATE[:store]))

function api_reset(_)
    reset!(STATE[:store])
    return json_ok(Dict("reset" => true))
end

# ---------------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------------

function handle_api(req::HTTP.Request, path::AbstractString)
    m = req.method

    path == "/api/health"   && m == "GET"  && return json_ok(Dict(
        "ok" => true, "julia" => string(VERSION),
        "puzzles" => length(STATE[:puzzles]), "vendored" => vendor_complete()))
    path == "/api/puzzles"  && m == "GET"  && return api_puzzles(req)
    path == "/api/run"      && m == "POST" && return api_run(req)
    path == "/api/progress" && m == "GET"  && return api_progress(req)
    path == "/api/heartbeat" && m == "POST" && return api_heartbeat(req)
    path == "/api/goodbye"   && m == "POST" && return api_goodbye(req)
    path == "/api/reset"    && m == "POST" && return api_reset(req)

    for (pattern, method, fn) in (
            ("/api/puzzles/:id",          "GET",  api_puzzle),
            ("/api/puzzles/:id/hint",     "GET",  api_hint),
            ("/api/puzzles/:id/solution", "GET",  api_solution),
            ("/api/puzzles/:id/draft",    "POST", api_draft),
            ("/api/puzzles/:id/status",   "POST", api_status))
        params = match_route(pattern, path)
        params === nothing && continue
        method == m || return json_err(405, "$m is not allowed on $path.")
        # Decode per segment, after splitting: ids may contain characters that
        # have to travel encoded (`palindrome?` arrives as `palindrome%3F`).
        # Unescaping the whole path first would turn %2F into a separator and
        # break the split.
        return fn(req, HTTP.URIs.unescapeuri(params["id"]))
    end

    return json_err(404, "No such endpoint: $path")
end

function handle(req::HTTP.Request)
    path = HTTP.URI(req.target).path
    try
        if startswith(path, "/api/")
            status, headers, body = handle_api(req, path)
            return HTTP.Response(status, headers; body = body)
        end
        resp = static_response(PUBLIC, path)
        if resp === nothing
            return HTTP.Response(404, ["Content-Type" => "text/plain; charset=utf-8"];
                                 body = "Not found: $path")
        end
        status, headers, body = resp
        return HTTP.Response(status, headers; body = body)
    catch e
        # An unhandled error must not take the server down with it (§2).
        @error "Unhandled error serving $path" exception = (e, catch_backtrace())
        return HTTP.Response(500, JSON_HEADERS;
            body = JSON3.write(Dict("error" => "Julia Gym hit an internal error. Check the server log.")))
    end
end

# ---------------------------------------------------------------------------
# Boot
# ---------------------------------------------------------------------------

function main()
    port = 8080
    i = findfirst(==("--port"), ARGS)
    i !== nothing && i < length(ARGS) && (port = parse(Int, ARGS[i+1]))
    validate_all = !("--no-validate" in ARGS)
    keep_alive   = "--keep-alive" in ARGS

    progress_path = DEFAULT_PROGRESS
    j = findfirst(==("--data"), ARGS)
    j !== nothing && j < length(ARGS) && (progress_path = abspath(ARGS[j+1]))

    vendor_complete() || (@info "Vendoring editor assets…"; vendor_assets())

    print("  Loading puzzles… ")
    flush(stdout)
    t0 = time()
    puzzles, problems = load_puzzles(ROOT; validate_all = validate_all)
    println("$(length(puzzles)) ready in $(round(time() - t0; digits = 1))s" *
            (isempty(problems) ? "" : ", $(length(problems)) SKIPPED (see above)"))

    STATE[:puzzles]  = puzzles
    STATE[:problems] = problems
    STATE[:store]    = load_store(progress_path)
    progress_path == DEFAULT_PROGRESS ||
        println("  Progress file: $progress_path")

    keep_alive ? println("  Staying up when the browser closes (--keep-alive).") :
                 start_watchdog()

    println()
    println("  Julia Gym — ready")
    println("  http://localhost:$port")
    println()
    # Flush explicitly: a redirected stdout is block-buffered, and HTTP.serve
    # never returns, so without this the banner is invisible to anything that
    # captures the output to a file or a pipe.
    flush(stdout)
    HTTP.serve(handle, "127.0.0.1", port)
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    main()
end
