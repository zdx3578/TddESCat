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

function full_region_members(frame,subject,groups,owner)
    allunique(subject) || return nothing
    members = BitSet()
    for (x,y,color) in subject
        checkbounds(Bool,frame,y+1,x+1) && frame[y+1,x+1] == color || return nothing
        push!(members,owner[y+1,x+1])
    end
    isempty(members) && return nothing
    sum(i->length(groups[i]),members) == length(subject) || return nothing
    return members
end

function support_features(frame, subject; connectivity=4)
    components = color_components(frame,connectivity)
    groups, owner = components.groups, components.owner
    role(i) = "role-" * string(i)
    subject_index = findfirst(==(subject),groups)
    region_roles = collect(eachindex(groups))
    if isnothing(subject_index)
        members = full_region_members(frame,subject,groups,owner)
        if !isnothing(members)
            if length(members) == 1
                subject_index = only(members)
            else
                push!(groups, sort!(copy(subject)))
                subject_index = length(groups)
                for member in members
                    region_roles[member] = subject_index
                end
            end
        end
    end
    pairs = Set{Tuple{Int,Int}}()
    directions = connectivity == 4 ? FOUR_NEIGHBORS : EIGHT_NEIGHBORS
    for y in axes(frame,1), x in axes(frame,2), (dx,dy) in directions
        xx, yy = x+dx,y+dy
        checkbounds(Bool,frame,yy,xx) || continue
        first, second = region_roles[owner[y,x]], region_roles[owner[yy,xx]]
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
    composite = !isnothing(subject_index) && subject_index > length(region_roles)
    colors = Tuple{String,Int}[]
    for i in sort!(unique(region_roles))
        pigments = i > length(region_roles) ? sort!(unique(last.(groups[i]))) : (groups[i][1][3],)
        append!(colors,((role(i),Int(color)) for color in pigments))
    end
    return (; subject=isnothing(subject_index) ? nothing : role(subject_index), composite, hints,
        neighbor=[(role(a),role(b)) for (a,b) in adjacency],
        colors)
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
