struct JointTrialAssessment
    verdict::Truth
    binding::Union{Nothing,MotionBinding}
    meter_scope::Union{Nothing,Tuple}
end

struct PublicTrial
    sample::MotionExample
    action::Dict{String,Int}
    effects::Union{Nothing,PublicEffects}
    assessments::IdDict{JointMechanism,Union{Nothing,JointTrialAssessment}}
end

PublicTrial(sample,action,effects) = PublicTrial(sample,action,effects,IdDict())
PublicTrial(sample,action) = PublicTrial(sample,action,nothing)

struct ActiveMechanism
    rule::JointMechanism
    condition::GuardSearch
    counterexamples::Vector{String}
    unknown::Vector{String}
    meter_scopes::Set{Tuple}
end

ActiveMechanism(rule,condition,refuted,unknown) = ActiveMechanism(rule,condition,refuted,unknown,Set{Tuple}())

mutable struct OnlineKnowledge
    rules::Vector{JointMechanism}
    active::Vector{ActiveMechanism}
    trials::Vector{PublicTrial}
    learning_jobs::Int
    definition_depths::Dict{String,Int}
    programs::Vector{Any}
    program_producers::Dict{String,Vector{Any}}
    policies::Vector{Any}
    observations::Dict{String,PublicEffects}
    projections::ProjectionMemory
    receipt::Union{Nothing,ReceiptRegions}
end

OnlineKnowledge() = OnlineKnowledge(JointMechanism[],ActiveMechanism[],PublicTrial[],0,Dict{String,Int}(),
    Any[],Dict(),Any[],Dict{String,PublicEffects}(),ProjectionMemory(),nothing)

function publish_receipt_regions!(knowledge,store,entry,view=receipt_regions(entry))
    event = entry.event
    view.event == event["event_id"] || error("Grounding belongs to a different public receipt")
    frames = [(frame=index-1,shape=size(regions.owner),regions=length(regions.groups),
        shared_boundaries=length(regions.boundaries),changed_pixels=view.differences[index],
        topology=view.topology[index])
        for (index,regions) in enumerate(view.frames)]
    atomic_json(store_path(store,"grounding",view.event * ".json"),
        (;schema_version=1,event=view.event,before=event["before_ref"],frames,
            response_blob=event["response_blob"]))
    knowledge.receipt = view
    return view
end

function prior_trials(config)
    directory = isnothing(config.learning) ? nothing : get(config.learning,"prior_evidence",nothing)
    observations = Dict{String,PublicEffects}()
    isnothing(directory) && return (;events=Any[],pairs=Tuple[],trials=PublicTrial[],observations)
    events = Any[]
    pairs = Tuple[]
    trials = PublicTrial[]
    ids = Set{String}()
    for name in readdir(directory;join=true)
        isdir(name) && realpath(name) == name && isdir(joinpath(name,"commands")) || continue
        sources = recover_run(RunStore(name);read_only=true)
        replay_effects!(observations,[sources])
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
                push!(trials,PublicTrial(motion_example(previous,item;history),action,observations[ref]))
            end
            push!(history,action["id"])
            previous = item
        end
    end
    isempty(trials) && error("Prior evidence contains no actionable events")
    return (;events,pairs,trials,observations)
end

public_components(frame) = sort!(color_components(frame).groups; by=shape->(length(shape),anchor(shape)))

function evaluate_joint_trial(rule, trial)
    trial.action["id"] == rule.action_id || return nothing
    # The confirmed frames and the rule's effect contract stay fixed while
    # additional trials can change the learned conditions.
    return get!(trial.assessments,rule) do
        row = trial.sample
        groups = public_components(row.before)
        meters = isnothing(trial.effects) ? MeterBinding[] : trial_meters(trial.effects)
        evaluation = evaluate_joint_rule(rule,row.before,groups,enclosure_pairs(groups),trial.action;meters)
        evaluation.truth == proven || return nothing
        assessed = measure_joint((model=rule,fragments=evaluation.fragments),row.after)
        verdict = "refuted" in values(assessed.assessments) ? disproven :
            all(==("supported"),values(assessed.assessments)) ? proven : unknown_truth
        move = findfirst(effect->effect.family == :translation,rule.effects)
        binding = if !isnothing(move)
            part = evaluation.fragments[move]
            MotionBinding(part.basis,part.value)
        end
        return JointTrialAssessment(verdict,binding,measured_scope(evaluation.fragments))
    end
end

function trial_meters(effects)
    result = Dict(meter_identity(binding)=>binding for binding in effects.live_meters)
    for effect in effects.effects
        effect.family == :measurement && (result[effect.context.instance] = effect.context.binding)
    end
    return collect(values(result))
end

function measured_scope(fragments)
    ids = Tuple(meter_pattern(part.binding) for part in fragments if part.family == :measurement)
    isempty(ids) && return nothing
    return (ids,Tuple(part.value for part in fragments if part.family == :translation))
end

function fit_joint_condition(rule, trials, limits)
    chosen = JointTrialAssessment[]
    rows = MotionExample[]
    for trial in trials
        evaluated = evaluate_joint_trial(rule,trial)
        isnothing(evaluated) && continue
        push!(chosen,evaluated)
        push!(rows,trial.sample)
    end
    ids = [row.event_id for row in rows]
    support = findall(item -> item.verdict == proven, chosen)
    broken = findall(item -> item.verdict == disproven, chosen)
    unknowns = ids[findall(item -> item.verdict == unknown_truth, chosen)]
    scopes = Set{Tuple}()
    for i in support
        scope = chosen[i].meter_scope
        isnothing(scope) || push!(scopes,scope)
    end
    if isempty(broken)
        condition = GuardSearch(MotionPredicate[],ids[support],String[],String[],true,!isempty(support),1)
        return ActiveMechanism(rule,condition,ids[broken],unknowns,scopes)
    end
    move_index = findfirst(effect -> effect.family == :translation, rule.effects)
    effect = isnothing(move_index) ? first(rule.effects) : rule.effects[move_index]
    bindings = [item.binding for item in chosen]
    delta = isnothing(move_index) ? (0,0) : Tuple(effect.values)
    if get(limits,:association,false) && !isnothing(move_index)
        examples = [AssociationExample(row,item.binding,item.verdict)
            for (row,item) in zip(rows,chosen) if item.verdict != unknown_truth]
        query = construct_relation(examples)
        if !isnothing(query)
            condition = GuardSearch(MotionPredicate[query],ids[support],ids[broken],String[],true,true,
                length(query.programs))
            return ActiveMechanism(rule,condition,ids[broken],unknowns,scopes)
        end
    end
    pool = predicate_pool(rows,effect.template,delta;
        context_radii=get(limits,:context_radii,(1,2,4)),
        allow_full_frame=get(limits,:allow_full_frame,true),
        history_lengths=get(limits,:history_lengths,(1,)))
    components = [color_components(row.before) for row in rows]
    test = (atom,i)->evaluate_predicate(atom,rows[i].before,bindings[i],delta,rows[i].previous_actions,
        components[i],rows[i].previous_transients)
    found = search_guards(ids,support,broken,pool.pool,test)
    updated = GuardSearch(found.atoms,found.support,found.excluded,found.unresolved,
        found.complete && pool.complete,found.feasible,found.visited)
    return ActiveMechanism(rule,updated,ids[broken],unknowns,scopes)
end

function update_joint_condition(current, rule, trial, trials, limits)
    if !isnothing(current) && isempty(current.counterexamples) && isempty(current.condition.atoms) &&
            current.condition.complete
        evaluated = evaluate_joint_trial(rule,trial)
        isnothing(evaluated) && return current
        ref = trial.sample.event_id
        if evaluated.verdict == unknown_truth
            return ActiveMechanism(rule,current.condition,String[],[current.unknown;ref],current.meter_scopes)
        elseif evaluated.verdict == proven
            support = [current.condition.support;ref]
            condition = GuardSearch(MotionPredicate[],support,String[],String[],true,true,1)
            scope = evaluated.meter_scope
            scopes = isnothing(scope) ? current.meter_scopes : union(current.meter_scopes,[scope])
            return ActiveMechanism(rule,condition,String[],current.unknown,scopes)
        end
    end
    return fit_joint_condition(rule,trials,limits)
end

function active_id(model::ActiveMechanism)
    fields = Any[model.rule.id,predicate_record.(model.condition.atoms),model.condition.feasible,model.condition.complete]
    isempty(model.meter_scopes) || push!(fields,sort!(collect(model.meter_scopes);by=repr))
    return "mechanism-" * content_hash(JSON.json(fields))
end

function frozen_knowledge_digest(knowledge)
    interpretations = [(active_id(model),model.rule.references,model.condition.support,
        model.counterexamples,model.unknown) for model in knowledge.active]
    programs = [(p.publication,p.definition,p.depth,p.sources,p.steps,p.shared,p.available_after)
        for p in knowledge.programs]
    policies = [(p.publication,p.definition,p.depth,p.model,p.body,p.training,p.available_after)
        for p in knowledge.policies]
    depths = [(id,knowledge.definition_depths[id]) for id in sort!(collect(keys(knowledge.definition_depths)))]
    projections = sort!([(id,scope.version,[row.event for row in scope.trials])
        for (id,scope) in knowledge.projections.scopes];by=first)
    return content_hash(JSON.json([interpretations,[trial.sample.event_id for trial in knowledge.trials],
        programs,policies,depths,projections]))
end

function archive_trial!(knowledge, trial, limits)
    any(t -> t.sample.event_id == trial.sample.event_id, knowledge.trials) && error("Repeated public feedback")
    push!(knowledge.trials,trial)
    updated = ActiveMechanism[]
    old = Dict(model.rule.id=>model for model in knowledge.active)
    for rule in knowledge.rules
        current = get(old,rule.id,nothing)
        if isnothing(current) || rule.action_id == trial.action["id"]
            current = update_joint_condition(current,rule,trial,knowledge.trials,limits)
        end
        push!(updated,current)
    end
    knowledge.active = updated
    return old
end

function mechanism_key(rule; composing=false)
    patch = rule.patch
    observation = composing && !isnothing(patch) ? (patch.shape,patch.moving,patch.fixed) : nothing
    portable_pigment = !isnothing(rule.click) && rule.click.local_pigment
    meaning = [rule.action_id,
        [(item.family,item.template,portable_pigment ? nothing : item.position,item.family == :selection ? Int[] : item.values,
          item.visibility,item.enclosed,isnothing(item.measurement) ? nothing :
            (meter_layout(item.measurement),meter_window(item.measurement.face.box),item.measurement.face.fill))
            for item in rule.effects],
        any(effect->effect.family == :count,rule.effects) ? rule.anchors : Pixel[],
        rule.spacing,rule.entry_colors,isnothing(rule.parent)]
    if !isnothing(rule.click)
        click = rule.click
        push!(meaning,(geometry(click.support),relative_click(click.point,click.support),
            click.local_pigment ? nothing : anchor(click.support)))
    end
    composing && push!(meaning,observation)
    return content_hash(JSON.json(meaning))
end

function candidate_evaluation(active, before, groups, enclosure, action, history; transients=nothing,meters=(),
                              observed_click=nothing,trained_click=nothing,role_index=nothing,relative_transfer=false)
    rule = active.rule
    result = evaluate_joint_rule(rule,before,groups,enclosure,action;
        meters,observed_click,trained_click,role_index,relative_transfer)
    result.truth == proven || return result
    scope = measured_scope(result.fragments)
    if !isnothing(scope) && scope ∉ active.meter_scopes
        return (truth=unknown_truth,fragments=result.fragments,reason="measurement_interaction_unproved")
    end
    active.condition.feasible ||
        return (truth=unknown_truth,fragments=result.fragments,reason="unresolved_condition")
    index = findfirst(effect -> effect.family == :translation, rule.effects)
    moving = isnothing(index) ? nothing : result.fragments[index]
    binding = isnothing(moving) ? nothing : MotionBinding(moving.basis,moving.value)
    delta = isnothing(moving) ? (0,0) : moving.expected
    truth = conjunction(active.condition.atoms,before,binding,delta,history;transients)
    return (truth, fragments=result.fragments, reason=truth == proven ? "published_joint_effects" :
        truth == disproven ? "learned_condition_false" : "learned_condition_unknown")
end

function public_action_candidates(observation, max_action_coordinates;object_probes=false,regions=nothing)
    frame = last(observation.frames)
    groups = isnothing(regions) ? public_components(frame) :
        sort(last(regions.frames).groups; by=shape->(length(shape),anchor(shape)))
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
        coordinates = unique(object_probes ? component_probe(shape) : (first(shape)[1],first(shape)[2])
            for shape in visually_bound)
        isempty(coordinates) && (coordinates = Pixel[(0,0)])
        for (x,y) in Iterators.take(coordinates,max_action_coordinates)
            push!(actions,Dict("id"=>6,"x"=>x,"y"=>y))
            click_count += 1
        end
    end
    return (; frame,groups,enclosure,actions,click_count)
end

action_key(a) = (a["id"],get(a,"x",-1),get(a,"y",-1))

function enabled_condition(knowledge, item, current, history; meters=())
    selected = filter(part -> part.family == :pigment, item.fragments)
    isempty(selected) && return nothing
    result = copy(current.frame)
    for part in selected, (x,y,_) in part.basis
        result[y+1,x+1] = UInt8(part.expected)
    end
    groups = public_components(result)
    enclosures = enclosure_pairs(groups)
    for other in knowledge.active
        isempty(other.condition.atoms) && continue
        for action in current.actions
            other.rule.action_id == action["id"] || continue
            original = candidate_evaluation(other,current.frame,current.groups,current.enclosure,action,history;meters)
            original.reason == "learned_condition_false" || continue
            hypothetical = candidate_evaluation(other,result,groups,enclosures,action,[history;item.model.rule.action_id];meters)
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

function ranked_public_actions(knowledge, observation, history, attempts, max_action_coordinates;
        composing=false, required_action=nothing, programs_pending=false, program_cursor=nothing,meters=(),
        object_probes=false, regions=nothing)
    values = public_action_candidates(observation,max_action_coordinates;object_probes,regions)
    transients = receipt_transient_colors(observation.frames)
    if programs_pending
        for action in program_click_actions(knowledge,program_cursor,values.groups,observation.available_actions)
            action in values.actions || push!(values.actions,action)
        end
    end
    if !isnothing(required_action) && required_action ∉ values.actions
        required_action["id"] in observation.available_actions || error("Unavailable experiment action")
        push!(values.actions,required_action)
    end
    judged = []
    models_by_action = Dict{Int,Vector{ActiveMechanism}}()
    for model in knowledge.active
        push!(get!(Vector{ActiveMechanism},models_by_action,model.rule.action_id),model)
    end
    versions = Dict{String,String}()
    version(model) = get!(() -> active_id(model),versions,model.rule.id)
    click_roles = Dict{String,NamedTuple}()
    click_bindings = IdDict{Vector{ColorCell},NamedTuple}()
    role_index = EffectRoleIndex()
    frame_regions = isnothing(regions) ? nothing : last(regions.frames)
    no_models = ActiveMechanism[]
    for action in values.actions
        supports = []
        reasons = String[]
        blocked_parents = Set{String}()
        blocked_resources = Set{Tuple}()
        rejected = false
        relation_reads = []
        models = get(models_by_action,action["id"],no_models)
        observed_click = action["id"] == 6 && any(model->!isnothing(model.rule.click),models) ?
            role_at_click(values.groups,(action["x"],action["y"]),frame_regions,click_bindings) : nothing
        for model in models
            scope = model.rule.click
            trained_click = isnothing(scope) ? nothing : get!(
                () -> click_role_signature(click_support_signature(scope.support),scope.point),click_roles,model.rule.id)
            selected = candidate_evaluation(model,values.frame,values.groups,values.enclosure,action,history;
                transients,meters,observed_click,trained_click,role_index)
            for atom in model.condition.atoms
                atom isa RelationPredicate || continue
                selected.reason in ("published_joint_effects","learned_condition_false","learned_condition_unknown") || continue
                push!(relation_reads,merge(predicate_record(atom),Dict("truth"=>string(selected.truth),
                    "model"=>version(model))))
            end
            push!(reasons,selected.reason)
            rejected |= selected.truth == disproven
            selected.reason == "resource_precondition" && push!(blocked_parents,model.rule.id)
            if composing && any(effect->effect.family in (:count,:measurement) && only(effect.values) < 0,model.rule.effects) &&
                selected.reason in ("resource_precondition","incomplete_effect_binding","measurement_interaction_unproved")
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
        sort!(supports;by=choice->(-length(choice.expected),version(choice.model)))
        agreed = !isempty(supports) && all(other->all(get(first(supports).expected,key,value) == value
            for (key,value) in other.expected),supports)
        reason = isempty(supports) ? (isempty(reasons) ? "uncovered" : join(sort!(unique(reasons)),",")) :
            agreed ? "published_joint_effects" : "competing_predictions"
        chosen = agreed ? first(supports) : nothing
        projection = nothing
        projection_contract = nothing
        projection_probe = nothing
        if composing && !isnothing(chosen)
            agreed = all(other->issubset(keys(other.expected),keys(chosen.expected)),supports)
            if agreed
                evaluated = compatible_frame_projection(supports,chosen.expected,values.frame;
                    memory=knowledge.projections,history)
                projection_probe = evaluated.probe
                if evaluated.conflict
                    agreed = false
                    reason = "competing_frame_projections"
                elseif isnothing(evaluated.choice)
                    agreed = false
                    reason = isnothing(projection_probe) ? "unproved_frame_projection" : last(projection_probe).status
                else
                    chosen,projection = evaluated.choice,evaluated.frame
                    projection_contract = evaluated.contract
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
                experiment = Dict("mechanism_versions"=>[version(choice.model) for choice in supports],
                    "witnesses"=>split.witnesses,"complete"=>split.complete,"work"=>split.work)
                trial_count == 0 && (priority = 2)
                reason = "discriminates_competing_predictions"
            end
        end
        if !isnothing(chosen) && !composing
            follow = enabled_condition(knowledge,chosen,values,history;meters)
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
        push!(judged,(; action, chosen, reason, rejected, follow, experiment,projection,projection_contract,
            projection_probe,relation_reads,
            rank=(priority,trial_count)))
    end
    sort!(judged;by=row->row.rank,alg=Base.Sort.MergeSort)
    return (; ranked=judged, values.click_count, values.groups)
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
    recent = min(count,length(rec.confirmed_refs))
    tail = @view rec.confirmed_refs[end-recent+1:end]
    return sort!(unique([rec.before_ref; own_sources; tail]))
end

relation_condition_key(rule) = semantic_hash([mechanism_key(rule;composing=true),
    isnothing(rule.click) ? nothing : rule.click.offsets])

function relation_condition_view(knowledge,rec,history,obs)
    models = Dict{String,Vector{ActiveMechanism}}()
    for model in knowledge.active
        push!(get!(Vector{ActiveMechanism},models,relation_condition_key(model.rule)),model)
    end
    receipts = Dict{String,Vector{String}}()
    reads(model) = get!(() -> recovery_reads(rec,model),receipts,model.rule.id)
    return (;models,history,reads,transients=receipt_transient_colors(obs.frames))
end

function predict_public(rec, item; plan_reads=String[],intervention_goal=nothing)
    choice = item.chosen
    if isnothing(choice)
        isnothing(intervention_goal) && return nothing
        return (before_ref=rec.before_ref,payload=Dict("model_version"=>intervention_goal.model,
            "binding"=>[Dict("slot"=>0,"ref"=>rec.before_ref * "-clicked-object")],
            "action"=>item.action,"guard_truth"=>true,"query_scope"=>["public_advancement"],
            "predicted_values"=>Dict("public_advancement"=>true),
            "event_reads"=>sort!(unique([rec.before_ref;plan_reads])),"enumeration_complete"=>false,
            "assumptions"=>[item.reason]))
    end
    measurements = String[ref for part in choice.fragments if part.family == :measurement
        for ref in (part.binding.face.source,part.binding.calibrated_at)]
    reads = sort!(unique([recovery_reads(rec,choice.model);plan_reads;measurements]))
    binding = [
        Dict("slot"=>i-1,"ref"=>rec.before_ref * "-query-" * key)
        for (i,key) in enumerate(sort!(collect(keys(choice.expected))))
    ]
    values = copy(choice.expected)
    if !isnothing(intervention_goal)
        values["public_advancement"] = true
        push!(binding,Dict("slot"=>length(binding),"ref"=>rec.before_ref * "-clicked-object"))
    end
    return (before_ref=rec.before_ref,payload=Dict("model_version"=>active_id(choice.model),
        "binding"=>binding,"action"=>item.action,"guard_truth"=>true,
        "query_scope"=>sort!(collect(keys(values))),"predicted_values"=>values,
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

function prepare_effect_learning!(knowledge, config, store, pairs, repo_root; existing_job=nothing)
    isempty(pairs) && return nothing
    for (pre,post) in pairs
        register_evidence_obligation!(store,pre)
        register_evidence_obligation!(store,post)
    end
    batch = learning_batch(pairs)
    evidence = batch["evidence_snapshot_id"]
    job = if isnothing(existing_job)
        knowledge.learning_jobs += 1
        path = store_path(store,"learning","job-" * lpad(knowledge.learning_jobs,6,'0'))
        mkpath(path)
        atomic_json(joinpath(path,"batch.json"),batch)
        path
    else
        read_json(joinpath(existing_job,"batch.json")) == batch || error("Recovered learning input differs")
        existing_job
    end
    learning = config.learning
    publication_dir = store_path(store,"publication")
    current = read_published_stitch(publication_dir)
    base = isnothing(current) ? LibrarySnapshot() : current.snapshot
    corpus = relation_corpus(pairs;previous_signature=isnothing(current) ? nothing : current.bundle["signature"],
        observations=knowledge.observations)
    isnothing(current) || merge_semantic_signature!(corpus.signature,current.bundle["signature"])
    atomic_json(joinpath(job,"observations.json"),Dict("scope_complete"=>corpus.complete,
        "events"=>public_effect_record.(corpus.observed),"bindings"=>corpus.bindings,
        "dispositions"=>corpus.dispositions, "scope"=>motion_guard_limits(config)))
    if isempty(corpus.programs)
        learning_assessment!(job,batch,"no_eligible_terms"; complete=true)
        return nothing
    end
    config_text = read(learning["policy_file"], String)
    supervision = read_json(store_path(store,"supervision.json"))
    content_hash(config_text) == supervision["policy_sha256"] || error("Session policy changed since launch")
    input = joinpath(job,"input")
    manifest_path = joinpath(input,"manifest.json")
    manifest = if isfile(manifest_path)
        read_json(manifest_path)
    else
        freeze_stitch_job(input,basename(job),evidence,base,corpus.signature,
            corpus.programs,corpus.origins,corpus.slots;repo_root,config_text,
            engine_identity=supervision["engine_identity"],input_scope_complete=corpus.complete,
            intent="effect", consumer="joint-mechanisms", obligation_refs=[row[2] for row in batch["inputs"]])
    end
    return (; job,batch,evidence,input,manifest,corpus,pairs)
end

function collect_effect_learning!(knowledge,config,store,prepared,status)
    (;job,batch,evidence,input,manifest,corpus,pairs) = prepared
    supervision = read_json(store_path(store,"supervision.json"))
    status["policy_sha256"] == manifest["config_file"]["sha256"] == supervision["policy_sha256"] ||
        error("Worker ran a different policy")
    if status["code"] ∉ (0,10) || !isdir(joinpath(job,"output"))
        learning_assessment!(job,batch,"worker_incomplete"; status)
        return nothing
    end
    publication_dir = store_path(store,"publication")
    current = read_published_stitch(publication_dir)
    checked = read_stitch_rounds(input,joinpath(job,"output"))
    checked.manifest["evidence_snapshot_id"] == evidence && checked.text == corpus.programs &&
        checked.origins == corpus.origins && checked.signature == corpus.signature ||
        error("Verified learning job does not agree with replayed evidence")
    summary = checked.summary
    termination_reason = isnothing(summary) ? nothing : summary["termination_reason"]
    fixed_point = termination_reason == "verified_compression_fixed_point"
    complete = termination_reason in ("verified_compression_fixed_point","input_scope_incomplete") &&
        !isempty(checked.verified) && last(checked.verified)["round_outcome"] == "no_positive_gain"
    if isempty(checked.verified) || isempty(last(checked.verified)["calls"])
        learning_assessment!(job,batch,"no_proved_definition_call"; complete, status,
            termination_reason, fixed_point)
        return nothing
    end
    digest = !isnothing(current) && current.bundle["input_sha256"] == checked.input_sha ?
        current.publication : publish_stitch!(publication_dir,checked;current_evidence=evidence)
    published = read_published_stitch(publication_dir;publication=digest)
    knowledge.definition_depths = definition_depths(published.snapshot.entries)
    incoming = read_joint_mechanisms(published,corpus,pairs)
    composing = !isnothing(config.planning) && haskey(config.planning,"goal")
    known = Dict(mechanism_key(rule;composing)=>rule for rule in knowledge.rules)
    for rule in incoming
        get!(known,mechanism_key(rule;composing),rule)
    end
    knowledge.rules = sort!(collect(values(known));by=rule->rule.id)
    limits = mechanism_limits(config)
    current_models = Dict(model.rule.id=>model for model in knowledge.active)
    knowledge.active = [get(() -> fit_joint_condition(rule,knowledge.trials,limits),current_models,rule.id)
        for rule in knowledge.rules]
    persist_relation_certificates!(store,knowledge.active)
    learning_assessment!(job,batch,"published"; complete, status, termination_reason, fixed_point,
        publication=digest, definitions=published.bundle["new_definition_ids"],
        current_mechanisms=active_id.(knowledge.active))
    return digest
end

function online_learn!(knowledge,config,store,pairs,repo_root; existing_job=nothing)
    prepared = prepare_effect_learning!(knowledge,config,store,pairs,repo_root;existing_job)
    isnothing(prepared) && return nothing
    status = wait_worker(prepared.job,store_path(store))
    return collect_effect_learning!(knowledge,config,store,prepared,status)
end

function finalize_learning!(knowledge, config, store, pairs, repo_root; frozen, inflight)
    publications = String[]
    if !isnothing(inflight)
        frozen && error("A background job crossed the evaluation boundary")
        status = wait_worker(inflight.job,store_path(store))
        publication = collect_effect_learning!(knowledge,config,store,inflight,status)
        isnothing(publication) || push!(publications,publication)
    end
    if !frozen
        for batch in Iterators.partition(pairs,config.learning["batch_confirmed_events"])
            publication = online_learn!(knowledge,config,store,batch,repo_root)
            isnothing(publication) || push!(publications,publication)
        end
    end
    pending = summarize_learning!(store)
    return (; publications,pending)
end

function collect_online_job!(knowledge,config,rec,job,status,publications,program_jobs,completed_cohorts;
                             live_agenda=nothing)
    if job.kind == :effect
        publication = collect_effect_learning!(knowledge,config,rec.store,job.prepared,status)
        isnothing(publication) || push!(publications,publication)
    elseif job.kind == :policy
        assessment = collect_policy_learning!(knowledge,rec.store,job.prepared,status;
            available_after=rec.before_ref,live_agenda)
        haskey(assessment,"publication") && push!(publications,assessment["publication"])
    else
        assessment = collect_program_learning!(knowledge,rec.store,job.prepared,status;
            available_after=rec.before_ref)
        push!(program_jobs,assessment)
        haskey(assessment,"publication") && push!(publications,assessment["publication"])
        if haskey(assessment,"cohort") && assessment["search_complete"] &&
                !isempty(get(assessment,"programs",[]))
            push!(completed_cohorts,assessment["cohort"])
        end
    end
end

function run_online!(rec, entry, config, repo_root; knowledge=OnlineKnowledge(), frozen=false,
                     visual_state=nothing, backends=Dict{String,ComputeWorker}())
    attempts = Dict{Tuple{Int,Int,Int},Int}()
    history = [0]
    pairs = []
    experiments = ExperimentSchedule()
    intervention_memory = InterventionMemory()
    relations = RelationAgenda()
    history_widths = get(something(config.search,Dict()),"history_lengths",[1,2,4])
    exploration_frontier = isnothing(rec.limit) ? PublicFrontier(history_widths) : nothing
    responses = ResponseLearning()
    factor_role_memo = Dict{Tuple,NamedTuple}()
    publications = String[]
    count = 0
    continuation = nothing
    goal_pending = nothing
    contact_pending = nothing
    program_cursor = nothing
    program_attempts = Set{Tuple{String,String,String}}()
    refuted_steps = Set{String}()
    inflight = nothing
    sequence_enabled = !frozen && get(config.learning,"sequences",false)
    sequence_events = sequence_enabled ? Any[entry] : Any[]
    measurement = MeterContext()
    program_jobs = Dict{String,Any}[]
    submitted_programs = Set{String}()
    completed_cohorts = Set{String}()
    submitted_policies = Set{String}()
    policy_needs_review = false
    blocked_policies = Set{String}()
    pending_policy = nothing
    policy_counterexample = nothing
    relation_policy_cursor = nothing
    attempted_relation_policies = Set{Tuple{String,String}}()
    policy_experiment_after = nothing
    last_relation_policy_check = 0
    pending_synthesis = nothing
    last_sequence_check = 0
    last_job = :program
    background = !frozen && get(config.learning,"background_search",false)
    composing = !isnothing(config.planning) && haskey(config.planning,"goal")
    relation_goals = !isnothing(config.planning) && get(config.planning,"relation_goals",false)
    spatial = !isnothing(config.planning) && get(config.planning,"autonomous",false) ? SpatialLearning() : nothing
    visual = isnothing(spatial) ? nothing : isnothing(visual_state) ? VisualControl() : visual_state
    relation_tasks = !frozen && !isnothing(visual) && relation_goals
    goal = composing ? bind_observed_goal(last(rec.observation.frames),config.planning["goal"]) : nothing
    limits = mechanism_limits(config)
    coordinates = isnothing(config.search) ? 4096 : config.search["max_action_coordinates"]
    consumed_depth = 0
    frozen_version = frozen ? frozen_knowledge_digest(knowledge) : nothing
    frozen_publication = frozen ? read_published_stitch(store_path(rec.store,"publication")) : nothing
    register_evidence_obligation!(rec.store,entry;frozen)
    relation_tasks && publish_receipt_regions!(knowledge,rec.store,entry)
    ready_at = time_ns()
    while public_budget_available(rec) && !rec.frozen
        if !isnothing(inflight) && isfile(joinpath(inflight.job,"worker-status.json"))
            status = read_json(joinpath(inflight.job,"worker-status.json"))
            collect_online_job!(knowledge,config,rec,inflight,status,publications,program_jobs,completed_cohorts;
                live_agenda=relations)
            inflight = nothing
        end
        if relation_tasks
            collect_response_model!(responses,rec.store,relations)
            collect_history_model!(responses,rec.store,relations)
        end
        decision_started = time_ns()
        obs = rec.observation
        meter_context!(measurement,obs)
        meters = collect(values(measurement.bindings))
        obs.state == "WIN" && break
        failed = obs.state == "GAME_OVER"
        retry = failed && relation_tasks ? failure_retry!(relations;frontier=exploration_frontier) : nothing
        failed && isnothing(retry) && break
        exhausted = !isnothing(visual) && !isnothing(visual.resource) &&
            read_meter(last(obs.frames),visual.resource) == 0
        if failed || exhausted
            failed || may_retry_visual_attempt!(visual,spatial,obs.levels_completed) || break
            reset = reset!(rec,obs.game_id)
            reset["completion"] == "confirmed" || break
            event = read_json(store_path(rec.store,"events",rec.before_ref * ".json"))
            reset_entry = (;event,observation=rec.observation)
            register_evidence_obligation!(rec.store,reset_entry;frozen)
            reset_regions = relation_tasks ? receipt_regions(reset_entry;previous=entry,previous_regions=knowledge.receipt) : nothing
            entry = reset_entry
            sequence_enabled && push!(sequence_events,entry)
            continuation = nothing
            goal_pending = nothing
            program_cursor = nothing
            contact_pending = nothing
            pending_policy = nothing
            policy_counterexample = nothing
            relation_policy_cursor = nothing
            policy_experiment_after = nothing
            fresh_binding = failed || rec.observation.levels_completed != obs.levels_completed
            if fresh_binding
                begin_visual_level!(visual,spatial)
                spatial = SpatialLearning()
                measurement = MeterContext()
                empty!(attempts)
                empty!(program_attempts)
                empty!(refuted_steps)
                empty!(blocked_policies)
                rebind_interventions!(intervention_memory)
            else
                begin_visual_attempt!(visual)
                intervention_memory.prior_observation = nothing
            end
            begin_relation_attempt!(relations,retry;observation=rec.observation)
            isnothing(exploration_frontier) || (exploration_frontier.route = nothing)
            atomic_json(store_path(rec.store,"attempts",reset["command_id"] * ".json"),(;
                event=rec.before_ref,prior=event["before_ref"],attempt=relations.attempt,revision=relations.restart,
                previous_level=obs.levels_completed,level=rec.observation.levels_completed,
                full_reset=rec.observation.full_reset,session=rec.observation.guid,rebound=fresh_binding))
            isnothing(reset_regions) || publish_receipt_regions!(knowledge,rec.store,reset_entry,reset_regions)
            history = [0]
            ready_at = time_ns()
            continue
        end
        if composing && isnothing(goal)
            goal = bind_observed_goal(last(obs.frames),config.planning["goal"])
        end
        !isnothing(goal) && goal_truth(goal,last(obs.frames)) == proven && break
        programs_pending = !isempty(knowledge.programs)
        object_probes = !isnothing(visual) && !composing && 6 in obs.available_actions
        relation_tasks && knowledge.receipt.event != rec.before_ref &&
            error("Decision would consume a different grounded receipt")
        ranking_started = time_ns()
        decision = ranked_public_actions(knowledge,obs,history,attempts,coordinates;
            composing,programs_pending,program_cursor,meters,object_probes,regions=knowledge.receipt)
        condition_view = relation_tasks ? relation_condition_view(knowledge,rec,history,obs) : nothing
        decision = merge(decision,(;condition_view))
        click_scene = object_probes ? intervention_scene(last(obs.frames),decision.groups) : NamedTuple[]
        isempty(decision.ranked) && break
        spatial_started = time_ns()
        item = first(decision.ranked)
        policy_note = nothing
        goal_cursor = nothing
        if composing
            selection = choose_observed_goal_step(rec,knowledge,goal,history,decision,goal_pending,coordinates;meters)
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
        learned_goal = if relation_goals && !isnothing(visual)
            learned_advancement(visual,obs.action["id"],rec.before_ref)
        end
        selected_policy = isnothing(pending_policy) ? active_policy(knowledge.policies,learned_goal) : nothing
        if !isnothing(selected_policy) && selected_policy.policy.definition in blocked_policies
            selected_policy = nothing
        end
        spatial_choice = if !isnothing(spatial)
            planned = autonomous_visual_plan(visual,spatial,obs,decision,rec.before_ref;
                goal=learned_goal,relationship=isnothing(selected_policy) ? nothing : selected_policy.relation,
                refuted=policy_counterexample)
            isnothing(planned) ? spatial_experiment(spatial,obs,decision) : planned
        end
        spatial_baseline = spatial_choice
        baseline_action = isnothing(spatial_choice) ? item.action : Dict("id"=>spatial_choice.id)
        continuing_contact = false
        contact_domain = if relation_goals && !isnothing(spatial) && programs_pending
            contact_goal_domain(visual,spatial,obs)
        end
        if !isnothing(contact_pending)
            verified_contact = planned_contact_step(contact_domain,contact_pending,obs,rec.before_ref)
            if !isnothing(verified_contact)
                spatial_choice = verified_contact
                visual.continuation = nothing
                continuing_contact = true
            end
            contact_pending = nothing
        end
        programs_started = time_ns()
        program_note = nothing
        program_forecast = nothing
        previous_program = program_cursor
        program_attempt = nothing
        if programs_pending
            constrained = composing || !isnothing(spatial)
            remaining = isnothing(rec.limit) ? typemax(Int) : rec.limit - rec.sent_count
            primitive_limit = isnothing(goal_cursor) ? remaining :
                length(projected_trace(goal_cursor))
            contact_limit = if isnothing(contact_domain) || isnothing(spatial_choice) ||
                    isnothing(visual.continuation) || spatial_choice.reason != "learned_visual_contact"
                0
            else
                1 + length(visual.continuation.steps)
            end
            needs = relation_goals && !isnothing(goal) ?
                goal_producer_needs(knowledge,goal,obs,history,coordinates,meters) : []
            function eligible(cursor)
                next = current_program_step(cursor,decision)
                isnothing(next) && return nothing
                constrained || return (;next,forecast=nothing)
                forecast = if relation_goals && !isnothing(goal)
                    program_establishes_goal(knowledge,goal,obs,history,cursor,coordinates,meters,
                        primitive_limit,needs)
                elseif contact_limit > 1
                    program_prepares_contact(knowledge,contact_domain,obs,history,cursor,coordinates,meters,
                        min(primitive_limit,contact_limit),rec.before_ref,spatial_choice.contact)
                end
                if isnothing(forecast)
                    forecast = goal_program(knowledge,obs,history,cursor,coordinates,meters,goal,spatial,
                        visual,spatial_choice,primitive_limit,goal_cursor)
                end
                isnothing(forecast) && return nothing
                return (;next=first(forecast.path).item,forecast)
            end
            selected_program = nothing
            if isnothing(program_cursor)
                state = content_hash(JSON.json([obs.levels_completed,last(obs.frames),obs.available_actions]))
                considered = Set{String}()
                for program in programs_for_relations(knowledge,needs)
                    constrained || length(program.steps) <= remaining || continue
                    any(step->program_step_key(step) in refuted_steps,program.steps) && continue
                    if contact_limit <= 1 && !isnothing(spatial_choice) &&
                            first(program.steps)["action"]["id"] != spatial_choice.id
                        continue
                    end
                    contract = semantic_hash([program.definition,program_step_key.(program.steps),program.shared])
                    contract in considered && continue
                    push!(considered,contract)
                    cursor = ProgramCursor(program,1,Any[])
                    candidate = eligible(cursor)
                    isnothing(candidate) && continue
                    projected = candidate.next.projection_contract
                    revision = isnothing(projected) ? active_id(candidate.next.chosen.model) : projected.version
                    key = (contract,state,revision)
                    key in program_attempts && continue
                    program_attempt = key
                    program_cursor = cursor
                    selected_program = candidate
                    break
                end
            else
                selected_program = eligible(program_cursor)
            end
            if !isnothing(program_cursor)
                definition = program_cursor.program
                program_note = Dict("definition"=>definition.definition,"publication"=>definition.publication,
                    "depth"=>definition.depth,"index"=>program_cursor.next_step,
                    "length"=>length(definition.steps),"training_events"=>definition.sources,
                    "available_after"=>definition.available_after,
                    "ordinary_action"=>first(decision.ranked).action,"baseline_action"=>baseline_action)
                if isnothing(selected_program)
                    program_note["feedback"] = "withdrawn_before_unproved_step"
                    program_note["withdrawn_suffix"] = collect(program_cursor.next_step:length(definition.steps))
                    program_cursor = nothing
                else
                    item = selected_program.next
                    program_forecast = selected_program.forecast
                    if !isnothing(program_forecast)
                        program_note["goal"] = goal_program_record(program_forecast)
                        program_note["relation_contract"] =
                            program_relation_contract(program_cursor.program,program_forecast)
                    end
                end
            end
        end
        tasks_started = time_ns()
        intervention = if object_probes
            choose_intervention(intervention_memory,click_scene,obs,decision.ranked,attempts;
                explore=!frozen,goal_learning=relation_goals,confirmed_count=count,
                agenda=relation_tasks ? relations : nothing,groups=decision.groups,
                meters,condition_view)
        end
        experiment = if !frozen && !composing
            if object_probes
                mixed_prefix_experiment(experiments,obs.levels_completed,obs.available_actions,history)
            elseif isnothing(program_cursor) && isnothing(spatial_choice)
                select_experiment!(experiments,rec.store,decision.ranked,obs.available_actions,rec.before_ref;
                    level=obs.levels_completed,history)
            end
        end
        context = relation_tasks ? relation_context(obs) : nothing
        relation_choice = if relation_tasks
            proposed = relation_experiment(relations,obs,decision,intervention,context;meters,
                uncertainty=circuit_experiment_scores(responses,relations),circuit_ref=responses.scope,
                history_model=history_experiment(responses,relations,context,obs.levels_completed),
                frontier=exploration_frontier)
            isnothing(proposed) ? partition_experiment(relations,click_scene,obs,context,knowledge.receipt) : proposed
        end
        relation_policy = if relation_tasks && isnothing(relations.restart)
            relation_policy_choice(knowledge.policies,relation_policy_cursor,attempted_relation_policies,
                relations,obs,decision;meters,relation=relation_choice)
        end
        policy_withdrawal = if !isnothing(relation_policy_cursor) && isnothing(relation_policy)
            prior = relation_policy_cursor
            (;definition=prior.policy.definition,last_observed=last(prior.observed),reason="unbound_next_task")
        end
        frontier = if relation_tasks && !isnothing(exploration_frontier)
            (;search=exploration_frontier,agenda=relations,observation=obs,decision,context)
        end
        policy_yield = !isnothing(policy_experiment_after) && !isnothing(relation_policy) &&
            isnothing(relation_policy_cursor)
        arbitration = task_arbitration(item,spatial_choice,intervention,relation_choice,experiment;
            program=!isnothing(program_cursor),continuing_contact,
            conditional=!isnothing(goal_cursor) || !isnothing(item.follow) ||
                get(something(policy_note,Dict()),"status",nothing) == "ready",
            object_probes,policy=isnothing(relation_policy) ? nothing : relation_policy.proposal,
            continuing_policy=!isnothing(relation_policy_cursor),policy_yield,frontier)
        prediction_started = time_ns()
        selected = arbitration.choice
        program_selected = selected.source == :program
        if program_selected
            if !isnothing(program_forecast)
                hasproperty(program_forecast,:contact_target) && (spatial_choice = nothing)
                goal_cursor = nothing
                policy_note = nothing
            end
        elseif !isnothing(program_cursor)
            program_cursor = previous_program
            program_attempt = nothing
            program_note = nothing
            program_forecast = nothing
        end
        isnothing(arbitration.frontier_task) || (relation_choice = arbitration.frontier_task)
        if selected.action != item.action || selected.source in (:spatial,:intervention,:relation,:relation_policy)
            choice = findfirst(row->row.action == selected.action,decision.ranked)
            if isnothing(choice)
                decision = ranked_public_actions(knowledge,obs,history,attempts,coordinates;
                    composing,required_action=selected.action,meters,object_probes,regions=knowledge.receipt)
                decision = merge(decision,(;condition_view))
                choice = findfirst(row->row.action == selected.action,decision.ranked)
            end
            item = merge(decision.ranked[choice],(reason=selected.reason,))
        end
        if selected.source ∉ (:spatial,:program)
            if !isnothing(spatial_choice)
                visual.continuation = nothing
                spatial_choice = nothing
            end
        end
        if selected.source ∉ (:base,:program)
            policy_note = nothing
            goal_cursor = nothing
        end
        selected.source == :experiment || (experiment = nothing)
        !isnothing(intervention) && selected.action == intervention.action || (intervention = nothing)
        object_probes && (intervention = executed_intervention(intervention,click_scene,item.action))
        intervention_goal = isnothing(intervention) ? nothing : intervention.goal
        selected.source == :relation_policy || (relation_policy = nothing)
        isnothing(policy_withdrawal) || (relation_policy_cursor = nothing)
        relation_proposal = if relation_tasks
            if !isnothing(relation_policy)
                relation_policy.proposal
            elseif selected.source == :relation
                relation_choice
            else
                tests = isnothing(intervention) ? nothing : get(intervention,:tests,nothing)
                isnothing(tests) && (tests = prepare_relation_tests(relations,context,obs,decision.groups,
                    item.action;meters,condition_view))
                isempty(tests) ? nothing : (action=item.action,intent=:apply_relation,tests,reads=String[],obligation=nothing)
            end
        end
        role_proof = if !isnothing(relation_proposal) && haskey(backends,"factor_kernel")
            role_factor_proof!(backends["factor_kernel"],relation_proposal,obs,rec.before_ref;memo=factor_role_memo)
        end
        resource_proof = if !isnothing(relation_proposal) && haskey(backends,"solver_python")
            resource_constraint_proof!(backends["solver_python"],relation_proposal,rec.before_ref)
        end
        relation_task = isnothing(relation_proposal) ? nothing : relation_task_record(relation_proposal)
        task = advancement_task(learned_goal,visual,spatial,obs,spatial_choice)
        policy_task = policy_task_record(selected_policy,learned_goal,spatial_choice,blocked_policies)
        plan_reads = isnothing(goal_cursor) ? String[] : reduce(vcat,
            (recovery_reads(rec,model) for model in knowledge.active if haskey(goal_cursor.node.dependencies,model.rule.id));
            init=String[])
        isnothing(task) || append!(plan_reads,task.reads)
        isnothing(policy_task) || append!(plan_reads,policy_task.reads)
        isnothing(intervention_goal) || append!(plan_reads,intervention_goal.reads)
        if !isnothing(experiment) && hasproperty(experiment,:obligation)
            push!(plan_reads,experiment.obligation.baseline_event)
        end
        isnothing(policy_counterexample) || push!(plan_reads,policy_counterexample.event)
        isnothing(policy_note) || append!(plan_reads,get(policy_note,"event_reads",String[]))
        policy_yield && push!(plan_reads,policy_experiment_after)
        if program_selected
            program = program_cursor.program
            append!(plan_reads,program.sources)
            isnothing(program.available_after) || push!(plan_reads,program.available_after)
            if !isnothing(program_forecast)
                if hasproperty(program_forecast,:regression)
                    append!(plan_reads,program_forecast.regression.reads)
                end
                for step in program_forecast.path
                    append!(plan_reads,recovery_reads(rec,step.item.chosen.model))
                    append!(plan_reads,step.item.projection_contract.reads)
                end
                if !isnothing(program_forecast.continuation)
                    rules = Set(step["rule"] for step in program_forecast.continuation)
                    for model in knowledge.active
                        model.rule.id in rules && append!(plan_reads,recovery_reads(rec,model))
                    end
                end
            end
        end
        projected = item.projection_contract
        projection_choice = item.chosen
        if isnothing(projected) && !isnothing(item.projection_probe)
            projection_choice,projected = item.projection_probe
        elseif isnothing(projected) && !isnothing(projection_choice) &&
                (composing || !isnothing(spatial) || programs_pending)
            projected = projected_contract(knowledge.projections,projection_choice,last(obs.frames),history)
        end
        if !isnothing(projected)
            append!(plan_reads,[projected.training;projected.reads])
        end
        prediction = predict_public(rec,item;plan_reads,intervention_goal)
        isnothing(relation_task) || (prediction = relation_prediction(rec,item,prediction,relation_task;role_proof,resource_proof))
        if !isnothing(spatial_choice)
            reads = unique([rec.before_ref;spatial_choice.reads])
            spatial_version = "spatial-" * content_hash(JSON.json(spatial_choice))
            if isnothing(prediction)
                prediction = (before_ref=rec.before_ref,payload=Dict{String,Any}(
                    "model_version"=>spatial_version,
                    "binding"=>[], "action"=>item.action,"guard_truth"=>"unknown",
                    "query_scope"=>String[],"predicted_values"=>Dict{String,Any}(),
                    "event_reads"=>reads,"enumeration_complete"=>false,
                    "assumptions"=>[item.reason]))
            else
                prediction.payload["event_reads"] = unique([prediction.payload["event_reads"];reads])
            end
            prediction.payload["spatial_experiment"] = spatial_choice
            prediction.payload["spatial_model_version"] = spatial_version
            if !isnothing(get(spatial_choice,:expected,nothing))
                prediction.payload["predicted_values"]["visual_signal"] = spatial_choice.expected
                prediction.payload["query_scope"] = sort!(collect(keys(prediction.payload["predicted_values"])))
            end
        end
        id = command_id(rec.next_sequence)
        plan = composing || program_selected || isnothing(config.planning) || isnothing(item.follow) ? nothing :
            propose_condition_plan(item,id)
        if !isnothing(plan)
            policy_note = Dict("operation"=>"freeze_projected_policy","status"=>"ready",
                "goal"=>"observed_condition_then_bound_effect","first"=>item.action,
                "next"=>plan.target.action,"dependencies"=>plan.policy.dependencies)
        end
        finished_decision = time_ns()
        timing_seconds = (observation=(ranking_started-decision_started)/1e9,
            action_ranking=(spatial_started-ranking_started)/1e9,
            goal_and_spatial_planning=(programs_started-spatial_started)/1e9,
            program_selection=(tasks_started-programs_started)/1e9,
            task_arbitration=(prediction_started-tasks_started)/1e9,
            action_binding_and_prediction=(finished_decision-prediction_started)/1e9)
        decision_record = Dict("command_id"=>id,"before_ref"=>rec.before_ref,"action"=>item.action,
            "reason"=>item.reason,"tried_after_previous"=>get(attempts,action_key(item.action),0),
            "decision_seconds"=>(finished_decision-decision_started)/1e9,
            "confirmed_to_decision_seconds"=>(finished_decision-ready_at)/1e9,
            "timing_seconds"=>timing_seconds,
            "candidates"=>[Dict("action"=>x.action,"reason"=>x.reason,"rank"=>x.rank,
                "relation_reads"=>x.relation_reads) for x in decision.ranked],
            "coordinate_domain"=>Dict("visible_candidates"=>decision.click_count,
                "protocol_points"=>6 in obs.available_actions ? 4096 : 0,
                "attempted"=>sum(key[1] == 6 for key in keys(attempts);init=0)))
        isnothing(policy_note) || (decision_record["policy"] = policy_note)
        isnothing(task) || (decision_record["relation_task"] = task)
        if relation_tasks
            decision_record["grounding_read"] = (event=knowledge.receipt.event,
                response_blob=entry.event["response_blob"])
            decision_record["task_arbitration"] = (;arbitration.choice,arbitration.baseline,arbitration.candidates)
            isnothing(relation_task) || (decision_record["public_relation_task"] = relation_task)
            isnothing(role_proof) || (decision_record["factor_role_proof"] = role_proof)
            isnothing(resource_proof) || (decision_record["resource_constraint_proof"] = resource_proof)
            isnothing(policy_withdrawal) || (decision_record["relation_policy_withdrawal"] = policy_withdrawal)
            policy_yield && (decision_record["exploration_after_policy"] = policy_experiment_after)
        end
        if !isnothing(relation_policy)
            policy = relation_policy.cursor.policy
            decision_record["relation_policy"] = (;definition=policy.definition,
                definitions=policy.body["definitions"],policy.publication,policy.available_after,
                policy.training,structure=policy.body["structure"],branches=relation_policy.branches,
                purpose=relation_policy.cursor.purpose,
                baseline_action=arbitration.baseline.action,changed_action=item.action != arbitration.baseline.action)
        end
        isnothing(policy_task) || (decision_record["learned_policy"] = policy_task)
        isnothing(intervention) || (decision_record["intervention"] = intervention_record(intervention,rec.before_ref))
        isnothing(spatial_choice) || (decision_record["spatial_experiment"] = spatial_choice)
        if !isnothing(spatial_baseline) && spatial_baseline != spatial_choice
            decision_record["spatial_baseline"] = spatial_baseline
        end
        isnothing(item.experiment) || (decision_record["experiment"] = item.experiment)
        isnothing(experiment) || (decision_record["experiment_obligation"] = experiment)
        isnothing(visual) || (decision_record["site_surveys"] = take_site_surveys!(visual))
        isnothing(program_note) || (decision_record["program"] = program_note)
        if !isnothing(projected)
            decision_record["projection"] = projection_record(projected,last(obs.frames))
        end
        isnothing(inflight) || (decision_record["pending_learning_job"] = basename(inflight.job))
        if !isnothing(item.chosen)
            model = item.chosen.model
            decision_record["mechanism_version"] = active_id(model)
            decision_record["binding_views"] = binding_view.(model.rule.effects)
            decision_record["condition_atoms"] = predicate_record.(model.condition.atoms)
            decision_record["relations"] = predicate_record.(filter(p->p isa RelationPredicate,model.condition.atoms))
            relation_macros = [ref for p in model.condition.atoms if p isa RelationPredicate for ref in p.macro_refs]
            decision_record["definition_refs"] = unique([model.rule.references;relation_macros])
        end
        if program_selected
            decision_record["definition_refs"] = unique([decision_record["definition_refs"];program_cursor.program.definition])
        end
        if !isnothing(policy_task)
            decision_record["definition_refs"] = unique([get(decision_record,"definition_refs",String[]);
                policy_task.definition])
        end
        if !isnothing(relation_policy)
            decision_record["definition_refs"] = unique([get(decision_record,"definition_refs",String[]);
                relation_policy.cursor.policy.body["definitions"]])
        end
        if !isnothing(policy_counterexample)
            decision_record["policy_counterexample"] = policy_counterexample
            policy_counterexample = nothing
        end
        atomic_json(store_path(rec.store,"decisions",id * ".json"),decision_record)
        args = item.action["id"] == 6 ? (x=item.action["x"],y=item.action["y"]) : (;)
        start = time_ns()
        command = submit_action!(rec,item.action["id"];args...,prediction)
        elapsed = (time_ns() - start)/1e9
        command["completion"] == "confirmed" || break
        program_selected && !isnothing(program_attempt) && push!(program_attempts,program_attempt)
        if !isnothing(relation_policy)
            scope = relation_policy.cursor.policy.body["scope"]
            push!(attempted_relation_policies,(scope,relation_policy.context))
        end
        referenced_definitions = get(decision_record,"definition_refs",String[])
        decision_depth = maximum((knowledge.definition_depths[id] for id in referenced_definitions); init=0)
        consumed_depth = max(consumed_depth,decision_depth)
        ready_at = time_ns()
        event = read_json(store_path(rec.store,"events",rec.before_ref * ".json"))
        resulting = (; event,observation=rec.observation)
        register_evidence_obligation!(rec.store,resulting;frozen)
        if relation_tasks
            record_experiment_prefix!(experiments,obs.levels_completed,obs.available_actions,history,item.action,event["event_id"])
        end
        isnothing(experiment) || record_experiment_service!(experiments,rec.store,experiment,event)
        sample = motion_example(entry,resulting;history)
        before_regions = knowledge.receipt
        after_regions = relation_tasks ? receipt_regions(resulting;previous=entry,previous_regions=knowledge.receipt) : nothing
        effects = observed_effects(entry,resulting;meters=measurement,before_regions,after_regions)
        intervention_feedback = observe_intervention!(intervention_memory,intervention,entry,resulting,effects;
            learn=!frozen,ordinal=count+1)
        knowledge.observations[effects.event_id] = effects
        if sequence_enabled
            push!(sequence_events,resulting)
        end
        spatial_feedback = nothing
        visual_feedback = nothing
        contact_feedback = nothing
        visual_observation = nothing
        site_transitions = NamedTuple[]
        motion_revision = nothing
        if !isnothing(spatial)
            contact_feedback = observe_visual_contact!(visual,spatial,entry,resulting;learn=!frozen)
            if obs.levels_completed == resulting.observation.levels_completed
                spatial_feedback = observe_spatial!(spatial,entry,resulting,effects)
                site_transitions = update_contact_sites!(visual,spatial,resulting)
                visual_observation = observe_visual!(visual,spatial,entry,resulting,spatial_feedback,effects)
                if !isnothing(spatial_feedback)
                    origin = locate_role(sample.before,spatial.role)
                    key = (origin,item.action["id"])
                    if haskey(spatial.conditions,key)
                        evidence = motion_evidence(spatial,origin,item.action["id"],sample.before,last(history);current=true)
                        motion_revision = (origin,action=item.action["id"],status=evidence.status,
                            reads=evidence.reads,variables=sort!(collect(keys(spatial.conditions[key]));by=repr))
                    end
                end
                if !isnothing(visual.field) && !isnothing(get(something(spatial_choice,(;)),:expected,nothing))
                    actual = visual_value(last(resulting.observation.frames),visual.field)
                    if isnothing(spatial_feedback) || isnothing(actual)
                        visual_feedback = (actual=actual,verdict="unknown")
                    else
                        agreement = spatial_feedback.after == spatial_choice.destination &&
                            actual == spatial_choice.expected
                        visual_feedback = (actual=actual,point=spatial_feedback.after,
                            verdict=agreement ? "supported" : "refuted")
                    end
                end
            else
                begin_visual_level!(visual,spatial)
                previous = spatial
                spatial = SpatialLearning()
                if !isnothing(locate_role(last(resulting.observation.frames),previous.role))
                    spatial.role = copy(previous.role)
                    spatial.role_reads = unique([previous.role_reads;effects.event_id])
                end
            end
        end
        assessment = isnothing(item.chosen) ? (actual=Dict(),assessments=Dict()) :
            measure_joint((model=item.chosen.model.rule,fragments=item.chosen.fragments),sample.after)
        relation_feedback = if relation_tasks
            observation = observe_relations!(relations,entry,resulting,effects,contact_feedback,site_transitions,
                relation_proposal;groups=decision.groups)
            finish_relation_dispatch!(relations,relation_proposal;feedback=observation.feedback)
            if !isnothing(exploration_frontier)
                refined = frontier_observe!(exploration_frontier,relations)
                isnothing(refined) || (observation = merge(observation,(history_refinement=refined,)))
                route = confirm_frontier_route!(exploration_frontier,relations,relation_proposal)
                isnothing(route) || (observation = merge(observation,(frontier_continuation=route,)))
            end
            observation
        end
        if relation_tasks && haskey(backends,"circuit_python")
            refinement = get(relation_feedback,:history_refinement,nothing)
            batch = config.learning["batch_confirmed_events"]
            worker = backends["circuit_python"]
            observe_response!(responses,relations;refinement)
            request_history_model!(responses,worker,relations,rec.before_ref,batch;priority=!isnothing(refinement))
            request_response_model!(responses,worker,relations,rec.before_ref,batch)
        end
        policy_experiment_after = nothing
        relation_policy_feedback = if !isnothing(relation_policy)
            feedback = confirm_relation_policy!(relation_policy,relations,relation_feedback,resulting)
            relation_policy_cursor = feedback.cursor
            policy_experiment_after = feedback.experiment_after
            (;event=sample.event_id,feedback.result,feedback.branches,feedback.experiment_after,
                definition=relation_policy.cursor.policy.definition)
        end
        projection_feedback = if !isnothing(projected)
            local_feedback = projection_choice === item.chosen ? assessment :
                measure_joint((model=projection_choice.model.rule,fragments=projection_choice.fragments),sample.after)
            check_projection!(knowledge.projections,projected,sample.before,sample.after,effects,
                local_feedback,limits.history_lengths;frozen)
        end
        if program_selected
            unproved = !isnothing(program_forecast) && !projection_feedback.matching
            response = unproved ? "goal_projection_refuted" : program_feedback!(program_cursor,item,assessment,effects)
            if response == "advance" && !isnothing(program_forecast) && length(program_forecast.path) == 1
                response = "completed"
                program_note["terminated_at_goal"] = true
            end
            program_note["feedback"] = response
            if response != "advance"
                if response ∉ ("completed","goal_projection_refuted")
                    failed = program_cursor.program.steps[program_cursor.next_step]
                    push!(refuted_steps,program_step_key(failed))
                end
                program_note["withdrawn_suffix"] = response == "completed" ? Int[] :
                    collect(program_cursor.next_step+1:length(program_cursor.program.steps))
                if response == "completed" && !isnothing(program_forecast)
                    contact_pending = get(program_forecast,:contact_target,nothing)
                end
                program_cursor = nothing
            end
        elseif !isempty(assessment.assessments) && all(==("supported"),values(assessment.assessments))
            delete!(refuted_steps,program_step_key(item.action,item.chosen.model.rule.effects))
        end
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
        level_changed = obs.levels_completed != resulting.observation.levels_completed
        level_changed && (contact_pending = nothing)
        level_changed && (program_cursor = nothing)
        level_changed && empty!(refuted_steps)
        level_changed && empty!(blocked_policies)
        new_scene = !isnothing(spatial) && level_changed
        old = if frozen
            Dict()
        elseif new_scene
            previous = Dict(m.rule.id=>m for m in knowledge.active)
            empty!(knowledge.trials)
            knowledge.active = [fit_joint_condition(rule,knowledge.trials,limits) for rule in knowledge.rules]
            previous
        else
            archive_trial!(knowledge,PublicTrial(sample,item.action,effects),limits)
        end
        frozen || persist_relation_certificates!(rec.store,knowledge.active)
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
        monitored_policy = isnothing(pending_policy) ? policy_task : merge(pending_policy,(recheck=false,))
        policy_result = policy_task_feedback(monitored_policy,contact_feedback,entry,resulting,site_transitions,visual)
        if !isnothing(policy_result) && policy_result.result == :awaiting_visible_result
            pending_policy = policy_task
        elseif !isnothing(pending_policy) && policy_result.result == :continue &&
                !haskey(visual.site_entries,pending_policy.site)
            policy_result = merge(policy_result,(result=:invalidated_variant,))
        end
        if !isnothing(policy_result) && policy_result.result in (:refuted_branch,:invalidated_variant)
            push!(blocked_policies,monitored_policy.definition)
            if !isnothing(contact_feedback) && contact_feedback.outcome == :blocked
                policy_counterexample = (definition=monitored_policy.definition,
                    event=contact_feedback.event,origin=contact_feedback.origin,action=contact_feedback.action,
                    site=contact_feedback.point)
            end
        end
        if !isnothing(policy_result) && policy_result.result ∉ (:awaiting_visible_result,:continue)
            pending_policy = nothing
        end
        atomic_json(store_path(rec.store,"checks",id * ".json"),
            Dict("event_ref"=>sample.event_id,"action"=>item.action,"round_trip_seconds"=>elapsed,
                "definition_refs"=>referenced_definitions,"consumed_definition_depth"=>decision_depth,
                "read_events"=>isnothing(prediction) ? [sample.before_id] : prediction.payload["event_reads"],
                "expected"=>isnothing(item.chosen) ? Dict() : item.chosen.expected,
                "actual"=>assessment.actual,"assessments"=>assessment.assessments,"revisions"=>revisions,
                "evidence"=>public_effect_record(effects),"coverage"=>coverage_record(decision,item,effects,assessment),
                "policy"=>policy_note,"program"=>program_note,"projection"=>projection_feedback,
                "task_feedback"=>advancement_feedback(task,entry,resulting,contact_feedback),
                "intervention_feedback"=>intervention_feedback,
                "public_relation_feedback"=>relation_feedback,
                "relation_policy_feedback"=>relation_policy_feedback,
                "learned_policy_feedback"=>policy_result,
                "spatial_feedback"=>spatial_feedback,
                "visual_feedback"=>visual_feedback,"contact_feedback"=>contact_feedback,
                "site_transitions"=>site_transitions,
                "site_surveys"=>isnothing(visual) ? [] : take_site_surveys!(visual),
                "visual_observation"=>visual_observation,"motion_revision"=>motion_revision))
        isnothing(after_regions) || publish_receipt_regions!(knowledge,rec.store,resulting,after_regions)
        attempts[action_key(item.action)] = get(attempts,action_key(item.action),0) + 1
        push!(history,item.action["id"])
        frozen || push!(pairs,(entry,resulting))
        entry = resulting
        count += 1
        policy_needs_review |= !isnothing(contact_feedback) || !isempty(site_transitions)
        if !frozen && isnothing(inflight)
            count_for_batch = config.learning["batch_confirmed_events"]
            prepared = nothing
            if !isnothing(pending_synthesis) && istaskdone(pending_synthesis.task)
                proposal = fetch(pending_synthesis.task)
                if !isnothing(proposal)
                    prepared = prepare_policy_learning!(knowledge,config,rec.store,repo_root,
                        pending_synthesis.agenda;entries=pending_synthesis.entries,
                        completed=submitted_policies,proposal,live_agenda=relations)
                end
                pending_synthesis = nothing
            end
            if isnothing(prepared) && isnothing(pending_synthesis) && sequence_enabled &&
                    relation_tasks && last_job != :policy && count-last_relation_policy_check >= count_for_batch
                if haskey(backends,"policy_synthesis")
                    worker = backends["policy_synthesis"]
                    known = Set{String}(policy.body["scope"] for policy in knowledge.policies
                        if haskey(policy.body,"tree"))
                    frozen_agenda = deepcopy(relations)
                    frozen_entries = copy(sequence_events)
                    snapshot = rec.before_ref
                    task = Threads.@spawn policy_corpus(frozen_agenda,frozen_entries;
                        published=known,solver=worker,snapshot)
                    pending_synthesis = (;task,agenda=frozen_agenda,entries=frozen_entries)
                else
                    prepared = prepare_policy_learning!(knowledge,config,rec.store,repo_root,relations;
                        entries=sequence_events,completed=submitted_policies)
                end
                last_relation_policy_check = count
            end
            if isnothing(prepared) && sequence_enabled && relation_goals && !isnothing(visual) && policy_needs_review
                prepared = prepare_policy_learning!(knowledge,config,rec.store,repo_root,visual;
                    completed=submitted_policies)
                policy_needs_review = false
            end
            if !isnothing(prepared)
                push!(submitted_policies,prepared.key)
                last_job = :policy
            end
            if isnothing(prepared) && sequence_enabled && last_job == :effect &&
                    count-last_sequence_check >= count_for_batch
                closed = compile_sequence_corpus([sequence_events];observations=knowledge.observations,
                    close_revisits=true)
                last_sequence_check = count
                corpus = next_program_corpus(closed,sequence_events,knowledge.observations,submitted_programs,completed_cohorts)
                if !isnothing(corpus) && !isempty(corpus.programs) && program_corpus_key(corpus) ∉ submitted_programs
                    prepared = prepare_program_learning!(knowledge,config,rec.store,repo_root,corpus)
                    push!(submitted_programs,prepared.key)
                    last_job = :program
                end
            end
            if isnothing(prepared) && length(pairs) >= count_for_batch
                batch = pairs[1:count_for_batch]
                deleteat!(pairs,1:count_for_batch)
                prepared = prepare_effect_learning!(knowledge,config,rec.store,batch,repo_root)
                last_job = :effect
            end
            if !isnothing(prepared)
                job = (; kind=last_job, job=prepared.job, prepared)
                if background
                    inflight = job
                else
                    status = wait_worker(job.job,store_path(rec.store))
                    collect_online_job!(knowledge,config,rec,job,status,publications,program_jobs,completed_cohorts;
                        live_agenda=relations)
                end
            end
        end
    end
    if !isnothing(spatial) && !rec.frozen && !isnothing(rec.card_id)
        close_scorecard!(rec)
    end
    defer_tail = isnothing(rec.limit) && !frozen && rec.observation.state in ("WIN","GAME_OVER")
    if !isnothing(inflight) && (!defer_tail || isfile(joinpath(inflight.job,"worker-status.json")))
        status = wait_worker(inflight.job,store_path(rec.store))
        collect_online_job!(knowledge,config,rec,inflight,status,publications,program_jobs,completed_cohorts;
            live_agenda=relations)
    end
    final = defer_tail ? (;publications=String[],pending=summarize_learning!(rec.store)) :
        finalize_learning!(knowledge,config,rec.store,pairs,repo_root;frozen,inflight=nothing)
    append!(publications,final.publications)
    sequence = nothing
    if sequence_enabled && !defer_tail
        episodes = [sequence_events]
        corpus = compile_sequence_corpus(episodes;observations=knowledge.observations,close_revisits=true)
        artifact = store_path(rec.store,"learning","sequence-corpus.json")
        compiled = persist_sequence_corpus(episodes,artifact;corpus)
        tail = next_program_corpus(corpus,sequence_events,knowledge.observations,submitted_programs,completed_cohorts)
        if !rec.frozen && !isnothing(tail) && !isempty(tail.programs) && program_corpus_key(tail) ∉ submitted_programs
            searched = train_program_corpus!(knowledge,config,rec.store,repo_root,tail;available_after=rec.before_ref)
            push!(program_jobs,searched)
            haskey(searched,"publication") && push!(publications,searched["publication"])
        end
        cohorts = program_cohort_ledger(rec.store,corpus)
        atomic_json(store_path(rec.store,"learning","program-cohorts.json"),cohorts)
        sequence = merge(compiled,(search=isempty(program_jobs) ? nothing : last(program_jobs),jobs=program_jobs,
            unsubmitted_cohorts=cohorts["unsubmitted"]))
    end
    if defer_tail
        # Every source is already in the receipt ledger, so recovery can
        # rebuild the pending cohorts without extending a terminal game.
        atomic_json(store_path(rec.store,"learning","deferred-tail.json"),(;
            event=rec.before_ref,public_state=rec.observation.state,
            pending_events=final.pending,sequence_sources=sequence_enabled ?
                [item.event["event_id"] for item in sequence_events] : String[]))
    end
    after_version = frozen ? frozen_knowledge_digest(knowledge) : nothing
    after_version == frozen_version || error("Frozen evaluation changed the mechanism")
    if frozen
        current = read_published_stitch(store_path(rec.store,"publication"))
        (isnothing(current) ? nothing : current.publication) ==
            (isnothing(frozen_publication) ? nothing : frozen_publication.publication) ||
            error("Frozen evaluation changed the publication")
    end
    projection_scopes = frozen ? length(knowledge.projections.scopes) :
        persist_projection_scopes!(rec.store,knowledge.projections)
    outcome = (; actions=count, publications, state=rec.observation.state, models=length(knowledge.active),
        levels_completed=rec.observation.levels_completed, win_levels=rec.observation.win_levels,
        frozen_before=frozen_version, frozen_after=after_version, consumed_definition_depth=consumed_depth,
        pending_learning_events=final.pending,pending_program_jobs=pending_program_jobs(rec.store),
        projection_scopes,sequence)
    composing || return outcome
    truth = isnothing(goal) ? unknown_truth : goal_truth(goal,last(rec.observation.frames))
    return merge(outcome,(goal=truth == proven ? "observed" : truth == disproven ? "not_reached" : "unknown",))
end

function recover_learning!(store, config, repo_root)
    config.learning === nothing && error("The run does not have a learning policy")
    session = read_json(store_path(store,"learning","session.json"))
    sources = recover_run(store)
    prior = prior_trials(config)
    knowledge = OnlineKnowledge()
    append!(knowledge.trials,prior.trials)
    merge!(knowledge.observations,prior.observations)
    replay_effects!(knowledge.observations,[sources])
    pairs = copy(prior.pairs)
    previous = nothing
    history = Int[]
    for item in sources
        register_evidence_obligation!(store,item; frozen=session["frozen"])
        action = item.observation.action
        if action["id"] == 0
            empty!(history)
        elseif !session["frozen"]
            !isnothing(previous) && item.event["before_ref"] == previous.event["event_id"] ||
                error("Recovered action lacks its observed preconditions")
            push!(pairs,(previous,item))
            push!(knowledge.trials,PublicTrial(motion_example(previous,item;history),action,
                knowledge.observations[item.event["event_id"]]))
        end
        push!(history,action["id"])
        previous = item
    end
    jobs = learning_jobs(store)
    knowledge.learning_jobs = isempty(jobs) ? 0 : parse(Int,split(basename(last(jobs)),'-')[2])
    records = Dict(item.event["event_id"]=>item for item in sources)
    for (before,after) in prior.pairs
        records[before.event["event_id"]] = before
        records[after.event["event_id"]] = after
    end
    cutoff = isempty(sources) ? nothing : last(sources).event["event_id"]
    if session["frozen"] && isfile(store_path(store,"learning","evaluation-boundary.json"))
        recover_program_jobs!(knowledge,config,store,repo_root,records,cutoff;published_only=true)
        return (;pending=summarize_learning!(store),programs=pending_program_jobs(store))
    end
    replay_projection_feedback!(knowledge.projections,store_path(store),sources,
        knowledge.observations,mechanism_limits(config).history_lengths)
    persist_projection_scopes!(store,knowledge.projections)
    by_event = Dict(pair[2].event["event_id"]=>pair for pair in pairs)
    attempted = Set{String}()
    for job in jobs
        batch_path = joinpath(job,"batch.json")
        isfile(batch_path) && !isfile(joinpath(job,"assessment.json")) || continue
        batch = read_json(batch_path)
        input = joinpath(job,"input")
        if isdir(input) && !isfile(joinpath(input,"manifest.json"))
            learning_assessment!(job,batch,"input_interrupted")
            continue
        end
        ids = [row[2] for row in batch["inputs"]]
        online_learn!(knowledge,config,store,[by_event[id] for id in ids],repo_root; existing_job=job)
        union!(attempted,ids)
    end
    dispositions = learning_dispositions(store)
    outstanding = [pair for pair in pairs if let ref = pair[2].event["event_id"]
        ref ∉ attempted && !get(get(dispositions,ref,Dict()),"complete",false)
    end]
    for group in Iterators.partition(outstanding,config.learning["batch_confirmed_events"])
        online_learn!(knowledge,config,store,group,repo_root)
    end
    recover_program_jobs!(knowledge,config,store,repo_root,records,cutoff)
    deferred = store_path(store,"learning","deferred-tail.json")
    if isfile(deferred) && !session["frozen"]
        saved = read_json(deferred)
        refs = saved["sequence_sources"]
        if !isempty(refs)
            allunique(refs) && last(refs) == cutoff || error("Deferred sequence scope differs from raw receipts")
            events = [records[ref] for ref in refs]
            issorted([item.event["sequence"] for item in events]) ||
                error("Deferred sequence events are out of order")
            corpus = compile_sequence_corpus([events];observations=knowledge.observations,close_revisits=true)
            persist_sequence_corpus([events],store_path(store,"learning","sequence-corpus.json");corpus)
            submitted = Set{String}(keys(program_jobs_by_snapshot(store)))
            tail = next_program_corpus(corpus,events,knowledge.observations,submitted,Set{String}())
            if !isnothing(tail) && !isempty(tail.programs) && program_corpus_key(tail) ∉ submitted
                train_program_corpus!(knowledge,config,store,repo_root,tail;available_after=cutoff)
            end
            atomic_json(store_path(store,"learning","program-cohorts.json"),program_cohort_ledger(store,corpus))
        end
    end
    return (;pending=summarize_learning!(store),programs=pending_program_jobs(store))
end
