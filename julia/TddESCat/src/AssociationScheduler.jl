const EVIDENCE_INTERPRETATION = "bounded-event-effects-v1"

function register_evidence_obligation!(store, item; frozen=false)
    event = item.event
    event["completion"] == "confirmed" || error("Only confirmed events can enter the evidence ledger")
    record = Dict("event_ref"=>event["event_id"], "before_ref"=>event["before_ref"],
        "response_blob"=>event["response_blob"], "intervention_group"=>event["intervention_group"],
        "sequence"=>event["sequence"], "action"=>event["action"], "interpretation"=>EVIDENCE_INTERPRETATION,
        "qualification"=>event["action"]["id"] == 0 ? "reset_context" : frozen ? "evaluation_only" : "training")
    path = store_path(store, frozen ? "evaluation" : "learning", "obligations", event["event_id"] * ".json")
    if isfile(path)
        read_json(path) == record || error("Conflicting evidence obligation")
    else
        atomic_json(path, record)
    end
    return record
end

function learning_batch(pairs)
    inputs = [[pre.event["event_id"], post.event["event_id"], post.event["response_blob"]] for (pre,post) in pairs]
    allunique(getindex.(inputs,2)) || error("Repeated intervention in one learning batch")
    return Dict("evidence_snapshot_id"=>"snapshot-" * content_hash(JSON.json(inputs)), "inputs"=>inputs)
end

function learning_jobs(store)
    directory = store_path(store,"learning")
    isdir(directory) || return String[]
    return sort!(filter(path->isdir(path) && occursin(r"^job-\d{6,}$",basename(path)), readdir(directory;join=true));
        by=path->parse(Int,split(basename(path),'-')[2]))
end

function learning_assessment!(job, batch, result; complete=false, fields...)
    atomic_json(joinpath(job,"assessment.json"), merge(
        Dict("result"=>result, "evidence_snapshot_id"=>batch["evidence_snapshot_id"], "complete"=>complete),
        Dict(string(key)=>value for (key,value) in fields)))
end

function learning_dispositions(store)
    records_by_event = Dict{String,Dict}()
    for job in learning_jobs(store)
        isfile(joinpath(job,"batch.json")) || continue
        batch = read_json(joinpath(job,"batch.json"))
        observed = joinpath(job,"observations.json")
        dispositions = isfile(observed) ? read_json(observed)["dispositions"] : Dict()
        path = joinpath(job,"assessment.json")
        assessment = isfile(path) ? read_json(path) : Dict("result"=>"awaiting_worker", "complete"=>false)
        for (_,ref,_) in batch["inputs"]
            previous = get(records_by_event,ref,nothing)
            record = Dict("job"=>basename(job), "disposition"=>get(dispositions,ref,"pending_interpretation"),
                "result"=>assessment["result"], "complete"=>assessment["complete"],
                "termination_reason"=>get(assessment,"termination_reason",nothing),
                "fixed_point"=>get(assessment,"fixed_point",false),
                "needs_reinterpretation"=>get(dispositions,ref,"pending_interpretation") != "compiled")
            if !isnothing(previous) && previous["complete"]
                error("Completed intervention was scheduled again")
            end
            records_by_event[ref] = record
        end
    end
    return records_by_event
end

function summarize_learning!(store)
    dispositions = learning_dispositions(store)
    events = Dict[]
    for kind in ("learning","evaluation")
        directory = store_path(store,kind,"obligations")
        isdir(directory) || continue
        for path in readdir(directory;join=true)
            row = read_json(path)
            ref = row["event_ref"]
            if row["qualification"] == "training"
                merge!(row, get(dispositions,ref,Dict("result"=>"pending","complete"=>false)))
            end
            push!(events,row)
        end
    end
    sort!(events;by=row->(row["intervention_group"],row["sequence"],row["event_ref"]))
    pending = [row["event_ref"] for row in events if row["qualification"] == "training" && !row["complete"]]
    atomic_json(store_path(store,"learning","dispositions.json"),Dict("events"=>events,"pending"=>pending))
    return pending
end

const PublicActionKey = NTuple{3,Int}

mutable struct ExperimentSchedule
    round::Int
    cursor::Int
    queue::Vector{PublicActionKey}
    deferred::Vector{PublicActionKey}
    prefixes::Dict{Tuple,Dict{Int,Tuple{Int,String}}}
    deferred_once::Bool
end

ExperimentSchedule() = ExperimentSchedule(0,1,PublicActionKey[],PublicActionKey[],Dict(),false)
concrete_action(key::PublicActionKey) = key[1] == 6 ?
    Dict("id"=>key[1],"x"=>key[2],"y"=>key[3]) : Dict("id"=>key[1])

function experiment_prefix_key(level,available,history)
    suffix = Tuple(last(history,min(2,length(history))))
    return (level,Tuple(sort(available)),suffix)
end

function record_experiment_prefix!(schedule,level,available,history,action,event)
    id = action["id"]
    id == 6 && return nothing
    key = experiment_prefix_key(level,available,history)
    past = get!(Dict{Int,Tuple{Int,String}},schedule.prefixes,key)
    count,first_seen = get(past,id,(0,event))
    past[id] = (count+1,first_seen)
    return nothing
end

function select_experiment!(schedule, store, ranked, available, before_ref;level=nothing,history=Int[])
    isempty(available) && return nothing
    schedule.cursor <= length(schedule.queue) || begin
        schedule.round += 1
        deferred = filter(key->key[1] in available,schedule.deferred)
        filter!(key->key[1] ∉ available,schedule.deferred)
        initial = PublicActionKey[action_key(item.action) for item in ranked]
        clicks = 6 in available ? PublicActionKey[(6,x,y) for y in 0:63 for x in 0:63] : PublicActionKey[]
        other = PublicActionKey[(id,-1,-1) for id in available if id != 6]
        schedule.queue = unique!([deferred; initial; other; clicks])
        schedule.cursor = 1
        atomic_json(store_path(store,"experiments","round-" * string(schedule.round) * ".json"),
            Dict("round"=>schedule.round,"before_ref"=>before_ref,"obligations"=>schedule.queue))
    end
    skipped = PublicActionKey[]
    while schedule.cursor <= length(schedule.queue) && schedule.queue[schedule.cursor][1] ∉ available
        push!(skipped,schedule.queue[schedule.cursor])
        schedule.cursor += 1
    end
    if !isempty(skipped)
        unique!(append!(schedule.deferred,skipped))
        atomic_json(store_path(store,"experiments","blocked-" * before_ref * "-" * string(schedule.round) * ".json"),
            Dict("before_ref"=>before_ref,"round"=>schedule.round,"obligations"=>skipped,
                "reason"=>"action_unavailable"))
    end
    schedule.cursor <= length(schedule.queue) ||
        return select_experiment!(schedule,store,ranked,available,before_ref;level,history)
    key = schedule.queue[schedule.cursor]
    prefix = experiment_prefix_key(level,available,history)
    past = get(schedule.prefixes,prefix,nothing)
    if !schedule.deferred_once && first(key) != 6 && !isnothing(past)
        alternatives = [action for action in available if action != 6]
        visits(action) = first(get(past,action,(0,"")))
        preferred = argmin(action->(visits(action),action),alternatives)
        if visits(preferred) < visits(first(key))
            action = concrete_action((preferred,-1,-1))
            obligation = (;prefix=last(prefix),baseline=concrete_action(key),
                previous_experiments=visits(preferred),baseline_experiments=visits(first(key)),
                baseline_event=last(past[first(key)]))
            return (;round=schedule.round,cursor=schedule.cursor,action,obligation)
        end
    end
    return (;round=schedule.round,cursor=schedule.cursor,action=concrete_action(key))
end

function record_experiment_service!(schedule, store, item, event)
    event["action"] == item.action || error("Experiment receipt differs from the selected obligation")
    obligation = get(item,:obligation,nothing)
    atomic_json(store_path(store,"experiments","service-" * event["event_id"] * ".json"),
        Dict("event_ref"=>event["event_id"],"before_ref"=>event["before_ref"],"action"=>item.action,
            "round"=>item.round,"cursor"=>item.cursor,"prefix_obligation"=>obligation))
    if isnothing(obligation)
        schedule.cursor += 1
        schedule.deferred_once = false
    else
        schedule.deferred_once = true
    end
end
