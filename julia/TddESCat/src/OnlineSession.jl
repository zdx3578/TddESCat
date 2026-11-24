struct PublicTrial
    sample::MotionExample
    action::Dict{String,Int}
end

struct ActiveMechanism
    rule::JointMechanism
    condition::GuardSearch
    counterexamples::Vector{String}
    unknown::Vector{String}
end

mutable struct OnlineKnowledge
    rules::Vector{JointMechanism}
    active::Vector{ActiveMechanism}
    trials::Vector{PublicTrial}
    learning_jobs::Int
    definition_depths::Dict{String,Int}
end

OnlineKnowledge() = OnlineKnowledge(JointMechanism[], ActiveMechanism[], PublicTrial[], 0, Dict{String,Int}())

function prior_trials(config)
    directory = isnothing(config.learning) ? nothing : get(config.learning,"prior_evidence",nothing)
    isnothing(directory) && return (; events=Any[], pairs=Tuple[], trials=PublicTrial[])
    events = Any[]
    pairs = Tuple[]
    trials = PublicTrial[]
    ids = Set{String}()
    for name in readdir(directory;join=true)
        isdir(name) && realpath(name) == name && isdir(joinpath(name,"commands")) || continue
        sources = recover_run(RunStore(name);read_only=true)
        history = Int[]
        previous = nothing
        for item in sources
            ref = item.event["event_id"]
            ref ∈ ids && error("Repeated earlier intervention")
            push!(ids,ref)
            push!(events,item.event)
            action = item.observation.action
            if action["id"] == 0
                empty!(history)
            else
                !isnothing(previous) && !isempty(history) || error("Earlier action lacks the reset context")
                push!(pairs,(previous,item))
                push!(trials,PublicTrial(motion_example(previous,item;history),action))
            end
            push!(history,action["id"])
            previous = item
        end
    end
    isempty(trials) && error("Prior evidence contains no actionable events")
    return (; events,pairs,trials)
end

function small_components(frame)
    return filter(shape -> length(shape) <= 192, color_components(frame).groups)
end

function fit_joint_condition(rule, trials, limits)
    chosen = []
    for trial in trials
        trial.action["id"] == rule.action_id || continue
        row = trial.sample
        groups = small_components(row.before)
        evaluation = evaluate_joint_rule(rule,row.before,groups,enclosure_pairs(groups),trial.action)
        evaluation.truth == proven || continue
        assessed = measure_joint((model=rule, fragments=evaluation.fragments),row.after)
        verdict = "refuted" in values(assessed.assessments) ? disproven :
            all(==("supported"), values(assessed.assessments)) ? proven : unknown_truth
        push!(chosen, (; row, evaluation.fragments, verdict))
    end
    rows = [item.row for item in chosen]
    ids = [row.event_id for row in rows]
    support = findall(item -> item.verdict == proven, chosen)
    broken = findall(item -> item.verdict == disproven, chosen)
    unknowns = ids[findall(item -> item.verdict == unknown_truth, chosen)]
    if isempty(broken)
        condition = GuardSearch(MotionPredicate[],ids[support],String[],String[],true,!isempty(support),1)
        return ActiveMechanism(rule,condition,ids[broken],unknowns)
    end
    move_index = findfirst(effect -> effect.family == :translation, rule.effects)
    effect = isnothing(move_index) ? first(rule.effects) : rule.effects[move_index]
    bindings = [isnothing(move_index) ? nothing : MotionBinding(r.fragments[move_index].basis,
        r.fragments[move_index].value) for r in chosen]
    delta = isnothing(move_index) ? (0,0) : Tuple(effect.values)
    work = get(limits,:max_guard_work,4096)
    pool = predicate_pool(rows,effect.template,delta; max_atoms=work,
        context_radii=get(limits,:context_radii,(1,2,4)),
        allow_full_frame=get(limits,:allow_full_frame,true),
        history_lengths=get(limits,:history_lengths,(1,)))
    test = (atom,i)->evaluate_predicate(atom,rows[i].before,bindings[i],delta,rows[i].previous_actions)
    found = search_guards(ids,support,broken,pool.pool,test;
        max_atoms=get(limits,:max_guard_atoms,2),max_work=work)
    updated = GuardSearch(found.atoms,found.support,found.excluded,found.unresolved,
        found.complete && pool.complete,found.feasible,found.visited)
    return ActiveMechanism(rule,updated,ids[broken],unknowns)
end

function active_id(model::ActiveMechanism)
    return "mechanism-" * content_hash(JSON.json([model.rule.id,
        predicate_record.(model.condition.atoms),model.condition.feasible,model.condition.complete]))
end

function frozen_knowledge_digest(knowledge)
    interpretations = [(active_id(model),model.rule.references,model.condition.support,
        model.counterexamples,model.unknown) for model in knowledge.active]
    return content_hash(JSON.json([interpretations,[trial.sample.event_id for trial in knowledge.trials]]))
end

function archive_trial!(knowledge, trial, limits)
    any(t -> t.sample.event_id == trial.sample.event_id, knowledge.trials) && error("Repeated public feedback")
    push!(knowledge.trials,trial)
    updated = ActiveMechanism[]
    old = Dict(model.rule.id=>model for model in knowledge.active)
    for rule in knowledge.rules
        current = get(old,rule.id,nothing)
        if isnothing(current) || rule.action_id == trial.action["id"]
            current = fit_joint_condition(rule,knowledge.trials,limits)
        end
        push!(updated,current)
    end
    knowledge.active = updated
    return old
end

function mechanism_key(rule; composing=false)
    patch = rule.patch
    observation = composing && !isnothing(patch) ? (patch.shape,patch.moving,patch.fixed) : nothing
    meaning = [rule.action_id,
        [(item.family,item.template,item.position,item.family == :selection ? Int[] : item.values,
          item.visibility,item.enclosed) for item in rule.effects],
        any(effect->effect.family == :count,rule.effects) ? rule.anchors : Pixel[],
        rule.spacing,rule.entry_colors,isnothing(rule.parent)]
    composing && push!(meaning,observation)
    return content_hash(JSON.json(meaning))
end

function candidate_evaluation(active, before, groups, enclosure, action, history)
    rule = active.rule
    result = evaluate_joint_rule(rule,before,groups,enclosure,action)
    result.truth == proven || return result
    active.condition.feasible ||
        return (truth=unknown_truth,fragments=result.fragments,reason="unresolved_condition")
    index = findfirst(effect -> effect.family == :translation, rule.effects)
    moving = isnothing(index) ? nothing : result.fragments[index]
    binding = isnothing(moving) ? nothing : MotionBinding(moving.basis,moving.value)
    delta = isnothing(moving) ? (0,0) : moving.expected
    truth = conjunction(active.condition.atoms,before,binding,delta,history)
    return (truth, fragments=result.fragments, reason=truth == proven ? "published_joint_effects" :
        truth == disproven ? "learned_condition_false" : "learned_condition_unknown")
end

function public_action_candidates(observation, max_action_coordinates)
    frame = last(observation.frames)
    groups = small_components(frame)
    enclosure = enclosure_pairs(groups)
    actions = Dict{String,Int}[]
    click_count = 0
    for id in observation.available_actions
        if id != 6
            push!(actions,Dict("id"=>id))
            continue
        end
        hinted = [position_offsets(item.target) for item in enclosure]
        visually_bound = sort(groups; by=s->(any(item->item.target == s,enclosure),
            position_offsets(s) ∉ hinted,length(s),anchor(s)))
        coordinates = unique((first(shape)[1],first(shape)[2]) for shape in visually_bound)
        isempty(coordinates) && (coordinates = Pixel[(0,0)])
        for (x,y) in Iterators.take(coordinates,max_action_coordinates)
            push!(actions,Dict("id"=>6,"x"=>x,"y"=>y))
            click_count += 1
        end
    end
    return (; frame,groups,enclosure,actions,click_count)
end

action_key(a) = (a["id"],get(a,"x",-1),get(a,"y",-1))

function enabled_condition(knowledge, item, current, history)
    selected = filter(part -> part.family == :pigment, item.fragments)
    isempty(selected) && return nothing
    result = copy(current.frame)
    for part in selected, (x,y,_) in part.basis
        result[y+1,x+1] = UInt8(part.expected)
    end
    groups = small_components(result)
    enclosures = enclosure_pairs(groups)
    for other in knowledge.active
        isempty(other.condition.atoms) && continue
        for action in current.actions
            other.rule.action_id == action["id"] || continue
            original = candidate_evaluation(other,current.frame,current.groups,current.enclosure,action,history)
            original.reason == "learned_condition_false" || continue
            hypothetical = candidate_evaluation(other,result,groups,enclosures,action,[history;item.model.rule.action_id])
            hypothetical.truth == proven || continue
            target = plan_channels(hypothetical.fragments)
            isnothing(target) || return (; action, model=other, expected=target)
        end
    end
    return nothing
end

function resource_binding(rule, fragments)
    movers = [item for item in fragments if !isnothing(item) && item.family == :translation]
    isempty(movers) && return nothing
    [item.value for item in movers] == rule.anchors || return nothing
    return Tuple(sort!(scope_key.(movers)))
end

function ranked_public_actions(knowledge, observation, history, attempts, max_action_coordinates; composing=false)
    values = public_action_candidates(observation,max_action_coordinates)
    judged = []
    for action in values.actions
        supports = []
        reasons = String[]
        blocked_parents = Set{String}()
        blocked_resources = Set{Tuple}()
        rejected = false
        for model in knowledge.active
            model.rule.action_id == action["id"] || continue
            selected = candidate_evaluation(model,values.frame,values.groups,values.enclosure,action,history)
            push!(reasons,selected.reason)
            rejected |= selected.truth == disproven
            selected.reason == "resource_precondition" && push!(blocked_parents,model.rule.id)
            if composing && any(effect->effect.family == :count && only(effect.values) < 0,model.rule.effects) &&
                selected.reason in ("resource_precondition","incomplete_effect_binding")
                binding = resource_binding(model.rule,selected.fragments)
                isnothing(binding) || push!(blocked_resources,binding)
            end
            selected.truth == proven || continue
            expected = plan_channels(selected.fragments)
            isnothing(expected) && continue
            push!(supports,(; model, selected.fragments, expected))
        end
        filter!(choice -> isnothing(choice.model.rule.parent) || choice.model.rule.parent ∉ blocked_parents,supports)
        if !isempty(blocked_resources)
            filter!(supports) do choice
                movers = filter(item->item.family == :translation,choice.fragments)
                Tuple(sort!(scope_key.(movers))) ∉ blocked_resources
            end
            push!(reasons,"shared_resource_binding_unproved")
        end
        sort!(supports;by=choice->(-length(choice.expected),active_id(choice.model)))
        agreed = !isempty(supports) && all(other->all(get(first(supports).expected,key,value) == value
            for (key,value) in other.expected),supports)
        reason = isempty(supports) ? (isempty(reasons) ? "uncovered" : join(sort!(unique(reasons)),",")) :
            agreed ? "published_joint_effects" : "competing_predictions"
        chosen = agreed ? first(supports) : nothing
        projection = nothing
        if composing && !isnothing(chosen)
            agreed = all(other->issubset(keys(other.expected),keys(chosen.expected)),supports)
            if agreed
                evaluated = compatible_frame_projection(supports,chosen.expected,values.frame)
                if evaluated.conflict
                    agreed = false
                    reason = "competing_frame_projections"
                elseif isnothing(evaluated.choice)
                    agreed = false
                    reason = "unproved_frame_projection"
                else
                    chosen,projection = evaluated.choice,evaluated.frame
                end
            else
                reason = "uncombined_effect_scopes"
            end
            agreed || (chosen = nothing)
        end
        follow = nothing
        priority = agreed ? 1 : rejected ? 4 : 3
        trial_count = get(attempts,action_key(action),0)
        experiment = nothing
        if isnothing(chosen) && length(supports) > 1
            split = distinguish_predictions([choice.expected for choice in supports])
            if split.separated > 0
                experiment = Dict("mechanism_versions"=>[active_id(choice.model) for choice in supports],
                    "witnesses"=>split.witnesses,"complete"=>split.complete,"work"=>split.work)
                trial_count == 0 && (priority = 2)
                reason = "discriminates_competing_predictions"
            end
        end
        if !isnothing(chosen) && !composing
            follow = enabled_condition(knowledge,chosen,values,history)
            if !isnothing(follow)
                priority = 0
                reason = "establishes_observed_condition"
            elseif any(part->part.family == :selection,chosen.fragments) && 6 ∉ history
                priority = 0
                reason = "tests_changed_role_selection"
            end
        elseif isnothing(chosen) && action["id"] == 6 && last(history) == 6
            priority += 1
        end
        push!(judged,(; action, chosen, reason, rejected, follow, experiment,projection,rank=(priority,trial_count)))
    end
    sort!(judged;by=row->row.rank,alg=Base.Sort.MergeSort)
    return (; ranked=judged, values.click_count)
end

function coverage_record(decision, item, effects, assessment)
    scope = if isnothing(item.chosen)
        "unresolved"
    elseif !item.chosen.model.condition.complete
        "bounded_prediction_with_incomplete_conditions"
    else
        "predicted_queries_only"
    end
    obligations = copy(effects.alternatives)
    isempty(effects.residual) || push!(obligations,"unexplained_pixel_changes")
    isempty(effects.public_delta) || push!(obligations,"public_state_or_trace_needs_effect_model")
    isempty(assessment.assessments) && push!(obligations,"insufficient_public_support_for_prediction")
    if !isnothing(item.chosen) && !isnothing(item.chosen.model.rule.parent)
        push!(obligations,"unbound_joint_channels")
    end
    if 6 in (candidate.action["id"] for candidate in decision.ranked)
        push!(obligations,"unprobed_click_coordinates")
    end
    return Dict("qualification"=>scope,"candidate_status"=>item.reason,
        "checked_queries"=>sort!(collect(keys(assessment.assessments))),
        "obligations"=>unique!(obligations))
end

function recovery_reads(rec, model)
    own_sources = [model.rule.training_event; model.condition.support; model.counterexamples]
    count = maximum((atom isa HistorySuffix ? length(atom.actions) : atom isa RecentAction ? 1 : 0
        for atom in model.condition.atoms);init=0)
    all_events = sort!([pair for pair in rec.sequence_by_event if last(pair) > 0];by=last)
    tail = count == 0 ? String[] : first.(last(all_events,min(count,length(all_events))))
    return sort!(unique([rec.before_ref; own_sources; tail]))
end

function predict_public(rec, item; plan_reads=String[])
    choice = item.chosen
    if isnothing(choice)
        return nothing
    end
    reads = sort!(unique([recovery_reads(rec,choice.model);plan_reads]))
    binding = [
        Dict("slot"=>i-1,"ref"=>rec.before_ref * "-query-" * key)
        for (i,key) in enumerate(sort!(collect(keys(choice.expected))))
    ]
    return (before_ref=rec.before_ref,payload=Dict("model_version"=>active_id(choice.model),
        "binding"=>binding,"action"=>item.action,"guard_truth"=>true,
        "query_scope"=>sort!(collect(keys(choice.expected))),"predicted_values"=>choice.expected,
        "event_reads"=>reads,"enumeration_complete"=>choice.model.condition.complete,
        "assumptions"=>[item.reason]))
end

function wait_worker(job, public_dir)
    path = joinpath(job,"worker-status.json")
    return open(joinpath(public_dir, "supervisor.lock"), "r") do lock
        while !isfile(path)
            ccall(:flock, Cint, (Cint, Cint), fd(lock), 6) == 0 &&
                error("Learning supervisor exited before reporting a worker result")
            systemerror("Unable to check supervisor liveness", Base.Libc.errno() != Base.Libc.EAGAIN)
            sleep(0.05)
        end
        read_json(path)
    end
end

function online_learn!(knowledge, config, store, pairs, repo_root)
    learning = config.learning
    publication_dir = store_path(store,"publication")
    current = read_published_stitch(publication_dir)
    base = isnothing(current) ? LibrarySnapshot() : current.snapshot
    corpus = relation_corpus(pairs; previous_signature=isnothing(current) ? nothing : current.bundle["signature"])
    refs = [[pre.event["event_id"],post.event["event_id"],post.event["response_blob"]] for (pre,post) in pairs]
    evidence = "snapshot-" * content_hash(JSON.json(refs))
    knowledge.learning_jobs += 1
    job = store_path(store,"learning","job-" * lpad(knowledge.learning_jobs,6,'0'))
    mkpath(job)
    atomic_json(joinpath(job,"observations.json"),Dict("scope_complete"=>corpus.complete,
        "events"=>public_effect_record.(corpus.observed),"bindings"=>corpus.bindings,
        "dispositions"=>corpus.dispositions, "scope"=>motion_guard_limits(config)))
    if isempty(corpus.programs)
        atomic_json(joinpath(job,"assessment.json"),Dict("result"=>"no_eligible_terms",
            "evidence_snapshot_id"=>evidence))
        return nothing
    end
    config_text = read(learning["policy_file"], String)
    supervision = read_json(store_path(store,"supervision.json"))
    content_hash(config_text) == supervision["policy_sha256"] || error("Session policy changed since launch")
    manifest = freeze_stitch_job(joinpath(job,"input"),basename(job),evidence,base,corpus.signature,
        corpus.programs,corpus.origins,corpus.slots;repo_root,config_text,
        engine_identity=supervision["engine_identity"],input_scope_complete=corpus.complete)
    status = wait_worker(job,store_path(store))
    status["policy_sha256"] == manifest["config_file"]["sha256"] || error("Worker ran a different policy")
    if status["code"] ∉ (0,10) || !isdir(joinpath(job,"output"))
        atomic_json(joinpath(job,"assessment.json"), Dict("result"=>"worker_incomplete","status"=>status))
        return nothing
    end
    checked = read_stitch_rounds(joinpath(job,"input"),joinpath(job,"output"))
    if isempty(checked.verified) || isempty(last(checked.verified)["calls"])
        atomic_json(joinpath(job,"assessment.json"),Dict("result"=>"no_proved_definition_call","status"=>status))
        return nothing
    end
    digest = publish_stitch!(publication_dir,checked;current_evidence=evidence)
    published = read_published_stitch(publication_dir;publication=digest)
    knowledge.definition_depths = definition_depths(published.snapshot.entries)
    term_limit = isnothing(config.search) ? 7 : config.search["max_parameter_term_nodes"]
    incoming = read_joint_mechanisms(published,corpus,pairs; term_limit)
    composing = !isnothing(config.planning) && haskey(config.planning,"goal")
    known = Dict(mechanism_key(rule;composing)=>rule for rule in knowledge.rules)
    for rule in incoming
        get!(known,mechanism_key(rule;composing),rule)
    end
    knowledge.rules = sort!(collect(values(known));by=rule->rule.id)
    limits = motion_guard_limits(config)
    knowledge.active = [fit_joint_condition(rule,knowledge.trials,limits) for rule in knowledge.rules]
    atomic_json(joinpath(job,"assessment.json"),Dict("result"=>"published","publication"=>digest,
        "definitions"=>published.bundle["new_definition_ids"],"current_mechanisms"=>active_id.(knowledge.active),
        "evidence_snapshot_id"=>evidence,"status"=>status))
    return digest
end

function run_online!(rec, entry, config, repo_root; knowledge=OnlineKnowledge(), frozen=false)
    attempts = Dict{Tuple{Int,Int,Int},Int}()
    history = [0]
    pairs = []
    publications = String[]
    count = 0
    continuation = nothing
    goal_pending = nothing
    composing = !isnothing(config.planning) && haskey(config.planning,"goal")
    goal = composing ? bind_observed_goal(last(rec.observation.frames),config.planning["goal"]) : nothing
    limits = motion_guard_limits(config)
    coordinates = isnothing(config.search) ? 4096 : config.search["max_action_coordinates"]
    consumed_depth = 0
    frozen_version = frozen ? frozen_knowledge_digest(knowledge) : nothing
    ready_at = time_ns()
    while rec.sent_count < rec.limit && !rec.frozen
        decision_started = time_ns()
        obs = rec.observation
        obs.state in ("WIN","GAME_OVER") && break
        if composing && isnothing(goal)
            goal = bind_observed_goal(last(obs.frames),config.planning["goal"])
        end
        !isnothing(goal) && goal_truth(goal,last(obs.frames)) == proven && break
        decision = ranked_public_actions(knowledge,obs,history,attempts,coordinates;composing)
        isempty(decision.ranked) && break
        item = first(decision.ranked)
        policy_note = nothing
        goal_cursor = nothing
        if composing
            selection = choose_observed_goal_step(rec,knowledge,goal,config.planning,history,decision,
                goal_pending,limits,coordinates)
            item = isnothing(selection.item) ? item : selection.item
            if isnothing(goal)
                request = argmin(candidate->(get(attempts,action_key(candidate.action),0),
                    action_key(candidate.action)),decision.ranked)
                item = merge(request,(reason="observe_goal_binding",))
            end
            goal_cursor = selection.cursor
            policy_note = selection.note
            goal_pending = nothing
        elseif !isnothing(continuation)
            restored = recheck_condition_plan(knowledge,continuation,decision.ranked)
            policy_note = Dict("operation"=>"revalidate_suffix","status"=>restored.status,
                "parent_command"=>continuation.command,"action"=>continuation.target.action)
            if !isnothing(restored.item)
                item = merge(restored.item,(reason="revalidated_policy_step",))
            end
            continuation = nothing
        end
        plan_reads = isnothing(goal_cursor) ? String[] : reduce(vcat,
            (recovery_reads(rec,model) for model in knowledge.active if haskey(goal_cursor.node.dependencies,model.rule.id));
            init=String[])
        prediction = predict_public(rec,item;plan_reads)
        id = command_id(rec.next_sequence)
        plan = composing || isnothing(config.planning) || isnothing(item.follow) ? nothing :
            propose_condition_plan(item,config.planning,id)
        if !isnothing(plan)
            policy_note = Dict("operation"=>"freeze_projected_policy","status"=>"ready",
                "goal"=>"observed_condition_then_bound_effect","first"=>item.action,
                "next"=>plan.target.action,"dependencies"=>plan.policy.dependencies)
        end
        decision_record = Dict("command_id"=>id,"before_ref"=>rec.before_ref,"action"=>item.action,
            "reason"=>item.reason,"tried_after_previous"=>get(attempts,action_key(item.action),0),
            "decision_seconds"=>(time_ns() - decision_started)/1e9,
            "confirmed_to_decision_seconds"=>(time_ns() - ready_at)/1e9,
            "candidates"=>[Dict("action"=>x.action,"reason"=>x.reason,"rank"=>x.rank) for x in decision.ranked],
            "coordinate_domain"=>Dict("visible_candidates"=>decision.click_count,
                "protocol_points"=>6 in obs.available_actions ? 4096 : 0,
                "attempted"=>sum(key[1] == 6 for key in keys(attempts);init=0)))
        isnothing(policy_note) || (decision_record["policy"] = policy_note)
        isnothing(item.experiment) || (decision_record["experiment"] = item.experiment)
        if !isnothing(item.chosen)
            model = item.chosen.model
            decision_record["mechanism_version"] = active_id(model)
            decision_record["definition_refs"] = model.rule.references
        end
        atomic_json(store_path(rec.store,"decisions",id * ".json"),decision_record)
        args = item.action["id"] == 6 ? (x=item.action["x"],y=item.action["y"]) : (;)
        start = time_ns()
        command = submit_action!(rec,item.action["id"];args...,prediction)
        elapsed = (time_ns() - start)/1e9
        command["completion"] == "confirmed" || break
        referenced_definitions = get(decision_record,"definition_refs",String[])
        decision_depth = maximum((knowledge.definition_depths[id] for id in referenced_definitions); init=0)
        consumed_depth = max(consumed_depth,decision_depth)
        ready_at = time_ns()
        event = read_json(store_path(rec.store,"events",rec.before_ref * ".json"))
        resulting = (; event,observation=rec.observation)
        sample = motion_example(entry,resulting;history)
        effects = observed_effects(entry,resulting)
        assessment = isnothing(item.chosen) ? (actual=Dict(),assessments=Dict()) :
            measure_joint((model=item.chosen.model.rule,fragments=item.chosen.fragments),sample.after)
        if !isnothing(plan)
            if !isempty(assessment.assessments) && all(==("supported"),values(assessment.assessments))
                continuation = plan
            else
                policy_note["feedback"] = "withdrawn_after_feedback"
            end
        end
        if !isnothing(goal_cursor)
            feedback = confirm_goal_step(goal_cursor,resulting.observation,assessment)
            policy_note["feedback"] = feedback.status
            if !isnothing(feedback.invalidation)
                feedback.invalidation["event_ref"] = sample.event_id
                policy_note["invalidation"] = feedback.invalidation
            end
            goal_pending = feedback.next
        end
        old = frozen ? Dict() : archive_trial!(knowledge,PublicTrial(sample,item.action),limits)
        revisions = []
        for model in knowledge.active
            prior = get(old,model.rule.id,nothing)
            isnothing(prior) && continue
            active_id(prior) != active_id(model) || continue
            push!(revisions,Dict("withdrawn"=>active_id(prior),"replacement"=>active_id(model),
                "restored"=>!prior.condition.feasible && model.condition.feasible,
                "event_ref"=>sample.event_id,"counterexamples"=>model.counterexamples,
                "outstanding"=>[model.condition.unresolved; model.condition.excluded; model.unknown]))
        end
        atomic_json(store_path(rec.store,"checks",id * ".json"),
            Dict("event_ref"=>sample.event_id,"action"=>item.action,"round_trip_seconds"=>elapsed,
                "definition_refs"=>referenced_definitions,"consumed_definition_depth"=>decision_depth,
                "read_events"=>isnothing(prediction) ? [sample.before_id] : prediction.payload["event_reads"],
                "expected"=>isnothing(item.chosen) ? Dict() : item.chosen.expected,
                "actual"=>assessment.actual,"assessments"=>assessment.assessments,"revisions"=>revisions,
                "evidence"=>public_effect_record(effects),"coverage"=>coverage_record(decision,item,effects,assessment),
                "policy"=>policy_note))
        attempts[action_key(item.action)] = get(attempts,action_key(item.action),0) + 1
        push!(history,item.action["id"])
        push!(pairs,(entry,resulting))
        entry = resulting
        count += 1
        if !frozen && length(pairs) == config.learning["batch_confirmed_events"]
            digest = online_learn!(knowledge,config,rec.store,pairs,repo_root)
            isnothing(digest) || push!(publications,digest)
            empty!(pairs)
        end
    end
    after_version = frozen ? frozen_knowledge_digest(knowledge) : nothing
    after_version == frozen_version || error("Frozen evaluation changed the mechanism")
    outcome = (; actions=count, publications, state=rec.observation.state, models=length(knowledge.active),
        frozen_before=frozen_version, frozen_after=after_version, consumed_definition_depth=consumed_depth)
    composing || return outcome
    truth = isnothing(goal) ? unknown_truth : goal_truth(goal,last(rec.observation.frames))
    return merge(outcome,(goal=truth == proven ? "observed" : truth == disproven ? "not_reached" : "unknown",))
end
