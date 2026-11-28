# Use the frozen capture implementation with an explicit Docker supervisor.
include(joinpath(@__DIR__, "..", "run.jl"))

length(ARGS) == 2 || error("Expected the run configuration and public directory")
config = load_run_config(ARGS[1])
public_dir = ARGS[2]
config.execution["memory_enforcement"] == "cooperative" ||
    error("Native Docker capture requires cooperative execution")
supervision = TddESCat.read_json(joinpath(public_dir, "supervision.json"))
get(supervision, "execution_mode", nothing) == "native_docker" &&
    supervision["state"] == "RUNNING" || error("Native Docker supervisor is missing")
result = Base.invokelatest(capture, config, public_dir)
println(JSON.json(result))
exit(result.quarantined || result.recorded == 0 ? 1 : 0)
