struct RunConfig
    path::String
    run_name::String
    run_root::String
    environment::Dict{String,Any}
    execution::Dict{String,Any}
    learning::Union{Nothing,Dict{String,Any}}
    search::Union{Nothing,Dict{String,Any}}
end

strict_integer(value) = value isa Integer && !(value isa Bool)
positive_integer(value) = strict_integer(value) && 0 < value <= typemax(Int)
seconds(value) = value isa Real && !(value isa Bool) && isfinite(value) && value > 0
nonempty_string(value) = value isa String && !isempty(value)
valid_id(value) = nonempty_string(value) && occursin(r"^[A-Za-z0-9][A-Za-z0-9_.-]*\z", value)

function require_keys(table, required; optional=(), at="config")
    table isa AbstractDict || throw(ArgumentError("$at must be an object"))
    for key in required
        haskey(table, key) || throw(ArgumentError("Missing $at.$key"))
    end
    for key in keys(table)
        key in required || key in optional || throw(ArgumentError("Unknown $at.$key"))
    end
    return table
end

function check_values(table, fields, valid, at)
    for key in fields
        valid(table[key]) || throw(ArgumentError("Invalid $at.$key"))
    end
end

function config_path(root, value)
    nonempty_string(value) || throw(ArgumentError("Invalid configuration path"))
    return normpath(joinpath(root, value))
end

function load_run_config(path::AbstractString)
    path = abspath(path)
    data = require_keys(TOML.parsefile(path), ("schema_version", "run_name", "run_root",
        "environment", "execution"); optional=("learning", "search"))
    strict_integer(data["schema_version"]) && data["schema_version"] == 1 ||
        throw(ArgumentError("Unsupported run config version"))
    valid_id(data["run_name"]) || throw(ArgumentError("Invalid run_name"))
    dir = dirname(path)
    env = require_keys(data["environment"], ("base_url", "competition_mode", "game_selection",
        "connect_timeout_seconds", "request_timeout_seconds");
        optional=("credentials_file", "game_id"), at="environment")
    url = env["base_url"]
    nonempty_string(url) && occursin(r"^https?://(?:\[[A-Fa-f0-9:]+\]|[A-Za-z0-9.-]+)(?::[0-9]+)?/?\z", url) ||
        throw(ArgumentError("Invalid environment.base_url"))
    env["base_url"] = rstrip(url, '/')
    check_values(env, ("competition_mode",), x -> x isa Bool, "environment")
    check_values(env, ("connect_timeout_seconds", "request_timeout_seconds"), seconds, "environment")
    selection = env["game_selection"]
    (selection == "public_list" && !haskey(env, "game_id") ||
        selection == "explicit" && valid_id(get(env, "game_id", nothing))) ||
        throw(ArgumentError("Invalid environment game selection"))
    if haskey(env, "credentials_file")
        env["credentials_file"] = config_path(dir, env["credentials_file"])
    end

    exec = require_keys(data["execution"], ("max_public_commands", "one_inflight_per_guid",
        "post_retry", "redirect", "memory_enforcement");
        optional=("solver_memory_bytes", "learning_memory_bytes"), at="execution")
    check_values(exec, ("max_public_commands",), positive_integer, "execution")
    exec["one_inflight_per_guid"] === true && exec["post_retry"] === false &&
        exec["redirect"] === false || throw(ArgumentError("Invalid retry or inflight policy"))
    isolation = exec["memory_enforcement"]
    isolation in ("cooperative", "cgroup_v2") || throw(ArgumentError("Invalid memory_enforcement"))
    for field in ("solver_memory_bytes", "learning_memory_bytes")
        if isolation == "cgroup_v2" || haskey(exec, field)
            positive_integer(get(exec, field, nothing)) || throw(ArgumentError("Invalid execution.$field"))
        end
    end

    learning = get(data, "learning", nothing)
    if !isnothing(learning)
        limits = ("batch_confirmed_events", "max_programs", "max_ast_nodes",
            "max_input_slots", "max_learning_seconds", "max_new_definitions")
        require_keys(learning, ("engine", "language", "seed", limits...); at="learning")
        learning["language"] == "typed-op-children-db-v1" || throw(ArgumentError("Unsupported language"))
        strict_integer(learning["seed"]) && learning["seed"] >= 0 || throw(ArgumentError("Invalid seed"))
        check_values(learning, limits, positive_integer, "learning")
        learning["engine"] = config_path(dir, learning["engine"])
    end

    search = get(data, "search", nothing)
    if !isnothing(search)
        limits = ("max_guard_atoms", "max_parameter_term_nodes", "max_guard_candidates", "max_match_witnesses")
        require_keys(search, ("context_radii", "allow_full_frame_context", "history_lengths", limits...); at="search")
        check_values(search, limits, positive_integer, "search")
        check_values(search, ("allow_full_frame_context",), x -> x isa Bool, "search")
        for (key, lower) in (("context_radii", 1), ("history_lengths", 0))
            values = search[key]
            values isa AbstractVector && !isempty(values) && all(x -> strict_integer(x) && x >= lower, values) &&
                sort(unique(values)) == values || throw(ArgumentError("Invalid search.$key"))
        end
    end
    return RunConfig(path, data["run_name"], config_path(dir, data["run_root"]), env, exec, learning, search)
end

function read_api_key(env)
    path = get(env, "credentials_file", nothing)
    isnothing(path) && return nothing
    isfile(path) || throw(ArgumentError("Missing credentials file"))
    (filemode(path) & 0o077) == 0 || throw(ArgumentError("Credentials file must be private"))
    secret = require_keys(TOML.parsefile(path), ("api_key",); at="credentials")["api_key"]
    nonempty_string(secret) && !occursin(r"[[:cntrl:]]", secret) ||
        throw(ArgumentError("Invalid API key"))
    return secret
end

function motion_guard_limits(config::RunConfig)
    search = config.search
    isnothing(search) && return (;)
    return (; max_guard_atoms=search["max_guard_atoms"], max_guard_work=search["max_guard_candidates"],
        context_radii=Tuple(search["context_radii"]), history_lengths=Tuple(search["history_lengths"]),
        allow_full_frame=search["allow_full_frame_context"])
end
