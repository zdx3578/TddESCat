import Galley

const GALLEY_QUERY_LOCK = ReentrantLock()
const GALLEY_JOIN_SCHEDULER = Galley.galley_scheduler(;cache=true)

function indexed_join_pairs(left_keys,right_keys)
    postings = Dict{Tuple,Vector{Int}}()
    for (index,key) in enumerate(right_keys)
        push!(get!(Vector{Int},postings,key),index)
    end
    absent = Int[]
    return [(i,j) for (i,key) in enumerate(left_keys) for j in get(postings,key,absent)]
end

function exact_join_pairs(left_keys,right_keys)
    # Tiny relations can stay in their ordered logical columns without
    # constructing and lowering sparse tensors for an equality join.
    if max(length(left_keys),length(right_keys)) <= 32
        return indexed_join_pairs(left_keys,right_keys)
    end
    return galley_join_pairs(left_keys,right_keys)
end

"""Return exact row pairs for an equality join over externally encoded keys."""
function galley_join_pairs(left_keys::AbstractVector{<:Tuple}, right_keys::AbstractVector{<:Tuple})
    (isempty(left_keys) || isempty(right_keys)) && return Tuple{Int,Int}[]
    keys = Dict{Tuple,Int}()
    code(key) = get!(() -> length(keys)+1,keys,key)
    left_codes, right_codes = code.(left_keys), code.(right_keys)
    function indicator(codes)
        return Galley.fsparse(collect(eachindex(codes)),codes,fill(true,length(codes)),
            (length(codes),length(keys)),|;fill_value=false)
    end
    left = Galley.lazy(indicator(left_codes))
    right = Galley.lazy(indicator(right_codes))
    contraction = Galley.tensordot(left,right,((2,),(2,));mult_op=(&),add_op=(|),init=false)
    tensor = lock(GALLEY_QUERY_LOCK) do
        Galley.compute(contraction;ctx=GALLEY_JOIN_SCHEDULER)
    end
    size(tensor) == (length(left_keys),length(right_keys)) || error("Galley returned an invalid join domain")
    left_rows,right_rows,data = Galley.ffindnz(tensor)
    pairs = Tuple{Int,Int}[]
    for (l,r,matched) in zip(left_rows,right_rows,data)
        matched || continue
        left_keys[l] == right_keys[r] || error("Galley returned an invalid join witness")
        push!(pairs,(l,r))
    end
    return pairs
end
