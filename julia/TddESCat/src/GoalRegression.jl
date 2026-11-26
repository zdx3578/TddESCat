const GOAL_REGRESSION_BODY = ("public-relationship-policy-v1","find_unsatisfied_relation",
    "bind_verified_producer","recheck_each_transition","continue_to_observed_goal")

function goal_history_width(knowledge)
    width = maximum((atom isa HistorySuffix ? length(atom.actions) : atom isa RecentAction ? 1 : 0
        for model in knowledge.active for atom in model.condition.atoms);init=1)
    return maximum((last(row.feature) for scope in values(knowledge.projections.scopes)
        for row in scope.conditions if first(row.feature) == "history");init=width)
end

function goal_producer_needs(knowledge,goal,observation,history,coordinates,meters)
    view = public_action_candidates(observation,coordinates)
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
            goal_truth(goal,patch.frame) == proven || continue
            reads = unique([model.rule.training_event;model.condition.support;model.counterexamples])
            push!(needs,(rule=model.rule.id,action,truth=gate.truth,
                conditions=predicate_record.(model.condition.atoms),reads))
        end
    end
    return needs
end

function program_establishes_goal(knowledge,goal,obs,history,cursor,coordinates,meters,limit,needs)
    initial = observed_goal_relations(goal,last(obs.frames))
    missing = [key for key in keys(initial) if getproperty(initial,key) == disproven]
    all(!=(unknown_truth),initial) || return nothing
    width = goal_history_width(knowledge)
    tail = nothing
    certificate = nothing
    function preserves(_,_,_,frame)
        facts = observed_goal_relations(goal,frame)
        return all(key->getproperty(initial,key) != proven || getproperty(facts,key) == proven,keys(initial))
    end
    function reaches(index,frame,recent)
        facts = observed_goal_relations(goal,frame)
        fulfilled = [key for key in missing if getproperty(facts,key) == proven]
        enough = all(==(proven),facts)
        binding = (role_color=Int(goal.role_color),role_geometry=goal.role_geometry,marker=goal.marker,
            cue_color=goal.cue_color,distance=goal.pixel_distance)
        if enough
            certificate = (;body=GOAL_REGRESSION_BODY,initial,missing,established=fulfilled,actual=facts,
                binding,producer=nothing,reads=String[])
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
                projection_allowed(projection) && goal_truth(goal,projection.frame) == proven || continue
                producer = (rule=need.rule,action=need.action,conditions=need.conditions,reads=need.reads)
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
            binding,producer,reads)
        return true
    end
    path = forecast_program(knowledge,obs,history,cursor,coordinates,meters,
        preserves,reaches,limit)
    isnothing(path) && return nothing
    return (contract="establishes_goal_relation",target=goal.marker,role=nothing,path,
        continuation=tail,regression=certificate)
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
        (isnothing(reading) || reading < max(1,control.rate)) && return nothing
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
