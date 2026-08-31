#!/bin/bash
#
# Julia Gym — the executable inside "Julia Gym.app".
#
# Two things make this harder than `julia server.jl`:
#
#   1. Finder does not run your shell profile. PATH is the bare system default
#      and the working directory is `/`, so julia is located explicitly.
#
#   2. macOS TCC. This project lives under ~/Library/CloudStorage, a protected
#      location. An app launched by launchd has no grant there and is refused
#      with "Operation not permitted" — silently, with no prompt, because the
#      app is not signed by an identified developer. Terminal.app *does* hold
#      that grant, so when the denial is detected we hand off to start.command
#      through Terminal instead of failing.
#
# Normal case: start the server, wait for it to answer, open the browser, and
# stay in the foreground so the app sits in the Dock — quitting it stops the
# server.

set -u

PORT=8080
URL="http://localhost:${PORT}"

# --- Where is the project? -------------------------------------------------
# $0 is .../Julia Gym.app/Contents/MacOS/JuliaGym — two levels up is the
# bundle, and the project is the directory holding it. This keeps the app
# working if the whole folder is moved.
BUNDLE="$(cd "$(dirname "$0")/../.." && pwd)"
ROOT="$(dirname "$BUNDLE")"

# If the app was moved away from the project, fall back to the build location.
if [ ! -f "$ROOT/server.jl" ]; then
    ROOT="__PROJECT_ROOT__"
fi

# --- Talking to the user ---------------------------------------------------
# There is no terminal attached, so anything the user must see is a dialog.
say()  { /usr/bin/osascript -e "display dialog \"$1\" buttons {\"OK\"} default button 1 with title \"Julia Gym\" with icon $2" >/dev/null 2>&1; }
fail() { say "$1" stop; exit 1; }

if [ ! -f "$ROOT/server.jl" ]; then
    fail "Could not find the Julia Gym project files.\n\nExpected them in the folder containing this app, or at:\n__PROJECT_ROOT__"
fi

# --- Can we actually reach the project? ------------------------------------
# Reading one file can succeed while listing the directory is refused, so probe
# with a directory read — that is what the server needs in order to glob
# puzzles/ and write data/.
if ! /bin/ls "$ROOT/puzzles" >/dev/null 2>&1; then
    # TCC has denied us. Terminal holds the permission; let it do the work.
    if /usr/bin/osascript >/dev/null 2>&1 <<OSA
tell application "Terminal"
    activate
    do script "'${ROOT}/start.command'"
end tell
OSA
    then
        exit 0
    fi
    fail "macOS is blocking access to the Julia Gym folder, and I couldn't hand off to Terminal.\n\nEither add this app in System Settings > Privacy & Security > Full Disk Access, or double-click start.command in the project folder."
fi

# --- Find julia ------------------------------------------------------------
JULIA=""
for candidate in \
    /opt/homebrew/bin/julia \
    /usr/local/bin/julia \
    "$HOME/.juliaup/bin/julia" \
    "$HOME/.local/bin/julia" \
    /Applications/Julia*.app/Contents/Resources/julia/bin/julia
do
    if [ -x "$candidate" ]; then JULIA="$candidate"; break; fi
done
# Last resort: a login shell, which does read the user's profile.
if [ -z "$JULIA" ]; then
    JULIA="$(${SHELL:-/bin/zsh} -l -c 'command -v julia' 2>/dev/null)"
fi
if [ -z "$JULIA" ] || [ ! -x "$JULIA" ]; then
    fail "Julia isn't installed, or I couldn't find it.\n\nInstall it from julialang.org, then open this app again."
fi

cd "$ROOT" || fail "Could not open the project folder."
mkdir -p "$ROOT/data"
LOG="$ROOT/data/server.log"

# --- Already running? ------------------------------------------------------
# Opening the app twice should show the game, not fight over the port.
if /usr/bin/curl -sf --max-time 2 "$URL/api/health" >/dev/null 2>&1; then
    /usr/bin/open "$URL"
    exit 0
fi

# --- Start the server ------------------------------------------------------
"$JULIA" --startup-file=no --project="$ROOT" "$ROOT/server.jl" --port "$PORT" \
    > "$LOG" 2>&1 &
SERVER_PID=$!

# Quitting the app stops the server, rather than leaving it running invisibly.
cleanup() {
    if kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null
        sleep 0.4
        kill -9 "$SERVER_PID" 2>/dev/null
    fi
}
trap cleanup EXIT INT TERM

# --- Wait for it to answer -------------------------------------------------
# Boot validates all 15 puzzles by actually running them, so a cold start takes
# several seconds. Allow a generous window before declaring failure.
READY=0
for _ in $(seq 1 90); do
    if /usr/bin/curl -sf --max-time 1 "$URL/api/health" >/dev/null 2>&1; then
        READY=1
        break
    fi
    kill -0 "$SERVER_PID" 2>/dev/null || break     # died during boot
    sleep 1
done

if [ "$READY" -ne 1 ]; then
    DETAIL="$(tail -n 10 "$LOG" 2>/dev/null | tr '"' "'" | tr '\n' ' ')"
    fail "Julia Gym could not start.\n\nThe log is at data/server.log\n\n${DETAIL}"
fi

/usr/bin/open "$URL"

# Stay in the foreground so the app remains in the Dock.
wait "$SERVER_PID"
