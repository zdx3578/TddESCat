function choose_motion_action(controller, observation, before_ref, previous_actions, attempts)
    ranked = []
    frame = last(observation.frames)
    for action in observation.available_actions
        # Coordinate actions require an independently justified concrete binding.
        action == 6 && continue
        judgment = cached_judgment(controller, action, frame, before_ref, previous_actions)
        score = judgment.predicate == proven ? 0 : judgment.predicate == unknown_truth ? 1 : 2
        push!(ranked, (; action, judgment, rank=(score, get(attempts, action, 0), action)))
    end
    sort!(ranked; by=choice->choice.rank)
    return ranked
end

function motion_prediction(controller, before_ref, action, judgment)
    scope = isnothing(judgment.expected) ? String[] : ["bound_support_displacement"]
    values = isnothing(judgment.expected) ? Dict() : Dict("bound_support_displacement"=>judgment.expected)
    binding = isnothing(judgment.bound) ? [] : [Dict("slot"=>0, "ref"=>before_ref * "-complete-support")]
    return (; before_ref, payload=Dict("model_version"=>controller.claim.version, "binding"=>binding,
        "action"=>Dict("id"=>action), "guard_truth"=>truth_wire(judgment.predicate), "query_scope"=>scope,
        "predicted_values"=>values, "enumeration_complete"=>controller.claim.guard.complete &&
            judgment.predicate != unknown_truth, "assumptions"=>[judgment.reason]))
end

function motion_step!(controller, rec, previous, history, attempts)
    ranked = choose_motion_action(controller, rec.observation, rec.before_ref, history, attempts)
    if isempty(ranked) || first(ranked).judgment.predicate == disproven
        return (status="withheld", next=nothing, result=nothing)
    end
    choice = first(ranked)
    action, judgment = choice.action, choice.judgment
    prediction = motion_prediction(controller, rec.before_ref, action, judgment)
    command = command_id(rec.next_sequence)
    decision = Dict("command_id"=>command, "before_ref"=>rec.before_ref,
        "model_version"=>controller.claim.version, "definition_ref"=>controller.claim.definition,
        "selected"=>action, "reads"=>judgment.reads,
        "candidates"=>[Dict("action"=>item.action, "guard"=>truth_wire(item.judgment.predicate),
            "reason"=>item.judgment.reason, "rank"=>item.rank) for item in ranked])
    atomic_json(store_path(rec.store, "decisions", command * ".json"), decision)
    received = submit_action!(rec, action; prediction)
    received["completion"] == "confirmed" || return (status=received["completion"], next=nothing, result=nothing)
    encoded = read_json(store_path(rec.store, "events", rec.before_ref * ".json"))
    after = (event=encoded, observation=rec.observation)
    result = observed_check(controller, action, judgment, previous, after, history)
    report = Dict("command_id"=>command, "event_ref"=>rec.before_ref, "model_version"=>decision["model_version"],
        "definition_ref"=>decision["definition_ref"], "frozen_expected"=>judgment.expected,
        "actual"=>result.actual, "status"=>result.status, "revision"=>result.revision)
    atomic_json(store_path(rec.store, "checks", command * ".json"), report)
    if !isnothing(result.revision)
        atomic_json(store_path(rec.store, "mechanisms", controller.claim.version * ".json"), claim_record(controller.claim))
    end
    attempts[action] = get(attempts, action, 0) + 1
    push!(history, action)
    return (status=result.status, next=after, result=report)
end
