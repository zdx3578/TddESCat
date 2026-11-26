mutable struct InterventionMemory
    samples::Vector{NamedTuple}
    probes::Dict{Tuple{Int,String},Int}
    points::Set{Tuple{Int,Pixel}}
    fallback_cursor::Dict{Int,Int}
end

InterventionMemory() = InterventionMemory(NamedTuple[],Dict(),Set(),Dict())

function component_probe(shape)
    left,top = anchor(shape)
    right = maximum(first,shape)
    bottom = maximum(cell->cell[2],shape)
    x,y,_ = argmin(cell->((2cell[1]-left-right)^2+(2cell[2]-top-bottom)^2,
        cell[1],cell[2]),shape)
    return (x,y)
end

function intervention_counts(values)
    counts = Dict{eltype(values),Int}()
    for value in values
        counts[value] = get(counts,value,0)+1
    end
    return counts
end

function intervention_scene(frame,groups)
    shapes = [semantic_hash(geometry(shape)) for shape in groups]
    colors = [Int(first(shape)[3]) for shape in groups]
    count_shapes = intervention_counts(shapes)
    count_colors = intervention_counts(colors)
    appearances = collect(zip(shapes,colors))
    count_appearances = intervention_counts(appearances)
    result = NamedTuple[]
    for (id,support) in enumerate(groups)
        point = component_probe(support)
        frame_area = length(frame)
        features = (geometry=shapes[id],pigment=colors[id],
            shape_multiplicity=count_shapes[shapes[id]],
            pigment_multiplicity=count_colors[colors[id]],
            appearance_multiplicity=count_appearances[appearances[id]])
        # A large region still gets a probe. Without an object/effect witness,
        # its center does not license a prediction over the rest of the region.
        boundary = count(((x,y,_),)->x == 0 || y == 0 || x == size(frame,2)-1 || y == size(frame,1)-1,support)
        broad = 4length(support) > frame_area || 2boundary > length(support)
        instance = semantic_hash([anchor(support),shape_template(support),Tuple(values(features))])
        push!(result,(;point,support,features,instance,broad))
    end
    return result
end

function point_component(groups,point)
    found = findfirst(shape->any(cell->(cell[1],cell[2]) == point,shape),groups)
    return isnothing(found) ? nothing : groups[found]
end

function intervention_models(memory)
    rows = filter(row->row.probe == :representative,memory.samples)
    positives = filter(row->row.advanced,rows)
    length(unique(row.level for row in positives)) >= 2 || return NamedTuple[]
    any(!row.advanced for row in rows) || return NamedTuple[]
    output = NamedTuple[]
    for variable in keys(first(rows).features)
        values = [getproperty(row.features,variable) for row in rows]
        relation = empirical_relation(values,Bool[row.advanced for row in rows],
            [[row.before,row.event] for row in rows])
        isnothing(relation) && continue
        repeatable = Set(key for key in relation.source if
            length(unique(row.level for row in positives if getproperty(row.features,variable) == key)) >= 2)
        isempty(repeatable) && continue
        push!(output,(;variable,relation,repeatable))
    end
    return output
end

function object_advancement(models,candidate,rows)
    isempty(models) && return nothing
    applicable = [getproperty(candidate.features,model.variable) for model in models]
    all(value in model.repeatable && empirical_successor(model.relation,value) === true
        for (value,model) in zip(applicable,models)) || return nothing
    rules = [(variable=model.variable,input=value,observed=sort!(collect(keys(model.relation.evidence))))
        for (value,model) in zip(applicable,models)]
    reads = sort!(unique!([ref for row in rows if row.probe == :representative for ref in (row.before,row.event)]))
    identity = [[string(row.variable),row.input,row.observed] for row in rules]
    return (relation="public_advancement", model="intervention-" * semantic_hash(identity),rules,reads)
end

function spatial_probe_point(index)
    # Visit all scales of the coordinate lattice before densely filling any row.
    x = 0
    y = 0
    for bit in 0:5
        x |= ((index >> (2bit+1)) & 1) << (5-bit)
        y |= ((index >> (2bit)) & 1) << (5-bit)
    end
    return (x,y)
end

function coordinate_intervention(memory,level,available)
    6 in available || return nothing
    first_index = get(memory.fallback_cursor,level,0)
    for distance in 0:4095
        index = mod(first_index+distance,4096)
        point = spatial_probe_point(index)
        (level,point) in memory.points && continue
        return (point,index)
    end
    return nothing
end

click_action(point) = Dict("id"=>6,"x"=>point[1],"y"=>point[2])

function choose_intervention(memory,scene,obs,ranked,attempts;
                             explore,goal_learning,confirmed_count)
    level = obs.levels_completed
    models = goal_learning ? intervention_models(memory) : NamedTuple[]
    for candidate in scene
        get(memory.probes,(level,candidate.instance),0) > 0 && continue
        goal = object_advancement(models,candidate,memory.samples)
        isnothing(goal) || return (action=click_action(candidate.point),
            probe=:representative,candidate,goal,fallback=nothing,
            reason="apply_learned_object_advancement")
    end
    explore || return nothing
    primitive = filter(row->row.action["id"] != 6,ranked)
    if !isempty(primitive) && iseven(confirmed_count)
        row = argmin(item->(get(attempts,action_key(item.action),0),item.rank),primitive)
        return (action=row.action,probe=:primitive,candidate=nothing,goal=nothing,fallback=nothing,
            reason="sample_action_alternative")
    end
    role = [c for c in scene if get(memory.probes,(level,c.instance),0) == 0]
    fallback = coordinate_intervention(memory,level,obs.available_actions)
    if !isempty(role) && (isnothing(fallback) || mod(confirmed_count,7) != 6)
        candidate = argmin(c->(c.broad,c.features.shape_multiplicity,-length(c.support),c.point),role)
        return (action=click_action(candidate.point),probe=:representative,candidate,goal=nothing,
            fallback=nothing,reason="probe_visible_object")
    end
    isnothing(fallback) && return nothing
    point,index = fallback
    role_index = findfirst(c->any(cell->(cell[1],cell[2]) == point,c.support),scene)
    candidate = isnothing(role_index) ? nothing : scene[role_index]
    return (action=click_action(point),probe=:coordinate,candidate,goal=nothing,
        fallback=index,reason="distinguish_uncovered_coordinate")
end

function executed_intervention(choice,scene,action)
    isnothing(choice) || return choice
    action["id"] == 6 || return nothing
    point = (action["x"],action["y"])
    found = findfirst(c->any(cell->(cell[1],cell[2]) == point,c.support),scene)
    candidate = isnothing(found) ? nothing : scene[found]
    probe = !isnothing(candidate) && candidate.point == point ? :representative : :coordinate
    return (;action,probe,candidate,goal=nothing,fallback=nothing,reason="observed_click")
end

function intervention_record(choice,before)
    candidate = choice.candidate
    binding = isnothing(candidate) ? nothing : (id=candidate.instance,
        point=candidate.point,features=candidate.features,cells=length(candidate.support))
    return (;before,probe=choice.probe,action=choice.action,binding,goal=choice.goal,reason=choice.reason)
end

function observe_intervention!(memory,choice,before,after,effects;learn=true)
    isnothing(choice) && return nothing
    prev,next = before.observation,after.observation
    choice.action == next.action || error("Intervention differs from the public receipt")
    event = after.event["event_id"]
    prior = before.event["event_id"]
    level = prev.levels_completed
    advanced = next.levels_completed > level
    if choice.action["id"] == 6
        point = (choice.action["x"],choice.action["y"])
        push!(memory.points,(level,point))
    end
    isnothing(choice.fallback) || (memory.fallback_cursor[level] = mod(choice.fallback+1,4096))
    if !isnothing(choice.candidate) && choice.probe == :representative
        candidate = choice.candidate
        key = (level,candidate.instance)
        memory.probes[key] = get(memory.probes,key,0)+1
        if learn
            push!(memory.samples,(;level,event,before=prior,probe=choice.probe,advanced,
                features=candidate.features))
        end
    end
    return (;event,before=prior,probe=choice.probe,action=choice.action,
        advanced,won=next.state == "WIN",result=isnothing(choice.goal) ? "observed" :
            advanced ? "established" : "refuted",
        effect_scope=unique(string(effect.family) for effect in effects.effects))
end
