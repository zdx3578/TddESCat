struct AssociationExample
    sample::MotionExample
    binding::MotionBinding
    verdict::Truth
end

struct AssociationIndex
    entries::Dict{String,AssociationExample}
    ports::Dict{Tuple{Int,String},Vector{String}}
    inverse_features::Dict{String,Set{String}}
end

AssociationIndex() = AssociationIndex(Dict(),Dict(),Dict())

function support_features(frame, subject; connectivity=4)
    components = color_components(frame,connectivity)
    groups, owner = components.groups, components.owner
    role(i) = "role-" * string(i)
    subject_index = findfirst(==(subject),groups)
    pairs = Set{Tuple{Int,Int}}()
    directions = connectivity == 4 ? FOUR_NEIGHBORS :
        [(dx,dy) for dx in -1:1 for dy in -1:1 if (dx,dy) != (0,0)]
    for y in axes(frame,1), x in axes(frame,2), (dx,dy) in directions
        xx, yy = x+dx,y+dy
        checkbounds(Bool,frame,yy,xx) || continue
        first, second = owner[y,x], owner[yy,xx]
        first != second && push!(pairs,(first,second))
    end
    adjacency = sort!(collect(pairs))
    labels = [semantic_hash(["support",connectivity,shape_template(shape)]) for shape in groups]
    previous = labels
    for _ in 1:2
        links = [String[] for _ in groups]
        for (source,target) in adjacency
            push!(links[source],previous[target])
        end
        previous = [semantic_hash([current,sort!(links[index])]) for (index,current) in enumerate(previous)]
    end
    hints = isnothing(subject_index) ? String[] : [labels[subject_index],previous[subject_index]]
    return (; subject=isnothing(subject_index) ? nothing : role(subject_index), hints,
        neighbor=[(role(a),role(b)) for (a,b) in adjacency],
        colors=[(role(i),Int(first(shape)[3])) for (i,shape) in enumerate(groups)])
end

association_port(example) =
    (example.sample.action,semantic_hash(["color-support",shape_template(example.binding.support)]))

function index_association!(index, example)
    ref = example.sample.event_id
    haskey(index.entries,ref) && error("Repeated intervention in association history")
    index.entries[ref] = example
    push!(get!(Vector{String},index.ports,association_port(example)),ref)
    support = support_features(example.sample.before,example.binding.support)
    for feature in support.hints
        push!(get!(Set{String},index.inverse_features,feature),ref)
    end
    return index
end

function recall_associations(index, current)
    port = association_port(current)
    template = shape_template(current.binding.support)
    candidates = filter(ref -> shape_template(index.entries[ref].binding.support) == template,
        get(index.ports,port,String[]))
    hints = support_features(current.sample.before,current.binding.support).hints
    sort!(candidates; by=ref->(-count(feature->ref in index.inverse_features[feature],hints),ref))
    return [index.entries[ref] for ref in candidates]
end
