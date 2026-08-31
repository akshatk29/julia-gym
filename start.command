#!/bin/bash
#
# Julia Gym — double-click to play, with the server log visible.
#
# Use this when you want to see what the server is doing. For a plain app icon
# with no terminal window, double-click "Julia Gym.app" instead.
#
# Ctrl-C, or closing this window, stops the server.

set -u
cd "$(dirname "$0")" || exit 1
PORT=8080
URL="http://localhost:${PORT}"

# Finder runs .command files through a login shell, so PATH is usually fine —
# but check anyway and say something useful if Julia is missing.
if ! command -v julia >/dev/null 2>&1; then
    for c in /opt/homebrew/bin/julia /usr/local/bin/julia "$HOME/.juliaup/bin/julia"; do
        [ -x "$c" ] && { PATH="$(dirname "$c"):$PATH"; break; }
    done
fi
if ! command -v julia >/dev/null 2>&1; then
    echo
    echo "  Julia isn't installed, or isn't on your PATH."
    echo "  Get it from https://julialang.org/downloads/ and run this again."
    echo
    read -r -p "  Press Return to close." _
    exit 1
fi

if curl -sf --max-time 2 "$URL/api/health" >/dev/null 2>&1; then
    echo "  Julia Gym is already running — opening $URL"
    open "$URL"
    exit 0
fi

# Open the browser once the server answers, without blocking the server itself.
(
    for _ in $(seq 1 90); do
        curl -sf --max-time 1 "$URL/api/health" >/dev/null 2>&1 && { open "$URL"; exit 0; }
        sleep 1
    done
) &

echo
echo "  Starting Julia Gym — the browser will open when it's ready."
echo "  Press Ctrl-C to stop."
echo
exec julia --startup-file=no --project=. server.jl --port "$PORT"
