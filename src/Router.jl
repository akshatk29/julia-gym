"""
    Router

Static file serving and small routing helpers. Deliberately thin: `server.jl` owns
the handler table, this module only knows how to turn a path into bytes and how to
match a request against a route pattern.
"""
module Router

export static_response, match_route, json_response, text_response, MIME_TYPES

const MIME_TYPES = Dict(
    ".html" => "text/html; charset=utf-8",
    ".js"   => "text/javascript; charset=utf-8",
    ".mjs"  => "text/javascript; charset=utf-8",
    ".css"  => "text/css; charset=utf-8",
    ".json" => "application/json; charset=utf-8",
    ".svg"  => "image/svg+xml",
    ".png"  => "image/png",
    ".ico"  => "image/x-icon",
    ".woff2"=> "font/woff2",
    ".woff" => "font/woff",
    ".ttf"  => "font/ttf",
    ".map"  => "application/json; charset=utf-8",
    ".md"   => "text/markdown; charset=utf-8",
)

mime_for(path) = get(MIME_TYPES, lowercase(splitext(path)[2]), "application/octet-stream")

"""
    safe_join(root, urlpath) -> String or nothing

Resolve a URL path against `root`, refusing anything that escapes it. Returns
`nothing` for traversal attempts or missing files.
"""
function safe_join(root::AbstractString, urlpath::AbstractString)
    rel = urlpath
    rel = replace(rel, '\\' => '/')
    rel = lstrip(rel, '/')
    rel = isempty(rel) ? "index.html" : rel
    # Reject traversal before touching the filesystem.
    any(seg -> seg == ".." , split(rel, '/')) && return nothing
    full = normpath(joinpath(root, rel))
    rootn = normpath(root)
    startswith(full, rootn * (endswith(rootn, "/") ? "" : "/")) || full == rootn || return nothing
    isfile(full) || return nothing
    return full
end

"""
    static_response(root, urlpath) -> HTTP-style (status, headers, body) tuple or nothing
"""
function static_response(root::AbstractString, urlpath::AbstractString)
    full = safe_join(root, urlpath)
    full === nothing && return nothing
    body = read(full)
    headers = ["Content-Type" => mime_for(full),
               "Cache-Control" => "no-cache"]
    return (200, headers, body)
end

"""
    match_route(pattern, path) -> Dict{String,String} or nothing

Matches `/api/puzzles/:id/hint` against `/api/puzzles/two-sum/hint`, returning the
captured params. Segment counts must match exactly.
"""
function match_route(pattern::AbstractString, path::AbstractString)
    pseg = split(strip(pattern, '/'), '/')
    aseg = split(strip(path, '/'), '/')
    length(pseg) == length(aseg) || return nothing
    params = Dict{String,String}()
    for (p, a) in zip(pseg, aseg)
        if startswith(p, ':')
            params[p[2:end]] = a
        elseif p != a
            return nothing
        end
    end
    return params
end

end # module
