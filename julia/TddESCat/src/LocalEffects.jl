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
end

effect_points(shape) = Set((x, y) for (x,y,_) in shape)
shape_key(shape) = Tuple(shape_template(shape))

function group_by_shape(groups)
    by_shape = Dict{Tuple,Vector{MotionShape}}()
    for shape in groups
        push!(get!(Vector{MotionShape}, by_shape, shape_key(shape)), shape)
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
        all(((x, y),) -> (x, y) in outline,
            ((x,y) for y in top:bottom for x in left:right if x in (left,right) || y in (top,bottom))) || continue
        for enclosed in groups
            all(cell -> left < cell[1] < right && top < cell[2] < bottom, enclosed) || continue
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

function observed_public_delta(previous, current)
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
            change = frame_difference(earlier,frame)
            push!(trace,Dict("response_frame"=>index-1,"changed_pixels"=>
                change isa AbstractVector ? length(change) : nothing))
            earlier = frame
        end
        delta["response_trace"] = trace
    end
    return delta
end

function possible_scene_transform(effects)
    offsets = Dict{Tuple,Vector{Pixel}}()
    for effect in effects
        effect.family == :translation || continue
        push!(get!(Vector{Pixel},offsets,Tuple(effect.values)),anchor(effect.before))
    end
    for points in values(offsets)
        length(points) >= 3 || continue
        a,b = points[1:2]
        any(c -> (b[1]-a[1])*(c[2]-a[2]) != (b[2]-a[2])*(c[1]-a[1]),points[3:end]) &&
            return true
    end
    return false
end

function observed_effects(previous, current; max_support_pixels=192, max_effects=8, max_roles=128)
    sample = motion_example(previous, current)
    action = current.observation.action
    frame_before = length(previous.observation.frames) - 1
    frame_after = length(current.observation.frames) - 1
    before, after = sample.before, sample.after
    effects = LocalEffect[]
    alternatives = String[]
    public_delta = observed_public_delta(previous,current)
    if size(before) != size(after)
        return PublicEffects(sample.event_id, sample.before_id, action, frame_before, frame_after,
            effects, Pixel[], ["different_frame_domains"], public_delta, false)
    end
    changed = Set((pixel.x, pixel.y) for pixel in frame_difference(before, after))
    before_groups = filter(shape -> length(shape) <= max_support_pixels, color_components(before).groups)
    after_groups = filter(shape -> length(shape) <= max_support_pixels, color_components(after).groups)
    if length(before_groups) + length(after_groups) > max_roles
        return PublicEffects(sample.event_id, sample.before_id, action, frame_before, frame_after,
            effects, sort!(collect(changed)), ["role_enumeration_budget"], public_delta, false)
    end
    B, A = group_by_shape(before_groups), group_by_shape(after_groups)
    static_support = Set(Tuple(shape) for shape in intersect(before_groups, after_groups))
    for key in sort!(collect(intersect(keys(B), keys(A))))
        old, new = B[key], A[key]
        length(old) == length(new) || continue
        departed = filter(s -> Tuple(s) ∉ static_support, old)
        arrived = filter(s -> Tuple(s) ∉ static_support, new)
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
    for first in before_groups, second in after_groups
        length(first) == length(second) && anchor(first) == anchor(second) &&
            first[1][3] != second[1][3] && effect_points(first) == effect_points(second) || continue
        push!(effects, local_effect(:pigment, first, second, Int[first[1][3],second[1][3]], changed))
        union!(seen_outline, effect_points(first))
    end
    for key in sort!(collect(union(keys(B), keys(A))))
        old, new = get(B, key, MotionShape[]), get(A, key, MotionShape[])
        length(old) == length(new) && continue
        departed = reduce(vcat, filter(s -> Tuple(s) ∉ static_support, old); init=ColorCell[])
        arrived = reduce(vcat, filter(s -> Tuple(s) ∉ static_support, new); init=ColorCell[])
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
        elseif !isempty(changed)
            push!(alternatives, "ambiguous_selection_binding")
        end
    end
    if length(current.observation.frames) > 1
        push!(alternatives, "intermediate_frames_require_separate_interpretation")
    end
    if possible_scene_transform(effects)
        push!(alternatives,"shared_scene_transform_or_joint_motion")
    end
    if length(effects) > max_effects
        resize!(effects, max_effects)
        push!(alternatives, "effect_enumeration_budget")
    end
    covered = Set(pixel for effect in effects for pixel in effect.changed)
    return PublicEffects(sample.event_id, sample.before_id, action, frame_before, frame_after,
        effects, sort!(collect(setdiff(changed, covered))), unique(alternatives), public_delta, isempty(alternatives))
end

function effect_record(effect::LocalEffect)
    return Dict("family"=>string(effect.family), "before"=>effect.before, "after"=>effect.after,
        "values"=>effect.values, "changed"=>effect.changed, "context"=>effect.context)
end

function public_effect_record(result::PublicEffects)
    return Dict("event_ref"=>result.event_id, "before_ref"=>result.before_id, "action"=>result.action,
        "frames"=>[result.frame_before,result.frame_after], "effects"=>effect_record.(result.effects),
        "residual"=>result.residual, "alternatives"=>result.alternatives,
        "public_delta"=>result.public_delta,"complete"=>result.complete)
end

function effect_program(effect, before, after)
    ints = [Literal("Integer", n) for n in effect.values]
    if effect.family == :translation
        return Call("link", before, after, Call("vec", ints...))
    elseif effect.family == :pigment
        return Call("pigment", before, after, [Literal("Color", value) for value in effect.values]...)
    elseif effect.family == :count
        return Call("count_shift", before, after, only(ints))
    end
    return Call("selection", before, after, Call("coord", ints...))
end

function relation_corpus(pairs; max_programs=256, max_ast_nodes=96, max_input_slots=12,
                         max_match_witnesses=10_000)
    programs = String[]
    origins = Dict{String,Any}[]
    bindings = Dict{String,Any}()
    observed = PublicEffects[]
    compiled = []
    complete = true
    max_effects = div(max_input_slots, 2)
    signature = typed_motion_signature(((v,0) for v in -64:64))
    registry, _ = registry_from(signature, [])
    used_slots = 0
    for (previous,current) in pairs
        output = observed_effects(previous,current; max_effects, max_roles=min(max_match_witnesses,512))
        push!(observed, output)
        complete &= output.complete
        isempty(output.effects) && continue
        "shared_scene_transform_or_joint_motion" in output.alternatives && continue
        if length(programs) == max_programs
            complete = false
            continue
        end
        joined = join_effect_roles(length(output.effects), max_match_witnesses)
        if !joined.complete
            complete = false
            continue
        end
        vertices = [role for pair in joined.roles for role in pair]
        slots_by_role = Dict(v=>index - 1 for (index,v) in enumerate(vertices))
        effect_terms = ConceptTerm[effect_program(effect, Slot(slots_by_role[pre]), Slot(slots_by_role[post]))
            for (effect,(pre,post)) in zip(output.effects, joined.roles)]
        if any(n -> abs(n) > 64, Iterators.flatten(effect.values for effect in output.effects))
            complete = false
            continue
        end
        term = reduce((a,b) -> Call("pair", a, b), effect_terms)
        rendered = render_term(term)
        syntax = decode_program(rendered,registry)
        if wire_cost(syntax) > max_ast_nodes
            complete = false
            continue
        end
        index = length(programs)
        push!(programs, rendered)
        used_slots = max(used_slots,length(vertices))
        push!(compiled, (output=output, roles=[(slots_by_role[pre],slots_by_role[post]) for (pre,post) in joined.roles]))
        reference = "effects-" * output.event_id
        bindings[reference] = merge(public_effect_record(output),
            Dict("catlab_event"=>joined.event, "catlab_role_vertices"=>joined.roles, "role_slots"=>last(compiled).roles))
        walk_wire(syntax) do _,path
            push!(origins, Dict("program_index"=>index, "expression_path"=>path,
                "occurrence_id"=>"occ-" * join([index;path],"."),
                "event_ref"=>output.event_id, "interpretation_ref"=>"bounded-event-effects-v1",
                "slot_bindings_ref"=>reference,"support_ref"=>reference))
        end
    end
    slots = [Dict("index"=>index - 1, "sort"=>isodd(index) ? "RoleBefore" : "RoleAfter",
        "time_role"=>isodd(index) ? "before" : "after", "role_constraints"=>[]) for index in 1:used_slots]
    return (; signature, slots, programs, origins, bindings, observed, compiled, complete)
end
