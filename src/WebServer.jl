module WebServer

using HTTP, JSON3
using Pkg: TOML

const ASSETS_DIR = normpath(joinpath(@__DIR__, "..", "assets"))

json_response(status, body) =
    HTTP.Response(status, ["Content-Type" => "application/json"], JSON3.write(body))

function serve_file(path::AbstractString, content_type::AbstractString)
    return req -> HTTP.Response(200, ["Content-Type" => content_type], read(path))
end

# Other services in this deployment sit behind an authenticating proxy, so
# outgoing requests need a bearer token. The token lives in the Julia
# package server auth file for whichever server JULIA_PKG_SERVER points at.
function auth_header()
    server = get(ENV, "JULIA_PKG_SERVER", "")
    isempty(server) && return Pair{String,String}[]
    path = joinpath(homedir(), ".julia", "servers", server, "auth.toml")
    isfile(path) || return Pair{String,String}[]
    token = get(TOML.parsefile(path), "access_token", nothing)
    token === nothing && return Pair{String,String}[]
    return ["Authorization" => "Bearer $token"]
end

function fetch_json(url::AbstractString)
    resp = HTTP.get(url, auth_header(); readtimeout = 5)
    return JSON3.read(String(resp.body))
end

function handle_api_data(dbservice_url::AbstractString, req::HTTP.Request)
    params = HTTP.queryparams(HTTP.URI(req.target))
    instrument_id = get(params, "instrument_id", "inst-1")
    limit = get(params, "limit", "200")
    query = "instrument_id=$(HTTP.escapeuri(instrument_id))&limit=$(HTTP.escapeuri(limit))"

    try
        raw = fetch_json("$dbservice_url/raw?$query")
        processed = fetch_json("$dbservice_url/processed?$query")
        return json_response(200, (raw = raw, processed = processed))
    catch e
        @warn "failed to reach DBService" exception = (e, catch_backtrace())
        return json_response(502, (error = "DBService unavailable: $(sprint(showerror, e))",))
    end
end

function build_router(dbservice_url::AbstractString)
    router = HTTP.Router()
    HTTP.register!(router, "GET", "/", serve_file(joinpath(ASSETS_DIR, "dashboard.html"), "text/html; charset=utf-8"))
    HTTP.register!(router, "GET", "/chart.umd.min.js", serve_file(joinpath(ASSETS_DIR, "chart.umd.min.js"), "application/javascript"))
    HTTP.register!(router, "GET", "/api/data", req -> handle_api_data(dbservice_url, req))
    HTTP.register!(router, "GET", "/health", req -> json_response(200, (status = "ok",)))
    return router
end

function main()
    dbservice_url = get(ENV, "DBSERVICE_URL", "https://dbservice.apps.nkottary.juliahub.dev")
    port = parse(Int, get(ENV, "WEBSERVER_PORT", "8080"))
    router = build_router(dbservice_url)
    @info "WebServer listening" port dbservice_url
    HTTP.serve(router, "0.0.0.0", port)
end

end # module WebServer
