const FrontierState = Tuple{String,Tuple}

struct PublicFrontier
    options::Dict{String,Vector{PublicActionKey}}
    outcomes::Dict{FrontierState,Dict{PublicActionKey,Vector{Int}}}
    visits::Dict{String,Vector{Int}}
    history_widths::Dict{String,Int}
    allowed_widths::Vector{Int}
    unresolved::Set{String}
end

PublicFrontier(widths=[1,2,4]) = PublicFrontier(Dict(),Dict(),Dict(),Dict(),
    sort!(unique([1;filter(>(1),widths)])),Set())

function frontier_prior(agenda,index,width)
    collected = Int[]
    while index != 0 && length(collected) < width
        push!(collected,index)
        index = agenda.samples[index].preceding
    end
    return reverse!(collected)
end

function frontier_state(search,agenda,context,index; width=get(search.history_widths,context,1))
    prior = frontier_prior(agenda,index,width)
    return (context,Tuple(action_key(agenda.samples[i].effects.action) for i in prior))
end

function frontier_options!(search,context,ranked,intervention)
    candidates = PublicActionKey[action_key(row.action) for row in ranked]
    isnothing(intervention) || push!(candidates,action_key(intervention.action))
    options = get!(Vector{PublicActionKey},search.options,context)
    union!(options,candidates)
    return options
end

function index_frontier_observation!(search,agenda,index)
    row = agenda.samples[index]
    node = frontier_state(search,agenda,row.context,row.preceding)
    outcomes = get!(Dict{PublicActionKey,Vector{Int}},search.outcomes,node)
    return push!(get!(Vector{Int},outcomes,action_key(row.effects.action)),index)
end

frontier_outcome(row) = (row.next_context,row.state,row.advanced)

function compatible_frontier_history(search,agenda,context,width)
    responses = Dict{Tuple,Tuple}()
    for index in search.visits[context]
        row = agenda.samples[index]
        state = frontier_state(search,agenda,context,row.preceding;width)
        key = (last(state),action_key(row.effects.action))
        outcome = frontier_outcome(row)
        get!(responses,key,outcome) == outcome || return false
    end
    return true
end

function frontier_observe!(search,agenda)
    index = length(agenda.samples)
    row = agenda.samples[index]
    context = row.context
    all_visits = push!(get!(Vector{Int},search.visits,context),index)
    bucket = index_frontier_observation!(search,agenda,index)
    context in search.unresolved && return nothing
    contrasted = first(bucket)
    frontier_outcome(agenda.samples[contrasted]) == frontier_outcome(row) && return nothing
    old = get(search.history_widths,context,1)
    usable = findfirst(width->width > old &&
        compatible_frontier_history(search,agenda,context,width),search.allowed_widths)
    width = isnothing(usable) ? old : search.allowed_widths[usable]
    if isnothing(usable)
        push!(search.unresolved,context)
    else
        search.history_widths[context] = width
        filter!(pair->first(first(pair)) != context,search.outcomes)
        for past in all_visits
            index_frontier_observation!(search,agenda,past)
        end
    end
    histories = [relation_ref.(agenda.samples[frontier_prior(agenda,agenda.samples[i].preceding,width)])
        for i in (contrasted,index)]
    return (;context,before_width=old,width,history_reads=histories,
        evidence=relation_ref.(agenda.samples[[contrasted,index]]),
        status=isnothing(usable) ? "unresolved" : "refined")
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

function frontier_successor(search,agenda,indices)
    next = frontier_state(search,agenda,agenda.samples[first(indices)].next_context,first(indices))
    for index in indices
        row = agenda.samples[index]
        row.state == "NOT_FINISHED" && !row.advanced &&
            frontier_state(search,agenda,row.next_context,index) == next || return nothing
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
            successor = frontier_successor(search,agenda,indices)
            (isnothing(successor) || haskey(parents,successor)) && continue
            parents[successor] = (node,last(indices))
            push!(queue,successor)
        end
    end
    return nothing
end

function frontier_choice(search,agenda,obs,decision,intervention,preferred)
    context = relation_context(obs)
    node = frontier_state(search,agenda,context,agenda.previous)
    frontier_options!(search,context,decision.ranked,intervention)
    repeated = get(get(search.outcomes,node,Dict()),action_key(preferred),nothing)
    isnothing(repeated) && return nothing
    latest = agenda.samples[last(repeated)]
    # Preserve repeated actions backed by a newly observed transition. Search a
    # different branch when the planned action already led to a known state.
    successor = frontier_successor(search,agenda,repeated)
    (latest.advanced || !isnothing(successor) && successor != node &&
        !haskey(search.outcomes,successor)) && return nothing

    untried = frontier_untried(search,node)
    live_history = frontier_prior(agenda,agenda.previous,get(search.history_widths,context,1))
    history_reads = relation_ref.(agenda.samples[live_history])
    if !isempty(untried)
        obligation = (previous=relation_ref(latest),baseline=preferred,context)
        return (;action=concrete_action(first(untried)),intent=:distinguish_public_frontier,
            tests=NamedTuple[],reads=unique([history_reads;relation_refs(latest)]),obligation)
    end
    found = frontier_path(search,agenda,node)
    isnothing(found) && return nothing
    edge = agenda.samples[first(found.route)]
    plan_refs = unique([ref for i in found.route for ref in relation_refs(agenda.samples[i])])
    obligation = (expected=edge.next_context,advanced=false,target=first(found.target),
        future_experiment=concrete_action(found.experiment),path=relation_ref.(agenda.samples[found.route]),
        baseline=preferred)
    return (;action=edge.effects.action,intent=:explore_observed_frontier_path,
        tests=NamedTuple[],reads=unique([history_reads;plan_refs]),obligation)
end
