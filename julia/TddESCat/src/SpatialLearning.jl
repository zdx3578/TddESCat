struct ObservedMove
    after::Pixel
    first_landing::Pixel
    event::String
end

mutable struct SpatialLearning
    role::MotionShape
    role_reads::Vector{String}
    offsets::Dict{Int,Dict{Pixel,Vector{String}}}
    visits::Dict{Pixel,Int}
    trials::Dict{Tuple{Pixel,Int},Vector{ObservedMove}}
    layouts::Dict{Pixel,Vector{UInt8}}
    floors::Dict{UInt8,Int}
end

SpatialLearning() = SpatialLearning(ColorCell[],String[],Dict(),Dict(),Dict(),Dict(),Dict())

function locate_role(frame, role)
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
        isnothing(found) || return nothing
        found = (ox-1,oy-1)
    end
    return found
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

function observe_spatial!(model, before, after, effects)
    old_obs,new_obs = before.observation,after.observation
    old_obs.levels_completed == new_obs.levels_completed || return nothing
    a,b = last(old_obs.frames),last(new_obs.frames)
    if isempty(model.role)
        candidate = spatial_role(effects,a,b)
        isempty(candidate) && return nothing
        model.role = candidate
        append!(model.role_reads,[effects.before_id,effects.event_id])
    end
    origin,landing = locate_role(a,model.role),locate_role(b,model.role)
    (isnothing(origin) || isnothing(landing)) && return nothing
    action = new_obs.action["id"]
    action == 6 && return nothing
    first_landing = landing
    if origin != landing && length(new_obs.frames) > 1
        for frame in new_obs.frames
            candidate = locate_role(frame,model.role)
            if !isnothing(candidate) && candidate != origin
                first_landing = candidate
                break
            end
        end
    end
    move = ObservedMove(landing,first_landing,effects.event_id)
    push!(get!(Vector{ObservedMove},model.trials,(origin,action)),move)
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

function spatial_experiment(model::SpatialLearning, obs, decision)
    frame = last(obs.frames)
    here = locate_role(frame,model.role)
    isnothing(here) && return nothing
    active = [row for row in decision.ranked if length(row.action) == 1]
    isempty(active) && return nothing
    action_ids = [row.action["id"] for row in active]
    unbound = spatial_unbound(model,here,action_ids)
    isnothing(unbound) || return unbound
    points = [here]
    parent = Dict{Pixel,Tuple{Int,Pixel,Vector{String}}}()
    visited = Set([here])
    best = nothing
    best_rank = nothing
    for p in points
        for id in action_ids
            measured = get(model.trials,(p,id),nothing)
            if !isnothing(measured)
                target = last(measured).after
                if target ∉ visited && target != p && all(row->row.after == target,measured)
                    parent[target] = (id,p,[row.event for row in measured])
                    push!(visited,target)
                    push!(points,target)
                end
                continue
            end
            offset = measured_offset(model,id)
            isnothing(offset) && continue
            target = p .+ first(offset)
            target in visited && !haskey(model.visits,target) && continue
            quality = frontier_score(model,frame,target)
            quality > 0 || continue
            travel, first_action, first_step = 0,id,target
            reads = [model.role_reads;last(offset)]
            q = p
            while q != here
                first_action, predecessor, sources = parent[q]
                first_step = q
                append!(reads,sources)
                travel += 1
                q = predecessor
            end
            # Prefer visually plausible, untested landings. Break ties by path cost.
            rank = (quality, !haskey(model.visits,target), -travel, -id)
            if isnothing(best_rank) || rank > best_rank
                best_rank = rank
                best = (id=first_action,reason="experiment_at_learned_spatial_frontier",
                    reads=unique(reads),role=here,destination=first_step,frontier=target)
            end
        end
    end
    return best
end

function spatial_unbound(model, here, action_ids)
    missing = findfirst(id->!haskey(model.offsets,id) &&
        isempty(get(model.trials,(here,id),ObservedMove[])),action_ids)
    isnothing(missing) && return nothing
    return (id=action_ids[missing],reason="test_unbound_spatial_action",
        reads=copy(model.role_reads),role=here,destination=nothing,frontier=here)
end
