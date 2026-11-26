const FrontierState = Tuple{String,Tuple}

struct RelationHistoryScope
    width::Int
    receipts::Bool
end

history_scope(agenda,context) = get(agenda.history_scopes,context,RelationHistoryScope(1,false))
refined_history(scope::RelationHistoryScope) = scope.width > 1 || scope.receipts

struct FrontierRoute
    steps::Vector{Int}
    cursor::Int
    target::FrontierState
    experiment::PublicActionKey
end

mutable struct PublicFrontier
    options::Dict{String,Vector{PublicActionKey}}
    outcomes::Dict{FrontierState,Dict{PublicActionKey,Vector{Int}}}
    visits::Dict{String,Vector{Int}}
    allowed_widths::Vector{Int}
    unresolved::Set{String}
    route::Union{Nothing,FrontierRoute}
end

PublicFrontier(widths=[1,2,4]) = PublicFrontier(Dict(),Dict(),Dict(),
    sort!(unique([1;filter(>(1),widths)])),Set(),nothing)

function frontier_prior(agenda,index,width)
    collected = Int[]
    while index != 0 && length(collected) < width
        push!(collected,index)
        index = agenda.samples[index].preceding
    end
    return reverse!(collected)
end

function relation_history_key(agenda,context,index;scope=history_scope(agenda,context))
    prior = frontier_prior(agenda,index,scope.width)
    return Tuple(scope.receipts ? (action_key(row.effects.action),row.receipt) : action_key(row.effects.action)
        for i in prior for row in (agenda.samples[i],))
end

frontier_state(agenda,context,index) = (context,relation_history_key(agenda,context,index))

function frontier_options!(search,context,ranked,intervention)
    candidates = PublicActionKey[action_key(row.action) for row in ranked]
    isnothing(intervention) || push!(candidates,action_key(intervention.action))
    options = get!(Vector{PublicActionKey},search.options,context)
    union!(options,candidates)
    return options
end

function index_frontier_observation!(search,agenda,index)
    row = agenda.samples[index]
    node = frontier_state(agenda,row.context,row.preceding)
    outcomes = get!(Dict{PublicActionKey,Vector{Int}},search.outcomes,node)
    return push!(get!(Vector{Int},outcomes,action_key(row.effects.action)),index)
end

frontier_outcome(row) = (row.next_context,row.state,row.advanced)

function compatible_frontier_history(search,agenda,context,scope)
    responses = Dict{Tuple,Tuple}()
    for index in search.visits[context]
        row = agenda.samples[index]
        past = relation_history_key(agenda,context,row.preceding;scope)
        key = (past,action_key(row.effects.action))
        outcome = frontier_outcome(row)
        get!(responses,key,outcome) == outcome || return false
    end
    return true
end

function extended_frontier_history(search,agenda,context,old)
    lower = max(old.width + Int(old.receipts),last(search.allowed_widths)+1)
    upper = maximum(i->agenda.samples[i].history_depth-1,search.visits[context];init=0)
    lower <= upper && compatible_frontier_history(search,agenda,context,RelationHistoryScope(upper,true)) ||
        return nothing
    # Wider confirmed histories only refine equivalence classes. Search the
    # observed range for the first separation without manufacturing a prefix.
    while lower < upper
        middle = lower + (upper-lower)÷2
        if compatible_frontier_history(search,agenda,context,RelationHistoryScope(middle,true))
            upper = middle
        else
            lower = middle+1
        end
    end
    actions = RelationHistoryScope(lower,false)
    if !old.receipts && lower > old.width && compatible_frontier_history(search,agenda,context,actions)
        return actions
    end
    return RelationHistoryScope(lower,true)
end

function frontier_response_matrix(search,agenda,context)
    visits = get(search.visits,context,Int[])
    histories = unique([relation_history_key(agenda,context,agenda.samples[i].preceding) for i in visits])
    actions = PublicActionKey[]
    rows = map(histories) do past
        observed = search.outcomes[(context,past)]
        row_actions = sort!(collect(keys(observed)))
        union!(actions,row_actions)
        cells = map(row_actions) do action
            samples = [agenda.samples[i] for i in observed[action]]
            outcomes = unique([frontier_outcome(row) for row in samples])
            status = length(outcomes) == 1 ? :observed : :conflict
            reads = unique([ref for row in samples for ref in relation_refs(row)])
            (;action,status,outcomes,reads)
        end
        (;history=past,cells)
    end
    available_actions = isempty(visits) ? Int[] : agenda.samples[first(visits)].available
    scope = history_scope(agenda,context)
    return (;context,scope.width,scope.receipts,actions=sort!(actions),available_actions,
        coordinate_domain=6 in available_actions ? 4096 : 0,unrecorded_response=:unknown,rows)
end

function frontier_history_probe(search,agenda,obs,context)
    scope = history_scope(agenda,context)
    refined_history(scope) || return nothing
    live = frontier_state(agenda,context,agenda.previous)
    tried = get(search.outcomes,live,nothing)
    for index in get(search.visits,context,Int[])
        row = agenda.samples[index]
        action = action_key(row.effects.action)
        (first(action) in obs.available_actions && (isnothing(tried) || !haskey(tried,action))) || continue
        witnessed = frontier_state(agenda,context,row.preceding)
        witnessed == live && continue
        samples = search.outcomes[witnessed][action]
        all(i->frontier_outcome(agenda.samples[i]) == frontier_outcome(row),samples) || continue
        live_reads = relation_ref.(agenda.samples[frontier_prior(agenda,agenda.previous,scope.width)])
        history_reads = relation_ref.(agenda.samples[frontier_prior(agenda,row.preceding,scope.width)])
        reads = unique([live_reads;history_reads;relation_refs(row)])
        obligation = (;context,current=last(live),comparison=last(witnessed),
            action=concrete_action(action),source=relation_ref(row),answer="unknown",
            observed_response=frontier_outcome(row),scope="observed_history_matrix")
        return (;action=concrete_action(action),intent=:test_history_response,tests=NamedTuple[],reads,obligation)
    end
    return nothing
end

function frontier_observe!(search,agenda)
    index = length(agenda.samples)
    row = agenda.samples[index]
    context = row.context
    options = get!(Vector{PublicActionKey},search.options,context)
    key = action_key(row.effects.action)
    key in options || push!(options,key)
    all_visits = push!(get!(Vector{Int},search.visits,context),index)
    bucket = index_frontier_observation!(search,agenda,index)
    context in search.unresolved && return nothing
    contrasted = first(bucket)
    frontier_outcome(agenda.samples[contrasted]) == frontier_outcome(row) && return nothing
    old = history_scope(agenda,context)
    candidates = [RelationHistoryScope(width,receipts) for receipts in (false,true)
        for width in search.allowed_widths if width >= old.width &&
        ((receipts == old.receipts && width > old.width) || (receipts && !old.receipts))]
    usable = findfirst(scope->compatible_frontier_history(search,agenda,context,scope),candidates)
    refined = isnothing(usable) ? extended_frontier_history(search,agenda,context,old) : candidates[usable]
    scope = something(refined,old)
    if isnothing(refined)
        push!(search.unresolved,context)
    else
        agenda.history_scopes[context] = scope
        filter!(pair->first(first(pair)) != context,search.outcomes)
        for past in all_visits
            index_frontier_observation!(search,agenda,past)
        end
    end
    histories = [relation_ref.(agenda.samples[frontier_prior(agenda,agenda.samples[i].preceding,scope.width)])
        for i in (contrasted,index)]
    matrix = frontier_response_matrix(search,agenda,context)
    return (;context,before_width=old.width,before_receipts=old.receipts,scope.width,scope.receipts,
        history_reads=histories,response_matrix=matrix,
        evidence=relation_ref.(agenda.samples[[contrasted,index]]),
        status=isnothing(refined) ? "unresolved" : "refined")
end

function frontier_untried(search,node)
    options = get(search.options,first(node),PublicActionKey[])
    tried = get(search.outcomes,node,nothing)
    return isnothing(tried) ? options : filter(key->!haskey(tried,key),options)
end

function frontier_new_configuration(search,node,available)
    tried = get(search.outcomes,node,nothing)
    untried(key) = isnothing(tried) || !haskey(tried,key)
    for id in available
        id == 6 && continue
        key = (id,-1,-1)
        untried(key) && return key
    end
    if 6 in available
        for index in 0:4095
            x,y = spatial_probe_point(index)
            key = (6,x,y)
            untried(key) && return key
        end
    end
    return nothing
end

function frontier_successor(agenda,indices)
    next = frontier_state(agenda,agenda.samples[first(indices)].next_context,first(indices))
    for index in indices
        row = agenda.samples[index]
        row.state == "NOT_FINISHED" && !row.advanced &&
            frontier_state(agenda,row.next_context,index) == next || return nothing
    end
    return next
end

function frontier_path(search,agenda,start)
    queue = FrontierState[start]
    parents = Dict{FrontierState,Union{Nothing,Tuple{FrontierState,Int}}}(start=>nothing)
    for node in queue
        if node != start
            untried = frontier_untried(search,node)
            if !isempty(untried)
                route = Int[]
                cursor = node
                while cursor != start
                    cursor,index = parents[cursor]
                    push!(route,index)
                end
                return (;route=reverse!(route),target=node,experiment=first(untried))
            end
        end
        outcomes = get(search.outcomes,node,nothing)
        isnothing(outcomes) && continue
        for key in get(search.options,first(node),PublicActionKey[])
            indices = get(outcomes,key,nothing)
            isnothing(indices) && continue
            successor = frontier_successor(agenda,indices)
            (isnothing(successor) || haskey(parents,successor)) && continue
            parents[successor] = (node,last(indices))
            push!(queue,successor)
        end
    end
    return nothing
end

function frontier_route_step(search,agenda,obs,node,route,preferred,history_reads)
    path = relation_ref.(agenda.samples[route.steps])
    plan_refs = unique([ref for index in route.steps for ref in relation_refs(agenda.samples[index])])
    reads = unique([history_reads;plan_refs])
    target,experiment = first(route.target),concrete_action(route.experiment)
    if route.cursor > length(route.steps)
        node == route.target && route.experiment in frontier_untried(search,node) &&
            first(route.experiment) in obs.available_actions || return nothing
        obligation = (;target,source="reachable_frontier_obligation",path,baseline=preferred)
        return (;action=experiment,intent=:distinguish_public_frontier,tests=NamedTuple[],reads,obligation)
    end
    index = route.steps[route.cursor]
    edge = agenda.samples[index]
    action = edge.effects.action
    frontier_state(agenda,edge.context,edge.preceding) == node && action["id"] in obs.available_actions ||
        return nothing
    observed = get(get(search.outcomes,node,Dict()),action_key(action),nothing)
    isnothing(observed) && return nothing
    expected = frontier_state(agenda,edge.next_context,index)
    frontier_successor(agenda,observed) == expected || return nothing
    obligation = (;expected=edge.next_context,advanced=false,target,future_experiment=experiment,
        path,step=route.cursor,baseline=preferred)
    return (;action,intent=:explore_observed_frontier_path,tests=NamedTuple[],reads,obligation,route)
end

function confirm_frontier_route!(search,agenda,proposal)
    previous = search.route
    search.route = nothing
    if isnothing(proposal) || !hasproperty(proposal,:route)
        return isnothing(previous) ? nothing : (;status=:released,step=previous.cursor)
    end
    route = proposal.route
    expected_index = route.steps[route.cursor]
    observed_index = length(agenda.samples)
    expected,observed = agenda.samples[expected_index],agenda.samples[observed_index]
    matches = observed.effects.action == expected.effects.action &&
        frontier_outcome(observed) == frontier_outcome(expected) &&
        frontier_state(agenda,observed.context,observed.preceding) ==
            frontier_state(agenda,expected.context,expected.preceding) &&
        frontier_state(agenda,observed.next_context,observed_index) ==
            frontier_state(agenda,expected.next_context,expected_index)
    matches || return (;status=:withdrawn,step=route.cursor)
    search.route = FrontierRoute(route.steps,route.cursor+1,route.target,route.experiment)
    return (;status=:confirmed,step=route.cursor,next=search.route.cursor)
end

function frontier_choice(search,agenda,obs,decision,intervention,preferred)
    context = relation_context(obs)
    node = frontier_state(agenda,context,agenda.previous)
    frontier_options!(search,context,decision.ranked,intervention)
    live_history = frontier_prior(agenda,agenda.previous,history_scope(agenda,context).width)
    history_reads = relation_ref.(agenda.samples[live_history])
    if !isnothing(search.route)
        next = frontier_route_step(search,agenda,obs,node,search.route,preferred,history_reads)
        isnothing(next) || return next
    end
    repeated = get(get(search.outcomes,node,Dict()),action_key(preferred),nothing)
    isnothing(repeated) && return nothing
    latest = agenda.samples[last(repeated)]
    # Preserve repeated actions backed by a newly observed transition. Search a
    # different branch when the planned action already led to a known state.
    successor = frontier_successor(agenda,repeated)
    (latest.advanced || !isnothing(successor) && successor != node &&
        !haskey(search.outcomes,successor)) && return nothing

    untried = frontier_untried(search,node)
    if !isempty(untried)
        obligation = (previous=relation_ref(latest),baseline=preferred,context)
        return (;action=concrete_action(first(untried)),intent=:distinguish_public_frontier,
            tests=NamedTuple[],reads=unique([history_reads;relation_refs(latest)]),obligation)
    end
    found = frontier_path(search,agenda,node)
    if isnothing(found)
        fresh = frontier_new_configuration(search,node,obs.available_actions)
        isnothing(fresh) && return nothing
        obligation = (previous=relation_ref(latest),baseline=preferred,context,
            source="untried_public_configuration")
        return (;action=concrete_action(fresh),intent=:distinguish_public_frontier,
            tests=NamedTuple[],reads=unique([history_reads;relation_refs(latest)]),obligation)
    end
    route = FrontierRoute(found.route,1,found.target,found.experiment)
    return frontier_route_step(search,agenda,obs,node,route,preferred,history_reads)
end
