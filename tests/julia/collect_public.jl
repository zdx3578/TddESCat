include(normpath(joinpath(@__DIR__, "..", "..", "scripts", "run.jl")))

function capture_interventions(config, public_dir, actions)
    with_run(public_dir) do store
        rec = Recorder(store, config)
        open_scorecard!(rec)["completion"] == "confirmed" || error("Unable to open training scorecard")
        reset!(rec,config.environment["game_id"])["completion"] == "confirmed" || error("Unable to reset training episode")
        for action in actions
            response = if action isa AbstractVector
                length(action) == 3 && first(action) == 6 || error("Malformed training click")
                submit_action!(rec,6;x=action[2],y=action[3])
            else
                submit_action!(rec,action)
            end
            response["completion"] == "confirmed" || error("Training intervention failed")
        end
        close_scorecard!(rec)["completion"] == "confirmed" || error("Unable to close training scorecard")
        length(recover_run(store)) == length(actions)+1 || error("Training intervention receipt missing")
    end
end

for item in JSON.parsefile(only(ARGS))
    config = load_run_config(item["config"])
    if haskey(item,"actions")
        capture_interventions(config,item["public"],item["actions"])
    else
        result = capture(config, item["public"]; collect_only=true)
        result.recorded > 1 && !result.quarantined || error("Training acquisition did not confirm")
    end
end
