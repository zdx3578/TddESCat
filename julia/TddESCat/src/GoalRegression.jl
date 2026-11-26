const GOAL_REGRESSION_BODY = ("public-relationship-policy-v1","find_unsatisfied_relation",
    "bind_verified_producer","recheck_each_transition","continue_to_observed_goal")

function projection_history_width(feature)
    kind,value = feature
    kind == "history" && return value
    kind == "joint" && return maximum(projection_history_width,value;init=0)
    return 0
end

function goal_history_width(knowledge)
    width = maximum((atom isa HistorySuffix ? length(atom.actions) : atom isa RecentAction ? 1 : 0
        for model in knowledge.active for atom in model.condition.atoms);init=1)
    return maximum((projection_history_width(row.feature) for scope in values(knowledge.projections.scopes)
        for row in scope.conditions);init=width)
end

function goal_producer_needs(knowledge,goal,observation,history,coordinates,meters)
    view = public_action_candidates(observation,coordinates)
    facts = observed_goal_relations(goal,view.frame)
    needs = NamedTuple[]
    for model in knowledge.active
        isempty(model.condition.atoms) && continue
        for action in view.actions
            action["id"] == model.rule.action_id || continue
            base = evaluate_joint_rule(model.rule,view.frame,view.groups,view.enclosure,action;meters)
            base.truth == proven || continue
            gate = candidate_evaluation(model,view.frame,view.groups,view.enclosure,action,history;meters)
            gate.truth == proven && continue
            patch = projection_patch((;model,base.fragments),view.frame)
            isnothing(patch) && continue
            after = observed_goal_relations(goal,patch.frame)
            establishes = [key for key in keys(facts) if getproperty(facts,key) != proven &&
                getproperty(after,key) == proven]
            isempty(establishes) && continue
            reads = unique([model.rule.training_event;model.condition.support;model.counterexamples])
            push!(needs,(rule=model.rule.id,action,truth=gate.truth,establishes,
                conditions=predicate_record.(model.condition.atoms),
                effect=plan_channels(base.fragments),counterexamples=copy(model.counterexamples),reads))
        end
    end
    return needs
end

function program_establishes_goal(knowledge,goal,obs,history,cursor,coordinates,meters,limit,needs)
    initial = observed_goal_relations(goal,last(obs.frames))
    missing = [key for key in keys(initial) if getproperty(initial,key) != proven]
    width = goal_history_width(knowledge)
    tail = nothing
    certificate = nothing
    reopened = Set{Symbol}()
    function track_obligations(_,_,_,frame)
        facts = observed_goal_relations(goal,frame)
        union!(reopened,(key for key in keys(initial) if getproperty(initial,key) == proven &&
            getproperty(facts,key) != proven))
        return true
    end
    function reaches(index,frame,recent)
        facts = observed_goal_relations(goal,frame)
        fulfilled = [key for key in missing if getproperty(facts,key) == proven]
        enough = all(==(proven),facts)
        binding = (role_color=Int(goal.role_color),role_geometry=goal.role_geometry,marker=goal.marker,
            cue_color=goal.cue_color,distance=goal.pixel_distance)
        if enough
            certificate = (;body=GOAL_REGRESSION_BODY,initial,missing,established=fulfilled,actual=facts,
                binding,producer=nothing,reads=String[],reopened=sort!(collect(reopened)))
            return true
        end
        producer = nothing
        if !isempty(needs)
            view = public_action_candidates((frames=[frame],available_actions=obs.available_actions),coordinates)
            for need in needs
                active = only(model for model in knowledge.active if model.rule.id == need.rule)
                result = candidate_evaluation(active,frame,view.groups,view.enclosure,need.action,recent;meters)
                result.truth == proven || continue
                projection = projected_contract(knowledge.projections,(model=active,fragments=result.fragments),frame,recent)
                projection_allowed(projection) || continue
                successors = observed_goal_relations(goal,projection.frame)
                establishes = filter(key->getproperty(facts,key) != proven &&
                    getproperty(successors,key) == proven,need.establishes)
                isempty(establishes) && continue
                producer = (rule=need.rule,action=need.action,conditions=need.conditions,
                    establishes,reads=need.reads)
                break
            end
        end
        isempty(fulfilled) && isnothing(producer) && return false
        index < limit || return false
        view = (frames=[frame],available_actions=obs.available_actions,levels_completed=obs.levels_completed)
        remaining = search_observed_goal(knowledge,view,recent,goal,width,coordinates,"relation-tail";meters)
        isnothing(remaining.cursor) && return false
        trace = projected_trace(remaining.cursor)
        index + length(trace) <= limit || return false
        tail = trace
        reads = isnothing(producer) ? String[] : producer.reads
        certificate = (;body=GOAL_REGRESSION_BODY,initial,missing,established=fulfilled,actual=facts,
            binding,producer,reads,reopened=sort!(collect(reopened)))
        return true
    end
    path = forecast_program(knowledge,obs,history,cursor,coordinates,meters,
        track_obligations,reaches,limit)
    isnothing(path) && return nothing
    return (contract="establishes_goal_relation",target=goal.marker,role=nothing,path,
        continuation=tail,regression=certificate)
end

function choose_goal_experiment(goal,knowledge,observation,history,decision,coordinates,meters)
    needs = goal_producer_needs(knowledge,goal,observation,history,coordinates,meters)
    isempty(needs) && return nothing
    for item in decision.ranked
        item.rejected && continue
        relevant = filter(row->row.truth == unknown_truth && row.action == item.action,needs)
        isempty(relevant) && continue
        prediction = item.experiment
        if isnothing(prediction)
            # Two plausible outcomes of an unresolved gate. A counterexample is
            # required before spending a task action to distinguish the gate.
            witnessed = filter(row->!isempty(row.counterexamples) && !isnothing(row.effect),relevant)
            isempty(witnessed) && continue
            prediction = (hypotheses=[(rule=row.rule,if_applicable=row.effect,
                if_unproved="test_whether_relation_is_established",opposed_by=row.counterexamples)
                for row in witnessed],)
        end
        reads = unique([ref for row in relevant for ref in row.reads])
        return (item=merge(item,(reason="discriminate_goal_relation",)),
            note=Dict("operation"=>"discriminate_goal_relation","status"=>"experimental",
                "conditions"=>relevant,"event_reads"=>reads,"predictions"=>prediction))
    end
    return nothing
end

"""Record the verified contact producer and the preconditions its route is serving."""
function advancement_task(goal,control,spatial,observation,choice)
    (isnothing(goal) || isnothing(choice)) && return nothing
    contact = get(choice,:contact,nothing)
    isnothing(contact) && return nothing
    contact.progress.model == goal.model && contact.progress.judgment == :progress ||
        return nothing
    contact.conditions.judgment == :admitted || return nothing
    contact.point in goal.targets || return nothing
    continuation = control.continuation
    next_origin, next_action = if !isnothing(continuation)
        last(continuation.steps).from,last(continuation.steps).action
    elseif choice.executes_contact
        choice.role,choice.id
    else
        return nothing
    end
    delta, delta_reads = measured_offset(spatial,next_action)
    frame = last(observation.frames)
    current = visual_value(frame,control.field)
    signature = isnothing(current) ? nothing : contact_signature(current,contact.site.value)
    admission = isnothing(signature) ? :unknown :
        contact_judgment(fit_contact_guards(control.contact_samples),signature,goal.facts,next_action)
    requirements = [("approach_contact",choice.role == next_origin ? :proven : :missing),
        ("admissible_contact",admission == :admitted ? :proven : admission == :blocked ? :missing : :unknown)]
    producer = (relation=goal.relation,action=next_action,origin=next_origin,target=contact.point,
        displacement=delta,guard=contact.conditions.rules,advancement=contact.progress.rules,
        read_events=unique([first(delta_reads);contact.conditions.reads;contact.progress.reads]))
    reads = unique([goal.reads;producer.read_events;choice.reads])
    return (goal=learned_goal_record(goal),producer,requirements,
        intent=any(row->last(row) != :proven,requirements) ? :establish_preconditions : :apply_producer,
        recheck=choice.executes_contact,reads)
end

function advancement_feedback(task, before, after, sample)
    isnothing(task) && return nothing
    crossed = after.observation.levels_completed > before.observation.levels_completed
    bound_contact = !isnothing(sample) && sample.point == task.producer.target &&
        sample.action == task.producer.action
    outcome = if task.recheck && bound_contact
        crossed ? :established : sample.outcome
    elseif crossed || task.recheck
        :unresolved
    else
        :continue
    end
    return (;outcome,event=after.event["event_id"],observed=(
        advanced=crossed, won=after.observation.state == "WIN", contact=bound_contact))
end

function contact_goal_domain(control,spatial,obs)
    (isempty(spatial.role) || isnothing(control.field)) && return nothing
    fitted = fit_contact_guards(control.contact_samples)
    isempty(fitted.examples) && return nothing
    facts = contact_facts(control,obs.action["id"])
    isempty(facts.remaining) && return nothing
    floor = visual_floor(spatial)
    isnothing(floor) && return nothing
    progress = fit_progress_relations(control.contact_samples)
    actions = filter(id->haskey(spatial.offsets,id),obs.available_actions)
    return (;control,spatial,actions,facts,fitted,progress,floor)
end

function feasible_contact(domain,frame,previous,event;target=nothing)
    control,spatial = domain.control,domain.spatial
    here = locate_role(frame,spatial.role)
    signal = visual_value(frame,control.field)
    (isnothing(here) || isnothing(signal)) && return nothing
    if !isnothing(control.resource)
        reading = read_meter(frame,control.resource)
        (isnothing(reading) || reading <= 0) && return nothing
    end
    candidates = NamedTuple[]
    facts = ContactFacts(domain.facts.remaining,previous,domain.facts.domain_reads)
    points = first.(facts.remaining)
    for action in domain.actions
        delta,range_reads = measured_offset(spatial,action)
        edge = projected_motion(control,spatial,frame,here,action,delta,here,domain.floor,points;
            current=true,previous_action=previous)
        (isnothing(edge) || edge.point ∉ points) && continue
        !isnothing(target) && (target.point != edge.point || target.action != action) && continue
        point = edge.point
        site = control.targets[point]
        visual_value(frame,site.field) == site.value || continue
        signature = contact_signature(signal,site.value)
        conditions = contact_conditions(domain.fitted,signature,facts,action)
        conditions.judgment == :admitted || continue
        progress = progress_conditions(domain.progress,facts,action)
        if !isnothing(domain.progress.model) && progress.judgment == :unknown
            continue
        end
        plan = (point,site,context=signal,field=control.field,conditions,progress,selected_at=event)
        reads = unique([spatial.role_reads;first(range_reads);edge.reads;site.event;conditions.reads;progress.reads])
        rank = progress.judgment == :progress ? 0 : 1
        push!(candidates,(;here,action,point,plan,reads,rank))
    end
    isempty(candidates) && return nothing
    return first(sort!(candidates;by=row->(row.rank,row.point,row.action)))
end

function program_prepares_contact(knowledge,domain,obs,history,cursor,coordinates,meters,limit,event,baseline)
    limit > 1 || return nothing
    isnothing(feasible_contact(domain,last(obs.frames),last(history),event)) || return nothing
    required = nothing
    function preserves_domain(_,_,_,frame)
        point = locate_role(frame,domain.spatial.role)
        isnothing(point) && return false
        return all(point != site_point && visual_value(frame,site.field) == site.value
            for (site_point,site) in domain.facts.remaining)
    end
    function reaches(_,frame,recent)
        candidate = feasible_contact(domain,frame,last(recent),event)
        isnothing(candidate) && return false
        !isnothing(baseline) && baseline.progress.judgment == :progress && candidate.rank != 0 && return false
        required = candidate
        return true
    end
    path = forecast_program(knowledge,obs,history,cursor,coordinates,meters,
        preserves_domain,reaches,limit-1)
    isnothing(path) && return nothing
    target = (point=required.point,action=required.action,scope=CONTACT_DOMAIN,origin=required.here)
    return (contract="establishes_contact_precondition",target=required.here,role=copy(domain.spatial.role),
        path,continuation=nothing,regression=(body=GOAL_REGRESSION_BODY,established=["admissible_contact_binding"],
            binding=target,contact=required.plan,reads=required.reads),contact_target=target)
end

function planned_contact_step(scope,target,obs,event)
    isnothing(scope) && return nothing
    current = feasible_contact(scope,last(obs.frames),obs.action["id"],event;target)
    isnothing(current) && return nothing
    return (id=current.action,reason="learned_visual_contact",reads=current.reads,role=current.here,
        destination=current.point,frontier=current.point,expected=nothing,
        contact=current.plan,executes_contact=true,effect_gain=0)
end
