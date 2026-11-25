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

function empirical_relation(values::Vector{Int}, outcomes::Vector{T}, witnesses) where T
    length(values) == length(outcomes) == length(witnesses) ||
        throw(ArgumentError("Empirical relation requires paired observations"))
    outputs = Dict{Int,T}()
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

function safe_precondition(relation, goal, enabled, known, completely_enumerated)
    nonempty = Set(x for (x,_) in keys(relation.evidence))
    relation.complete || return empty(copy(relation.source))
    return intersect(liberal_precondition(relation,goal),enabled,known,nonempty,completely_enumerated)
end

function compose_relations(left::FiniteRelation{S,T}, right::FiniteRelation{T,U}; max_work) where {S,T,U}
    right.source == left.target || throw(ArgumentError("Composition domains differ"))
    positive_integer(max_work) || throw(ArgumentError("Invalid relation work limit"))
    right_rows = Dict{T,Vector{Tuple{U,Set{String}}}}()
    for ((mid,out),refs) in right.evidence
        push!(get!(Vector{Tuple{U,Set{String}}},right_rows,mid),(out,refs))
    end
    relation = Dict{Tuple{S,U},Set{String}}()
    witnesses = Dict{Tuple{S,U},Set{T}}()
    work = 0
    complete = left.complete && right.complete
    stop = complete ? "exhausted" : "incomplete_input"
    for ((input,mid),first) in sort!(collect(left.evidence);by=entry->repr(entry.first))
        for (out,second) in get(right_rows,mid,Tuple{U,Set{String}}[])
            if work >= max_work
                return (relation=FiniteRelation(left.source,right.target,relation,false),witnesses,
                    complete=false,stop_reason="work_limit",work)
            end
            work += 1
            key = (input,out)
            union!(get!(Set{String},relation,key),first,second)
            push!(get!(Set{T},witnesses,key),mid)
        end
    end
    return (relation=FiniteRelation(left.source,right.target,relation,complete),witnesses,
        complete,stop_reason=stop,work)
end
