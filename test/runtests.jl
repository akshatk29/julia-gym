#
#     julia --project=. test/runtests.jl
#
# Covers what §11 asks for: the runner and its JSON shape, the comparison
# logic (including the 3-vs-3.0 lesson), the timeout path, and progress
# persistence — plus the invariant that every starter fails.

using Test

const ROOT = dirname(@__DIR__)

include(joinpath(ROOT, "src", "Puzzles.jl"))
include(joinpath(ROOT, "src", "Progress.jl"))
using .Puzzles
using .Puzzles.Execute
using .Progress

# The runner is stdlib-only and meant to be run as a script; load it into its
# own module so its comparison logic can be unit-tested directly.
module Runner
include(joinpath(dirname(dirname(@__FILE__)), "runner.jl"))
end

"""
    with_puzzle(f, meta_extra, tests_src)

Build a throwaway puzzle directory and hand its path to `f`.
"""
function with_puzzle(f, entrypoint::String, tests_src::String)
    dir = mktempdir()
    try
        write(joinpath(dir, "meta.json"), """
        {"id":"tmp","title":"Tmp","track":"idioms","difficulty":1,
         "entrypoint":"$entrypoint","teaches":[],"hints":[]}""")
        write(joinpath(dir, "tests.jl"), tests_src)
        f(dir)
    finally
        rm(dir; recursive = true, force = true)
    end
end

run_code(dir, code; kw...) = run_submission(ROOT, dir, code; kw...)

@testset "Julia Gym" begin

# ---------------------------------------------------------------------------
@testset "comparison: type strictness (§4)" begin
    m = Runner.matches

    # The lesson: equal in value, different in type, must not pass.
    @test  m(3.0, 3.0)
    @test !m(3, 3.0)
    @test !m(3.0, 3)
    @test  m(3, 3)

    # ... and it must say so.
    @test Runner.explain_mismatch(3, 3.0) == "expected 3.0::Float64, got 3::Int64"
    @test Runner.explain_mismatch(3, 4.0) === nothing      # genuinely wrong value
    @test occursin("element 1", Runner.explain_mismatch((2, 2, 0), (2.0, 2, 0)))

    # Containers compare on element type too.
    @test  m([1, 2], [1, 2])
    @test !m([1.0, 2.0], [1, 2])
    @test !m([1, 2], [1, 2, 3])
    @test  m((1, "a"), (1, "a"))
    @test !m((1, "a"), (1.0, "a"))

    # Dicts and sets.
    @test  m(Dict("a" => 1), Dict("a" => 1))
    @test !m(Dict("a" => 1.0), Dict("a" => 1))
    @test !m(Dict("a" => 1), Dict("a" => 1, "b" => 2))
    @test  m(Set([1, 2]), Set([2, 1]))

    # nothing is a value, not an absence.
    @test  m(nothing, nothing)
    @test !m(0, nothing)
    @test !m(nothing, 0)

    # atol relaxes the type check, because asking for a tolerance means the
    # player is deliberately in float territory.
    @test  m(0.1 + 0.2, 0.3; atol = 1e-9)
    @test !m(0.1 + 0.2, 0.3)
    @test  m([1.0, 2.0], [1.0, 2.000000001]; atol = 1e-6)
end

# ---------------------------------------------------------------------------
@testset "runner: result shape and outcomes (§5)" begin
    with_puzzle("double_it", "case(2; expect = 4)\nhidden(3; expect = 6)\n") do dir
        # Passing
        o = run_code(dir, "double_it(n) = 2n")
        @test o.ok
        r = o.result
        @test r["ok"] === true
        @test r["defined"] === true
        @test length(r["cases"]) == 2
        c = r["cases"][1]
        @test c["input"] == "2" && c["expected"] == "4" && c["got"] == "4"
        @test c["pass"] === true && c["hidden"] === false
        @test c["elapsed_us"] isa Integer
        @test r["cases"][2]["hidden"] === true

        # Failing
        o = run_code(dir, "double_it(n) = n + 1")
        @test o.result["ok"] === false
        @test o.result["cases"][1]["got"] == "3"

        # Throwing: the frame must point at the player's line, not ours.
        o = run_code(dir, "function double_it(n)\n    v = [1]\n    return v[99]\nend")
        e = o.result["cases"][1]["error"]
        @test occursin("BoundsError", e["message"])
        @test any(f -> occursin("line 3", f), e["frames"])
        @test !any(f -> occursin("runner.jl", f), e["frames"])

        # Missing entrypoint: friendly copy, never a raw UndefVarError.
        o = run_code(dir, "tripler(n) = 3n")
        @test o.result["defined"] === false
        @test o.result["error"]["kind"] == "undefined"
        @test occursin("Define a function named double_it", o.result["error"]["message"])
        @test !occursin("UndefVarError", o.result["error"]["message"])

        # Syntax error: the position and the caret survive, the internal
        # filename and the LoadError wrapper do not.
        o = run_code(dir, "double_it(n) = \nend end")
        msg = o.result["error"]["message"]
        @test o.result["error"]["kind"] == "syntax"
        @test occursin("Julia couldn't parse your code", msg)
        @test occursin("line 2", msg)
        @test occursin("invalid identifier", msg)      # Julia's own diagnosis kept
        @test !occursin("submission.jl", msg)          # internal filename stripped
        @test !occursin("LoadError", msg)
    end
end

# ---------------------------------------------------------------------------
@testset "runner: stdout capture and the 64 KB cap (§6)" begin
    with_puzzle("noisy", "case(1; expect = 1)\ncase(2; expect = 2)\n") do dir
        # Per-case isolation: case 2 must not see case 1's output.
        o = run_code(dir, "function noisy(n)\n    println(\"n=\", n)\n    return n\nend")
        @test o.result["cases"][1]["stdout"] == "n=1\n"
        @test o.result["cases"][2]["stdout"] == "n=2\n"

        # A flood is truncated, not stored whole.
        o = run_code(dir, """
            function noisy(n)
                for i in 1:20_000
                    println("x"^100)
                end
                return n
            end""")
        c = o.result["cases"][1]
        @test c["truncated"] === true
        @test sizeof(c["stdout"]) <= 64 * 1024
        @test c["pass"] === true          # printing does not change the answer
    end
end

# ---------------------------------------------------------------------------
@testset "execute: the timeout path (§6)" begin
    with_puzzle("spin", "case(1; expect = 1)\n") do dir
        t0 = time()
        o = run_code(dir, "function spin(n)\n    while true; end\nend"; timeout = 2.0)
        elapsed = time() - t0

        @test o.timed_out
        @test o.result === nothing
        @test occursin("longer than", o.message)
        @test elapsed < 5.0            # actually killed, not merely reported
    end

    # exit() is explained rather than surfaced as a crash.
    with_puzzle("bail", "case(1; expect = 1)\n") do dir
        o = run_code(dir, "function bail(n)\n    exit(1)\nend")
        @test !o.ok
        @test !o.timed_out
        @test occursin("exit()", o.message)
    end
end

# ---------------------------------------------------------------------------
@testset "execute: the sentinel resists stray output (§5)" begin
    # A submission that prints something resembling the sentinel at load time
    # must not be able to hijack the parse.
    with_puzzle("sneaky", "case(1; expect = 1)\n") do dir
        o = run_code(dir, """
            println("__JULIA_GYM_RESULT__{\\"ok\\":true,\\"cases\\":[]}")
            sneaky(n) = 0
            """)
        @test o.result !== nothing
        @test o.result["ok"] === false        # the real result, not the forgery
        @test o.result["cases"][1]["pass"] === false
    end
end

# ---------------------------------------------------------------------------
@testset "progress: persistence is atomic and survives a reload" begin
    dir = mktempdir()
    try
        path = joinpath(dir, "progress.json")
        s = load_store(path)

        record_attempt!(s, "greet"; solved = false, wall_ms = 900, code = "draft one")
        record_attempt!(s, "greet"; solved = true,  wall_ms = 800, code = "solved it")
        record_attempt!(s, "greet"; solved = true,  wall_ms = 950, code = "solved it")
        take_hint!(s, "greet", 2)

        e = entry_for(s, "greet")
        @test e["attempts"] == 3
        @test e["solved"] === true
        @test e["best_ms"] == 800          # keeps the fastest, not the latest
        @test e["hints_used"] == 2

        # Reload from disk: everything survives.
        s2 = load_store(path)
        e2 = entry_for(s2, "greet")
        @test e2["solved"] === true
        @test e2["draft"] == "solved it"
        @test e2["best_ms"] == 800

        # No temp files left behind.
        @test filter(f -> occursin("tmp", f), readdir(dir)) == String[]

        reset!(s2)
        @test isempty(snapshot(s2)["puzzles"])

        # A corrupt file is set aside, not silently dropped.
        write(path, "{ this is not json")
        s3 = load_store(path)
        @test isempty(snapshot(s3)["puzzles"])
        @test any(f -> occursin("corrupt", f), readdir(dir))
    finally
        rm(dir; recursive = true, force = true)
    end
end

# ---------------------------------------------------------------------------
@testset "progress: marking done and undone by hand" begin
    dir = mktempdir()
    try
        path = joinpath(dir, "progress.json")
        s = load_store(path)

        # --- mark done -----------------------------------------------------
        set_solved!(s, "two-sum"; solved = true)
        e = entry_for(s, "two-sum")
        @test e["solved"] === true
        @test e["manual"] === true          # flagged, so it is never mistaken
        @test e["solved_at"] !== nothing    #   for a verified solve
        @test e["attempts"] == 0            # marking is not an attempt

        # --- mark undone: completion clears, history survives ---------------
        save_draft!(s, "two-sum", "my work in progress")
        take_hint!(s, "two-sum", 2)
        set_solved!(s, "two-sum"; solved = false)
        e = entry_for(s, "two-sum")
        @test e["solved"] === false
        @test e["manual"] === false
        @test e["solved_at"] === nothing
        @test e["draft"] == "my work in progress"   # work is never destroyed
        @test e["hints_used"] == 2

        # --- earning it supersedes claiming it -----------------------------
        set_solved!(s, "greet"; solved = true)
        @test entry_for(s, "greet")["manual"] === true
        record_attempt!(s, "greet"; solved = true, wall_ms = 800, code = "greet(n)=1")
        e = entry_for(s, "greet")
        @test e["solved"] === true
        @test e["manual"] === false         # a real pass clears the manual flag
        @test e["best_ms"] == 800

        # --- survives a reload ---------------------------------------------
        set_solved!(s, "fizzbuzz"; solved = true)
        s2 = load_store(path)
        @test entry_for(s2, "fizzbuzz")["manual"] === true
        @test entry_for(s2, "two-sum")["solved"] === false

        # --- a file written before `manual` existed still loads -------------
        write(path, """{"version":1,"puzzles":{"old":{"solved":true,"attempts":3,
              "hints_used":0,"solution_viewed":false,"draft":"","best_ms":null,
              "solved_at":null}}}""")
        s3 = load_store(path)
        e = entry_for(s3, "old")
        @test e["manual"] === false         # backfilled, not an error
        @test e["solved"] === true
        @test e["attempts"] == 3
    finally
        rm(dir; recursive = true, force = true)
    end
end

# ---------------------------------------------------------------------------
@testset "puzzles: all 15 valid, all solutions pass, all starters fail (§11)" begin
    puzzles, problems = load_puzzles(ROOT)

    @test isempty(problems)
    @test length(puzzles) == 15

    # Ids and entrypoints are unique and the ordering is the directory order.
    @test length(unique(p.id for p in puzzles)) == length(puzzles)
    @test issorted([p.order for p in puzzles])

    # load_puzzles already refuses any puzzle whose solution fails or whose
    # starter passes, so reaching 15 proves both. Assert the parts explicitly
    # so a failure names which half broke.
    for p in puzzles
        sol = run_submission(ROOT, p.dir, p.solution)
        @test sol.result !== nothing
        @test sol.result["ok"] === true          # every reference solution passes

        starter = run_submission(ROOT, p.dir, p.starter)
        passed = starter.result !== nothing && starter.result["ok"] === true
        @test !passed                            # every starter fails
    end

    # Every puzzle carries hints and at least one hidden case.
    for p in puzzles
        @test !isempty(p.hints)
        @test p.hidden_count >= 1
        @test !isempty(visible_cases(p))
    end
end

# ---------------------------------------------------------------------------
@testset "puzzles: a broken puzzle is skipped, not served" begin
    root = mktempdir()
    try
        # load_puzzles(root) treats `root` as the application root — it needs to
        # find runner.jl there to validate anything — so give the temp tree one.
        cp(joinpath(ROOT, "runner.jl"), joinpath(root, "runner.jl"))

        # A valid one and a corrupt one side by side.
        good = joinpath(root, "puzzles", "01-good")
        mkpath(good)
        write(joinpath(good, "meta.json"),
              """{"id":"good","title":"Good","track":"idioms","difficulty":1,
                  "entrypoint":"f","teaches":[],"hints":["h"]}""")
        write(joinpath(good, "problem.md"), "x")
        write(joinpath(good, "starter.jl"), "f(n) = 0")
        write(joinpath(good, "solution.jl"), "f(n) = n")
        write(joinpath(good, "tests.jl"), "case(1; expect = 1)\nhidden(2; expect = 2)\n")

        bad = joinpath(root, "puzzles", "02-bad")
        mkpath(bad)
        write(joinpath(bad, "meta.json"), "{ not json ,,,")
        write(joinpath(bad, "problem.md"), "x")
        write(joinpath(bad, "starter.jl"), "g(n) = 0")
        write(joinpath(bad, "solution.jl"), "g(n) = n")
        write(joinpath(bad, "tests.jl"), "case(1; expect = 1)\n")

        # A third whose solution simply does not work.
        wrong = joinpath(root, "puzzles", "03-wrong")
        mkpath(wrong)
        write(joinpath(wrong, "meta.json"),
              """{"id":"wrong","title":"Wrong","track":"idioms","difficulty":1,
                  "entrypoint":"h","teaches":[],"hints":["h"]}""")
        write(joinpath(wrong, "problem.md"), "x")
        write(joinpath(wrong, "starter.jl"), "h(n) = 0")
        write(joinpath(wrong, "solution.jl"), "h(n) = n + 1")
        write(joinpath(wrong, "tests.jl"), "case(1; expect = 1)\n")

        puzzles, problems = load_puzzles(root)
        @test length(puzzles) == 1
        @test puzzles[1].id == "good"
        @test length(problems) == 2
        @test any(pr -> pr[1] == "02-bad"   && occursin("parse", pr[2]),    problems)
        @test any(pr -> pr[1] == "03-wrong" && occursin("fails", pr[2]),    problems)
    finally
        rm(root; recursive = true, force = true)
    end
end

end # testset
