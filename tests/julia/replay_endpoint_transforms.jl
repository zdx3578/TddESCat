# Usage: julia --project=julia/TddESCat tests/julia/replay_endpoint_transforms.jl PUBLIC_DIR [EVENT_LIMIT]
# Retain the archived actions. Bind each new prediction before decoding its response.
using TddESCat
const TC = TddESCat

function replay_endpoints(directory,limit)
    store = TC.RunStore(abspath(directory))
    events = sort!(TC.records(store,"events");by=e->e["sequence"])
    agenda = TC.RelationAgenda()
    seen = Dict{String,Int}()
    previous = nothing
    for event in Iterators.take(events,limit)
        event["completion"] == "confirmed" || error("Unconfirmed receipt")
        command = TC.read_json(TC.store_path(store,"commands",event["command_ref"]*".json"))
        command["completion"] == "confirmed" || error("Unconfirmed command")
        TC.content_hash(codeunits(command["request_body"])) == event["request_sha256"] || error("Request mismatch")
        id,action = event["event_id"],TC.action_from_request(command)
        reset = action["id"] == 0
        if !reset
            !isnothing(previous) && previous.event["event_id"] == event["before_ref"] || error("Missing action predecessor")
        end
        proposal = if !reset
            obs = previous.observation
            TC.bind_transition_trials(agenda,nothing,obs,action,TC.public_components(last(obs.frames)))
        end
        if !isnothing(proposal)
            task = TC.relation_task_record(proposal)
            prediction = TC.relation_prediction((;before_ref=event["before_ref"]),proposal,nothing,task)
            TC.available_prediction_reads(prediction.payload["event_reads"],event["before_ref"],seen,event["sequence"])
        end
        observation = TC.checked_receipt(store,command)
        event == TC.event_record(command,observation) || error("Receipt differs from command")
        TC.check_frozen_prediction(store,command,action,seen)
        if !reset
            before = previous.observation
            outcome = TC.observe_transitions!(agenda.transitions,before,observation,id,event["before_ref"],
                proposal,nothing,nothing)
            for (trial,check) in zip(isnothing(proposal) ? () : proposal.transitions,outcome.checks)
                println(TC.JSON.json((;game=before.game_id,level=before.levels_completed,event=id,action,
                    trial.key,trial.version,trial.expected,trial.reads,trial.scope,check)))
            end
        end
        seen[id] = event["sequence"]
        previous = (;event,observation)
    end
end

replay_endpoints(ARGS[1],length(ARGS)>1 ? parse(Int,ARGS[2]) : typemax(Int))
