# Julia Gym — build plan

A LeetCode-style practice app for learning Julia, running as a **local web app** on
`http://localhost:8080`. Submissions are executed by the **real `julia` binary** already
installed on this machine — no interpreter emulation, no cloud calls, no network required
after first setup.

Hand this file to Claude Code as the spec. Work through the milestones in order; each one
ends in a state you can run and see.

---

## 1. Product definition

**Audience:** someone who already programs (loops, functions, recursion are familiar) but is
new to Julia. Puzzles teach Julia's syntax and idioms rather than programming fundamentals.

**Core loop:** pick a puzzle → read the problem → write a function in the editor → hit Run →
see each test case pass or fail with real Julia output and real Julia error messages → solve
it → the puzzle turns green and the next one unlocks.

**Three tracks**, interleaved by difficulty rather than siloed:

| Track | What it drills |
|---|---|
| **Idioms** | 1-based indexing, `end` in slices, string interpolation, `/` vs `÷`, comprehensions, broadcasting with `.`, the `!` mutation convention, ranges |
| **Algorithms** | LeetCode-flavored classics — fizzbuzz, two-sum, Kadane, binary search, anagrams — written in Julia |
| **Wrangling** | `Dict`, `Set`, `filter`/`map`/`reduce`, sorting with `by=`/`rev=`, grouping, counting |

**Explicit non-goals for v1:** user accounts, multiplayer, a puzzle authoring UI, remote
deployment, Docker, mobile layout beyond "it doesn't break".

---

## 2. Architecture

```
browser (vanilla JS SPA)
   │  fetch JSON
   ▼
server.jl            ← HTTP.jl, serves static files + /api/*
   │  spawn, JSON over stdout
   ▼
runner.jl            ← fresh child `julia` process per submission
   │  include user code in a sandbox module, run the puzzle's tests.jl
   ▼
structured JSON result → server → browser
```

**Why a child process per run:** isolation. A submission that infinite-loops, defines a
conflicting method, or calls `exit()` must not take the server down. The child is killed on
timeout and the server keeps serving.

**Stack decisions (do not substitute without saying why):**

- **Backend: Julia + `HTTP.jl`.** One dependency, and it keeps the whole app in the language
  being taught. If `Pkg.add("HTTP")` cannot reach the network, fall back to a stdlib
  `Sockets`-based server that handles `GET`/`POST` with `Content-Length` bodies only — write
  it behind the same internal interface so the rest of the app doesn't care.
- **Frontend: no build step.** Plain HTML + CSS + ES modules served from `public/`. No npm,
  no bundler, no framework. The whole point is `julia server.jl` and it works.
- **Editor: CodeMirror 6** loaded from a CDN with the Julia legacy mode, **vendored into
  `public/vendor/` on first setup** so the app works offline afterward. If vendoring fails,
  degrade to a styled `<textarea>` with tab-to-indent — the app must never be unusable
  because a CDN is unreachable.
- **Persistence: a JSON file on disk** (`data/progress.json`), written through the API. Not
  localStorage — progress should survive a browser cache clear and be greppable.

---

## 3. File layout

```
julia-gym/
├── Project.toml            # deps: HTTP, JSON3
├── server.jl               # entry point: julia --project=. server.jl
├── src/
│   ├── Router.jl           # request routing + static file serving
│   ├── Puzzles.jl          # load + validate puzzle directory at boot
│   ├── Execute.jl          # spawn/timeout/capture the child process
│   └── Progress.jl         # read/write data/progress.json atomically
├── runner.jl               # child process entry point (stdlib only)
├── puzzles/
│   └── 01-greet/
│       ├── meta.json       # id, title, track, difficulty, function name, hints
│       ├── problem.md      # the statement the player reads
│       ├── starter.jl      # what's pre-filled in the editor
│       ├── solution.jl     # reference solution (also used as a self-test)
│       └── tests.jl        # sample + hidden cases
├── public/
│   ├── index.html
│   ├── app.js
│   ├── styles.css
│   └── vendor/             # codemirror bundle, vendored at setup
├── data/progress.json      # created on first run
└── test/runtests.jl        # server-side tests
```

---

## 4. Puzzle format

A puzzle is a directory. Adding one means adding a folder — no registry file to edit, no code
to touch. `Puzzles.jl` globs `puzzles/*/` at boot, sorts by directory name, and **validates
every puzzle**: required files present, `meta.json` parses, and the reference solution passes
its own tests. A puzzle that fails validation is logged loudly and skipped, not silently
served broken.

**`meta.json`**

```json
{
  "id": "two-sum",
  "title": "Two Sum, One-Indexed",
  "track": "algorithms",
  "difficulty": 2,
  "entrypoint": "two_sum",
  "teaches": ["1-based indexing", "Dict lookup", "tuples"],
  "hints": [
    "A Dict maps each value you've already seen to the index you saw it at.",
    "Julia indexes from 1 — if you port a Python solution, the answer is off by one.",
    "Return a tuple: `(i, j)`."
  ]
}
```

**`tests.jl`** — a tiny DSL provided by the runner, so puzzle authors write plain Julia:

```julia
case([2, 7, 11, 15], 9; expect = (1, 2))
case([3, 2, 4], 6;      expect = (2, 3))
hidden([1, 2], 3;       expect = (1, 2))
hidden(collect(1:1000), 1999; expect = (999, 1000))
```

- `case(args...; expect)` — visible to the player before running, listed in the problem pane.
- `hidden(args...; expect)` — shown only after a run, and only as pass/fail plus the input
  (never pre-revealed) so the player can't pattern-match to the answer.
- `expect` compares with `==` by default. Support `expect_fn = got -> ...` for problems with
  multiple valid answers, and `atol` for floats.
- Support a `stdout` keyword for the handful of puzzles that are about printing.

**Type strictness matters here.** `3` and `3.0` are different types in Julia and one of the
puzzles exists specifically to teach that. The comparison must therefore check `typeof` for
numeric results, not just `==`, and the failure message must say
`expected 3.0::Float64, got 3::Int64` — that error *is* the lesson.

---

## 5. The runner (`runner.jl`)

Invoked as:

```
julia --startup-file=no --history-file=no --color=no runner.jl <puzzle-dir> <submission-file>
```

Sequence:

1. Read the submission and `include_string` it into a **fresh anonymous module**, so the
   player can't clobber `Base` for the harness and repeated runs never collide.
2. Check the module actually defines `meta.entrypoint`. If not, emit a friendly error:
   `Define a function named two_sum — I couldn't find it.` (This is the single most common
   failure mode; do not let it surface as a raw `UndefVarError`.)
3. For each case: redirect `stdout`/`stderr` into a buffer, call the function inside a
   `try`, record `got`, `stdout`, elapsed µs, and any exception.
4. Emit **one JSON object on the final line of stdout**, prefixed with a sentinel like
   `__JULIA_GYM_RESULT__`, so any stray printing from user code before it can't corrupt the
   parse.

Result shape:

```json
{
  "ok": true,
  "defined": true,
  "cases": [{
    "hidden": false,
    "input": "[2, 7, 11, 15], 9",
    "expected": "(1, 2)",
    "got": "(2, 1)",
    "pass": false,
    "stdout": "",
    "error": null,
    "elapsed_us": 41
  }],
  "compile_ms": 220
}
```

**Rendering values:** use `repr()` for expected/got so the player sees real Julia syntax
(`[1, 2, 3]`, `"abc"`, `'x'`, `Dict("a" => 1)`), and truncate any single rendered value past
~400 chars with a `…` marker.

**Errors:** capture the exception and the first ~12 stack frames, strip frames belonging to
the harness, and rewrite the submission's frames to the line numbers the player sees in the
editor (`include_string` with a line offset of 0 and the filename `submission.jl` makes this
line up). A `BoundsError` pointing at the wrong line is worse than no line at all.

---

## 6. Execution safety and speed

This app runs code the user themselves typed, on their own machine — it is not a hostile
multi-tenant sandbox, and the plan should not pretend otherwise. But it must be *robust*:

- **Timeout:** 5 s wall clock per submission. Kill the process group (`SIGKILL` after
  `SIGTERM`), and report `Your code ran longer than 5 seconds — likely an infinite loop.`
- **Output cap:** stop capturing after 64 KB of stdout and note the truncation. A `while true;
  println("x"); end` must not fill memory or the browser.
- **One run at a time per client**, enforced server-side; the Run button disables while in
  flight.
- **Working directory** for the child is a scratch dir, not the puzzle dir.
- **Startup latency:** Julia's cold start plus compile is ~0.3–1.0 s. Ship v1 as
  process-per-run and *measure*. If the p50 is above ~1.2 s, add a warm worker: a persistent
  `julia` process kept by the server that receives jobs on stdin, runs each in a fresh module,
  and is recycled after 25 jobs or any timeout. Keep process-per-run as the fallback path —
  the warm pool is an optimization, not the contract.

---

## 7. HTTP API

| Method | Path | Body / returns |
|---|---|---|
| `GET` | `/api/puzzles` | List: id, title, track, difficulty, solved, best time. No solutions. |
| `GET` | `/api/puzzles/:id` | Problem markdown (rendered client-side), starter code, sample cases, hint count, saved draft. **Never** the reference solution. |
| `POST` | `/api/run` | `{puzzle, code}` → the runner result. Persists the draft. On all-pass, marks solved. |
| `GET` | `/api/puzzles/:id/hint?n=1` | One hint at a time; records how many were taken. |
| `GET` | `/api/puzzles/:id/solution` | The reference solution. Gated behind an explicit client confirm; records that it was viewed. |
| `GET` | `/api/progress` | Solved set, attempts, hints used, drafts. |
| `POST` | `/api/reset` | Clears progress (with a confirm in the UI). |

Solutions and hidden-case expectations must not be in the initial page payload — if they're
in the HTML, the game is over the first time someone opens devtools.

---

## 8. Interface

Three regions on desktop, stacked on narrow screens:

```
┌──────────┬───────────────────────┬────────────────────────┐
│ puzzles  │  problem statement    │  editor                │
│ (rail)   │  examples             │  [Run ⌘↵]  [Hint]      │
│ ●●○○○    │  what it teaches      ├────────────────────────┤
│          │                       │  test results + stdout │
└──────────┴───────────────────────┴────────────────────────┘
```

**Visual direction — derive it from Julia itself, not from a generic dark IDE theme.** The
language's identity is three dots in red, green, and purple; use them as the actual state
system rather than decoration:

- **Palette:** Julia purple `#9558B2` as the single accent, Julia green `#389826` for pass,
  Julia red `#CB3C33` for fail, Julia blue `#4063D8` for "running". Neutrals biased slightly
  toward violet — a plain `#808080` grey reads as unconsidered next to those.
- **Progress rail:** each puzzle is a dot. Unsolved is an outline, solved fills in, solved
  without hints gets the full three-dot logo mark. The motif is load-bearing, not applied.
- **Type:** a characterful display face for headings paired with `JuliaMono` or `IBM Plex
  Mono` for all code and all data (test tables get `font-variant-numeric: tabular-nums`).
  Avoid Inter and Space Grotesk — they're the default everything-looks-the-same choice.
- **Themes:** define the full light palette on `:root`, redefine only the tokens under
  `@media (prefers-color-scheme: dark)`, and style every component through tokens. Never
  declare a color only inside a media query.

**Interaction requirements:**

- `Ctrl/⌘+Enter` runs. `Esc` closes the hint or solution panel. Focus states are visible.
- Test results animate in one row at a time (~60 ms stagger) — it reads as the suite running.
  Respect `prefers-reduced-motion`.
- A failing case shows input, expected, got, and stdout side by side, monospaced and aligned.
  A Julia exception shows the real message and the mapped line number.
- Drafts autosave (debounced ~800 ms) so a reload never loses work.
- Hints reveal one at a time and say how many remain.

---

## 9. Initial puzzle set (15)

Ship all fifteen in v1 — a practice app with three puzzles isn't a practice app. Ordered by
difficulty; the track is a tag, not a section.

| # | id | Teaches |
|---|---|---|
| 1 | `greet` | String interpolation `"Hello, $name!"` |
| 2 | `middle-slice` | 1-based indexing, `v[2:end-1]` |
| 3 | `divide-three-ways` | `/` gives `Float64`, `÷` gives `Int`, `%` — the type lesson |
| 4 | `squares` | Comprehension `[i^2 for i in 1:n]` |
| 5 | `shout-all` | Broadcasting `uppercase.(words)` |
| 6 | `fizzbuzz` | Conditionals; returns `Vector{String}`, not printing |
| 7 | `record-score!` | The `!` convention, mutating a `Dict`, returning it |
| 8 | `palindrome?` | Strings, `filter`, `lowercase`, `reverse` |
| 9 | `two-sum` | `Dict` lookup, tuples, and the 1-based off-by-one trap |
| 10 | `word-count` | `split`, `Dict` accumulation, `get` with a default |
| 11 | `top-words` | Sorting pairs with `by=` and `rev=`, tie-breaking |
| 12 | `group-by-initial` | `Dict{Char, Vector{String}}`, `push!` into a fetched value |
| 13 | `binary-search` | Ranges, `÷` for the midpoint, returning `nothing` |
| 14 | `longest-run` | Single-pass scanning, `enumerate` |
| 15 | `max-subarray` | Kadane's; `max`, accumulator patterns |

Each `problem.md` is short: one paragraph of framing, a worked example with a real
input/output pair, and a one-line **"Julia note"** calling out the idiom in play. Do not
write tutorials — the puzzle teaches by being failed.

---

## 10. Milestones

Each milestone must end runnable. Do not start the next one with the previous one broken.

**M1 — Serve something.** `Project.toml`, `server.jl`, static file serving, a page that says
hello. `julia --project=. server.jl` opens on `:8080`. *Verify:* the page loads.

**M2 — Execute Julia.** `runner.jl` + `Execute.jl`. A hardcoded submission and a hardcoded
test file produce a JSON result at the terminal. *Verify:* a passing case, a failing case, a
throwing case, and an infinite loop all produce correct JSON — the infinite loop in ≤5 s.

**M3 — Puzzles on disk.** Puzzle loader, validator, first three puzzle directories.
*Verify:* boot-time validation runs every reference solution against its own tests and all
pass; corrupt one deliberately and confirm it's reported and skipped.

**M4 — API.** All endpoints from §7 plus `Progress.jl` with atomic writes (temp file +
rename). *Verify:* `curl` each endpoint; confirm no endpoint leaks a solution.

**M5 — Interface.** Layout, editor, run, results, hints, progress rail, both themes.
*Verify:* solve a puzzle end to end without touching the terminal.

**M6 — Content.** All 15 puzzles. *Verify:* every reference solution passes; every starter
file *fails* (a starter that accidentally passes is a bug).

**M7 — Polish.** Keyboard shortcuts, autosave, animations, empty and error states, and the
latency measurement from §6 — add the warm worker only if the numbers call for it.

---

## 11. Definition of done

- [ ] `julia --project=. server.jl` is the only command needed to start, and it prints the URL.
- [ ] First-run setup (`Pkg.instantiate`, vendoring the editor) is automatic or one documented command.
- [ ] All 15 reference solutions pass; all 15 starters fail.
- [ ] Infinite loop, `exit()`, a 100 MB print, and a syntax error each produce a clean UI
      message and leave the server up.
- [ ] Wrong-type answers (`3` for `3.0`) fail with a message naming both types.
- [ ] No solution text reachable without hitting the gated endpoint.
- [ ] Works with the network off after setup.
- [ ] Readable in light and dark; no color defined only inside a media query.
- [ ] `julia --project=. test/runtests.jl` covers the runner, the comparison logic, the
      timeout path, and progress persistence.

---

## 12. Notes for whoever builds this

- The interesting engineering is in §5 and §6 — the harness and the failure modes. The UI is
  straightforward once the result JSON is right. Build in that order.
- Every error message a player sees is product copy. `UndefVarError: two_sum not defined` is a
  failure of the app, not of the player.
- Resist adding a puzzle editor, a leaderboard, or accounts. The value is 15 good puzzles and
  a run loop that feels instant.
