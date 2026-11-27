struct LocalEffect
    family::Symbol
    before::MotionShape
    after::MotionShape
    values::Vector{Int}
    changed::Vector{Pixel}
    context::NamedTuple
end

struct PublicEffects
    event_id::String
    before_id::String
    action::Dict{String,Int}
    frame_before::Int
    frame_after::Int
    effects::Vector{LocalEffect}
    residual::Vector{Pixel}
    alternatives::Vector{String}
    public_delta::Dict{String,Any}
    complete::Bool
    candidate_roles::Int
    live_meters::Vector{MeterBinding}
    uncertain_meters::Vector{String}
end

effect_points(shape) = Set((x, y) for (x,y,_) in shape)
function group_by_shape(groups)
    by_shape = Dict{MotionShape,Vector{MotionShape}}()
    for shape in groups
        push!(get!(Vector{MotionShape}, by_shape, shape_template(shape)), shape)
    end
    return by_shape
end

function local_effect(family, before, after, values, changed; context=(;))
    covered = sort!(collect(intersect(changed, union(effect_points(before), effect_points(after)))))
    return LocalEffect(family, before, after, values, covered, context)
end

function enclosure_pairs(groups)
    pairs = []
    for surround in groups
        left, top = anchor(surround)
        right = maximum(first, surround)
        bottom = maximum(cell -> cell[2], surround)
        right > left + 1 && bottom > top + 1 || continue
        outline = effect_points(surround)
        center = (left + right) ÷ 2
        interior = findfirst(y->(center,y) ∉ outline,top:bottom)
        isnothing(interior) && continue
        band = interior - 1
        width,height = right-left+1,bottom-top+1
        0 < 2band < min(width,height) || continue
        length(outline) == width*height - (width-2band)*(height-2band) || continue
        all(((x,y),)->min(x-left,right-x,y-top,bottom-y) < band,outline) || continue
        for enclosed in groups
            all(cell -> left+band <= cell[1] <= right-band &&
                top+band <= cell[2] <= bottom-band,enclosed) || continue
            push!(pairs, (signal=surround, target=enclosed))
        end
    end
    return pairs
end

function count_visibility(before, after, disappearing, appearing, changed)
    witnesses = ColorCell[]
    footprint = union(effect_points(disappearing), effect_points(appearing))
    for (x,y) in sort!(collect(footprint))
        for (dx,dy) in FOUR_NEIGHBORS
            u,v = x + dx, y + dy
            checkbounds(Bool, before, v + 1, u + 1) || continue
            (u,v) ∉ footprint && (u,v) ∉ changed || continue
            before[v + 1, u + 1] == after[v + 1, u + 1] || continue
            push!(witnesses, (u,v,before[v + 1,u + 1]))
        end
    end
    return sort!(unique!(witnesses))
end

function observed_public_delta(previous, current; regions=nothing)
    a, b = previous.observation, current.observation
    delta = Dict{String,Any}()
    for (name,left,right) in (("state",a.state,b.state),
            ("levels_completed",a.levels_completed,b.levels_completed),
            ("available_actions",a.available_actions,b.available_actions))
        left == right || (delta[name]=Dict("before"=>left,"after"=>right))
    end
    if length(b.frames) > 1
        earlier = last(a.frames)
        trace = []
        for (index,frame) in enumerate(b.frames)
            changed_pixels = if isnothing(regions)
                change = frame_difference(earlier,frame)
                change isa AbstractVector ? length(change) : nothing
            else
                regions.differences[index]
            end
            push!(trace,Dict("response_frame"=>index-1,"changed_pixels"=>changed_pixels))
            earlier = frame
        end
        delta["response_trace"] = trace
    end
    return delta
end

const SHARED_SCENE_TRANSLATION = "shared_scene_transform_or_joint_motion"

function scene_translation_contrasts(effects,stationary,after)
    offsets = Dict{Pixel,Vector{Pixel}}()
    for effect in effects
        effect.family == :translation || continue
        push!(get!(Vector{Pixel},offsets,Tuple(effect.values)),anchor(effect.before))
    end
    contrasts = NamedTuple[]
    candidates = filter(offsets) do (_,points)
        length(points) >= 3 || return false
        anchors = unique(points)
        length(anchors) >= 3 || return false
        a,b = anchors[1:2]
        return any(c -> (b[1]-a[1])*(c[2]-a[2]) != (b[2]-a[2])*(c[1]-a[1]),anchors[3:end])
    end
    isempty(candidates) && return contrasts
    height,width = size(after)
    interior = filter(group->all(((x,y,_),)->0 < x < width-1 && 0 < y < height-1,group),
        sort!(collect(stationary);by=first))
    for delta in sort!(collect(keys(candidates)))
        dx,dy = delta
        witness = nothing
        for group in interior
            all(((x,y,_),)->checkbounds(Bool,after,y+dy+1,x+dx+1),group) || continue
            mismatch = findfirst(((x,y,c),)->after[y+dy+1,x+dx+1] != c,group)
            isnothing(mismatch) && continue
            x,y,c = group[mismatch]
            at = (x+dx,y+dy)
            witness = (;stationary=group,at,expected=c,actual=after[at[2]+1,at[1]+1])
            break
        end
        push!(contrasts,(;delta,witness))
    end
    return contrasts
end

function observed_effects(previous, current; meters=MeterContext(), before_regions=nothing, after_regions=nothing)
    sample = motion_example(previous, current)
    action = current.observation.action
    frame_before = length(previous.observation.frames) - 1
    frame_after = length(current.observation.frames) - 1
    before, after = sample.before, sample.after
    effects = LocalEffect[]
    alternatives = String[]
    public_delta = observed_public_delta(previous,current;regions=after_regions)
    if size(before) != size(after)
        return PublicEffects(sample.event_id, sample.before_id, action, frame_before, frame_after,
            effects, Pixel[], ["different_frame_domains"], public_delta, false, 0,MeterBinding[],String[])
    end
    changed = Set((pixel.x, pixel.y) for pixel in frame_difference(before, after))
    before_groups = isnothing(before_regions) ? color_components(before).groups : copy(last(before_regions.frames).groups)
    after_groups = isnothing(after_regions) ? color_components(after).groups : copy(last(after_regions.frames).groups)
    candidate_roles = length(before_groups) + length(after_groups)
    meter_context!(meters,previous.observation)
    readings = NamedTuple[]
    live_meters = MeterBinding[]
    uncertain_meters = String[]
    if previous.observation.levels_completed == current.observation.levels_completed
        measured = meter_readings!(meters,before,current.observation.frames,before_groups,
            sample.before_id,sample.event_id)
        readings,live_meters,uncertain_meters = measured.readings,measured.live,measured.unresolved
        isempty(uncertain_meters) || push!(alternatives,"measurement_visibility_unresolved")
    end
    for row in readings
        binding = row.binding
        from,to = first(row.values),last(row.values)
        from == to && continue
        pixels = meter_pixels(binding,from,to)
        push!(effects,LocalEffect(:measurement,meter_support(binding,from),meter_support(binding,to),
            [to-from],pixels,(measurement=meter_contract(),binding,instance=meter_identity(binding),
                before_value=from,after_value=to,response_values=row.values[2:end],
                reads=unique([binding.face.source,binding.calibrated_at,sample.before_id,sample.event_id]))))
    end
    # A certified display profile already explains these supports. Keep the
    # same pixels out of the discrete-component and pigment interpretations.
    if !isempty(readings)
        inside_display(shape) = any(readings) do row
            box = row.binding.face.box
            all(cell->in_window(box,cell[1],cell[2]),shape)
        end
        filter!(shape->!inside_display(shape),before_groups)
        filter!(shape->!inside_display(shape),after_groups)
    end
    B, A = group_by_shape(before_groups), group_by_shape(after_groups)
    static_support = Set(intersect(before_groups,after_groups))
    for key in sort!(collect(intersect(keys(B), keys(A))))
        old, new = B[key], A[key]
        length(old) == length(new) || continue
        departed = filter(s -> s ∉ static_support, old)
        arrived = filter(s -> s ∉ static_support, new)
        isempty(departed) && continue
        if length(departed) == 1 && length(arrived) == 1
            a, b = only(departed), only(arrived)
            delta = anchor(b) .- anchor(a)
            delta != (0,0) || continue
            push!(effects, local_effect(:translation, a, b, collect(delta), changed;
                context=(unmatched_before=length(departed), stationary=length(old) - 1)))
        else
            push!(alternatives, "competing_support_correspondences")
        end
    end
    seen_outline = Set{Pixel}()
    by_anchor = Dict{Pixel,Vector{MotionShape}}()
    for shape in after_groups
        push!(get!(Vector{MotionShape}, by_anchor, anchor(shape)), shape)
    end
    for first in before_groups, second in get(by_anchor, anchor(first), MotionShape[])
        length(first) == length(second) && anchor(first) == anchor(second) &&
            first[1][3] != second[1][3] && effect_points(first) == effect_points(second) || continue
        push!(effects, local_effect(:pigment, first, second, Int[first[1][3],second[1][3]], changed))
        union!(seen_outline, effect_points(first))
    end
    for key in sort!(collect(union(keys(B), keys(A))))
        old, new = get(B, key, MotionShape[]), get(A, key, MotionShape[])
        length(old) == length(new) && continue
        departed = reduce(vcat, filter(s -> s ∉ static_support, old); init=ColorCell[])
        arrived = reduce(vcat, filter(s -> s ∉ static_support, new); init=ColorCell[])
        # A contour changing while part of the same support stays visible does not
        # certify a disappearing/appearing whole component of this prototype.
        any(((x,y,color),)->after[y+1,x+1] == color,departed) && continue
        any(((x,y,color),)->before[y+1,x+1] == color,arrived) && continue
        !isempty(intersect(seen_outline, union(effect_points(departed), effect_points(arrived)))) && continue
        witnesses = count_visibility(before, after, departed, arrived, changed)
        isempty(witnesses) && continue
        affected = local_effect(:count, reduce(vcat, old; init=ColorCell[]),
            reduce(vcat, new; init=ColorCell[]), [length(new) - length(old)], changed;
            context=(prototype=collect(key), before_count=length(old), after_count=length(new), visibility=witnesses))
        isempty(affected.changed) || push!(effects, affected)
    end
    if action["id"] == 6
        from, to = enclosure_pairs(before_groups), enclosure_pairs(after_groups)
        xy = (action["x"], action["y"])
        if length(from) == length(to) == 1
            before_role, after_role = only(from), only(to)
            clicked = [s for s in before_groups if xy in effect_points(s)]
            unique_hit = length(clicked) == 1 && only(clicked) == after_role.target
            if before_role.target != after_role.target && unique_hit
                filter!(effect -> !(effect.family == :translation && effect.before == before_role.signal &&
                    effect.after == after_role.signal),effects)
                pixels = union(effect_points(before_role.signal), effect_points(after_role.signal))
                push!(effects, LocalEffect(:selection, before_role.target, after_role.target, collect(xy),
                    sort!(collect(intersect(changed, pixels))),
                    (before_signal=before_role.signal, after_signal=after_role.signal)))
            end
        elseif !isempty(changed) && (!isempty(from) || !isempty(to))
            push!(alternatives, "ambiguous_selection_binding")
        end
    end
    if haskey(public_delta,"response_trace")
        # Equal snapshots contribute frame evidence to the same public action.
        # A trace with extra visible transitions needs its own interpretation.
        counts = [row["changed_pixels"] for row in public_delta["response_trace"]]
        one_transition = all(!isnothing,counts) && count(>(0),counts) <= 1
        one_transition || push!(alternatives,"intermediate_frames_require_separate_interpretation")
    end
    contrasts = scene_translation_contrasts(effects,static_support,after)
    if !isempty(contrasts)
        public_delta["scene_translation_contrasts"] = contrasts
        push!(alternatives,SHARED_SCENE_TRANSLATION)
    end
    covered = Set(pixel for effect in effects for pixel in effect.changed)
    return PublicEffects(sample.event_id, sample.before_id, action, frame_before, frame_after,
        effects, sort!(collect(setdiff(changed, covered))), unique(alternatives), public_delta,
        isempty(alternatives), candidate_roles,live_meters,uncertain_meters)
end

function endpoint_effects_observed(output::PublicEffects)
    output.complete && return true
    isempty(output.alternatives) && return false
    return all(output.alternatives) do alternative
        if alternative == "intermediate_frames_require_separate_interpretation"
            trace = get(output.public_delta,"response_trace",[])
            return !isempty(trace) && all(row->row["changed_pixels"] isa Int,trace)
        elseif alternative == SHARED_SCENE_TRANSLATION
            contrasts = get(output.public_delta,"scene_translation_contrasts",[])
            return !isempty(contrasts) && all(row->!isnothing(row.witness),contrasts)
        end
        return false
    end
end

scene_translation_unresolved(output::PublicEffects) = SHARED_SCENE_TRANSLATION in output.alternatives

function replay_effects!(observations, episodes)
    for episode in episodes
        all(after->after.observation.action["id"] == 0 || haskey(observations,after.event["event_id"]),
            Iterators.drop(episode,1)) && continue
        meters = MeterContext()
        for (before,after) in zip(episode,Iterators.drop(episode,1))
            after.observation.action["id"] == 0 && continue
            after.event["before_ref"] == before.event["event_id"] || (meters = MeterContext(); continue)
            ref = after.event["event_id"]
            result = observed_effects(before,after;meters)
            if haskey(observations,ref)
                parse_json(JSON.json(public_effect_record(observations[ref]))) ==
                    parse_json(JSON.json(public_effect_record(result))) ||
                    error("Replayed public observation differs from its earlier interpretation")
            else
                observations[ref] = result
            end
        end
    end
    return observations
end

function effect_record(effect::LocalEffect)
    return Dict("family"=>string(effect.family), "before"=>effect.before, "after"=>effect.after,
        "values"=>effect.values, "changed"=>effect.changed, "context"=>effect.context)
end

function public_effect_record(result::PublicEffects)
    return Dict("event_ref"=>result.event_id, "before_ref"=>result.before_id, "action"=>result.action,
        "frames"=>[result.frame_before,result.frame_after], "effects"=>effect_record.(result.effects),
        "residual"=>result.residual, "alternatives"=>result.alternatives,
        "public_delta"=>result.public_delta,"complete"=>result.complete,
        "candidate_roles"=>result.candidate_roles,"live_meters"=>result.live_meters,
        "uncertain_meters"=>result.uncertain_meters)
end

function effect_program(effect, before, after)
    ints = [Literal("Integer", n) for n in effect.values]
    if effect.family == :translation
        return Call("link", before, after, Call("vec", ints...))
    elseif effect.family == :pigment
        return Call("pigment", before, after, [Literal("Color", value) for value in effect.values]...)
    elseif effect.family == :count
        return Call("count_shift", before, after, only(ints))
    elseif effect.family == :measurement
        return Call("display_shift", before, after, only(ints))
    elseif effect.family == :selection
        return Call("selection", before, after, Call("coord", ints...))
    end
    error("No public effect semantics for " * string(effect.family))
end

effect_sort(family,after) = (family == :measurement ? "Measure" : "Role") * (after ? "After" : "Before")

function compose_effects(terms, lo=firstindex(terms), hi=lastindex(terms))
    lo == hi && return terms[lo]
    middle = (lo + hi) ÷ 2
    return Call("pair", compose_effects(terms, lo, middle), compose_effects(terms, middle + 1, hi))
end

function relation_corpus(pairs; previous_signature=nothing, observations=Dict{String,PublicEffects}())
    programs = String[]
    origins = Dict{String,Any}[]
    bindings = Dict{String,Any}()
    observed = [get!(() -> observed_effects(previous,current),observations,current.event["event_id"])
        for (previous,current) in pairs]
    compiled = []
    dispositions = Dict{String,String}()
    values = Set(-64:64)
    for output in observed, effect in output.effects, value in effect.values
        if effect.family in (:count,:measurement)
            push!(values, value)
        end
    end
    if !isnothing(previous_signature)
        for op in previous_signature["operators"]
            op["output"] == "Integer" && isempty(op["inputs"]) || continue
            push!(values, parse(Int, op["symbol"][2:end]))
        end
    end
    signature = typed_motion_signature(((v,0) for v in values))
    registry, _ = registry_from(signature, [])
    slots = Dict{String,Any}[]
    ports = Dict{Tuple{Int,String},Int}()
    for output in observed
        if isempty(output.effects)
            dispositions[output.event_id] = isempty(output.alternatives) ? "no_supported_effect" : "unresolved"
            continue
        end
        if scene_translation_unresolved(output)
            dispositions[output.event_id] = "ambiguous_scene_transform"
            continue
        end
        joined = join_effect_roles(length(output.effects))
        function role_slot(role,effect,after)
            sort = effect_sort(effect.family,after)
            return get!(ports,(role,sort)) do
                index = length(slots)
                push!(slots,Dict("index"=>index,"sort"=>sort,"time_role"=>after ? "after" : "before","role_constraints"=>[]))
                index
            end
        end
        role_slots = [(role_slot(pre,effect,false),role_slot(post,effect,true))
            for (effect,(pre,post)) in zip(output.effects, joined.roles)]
        effect_terms = ConceptTerm[effect_program(effect,Slot(pre),Slot(post))
            for (effect,(pre,post)) in zip(output.effects,role_slots)]
        term = compose_effects(effect_terms)
        rendered = render_term(term)
        syntax = decode_program(rendered,registry)
        index = length(programs)
        push!(programs, rendered)
        dispositions[output.event_id] = output.complete ? "compiled" : "compiled_with_unresolved_interpretation"
        push!(compiled, (output=output, roles=role_slots))
        reference = "effects-" * output.event_id
        bindings[reference] = merge(public_effect_record(output),
            Dict("catlab_event"=>joined.event, "catlab_role_vertices"=>joined.roles, "role_slots"=>last(compiled).roles))
        walk_wire(syntax) do _,path
            push!(origins, Dict("program_index"=>index, "expression_path"=>path,
                "occurrence_id"=>"occ-" * join([index;path],"."),
                "event_ref"=>output.event_id, "interpretation_ref"=>"bounded-event-effects-v1",
                "slot_bindings_ref"=>reference,"support_ref"=>reference,"source_kind"=>"observed"))
        end
    end
    return (; signature, slots, programs, origins, bindings, observed, compiled, dispositions,
        complete=all(output -> output.complete, observed))
end
