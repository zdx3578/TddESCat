mutable struct InterventionMemory
    samples::Vector{NamedTuple}
    probes::Dict{Tuple{Int,String},Int}
    points::Set{Tuple{Int,Pixel}}
    fallback_cursor::Dict{Int,Int}
    primitive_schedule::Dict{Tuple{Int,Int},Tuple{Int,Int}}
    prior_observation::Union{Nothing,Tuple{String,PublicObservation}}
end

InterventionMemory() = InterventionMemory(NamedTuple[],Dict(),Set(),Dict(),Dict(),nothing)

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

function same_intervention_context(a,b)
    return a.levels_completed == b.levels_completed && a.state == b.state &&
        a.available_actions == b.available_actions
end

intervention_frame_distance(a,b) = count(pair->first(pair) != last(pair),zip(a,b))

function primitive_outcome(earlier,prev,next)
    same_intervention_context(prev,next) || return :new_observation
    before,after = last(prev.frames),last(next.frames)
    all(==(before),next.frames) && return :unchanged
    if !isnothing(earlier) && same_intervention_context(earlier,prev)
        prior = last(earlier.frames)
        restored = intervention_frame_distance(prior,after)
        if restored < min(intervention_frame_distance(prior,before),intervention_frame_distance(before,after))
            return :revisited
        end
    end
    return :new_observation
end

intervention_appearance(features) = (features.geometry,features.pigment)

function object_effect_followup(memory,level,candidates)
    by_appearance = Dict{Tuple{String,Int},Vector{NamedTuple}}()
    for row in memory.samples
        row.level == level || continue
        key = intervention_appearance(row.features)
        push!(get!(Vector{NamedTuple},by_appearance,key),row)
    end
    learned = Dict{Tuple{String,Int},NamedTuple}()
    for (appearance,rows) in by_appearance
        witnessed = filter(row->!isempty(row.object_effects),rows)
        length(witnessed) > length(rows)-length(witnessed) || continue
        length(unique(row.point for row in witnessed)) >= 2 || continue
        kinds = reduce(intersect,(Set(row.object_effects) for row in witnessed))
        isempty(kinds) && continue
        reads = sort!(unique!([ref for row in rows for ref in (row.before,row.event)]))
        learned[appearance] = (point=last(witnessed).point,reads,effects=sort!(collect(kinds)))
    end
    options = NamedTuple[]
    for candidate in candidates
        (level,candidate.point) in memory.points && continue
        witness = get(learned,intervention_appearance(candidate.features),nothing)
        isnothing(witness) && continue
        distance = sum(abs,candidate.point .- witness.point)
        push!(options,(;candidate,distance,witness.reads,witness.effects))
    end
    return isempty(options) ? nothing : argmin(row->(row.distance,row.candidate.point),options)
end

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
    primitive = filter(ranked) do row
        id = row.action["id"]
        _,eligible_at = get(memory.primitive_schedule,(level,id),(0,0))
        return id != 6 && confirmed_count >= eligible_at
    end
    if !isempty(primitive) && iseven(confirmed_count)
        row = argmin(item->(get(attempts,action_key(item.action),0),item.rank),primitive)
        return (action=row.action,probe=:primitive,candidate=nothing,goal=nothing,fallback=nothing,
            reason="sample_action_alternative")
    end
    role = [c for c in scene if get(memory.probes,(level,c.instance),0) == 0]
    fallback = coordinate_intervention(memory,level,obs.available_actions)
    if !isempty(role) && (isnothing(fallback) || mod(confirmed_count,7) != 6)
        followup = object_effect_followup(memory,level,role)
        if !isnothing(followup)
            return (action=click_action(followup.candidate.point),probe=:representative,
                candidate=followup.candidate,goal=nothing,fallback=nothing,
                hypothesis=(;followup.reads,followup.effects),reason="extend_observed_object_effect")
        end
        candidate = argmin(c->(c.broad,(level,c.point) in memory.points,c.features.shape_multiplicity,
            -length(c.support),c.point),role)
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
    if action["id"] != 6
        return (;action,probe=:primitive,candidate=nothing,goal=nothing,fallback=nothing,
            reason="observed_primitive")
    end
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
    return (;before,probe=choice.probe,action=choice.action,binding,goal=choice.goal,
        hypothesis=get(choice,:hypothesis,nothing),reason=choice.reason)
end

function observe_intervention!(memory,choice,before,after,effects;learn=true,ordinal)
    prev,next = before.observation,after.observation
    event = after.event["event_id"]
    prior = before.event["event_id"]
    earlier = memory.prior_observation
    memory.prior_observation = (prior,prev)
    isnothing(choice) && return nothing
    choice.action == next.action || error("Intervention differs from the public receipt")
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
            object_effects = advanced ? Symbol[] : unique(effect.family for effect in effects.effects
                if effect.family != :measurement && candidate.point in effect.changed)
            push!(memory.samples,(;level,event,before=prior,probe=choice.probe,advanced,
                features=candidate.features,point=candidate.point,object_effects))
        end
    end
    schedule = if choice.probe == :primitive && learn
        key = (level,choice.action["id"])
        repeats,_ = get(memory.primitive_schedule,key,(0,0))
        outcome = primitive_outcome(isnothing(earlier) ? nothing : last(earlier),prev,next)
        repeats = outcome == :new_observation ? 0 : repeats+1
        eligible_at = ordinal + 2*(repeats+1)^2
        memory.primitive_schedule[key] = (repeats,eligible_at)
        (;outcome,eligible_at,repeats,earlier=outcome == :revisited ? first(earlier) : nothing)
    end
    return (;event,before=prior,probe=choice.probe,action=choice.action,
        advanced,won=next.state == "WIN",result=isnothing(choice.goal) ? "observed" :
            advanced ? "established" : "refuted",
        effect_scope=unique(string(effect.family) for effect in effects.effects),schedule)
end
