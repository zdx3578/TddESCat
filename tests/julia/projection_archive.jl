using TddESCat

const TC = TddESCat
source,input,output = ARGS
store = TC.RunStore(source)
episodes = recover_run(store;read_only=true)
events = Dict(row.event["event_id"]=>row for row in episodes)
witnesses = TC.read_json(input)
memory = TC.ProjectionMemory()
observed = []
for witness in witnesses
    event = events[witness["ref"]]
    prior = events[witness["before_ref"]]
    before,after = last(prior.observation.frames),last(event.observation.frames)
    prediction = copy(after)
    for (x,y,expected,actual) in [witness["inside"];witness["outside"]]
        @assert prediction[y+1,x+1] == actual
        prediction[y+1,x+1] = UInt8(expected)
    end
    @assert TC.frame_key(prediction) == witness["frame_sha256"]
    @assert TC.frame_key(after) == witness["actual_sha256"]
    @assert witness["local_supported"]
    id = witness["mechanism"]
    feedback = TC.projection_outcome((frame=prediction,base=prediction,writes=Tuple.(witness["writes"])),
        before,after,true,witness["complete"],String[])
    @assert !feedback.matching
    check = TC.read_json(joinpath(source,"checks",witness["command"] * ".json"))
    @assert all(==("supported"),values(check["assessments"]))
    quantities = Int[effect["context"]["before_value"] for effect in check["evidence"]["effects"]
        if effect["family"] == "measurement"]
    observation = TC.ProjectionTrial(event.event["event_id"],prior.event["event_id"],before,
        [prior.observation.action["id"]],quantities,feedback.outcome,feedback.correction)
    scope = TC.observe_projection!(memory,id,observation,[1,2,4])
    @assert scope.disputed
    @assert TC.projection_applicability(memory,id,before,observation.history,quantities).status != "witnessed_base"
    push!(observed,(command=witness["command"],contract=id,version=scope.version,feedback))
end
first_case = first(witnesses)
after_first = events[first_case["ref"]]
following = only(row for row in episodes if row.event["before_ref"] == first_case["ref"])
next_check = TC.read_json(joinpath(source,"checks",following.event["command_ref"] * ".json"))
@assert next_check["program"] === nothing && all(==("supported"),values(next_check["assessments"]))
status = TC.projection_applicability(memory,first_case["mechanism"],last(after_first.observation.frames),
    [after_first.observation.action["id"]],Int[]).status
@assert status == "unproved_projection_scope"
corpus = TC.read_json(joinpath(source,"learning","sequence-corpus.json"))
cohorts = TC.program_cohort_ledger(store,(scopes=corpus["scopes"],))
@assert length(cohorts["groups"]) == 149
@assert cohorts["unsubmitted"] == 70 && cohorts["search_incomplete"] == 5
TC.atomic_json(output,(;observed,following_local_only=(command=following.event["command_ref"],status),
    cohorts))
println("Seven archived counterexamples and 149 cohort groups verified.")
