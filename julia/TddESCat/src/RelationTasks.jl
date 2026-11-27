"""Index confirmed transfers, including those with no identified public effect."""
struct RelationSample
    effects::PublicEffects
    level::Int
    attempt::Int
    context::String
    next_context::String
    receipt::String
    preceding::Int
    history_depth::Int
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

struct OutcomeRelationWitness
    steps::Vector{Pair{Int,String}}
    comparison::Int
    outcome::Int
end

mutable struct RelationAgenda
    samples::Vector{RelationSample}
    producers::Dict{String,RelationProducer}
    by_action::Dict{String,Vector{String}}
    by_relation::Dict{String,Vector{String}}
    lineages::Dict{MotionShape,String}
    produced_at::Dict{String,Vector{Int}}
    relation_replays::Set{Tuple{String,Tuple,PublicActionKey}}
    visits::Dict{Tuple{String,PublicActionKey},Vector{Int}}
    context_comparisons::Dict{Tuple{Int,PublicActionKey,String},Vector{Int}}
    checked_effects::Set{Tuple}
    pairs::Set{Tuple{String,PublicActionKey,PublicActionKey}}
    failures::Dict{Tuple{String,PublicActionKey,PublicActionKey},Int}
    reopened::Set{Tuple{String,PublicActionKey,PublicActionKey}}
    delayed::Dict{String,Vector{Tuple{Int,String}}}
    advancement::Dict{Tuple{Int,Int},Vector{Int}}
    advancement_roles::Dict{Int,Tuple}
    advancement_counterexamples::Dict{NamedTuple,Int}
    preparation_roles::Dict{Int,Tuple}
    outcomes::Vector{NamedTuple}
    outcome_relations::Vector{OutcomeRelationWitness}
    history_scopes::Dict{String,RelationHistoryScope}
    preparations::Set{Tuple{Int,String,Int}}
    attempt::Int
    start::Int
    previous::Int
    restart::Union{Nothing,NamedTuple}
    preparing::Union{Nothing,NamedTuple}
end

RelationAgenda() = RelationAgenda(RelationSample[],Dict(),Dict(),Dict(),Dict(),Dict(),Set(),Dict(),Dict(),Set(),Set(),Dict(),Set(),
    Dict(),Dict(),Dict(),Dict(),Dict(),NamedTuple[],OutcomeRelationWitness[],Dict(),Set(),1,1,0,nothing,nothing)

relation_context(obs) = semantic_hash([obs.levels_completed,size(last(obs.frames)),
    content_hash(vec(last(obs.frames))),sort(obs.available_actions)])

function relation_receipt(obs,context)
    frames = [(size(frame),content_hash(vec(frame))) for frame in @view(obs.frames[1:end-1])]
    return semantic_hash([context,frames])
end

relation_ref(row::RelationSample) = row.effects.event_id
relation_refs(row::RelationSample) = [row.effects.before_id,relation_ref(row)]
previous_key(agenda,index) = index == 0 ? (0,-1,-1) : action_key(agenda.samples[index].effects.action)
click_profile(support,point) = semantic_hash([6,shape_template(support),Tuple(relative_click(point,support))])
primitive_profile(id) = string(id)

function effect_experiment_scope(level,action,history,test)
    conditions = Tuple(sort!(unique([model.version for model in get(test,:conditions,NamedTuple[])])))
    return (level,action,history,test.key,conditions,String(canonical_bytes(test.expected)))
end

function observed_failure(agenda,context,action,previous)
    !refined_history(history_scope(agenda,context)) &&
        return haskey(agenda.failures,(context,previous_key(agenda,previous),action))
    current = relation_history_key(agenda,context,previous)
    return any(get(agenda.visits,(context,action),Int[])) do index
        row = agenda.samples[index]
        row.state == "GAME_OVER" && relation_history_key(agenda,context,row.preceding) == current
    end
end

function visible_role_multiset(groups)
    total = sum(length,groups;init=0)
    return Tuple(sort!([semantic_hash(shape_template(group)) for group in groups if 4length(group) <= total]))
end

function witnessed_outcome_requirements(agenda,index)
    requirements = NamedTuple[]
    while true
        row = agenda.samples[index]
        row.preceding == 0 && break
        prior = agenda.samples[row.preceding]
        action = row.effects.action["id"]
        delta = get(prior.effects.public_delta,"available_actions",nothing)
        same_scope = prior.attempt == row.attempt && prior.level == row.level && prior.next_context == row.context
        same_scope && !isnothing(delta) && action ∉ delta["before"] && action in delta["after"] || break
        index = row.preceding
        push!(requirements,(;index,event=relation_ref(prior),action,relation="available_action"))
    end
    return reverse!(requirements)
end

function witnessed_outcome_relation(agenda,index)
    outcome = agenda.samples[index]
    action = action_key(outcome.effects.action)
    first(action) == 6 && isnothing(outcome.binding) && return nothing
    steps = Pair{Int,String}[]
    current = outcome
    available = Set(outcome.available)
    while current.preceding != 0
        at = current.preceding
        preparation = agenda.samples[at]
        preparation.state == "NOT_FINISHED" && !preparation.advanced &&
            preparation.attempt == outcome.attempt && preparation.level == outcome.level &&
            preparation.next_context == current.context && Set(preparation.available) == available &&
            preparation.effects.complete && isempty(preparation.effects.residual) || break
        profile = isnothing(preparation.binding) ? primitive_profile(preparation.effects.action["id"]) :
            preparation.binding.appearance
        keys = get(agenda.by_action,profile,String[])
        producer = findfirst(key->at in agenda.producers[key].support,keys)
        isnothing(producer) && break
        push!(steps,at=>keys[producer])
        comparisons = get(agenda.visits,(preparation.context,action),Int[])
        comparison = findlast(comparisons) do compared
            row = agenda.samples[compared]
            compared < at && row.state == "NOT_FINISHED" && !row.advanced &&
                (first(action) != 6 || !isnothing(row.binding) && row.binding.appearance == outcome.binding.appearance)
        end
        if !isnothing(comparison)
            return OutcomeRelationWitness(reverse!(steps),comparisons[comparison],index)
        end
        current = preparation
    end
    return nothing
end

outcome_relation_chain(agenda,witness) =
    [(;event=relation_ref(agenda.samples[at]),producer) for (at,producer) in witness.steps]

function record_public_outcome!(agenda,index)
    row = agenda.samples[index]
    result = row.state == "WIN" ? :win : row.state == "GAME_OVER" ? :failure :
        row.advanced ? :advancement : nothing
    isnothing(result) && return nothing
    requirements = witnessed_outcome_requirements(agenda,index)
    preparation = isempty(requirements) ? nothing : last(requirements)
    witness = result == :failure ? nothing : witnessed_outcome_relation(agenda,index)
    isnothing(witness) || push!(agenda.outcome_relations,witness)
    chain = isnothing(witness) ? nothing : outcome_relation_chain(agenda,witness)
    outcome = (;index,result,event=relation_ref(row),before=row.effects.before_id,
        attempt=row.attempt,level=row.level,preparation,requirements,dependency=row.dependency,
        relationship=isnothing(witness) ? nothing : (;producer=first(chain).producer,
            preparation=first(chain).event,chain,
            comparison=relation_ref(agenda.samples[witness.comparison]),status=:hypothesis),
        local_effects_complete=row.effects.complete && isempty(row.effects.residual))
    push!(agenda.outcomes,outcome)
    return outcome
end

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
        verdict = measure_joint((model=test.rule,fragments=test.fragments),after;effects)
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
        proposal.intent in (:distinguish_changed_context,:test_delayed_effect,:test_history_response,
            :complete_preparation,:continue_outcome_preparation,:continue_outcome_relation) ?
        relation_ref(prior) : nothing
    next_context = relation_context(next)
    depth = isnothing(prior) ? 1 : prior.history_depth+1
    sample = RelationSample(effects,prev.levels_completed,agenda.attempt,relation_context(prev),
        next_context,relation_receipt(next,next_context),agenda.previous,depth,next.state,advanced,nothing_visible,prev.available_actions,
        binding,dependency,contact,site_changes)
    push!(agenda.samples,sample)
    index = length(agenda.samples)
    action = action_key(effects.action)
    previous = previous_key(agenda,sample.preceding)
    push!(get!(Vector{Int},agenda.visits,(sample.context,action)),index)
    if haskey(effects.public_delta,"available_actions") && !advanced && next.state == "NOT_FINISHED"
        before_groups = isnothing(groups) ? public_components(last(prev.frames)) : groups
        agenda.preparation_roles[index] = visible_role_multiset(before_groups)
    end
    public_outcome = record_public_outcome!(agenda,index)
    if sample.preceding != 0 && agenda.samples[sample.preceding].unchanged
        push!(agenda.pairs,(sample.context,previous,action))
    end
    feedback = relation_checks(proposal,last(next.frames),effects)
    if !isnothing(proposal) && proposal.intent in
            (:recover_confirmed_progress,:restore_failure_experiment_context,:explore_observed_frontier_path)
        observed = sample.next_context == proposal.obligation.expected &&
            sample.advanced == proposal.obligation.advanced && sample.state == "NOT_FINISHED"
        feedback = merge(feedback,(result=observed ? :established : :refuted,))
    elseif !isnothing(proposal) && (proposal.intent in (:probe_observed_advancement,:continue_outcome_relation) ||
            proposal.intent == :execute_relation_policy &&
            get(proposal.obligation,:public_outcome,nothing) == "advancement")
        feedback = merge(feedback,(result=sample.advanced ? :established : :refuted,))
        if proposal.intent == :probe_observed_advancement && !sample.advanced
            transfer = proposal.obligation.transfer
            if !isnothing(transfer)
                counterexample = get!(agenda.advancement_counterexamples,transfer,index)
                feedback = merge(feedback,(;withdrawn_transfer=(;
                    scope=transfer,event=relation_ref(agenda.samples[counterexample]))))
            end
        end
    elseif !isnothing(proposal) && proposal.intent == :prepare_public_outcome
        legal = proposal.obligation.action in next.available_actions
        feedback = merge(feedback,(result=next.state == "NOT_FINISHED" && legal ? :established : :refuted,))
    elseif !isnothing(proposal) && proposal.intent == :distinguish_changed_context && !isnothing(binding)
        scope = (sample.level,action,binding.appearance)
        comparisons = get!(Vector{Int},agenda.context_comparisons,scope)
        previous_comparison = isempty(comparisons) ? nothing : relation_ref(agenda.samples[last(comparisons)])
        push!(comparisons,index)
        comparison = (;prior=proposal.obligation.prior,previous_comparison,confirmed_tests=length(comparisons),
            response_changed=!sample.unchanged)
        feedback = merge(feedback,(;comparison))
    end
    if !isnothing(feedback)
        history = !isempty(proposal.tests) && (action[1] == 6 || proposal.intent == :execute_relation_policy) ?
            relation_history_key(agenda,sample.context,sample.preceding) : nothing
        for (row,test) in zip(feedback.tests,proposal.tests)
            row.status == :refuted && push!(agenda.producers[row.producer].refuted,index)
            if !isnothing(history) && row.status in (:established,:refuted)
                scope = effect_experiment_scope(sample.level,action,history,test)
                push!(agenda.checked_effects,scope)
            end
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
        state = (first(action),first(previous))
        push!(get!(Vector{Int},agenda.advancement,state),index)
        if first(action) != 6
            before_groups = isnothing(groups) ? public_components(last(prev.frames)) : groups
            agenda.advancement_roles[index] = visible_role_multiset(before_groups)
        end
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
        site_transitions=[row.observed for row in site_changes],producer=contract,feedback,failure,unresolved,
        public_outcome)
end

function outcome_preparation(agenda,obs,decision,context)
    appearances = nothing
    current_history = relation_history_key(agenda,context,agenda.previous)
    for outcome in Iterators.reverse(agenda.outcomes)
        (outcome.result == :failure || isempty(outcome.requirements) ||
            outcome.preparation.action in obs.available_actions) && continue
        for (step,preparation) in enumerate(outcome.requirements)
            preparation.action in obs.available_actions && continue
            row = agenda.samples[preparation.index]
            Set(row.available) == Set(obs.available_actions) || continue
            if isnothing(row.binding)
                isnothing(appearances) && (appearances = visible_role_multiset(decision.groups))
                get(agenda.preparation_roles,preparation.index,nothing) == appearances || continue
            end
            candidate = findfirst(decision.ranked) do option
                key = action_key(option.action)
                first(key) == row.effects.action["id"] || return false
                observed = get(agenda.visits,(context,key),Int[])
                any(i->relation_history_key(agenda,context,agenda.samples[i].preceding) == current_history,observed) &&
                    return false
                isnothing(row.binding) && return true
                support = point_component(decision.groups,key[2:3])
                return !isnothing(support) && click_profile(support,key[2:3]) == row.binding.appearance
            end
            isnothing(candidate) && continue
            reads = relation_refs(agenda.samples[outcome.index])
            for required in outcome.requirements
                append!(reads,relation_refs(agenda.samples[required.index]))
            end
            links = [(;required.event,required.action,required.relation) for required in outcome.requirements]
            obligation = (;outcome=outcome.event,preparation=relation_ref(row),action=preparation.action,
                relation=preparation.relation,scope=row.context == context ? "observed_instance" : "new_instance",
                chain=links,step)
            return (;action=decision.ranked[candidate].action,intent=:prepare_public_outcome,tests=NamedTuple[],
                reads=unique!(reads),obligation)
        end
    end
    return nothing
end

function partition_experiment(agenda,scene,obs,context,regions)
    (isnothing(regions) || 6 ∉ obs.available_actions) && return nothing
    index = findlast(!isnothing,regions.topology)
    isnothing(index) && return nothing
    change = regions.topology[index]
    change.status == "observed_overlap" || return nothing
    affected = BitSet(merge.after for merge in change.merges)
    for split in change.splits
        union!(affected,first.(split.after))
    end
    isempty(affected) && return nothing
    labels = last(regions.frames).owner
    for candidate in scene
        candidate.broad && continue
        x,y = candidate.point
        label = labels[y+1,x+1]
        label in affected || continue
        action = click_action(candidate.point)
        haskey(agenda.visits,(context,action_key(action))) && continue
        obligation = (;source=regions.event,response_frame=index-1,region=label,
            binding=candidate.instance,status="unresolved")
        return (;action,intent=:probe_partition_binding,tests=NamedTuple[],reads=[regions.event],obligation)
    end
    return nothing
end

function matches_outcome_binding(row,action,groups)
    id,x,y = action_key(action)
    id == row.effects.action["id"] || return false
    id == 6 || return true
    isnothing(row.binding) && return false
    support = point_component(groups,(x,y))
    return !isnothing(support) && click_profile(support,(x,y)) == row.binding.appearance
end

function rebound_outcome_action(row,decision)
    candidate = findfirst(item->matches_outcome_binding(row,item.action,decision.groups),decision.ranked)
    return isnothing(candidate) ? nothing : decision.ranked[candidate].action
end

function equivalent_effect_roles(agenda,source,target)
    first,second = agenda.producers[source],agenda.producers[target]
    first.relations == second.relations || return nothing
    a,b = first.rule.click,second.rule.click
    relative_effect_roles(a) && relative_effect_roles(b) || return nothing
    a.offsets == b.offsets && all(!isnothing,a.offsets) || return nothing
    return (;source,target,offsets=a.offsets)
end

function outcome_preparation_step(agenda,witness,step,obs,decision,context,target;
                                  meters,condition_view,confirmed=String[])
    at, producer = witness.steps[step]
    source = agenda.samples[at]
    Set(source.available) == Set(obs.available_actions) || return nothing
    history = relation_history_key(agenda,context,agenda.previous)
    for item in decision.ranked
        action = item.action
        action["id"] == source.effects.action["id"] || continue
        key = action_key(action)
        if step == 1 && any(index->relation_history_key(agenda,context,agenda.samples[index].preceding) == history,
                get(agenda.visits,(context,key),Int[]))
            continue
        end
        observed_failure(agenda,context,action_key(action),agenda.previous) && continue
        tests = prepare_relation_tests(agenda,context,obs,decision.groups,action;meters,condition_view)
        matching = findfirst(test->test.key == producer,tests)
        equivalence = nothing
        if isnothing(matching)
            for (index,test) in enumerate(tests)
                test.scope in (:bound,:replicated) || continue
                equivalence = equivalent_effect_roles(agenda,producer,test.key)
                isnothing(equivalence) && continue
                matching = index
                break
            end
        end
        isnothing(matching) && continue
        contract = tests[matching]
        expected = contract.expected
        all(test->test.expected == expected,tests) || continue
        comparison,outcome = agenda.samples[[witness.comparison,witness.outcome]]
        chain = outcome_relation_chain(agenda,witness)
        obligation = (;producer=contract.key,target,comparison=relation_ref(comparison),
            preparation=relation_ref(source),outcome=relation_ref(outcome),index=witness.outcome,
            sought=contract.relations,scope=:hypothesis,chain,step,confirmed)
        isnothing(equivalence) || (obligation = merge(obligation,(;role_equivalence=equivalence)))
        reads = unique([relation_refs(comparison);relation_refs(outcome);confirmed;
            [ref for (index,_) in witness.steps for ref in relation_refs(agenda.samples[index])]])
        intent = step == 1 ? :establish_outcome_relation : :continue_outcome_preparation
        return (;action,intent,tests=[contract],reads,obligation,witness)
    end
    return nothing
end

function prepare_outcome_relation(agenda,obs,decision,context;meters,condition_view)
    for witness in Iterators.reverse(agenda.outcome_relations)
        target = rebound_outcome_action(agenda.samples[witness.outcome],decision)
        isnothing(target) && continue
        observed_failure(agenda,context,action_key(target),agenda.previous) && continue
        next = outcome_preparation_step(agenda,witness,1,obs,decision,context,target;meters,condition_view)
        isnothing(next) || return next
    end
    return nothing
end

function advancement_probe(agenda,obs,decision,context)
    isempty(agenda.advancement) && return nothing
    previous = previous_key(agenda,agenda.previous)
    current_history = relation_history_key(agenda,context,agenda.previous)
    available = Set(obs.available_actions)
    domain = Tuple(sort!(collect(available)))
    scene = nothing
    choices = NamedTuple[]
    for item in decision.ranked
        key = action_key(item.action)
        history = get(agenda.advancement,(first(key),first(previous)),nothing)
        isnothing(history) && continue
        prior = get(agenda.visits,(context,key),Int[])
        any(index->!agenda.samples[index].advanced &&
            relation_history_key(agenda,context,agenda.samples[index].preceding) == current_history,prior) && continue
        profile = if first(key) == 6
            point = key[2:3]
            support = point_component(decision.groups,point)
            isnothing(support) && continue
            click_profile(support,point)
        else
            isnothing(scene) && (scene = visible_role_multiset(decision.groups))
            scene
        end
        transfer = (level=obs.levels_completed,action=first(key),previous=first(previous),
            role=profile,available=domain)
        for index in Iterators.reverse(history)
            row = agenda.samples[index]
            Set(row.available) == available || continue
            new_instance = row.context != context
            if new_instance
                # A failed experiment withdraws the broad transfer claim.
                # Other bindings still compete through normal exploration.
                haskey(agenda.advancement_counterexamples,transfer) && continue
            else
                relation_history_key(agenda,context,row.preceding) == current_history || continue
            end
            matches = first(key) == 6 ? !isnothing(row.binding) && row.binding.appearance == profile :
                get(agenda.advancement_roles,index,nothing) == profile
            matches || continue
            push!(choices,(;action=item.action,row,transfer=new_instance ? transfer : nothing,
                prior=length(prior),rank=item.rank))
            break
        end
    end
    isempty(choices) && return nothing
    best = argmin(item->(!isnothing(item.transfer),item.prior,item.rank),choices)
    obligation = (;source=relation_ref(best.row),expected="public_advancement",
        scope=isnothing(best.transfer) ? "observed_instance" : "new_instance",
        source_level=best.row.level,transfer=best.transfer)
    return (;action=best.action,intent=:probe_observed_advancement,tests=NamedTuple[],
        reads=relation_refs(best.row),obligation)
end

function verified_instance(agenda,producer,context,action,previous,level;condition=nothing)
    history = relation_history_key(agenda,context,previous)
    exact(index) = begin
        row = agenda.samples[index]
        row.context == context && action_key(row.effects.action) == action &&
            relation_history_key(agenda,context,row.preceding) == history
    end
    any(exact,producer.refuted) && return :counterexample
    clashes = any(get(agenda.visits,(context,action),Int[])) do index
        exact(index) && agenda.samples[index].unchanged
    end
    clashes && return :counterexample
    any(exact,producer.support) && return :bound
    refined_history(history_scope(agenda,context)) && return :unverified
    # Both local effects and disagreement remain in the same index.
    # Evidence for visual transfer excludes terminal outcomes.
    support = isnothing(condition) ? producer.support :
        filter(i->relation_ref(agenda.samples[i]) in condition.support,producer.support)
    witnesses = [row.binding for index in support for row in (agenda.samples[index],)
        if row.level == level && row.state == "NOT_FINISHED" && !isnothing(row.binding)]
    contradicted = any(producer.refuted) do index
        row = agenda.samples[index]
        row.level == level && (isnothing(condition) || relation_ref(row) ∉ condition.excluded)
    end
    if action[1] != 6
        contexts = Set(row.context for index in support for row in (agenda.samples[index],)
            if row.level == level && row.state == "NOT_FINISHED" &&
                first(previous_key(agenda,row.preceding)) == first(previous_key(agenda,previous)))
        return length(contexts) >= 2 && !contradicted ? :replicated : :unverified
    end
    return length(unique(row.point for row in witnesses)) >= 2 &&
        length(unique(row.lineage for row in witnesses)) >= 2 && !contradicted ? :replicated : :unverified
end

function prepare_relation_tests(agenda,context,obs,groups,action;meters=(),condition_view=nothing,
                                enclosure=nothing,role_index=nothing)
    point = action_key(action)
    role = action["id"] == 6 ? point_component(groups,point[2:3]) : nothing
    action["id"] == 6 && isnothing(role) && return NamedTuple[]
    profile = isnothing(role) ? primitive_profile(action["id"]) : click_profile(role,point[2:3])
    ids = get(agenda.by_action,profile,String[])
    isempty(ids) && return NamedTuple[]
    frame = last(obs.frames)
    isnothing(enclosure) && (enclosure = enclosure_pairs(groups))
    previous = agenda.previous
    tests = NamedTuple[]
    for key in ids
        producer = agenda.producers[key]
        scope = verified_instance(agenda,producer,context,point,previous,obs.levels_completed)
        scope == :counterexample && continue
        # Unrestricted matches of a deterministic relative footprint are still
        # experiments until there are concrete outcomes at multiple bindings.
        rule = producer.rule
        eval = evaluate_joint_rule(rule,frame,groups,enclosure,action;meters,relative_transfer=true,role_index)
        eval.truth == proven || continue
        expected = plan_channels(eval.fragments)
        isnothing(expected) && continue
        conditions = NamedTuple[]
        if !isnothing(condition_view)
            models = get(condition_view.models,relation_condition_key(rule),())
            for model in models
                known = candidate_evaluation(model,frame,groups,enclosure,action,condition_view.history;
                    meters,transients=condition_view.transients,role_index,relative_transfer=true)
                known.truth == proven && plan_channels(known.fragments) == expected || continue
                push!(conditions,(;version=active_id(model),reads=condition_view.reads(model)))
                if scope == :unverified && !isempty(model.condition.excluded)
                    scope = verified_instance(agenda,producer,context,point,previous,obs.levels_completed;
                        condition=model.condition)
                end
            end
            isempty(models) || !isempty(conditions) || continue
        end
        if scope != :bound && (isnothing(rule.click) ? scope == :replicated : !rule.click.local_pigment)
            guard = (complete=true,)
            projected = projection_patch((model=(;rule,condition=guard),fragments=eval.fragments),frame)
            isnothing(projected) && continue
        end
        reads = unique([ref for index in [producer.support;producer.refuted]
            for ref in relation_refs(agenda.samples[index])])
        for condition in conditions
            append!(reads,condition.reads)
        end
        scope_history = history_scope(agenda,context)
        if refined_history(scope_history)
            append!(reads,relation_ref.(agenda.samples[frontier_prior(agenda,previous,scope_history.width)]))
        end
        push!(tests,(;key,rule,scope,expected,eval.fragments,reads=unique!(reads),conditions,relations=producer.relations))
    end
    if any(test->test.scope == :bound,tests)
        filter!(test->test.scope == :bound,tests)
    end
    return tests
end

function experimental_response_score(scores,action,groups)
    id = action["id"]
    (id != 6 || isempty(scores) || haskey(scores,id)) && return get(scores,id,0.0)
    point = (action["x"],action["y"])
    support = point_component(groups,point)
    isnothing(support) && return 0.0
    return get(scores,(id,click_profile(support,point)),0.0)
end

function relation_experiment(agenda,obs,decision,intervention,context;meters=(),uncertainty=Dict{Int,Float64}(),
                             circuit_ref=nothing,history_model=nothing,frontier=nothing)
    previous = agenda.previous
    prior = previous == 0 ? nothing : agenda.samples[previous]
    condition_view = get(decision,:condition_view,nothing)
    if !isnothing(agenda.restart)
        failure = agenda.restart
        recovery_trace = [failure.prefix;failure.experiment_path]
        if failure.cursor <= length(recovery_trace)
            row = agenda.samples[recovery_trace[failure.cursor]]
            action = row.effects.action
            bound = context == row.context && row.level == obs.levels_completed &&
                action["id"] in obs.available_actions
            if bound && !isnothing(frontier)
                bound = frontier_state(agenda,context,previous) ==
                    frontier_state(agenda,row.context,row.preceding)
            end
            if bound
                obligation = (;failure=failure.event,source=relation_ref(row),
                    expected=row.next_context,advanced=row.advanced,step=failure.cursor)
                intent = failure.cursor <= length(failure.prefix) ?
                    :recover_confirmed_progress : :restore_failure_experiment_context
                return (;action,intent,tests=NamedTuple[],
                    reads=unique([failure.event;relation_refs(row)]),obligation)
            end
        end
        # The original first action is excluded only in its own public context.
        altered(row) = failure.initial != context || action_key(row.action) != failure.first
        rows = [(action=row.action,rank=row.rank) for row in decision.ranked if altered(row)]
        if !isnothing(intervention) && altered(intervention) &&
                all(row->row.action != intervention.action,rows)
            push!(rows,(action=intervention.action,rank=(0,0)))
        end
        if !isnothing(frontier)
            node = frontier_state(agenda,context,previous)
            tried = get(frontier.outcomes,node,nothing)
            if !isnothing(tried)
                filter!(row->!haskey(tried,action_key(row.action)),rows)
            end
            if isempty(rows)
                fresh = frontier_new_configuration(frontier,node,obs.available_actions)
                if !isnothing(fresh)
                    push!(rows,(action=concrete_action(fresh),rank=(0,0)))
                end
            end
        end
        if !isempty(rows)
            function rank_revision(row)
                key = action_key(row.action)
                support = key[1] == 6 ? point_component(decision.groups,key[2:3]) : nothing
                role = isnothing(support) ? nothing : click_profile(support,key[2:3])
                return (observed_failure(agenda,context,key,previous),
                    !isnothing(failure.role) && role != failure.role,
                    length(get(agenda.visits,(context,key),Int[])),row.rank)
            end
            row = argmin(rank_revision,rows)
            return (;action=row.action,intent=:revise_failed_trace,tests=NamedTuple[],
                reads=[failure.event],obligation=failure)
        end
    end
    if !isnothing(agenda.preparing)
        plan = agenda.preparing
        if get(plan,:kind,nothing) == :outcome_relation
            target = plan.obligation.target
            outcome = agenda.samples[plan.witness.outcome]
            if !isnothing(prior) && relation_ref(prior) == plan.event && context == plan.context
                if target["id"] ∉ obs.available_actions || !matches_outcome_binding(outcome,target,decision.groups)
                    target = rebound_outcome_action(outcome,decision)
                end
                if !isnothing(target) && !observed_failure(agenda,context,action_key(target),previous)
                    step = plan.obligation.step + 1
                    confirmed = plan.confirmed
                    if step > length(plan.witness.steps)
                        obligation = merge(plan.obligation,(;target,confirmed,established=plan.event))
                        return (;action=target,intent=:continue_outcome_relation,tests=NamedTuple[],
                            reads=plan.reads,obligation)
                    end
                    next = outcome_preparation_step(agenda,plan.witness,step,obs,decision,context,target;
                        meters,condition_view,confirmed)
                    isnothing(next) || return next
                end
            end
        elseif !isnothing(prior) && prior.unchanged && context == plan.context &&
                prior.effects.action == plan.first && plan.next["id"] in obs.available_actions
            tests = prepare_relation_tests(agenda,context,obs,decision.groups,plan.next;meters,condition_view)
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
    outcome_relation = prepare_outcome_relation(agenda,obs,decision,context;meters,condition_view)
    isnothing(outcome_relation) || return outcome_relation
    comparison = isnothing(intervention) ? nothing : get(intervention,:effect_experiment,nothing)
    if !isnothing(comparison) && comparison.comparison == :distinguish_concrete_effects
        return (;intervention.action,intent=:test_concrete_effect,intervention.tests,
            reads=String[],obligation=comparison)
    end
    sought = observed_relation_task(agenda,obs,decision,context;meters)
    isnothing(sought) || return sought
    progress = advancement_probe(agenda,obs,decision,context)
    isnothing(progress) || return progress
    preparation = outcome_preparation(agenda,obs,decision,context)
    isnothing(preparation) || return preparation
    if !isnothing(frontier) && (isnothing(history_model) || history_scope(agenda,context).receipts)
        contrast = frontier_history_probe(frontier,agenda,obs,context)
        isnothing(contrast) || return contrast
    end
    if !isnothing(prior) && (prior.unchanged || !isnothing(history_model))
        first_action = action_key(prior.effects.action)
        rows = filter(decision.ranked) do row
            key = action_key(row.action)
            prior.unchanged ? (context,first_action,key) ∉ agenda.pairs :
                !haskey(agenda.visits,(context,key))
        end
        unseen(row) = !isnothing(history_model) && !haskey(history_model.edges,history_action(row.action))
        if !isempty(rows) && (prior.unchanged || any(unseen,rows))
            priority(row) = (row.action["id"] == 6,
                !isnothing(intervention) && row.action != intervention.action,
                length(get(agenda.visits,(context,action_key(row.action)),Int[])))
            baseline = argmin(row->(priority(row),row.rank),rows)
            entropy(row) = isnothing(circuit_ref) ? 0.0 : experimental_response_score(uncertainty,row.action,decision.groups)
            circuit = isnothing(circuit_ref) ? baseline : argmin(row->(priority(row),-entropy(row),row.rank),rows)
            row = isnothing(history_model) ? circuit :
                argmin(row->(priority(row),!unseen(row),-entropy(row),row.rank),rows)
            history = if unseen(row)
                (;scope=history_model.scope,state=history_model.state,answer="unknown",changed_action=row.action != circuit.action)
            end
            history_only = isnothing(history_model) ? baseline : argmin(row->(priority(row),!unseen(row),row.rank),rows)
            circuit_changed = row.action != history_only.action
            tests = prepare_relation_tests(agenda,context,obs,decision.groups,row.action;meters,condition_view)
            reads = relation_refs(prior)
            circuit_changed && push!(reads,circuit_ref)
            isnothing(history) || push!(reads,history.scope)
            if prior.unchanged || !isnothing(history)
                intent = prior.unchanged ? :test_delayed_effect : :test_history_response
                return (;action=row.action,intent,tests,reads=unique!(reads),
                    obligation=(prefix=relation_ref(prior),action=prior.effects.action,
                        circuit=circuit_changed ? circuit_ref : nothing,history,baseline=baseline.action))
            end
        end
    end
    isnothing(intervention) && return nothing
    action = intervention.action
    tests = get(intervention,:tests,nothing)
    isnothing(tests) && (tests = prepare_relation_tests(agenda,context,obs,decision.groups,action;
        meters,condition_view))
    if hasproperty(intervention,:changed_context)
        return (;action,intent=:distinguish_changed_context,tests,reads=intervention.changed_context.reads,
            obligation=intervention.changed_context)
    end
    isempty(tests) && return nothing
    return (;action,intent=:test_concrete_effect,tests,reads=String[],obligation=comparison)
end

function observed_relation_task(agenda,obs,decision,context;meters)
    previous = agenda.previous
    history = relation_history_key(agenda,context,previous)
    condition_view = get(decision,:condition_view,nothing)
    examined = Set{PublicActionKey}()
    candidates = NamedTuple[]
    for index in Iterators.reverse(get(agenda.produced_at,context,Int[]))
        row = agenda.samples[index]
        action = row.effects.action
        key = action_key(action)
        key in examined && continue
        push!(examined,key)
        route = (context,history,key)
        (route in agenda.relation_replays || observed_failure(agenda,context,key,previous)) && continue
        action["id"] in obs.available_actions || continue
        tests = prepare_relation_tests(agenda,context,obs,decision.groups,action;meters,condition_view)
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
                          continuing_policy=false,policy_yield=false,frontier=nothing)
    candidates = NamedTuple[]
    add(source,action,reason,priority) = push!(candidates,(;source,action,reason,priority))
    add(program ? :program : :base,item.action,item.reason,program ? 0 : conditional ? 1 : 8)
    contact_ready = false
    if !isnothing(spatial)
        contact = get(spatial,:contact,nothing)
        contact_ready = continuing_contact || !isnothing(contact) && contact.conditions.judgment == :admitted
        grounded = contact_ready || get(spatial,:effect_gain,0) > 0
        add(:spatial,Dict("id"=>spatial.id),spatial.reason,grounded ? 1 : object_probes ? 7 : 4)
    end
    if !isnothing(intervention)
        add(:intervention,intervention.action,intervention.reason,isnothing(intervention.goal) ? 6 : 2)
    end
    if !isnothing(relation)
        priority = relation.intent in (:recover_confirmed_progress,:restore_failure_experiment_context) ? -1 :
            relation.intent in (:revise_failed_trace,:complete_preparation,:continue_outcome_preparation,
                :continue_outcome_relation) ? 1 :
            relation.intent in (:test_concrete_effect,:distinguish_changed_context,:test_delayed_effect,
                :test_history_response,:establish_preparation,:establish_observed_relation,:probe_observed_advancement,
                :prepare_public_outcome,:establish_outcome_relation) ? 3 : 5
        reason = !isnothing(intervention) && relation.action == intervention.action &&
            relation.intent in (:test_concrete_effect,:test_delayed_effect) ?
            intervention.reason : string(relation.intent)
        add(:relation,relation.action,reason,priority)
    end
    if !isnothing(experiment)
        priority = get(experiment,:independent,false) ? 4 : 7
        add(:experiment,experiment.action,"distinguish_public_experiment",priority)
    end
    baseline = argmin(row->row.priority,candidates)
    if !isnothing(policy)
        purpose = get(policy.obligation,:purpose,nothing)
        directed = !isnothing(purpose) && purpose.kind in (:establish_public_outcome,:enable_policy_action)
        priority = continuing_policy ? 0 : policy_yield ? baseline.priority+1 : directed ? 2 : 4
        add(:relation_policy,policy.action,"execute_relation_policy",priority)
    end
    choice = argmin(row->row.priority,candidates)
    frontier_task = nothing
    if !isnothing(frontier)
        protected = if choice.source == :spatial
            contact_ready
        elseif choice.source == :relation_policy
            continuing_policy || choice.priority <= 2
        elseif choice.source == :relation
            choice.priority <= 2 || relation.intent in
                (:establish_preparation,:probe_observed_advancement,:prepare_public_outcome,:establish_outcome_relation)
        elseif choice.source == :experiment
            get(experiment,:independent,false)
        else
            choice.priority <= 2
        end
        if protected
            frontier_options!(frontier.search,frontier.context,frontier.decision.ranked,intervention)
        else
            frontier_task = frontier_choice(frontier.search,frontier.agenda,frontier.observation,
                frontier.decision,intervention,choice.action)
            if !isnothing(frontier_task)
                add(:relation,frontier_task.action,string(frontier_task.intent),choice.priority-1)
                choice = last(candidates)
            end
        end
    end
    return (;choice,baseline,candidates,frontier_task)
end

function changed_context_probe(agenda,obs,scene)
    agenda.previous == 0 && return nothing
    latest = agenda.samples[agenda.previous]
    latest.context == latest.next_context && return nothing
    best = nothing
    fewest_tests = typemax(Int)
    comparison_reads = String[]
    for candidate in scene
        action = click_action(candidate.point)
        key = action_key(action)
        haskey(agenda.visits,(latest.next_context,key)) && continue
        original = get(agenda.visits,(latest.context,key),Int[])
        isempty(original) && continue
        earlier = agenda.samples[last(original)]
        earlier.unchanged || continue
        isnothing(earlier.binding) && continue
        appearance = click_profile(candidate.support,candidate.point)
        earlier.binding.appearance == appearance || continue
        comparisons = get(agenda.context_comparisons,(obs.levels_completed,key,appearance),nothing)
        count = isnothing(comparisons) ? 0 : length(comparisons)
        count > 0 && push!(comparison_reads,relation_ref(agenda.samples[last(comparisons)]))
        count < fewest_tests || continue
        best = (;candidate,action,earlier)
        fewest_tests = count
        count == 0 && break
    end
    isnothing(best) && return nothing
    # A different context still permits a comparison after earlier attempts.
    # Give the eligible binding with fewer confirmed comparisons the first turn.
    obligation = (;reads=unique([relation_refs(best.earlier);relation_refs(latest);comparison_reads]),
        prior=relation_ref(best.earlier),previous_context=latest.context,context=latest.next_context,
        prior_confirmed_tests=fewest_tests)
    return (;best.action,probe=:representative,best.candidate,goal=nothing,fallback=nothing,
        changed_context=obligation,reason="distinguish_changed_object_context")
end

"""Offer an experiment for a concrete effect whose current scope still needs a comparison."""
function object_effect_followup(agenda::RelationAgenda,obs,context,candidates;
                                groups=nothing,meters=(),condition_view=nothing)
    options = NamedTuple[]
    level = obs.levels_completed
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
    isempty(options) && return nothing
    isnothing(groups) && (groups = public_components(last(obs.frames)))
    enclosure = enclosure_pairs(groups)
    role_index = EffectRoleIndex()
    sort!(options;by=row->(haskey(agenda.lineages,row.candidate.support),
        -row.witnesses,row.distance,row.candidate.point))
    examined = Set{Tuple{Int,Int}}()
    history = relation_history_key(agenda,context,agenda.previous)
    for row in options
        candidate = row.candidate
        candidate.point in examined && continue
        push!(examined,candidate.point)
        action = click_action(candidate.point)
        tests = prepare_relation_tests(agenda,context,obs,groups,action;
            meters,condition_view,enclosure,role_index)
        isempty(tests) && continue
        pending = [test.key for test in tests if
            effect_experiment_scope(level,action_key(action),history,test) ∉ agenda.checked_effects]
        isempty(pending) && continue
        comparison = all(test->test.expected == first(tests).expected,tests) ?
            :effect_at_bound_condition : :distinguish_concrete_effects
        purpose = (;comparison,producers=pending,history)
        return (;candidate,tests,purpose)
    end
    return nothing
end

function relation_task_record(proposal)
    reads = sort!(unique([proposal.reads;[ref for test in proposal.tests for ref in test.reads]]))
    contracts = [(producer=test.key,scope=test.scope,relations=test.relations,expected=test.expected,
        roles=[(family=part.family,port=program_input(part)) for part in test.fragments],reads=test.reads,
        conditions=get(test,:conditions,NamedTuple[]))
        for test in proposal.tests]
    return (;intent=proposal.intent,action=proposal.action,reads,contracts,obligation=proposal.obligation)
end

function relation_prediction(rec,item,prediction,task;role_proof=nothing,resource_proof=nothing)
    isempty(task.reads) && return prediction
    reads = sort!(unique([rec.before_ref;task.reads]))
    if !isnothing(role_proof) && get(role_proof,:reused,false)
        role_proof.proved_at in reads || push!(reads,role_proof.proved_at)
    end
    admitted = length(task.contracts) == 1 && only(task.contracts).scope in (:bound,:replicated)
    if !isnothing(role_proof)
        admitted &= role_proof.execution == "completed" && role_proof.answer == "value" &&
            get(role_proof.value,"entailed",false) === true
    end
    admitted &= isnothing(resource_proof) || resource_proof.status == :proven
    values = Dict{String,Any}()
    if admitted
        for (channel,value) in only(task.contracts).expected
            values["relation-" * channel] = value
        end
    end
    if task.intent == :execute_relation_policy &&
            get(task.obligation,:public_outcome,nothing) == "advancement" &&
            task.obligation.scope == :observed_instance
        values["public_advancement"] = true
        admitted = true
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

function failure_retry!(agenda;frontier=nothing)
    isempty(agenda.samples) && return nothing
    length(agenda.samples) >= agenda.start || return nothing
    ending = last(agenda.samples)
    ending.state == "GAME_OVER" || return nothing
    scope = (ending.context,previous_key(agenda,ending.preceding),action_key(ending.effects.action))
    last_level = findprev(row->row.advanced,agenda.samples,length(agenda.samples))
    first_index = isnothing(last_level) ? agenda.start : max(agenda.start,last_level+1)
    first_sample = agenda.samples[first_index]
    # RETRY needs a different experiment in the failed level.
    first_action = action_key(first_sample.effects.action)
    experiment_path = Int[]
    if isnothing(frontier)
        scope in agenda.reopened && return nothing
        length(first_sample.available) > 1 || 6 in first_sample.available || return nothing
    else
        origin = frontier_state(agenda,first_sample.context,first_sample.preceding)
        if isempty(frontier_untried(frontier,origin))
            reachable = frontier_path(frontier,agenda,origin)
            if isnothing(reachable) && isnothing(frontier_new_configuration(frontier,origin,first_sample.available))
                reachable = frontier_path(frontier,agenda,origin;include_configurations=true)
                isnothing(reachable) && return nothing
            end
            isnothing(reachable) || (experiment_path = reachable.route)
        end
    end
    push!(agenda.reopened,scope)
    return (;event=relation_ref(ending),initial=first_sample.context,first=first_action,
        level=first_sample.level,attempt=agenda.attempt,attribution=:unresolved,
        role=isnothing(first_sample.binding) ? nothing : first_sample.binding.appearance,
        prefix=Int[],experiment_path,cursor=1)
end

function winning_prefix(agenda,restart,context,level)
    level < restart.level || return Int[]
    # Learn only from one contiguous confirmed trace, never concatenate fragments
    # that merely share a rendered frame after potentially hidden state changes.
    for start in Iterators.reverse(eachindex(agenda.samples))
        first = agenda.samples[start]
        first.level == level && first.context == context && first.preceding == 0 || continue
        expected = context
        for index in start:length(agenda.samples)
            row = agenda.samples[index]
            row.attempt == first.attempt && row.context == expected && row.state == "NOT_FINISHED" || break
            expected = row.next_context
            row.advanced && row.level+1 == restart.level && return collect(start:index)
        end
    end
    return Int[]
end

function begin_relation_attempt!(agenda,restart;observation=nothing)
    agenda.attempt += 1
    agenda.start = length(agenda.samples)+1
    agenda.previous = 0
    agenda.restart = if isnothing(restart) || isnothing(observation)
        restart
    else
        prefix = winning_prefix(agenda,restart,relation_context(observation),observation.levels_completed)
        merge(restart,(;prefix))
    end
    agenda.preparing = nothing
    empty!(agenda.lineages)
end

function finish_relation_dispatch!(agenda,proposal;feedback=nothing)
    restart = agenda.restart
    agenda.restart = nothing
    agenda.preparing = nothing
    isnothing(proposal) && return
    if proposal.intent in (:recover_confirmed_progress,:restore_failure_experiment_context)
        row = last(agenda.samples)
        expected = proposal.obligation
        if row.next_context == expected.expected && row.advanced == expected.advanced &&
                row.state == "NOT_FINISHED"
            agenda.restart = merge(restart,(cursor=restart.cursor+1,))
        end
    elseif proposal.intent == :establish_preparation
        plan = proposal.obligation
        push!(agenda.preparations,(agenda.attempt,plan.context,plan.index))
        agenda.preparing = plan
    elseif proposal.intent in (:establish_outcome_relation,:continue_outcome_preparation) &&
            !isnothing(feedback) && feedback.result == :established
        row = last(agenda.samples)
        if row.state == "NOT_FINISHED" && !row.advanced
            confirmed = [proposal.obligation.confirmed;relation_ref(row)]
            agenda.preparing = (;kind=:outcome_relation,event=relation_ref(row),context=row.next_context,
                proposal.witness,proposal.obligation,confirmed,reads=unique([proposal.reads;relation_refs(row)]))
        end
    elseif proposal.intent == :establish_observed_relation
        push!(agenda.relation_replays,proposal.obligation.route)
    end
end
