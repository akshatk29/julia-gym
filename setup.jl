#!/usr/bin/env julia
#
# First-run setup: install dependencies and vendor the editor + fonts into
# public/vendor/ so the app works with the network off afterwards.
#
# Idempotent — every step is skipped if its output already exists. Safe to run
# on every boot, which is what server.jl does.
#
# Run standalone with:  julia --project=. setup.jl

const ROOT   = @__DIR__
const VENDOR = joinpath(ROOT, "public", "vendor")

const ASSETS = [
    # (destination filename, url)
    ("codemirror.js",  "https://cdn.jsdelivr.net/npm/codemirror@5.65.16/lib/codemirror.js"),
    ("codemirror.css", "https://cdn.jsdelivr.net/npm/codemirror@5.65.16/lib/codemirror.css"),
    ("julia.js",       "https://cdn.jsdelivr.net/npm/codemirror@5.65.16/mode/julia/julia.js"),
    ("matchbrackets.js","https://cdn.jsdelivr.net/npm/codemirror@5.65.16/addon/edit/matchbrackets.js"),
    ("closebrackets.js","https://cdn.jsdelivr.net/npm/codemirror@5.65.16/addon/edit/closebrackets.js"),
    ("plex-mono-400.woff2", "https://cdn.jsdelivr.net/npm/@fontsource/ibm-plex-mono@5.0.13/files/ibm-plex-mono-latin-400-normal.woff2"),
    ("plex-mono-600.woff2", "https://cdn.jsdelivr.net/npm/@fontsource/ibm-plex-mono@5.0.13/files/ibm-plex-mono-latin-600-normal.woff2"),
    ("fraunces-var.woff2",  "https://cdn.jsdelivr.net/npm/@fontsource-variable/fraunces@5.0.20/files/fraunces-latin-wght-normal.woff2"),
]

"""
    ensure_deps()

`Pkg.instantiate()` the project. Cheap and silent once the manifest is resolved.
"""
function ensure_deps()
    if !isfile(joinpath(ROOT, "Manifest.toml"))
        @info "Installing Julia dependencies (first run)…"
        run(`$(Base.julia_cmd()[1]) --startup-file=no --project=$ROOT -e "using Pkg; Pkg.instantiate()"`)
    end
end

"""
    vendor_assets(; force=false) -> (fetched, skipped, failed)

Download each missing asset. A failure is logged, not fatal: the frontend degrades
to a plain textarea and system fonts when the vendor directory is incomplete.
"""
function vendor_assets(; force::Bool=false)
    mkpath(VENDOR)
    fetched, skipped, failed = String[], String[], String[]
    for (name, url) in ASSETS
        dest = joinpath(VENDOR, name)
        if !force && isfile(dest) && filesize(dest) > 0
            push!(skipped, name); continue
        end
        tmp = dest * ".part"
        try
            # curl is present on every macOS/Linux box and avoids pulling a
            # Downloads-vs-TLS dependency into the request path.
            run(pipeline(`curl -fsSL --max-time 45 -o $tmp $url`; stdout=devnull, stderr=devnull))
            filesize(tmp) > 0 || error("empty download")
            mv(tmp, dest; force=true)
            push!(fetched, name)
        catch e
            isfile(tmp) && rm(tmp; force=true)
            @warn "Could not vendor $name — the app will fall back gracefully." url exception=e
            push!(failed, name)
        end
    end
    return (fetched, skipped, failed)
end

"""
    vendor_complete() -> Bool

True when every asset is present and non-empty.
"""
vendor_complete() = all(a -> (p = joinpath(VENDOR, a[1]); isfile(p) && filesize(p) > 0), ASSETS)

function main()
    ensure_deps()
    fetched, skipped, failed = vendor_assets(; force = "--force" in ARGS)
    println("Setup: $(length(fetched)) fetched, $(length(skipped)) already present, $(length(failed)) failed.")
    isempty(failed) || println("Failed: ", join(failed, ", "), " — run `julia --project=. setup.jl` again when online.")
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    main()
end
