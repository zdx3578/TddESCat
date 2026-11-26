struct SuccessorScope{S}
    states::Set{S}
    domain::Truth
    complete::Bool
    dependencies::Set{String}
end

struct PlanningModel{S,A,O}
    states::Set{S}
    enabled::Dict{S,Set{A}}
    effects::Dict{Tuple{S,A},SuccessorScope{S}}
    observations::Dict{S,Set{O}}
    versions::Dict{String,String}
end

struct PolicyNode{S,A,O}
    belief::Set{S}
    action::Union{Nothing,A}
    branches::Dict{O,PolicyNode{S,A,O}}
    dependencies::Dict{String,String}
end

function common_actions(model::PlanningModel{S,A,O},belief) where {S,A,O}
    isempty(belief) && return Set{A}()
    return reduce(intersect,(get(model.enabled,state,Set{A}()) for state in belief))
end

function observable_successors(model::PlanningModel{S,A,O},belief,action) where {S,A,O}
    observations = Dict{O,Set{S}}()
    reads = Set{String}()
    action in common_actions(model,belief) ||
        return (branches=observations,complete=false,reason="action_unavailable",dependencies=reads)
    for state in belief
        scope = get(model.effects,(state,action),nothing)
        if isnothing(scope) || scope.domain != proven || !scope.complete || isempty(scope.states)
            return (branches=observations,complete=false,reason="unknown_successor_scope",dependencies=reads)
        end
        issubset(scope.states,model.states) || error("Successor escaped model scope")
        union!(reads,scope.dependencies)
        for successor in scope.states
            labels = get(model.observations,successor,Set{O}())
            isempty(labels) && return (branches=observations,complete=false,
                reason="unknown_observation",dependencies=reads)
            for label in labels
                push!(get!(Set{S},observations,label),successor)
            end
        end
    end
    return (branches=observations,complete=true,reason="exhausted",dependencies=reads)
end

function solve_policy(model::PlanningModel{S,A,O},belief,goal;depth=nothing,max_work=nothing) where {S,A,O}
    (isnothing(depth) || strict_integer(depth) && depth >= 0) &&
        (isnothing(max_work) || positive_integer(max_work)) || throw(ArgumentError("Invalid policy query limit"))
    issubset(belief,model.states) && issubset(goal,model.states) ||
        throw(ArgumentError("Policy query is outside the model"))
    isempty(belief) && return (status="belief_needs_revision",policy=nothing,work=0)
    if isnothing(depth) && isnothing(max_work)
        determined = policy_from_deterministic_plan(model,belief,goal)
        isnothing(determined) || return determined
    end

    beliefs = [Set{S}(belief)]
    ids = Dict(first(beliefs)=>1)
    edges = Vector{NamedTuple}[NamedTuple[]]
    goals = Set{Int}()
    missing = false
    interrupted = false
    work = 0
    index = 1
    while index <= length(beliefs)
        selected = beliefs[index]
        if issubset(selected,goal)
            push!(goals,index)
        else
            for action in sort!(collect(common_actions(model,selected));by=repr)
                if work == max_work
                    interrupted = true
                    break
                end
                work += 1
                successor = observable_successors(model,selected,action)
                if !successor.complete
                    missing = true
                    continue
                end
                children = Dict{O,Int}()
                for label in sort!(collect(keys(successor.branches));by=repr)
                    states = successor.branches[label]
                    children[label] = get!(ids,states) do
                        push!(beliefs,states)
                        push!(edges,NamedTuple[])
                        length(beliefs)
                    end
                end
                push!(edges[index],(;action,children,dependencies=successor.dependencies))
            end
        end
        index += 1
    end

    nodes = Dict(i=>PolicyNode{S,A,O}(beliefs[i],nothing,Dict(),Dict()) for i in goals)
    ranks = Dict(i=>0 for i in goals)
    while !haskey(nodes,1)
        discovered = Dict{Int,Tuple{Int,PolicyNode{S,A,O}}}()
        for i in eachindex(beliefs)
            haskey(nodes,i) && continue
            available = filter(edge->!isempty(edge.children) &&
                all(haskey(nodes,j) for j in values(edge.children)),edges[i])
            isempty(available) && continue
            edge = argmin(edge->(maximum(j->ranks[j],values(edge.children)),repr(edge.action)),available)
            rank = 1 + maximum(j->ranks[j],values(edge.children))
            branches = Dict(label=>nodes[j] for (label,j) in edge.children)
            reads = Dict(ref=>model.versions[ref] for ref in edge.dependencies)
            for node in values(branches)
                merge!(reads,node.dependencies)
            end
            discovered[i] = (rank,PolicyNode{S,A,O}(beliefs[i],edge.action,branches,reads))
        end
        isempty(discovered) && break
        for (i,(rank,node)) in discovered
            ranks[i] = rank
            nodes[i] = node
        end
    end

    if haskey(nodes,1)
        !isnothing(depth) && ranks[1] > depth &&
            return (status="depth_limit",policy=nothing,work)
        return (status=ranks[1] == 0 ? "achieved" : "policy",policy=nodes[1],work,rank=ranks[1])
    end
    status = interrupted ? "work_limit" : missing ? "incomplete" : "no_policy_in_scope"
    return (;status,policy=nothing,work)
end

function revalidate_policy(model,node,current_belief)
    isempty(current_belief) && return "belief_needs_revision"
    issubset(current_belief,node.belief) || return "belief_changed"
    all(get(model.versions,key,nothing)==value for (key,value) in node.dependencies) ||
        return "dependency_changed"
    isnothing(node.action) && return "achieved"
    parts = observable_successors(model,current_belief,node.action)
    parts.complete || return parts.reason
    all(haskey(node.branches,label) && issubset(states,node.branches[label].belief)
        for (label,states) in parts.branches) || return "successors_changed"
    return "ready"
end

function continue_policy(model,node,label,current_belief)
    child = get(node.branches,label,nothing)
    isnothing(child) && return (status="unpredicted_observation",policy=nothing)
    status = revalidate_policy(model,child,current_belief)
    return (status,policy=status in ("ready","achieved") ? child : nothing)
end

mutable struct DependencyIndex
    readers::Dict{String,Set{String}}
    invalid::Set{String}
end

DependencyIndex() = DependencyIndex(Dict(),Set())

function track_reads!(index::DependencyIndex,consumer,reads)
    for ref in reads
        push!(get!(Set{String},index.readers,ref),consumer)
    end
    return consumer
end

function invalidate_dependents!(index::DependencyIndex,changed)
    queue = collect(String,changed)
    seen = Set{String}()
    while !isempty(queue)
        ref = pop!(queue)
        ref in seen && continue
        push!(seen,ref)
        append!(queue,get(index.readers,ref,Set{String}()))
    end
    union!(index.invalid,seen)
    return sort!(collect(seen))
end

function propose_condition_plan(item,command)
    target = item.follow
    support = item.chosen.model
    first,second = action_key(item.action),action_key(target.action)
    helper_id, target_id = support.rule.id,target.model.rule.id
    versions = Dict(helper_id=>active_id(support),target_id=>active_id(target.model))
    A = typeof(first)
    domain = Set(0:2)
    available = Dict(0=>Set([first]),1=>Set([second]),2=>Set{A}())
    forward = Dict((0,first)=>SuccessorScope(Set([1]),proven,true,Set([helper_id])),
        (1,second)=>SuccessorScope(Set([2]),proven,true,Set([target_id])))
    model = PlanningModel(domain,available,forward,
        Dict(0=>Set(["condition_closed"]),1=>Set(["condition_observed"]),2=>Set(["bounded_effect"])),versions)
    projection = factor_query(Dict(0=>"condition_closed",1=>"condition_observed",2=>"bounded_effect"),
        Dict(0=>false,1=>false,2=>true);max_work=length(domain)^2)
    projection.sufficient || return nothing
    planned = solve_policy(model,Set([0]),Set([2]))
    isnothing(planned.policy) && return nothing
    return (; command,target,model,policy=planned.policy)
end

function recheck_condition_plan(knowledge,prior,current)
    successor = findfirst(item->item.action == prior.target.action &&
        !isnothing(item.chosen) && item.chosen.model.rule.id == prior.target.model.rule.id &&
        item.chosen.expected == prior.target.expected,current)
    isnothing(successor) && return (status="live_binding_unproved",item=nothing)
    versions = Dict(item.rule.id=>active_id(item) for item in knowledge.active)
    all(get(versions,key,nothing)==value for (key,value) in prior.policy.dependencies) ||
        return (status="dependency_changed",item=nothing)
    fresh = PlanningModel(prior.model.states,prior.model.enabled,prior.model.effects,
        prior.model.observations,versions)
    branch = continue_policy(fresh,prior.policy,"condition_observed",Set([1]))
    branch.status == "ready" || return (status=branch.status,item=nothing)
    return (status="ready",item=current[successor])
end
