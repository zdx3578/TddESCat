# Re-read exactly the confirmed inputs in an existing bounded-window replay.
# Arguments: archived runs root, prior window results JSON, output JSON.
include(joinpath(@__DIR__,"competitive_role_replay.jl"))
using SHA

function replay_omission_window(archive,w)
    path = joinpath(archive,"TddESCat-v13-eval-composed","runs",w["run"],w["game"])
    w["attempt"]=="original" || (path=joinpath(path,w["attempt"]))
    store = TC.RunStore(joinpath(path,"public"))
    prior = read_entry(store,w["first_event"])
    @assert prior.event["response_blob"]==w["initial_sha256"]
    agenda,meters,frontier = TC.RelationAgenda(),TC.MeterContext(),TC.PublicFrontier()
    if w["complete_attempt_prefix"]
        @assert prior.observation.action["id"]==0
        TC.begin_relation_attempt!(agenda,nothing;observation=prior.observation)
    end
    view = TC.receipt_regions(prior)
    steps = NamedTuple[]
    for record in w["steps"]
        @assert prior.event["event_id"]==record["before"]
        context = TC.relation_context(prior.observation)
        groups = last(view.frames).groups
        offer = TC.omitted_preparation_experiment(agenda,prior.observation,(;groups),context)
        node = TC.frontier_state(agenda,context,agenda.previous)
        prefix = TC.frontier_prior(agenda,agenda.previous,TC.history_scope(agenda,context).width)
        history = TC.relation_ref.(agenda.samples[prefix])
        route = TC.frontier_omission_route(frontier,agenda,prior.observation,(;groups),nothing,node,history)
        current = read_entry(store,record["event"])
        @assert current.event["response_blob"]==record["response_sha256"] &&
            current.event["before_ref"]==prior.event["event_id"] && current.observation.action==record["action"]
        after = TC.receipt_regions(current;previous=prior,previous_regions=view)
        effects = TC.observed_effects(prior,current;meters,before_regions=view,after_regions=after)
        change = TC.observe_relations!(agenda,prior,current,effects,nothing,NamedTuple[],nothing;
            groups,after_groups=last(after.frames).groups,after_regions=after)
        TC.frontier_observe!(frontier,agenda)
        flow = change.fact_flow
        @assert isnothing(flow.confirmed_task) &&
            !any(e->e.usage in (:task_read,:omission_test,:policy_preparation_read,:outcome_preparation_read),flow.inputs)
        pending = [task for table in values(agenda.uses.omissions) for task in values(table)
            if task.consumer==length(agenda.samples)]
        exact = [e for e in flow.inputs if e.usage==:omission_contrast]
        applicable = isnothing(offer) ? nothing : (;offer.action,offer.obligation.consumer,
            reads=TC.omission_evidence_refs(agenda,offer.obligation),same_as_archived=offer.action==current.observation.action)
        reachable = isnothing(route) ? nothing : (;route.action,path=route.obligation.path,
            route.obligation.future_experiment,same_as_archived=route.action==current.observation.action)
        push!(steps,(;reachable,event=record["event"],response_sha256=record["response_sha256"],applicable,
            proposed=flow.proposed_omissions,confounded=flow.confounded_omissions,
            exact,scheduled=length(pending),inputs=length(flow.inputs),eligible_before=flow.eligible_before,
            result=change.public_outcome))
        prior,view = current,after
    end
    endpoint = last(steps)
    @assert !isnothing(endpoint.result) && endpoint.event==w["endpoint_event"]
    return (;game=w["game"],level=w["level"],attempt=w["attempt"],first_event=w["first_event"],
        first_sha256=w["initial_sha256"],window_predecessor_unknown=w["window_predecessor_unknown"],
        endpoint_event=endpoint.event,steps)
end

function omission_summary(rows)
    plans = [p for r in rows for p in r.proposed]
    return (;observations=length(rows),with_prior_facts=count(r->r.eligible_before>0,rows),
        new_experiments=length(plans),observations_with_new_experiment=count(r->!isempty(r.proposed),rows),
        single_factor=count(p->p.isolated,plans),uncontrolled_or_joint=count(p->!p.isolated,plans),
        multiple_candidates=count(p->length(p.candidates)>1,plans),
        uncontrolled_pixels=count(p->p.uncontrolled_pixels>0,plans),
        other_action_domains=count(p->!isempty(p.available_added) || !isempty(p.available_removed),plans),
        existing_confounded_comparisons=sum(length(r.confounded) for r in rows),
        prestate_offer=count(r->!isnothing(r.applicable),rows),
        reachable_prior_route=count(r->!isnothing(r.reachable),rows),
        differing_hypothetical_route=count(r->!isnothing(r.reachable) && !r.reachable.same_as_archived,rows),
        differing_hypothetical_offer=count(r->!isnothing(r.applicable) && !r.applicable.same_as_archived,rows),
        exact_comparisons=sum(length(r.exact) for r in rows),
        observed_uses=sum(r.inputs for r in rows),
        outcome_witnesses=count(r->!isnothing(r.result) && !isnothing(r.result.relationship),rows))
end

function replay_omissions(args)
    archive,baseline,output = args
    old = TC.read_json(baseline)
    windows = [replay_omission_window(archive,w) for w in old["witnesses"]]
    all_steps = reduce(vcat,(w.steps for w in windows))
    endpoints = [last(w.steps) for w in windows]
    summary = (;windows=length(windows),truncated_predecessor=count(w->w.window_predecessor_unknown,windows),
        all_steps=omission_summary(all_steps),endpoints=omission_summary(endpoints))
    @assert summary.windows==13 && summary.all_steps.observations==old["summary"]["actions"]
    artifact=(;baseline_sha256=bytes2hex(sha256(read(baseline))),archive_revision=old["archive_revision"],
        source_sha256=bytes2hex(sha256(read(joinpath(dirname(pathof(TC)),"RelationUse.jl")))),
        scope="confirmed raw frames only; empty initial agenda; offers hypothetical; no dispatch, backend, contact state or simulator",
        summary,windows)
    TC.atomic_json(output,artifact)
    println(TC.JSON.json(summary))
end

if abspath(PROGRAM_FILE)==@__FILE__
    replay_omissions(ARGS)
end
