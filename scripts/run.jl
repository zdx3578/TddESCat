using TddESCat
import JSON

function capture(config, public_dir)
    config.execution["memory_enforcement"] == "cooperative" ||
        throw(ArgumentError("Capture requires delegated cgroup_v2 or an explicit cooperative config"))
    return with_run(public_dir) do store
        rec = Recorder(store, config)
        games = list_games(rec.client)
        requested = get(config.environment, "game_id", nothing)
        game_id = if isnothing(requested)
            isempty(games) && error("Public game list is empty")
            first(games)
        else
            requested in games || error("Configured game is absent from the public list")
            requested
        end
        if open_scorecard!(rec)["completion"] == "confirmed"
            if reset!(rec, game_id)["completion"] == "confirmed"
                explore!(rec)
            end
            rec.frozen || close_scorecard!(rec)
        end
        events = recover_run(store)
        return (recorded=length(events), requested_game_id=game_id, quarantined=rec.frozen)
    end
end

function explore!(rec)
    attempts = zeros(Int, 7)
    click_cursor = 0
    while rec.sent_count < rec.limit && !rec.frozen
        obs = rec.observation
        available = obs.available_actions
        if isempty(available) || obs.state in ("WIN", "GAME_OVER")
            break
        end
        id = first(sort(available; by=candidate -> (attempts[candidate], candidate)))
        xy = id == 6 ? (x=mod(click_cursor, 64), y=mod(div(click_cursor, 64), 64)) : (;)
        command = TddESCat.command_id(rec.next_sequence)
        decision = Dict("schema_version" => 1, "command_id" => command,
            "before_ref" => rec.before_ref, "reason" => "least_attempted_public_action",
            "available_actions" => available, "action" => merge((id=id,), xy))
        TddESCat.atomic_json(TddESCat.store_path(rec.store, "decisions", command * ".json"), decision)
        result = submit_action!(rec, id; xy...)
        result["completion"] == "confirmed" || break
        attempts[id] += 1
        id == 6 && (click_cursor += 1)
    end
end

function main(args)
    if length(args) == 2 && first(args) == "--replay"
        isdir(last(args)) || throw(ArgumentError("Public run directory does not exist"))
        println(JSON.json(with_run(replay_run!, last(args))))
        return 0
    end
    if !(length(args) in (2, 4) && first(args) == "--config" &&
            (length(args) == 2 || args[3] == "--public-dir"))
        throw(ArgumentError("usage: run.jl --config <file> [--public-dir <dir>] | --replay <dir>"))
    end
    cfg = load_run_config(args[2])
    public_dir = if length(args) == 4
        abspath(last(args))
    else
        mkpath(cfg.run_root)
        joinpath(mktempdir(cfg.run_root; prefix=cfg.run_name * "-", cleanup=false), "public")
    end
    result = capture(cfg, public_dir)
    println(JSON.json(result))
    return result.quarantined || result.recorded == 0 ? 1 : 0
end

exit(main(ARGS))
