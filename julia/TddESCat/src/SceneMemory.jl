struct TileObservation
    patch::Tuple
    event::String
    perimeter::Bool
end

struct LandmarkObservation
    point::Pixel
    event::String
end

struct BoundaryMotion
    alignment::Pixel
    event::String
end

mutable struct SceneMemory
    tiles::Dict{Pixel,TileObservation}
    sightings::Dict{Tuple,Dict{Int,LandmarkObservation}}
    read_views::Set{String}
    viewpoints::Set{Pixel}
    tick::Int
end

SceneMemory() = SceneMemory(Dict(),Dict(),Set(),Set(),0)

function observe_scene!(scene, spatial, frame, here, event)
    event in scene.read_views && return
    stride = spatial_grid(spatial)
    any(iszero,stride) && return
    base = visual_floor(spatial)
    isnothing(base) && return
    width,height = role_size(spatial.role)
    h,w = size(frame)
    edges = findall(c->c[1] in (0,width-1) || c[2] in (0,height-1),spatial.role)
    landmarks = Dict{Tuple,Vector{Pixel}}()
    for y in mod(here[2],stride[2]):stride[2]:h-height,
            x in mod(here[1],stride[1]):stride[1]:w-width
        p = (x,y)
        p == here && continue
        patch = Tuple(footprint(frame,spatial.role,p))
        2count(==(base),patch) >= length(patch) || continue
        perimeter = !isempty(edges) && all(patch[i] == base for i in edges)
        previous = get(scene.tiles,p,nothing)
        if perimeter || isnothing(previous) || !previous.perimeter
            scene.tiles[p] = TileObservation(patch,event,perimeter)
        end
        if perimeter && !allequal(patch)
            push!(get!(Vector{Pixel},landmarks,patch),p)
        end
    end
    for (patch,points) in landmarks
        length(points) == 1 || continue
        samples = get!(Dict{Int,LandmarkObservation},scene.sightings,patch)
        p = only(points)
        earlier = get(samples,scene.tick,nothing)
        if isnothing(earlier)
            samples[scene.tick] = LandmarkObservation(p,event)
        elseif earlier.point != p
            # A clock fitted to a previous attempt is a hypothesis. Keep the new
            # evidence and allow a different history dependence to be found.
            empty!(samples)
            samples[scene.tick] = LandmarkObservation(p,event)
        end
    end
    push!(scene.read_views,event)
    push!(scene.viewpoints,here)
    return nothing
end

function infer_landmark_period(samples, stride)
    length(samples) >= 4 || return nothing
    span = maximum(keys(samples))-minimum(keys(samples))
    for period in 2:min(span,length(samples)-2)
        locations = Dict{Int,Pixel}()
        for (tick,sample) in samples
            offset = mod(tick,period)
            get(locations,offset,sample.point) == sample.point || break
            locations[offset] = sample.point
        end
        length(locations) == period || continue
        all(locations[mod(tick,period)] == sample.point for (tick,sample) in samples) || continue
        positions = [locations[i] for i in 0:period-1]
        adjacent(a,b) = begin
            dx,dy = abs.(a .- b)
            (dx,dy) in ((0,0),(stride[1],0),(0,stride[2]))
        end
        all(adjacent(positions[i],positions[mod1(i+1,period)]) for i in 1:period) || continue
        ordered = sort!(collect(keys(samples)))
        witness = Dict{Int,String}()
        recurrence = nothing
        for tick in ordered
            phase = mod(tick,period)
            if haskey(witness,phase)
                isnothing(recurrence) && (recurrence = samples[tick].event)
            else
                witness[phase] = samples[tick].event
            end
        end
        reads = sort!(collect(values(witness)))
        isnothing(recurrence) || push!(reads,recurrence)
        return (;positions,reads)
    end
    return nothing
end

function scene_clock(scene, spatial)
    strides = spatial_grid(spatial)
    moving = Dict{Tuple,Any}()
    for (patch,samples) in scene.sightings
        length(Set(s.point for s in values(samples))) > 1 || continue
        moving[patch] = infer_landmark_period(samples,strides)
    end
    period = foldl(lcm,(length(path.positions) for path in values(moving) if !isnothing(path));init=1)
    return (; moving,period)
end

function scene_tile(scene, spatial, frame, target, here)
    cached = get(scene.tiles,target,nothing)
    if target != here
        patch = Tuple(footprint(frame,spatial.role,target))
        base = visual_floor(spatial)
        if !isempty(patch) && (isnothing(cached) || 2count(==(base),patch) >= length(patch))
            return (;patch,reads=String[])
        end
    end
    isnothing(cached) && return (patch=Tuple(get(spatial.layouts,target,UInt8[])),reads=String[])
    return (patch=cached.patch,reads=[cached.event])
end

function timed_patch(clock, patch, point, phase, plain)
    for (symbol,path) in clock.moving
        isnothing(path) && continue
        if path.positions[mod(phase,length(path.positions))+1] == point
            return (patch=symbol,reads=path.reads)
        end
    end
    patch in keys(clock.moving) && !isnothing(clock.moving[patch]) && return (patch=plain,reads=String[])
    return (;patch,reads=String[])
end

function boundary_pigments(frame, p, (width,height), floor)
    x,y = p
    candidates = Tuple{Pixel,UInt8}[]
    for d in FOUR_NEIGHBORS
        dx,dy = d
        u = x + (dx < 0 ? -1 : dx > 0 ? width : 0)
        v = y + (dy < 0 ? -1 : dy > 0 ? height : 0)
        line = dx == 0 ? [(u+i,v) for i in 0:width-1] : [(u,v+i) for i in 0:height-1]
        all(((w,h),)->checkbounds(Bool,frame,h+1,w+1),line) || continue
        pigment = frame[v+1,u+1]
        pigment == floor && continue
        all(frame[b+1,a+1] == pigment for (a,b) in line) && push!(candidates,(d,pigment))
    end
    return candidates
end

function observe_boundary_motion!(rules, spatial, frame, move)
    footprint_shift = sign.(move.after .- move.first_landing)
    sum(abs,footprint_shift) == 1 || return
    shade = visual_floor(spatial)
    isnothing(shade) && return
    tags = boundary_pigments(frame,move.first_landing,role_size(spatial.role),shade)
    isempty(tags) && return
    sort!(tags;by=t->count(==(last(t)),frame))
    length(tags) > 1 && count(==(tags[1][2]),frame) == count(==(tags[2][2]),frame) && return
    ((dx,dy),pigment) = first(tags)
    a,b = footprint_shift
    witness = BoundaryMotion((dx*a+dy*b,dx*b-dy*a),move.event)
    rows = get!(Vector{BoundaryMotion},rules,pigment)
    any(r->r.alignment == witness.alignment,rows) || push!(rows,witness)
end

function boundary_projection(rules, spatial, frame, at)
    tags = boundary_pigments(frame,at,role_size(spatial.role),visual_floor(spatial))
    possible = []
    for ((dx,dy),pigment) in tags
        rows = get(rules,pigment,BoundaryMotion[])
        length(rows) == 1 || continue
        a,b = only(rows).alignment
        stride = spatial_grid(spatial)
        offset = (a*dx-b*dy,a*dy+b*dx) .* stride
        push!(possible,(offset=offset,event=only(rows).event))
    end
    length(possible) == 1 || return nothing
    return only(possible)
end
