struct VisualTransition
    before::VisualValue
    after::VisualValue
    event::String
end

struct VisualContact
    point::Pixel
    phase::Int
    patch::Tuple
    transition::VisualTransition
end

struct VisualStep
    from::Pixel
    to::Pixel
    signal_before::VisualValue
    signal_after::Union{Nothing,VisualValue}
    action::Int
    minimum_charge::Int
end

struct VisualContinuation
    steps::Vector{VisualStep}
    reason::String
    frontier::Pixel
    reads::Vector{String}
end

mutable struct VisualControl
    field::Union{Nothing,VisualField}
    targets::Dict{Pixel,VisualValue}
    matched::Set{Pixel}
    failed_targets::Set{Tuple{Pixel,VisualValue}}
    reads::Vector{String}
    changes::Dict{Tuple,Vector{VisualTransition}}
    contacts::Vector{VisualContact}
    scene::SceneMemory
    boundary_rules::Dict{UInt8,Vector{BoundaryMotion}}
    counters::Vector{NamedTuple}
    resource::Union{Nothing,NamedTuple}
    rate::Int
    refill::Dict{Tuple,String}
    spent::Set{Pixel}
    reset_budget::Int
    continuation::Union{Nothing,VisualContinuation}
end

VisualControl() = VisualControl(nothing,Dict(),Set(),Set(),String[],Dict(),VisualContact[],
    SceneMemory(),Dict(),NamedTuple[],nothing,0,Dict(),Set(),-1,nothing)

function begin_visual_level!(control, spatial)
    if !isempty(spatial.role)
        clock = scene_clock(control.scene,spatial)
        control.changes = learned_visual_transitions(control,clock,spatial)
    end
    control.field = nothing
    empty!(control.targets)
    empty!(control.matched)
    empty!(control.failed_targets)
    empty!(control.reads)
    empty!(control.contacts)
    control.scene = SceneMemory()
    empty!(control.counters)
    control.resource = nothing
    control.rate = 0
    empty!(control.spent)
    control.reset_budget = -1
    control.continuation = nothing
end

function begin_visual_attempt!(control)
    empty!(control.matched)
    empty!(control.spent)
    control.scene.tick = 0
    control.continuation = nothing
end

function role_size(role)
    return maximum(c->c[1],role)+1,maximum(c->c[2],role)+1
end

function spatial_grid(model)
    offsets = [first(measured_offset(model,id)) for id in keys(model.offsets)]
    x = foldl(gcd,(abs(first(d)) for d in offsets);init=0)
    y = foldl(gcd,(abs(last(d)) for d in offsets);init=0)
    return x,y
end

function bind_visual_fields!(control, spatial, frame, here, event)
    stride = spatial_grid(spatial)
    any(iszero,stride) && return
    w,h = role_size(spatial.role)
    motifs = visual_motifs(frame,2max(w,h)+1)
    paired = []
    for signal in motifs
        targets = Dict{Pixel,VisualValue}()
        for mark in motifs
            mark.field.scale < signal.field.scale || continue
            mark.field.background == signal.field.background || continue
            (mark.value.width,mark.value.height) == (signal.value.width,signal.value.height) || continue
            b = mark.field.box
            p = (2b.x+b.width-w,2b.y+b.height-h)
            all(iseven,p) || continue
            q = div.(p,2)
            all(iszero,mod.(q .- here,stride)) || continue
            targets[q] = mark.value
        end
        isempty(targets) || push!(paired,(field=signal.field,targets=targets))
    end
    isempty(paired) && return
    modified = isnothing(control.field)
    if modified
        best = argmax(row->(length(row.targets),row.field.scale),paired)
        control.field = best.field
    end
    for pair in paired
        pair.field == control.field || continue
        modified |= any(get(control.targets,p,nothing) != value for (p,value) in pair.targets)
        merge!(control.targets,pair.targets)
    end
    modified && push!(control.reads,event)
end

function observe_visual!(control, spatial, before, after, move, effects)
    isnothing(move) && return
    a,b = last(before.observation.frames),last(after.observation.frames)
    here = locate_role(a,spatial.role)
    there = move.after
    if isnothing(control.resource)
        if isempty(control.counters)
            append!(control.counters,rectangular_fields(a,role_size(spatial.role)...))
        end
        falling = filter(c->read_counter(a,c) > read_counter(b,c),control.counters)
        if length(falling) == 1
            control.resource = only(falling)
            push!(control.reads,effects.event_id)
        end
    end
    if here == there
        if !isnothing(control.field) && haskey(spatial.offsets,after.observation.action["id"])
            delta = first(measured_offset(spatial,after.observation.action["id"]))
            target = here .+ delta
            signal = visual_value(a,control.field)
            target in keys(control.targets) && !isnothing(signal) &&
                push!(control.failed_targets,(target,signal))
        end
        return
    end
    control.scene.tick += 1
    move.first_landing != move.after && observe_boundary_motion!(control.boundary_rules,spatial,a,move)
    patch = Tuple(footprint(a,spatial.role,there))
    if !isnothing(control.resource)
        old,new = read_counter(a,control.resource),read_counter(b,control.resource)
        if new > old > 0
            control.refill[patch] = effects.event_id
            push!(control.spent,there)
        elseif new < old && control.rate == 0
            control.rate = old-new
            push!(control.reads,effects.event_id)
        end
    end
    first_view = there ∉ control.scene.viewpoints
    observe_scene!(control.scene,spatial,b,there,effects.event_id)
    if isnothing(control.field) || isempty(control.targets)
        bind_visual_fields!(control,spatial,a,here,effects.before_id)
    end
    first_view && bind_visual_fields!(control,spatial,b,there,effects.event_id)
    isnothing(control.field) && return
    there in keys(control.targets) && push!(control.matched,there)
    old,new = visual_value(a,control.field),visual_value(b,control.field)
    (isnothing(old) || isnothing(new)) && return
    push!(control.contacts,VisualContact(there,control.scene.tick,patch,VisualTransition(old,new,effects.event_id)))
end

function learned_visual_transitions(control, clock, spatial)
    result = Dict(k=>copy(v) for (k,v) in control.changes)
    plain = Tuple(fill(visual_floor(spatial),length(spatial.role)))
    for contact in control.contacts
        patch = timed_patch(clock,contact.patch,contact.point,contact.phase,plain).patch
        isempty(patch) && continue
        row = contact.transition
        if patch in keys(clock.moving) && isnothing(clock.moving[patch])
            continue
        end
        allequal(patch) && row.before != row.after && continue
        rows = get!(Vector{VisualTransition},result,patch)
        any(r->r.before == row.before && r.after == row.after,rows) || push!(rows,row)
    end
    return result
end

function visual_prediction(transitions, patch, value)
    samples = get(transitions,patch,VisualTransition[])
    exact = [row for row in samples if row.before == value]
    if !isempty(exact)
        allequal(row.after for row in exact) || return nothing
        return (value=first(exact).after,reads=[row.event for row in exact])
    end
    isempty(samples) && return nothing
    transforms = filter(RECTANGLE_TRANSFORMS) do op
        all(visual_transform(row.before,op) == row.after for row in samples)
    end
    if !isempty(transforms)
        choices = unique(visual_transform(value,op) for op in transforms)
        length(choices) == 1 && return (value=only(choices),reads=[r.event for r in samples])
    end
    if all(r->r.before.mask == r.after.mask && r.before.width == r.after.width &&
            r.before.height == r.after.height,samples)
        by_color = filter(r->r.before.pigment == value.pigment,samples)
        pigments = unique(row.after.pigment for row in by_color)
        if length(pigments) == 1
            return (value=VisualValue(value.width,value.height,value.mask,only(pigments)),
                reads=[row.event for row in by_color])
        end
    end
    if all(row->row.before.pigment == row.after.pigment,samples)
        # Test whether the same operation on a rotated input also rotates the output.
        # A disagreement between compatible witnesses leaves the result unresolved.
        matches = VisualValue[]
        reads = String[]
        for row in samples, op in RECTANGLE_TRANSFORMS
            a = visual_transform(row.before,op)
            (a.width,a.height,a.mask) == (value.width,value.height,value.mask) || continue
            b = visual_transform(row.after,op)
            push!(matches,VisualValue(b.width,b.height,b.mask,value.pigment))
            push!(reads,row.event)
        end
        !isempty(matches) && allequal(matches) && return (value=first(matches),reads=unique(reads))
    end
    return nothing
end

function visual_floor(spatial)
    isempty(spatial.floors) && return nothing
    return first(sort!(collect(keys(spatial.floors));by=c->(-spatial.floors[c],c)))
end

struct VisualRouteState
    point::Pixel
    signal::VisualValue
    charge::Int
    spent::Tuple
    matched::Tuple
    phase::Int
end

struct VisualRouteLink
    state::VisualRouteState
    parent::Int
    action::Int
    reads::Vector{String}
    predicted::Bool
    depth::Int
end

function extend_visual_set(items, point)
    point in items && return items
    return Tuple(sort!([items...;[point]]))
end

function route_proposal(control, route, index, evidence, here; probe=nothing)
    reads = copy(evidence)
    certain = true
    steps = VisualStep[]
    frontier = isnothing(probe) ? route[index].state.point : probe.point
    if !isnothing(probe)
        append!(reads,probe.reads)
        source = route[index].state
        push!(steps,VisualStep(source.point,probe.point,source.signal,nothing,probe.action,source.charge))
    end
    while route[index].parent != 0
        link = route[index]
        source = route[link.parent].state
        certain &= link.predicted
        append!(reads,link.reads)
        push!(steps,VisualStep(source.point,link.state.point,source.signal,
            link.predicted ? link.state.signal : nothing,link.action,source.charge))
        index = link.parent
    end
    reverse!(steps)
    reason = isnothing(probe) ? (certain ? "visual_goal_hypothesis" : "experiment_on_goal_route") :
        "experiment_on_unknown_visual_effect"
    control.continuation = VisualContinuation(steps,reason,frontier,unique!(reads))
    return take_visual_step!(control,here)
end

function take_visual_step!(control, here; checked=String[])
    continuation = control.continuation
    step = popfirst!(continuation.steps)
    isempty(continuation.steps) && (control.continuation = nothing)
    return (id=step.action,reason=continuation.reason,reads=unique([continuation.reads;checked]),role=here,
        destination=step.to,frontier=continuation.frontier,expected=step.signal_after)
end

function revalidate_visual_step!(control, spatial, frame, here, signal, charge, motions,
        floor, targets, clock, transitions)
    isnothing(control.continuation) && return nothing
    step = first(control.continuation.steps)
    if step.from == here && step.signal_before == signal && charge >= step.minimum_charge &&
            haskey(motions,step.action)
        delta = first(motions[step.action])
        motion = projected_motion(control,spatial,frame,here,step.action,delta,here,floor,targets)
        if !isnothing(motion) && motion.point == step.to
            tile = scene_tile(control.scene,spatial,frame,step.to,here)
            plain = Tuple(fill(floor,length(spatial.role)))
            timed = timed_patch(clock,tile.patch,step.to,control.scene.tick+1,plain)
            patch = timed.patch
            reads = [control.reads;motion.reads;tile.reads;timed.reads]
            gate = step.to in targets
            if gate && signal == control.targets[step.to] && (step.to,signal) ∉ control.failed_targets
                return take_visual_step!(control,here;checked=reads)
            elseif !gate
                inferred = visual_prediction(transitions,patch,signal)
                value = if isnothing(inferred)
                    !isempty(patch) && (allequal(patch) || haskey(control.refill,patch)) ? signal : nothing
                else
                    inferred.value
                end
                if value == step.signal_after
                    isnothing(inferred) || append!(reads,inferred.reads)
                    return take_visual_step!(control,here;checked=reads)
                end
            end
        end
    end
    control.continuation = nothing
    return nothing
end

visual_outline(value) = (value.width,value.height,value.mask)

function experiment_relevance(samples, current, targets)
    isempty(targets) && return 0
    # Compare the channels a landmark has measurably changed to those that
    # still differ between the current binding and a candidate target.
    pigments = any(row->row.before.pigment != row.after.pigment,samples)
    outlines = any(row->visual_outline(row.before) != visual_outline(row.after),samples)
    return maximum(Int(pigments && current.pigment != target.pigment) +
        Int(outlines && visual_outline(current) != visual_outline(target)) for target in targets)
end

function projected_motion(control, spatial, frame, from, action, delta, here, floor, targets)
    entry = from .+ delta
    observations = get(spatial.trials,(from,action),ObservedMove[])
    accepted = filter(m->m.after != from,observations)
    if !isempty(accepted) && allequal(m.after for m in accepted)
        m = first(accepted)
        return (point=m.after,reads=[m.event])
    end
    !isempty(observations) && isempty(accepted) && entry ∉ targets && return nothing
    effect = boundary_projection(control.boundary_rules,spatial,frame,entry)
    (isnothing(effect) || effect.offset == (0,0)) && return (point=entry,reads=String[])
    reads = [effect.event]
    while true
        step = entry .+ effect.offset
        step in targets && break
        tile = scene_tile(control.scene,spatial,frame,step,here)
        isempty(tile.patch) && break
        2count(==(floor),tile.patch) >= length(tile.patch) || break
        entry = step
        append!(reads,tile.reads)
    end
    return (point=entry,reads=reads)
end

function visual_plan(control, spatial, obs, decision, event)
    isempty(spatial.role) && return nothing
    frame = last(obs.frames)
    here = locate_role(frame,spatial.role)
    isnothing(here) && return nothing
    observe_scene!(control.scene,spatial,frame,here,event)
    candidates = sort!([row.action["id"] for row in decision.ranked if length(row.action) == 1])
    unbound = spatial_unbound(spatial,here,candidates)
    isnothing(unbound) || return unbound
    if isnothing(control.field)
        bind_visual_fields!(control,spatial,frame,here,event)
    end
    isnothing(control.field) && return nothing
    signal = visual_value(frame,control.field)
    isnothing(signal) && return nothing
    floor = visual_floor(spatial)
    isnothing(floor) && return nothing
    clock = scene_clock(control.scene,spatial)
    transitions = learned_visual_transitions(control,clock,spatial)
    plain = Tuple(fill(floor,length(spatial.role)))
    action_ids = filter(id->haskey(spatial.offsets,id),candidates)
    isempty(action_ids) && return nothing
    motions = Dict(id=>measured_offset(spatial,id) for id in action_ids)
    charge = isnothing(control.resource) ? typemax(Int) : read_counter(frame,control.resource)
    rate = isnothing(control.resource) ? 0 : max(1,control.rate)
    targets = filter(p->p ∉ control.matched,collect(keys(control.targets)))
    continued = revalidate_visual_step!(control,spatial,frame,here,signal,charge,motions,
        floor,targets,clock,transitions)
    isnothing(continued) || return continued
    initial = VisualRouteState(here,signal,charge,Tuple(sort!(collect(control.spent))),(),
        mod(control.scene.tick,clock.period))
    cache = Dict{Pixel,NamedTuple}()
    edges = Dict{Tuple{Pixel,Int},Union{Nothing,NamedTuple}}()
    predictions = Dict{Tuple{Tuple,VisualValue},Union{Nothing,NamedTuple}}()
    route = [VisualRouteLink(initial,0,0,String[],true,0)]
    visited = Dict{Tuple{Pixel,VisualValue,Tuple,Tuple,Int},Int}(
        (here,signal,initial.spent,initial.matched,initial.phase)=>charge)
    experiment = nothing
    best_score = nothing
    evidence = unique([spatial.role_reads;control.reads])
    goals = [control.targets[p] for p in targets]
    for (index,row) in enumerate(route)
        s = row.state
        !isempty(targets) && all(p->p in s.matched,targets) &&
            return route_proposal(control,route,index,evidence,here)
        s.charge > 0 || continue
        for id in action_ids
            delta,sources = motions[id]
            edge = get!(edges,(s.point,id)) do
                projected_motion(control,spatial,frame,s.point,id,delta,here,floor,targets)
            end
            isnothing(edge) && continue
            destination = edge.point
            tile = get!(cache,destination) do
                scene_tile(control.scene,spatial,frame,destination,here)
            end
            phase = mod(s.phase+1,clock.period)
            timed = timed_patch(clock,tile.patch,destination,phase,plain)
            patch = timed.patch
            isempty(patch) && continue
            gate = destination in targets && destination ∉ s.matched
            opened = destination in s.matched
            if gate
                s.signal == control.targets[destination] || continue
                (destination,s.signal) in control.failed_targets && continue
            elseif !opened && !haskey(spatial.layouts,destination) && 2count(==(floor),patch) < length(patch)
                continue
            end
            prediction = if gate || opened
                (value=s.signal,reads=String[])
            else
                get!(predictions,(patch,s.signal)) do
                    visual_prediction(transitions,patch,s.signal)
                end
            end
            collectible = haskey(control.refill,patch)
            if isnothing(prediction) && (allequal(patch) || collectible)
                prediction = (value=s.signal,reads=String[])
            end
            predicted = !isnothing(prediction)
            if !predicted
                score = (experiment_relevance(get(transitions,patch,VisualTransition[]),s.signal,goals),
                    -row.depth,s.charge)
                if isnothing(best_score) || score > best_score
                    best_score = score
                    experiment = (index=index,action=id,point=destination,
                        reads=[first(sources);tile.reads;timed.reads;edge.reads])
                end
                # A currently matching signal can motivate a route experiment
                # while an unexplained surface remains open to immediate refutation.
                any(control.targets[p] == s.signal for p in targets) || continue
                prediction = (value=s.signal,reads=String[])
            end
            new_charge, spent = max(0,s.charge-rate),s.spent
            if collectible && destination ∉ spent && !isnothing(control.resource)
                capacity = control.resource.box
                new_charge = max(capacity.width,capacity.height)
                spent = extend_visual_set(spent,destination)
            end
            matched = gate ? extend_visual_set(s.matched,destination) : s.matched
            key = (destination,prediction.value,spent,matched,phase)
            new_charge > get(visited,key,-1) || continue
            visited[key] = new_charge
            required = [first(sources);tile.reads;timed.reads;edge.reads;prediction.reads]
            spent != s.spent && push!(required,control.refill[patch])
            push!(route,VisualRouteLink(VisualRouteState(destination,prediction.value,new_charge,spent,matched,phase),
                index,id,required,predicted,row.depth+1))
        end
    end
    isnothing(experiment) && return nothing
    return route_proposal(control,route,experiment.index,evidence,here;probe=experiment)
end
