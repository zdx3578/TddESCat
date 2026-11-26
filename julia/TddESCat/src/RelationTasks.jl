const PublicActionKey = Tuple{Int,Int,Int}

"""Index confirmed transfers, including those with no identified public effect."""
struct RelationSample
    effects::PublicEffects
    level::Int
    attempt::Int
    context::String
    next_context::String
    preceding::Int
    state::String
    advanced::Bool
    unchanged::Bool
    available::Vector{Int}
    binding::Union{Nothing,NamedTuple}
    dependency::Union{Nothing,String}
    contact::Union{Nothing,ContactSample}
    site_changes::Vector{NamedTuple}
end

mutable struct RelationProducer
    rule::JointMechanism
    relations::Vector{String}
    support::Vector{Int}
    refuted::Vector{Int}
end

mutable struct RelationAgenda
    samples::Vector{RelationSample}
    producers::Dict{String,RelationProducer}
    by_action::Dict{String,Vector{String}}
    by_relation::Dict{String,Vector{String}}
    lineages::Dict{MotionShape,String}
    produced_at::Dict{String,Vector{Int}}
    relation_replays::Set{Tuple{String,PublicActionKey,PublicActionKey}}
    visits::Dict{Tuple{String,PublicActionKey},Vector{Int}}
    pairs::Set{Tuple{String,PublicActionKey,PublicActionKey}}
    failures::Dict{Tuple{String,PublicActionKey,PublicActionKey},Int}
    reopened::Set{Tuple{String,PublicActionKey,PublicActionKey}}
    delayed::Dict{String,Vector{Tuple{Int,String}}}
    preparations::Set{Tuple{Int,String,Int}}
    attempt::Int
    start::Int
    previous::Int
    restart::Union{Nothing,NamedTuple}
    preparing::Union{Nothing,NamedTuple}
end

RelationAgenda() = RelationAgenda(RelationSample[],Dict(),Dict(),Dict(),Dict(),Dict(),Set(),Dict(),Set(),Dict(),Set(),
    Dict(),Set(),1,1,0,nothing,nothing)

relation_context(obs) = semantic_hash([obs.levels_completed,size(last(obs.frames)),
    content_hash(vec(last(obs.frames))),sort(obs.available_actions)])

relation_ref(row::RelationSample) = row.effects.event_id
relation_refs(row::RelationSample) = [row.effects.before_id,relation_ref(row)]
previous_key(agenda,index) = index == 0 ? (0,-1,-1) : action_key(agenda.samples[index].effects.action)
click_profile(support,point) = semantic_hash([6,shape_template(support),Tuple(relative_click(point,support))])
primitive_profile(id) = string(id)

function effect_relation(family,prototype,values)
    return string(family) * "-" * semantic_hash([prototype,values])
end

function producer_relations(rule)
    return [effect_relation(model.family,
        isnothing(model.measurement) ? model.template : meter_pattern(model.measurement),
        model.family == :selection ? Tuple(relative_click(model.values,rule.click.support)) : model.values)
        for model in rule.effects]
end

function observed_producer!(agenda,sample,before,after)
    output = sample.effects
    (sample.advanced || isempty(output.effects) || !output.complete) && return nothing
    rule = observed_joint_model(output,before,after)
    action = rule.action_id
    action == 6 && isnothing(rule.click) && return nothing
    relations = producer_relations(rule)
    scope = rule.click
    profile = action == 6 ? click_profile(scope.support,scope.point) : primitive_profile(action)
    origin = isnothing(scope) ? (0,0) : anchor(scope.support)
    visibility = [[(x-origin[1],y-origin[2],c) for (x,y,c) in model.visibility] for model in rule.effects]
    guards = isnothing(scope) ? [model.position for model in rule.effects] :
        relative_effect_roles(scope) ? scope.offsets : [origin]
    key = semantic_hash([profile,relations,guards,visibility,rule.spacing,rule.entry_colors,
        isnothing(rule.patch) ? nothing : (rule.patch.moving,rule.patch.fixed)])
    producer = get!(agenda.producers,key) do
        push!(get!(Vector{String},agenda.by_action,profile),key)
        for relation in unique(relations)
            push!(get!(Vector{String},agenda.by_relation,relation),key)
        end
        RelationProducer(rule,relations,Int[],Int[])
    end
    push!(producer.support,length(agenda.samples))
    sample.state == "NOT_FINISHED" &&
        push!(get!(Vector{Int},agenda.produced_at,sample.context),length(agenda.samples))
    return (;key,relations)
end

function relation_checks(proposal,after,effects)
    isnothing(proposal) && return nothing
    results = NamedTuple[]
    for test in proposal.tests
        verdict = measure_joint((model=test.rule,fragments=test.fragments),after)
        # A uniquely observed different displacement refutes the prediction even
        # when a screen full of identical supports defeats post-state matching.
        for part in test.fragments
            part.family == :translation || continue
            changes = filter(effect->effect.family == :translation && effect.before == part.basis,effects.effects)
            length(changes) == 1 || continue
            key = scope_key(part)
            actual = Tuple(only(changes).values)
            verdict.actual[key] = actual
            verdict.assessments[key] = actual == part.expected ? "supported" : "refuted"
        end
        status = "refuted" in values(verdict.assessments) ? :refuted :
            all(==("supported"),values(verdict.assessments)) ? :established : :unresolved
        push!(results,(producer=test.key,scope=test.scope,status,expected=test.expected,
            actual=verdict.actual,judgments=verdict.assessments))
    end
    result = if !isempty(results)
        any(row->row.status == :established,results) ? :established :
            all(row->row.status == :refuted,results) ? :refuted : :unresolved
    elseif effects.complete && !isempty(effects.effects)
        :observed
    else
        :unresolved
    end
    return (;intent=proposal.intent,result,tests=results)
end

function observe_relations!(agenda,before,after,effects,contact,site_changes,proposal;groups=nothing)
    prev,next = before.observation,after.observation
    advanced = next.levels_completed > prev.levels_completed
    nothing_visible = same_intervention_context(prev,next) && all(==(last(prev.frames)),next.frames)
    binding = if effects.action["id"] == 6
        point = action_key(effects.action)[2:3]
        support = point_component(isnothing(groups) ? public_components(last(prev.frames)) : groups,point)
        if !isnothing(support)
            lineage = get!(() -> effects.before_id * "-" * join(point,"-"),agenda.lineages,support)
            (;lineage,point,appearance=click_profile(support,point))
        end
    end
    prior = agenda.previous == 0 ? nothing : agenda.samples[agenda.previous]
    dependency = !isnothing(prior) && !isnothing(proposal) &&
        proposal.intent in (:distinguish_changed_context,:test_delayed_effect,:complete_preparation) ?
        relation_ref(prior) : nothing
    sample = RelationSample(effects,prev.levels_completed,agenda.attempt,relation_context(prev),
        relation_context(next),agenda.previous,next.state,advanced,nothing_visible,prev.available_actions,
        binding,dependency,contact,site_changes)
    push!(agenda.samples,sample)
    index = length(agenda.samples)
    action = action_key(effects.action)
    previous = previous_key(agenda,sample.preceding)
    push!(get!(Vector{Int},agenda.visits,(sample.context,action)),index)
    if sample.preceding != 0 && agenda.samples[sample.preceding].unchanged
        push!(agenda.pairs,(sample.context,previous,action))
    end
    feedback = relation_checks(proposal,last(next.frames),effects)
    if !isnothing(feedback)
        for row in feedback.tests
            row.status == :refuted && push!(agenda.producers[row.producer].refuted,index)
        end
    end
    contract = observed_producer!(agenda,sample,last(prev.frames),last(next.frames))
    if !isnothing(contract) && !isnothing(prior) && prior.unchanged && next.state == "NOT_FINISHED"
        contrasted = any(get(agenda.visits,(sample.context,action),Int[])) do at
            row = agenda.samples[at]
            row.unchanged && previous_key(agenda,row.preceding) != previous
        end
        if contrasted
            push!(get!(Vector{Tuple{Int,String}},agenda.delayed,prior.context),(index,contract.key))
        end
    end
    if advanced
        empty!(agenda.lineages)
    else
        links = [(effect.before,effect.after,agenda.lineages[effect.before]) for effect in effects.effects
            if effects.complete && effect.family in (:translation,:pigment) && haskey(agenda.lineages,effect.before)]
        for (source,_,_) in links
            delete!(agenda.lineages,source)
        end
        for (_,target,lineage) in links
            agenda.lineages[target] = lineage
        end
    end
    failure = if next.state == "GAME_OVER"
        scope = (sample.context,previous,action)
        novel = !haskey(agenda.failures,scope)
        agenda.failures[scope] = index
        (;scope,novel,context=sample.context,history=relation_ref.(agenda.samples[agenda.start:end]),
            attribution=:unresolved)
    end
    agenda.previous = advanced ? 0 : index
    unresolved = copy(effects.alternatives)
    isempty(effects.residual) || push!(unresolved,"unexplained_pixel_changes")
    nothing_visible && push!(unresolved,"possible_delayed_effect")
    return (;event=effects.event_id,before=effects.before_id,context=sample.context,after=sample.next_context,
        attempt=sample.attempt,prior=sample.preceding == 0 ? nothing : relation_ref(agenda.samples[sample.preceding]),
        reached=(;advanced,state=next.state),binding,contact=isnothing(contact) ? nothing : contact.event,
        site_transitions=[row.observed for row in site_changes],producer=contract,feedback,failure,unresolved)
end

function verified_instance(agenda,producer,context,action,previous,level)
    exact(index) = begin
        row = agenda.samples[index]
        row.context == context && action_key(row.effects.action) == action &&
            previous_key(agenda,row.preceding) == previous
    end
    any(exact,producer.refuted) && return :counterexample
    clashes = any(get(agenda.visits,(context,action),Int[])) do index
        exact(index) && agenda.samples[index].unchanged
    end
    clashes && return :counterexample
    any(exact,producer.support) && return :bound
    # Both local effects and disagreement remain in the same index.
    # Evidence for visual transfer excludes terminal outcomes.
    witnesses = [row.binding for index in producer.support for row in (agenda.samples[index],)
        if row.level == level && row.state == "NOT_FINISHED" && !isnothing(row.binding)]
    contradicted = any(index->agenda.samples[index].level == level,producer.refuted)
    if action[1] != 6
        contexts = Set(row.context for index in producer.support for row in (agenda.samples[index],)
            if row.level == level && row.state == "NOT_FINISHED" && previous_key(agenda,row.preceding)[1] == previous[1])
        return length(contexts) >= 2 && !contradicted ? :replicated : :unverified
    end
    return length(unique(row.point for row in witnesses)) >= 2 &&
        length(unique(row.lineage for row in witnesses)) >= 2 && !contradicted ? :replicated : :unverified
end

function prepare_relation_tests(agenda,context,obs,groups,action;meters=())
    point = action_key(action)
    role = action["id"] == 6 ? point_component(groups,point[2:3]) : nothing
    action["id"] == 6 && isnothing(role) && return NamedTuple[]
    profile = isnothing(role) ? primitive_profile(action["id"]) : click_profile(role,point[2:3])
    ids = get(agenda.by_action,profile,String[])
    isempty(ids) && return NamedTuple[]
    frame = last(obs.frames)
    enclosure = enclosure_pairs(groups)
    previous = previous_key(agenda,agenda.previous)
    tests = NamedTuple[]
    for key in ids
        producer = agenda.producers[key]
        scope = verified_instance(agenda,producer,context,point,previous,obs.levels_completed)
        scope == :counterexample && continue
        # Unrestricted matches of a deterministic relative footprint are still
        # experiments until there are concrete outcomes at multiple bindings.
        rule = producer.rule
        eval = evaluate_joint_rule(rule,frame,groups,enclosure,action;meters,relative_transfer=true)
        eval.truth == proven || continue
        expected = plan_channels(eval.fragments)
        isnothing(expected) && continue
        if scope != :bound && (isnothing(rule.click) ? scope == :replicated : !rule.click.local_pigment)
            guard = (complete=true,)
            projected = projection_patch((model=(;rule,condition=guard),fragments=eval.fragments),frame)
            isnothing(projected) && continue
        end
        reads = unique([ref for index in [producer.support;producer.refuted]
            for ref in relation_refs(agenda.samples[index])])
        push!(tests,(;key,rule,scope,expected,eval.fragments,reads,relations=producer.relations))
    end
    if any(test->test.scope == :bound,tests)
        filter!(test->test.scope == :bound,tests)
    end
    return tests
end

function relation_experiment(agenda,obs,decision,intervention,context;meters=())
    previous = agenda.previous
    prior = previous == 0 ? nothing : agenda.samples[previous]
    if !isnothing(agenda.restart)
        failure = agenda.restart
        rows = [row for row in decision.ranked if action_key(row.action) != failure.first]
        if isempty(rows) && !isnothing(intervention) && action_key(intervention.action) != failure.first
            push!(rows,(action=intervention.action,rank=(0,0)))
        end
        if !isempty(rows)
            row = argmin(row->(length(get(agenda.visits,(context,action_key(row.action)),Int[])),row.rank),rows)
            return (;action=row.action,intent=:revise_failed_trace,tests=NamedTuple[],
                reads=[failure.event],obligation=failure)
        end
    end
    if !isnothing(agenda.preparing)
        plan = agenda.preparing
        if !isnothing(prior) && prior.unchanged && context == plan.context &&
                prior.effects.action == plan.first && plan.next["id"] in obs.available_actions
            tests = prepare_relation_tests(agenda,context,obs,decision.groups,plan.next;meters)
            if any(test->test.key == plan.producer && test.scope == :bound,tests)
                return (;action=plan.next,intent=:complete_preparation,tests,reads=plan.reads,obligation=plan)
            end
        end
    end
    for (index,producer) in get(agenda.delayed,context,Tuple{Int,String}[])
        row = agenda.samples[index]
        prefix = agenda.samples[row.preceding]
        key = (agenda.attempt,context,index)
        key in agenda.preparations && continue
        prefix.effects.action["id"] in obs.available_actions && row.effects.action["id"] in obs.available_actions ||
            continue
        sought = agenda.producers[producer].relations
        all(producer in agenda.by_relation[relation] for relation in sought) || continue
        reads = unique([relation_refs(prefix);relation_refs(row)])
        obligation = (;context,first=prefix.effects.action,next=row.effects.action,producer,sought,reads,index)
        return (;action=prefix.effects.action,intent=:establish_preparation,tests=NamedTuple[],
            reads,obligation)
    end
    sought = observed_relation_task(agenda,obs,decision,context;meters)
    isnothing(sought) || return sought
    if !isnothing(prior) && prior.unchanged
        first_action = action_key(prior.effects.action)
        rows = filter(decision.ranked) do row
            key = action_key(row.action)
            (context,first_action,key) ∉ agenda.pairs
        end
        if !isempty(rows)
            row = argmin(row->(row.action["id"] == 6,
                !isnothing(intervention) && row.action != intervention.action,
                length(get(agenda.visits,(context,action_key(row.action)),Int[])),
                row.rank),rows)
            tests = prepare_relation_tests(agenda,context,obs,decision.groups,row.action;meters)
            return (;action=row.action,intent=:test_delayed_effect,tests,
                reads=relation_refs(prior),obligation=(prefix=relation_ref(prior),action=prior.effects.action))
        end
    end
    isnothing(intervention) && return nothing
    action = intervention.action
    tests = prepare_relation_tests(agenda,context,obs,decision.groups,action;meters)
    if hasproperty(intervention,:changed_context)
        return (;action,intent=:distinguish_changed_context,tests,reads=intervention.changed_context.reads,
            obligation=intervention.changed_context)
    end
    isempty(tests) && return nothing
    return (;action,intent=:test_concrete_effect,tests,reads=String[],obligation=nothing)
end

function observed_relation_task(agenda,obs,decision,context;meters)
    previous = previous_key(agenda,agenda.previous)
    examined = Set{PublicActionKey}()
    candidates = NamedTuple[]
    for index in Iterators.reverse(get(agenda.produced_at,context,Int[]))
        row = agenda.samples[index]
        action = row.effects.action
        key = action_key(action)
        key in examined && continue
        push!(examined,key)
        route = (context,previous,key)
        (route in agenda.relation_replays || haskey(agenda.failures,route)) && continue
        action["id"] in obs.available_actions || continue
        tests = prepare_relation_tests(agenda,context,obs,decision.groups,action;meters)
        isempty(tests) && continue
        all(test->test.expected == first(tests).expected,tests) || continue
        priority = any(test->test.scope in (:bound,:replicated),tests) ? 0 : 1
        obligation = (;route,prior=relation_ref(row))
        push!(candidates,(;action,intent=:establish_observed_relation,tests,reads=relation_refs(row),
            obligation,priority))
    end
    return isempty(candidates) ? nothing : argmin(row->row.priority,candidates)
end

"""Compare legal dispatches once. A grounded continuation survives speculative exploration."""
function task_arbitration(item,spatial,intervention,relation,experiment;
                          program,continuing_contact,conditional,object_probes,policy=nothing,
                          continuing_policy=false)
    candidates = NamedTuple[]
    add(source,action,reason,priority) = push!(candidates,(;source,action,reason,priority))
    add(program ? :program : :base,item.action,item.reason,program ? 0 : conditional ? 1 : 8)
    if !isnothing(spatial)
        contact = get(spatial,:contact,nothing)
        grounded = continuing_contact || !isnothing(contact) && contact.conditions.judgment == :admitted ||
            get(spatial,:effect_gain,0) > 0
        add(:spatial,Dict("id"=>spatial.id),spatial.reason,grounded ? 1 : object_probes ? 7 : 4)
    end
    if !isnothing(intervention)
        add(:intervention,intervention.action,intervention.reason,isnothing(intervention.goal) ? 6 : 2)
    end
    if !isnothing(relation)
        priority = relation.intent in (:revise_failed_trace,:complete_preparation) ? 1 :
            relation.intent in (:test_concrete_effect,:distinguish_changed_context,:test_delayed_effect,
                :establish_preparation,:establish_observed_relation) ? 3 : 5
        reason = !isnothing(intervention) && relation.action == intervention.action &&
            relation.intent in (:test_concrete_effect,:test_delayed_effect) ?
            intervention.reason : string(relation.intent)
        add(:relation,relation.action,reason,priority)
    end
    isnothing(experiment) || add(:experiment,experiment.action,"distinguish_public_experiment",7)
    baseline = argmin(row->row.priority,candidates)
    isnothing(policy) || add(:relation_policy,policy.action,"execute_relation_policy",continuing_policy ? 0 : 1)
    return (choice=argmin(row->row.priority,candidates),baseline,candidates)
end

function changed_context_probe(agenda,obs,scene)
    agenda.previous == 0 && return nothing
    latest = agenda.samples[agenda.previous]
    latest.context == latest.next_context && return nothing
    for candidate in scene
        action = click_action(candidate.point)
        key = action_key(action)
        haskey(agenda.visits,(latest.next_context,key)) && continue
        original = get(agenda.visits,(latest.context,key),Int[])
        isempty(original) && continue
        earlier = agenda.samples[last(original)]
        earlier.unchanged || continue
        !isnothing(earlier.binding) && earlier.binding.appearance == click_profile(candidate.support,candidate.point) ||
            continue
        # The binding survived. The scene changed elsewhere, so the earlier
        # observation is insufficient to decide this case.
        obligation = (;reads=unique([relation_refs(earlier);relation_refs(latest)]),
            prior=relation_ref(earlier),previous_context=latest.context,context=latest.next_context)
        return (;action,probe=:representative,candidate,goal=nothing,fallback=nothing,
            changed_context=obligation,reason="distinguish_changed_object_context")
    end
    return nothing
end

"""Dispatch a rebound role only through the producer that will check the actual receipt."""
function object_effect_followup(agenda::RelationAgenda,level,candidates)
    options = NamedTuple[]
    for candidate in candidates
        profile = click_profile(candidate.support,candidate.point)
        if !haskey(agenda.by_action,profile)
            continue
        end
        for key in agenda.by_action[profile]
            producer = agenda.producers[key]
            witnesses = [agenda.samples[index] for index in producer.support if agenda.samples[index].level == level]
            isempty(witnesses) && continue
            x,y = action_key(last(witnesses).effects.action)[2:3]
            distance = sum(abs,candidate.point .- (x,y))
            push!(options,(;candidate,distance,witnesses=length(witnesses)))
        end
    end
    return isempty(options) ? nothing : argmin(row->(haskey(agenda.lineages,row.candidate.support),
        -row.witnesses,row.distance,row.candidate.point),options).candidate
end

function relation_task_record(proposal)
    reads = sort!(unique([proposal.reads;[ref for test in proposal.tests for ref in test.reads]]))
    contracts = [(producer=test.key,scope=test.scope,relations=test.relations,expected=test.expected,
        roles=[(family=part.family,port=program_input(part)) for part in test.fragments],reads=test.reads)
        for test in proposal.tests]
    return (;intent=proposal.intent,action=proposal.action,reads,contracts,obligation=proposal.obligation)
end

function relation_prediction(rec,item,prediction,task)
    isempty(task.reads) && return prediction
    reads = sort!(unique([rec.before_ref;task.reads]))
    admitted = length(task.contracts) == 1 && only(task.contracts).scope in (:bound,:replicated)
    values = Dict{String,Any}()
    if admitted
        for (channel,value) in only(task.contracts).expected
            values["relation-" * channel] = value
        end
    end
    if isnothing(prediction)
        return (before_ref=rec.before_ref,payload=Dict{String,Any}(
            "model_version"=>length(task.contracts) == 1 ? "relation-" * only(task.contracts).producer : nothing,
            "binding"=>[],"action"=>item.action,"guard_truth"=>admitted ? true : "unknown",
            "query_scope"=>sort!(collect(keys(values))),"predicted_values"=>values,
            "event_reads"=>reads,"enumeration_complete"=>false,"assumptions"=>[string(task.intent)]))
    end
    append!(prediction.payload["event_reads"],reads)
    unique!(prediction.payload["event_reads"])
    merge!(prediction.payload["predicted_values"],values)
    prediction.payload["query_scope"] = sort!(collect(keys(prediction.payload["predicted_values"])))
    return prediction
end

function failure_retry!(agenda)
    isempty(agenda.samples) && return nothing
    length(agenda.samples) >= agenda.start || return nothing
    ending = last(agenda.samples)
    ending.state == "GAME_OVER" || return nothing
    scope = (ending.context,previous_key(agenda,ending.preceding),action_key(ending.effects.action))
    scope in agenda.reopened && return nothing
    first_sample = agenda.samples[agenda.start]
    # RESET has its own public route. Replay the failed prefix only when
    # there is a different experiment to try on the new public instance.
    first_action = action_key(first_sample.effects.action)
    length(first_sample.available) > 1 || 6 in first_sample.available || return nothing
    push!(agenda.reopened,scope)
    return (;event=relation_ref(ending),initial=first_sample.context,first=first_action,
        level=first_sample.level,attempt=agenda.attempt,attribution=:unresolved)
end

function begin_relation_attempt!(agenda,restart)
    agenda.attempt += 1
    agenda.start = length(agenda.samples)+1
    agenda.previous = 0
    agenda.restart = restart
    agenda.preparing = nothing
    empty!(agenda.lineages)
end

function finish_relation_dispatch!(agenda,proposal)
    agenda.restart = nothing
    agenda.preparing = nothing
    isnothing(proposal) && return
    if proposal.intent == :establish_preparation
        plan = proposal.obligation
        push!(agenda.preparations,(agenda.attempt,plan.context,plan.index))
        agenda.preparing = plan
    elseif proposal.intent == :establish_observed_relation
        push!(agenda.relation_replays,proposal.obligation.route)
    end
end
