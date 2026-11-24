include(normpath(joinpath(@__DIR__, "..", "..", "scripts", "run.jl")))

operation, roster = ARGS
operation in ("capture", "replay") || throw(ArgumentError("Invalid Public25 operation"))
results = Dict{String,Any}()
for episode in JSON.parsefile(roster)
    public = episode["public"]
    result = try
        if operation == "capture"
            config = load_run_config(joinpath(public, "agent.toml"))
            capture(config, public; collect_only=true)
        else
            first_pass = with_run(replay_run!, public)
            second_pass = with_run(replay_run!, public)
            (; first_pass, second_pass)
        end
    catch error
        error isa InterruptException && rethrow()
        (; error=sprint(showerror, error, catch_backtrace()))
    end
    results[episode["game_id"]] = result
end
println(JSON.json(results))
