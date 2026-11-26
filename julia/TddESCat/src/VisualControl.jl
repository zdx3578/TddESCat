struct VisualTransition
    before::VisualValue
    after::VisualValue
    event::String
end

struct VisualContact
    point::Pixel
    phase::Int
    action_phase::Int
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
    contact::Union{Nothing,Symbol}
end

struct VisualContinuation
    steps::Vector{VisualStep}
    reason::String
    frontier::Pixel
    reads::Vector{String}
    contact_plan::Union{Nothing,NamedTuple}
    effect_gain::Int
end

mutable struct VisualControl
    field::Union{Nothing,VisualField}
    targets::Dict{Pixel,VisualSite}
    matched::Set{Pixel}
    detached::Set{Pixel}
    site_status::Dict{Pixel,String}
    site_entries::Dict{Pixel,String}
    contact_samples::Vector{ContactSample}
    goal_samples::Vector{GoalSample}
    site_completions::Dict{String,NamedTuple}
    attempt_epoch::Int
    reads::Vector{String}
    changes::Dict{Tuple,Vector{VisualTransition}}
    contacts::Vector{VisualContact}
    scene::SceneMemory
    boundary_rules::Dict{UInt8,Vector{BoundaryMotion}}
    resource::Union{Nothing,MeterBinding}
    meter_dynamics::MeterDynamics
    spent::Set{Pixel}
    exhausted_evidence::Set{String}
    continuation::Union{Nothing,VisualContinuation}
    site_surveys::Vector{NamedTuple}
end

VisualControl() = VisualControl(nothing,Dict(),Set(),Set(),Dict(),Dict(),ContactSample[],GoalSample[],Dict(),0,String[],Dict(),VisualContact[],
    SceneMemory(),Dict(),nothing,MeterDynamics(),Set(),Set(),nothing,NamedTuple[])

function begin_visual_level!(control, spatial)
    if !isempty(spatial.role)
        clock = scene_clock(control.scene,spatial)
        control.changes = learned_visual_transitions(control,clock,spatial)
    end
    control.field = nothing
    empty!(control.targets)
    empty!(control.matched)
    empty!(control.detached)
    empty!(control.site_status)
    empty!(control.site_entries)
    control.attempt_epoch += 1
    empty!(control.reads)
    empty!(control.contacts)
    control.scene = SceneMemory()
    control.resource = nothing
    empty!(control.meter_dynamics.local_rows)
    empty!(control.spent)
    empty!(control.exhausted_evidence)
    control.continuation = nothing
end

function may_retry_visual_attempt!(control, spatial, level)
    # Compare learned content rather than a count of frames or events. A newly
    # revealed contact can change the next experiment even on a visited tile.
    admission = fit_contact_guards(control.contact_samples)
    progress = fit_progress_relations(control.contact_samples)
    conditions = [(key,sort!([(read,sort!(collect(keys(relation.evidence)))) for (read,relation) in rows];by=repr))
        for (key,rows) in spatial.conditions]
    evidence = [
        [control.field],
        [(p,site.field,site.value) for (p,site) in control.targets],
        [(p,action,move.first_landing,move.after)
            for ((p,action),moves) in spatial.trials for move in moves],
        [(p,tile.patch,tile.perimeter) for (p,tile) in control.scene.tiles],
        [(c.patch,c.transition.before,c.transition.after) for c in control.contacts],
        [(s.point,s.context,s.site.value,s.outcome) for s in control.contact_samples if s.level == level],
        [(row.patch,row.action,row.used,row.before,row.after) for row in control.meter_dynamics.gain_rows],
        conditions,collect(control.detached),
        [(guard.same,guard.different) for guard in admission.rules],
        [(name,sort!(collect(keys(relation.evidence)))) for (name,relation) in admission.scoped],
        [progress.model]
    ]
    revision = content_hash(JSON.json([sort!(unique!(JSON.json.(group))) for group in evidence]))
    revision in control.exhausted_evidence && return false
    push!(control.exhausted_evidence,revision)
    return true
end

function begin_visual_attempt!(control)
    empty!(control.matched)
    empty!(control.detached)
    empty!(control.site_status)
    empty!(control.site_entries)
    control.attempt_epoch += 1
    empty!(control.spent)
    control.scene.tick = 0
    control.scene.confirmed_actions = 0
    control.continuation = nothing
end

function take_site_surveys!(control)
    surveys = copy(control.site_surveys)
    empty!(control.site_surveys)
    return surveys
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
    push!(control.site_surveys,(event=event,origin=here,stride,role=copy(spatial.role)))
    sites = Dict{Pixel,VisualSite}()
    windows = VisualField[]
    occupied = Set(here .+ (x,y) for (x,y,_) in spatial.role)
    for (point,site) in control.targets
        b = site.field.box
        checkbounds(Bool,frame,b.y+b.height,b.x+b.width) || continue
        any(((x,y),)->in_window(b,x,y),occupied) && continue
        if point ∉ control.detached &&
                all(==(site.field.background),@view frame[b.y+1:b.y+b.height,b.x+1:b.x+b.width])
            push!(control.detached,point)
            control.site_status[point] = event
        end
    end
    for motif in visual_motifs(frame,2max(w,h)+1)
        b = motif.field.box
        centered = (2b.x+b.width-w,2b.y+b.height-h)
        point = div.(centered,2)
        on_lattice = all(iseven,centered) && all(iszero,mod.(point .- here,stride))
        if !on_lattice
            push!(windows,motif.field)
        elseif b.width <= w && b.height <= h &&
                motif_contrast_boundary(frame,motif.field,max(w,h))
            sites[point] = VisualSite(motif.field,motif.value,event)
        end
    end
    isempty(sites) && return
    modified = isnothing(control.field)
    if modified
        isempty(windows) && return
        # Prefer a less compressed observation window as the initial context.
        # This choice places no condition on admitted interactions.
        control.field = first(sort!(windows;by=f->(-f.box.width*f.box.height,f.box.y,f.box.x)))
    end
    for (point,site) in sites
        existing = get(control.targets,point,nothing)
        if point in control.detached || isnothing(existing) || existing.value != site.value || existing.field != site.field
            delete!(control.matched,point)
            delete!(control.detached,point)
            delete!(control.site_entries,point)
            control.targets[point] = site
            control.site_status[point] = event
            modified = true
        end
    end
    modified && push!(control.reads,event)
end

function scene_survey(control, spatial, obs, decision)
    scene = control.scene
    isnothing(scene.occlusion_ref) && return nothing
    frame = last(obs.frames)
    here = locate_role(frame,spatial.role)
    isnothing(here) && return nothing
    floor = visual_floor(spatial)
    isnothing(floor) && return nothing
    stride = spatial_grid(spatial)
    any(iszero,stride) && return nothing
    targets = collect(keys(control.targets))
    actions = sort!([row.action["id"] for row in decision.ranked if length(row.action) == 1 &&
        haskey(spatial.offsets,row.action["id"])])
    isempty(actions) && return nothing
    motions = Dict(id=>measured_offset(spatial,id) for id in actions)
    charge = isnothing(control.resource) ? typemax(Int) : read_meter(frame,control.resource)
    isnothing(charge) && return nothing
    meter_model = fit_meter_dynamics(control.meter_dynamics)
    state = (here,charge,Tuple(sort!(collect(control.spent))))
    agenda = NamedTuple[(state=state,action=0,first_point=here,parent=0,reads=String[],depth=0)]
    best = 0
    rank = (0,0,0)
    reached = Dict{Tuple{Pixel,Tuple},Int}((here,state[3])=>charge)
    edges = Dict{Tuple{Pixel,Int,Bool},Union{Nothing,NamedTuple}}()
    tiles = Dict{Pixel,NamedTuple}()
    novelties = Dict{Pixel,Int}()
    transfers = Dict{Tuple,Union{Nothing,NamedTuple}}()
    for (index,row) in enumerate(agenda)
        p,left,used = row.state
        if p ∉ scene.viewpoints && !isempty(scene.viewpoints)
            novelty = get!(novelties,p) do
                minimum(sum(abs.(p .- q) .÷ stride) for q in scene.viewpoints)
            end
            score = (novelty,left,-row.depth)
            if score > rank
                rank = score
                best = index
            end
        end
        left > 0 || continue
        for id in actions
            delta,sources = motions[id]
            current = row.depth == 0
            edge = get!(edges,(p,id,current)) do
                projected_motion(control,spatial,frame,p,id,delta,here,floor,targets;
                    current,previous_action=obs.action["id"])
            end
            isnothing(edge) && continue
            q = edge.point
            q in targets && q ∉ control.matched && continue
            tile = get!(tiles,q) do
                scene_tile(scene,spatial,frame,q,here)
            end
            isempty(tile.patch) && continue
            haskey(spatial.layouts,q) || 2count(==(floor),tile.patch) >= length(tile.patch) || continue
            already_used,moved = q in used,p != q
            transfer = get!(transfers,(id,tile.patch,left,already_used,moved)) do
                visual_meter_prediction(control,meter_model,id,tile.patch,left,already_used;moved)
            end
            isnothing(transfer) && continue
            remaining = transfer.value
            next_used = remaining > left ? extend_visual_set(used,q) : used
            key = (q,next_used)
            remaining > get(reached,key,-1) || continue
            reached[key] = remaining
            reads = [first(sources);edge.reads;tile.reads;transfer.reads]
            push!(agenda,(state=(q,remaining,next_used),action=row.action == 0 ? id : row.action,
                first_point=row.action == 0 ? q : row.first_point,parent=index,reads,depth=row.depth+1))
        end
    end
    best == 0 && return nothing
    path = Int[]
    index = best
    while agenda[index].parent != 0
        push!(path,index)
        index = agenda[index].parent
    end
    reads = [spatial.role_reads;control.reads;scene.occlusion_ref]
    for index in Iterators.reverse(path)
        append!(reads,agenda[index].reads)
    end
    selected = agenda[best]
    control.continuation = nothing
    return (id=selected.action,reason="inspect_unseen_neighborhood",reads=unique!(reads),
        role=here,destination=selected.first_point,frontier=selected.state[1],expected=nothing)
end

function autonomous_visual_plan(control,spatial,obs,decision,event;goal=nothing,relationship=nothing,refuted=nothing)
    proposed = visual_plan(control,spatial,obs,decision,event;goal,relationship,refuted)
    if !isnothing(proposed) &&
            (proposed.reason in ("learned_visual_contact","experiment_on_contact_relation") ||
            get(proposed,:effect_gain,0) > 0)
        return proposed
    end
    survey = scene_survey(control,spatial,obs,decision)
    return isnothing(survey) ? proposed : survey
end

function observe_visual!(control, spatial, before, after, move, effects)
    a,b = last(before.observation.frames),last(after.observation.frames)
    here = locate_role(a,spatial.role)
    there = isnothing(move) ? locate_role(b,spatial.role) : move.after
    moved = !isnothing(move) && here != there
    meters = [effect.context.binding for effect in effects.effects
        if effect.family == :measurement && only(effect.values) < 0]
    if isnothing(control.resource) && length(meters) == 1
        control.resource = only(meters)
        append!(control.reads,[control.resource.face.source,control.resource.calibrated_at])
    elseif !isnothing(control.resource)
        rebound = findfirst(candidate->meter_window(candidate.face.box) == meter_window(control.resource.face.box) &&
            meter_layout(candidate) == meter_layout(control.resource),meters)
        isnothing(rebound) || (control.resource = meters[rebound])
    end

    control.scene.confirmed_actions += 1
    if moved
        control.scene.tick += 1
        move.first_landing != move.after && observe_boundary_motion!(control.boundary_rules,spatial,a,move)
    end
    patch = moved ? Tuple(footprint(a,spatial.role,there)) : ()
    counter = nothing
    if !isnothing(control.resource)
        old,new = read_meter(a,control.resource),read_meter(b,control.resource)
        counter = (field=control.resource.face,binding=control.resource,before=old,after=new)
        if isnothing(old) || isnothing(new)
            control.continuation = nothing
        elseif !isnothing(there)
            record_meter_transition!(control.meter_dynamics,after.observation.action["id"],patch,
                there in control.spent,moved,old,new,effects.event_id)
            moved && new > old && push!(control.spent,there)
        end
    end

    if moved
        first_view = there ∉ control.scene.viewpoints
        observe_scene!(control.scene,spatial,b,there,effects.event_id)
        if isnothing(control.field) || isempty(control.targets)
            bind_visual_fields!(control,spatial,a,here,effects.before_id)
        end
        first_view && bind_visual_fields!(control,spatial,b,there,effects.event_id)
    end
    signal = nothing
    if !isnothing(control.field)
        old = visual_value(a,control.field)
        trace = [visual_value(frame,control.field) for frame in after.observation.frames]
        signal = (field=control.field,before=old,trace)
        if !isnothing(there) && !isnothing(old) && !isnothing(last(trace)) && (moved || old != last(trace))
            push!(control.contacts,VisualContact(there,control.scene.tick,control.scene.confirmed_actions,patch,
                VisualTransition(old,last(trace),effects.event_id)))
        end
    end
    return (before_ref=effects.before_id,event_ref=effects.event_id,
        motion=isnothing(move) ? :unbound : moved ? :moved : :stationary,
        counter,signal,action_count=control.scene.confirmed_actions,movement_count=control.scene.tick)
end

function contact_facts(control, previous_action)
    points = sort!([p for p in keys(control.targets) if p ∉ control.matched && p ∉ control.detached])
    reads = sort!(unique!([[site.event for site in values(control.targets)];collect(values(control.site_status))]))
    return ContactFacts([(point,control.targets[point]) for point in points],previous_action,reads)
end

function observe_visual_contact!(control, spatial, before, after;learn=true)
    isnothing(control.field) && return nothing
    before_obs, after_obs = before.observation,after.observation
    frame = last(before_obs.frames)
    origin = locate_role(frame,spatial.role)
    action = after_obs.action["id"]
    offset = measured_offset(spatial,action)
    (isnothing(origin) || isnothing(offset)) && return nothing
    point = origin .+ first(offset)
    point in control.detached && return nothing
    site = get(control.targets,point,nothing)
    isnothing(site) && return nothing
    context = visual_value(frame,control.field)
    isnothing(context) && return nothing
    read_site = visual_value(frame,site.field)
    read_site == site.value || return nothing
    positions = [locate_role(result,spatial.role) for result in after_obs.frames]
    progress = before_obs.levels_completed < after_obs.levels_completed
    outcome = if progress && point in positions
        :progress
    elseif progress
        return nothing
    elseif last(positions) == point
        :entered
    elseif all(==(origin),positions)
        :blocked
    else
        return nothing
    end
    facts = contact_facts(control,before_obs.action["id"])
    if outcome == :entered
        control.site_entries[point] = after.event["event_id"]
    end
    sample = ContactSample(before_obs.levels_completed,point,context,site,control.field,origin,
        action,outcome,before.event["event_id"],after.event["event_id"],spatial.role,
        first(last(offset)),facts,after_obs.state)
    if learn
        push!(control.contact_samples,sample)
        push!(control.goal_samples,goal_sample(sample,before,after;attempt=control.attempt_epoch))
    end
    return sample
end

function learned_visual_transitions(control, clock, spatial)
    result = Dict(k=>copy(v) for (k,v) in control.changes)
    plain = Tuple(fill(visual_floor(spatial),length(spatial.role)))
    for contact in control.contacts
        patch = timed_patch(clock,contact.patch,contact.point,contact.phase,plain;action_phase=contact.action_phase).patch
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

function route_proposal(control, route, probe, evidence, here; contact_plan=nothing, effect_gain=0)
    reads = [evidence;probe.reads]
    index = probe.index
    source = route[index].state
    mode = isnothing(contact_plan) ? nothing : contact_plan.conditions.judgment
    steps = [VisualStep(source.point,probe.point,source.signal,nothing,probe.action,source.charge,mode)]
    certain = true
    while route[index].parent != 0
        link = route[index]
        source = route[link.parent].state
        certain &= link.predicted
        append!(reads,link.reads)
        push!(steps,VisualStep(source.point,link.state.point,source.signal,
            link.predicted ? link.state.signal : nothing,link.action,source.charge,nothing))
        index = link.parent
    end
    reverse!(steps)
    reason = if isnothing(contact_plan)
        "experiment_on_unknown_visual_effect"
    elseif mode == :admitted && certain
        "learned_visual_contact"
    else
        "experiment_on_contact_relation"
    end
    control.continuation = VisualContinuation(steps,reason,probe.point,unique!(reads),contact_plan,effect_gain)
    return take_visual_step!(control,here)
end

function take_visual_step!(control, here; checked=String[])
    continuation = control.continuation
    step = popfirst!(continuation.steps)
    isempty(continuation.steps) && (control.continuation = nothing)
    return (id=step.action,reason=continuation.reason,reads=unique([continuation.reads;checked]),role=here,
        destination=step.to,frontier=continuation.frontier,expected=step.signal_after,
        contact=continuation.contact_plan,executes_contact=!isnothing(step.contact),
        effect_gain=continuation.effect_gain)
end

function revalidate_visual_step!(control, spatial, frame, here, signal, charge, motions,
        floor, targets, clock, transitions, fitted, progress, facts, level, event, meter_model)
    isnothing(control.continuation) && return nothing
    step = first(control.continuation.steps)
    plan = control.continuation.contact_plan
    if !isnothing(plan) && (plan.progress.model != progress.model ||
            plan.progress.facts.remaining != facts.remaining)
        control.continuation = nothing
        return nothing
    end
    if step.from == here && step.signal_before == signal && charge >= step.minimum_charge &&
            haskey(motions,step.action)
        delta = first(motions[step.action])
        motion = projected_motion(control,spatial,frame,here,step.action,delta,here,floor,targets;
            current=true,previous_action=facts.previous_action)
        if !isnothing(motion) && motion.point == step.to
            tile = scene_tile(control.scene,spatial,frame,step.to,here)
            plain = Tuple(fill(floor,length(spatial.role)))
            timed = timed_patch(clock,tile.patch,step.to,control.scene.tick+1,plain)
            patch = timed.patch
            reads = [control.reads;motion.reads;tile.reads;timed.reads]
            if step.to in targets && !isnothing(step.contact)
                site = control.targets[step.to]
                signature = contact_signature(signal,site.value)
                judgment = contact_judgment(fitted,signature,facts,step.action)
                tested = contact_observed(control.contact_samples,level,step.to,signal,site.value;
                    facts=isempty(fitted.scope_samples) ? nothing : facts,action=step.action)
                planned_site = control.continuation.contact_plan.site
                if site == planned_site && visual_value(frame,site.field) == site.value &&
                        judgment == step.contact && (!tested || judgment == :admitted)
                    completion = progress_conditions(progress,facts,step.action)
                    if plan.progress.judgment == completion.judgment
                        updated = merge(plan,(conditions=contact_conditions(fitted,signature,facts,step.action),
                            progress=completion,selected_at=event))
                        control.continuation = VisualContinuation(control.continuation.steps,
                            control.continuation.reason,control.continuation.frontier,
                            control.continuation.reads,updated,control.continuation.effect_gain)
                        return take_visual_step!(control,here;checked=[reads;fitted.reads;completion.reads])
                    end
                end
            elseif step.to ∉ targets && isnothing(step.contact)
                inferred = visual_prediction(transitions,patch,signal)
                value = if isnothing(inferred)
                    !isempty(patch) && (allequal(patch) || patch in meter_model.gains) ? signal : nothing
                else
                    inferred.value
                end
                transfer = visual_meter_prediction(control,meter_model,step.action,patch,charge,
                    step.to in control.spent;moved=step.to!=here)
                if value == step.signal_after && !isnothing(transfer)
                    isnothing(inferred) || append!(reads,inferred.reads)
                    append!(reads,transfer.reads)
                    return take_visual_step!(control,here;checked=reads)
                end
            end
        end
    end
    control.continuation = nothing
    return nothing
end

function experiment_relevance(samples, current, sites, fitted)
    changed = foldl(|,(xor(contact_signature(sample.before,sample.after),
        (1 << length(CONTACT_COMPARISONS))-1) for sample in samples);init=0)
    iszero(changed) && return 0
    score = 0
    for target in sites, guard in fitted.rules
        current_signature = contact_signature(current,target)
        required = guard.same | guard.different
        unmet = xor(current_signature,guard.same) & required
        score = max(score,count_ones(unmet & changed))
    end
    return score
end

function projected_motion(control, spatial, frame, from, action, delta, here, floor, targets;
        current=false, previous_action=0)
    entry = from .+ delta
    evidence = motion_evidence(spatial,from,action,frame,previous_action;current)
    if evidence.status in (:witnessed,:conditional_motion)
        return (point=evidence.point,reads=evidence.reads)
    elseif evidence.status in (:conflict,:conditional_stop)
        return nothing
    elseif evidence.status == :stopped && entry ∉ targets
        return nothing
    end
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

function visual_plan(control, spatial, obs, decision, event;goal=nothing,relationship=nothing,refuted=nothing)
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
    if !isnothing(refuted)
        control.continuation = nothing
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
    charge = isnothing(control.resource) ? typemax(Int) : read_meter(frame,control.resource)
    isnothing(charge) && return nothing
    meter_model = fit_meter_dynamics(control.meter_dynamics)
    facts = contact_facts(control,obs.action["id"])
    targets = first.(facts.remaining)
    fitted = fit_contact_guards(control.contact_samples)
    progress = isnothing(goal) ? fit_progress_relations(control.contact_samples) : goal.fit
    use_history = any(row->uses_progress_history(first(row)),progress.models) ||
        !isempty(fitted.scope_samples)
    level = obs.levels_completed
    continued = revalidate_visual_step!(control,spatial,frame,here,signal,charge,motions,
        floor,targets,clock,transitions,fitted,progress,facts,level,event,meter_model)
    isnothing(continued) || return continued
    initial = VisualRouteState(here,signal,charge,Tuple(sort!(collect(control.spent))),
        mod(control.scene.tick,clock.period))
    cache = Dict{Pixel,NamedTuple}()
    edges = Dict{Tuple{Pixel,Int,Bool},Union{Nothing,NamedTuple}}()
    predictions = Dict{Tuple{Tuple,VisualValue},Union{Nothing,NamedTuple}}()
    contacts = Dict{Tuple{Pixel,VisualValue,Int,Int},NamedTuple}()
    route = [VisualRouteLink(initial,0,0,String[],true,0)]
    visited = Dict{Tuple{Pixel,VisualValue,Tuple,Int,Int},Int}(
        (here,signal,initial.spent,initial.phase,use_history ? facts.previous_action : 0)=>charge)
    experiment = nothing
    best_score = nothing
    contact = nothing
    contact_rank = nothing
    intermediate = nothing
    evidence = unique([event;spatial.role_reads;control.reads])
    goals = [control.targets[p].value for p in targets]
    effect_scores = Dict{Tuple{Tuple,VisualValue},Int}()
    meter_predictions = Dict{Tuple,Any}()
    for (index,row) in enumerate(route)
        s = row.state
        s.charge > 0 || continue
        for id in action_ids
            delta,sources = motions[id]
            current = row.parent == 0
            if current && !isnothing(refuted) && here == refuted.origin && id == refuted.action
                continue
            end
            edge = get!(edges,(s.point,id,current)) do
                projected_motion(control,spatial,frame,s.point,id,delta,here,floor,targets;
                    current,previous_action=obs.action["id"])
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
            reads = [first(sources);tile.reads;timed.reads;edge.reads]
            if destination in targets
                site = control.targets[destination]
                prior = current ? facts.previous_action : row.action
                context = ContactFacts(facts.remaining,prior,facts.domain_reads)
                key = isempty(fitted.scope_samples) ? (destination,s.signal,0,0) :
                    (destination,s.signal,prior,id)
                observation = get!(contacts,key) do
                    signature = contact_signature(s.signal,site.value)
                    judgment = contact_judgment(fitted,signature,context,id)
                    tested = contact_observed(control.contact_samples,level,destination,s.signal,site.value;
                        facts=isempty(fitted.scope_samples) ? nothing : context,action=id)
                    (;signature,judgment,tested)
                end
                draft = (index=index,action=id,point=destination,reads=[reads;site.event;fitted.reads])
                if observation.judgment == :admitted
                    completion = progress_conditions(progress,context,id)
                    draft = merge(draft,(reads=[draft.reads;completion.reads],))
                    plan = (point=destination,site=site,context=s.signal,field=control.field,
                        conditions=contact_conditions(fitted,observation.signature,context,id),selected_at=event,
                        progress=completion)
                    demanded = relationship == "observed_site_change" ? :enter_only :
                        relationship == "discriminate" ? :unknown : :progress
                    if isnothing(progress.model) || completion.judgment == demanded &&
                            (isnothing(goal) || destination in goal.targets)
                        return route_proposal(control,route,draft,evidence,here;contact_plan=plan)
                    end
                    isnothing(intermediate) && (intermediate=(probe=draft,plan))
                    continue
                end
                if !observation.tested
                    rank = (observation.judgment == :unknown,-row.depth,s.charge)
                    if isnothing(contact_rank) || rank > contact_rank
                        contact_rank = rank
                        contact = (probe=draft,context=s.signal,site=site,signature=observation.signature,
                            facts=context)
                    end
                end
                continue
            end
            opened = destination in control.matched
            if !opened && !haskey(spatial.layouts,destination) && 2count(==(floor),patch) < length(patch)
                continue
            end
            prediction = get!(predictions,(patch,s.signal)) do
                visual_prediction(transitions,patch,s.signal)
            end
            collectible = patch in meter_model.gains
            if isnothing(prediction) && (allequal(patch) || collectible || opened)
                prediction = (value=s.signal,reads=String[])
            end
            predicted = !isnothing(prediction)
            if !predicted
                gain = get!(effect_scores,(patch,s.signal)) do
                    samples = get(transitions,patch,VisualTransition[])
                    any(sample->sample.before == s.signal,samples) && return 0
                    experiment_relevance(samples,s.signal,goals,fitted)
                end
                score = (gain,-row.depth,s.charge)
                if isnothing(best_score) || score > best_score
                    best_score = score
                    witnesses = [sample.event for sample in get(transitions,patch,VisualTransition[])]
                    experiment = (index=index,action=id,point=destination,
                        reads=unique([reads;witnesses;fitted.reads]),gain)
                end
                any(value->contact_judgment(fitted,contact_signature(s.signal,value)) == :admitted,goals) ||
                    continue
                prediction = (value=s.signal,reads=String[])
            end
            meter_key = (id,patch,s.charge,destination in s.spent,destination!=s.point)
            transfer = get!(meter_predictions,meter_key) do
                visual_meter_prediction(control,meter_model,id,patch,s.charge,destination in s.spent;
                    moved=destination!=s.point)
            end
            if isnothing(transfer)
                if current && isnothing(experiment)
                    experiment = (index=index,action=id,point=destination,reads,gain=0)
                    best_score = (0,-row.depth,s.charge)
                end
                continue
            end
            new_charge = transfer.value
            spent = new_charge > s.charge ? extend_visual_set(s.spent,destination) : s.spent
            key = (destination,prediction.value,spent,phase,use_history ? id : 0)
            new_charge > get(visited,key,-1) || continue
            visited[key] = new_charge
            append!(reads,[prediction.reads;transfer.reads])
            push!(route,VisualRouteLink(VisualRouteState(destination,prediction.value,new_charge,spent,phase),
                index,id,reads,predicted,row.depth+1))
        end
    end
    if !isnothing(intermediate)
        return route_proposal(control,route,intermediate.probe,evidence,here;contact_plan=intermediate.plan)
    end
    if !isnothing(contact) && (contact_rank[1] || isnothing(experiment))
        completion = progress_conditions(progress,contact.facts,contact.probe.action)
        plan = (point=contact.probe.point,site=contact.site,context=contact.context,field=control.field,
            conditions=contact_conditions(fitted,contact.signature,contact.facts,contact.probe.action),
            selected_at=event,progress=completion)
        probe = merge(contact.probe,(reads=[contact.probe.reads;completion.reads],))
        return route_proposal(control,route,probe,evidence,here;contact_plan=plan)
    end
    isnothing(experiment) && return nothing
    return route_proposal(control,route,experiment,evidence,here;effect_gain=experiment.gain)
end
