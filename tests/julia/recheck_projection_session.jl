using TddESCat
const TC = TddESCat
directory, destination = ARGS
store = TC.RunStore(directory)
events = TC.recover_run(store;read_only=true)
observations = TC.replay_effects!(Dict{String,TC.PublicEffects}(),[events])
memory = TC.ProjectionMemory()
config = TC.load_run_config(joinpath(directory,"agent.toml"))
TC.replay_projection_feedback!(memory,directory,events,observations,TC.mechanism_limits(config).history_lengths)
out = TC.RunStore(destination)
count = TC.persist_projection_scopes!(out,memory)
saved = TC.read_json(joinpath(directory,"learning","projection-scopes.json"))
replayed = TC.read_json(joinpath(destination,"learning","projection-scopes.json"))
@assert saved == replayed
println("Verified projection scopes: ",count)
