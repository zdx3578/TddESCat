include(normpath(joinpath(@__DIR__, "..", "..", "scripts", "run.jl")))

for item in JSON.parsefile(only(ARGS))
    config = load_run_config(item["config"])
    result = capture(config, item["public"]; collect_only=true)
    result.recorded > 1 && !result.quarantined || error("Training acquisition did not confirm")
end
