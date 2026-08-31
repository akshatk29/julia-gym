# Julia Gym

A LeetCode-style practice app for learning Julia, running as a local web app.
Submissions are executed by the real `julia` binary on this machine — no
interpreter emulation, no cloud calls, no network needed after first setup.

Built to the spec in [`JULIA_GYM_PLAN.md`](JULIA_GYM_PLAN.md).

## Run it

**Double-click `Julia Gym.app`.** The browser opens on its own when the server
is ready (a few seconds — it validates all 15 puzzles at boot by running them).

On a fresh clone the app does not exist yet — build it once, then double-click it:

```bash
./build/make_app.sh
```

All three do the same thing:

| | |
|---|---|
| `Julia Gym.app` | Double-click. Quitting the app stops the server. |
| `start.command` | Double-click. Opens a Terminal window showing the server log; Ctrl-C stops it. |
| `julia --project=. server.jl` | The plain command. `--port N` to use a different port. |

Julia must be installed (<https://julialang.org/downloads/>); the launchers
look for it in the usual places and say so plainly if it is missing. Everything
else — dependencies and the vendored editor — is installed automatically on the
first run, after which the app is fully offline.

### A note on the app and macOS permissions

This project lives under `~/Library/CloudStorage`, which macOS protects. An app
launched from Finder has no access grant there, and because `Julia Gym.app` is
built locally rather than signed by a registered developer, macOS refuses it
*silently* instead of prompting.

So the app checks whether it can actually read the project folder, and when it
cannot it hands the job to Terminal — which does hold that permission — by
running `start.command` there. The result is the same: one double-click, the
browser opens. You may see a one-time *"Julia Gym wants to control Terminal"*
prompt; allow it.

If you would rather the app run the server itself with no Terminal window, add
it under **System Settings › Privacy & Security › Full Disk Access**. It will
then take the direct path. Moving the project somewhere unprotected (say
`~/Projects`) has the same effect.

Re-run `./build/make_app.sh` after changing the launcher or the icon.

## While you play

**Closing the browser stops the server.** There is nothing to Ctrl-C. The page
tells the server it is leaving as it unloads, and sends a heartbeat while it is
open as a backstop for the cases where it cannot — a crash, or a force-quit.

Switching to another tab does *not* stop it. That distinction is the reason for
two signals rather than one: browsers throttle background timers to roughly one
tick a minute, so a heartbeat deadline short enough to feel responsive would
shut the game down merely because you looked at another tab. The explicit
goodbye handles the common case in a few seconds; the heartbeat deadline is two
minutes and only catches the rest. A reload survives both.

Use `--keep-alive` to switch this off and leave the server running.

**Marking a puzzle done by hand.** The toolbar button marks the current puzzle
complete, and reads *Mark undone* once it is, so you can put it back. Marking
undone keeps your attempts, hints and saved draft — only the completion is
cleared.

A puzzle ticked off by hand gets a filled dot on the rail but not the three-dot
mark; that stays reserved for a puzzle solved by passing its tests with no
hints and no look at the solution. Passing the tests later upgrades a manual
tick to a real solve.

Looking at the reference solution does **not** mark a puzzle complete — it only
records that you looked, which costs the three-dot mark.

## Flags

```
julia --project=. server.jl [--port 8080] [--data PATH] [--keep-alive] [--no-validate]
```

`--data PATH` points progress at a different file. Use it for experiments and
throwaway runs so they cannot touch your real solves and drafts.

## Tests

```bash
julia --project=. test/runtests.jl
```

188 assertions covering the comparison logic, the runner's result shape, the
timeout and abort paths, stdout capture and truncation, progress persistence,
and the invariant that every reference solution passes while every starter
fails.

## Layout

```
server.jl          entry point — routing, the API, boot
runner.jl          child process: sandboxes a submission, runs its tests   (stdlib only)
setup.jl           dependency install + asset vendoring, idempotent
src/Router.jl      static files, route matching
src/Puzzles.jl     puzzle loading and boot-time validation
src/Execute.jl     spawn / timeout / capture
src/Progress.jl    atomic read-write of data/progress.json
puzzles/NN-<id>/   one directory per puzzle
public/            the frontend — no build step, no npm
```

## Adding a puzzle

Create a directory under `puzzles/` and restart. There is no registry to edit.
It needs five files:

| File | What it is |
|---|---|
| `meta.json` | `id`, `title`, `track`, `difficulty`, `entrypoint`, `teaches`, `hints` |
| `problem.md` | the statement — one paragraph, a worked example, one **Julia note** |
| `starter.jl` | what is pre-filled in the editor; it **must fail** the tests |
| `solution.jl` | the reference solution; it **must pass** |
| `tests.jl` | the cases |

`tests.jl` uses a two-function DSL:

```julia
case([2, 7, 11, 15], 9; expect = (1, 2))   # shown in the problem pane
hidden([1, 2], 3;       expect = (1, 2))   # pass/fail and input only, never the expectation
```

Keywords: `expect`, `expect_fn = got -> ...` for problems with several valid
answers, `atol` for floats, and `stdout` for the puzzles that are about
printing.

Comparison is **type-strict**: `3` does not satisfy an expectation of `3.0`, and
the failure says `expected 3.0::Float64, got 3::Int64`. That error is the
lesson, not an inconvenience.

At boot every puzzle is validated by running its reference solution against its
own tests, and its starter to confirm the starter fails. Anything that does not
hold is logged loudly and skipped — a broken puzzle is never served.

## Notes on the implementation

- **A fresh child process per submission.** Isolation: an infinite loop, a call
  to `exit()`, or a 100 MB print cannot take the server down. Timeout is 5 s,
  enforced with `SIGTERM` then `SIGKILL` to the child's process group.
- **`runner.jl` loads no packages.** Its cost is paid on every run, so it hand-
  writes its JSON. The child runs at `-O0`, which cuts startup from ~1.05 s to
  ~0.74 s without changing any result.
- **No warm worker.** §6 says to add one only if the p50 exceeds ~1.2 s.
  Measured over 20 full HTTP round trips: p50 **816 ms**, p90 877 ms. Process-
  per-run stands.
- **Solutions never leave the server** except through
  `GET /api/puzzles/:id/solution`, which records that it was viewed. Hidden
  cases' expectations are stripped from every run result before it is sent.
- **Editor: CodeMirror 5**, not 6. CM6 ships only as an unbundled ES-module
  graph, which cannot be vendored without a build step — and "no build step" is
  the harder constraint. CM5 is two UMD files with a first-class Julia mode. If
  the vendor directory is missing, the editor degrades to a styled textarea and
  the app stays usable.
