struct FiniteRelation{S,T}
    source::Set{S}
    target::Set{T}
    evidence::Dict{Tuple{S,T},Set{String}}
    complete::Bool
end

function finite_relation(source, target, rows; complete=true)
    from, to = Set(source), Set(target)
    evidence = Dict{Tuple{eltype(from),eltype(to)},Set{String}}()
    for (x,y,refs) in rows
        x in from && y in to || throw(ArgumentError("Relation row is outside its typed domain"))
        union!(get!(Set{String},evidence,(x,y)),refs)
    end
    return FiniteRelation(from,to,evidence,complete)
end

function post_image(relation::FiniteRelation, subset)
    issubset(subset,relation.source) || throw(ArgumentError("Post input is outside the relation domain"))
    return Set(y for (x,y) in keys(relation.evidence) if x in subset)
end

function empirical_relation(values::Vector{S}, outcomes::Vector{T}, witnesses) where {S,T}
    length(values) == length(outcomes) == length(witnesses) ||
        throw(ArgumentError("Empirical relation requires paired observations"))
    outputs = Dict{S,T}()
    for (value,outcome) in zip(values,outcomes)
        get!(outputs,value,outcome) == outcome || return nothing
    end
    return finite_relation(values,outcomes,zip(values,outcomes,witnesses);complete=false)
end

function empirical_successor(relation::FiniteRelation, input)
    input in relation.source || return nothing
    outputs = post_image(relation,(input,))
    length(outputs) == 1 || return nothing
    return only(outputs)
end

function liberal_precondition(relation::FiniteRelation, goal)
    issubset(goal,relation.target) || throw(ArgumentError("Precondition goal is outside the relation range"))
    return setdiff(relation.source, Set(x for (x,y) in keys(relation.evidence) if y ∉ goal))
end

function possible_precondition(relation::FiniteRelation, goal, enabled, known)
    issubset(goal,relation.target) || throw(ArgumentError("Precondition goal is outside the relation range"))
    return Set(x for (x,y) in keys(relation.evidence) if x in enabled && x in known && y in goal)
end

function safe_precondition(relation::FiniteRelation, goal, enabled, known, completely_enumerated)
    nonempty = Set(x for (x,_) in keys(relation.evidence))
    relation.complete || return empty(copy(relation.source))
    return intersect(liberal_precondition(relation,goal),enabled,known,nonempty,completely_enumerated)
end

function safe_precondition(composition::NamedTuple, goal, enabled, known, completely_enumerated)
    return intersect(liberal_precondition(composition.relation,goal),enabled,known,
        completely_enumerated,composition.execution_complete)
end

function normalized_probability_total(weights)
    isempty(weights) && return nothing
    all(p->p isa Real && !(p isa Bool) && isfinite(p) && 0 <= p <= 1,weights) || return nothing
    total = sum(weights)
    normalized = total isa AbstractFloat ? isapprox(total,one(total);rtol=0,atol=1e-6) : isone(total)
    return normalized ? total : nothing
end

function probability_precondition(relation::FiniteRelation, goal, enabled, known, completely_enumerated, distributions)
    issubset(goal,relation.target) || throw(ArgumentError("Precondition goal is outside the relation range"))
    eligible = intersect(relation.source,enabled,known,completely_enumerated)
    targets = Dict(x=>Set{eltype(relation.target)}() for x in eligible)
    for (x,y) in keys(relation.evidence)
        x in eligible && push!(targets[x],y)
    end
    mass = Dict{eltype(relation.source),Real}()
    for input in eligible
        weights = get(distributions,input,nothing)
        isnothing(weights) && continue
        Set(keys(weights)) == targets[input] || continue
        total = normalized_probability_total(values(weights))
        isnothing(total) && continue
        mass[input] = sum((p for (y,p) in weights if y in goal);init=zero(total))/total
    end
    return (;mass,unresolved=setdiff(intersect(relation.source,enabled),keys(mass)))
end

function compose_relations(left::FiniteRelation{S,T}, right::FiniteRelation{T,U}; max_work,
                           guard=nothing) where {S,T,U}
    right.source == left.target || throw(ArgumentError("Composition domains differ"))
    positive_integer(max_work) || throw(ArgumentError("Invalid relation work limit"))
    right_rows = Dict{T,Vector{Tuple{U,Set{String}}}}()
    for ((mid,out),refs) in right.evidence
        push!(get!(Vector{Tuple{U,Set{String}}},right_rows,mid),(out,refs))
    end
    relation = Dict{Tuple{S,U},Set{String}}()
    witnesses = Dict{Tuple{S,U},Set{T}}()
    blocked = Dict{S,Set{T}}()
    unresolved = Dict{S,Set{T}}()
    reachable = Set{S}()
    execution_complete = Set{S}()
    work = 0
    complete = left.complete && right.complete
    stop = complete ? "exhausted" : "incomplete_input"
    for ((input,mid),first) in sort!(collect(left.evidence);by=entry->repr(entry.first))
        push!(reachable,input)
        allowed = isnothing(guard) ? proven : get(guard,mid,unknown_truth)
        if allowed == disproven
            push!(get!(Set{T},blocked,input),mid)
            continue
        elseif allowed != proven
            push!(get!(Set{T},unresolved,input),mid)
            complete = false
            stop = "incomplete_input"
            continue
        end
        rows = get(right_rows,mid,Tuple{U,Set{String}}[])
        if !right.complete
            push!(get!(Set{T},unresolved,input),mid)
        elseif isempty(rows)
            push!(get!(Set{T},blocked,input),mid)
        end
        for (out,second) in rows
            if work >= max_work
                return (relation=FiniteRelation(left.source,right.target,relation,false),witnesses,
                    blocked,unresolved,execution_complete,complete=false,stop_reason="work_limit",work)
            end
            work += 1
            key = (input,out)
            union!(get!(Set{String},relation,key),first,second)
            push!(get!(Set{T},witnesses,key),mid)
        end
    end
    if left.complete
        union!(execution_complete,setdiff(reachable,keys(blocked),keys(unresolved)))
    end
    return (relation=FiniteRelation(left.source,right.target,relation,complete),witnesses,
        blocked,unresolved,execution_complete,complete,stop_reason=stop,work)
end
