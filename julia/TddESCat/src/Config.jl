struct RunConfig
    path::String
    run_name::String
    run_root::String
    environment::Dict{String,Any}
    execution::Dict{String,Any}
    learning::Union{Nothing,Dict{String,Any}}
    search::Union{Nothing,Dict{String,Any}}
    planning::Union{Nothing,Dict{String,Any}}
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

function stitch_policy(text)
    policy = require_keys(TOML.parse(text), ("schema_version", "language", "search", "max_arity",
        "sym_var_cost", "search_options", "processing", "termination", "progress"); at="stitch")
    policy["schema_version"] === 2 && policy["language"] == "typed-op-children-db-v1" &&
        policy["search"] == "best-first" && policy["sym_var_cost"] === 1 &&
        strict_integer(policy["max_arity"]) && 0 <= policy["max_arity"] ||
        throw(ArgumentError("Unsupported E-Stitch policy"))
    termination = require_keys(policy["termination"], ("learning",); at="stitch.termination")
    termination["learning"] == "verified_compression_fixed_point" ||
        throw(ArgumentError("Unsupported learning termination"))
    return policy
end

function load_run_config(path::AbstractString)
    path = abspath(path)
    data = require_keys(TOML.parsefile(path), ("schema_version", "run_name", "run_root",
        "environment", "execution"); optional=("learning", "search", "planning"))
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
        optional=("solver_memory_bytes", "learning_memory_bytes", "frozen_evaluation"), at="execution")
    check_values(exec, ("max_public_commands",), positive_integer, "execution")
    exec["one_inflight_per_guid"] === true && exec["post_retry"] === false &&
        exec["redirect"] === false || throw(ArgumentError("Invalid retry or inflight policy"))
    isolation = exec["memory_enforcement"]
    get(exec, "frozen_evaluation", false) isa Bool || throw(ArgumentError("Invalid execution.frozen_evaluation"))
    isolation in ("cooperative", "cgroup_v2") || throw(ArgumentError("Invalid memory_enforcement"))
    for field in ("solver_memory_bytes", "learning_memory_bytes")
        if haskey(exec, field)
            positive_integer(get(exec, field, nothing)) || throw(ArgumentError("Invalid execution.$field"))
        end
    end

    learning = get(data, "learning", nothing)
    if !isnothing(learning)
        require_keys(learning, ("engine", "policy_file", "batch_confirmed_events");
            optional=("prior_evidence",), at="learning")
        check_values(learning, ("batch_confirmed_events",), positive_integer, "learning")
        learning["engine"] = config_path(dir, learning["engine"])
        learning["policy_file"] = config_path(dir, learning["policy_file"])
        stitch_policy(read(learning["policy_file"], String))
        haskey(learning,"prior_evidence") && (learning["prior_evidence"] = config_path(dir, learning["prior_evidence"]))
    end
    if get(exec,"frozen_evaluation",false)
        !isnothing(learning) && haskey(learning,"prior_evidence") || throw(ArgumentError("Frozen evaluation needs prior evidence"))
    end

    search = get(data, "search", nothing)
    if !isnothing(search)
        limits = ("max_guard_atoms", "max_parameter_term_nodes", "max_guard_candidates", "max_action_coordinates")
        require_keys(search, ("context_radii", "allow_full_frame_context", "history_lengths", limits...); at="search")
        check_values(search, limits, positive_integer, "search")
        check_values(search, ("allow_full_frame_context",), x -> x isa Bool, "search")
        for (key, lower) in (("context_radii", 1), ("history_lengths", 0))
            values = search[key]
            values isa AbstractVector && !isempty(values) && all(x -> strict_integer(x) && x >= lower, values) &&
                sort(unique(values)) == values || throw(ArgumentError("Invalid search.$key"))
        end
    end
    planning = get(data,"planning",nothing)
    if !isnothing(planning)
        isnothing(learning) && throw(ArgumentError("Planning requires learned mechanisms"))
        require_keys(planning,("depth","max_work");optional=("max_states","goal"),at="planning")
        check_values(planning,("depth","max_work"),positive_integer,"planning")
        planning["depth"] <= 16 || throw(ArgumentError("Planning depth exceeds the finite profile"))
        if haskey(planning,"goal")
            goal = require_keys(planning["goal"],("role_color","marker_color");
                optional=("cue_color","marker_gap"),at="planning.goal")
            colors = [key for key in keys(goal) if key != "marker_gap"]
            check_values(goal,colors,n -> strict_integer(n) && 0 <= n <= 15,"planning.goal")
            allunique(goal[key] for key in colors) || throw(ArgumentError("Goal colors coincide"))
            gap = get(goal,"marker_gap",0)
            strict_integer(gap) && 0 <= gap <= 3 || throw(ArgumentError("Invalid planning.goal.marker_gap"))
        end
        if haskey(planning,"max_states")
            limit = planning["max_states"]
            positive_integer(limit) && limit <= 256 || throw(ArgumentError("Invalid planning.max_states"))
        end
    end
    return RunConfig(path, data["run_name"], config_path(dir, data["run_root"]), env, exec, learning, search, planning)
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
