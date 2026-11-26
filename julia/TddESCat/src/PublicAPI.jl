const SCORECARD_OPEN = "/api/scorecard/open"
const SCORECARD_CLOSE = "/api/scorecard/close"
const RESET_ROUTE = "/api/cmd/RESET"
const PUBLIC_STATES = ("NOT_PLAYED", "NOT_FINISHED", "WIN", "GAME_OVER")

struct ProtocolError <: Exception
    reason::String
end
Base.showerror(io::IO, error::ProtocolError) = print(io, error.reason)
expect(condition, reason) = condition || throw(ProtocolError(reason))

struct PublicClient
    environment::Dict{String,Any}
    http::HTTP.Client
    api_key::Union{Nothing,String}
end

function open_client(config::RunConfig)
    env = config.environment
    http = HTTP.Client(; cookiejar=HTTP.CookieJar(), transport=HTTP.Transport())
    return PublicClient(env, http, read_api_key(env))
end

function public_request(client::PublicClient, method, path, body=nothing)
    if method == "GET"
        path == "/api/games" || throw(ArgumentError("Unsupported public route"))
    else
        method == "POST" && path isa String &&
            (path in (SCORECARD_OPEN, SCORECARD_CLOSE, RESET_ROUTE) ||
             occursin(r"^/api/cmd/ACTION[1-7]\z", path)) ||
            throw(ArgumentError("Unsupported public route"))
    end
    headers = ["Accept" => "application/json"]
    isnothing(body) || push!(headers, "Content-Type" => "application/json")
    isnothing(client.api_key) || push!(headers, "X-API-Key" => client.api_key)
    env = client.environment
    return HTTP.request(method, env["base_url"] * path; headers, body, client=client.http,
        retry=false, redirect=false, status_exception=false,
        connect_timeout=env["connect_timeout_seconds"], request_timeout=env["request_timeout_seconds"],
        max_decompressed_size=8 << 20)
end

function response_json(bytes)
    try
        return parse_json(String(copy(bytes)))
    catch error
        error isa InterruptException && rethrow()
        throw(ProtocolError("invalid_json"))
    end
end

function list_games(client::PublicClient)
    response = public_request(client, "GET", "/api/games")
    expect(200 <= response.status < 300, "game_list_http_error")
    payload = response_json(response.body)
    expect(payload isa Vector, "invalid_game_list")
    ids = String[]
    for row in payload
        expect(row isa Dict && valid_id(get(row, "game_id", nothing)), "invalid_game_id")
        push!(ids, row["game_id"])
    end
    return sort!(unique!(ids))
end

struct PublicObservation
    game_id::String
    guid::String
    frames::Vector{Matrix{UInt8}}
    state::String
    levels_completed::Int
    win_levels::Int
    action::Dict{String,Int}
    available_actions::Vector{Int}
    full_reset::Union{Nothing,Bool}
end

coord(value) = strict_integer(value) && 0 <= value <= 63
function screen_click(x, y; origin_x=0, origin_y=0)
    all(coord, (x, y, origin_x, origin_y)) || throw(ArgumentError("Invalid screen coordinate"))
    screen_x, screen_y = Int(x) + Int(origin_x), Int(y) + Int(origin_y)
    coord(screen_x) && coord(screen_y) || throw(ArgumentError("Click outside the protocol domain"))
    return (screen_x, screen_y)
end

function matrix_frame(frame)
    expect(frame isa Vector && 1 <= length(frame) <= 64, "invalid_frame_height")
    row = first(frame)
    expect(row isa Vector && 1 <= length(row) <= 64, "invalid_frame_width")
    width = length(row)
    pixels = Matrix{UInt8}(undef, length(frame), width)
    for (y, row) in enumerate(frame)
        expect(row isa Vector && length(row) == width, "nonrectangular_frame")
        for (x, value) in enumerate(row)
            expect(strict_integer(value) && 0 <= value <= 15, "invalid_pixel")
            pixels[y, x] = value
        end
    end
    return pixels
end

function validate_response(bytes, game_id, guid, action)
    data = response_json(bytes)
    expect(data isa Dict, "invalid_response")
    expect(get(data, "game_id", nothing) == game_id, "game_mismatch")
    actual_guid = get(data, "guid", nothing)
    expect(nonempty_string(actual_guid), "missing_guid")
    expect(isnothing(guid) || actual_guid == guid, "guid_mismatch")
    state = get(data, "state", nothing)
    expect(state in PUBLIC_STATES, "invalid_game_state")
    completed, limit = get(data, "levels_completed", nothing), get(data, "win_levels", nothing)
    expect(strict_integer(completed) && 0 <= completed <= typemax(Int) &&
        positive_integer(limit), "invalid_progress")
    reply = get(data, "action_input", nothing)
    id = reply isa Dict ? get(reply, "id", nothing) : nothing
    expect(strict_integer(id) && id == action["id"], "action_mismatch")
    if id == 6
        xy = get(reply, "data", nothing)
        expect(xy isa Dict && all(
            k -> coord(get(xy, k, nothing)) && xy[k] == action[k], ("x", "y")), "coordinates_mismatch")
    end
    domain = get(data, "available_actions", nothing)
    expect(domain isa Vector && all(i -> strict_integer(i) && 1 <= i <= 7, domain) &&
        length(unique(domain)) == length(domain), "invalid_available_actions")
    raw_frames = get(data, "frame", nothing)
    expect(raw_frames isa Vector && !isempty(raw_frames), "invalid_frame_sequence")
    frames = matrix_frame.(raw_frames)
    expect(all(frame -> size(frame) == size(first(frames)), frames), "inconsistent_frame_shapes")
    full_reset = get(data, "full_reset", nothing)
    expect(!haskey(data, "full_reset") || full_reset isa Bool, "invalid_full_reset")
    return PublicObservation(game_id, actual_guid, frames, state, completed, limit, action,
        Int.(domain), full_reset)
end
