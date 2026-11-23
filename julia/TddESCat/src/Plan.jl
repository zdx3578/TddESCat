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

function solve_policy(model::PlanningModel{S,A,O},belief,goal;depth,max_work) where {S,A,O}
    depth >= 0 && positive_integer(max_work) || throw(ArgumentError("Invalid policy budget"))
    issubset(belief,model.states) && issubset(goal,model.states) ||
        throw(ArgumentError("Policy query is outside the model"))
    used = Ref(0)
    cache = Dict()
    function solve(selected,remaining)
        isempty(selected) && return (status="belief_needs_revision",policy=nothing)
        if issubset(selected,goal)
            return (status="achieved",policy=PolicyNode{S,A,O}(copy(selected),nothing,Dict(),Dict()))
        end
        remaining == 0 && return (status="depth_limit",policy=nothing)
        key = (Set(selected),remaining)
        haskey(cache,key) && return cache[key]
        uncertain = false
        for action in sort!(collect(common_actions(model,selected));by=repr)
            used[] >= max_work && return (status="work_limit",policy=nothing)
            used[] += 1
            predicted = observable_successors(model,selected,action)
            if !predicted.complete
                uncertain = true
                continue
            end
            branches = Dict{O,PolicyNode{S,A,O}}()
            reads = Dict(ref=>model.versions[ref] for ref in predicted.dependencies)
            for label in sort!(collect(keys(predicted.branches));by=repr)
                downstream = solve(predicted.branches[label],remaining-1)
                if isnothing(downstream.policy)
                    uncertain |= downstream.status != "no_policy_in_scope"
                    break
                end
                branches[label] = downstream.policy
                merge!(reads,downstream.policy.dependencies)
            end
            if length(branches) == length(predicted.branches) && !isempty(branches)
                found = (status="policy",policy=PolicyNode{S,A,O}(copy(selected),action,branches,reads))
                cache[key] = found
                return found
            end
        end
        result = (status=uncertain ? "incomplete" : "no_policy_in_scope",policy=nothing)
        if !uncertain
            cache[key] = result
        end
        return result
    end
    result = solve(Set{S}(belief),depth)
    return merge(result,(;work=used[]))
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

function propose_condition_plan(item,config,command)
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
        Dict(0=>false,1=>false,2=>true);max_work=config["max_work"])
    projection.sufficient || return nothing
    planned = solve_policy(model,Set([0]),Set([2]);depth=config["depth"],max_work=config["max_work"])
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
