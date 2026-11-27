struct ObservedMove
    after::Pixel
    first_landing::Pixel
    event::String
    orientation_before::Int
    orientation_after::Int
    continuable::Bool
end

struct MotionContext
    before::String
    frame::Matrix{UInt8}
    previous_action::Int
end

const MotionVariable = Union{Pixel,Symbol}

mutable struct SpatialLearning
    role::MotionShape
    orientations::Vector{MotionShape}
    role_reads::Vector{String}
    offsets::Dict{Int,Dict{Pixel,Vector{String}}}
    visits::Dict{Pixel,Int}
    trials::Dict{Tuple{Pixel,Int},Vector{ObservedMove}}
    unlocalized::Dict{Int,Dict{Tuple{Pixel,String},String}}
    layouts::Dict{Pixel,Vector{UInt8}}
    floors::Dict{UInt8,Int}
    motion_contexts::Dict{String,MotionContext}
    conditions::Dict{Tuple{Pixel,Int},Dict{MotionVariable,FiniteRelation{Int,Pixel}}}
end

SpatialLearning() = SpatialLearning(ColorCell[],MotionShape[],String[],Dict(),Dict(),Dict(),Dict(),Dict(),Dict(),Dict(),Dict())

function role_match(frame, role)
    isempty(role) && return nothing
    pigment_counts = zeros(Int,16)
    for c in frame
        pigment_counts[c+1] += 1
    end
    dx,dy,pigment = argmin(cell->pigment_counts[cell[3]+1],role)
    found = nothing
    for y in axes(frame,1), x in axes(frame,2)
        frame[y,x] == pigment || continue
        ox,oy = x-dx,y-dy
        all(role) do (u,v,color)
            checkbounds(Bool,frame,oy+v,ox+u) && frame[oy+v,ox+u] == color
        end || continue
        isnothing(found) || return :ambiguous
        found = (ox-1,oy-1)
    end
    return found
end

function locate_role(frame,role)
    found = role_match(frame,role)
    return found === :ambiguous ? nothing : found
end

function spatial_binding(frame,role,orientations)
    found = nothing
    for (orientation,template) in enumerate(Iterators.flatten(((role,),orientations)))
        point = role_match(frame,template)
        isnothing(point) && continue
        (point === :ambiguous || !isnothing(found)) && return :ambiguous
        found = (;point,orientation)
    end
    return found
end

spatial_binding(frame,model::SpatialLearning) = spatial_binding(frame,model.role,model.orientations)

function locate_role(frame,model::SpatialLearning)
    found = spatial_binding(frame,model)
    return found isa NamedTuple ? found.point : nothing
end

function rebind_spatial(previous,frame,event;retain_motion=false)
    rebound = SpatialLearning()
    isnothing(locate_role(frame,previous)) && return rebound
    rebound.role = copy(previous.role)
    rebound.orientations = copy(previous.orientations)
    rebound.role_reads = unique([previous.role_reads;event])
    if retain_motion
        rebound.offsets = deepcopy(previous.offsets)
        rebound.floors = copy(previous.floors)
    end
    return rebound
end

function same_footprint_rotations(role)
    rotations = MotionShape[]
    points = effect_points(role)
    rotated = role
    for _ in 1:3
        h = maximum(cell->cell[2],rotated)+1
        rotated = sort!(ColorCell[(h-1-y,x,c) for (x,y,c) in rotated])
        rotated != role && rotated ∉ rotations && effect_points(rotated) == points &&
            push!(rotations,rotated)
    end
    return rotations
end

function full_spatial_support(frame,point,role)
    parts = color_components(frame)
    x,y = point
    members = Set(parts.owner[y+v+1,x+u+1] for (u,v,_) in role)
    return sum(i->length(parts.groups[i]),members) == length(role)
end

function witness_orientation!(model,before,after,origin,effects)
    rotations = same_footprint_rotations(model.role)
    isempty(rotations) && return nothing
    start = spatial_binding(before,model.role,rotations)
    finish = spatial_binding(after,model.role,rotations)
    start isa NamedTuple && start.point == origin.point && finish isa NamedTuple || return nothing
    finish.orientation > 1 || return nothing
    prior = start.orientation == 1 ? model.role : rotations[start.orientation-1]
    form = rotations[finish.orientation-1]
    full_spatial_support(before,start.point,prior) &&
        full_spatial_support(after,finish.point,form) || return nothing
    form ∉ model.orientations || return nothing
    push!(model.orientations,form)
    append!(model.role_reads,[effects.before_id,effects.event_id])
    unique!(model.role_reads)
    return (point=finish.point,orientation=length(model.orientations)+1)
end

function spatial_role(effects, before, after)
    shifts = Dict{Pixel,Vector{MotionShape}}()
    for effect in effects.effects
        effect.family == :translation || continue
        push!(get!(Vector{MotionShape},shifts,Tuple(effect.values)),effect.before)
    end
    # Touching components with a common witnessed displacement are a candidate support.
    candidates = MotionShape[]
    for parts in values(shifts)
        points = Dict((x,y)=>c for part in parts for (x,y,c) in part)
        while !isempty(points)
            p = first(keys(points))
            queue = [p]
            whole = ColorCell[(p...,pop!(points,p))]
            for (x,y) in queue, (dx,dy) in FOUR_NEIGHBORS
                q = (x+dx,y+dy)
                haskey(points,q) || continue
                push!(whole,(q...,pop!(points,q)))
                push!(queue,q)
            end
            length(whole) > 1 || continue
            role = collect(shape_template(sort!(whole)))
            a,b = locate_role(before,role),locate_role(after,role)
            if !isnothing(a) && !isnothing(b) && a != b
                push!(candidates,role)
            end
        end
    end
    isempty(candidates) && return ColorCell[]
    sort!(candidates;by=length,rev=true)
    length(candidates) > 1 && length(candidates[1]) == length(candidates[2]) && return ColorCell[]
    return first(candidates)
end

function footprint(frame, role, p)
    x,y = p
    return all(((u,v,_),)->checkbounds(Bool,frame,y+v+1,x+u+1),role) ?
        UInt8[frame[y+v+1,x+u+1] for (u,v,_) in role] : UInt8[]
end

function dominant_pixel(patch)
    isempty(patch) && return nothing
    pixels = sort!(unique(patch))
    return argmax(pigment->count(==(pigment),patch),pixels)
end

function motion_value(variable, frame, previous_action)
    variable == :previous_action && return previous_action
    x,y = variable
    return checkbounds(Bool,frame,y+1,x+1) ? Int(frame[y+1,x+1]) : nothing
end

function fit_motion_conditions(model, rows)
    outcomes = Pixel[row.after for row in rows]
    different = findfirst(!=(first(outcomes)),outcomes)
    isnothing(different) && return Dict{MotionVariable,FiniteRelation{Int,Pixel}}()
    contexts = [model.motion_contexts[row.event] for row in rows]
    witnesses = [[context.before,row.event] for (context,row) in zip(contexts,rows)]
    a,b = first(contexts),contexts[different]
    variables = MotionVariable[]
    a.previous_action != b.previous_action && push!(variables,:previous_action)
    if size(a.frame) == size(b.frame)
        for y in axes(a.frame,1), x in axes(a.frame,2)
            a.frame[y,x] != b.frame[y,x] && push!(variables,(x-1,y-1))
        end
    end
    candidates = Dict{MotionVariable,FiniteRelation{Int,Pixel}}()
    for variable in variables
        values = [motion_value(variable,ctx.frame,ctx.previous_action) for ctx in contexts]
        any(isnothing,values) && continue
        relation = empirical_relation(Int[v for v in values],outcomes,witnesses)
        isnothing(relation) || (candidates[variable] = relation)
    end
    return candidates
end

function motion_evidence(model, origin, action, frame, previous_action; current,orientation=nothing)
    key = (origin,action)
    rows = get(model.trials,key,ObservedMove[])
    if !isempty(rows) && !isempty(model.orientations)
        if current && isnothing(orientation)
            binding = spatial_binding(frame,model)
            if !(binding isa NamedTuple && binding.point == origin)
                return (status=:conflict,point=nothing,reads=model.role_reads)
            end
            orientation = binding.orientation
        end
        if !isnothing(orientation)
            rows = filter(row->row.orientation_before == orientation,rows)
        elseif length(Set(row.orientation_before for row in rows)) <= length(model.orientations)
            return (status=:conflict,point=nothing,reads=model.role_reads)
        end
    end
    isempty(rows) && return (status=:untested,point=nothing,reads=String[])
    landings = Set(row.after for row in rows)
    function next_orientation(point)
        matching = filter(row->row.after == point,rows)
        isempty(matching) && return nothing
        all(row->row.continuable && row.orientation_after == first(matching).orientation_after,matching) ||
            return nothing
        return first(matching).orientation_after
    end
    if length(landings) == 1
        point = only(landings)
        return (status=point == origin ? :stopped : :witnessed,point,
            orientation=next_orientation(point),reads=[first(rows).event])
    end
    reads = unique([ref for row in rows for ref in (model.motion_contexts[row.event].before,row.event)])
    unknown = (status=:conflict,point=nothing,reads)
    current || return unknown
    candidates = get(model.conditions,key,nothing)
    (isnothing(candidates) || isempty(candidates)) && return unknown
    projected = [empirical_successor(relation,motion_value(variable,frame,previous_action))
        for (variable,relation) in candidates]
    (any(isnothing,projected) || !allequal(projected)) && return unknown
    point = first(projected)
    return (status=point == origin ? :conditional_stop : :conditional_motion,point,
        orientation=next_orientation(point),reads)
end

function spatial_probe_scope(observation,origin)
    frame = last(observation.frames)
    context = semantic_hash([observation.levels_completed,size(frame),content_hash(vec(frame)),
        sort(observation.available_actions),action_key(observation.action)])
    return (origin,context)
end

function observe_spatial!(model, before, after, effects)
    old_obs,new_obs = before.observation,after.observation
    old_obs.levels_completed == new_obs.levels_completed || return nothing
    action = new_obs.action["id"]
    # Spatial roles require a non-coordinate intervention witness.
    action == 6 && return nothing
    a,b = last(old_obs.frames),last(new_obs.frames)
    if isempty(model.role)
        candidate = spatial_role(effects,a,b)
        isempty(candidate) && return nothing
        model.role = candidate
        append!(model.role_reads,[effects.before_id,effects.event_id])
    end
    start = spatial_binding(a,model)
    start isa NamedTuple || return nothing
    finish = spatial_binding(b,model)
    isnothing(finish) && (finish = witness_orientation!(model,a,b,start,effects))
    origin = start.point
    if !(finish isa NamedTuple)
        attempts = get!(Dict{Tuple{Pixel,String},String},model.unlocalized,action)
        get!(attempts,spatial_probe_scope(old_obs,origin),effects.event_id)
        return nothing
    end
    landing = finish.point
    first_landing = landing
    if length(new_obs.frames) > 1
        for frame in new_obs.frames
            candidate = locate_role(frame,model)
            if !isnothing(candidate) && candidate != origin
                first_landing = candidate
                break
            end
        end
    end
    move = ObservedMove(landing,first_landing,effects.event_id,start.orientation,finish.orientation,
        new_obs.state == "NOT_FINISHED")
    key = (origin,action)
    rows = get!(Vector{ObservedMove},model.trials,key)
    model.motion_contexts[move.event] = MotionContext(effects.before_id,a,old_obs.action["id"])
    push!(rows,move)
    if any(row->row.after != landing,rows)
        model.conditions[key] = fit_motion_conditions(model,rows)
    end
    model.visits[landing] = get(model.visits,landing,0)+1
    if origin != landing
        delta = first_landing .- origin
        samples = get!(Dict{Pixel,Vector{String}},model.offsets,action)
        push!(get!(Vector{String},samples,delta),effects.event_id)
        patch = footprint(a,model.role,landing)
        shade = dominant_pixel(patch)
        if !isnothing(shade)
            model.layouts[landing] = patch
            model.floors[shade] = get(model.floors,shade,0)+1
        end
        model.layouts[origin] = footprint(b,model.role,origin)
    end
    return move
end

function measured_offset(model, id)
    values = get(model.offsets,id,nothing)
    isnothing(values) && return nothing
    # A frequent displacement is the hypothesis for a new binding. Observed local
    # edges carry their actual landing position, including longer displacements.
    rows = sort!(collect(values);by=row->(-length(last(row)),sum(abs,first(row)),first(row)))
    return first(rows)
end

function frontier_score(model, frame, destination)
    patch = get(model.layouts,destination,nothing)
    isnothing(patch) && (patch = footprint(frame,model.role,destination))
    isempty(patch) && return 0
    colors = Set(patch)
    occupied = haskey(model.layouts,destination)
    base = isempty(model.floors) ? nothing :
        first(sort!(collect(keys(model.floors));by=c->(-model.floors[c],c)))
    common = !isnothing(base) && 2count(==(base),patch) >= length(patch)
    return occupied ? 4 : common ? (length(colors)>1 ? 5 : 4) : length(colors)>1 ? 2 : 1
end

function spatial_grid(model)
    offsets = [first(measured_offset(model,id)) for id in keys(model.offsets)]
    x = foldl(gcd,(abs(first(d)) for d in offsets);init=0)
    y = foldl(gcd,(abs(last(d)) for d in offsets);init=0)
    return x,y
end

function region_probe_sites(model,frame,here,regions)
    sites = Dict{Pixel,Int}()
    isnothing(regions) && return sites
    floor = visual_floor(model)
    isnothing(floor) && return sites
    stride = spatial_grid(model)
    all(iszero,stride) && return sites
    role = effect_points(model.role)
    occupied = Set(here .+ point for point in role)
    aligned(point) = all(i->iszero(stride[i]) ? point[i] == here[i] :
        iszero(mod(point[i]-here[i],stride[i])),1:2)
    for (index,group) in enumerate(last(regions.frames).groups)
        length(group) <= length(role) && first(group)[3] != floor || continue
        support = effect_points(group)
        isdisjoint(support,occupied) || continue
        representative = first(group)[1:2]
        for offset in role
            point = representative .- offset
            aligned(point) || continue
            all(pixel->pixel .- point in role,support) || continue
            patch = footprint(frame,model.role,point)
            isempty(patch) && continue
            if haskey(model.visits,point) && get(model.layouts,point,nothing) == patch
                continue
            end
            get!(sites,point,index)
        end
    end
    return sites
end

function spatial_experiment(model::SpatialLearning, obs, decision;regions=nothing)
    frame = last(obs.frames)
    here = spatial_binding(frame,model)
    here isa NamedTuple || return nothing
    active = [row for row in decision.ranked if length(row.action) == 1]
    isempty(active) && return nothing
    action_ids = [row.action["id"] for row in active]
    unbound = spatial_unbound(model,here.point,action_ids,obs;orientation=here.orientation)
    isnothing(unbound) || return unbound
    sites = region_probe_sites(model,frame,here.point,regions)
    distance(a,b) = sum(abs,a .- b)
    closest(point) = argmin(site->(distance(point,site),site),keys(sites))
    initial_distance = isempty(sites) ? 0 : distance(here.point,closest(here.point))
    points = [here]
    parent = Dict{typeof(here),Tuple{Int,typeof(here),Vector{String}}}()
    visited = Set([here])
    visited_points = Set([here.point])
    best = nothing
    best_rank = nothing
    for p in points
        for id in action_ids
            observed = motion_evidence(model,p.point,id,frame,obs.action["id"];
                current=p == here,orientation=p.orientation)
            orientation = get(observed,:orientation,nothing)
            if !isnothing(orientation)
                target = (point=observed.point,orientation=orientation)
                if target ∉ visited
                    parent[target] = (id,p,observed.reads)
                    push!(visited,target)
                    push!(visited_points,target.point)
                    push!(points,target)
                end
                continue
            elseif observed.status == :conflict && p == here
                # A new scope is an experiment. It supplies no projected successor.
                rows = model.trials[(p.point,id)]
                tested = any(rows) do row
                    context = model.motion_contexts[row.event]
                    context.previous_action == obs.action["id"] && context.frame == frame
                end
                if !tested
                    return (id=id,reason="distinguish_motion_context",
                        reads=unique([model.role_reads;observed.reads]),role=here.point,
                        destination=nothing,frontier=here.point)
                end
            end
            observed.status == :untested || continue
            offset = measured_offset(model,id)
            isnothing(offset) && continue
            target = p.point .+ first(offset)
            target in visited_points && !haskey(model.visits,target) && continue
            quality = frontier_score(model,frame,target)
            quality > 0 || continue
            site = isempty(sites) ? nothing : closest(target)
            cost = isnothing(site) ? 0 : distance(target,site)
            approaching = !isnothing(site) && cost < initial_distance
            travel, first_action, first_step = 0,id,(point=target,orientation=here.orientation)
            reads = [model.role_reads;last(offset)]
            q = p
            while q != here
                first_action, predecessor, sources = parent[q]
                first_step = q
                append!(reads,sources)
                travel += 1
                q = predecessor
            end
            rank = (approaching,approaching ? -cost : 0,quality,!haskey(model.visits,target),-travel,-id)
            if isnothing(best_rank) || rank > best_rank
                best_rank = rank
                reason = approaching ? "approach_untried_region_relation" : "experiment_at_learned_spatial_frontier"
                if approaching
                    push!(reads,regions.event)
                end
                best = (id=first_action,reason,
                    reads=unique(reads),role=here.point,destination=first_step.point,frontier=target)
                if approaching
                    best = merge(best,(;region_probe=(event=regions.event,region=sites[site],point=site,
                        status=:unresolved)))
                end
                if first_step.point == here.point && first_step.orientation != here.orientation
                    best = merge(best,(;pose=(before=here.orientation,after=first_step.orientation)))
                end
            end
        end
    end
    return best
end

function spatial_unbound(model, here, action_ids, obs;orientation=nothing)
    if isnothing(orientation) && !isempty(model.orientations)
        binding = spatial_binding(last(obs.frames),model)
        binding isa NamedTuple && (orientation = binding.orientation)
    end
    tried(row) = isnothing(orientation) || row.orientation_before == orientation
    candidates = [id for id in action_ids if !haskey(model.offsets,id) &&
        !any(tried,get(model.trials,(here,id),()))]
    isempty(candidates) && return nothing
    scope = spatial_probe_scope(obs,here)
    options = NamedTuple[]
    for id in candidates
        trials = get(model.unlocalized,id,nothing)
        if isnothing(trials)
            push!(options,(;id,unlocated_before=0))
        elseif !haskey(trials,scope)
            push!(options,(;id,unlocated_before=length(trials)))
        end
    end
    isempty(options) && return nothing
    chosen = argmin(option->option.unlocated_before,options)
    return (;chosen.id,chosen.unlocated_before,reason="test_unbound_spatial_action",
        reads=copy(model.role_reads),role=here,destination=nothing,frontier=here)
end
