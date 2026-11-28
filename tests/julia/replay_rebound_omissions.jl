# Arguments: archived runs root, committed thirteen-window evidence manifest, output JSON.
include(joinpath(@__DIR__,"competitive_role_replay.jl"))
using SHA

# Restore the fields consumed by the native arbiter, including public contact
# guard evidence. Candidate exploration cannot use the command's later receipt.
function replay_spatial(d)
    convert(value) = value
    convert(value::AbstractDict) = (; (Symbol(key)=>(key=="judgment" ? Symbol(v) : convert(v))
        for (key,v) in pairs(value))...)
    return convert(d)
end

function replay_rebound_choice(agenda,search,prior,decision,record,rebound,context)
    obs = prior.observation
    vote = record["task_arbitration"]
    candidates = vote["candidates"]
    # Do not silently discard a competitor with unavailable internal state.
    @assert all(r->r["source"] in ("base","program","spatial"),candidates)
    base = only(filter(r->r["source"] in ("base","program"),candidates))
    item = (;action=base["action"],reason=base["reason"])
    spatial = if any(r->r["source"]=="spatial",candidates)
        original = only(filter(r->r["source"]=="spatial",candidates))
        source = get(record,"spatial_experiment",nothing)
        isnothing(source) && (source=get(record,"spatial_baseline",nothing))
        @assert !isnothing(source) && source["id"]==original["action"]["id"] && source["reason"]==original["reason"]
        replay_spatial(source)
    end
    args = (;program=base["source"]=="program",conditional=base["priority"]==1,
        continuing_contact=false,object_probes=6 in obs.available_actions)
    earlier = TC.task_arbitration(item,spatial,nothing,nothing,nothing;args...)
    archived = vote["choice"]
    @assert earlier.choice.action==archived["action"] && string(earlier.choice.source)==archived["source"] &&
        earlier.choice.priority==archived["priority"]
    proposal = TC.relation_experiment(agenda,obs,decision,nothing,context;frontier=search)
    voted = TC.task_arbitration(item,spatial,nothing,proposal,nothing;args...,
        frontier=(;search,agenda,observation=obs,decision,context))
    winner = voted.choice.source==:relation ? something(voted.frontier_task,proposal) : nothing
    return (;before=prior.event["event_id"],rebound.action,trial=rebound.obligation.consumer,
        source=rebound.obligation.source_event,reference=rebound.obligation.source_context,
        spans=rebound.obligation.uncontrolled.pixel_spans,proposed=isnothing(proposal) ? nothing : proposal.intent,
        dispatched_intent=isnothing(winner) ? nothing : winner.intent,choice=voted.choice,
        archived,competitors=candidates)
end

function replay_rebound_window(runs,w)
    path = joinpath(runs,w["run"],w["game"])
    w["attempt"]=="original" || (path=joinpath(path,w["attempt"]))
    store = TC.RunStore(joinpath(path,"public"))
    first_event = w["first_event"]
    prior = read_entry(store,first_event)
    @assert prior.event["response_blob"]==w["first_sha256"]
    agenda,meters,search = TC.RelationAgenda(),TC.MeterContext(),TC.PublicFrontier()
    w["truncated_predecessor"] || TC.begin_relation_attempt!(agenda,nothing;observation=prior.observation)
    source = TC.receipt_regions(prior)
    emissions = NamedTuple[]
    start = parse(Int,last(split(first_event,"-c")))
    stop = parse(Int,last(split(w["endpoint"],"-c")))
    for sequence in start+1:stop
        command = "c" * lpad(string(sequence),9,'0')
        before = prior.event["event_id"]
        archived = TC.read_json(TC.store_path(store,"decisions",command*".json"))
        @assert archived["before_ref"]==before && archived["command_id"]==command
        obs,groups = prior.observation,last(source.frames).groups
        ranked = [(;action=r["action"],rank=Tuple(r["rank"]),reason=r["reason"]) for r in archived["candidates"]]
        decision = (;ranked,groups)
        context = TC.relation_context(obs)
        TC.frontier_options!(search,context,ranked,nothing)
        rebound = TC.rebound_omission_experiment(agenda,obs,decision,context)
        if !isnothing(rebound)
            push!(emissions,replay_rebound_choice(agenda,search,prior,decision,archived,rebound,context))
        end
        ref = first(rsplit(first_event,"-";limit=2))*"-"*command
        current = read_entry(store,ref)
        @assert current.event["before_ref"]==before && current.observation.action==archived["action"]
        next = TC.receipt_regions(current;previous=prior,previous_regions=source)
        effects = TC.observed_effects(prior,current;meters,before_regions=source,after_regions=next)
        TC.observe_relations!(agenda,prior,current,effects,nothing,NamedTuple[],nothing;
            groups,after_groups=last(next.frames).groups,after_regions=next)
        TC.frontier_observe!(search,agenda)
        prior,source = current,next
    end
    @assert prior.event["event_id"]==w["endpoint"] && prior.event["response_blob"]==w["endpoint_sha256"]
    return (;game=w["game"],first=first_event,observations=stop-start,emissions)
end

function replay_rebound(args)
    runs,manifest,output = args
    source = TC.read_json(manifest)["replay"]
    windows = [replay_rebound_window(runs,w) for w in source["endpoint_traces"]]
    emissions = [r for window in windows for r in window.emissions]
    observations = sum(w->w.observations,windows)
    @assert observations==source["all_steps"]["observations"]
    summary = (;observations,offers=length(emissions),changed=count(r->r.choice.action!=r.archived["action"],emissions))
    TC.atomic_json(output,(;complete=true,manifest_sha256=bytes2hex(sha256(read(manifest))),
        scope="Archived actions held fixed. Raw confirmed receipts update the agenda; pre-command candidates share native arbitration. No new dispatch.",
        summary,windows))
    println(TC.JSON.json(summary))
end

if abspath(PROGRAM_FILE)==@__FILE__
    replay_rebound(ARGS)
end
