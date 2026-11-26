const FrontierState = Tuple{String,PublicActionKey}

struct PublicFrontier
    options::Dict{FrontierState,Vector{PublicActionKey}}
    outcomes::Dict{FrontierState,Dict{PublicActionKey,Vector{Int}}}
end

PublicFrontier() = PublicFrontier(Dict(),Dict())

function frontier_options!(search,context,previous,ranked,intervention)
    node = (context,previous)
    candidates = PublicActionKey[action_key(row.action) for row in ranked]
    isnothing(intervention) || push!(candidates,action_key(intervention.action))
    options = get!(Vector{PublicActionKey},search.options,node)
    union!(options,candidates)
    return options
end

function frontier_observe!(search,agenda)
    index = length(agenda.samples)
    row = agenda.samples[index]
    node = (row.context,previous_key(agenda,row.preceding))
    outcomes = get!(Dict{PublicActionKey,Vector{Int}},search.outcomes,node)
    push!(get!(Vector{Int},outcomes,action_key(row.effects.action)),index)
    return nothing
end

function frontier_untried(search,node)
    options = get(search.options,node,PublicActionKey[])
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
    rows = @view agenda.samples[indices]
    first_row = first(rows)
    all(row->row.state == "NOT_FINISHED" && !row.advanced &&
        row.next_context == first_row.next_context,rows) || return nothing
    return (first_row.next_context,action_key(first_row.effects.action))
end

function frontier_path(search,agenda,start)
    queue = [start]
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
        for key in get(search.options,node,PublicActionKey[])
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

function frontier_choice(search,agenda,obs,decision,intervention,preferred)
    context = relation_context(obs)
    prior = previous_key(agenda,agenda.previous)
    node = (context,prior)
    frontier_options!(search,context,prior,decision.ranked,intervention)
    repeated = get(get(search.outcomes,node,Dict()),action_key(preferred),nothing)
    isnothing(repeated) && return nothing
    latest = agenda.samples[last(repeated)]
    # Preserve repeated actions backed by a newly observed transition. Search a
    # different branch when the planned action already led to a known state.
    successor = (latest.next_context,action_key(preferred))
    (latest.advanced || successor != node && !haskey(search.outcomes,successor)) && return nothing

    untried = frontier_untried(search,node)
    index = last(repeated)
    if !isempty(untried)
        obligation = (previous=relation_ref(latest),baseline=preferred,context)
        return (;action=concrete_action(first(untried)),intent=:distinguish_public_frontier,
            tests=NamedTuple[],reads=relation_refs(latest),obligation)
    end
    found = frontier_path(search,agenda,node)
    isnothing(found) && return nothing
    edge = agenda.samples[first(found.route)]
    plan_refs = unique([ref for i in found.route for ref in relation_refs(agenda.samples[i])])
    obligation = (expected=edge.next_context,advanced=false,target=first(found.target),
        future_experiment=concrete_action(found.experiment),path=relation_ref.(agenda.samples[found.route]),
        baseline=preferred)
    return (;action=edge.effects.action,intent=:explore_observed_frontier_path,
        tests=NamedTuple[],reads=plan_refs,obligation)
end
