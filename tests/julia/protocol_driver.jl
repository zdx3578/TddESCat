using TddESCat
import JSON

function crash_hook(op)
    stage = get(op, "crash_at", nothing)
    return (reached, _) -> if string(reached) == stage
        ccall(:_exit, Cvoid, (Cint,), 79)
    end
end

if length(ARGS) == 2 && first(ARGS) == "--replay"
    println(JSON.json(with_run(replay_run!, last(ARGS))))
else
    for run in JSON.parsefile(only(ARGS))
        cfg = load_run_config(run["config"])
        with_run(run["public"]) do store
            rec = Recorder(store, cfg)
            for op in run["ops"]
                name = op["op"]
                hook = crash_hook(op)
                if name == "open"
                    open_scorecard!(rec; hook)
                elseif name == "reset"
                    reset!(rec, op["game_id"]; hook)
                elseif name == "action"
                    x, y = get(op, "x", nothing), get(op, "y", nothing)
                    if haskey(op, "origin_x")
                        x, y = screen_click(x, y; origin_x=op["origin_x"], origin_y=op["origin_y"])
                    end
                    submit_action!(rec, op["id"]; x, y, hook)
                elseif name == "close"
                    close_scorecard!(rec)
                else
                    error("Invalid test operation")
                end
            end
            recover_run(store)
        end
    end
end
