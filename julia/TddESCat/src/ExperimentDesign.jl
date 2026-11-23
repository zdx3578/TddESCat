function distinguish_predictions(predictions; max_work)
    positive_integer(max_work) || throw(ArgumentError("Invalid experiment budget"))
    witnesses = []
    separated = 0
    work = 0
    for left in eachindex(predictions), right in left+1:length(predictions)
        first, second = predictions[left],predictions[right]
        queries = sort!(collect(intersect(keys(first),keys(second))))
        work == max_work && return (;witnesses,separated,complete=false,work)
        work += 1
        for key in queries
            work == max_work && return (;witnesses,separated,complete=false,work)
            work += 1
            a,b = first[key],second[key]
            (isnothing(a) || isnothing(b) || a === unknown_truth || b === unknown_truth) && continue
            isequal(a,b) && continue
            push!(witnesses,(;left,right,query=key,values=[a,b]))
            separated += 1
            break
        end
    end
    return (;witnesses,separated,complete=true,work)
end
