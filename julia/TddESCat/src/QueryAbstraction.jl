function factor_query(partition, query; max_work)
    positive_integer(max_work) || throw(ArgumentError("Invalid query budget"))
    representatives = Dict()
    agreed = Dict()
    disagreements = Dict()
    unresolved = Set()
    work = 0
    for state in sort!(collect(keys(partition));by=repr)
        work == max_work && break
        work += 1
        group = partition[state]
        value = get(query,state,nothing)
        if isnothing(value) || value === unknown_truth
            push!(unresolved,group)
        elseif !haskey(agreed,group)
            agreed[group] = value
            representatives[group] = state
        elseif !isequal(value,agreed[group]) && !haskey(disagreements,group)
            disagreements[group] = (left=representatives[group],right=state,
                left_value=agreed[group],right_value=value)
        end
    end
    complete = work == length(partition)
    sufficient = complete && isempty(disagreements) && isempty(unresolved)
    return (; sufficient, complete, work, values=sufficient ? agreed : Dict(), disagreements, unresolved)
end

function refine_partition(model::PlanningModel{S,A,O}, partition, queries; max_work) where {S,A,O}
    Set(keys(partition)) == model.states || throw(ArgumentError("Partition does not cover model scope"))
    positive_integer(max_work) || throw(ArgumentError("Invalid refinement budget"))
    states = sort!(collect(model.states);by=repr)
    classes = Dict(partition)
    reads = Set{String}()
    unresolved = Set{S}()
    work = 0
    while true
        updated = Dict{S,Int}()
        signatures = Dict()
        for state in states
            enabled = sort!(collect(common_actions(model,Set([state])));by=repr)
            own = [get(query,state,nothing) for query in queries]
            any(item->isnothing(item) || item === unknown_truth,own) && push!(unresolved,state)
            successors = []
            for action in enabled
                work == max_work && return (;partition=classes,complete=false,
                    reason="work_limit",reads,unresolved,work)
                work += 1
                scope = observable_successors(model,Set([state]),action)
                if !scope.complete
                    push!(unresolved,state)
                    push!(successors,(action,scope.reason))
                    continue
                end
                union!(reads,scope.dependencies)
                outputs = Set((observation,classes[target])
                    for (observation,targets) in scope.branches for target in targets)
                push!(successors,(action,sort!(collect(outputs);by=repr)))
            end
            signature = (classes[state],Tuple(own),Tuple(successors))
            updated[state] = get!(signatures,signature,length(signatures)+1)
        end
        # Each signature preserves its prior class, so unchanged cardinality establishes stability.
        if length(signatures) == length(Set(values(classes)))
            return (;partition=updated,complete=isempty(unresolved),
                reason=isempty(unresolved) ? "stable" : "unknown_values",reads,unresolved,work)
        end
        classes = updated
    end
end

function check_causal_square(concrete::FiniteRelation, abstracted::FiniteRelation, partition, states)
    concrete.complete && abstracted.complete || return unknown_truth
    isempty(states) && return unknown_truth
    low = Set(partition[state] for state in post_image(concrete,states))
    high = post_image(abstracted, Set(partition[state] for state in states))
    return low == high ? proven : disproven
end
