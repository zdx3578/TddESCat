struct EffectModel
    family::Symbol
    template::MotionShape
    position::Union{Nothing,Pixel}
    values::Vector{Int}
    visibility::MotionShape
    enclosed::Bool
    measurement::Union{Nothing,MeterBinding}
end

EffectModel(family,template,position,values,visibility,enclosed) =
    EffectModel(family,template,position,values,visibility,enclosed,nothing)

const PixelChange = Tuple{Int,Int,UInt8,UInt8}

struct FramePatch
    shape::Tuple{Int,Int}
    moving::Vector{PixelChange}
    fixed::Vector{PixelChange}
end

struct JointMechanism
    id::String
    action_id::Int
    effects::Vector{EffectModel}
    references::Vector{String}
    training_event::String
    anchors::Vector{Pixel}
    spacing::Vector{Pixel}
    entry_colors::Vector{UInt8}
    parent::Union{Nothing,String}
    patch::Union{Nothing,FramePatch}
end

function frame_patch(output, before, after, anchors)
    output.complete && isempty(output.residual) && isempty(output.public_delta) || return nothing
    moving = Set{Pixel}()
    fixed = Set{Pixel}()
    for effect in output.effects
        effect.family == :measurement && continue
        union!(effect.family == :translation ? moving : fixed, effect.changed)
    end
    isdisjoint(moving, fixed) || return nothing
    shift_x, shift_y = isempty(anchors) ? (0,0) : first(anchors)
    changes(points, dx, dy) = PixelChange[(x-dx,y-dy,before[y+1,x+1],after[y+1,x+1])
        for (x,y) in sort!(collect(points))]
    return FramePatch(size(before), changes(moving,shift_x,shift_y), changes(fixed,0,0))
end

function support_grid(shape)
    cells = Dict((x,y)=>color for (x,y,color) in shape)
    unit = 0
    for ((x,y),color) in cells, (dx,dy) in ((1,0),(0,1))
        get(cells,(x-dx,y-dy),nothing) == color && continue
        width = 1
        while get(cells,(x+width*dx,y+width*dy),nothing) == color
            width += 1
        end
        unit = gcd(unit,width)
    end
    x0,y0 = anchor(shape)
    canonical = sort!(unique([(div(x-x0,unit),div(y-y0,unit),color) for (x,y,color) in shape]))
    length(canonical) * unit^2 == length(shape) ||
        return (unit=1, canonical=shape_template(shape))
    return (;unit,canonical)
end

geometry(shape) = [(x,y) for (x,y,_) in support_grid(shape).canonical]

function flatten_effect_terms(term)
    if term["kind"] == "Call" && term["operator"] == "pair"
        return reduce(vcat, flatten_effect_terms.(term["args"]))
    end
    return [term]
end

function effect_paths(term, path=Int[])
    if term["kind"] == "Call" && term["operator"] == "pair"
        return reduce(vcat,[effect_paths(child,[path; i-1]) for (i,child) in enumerate(term["args"])])
    end
    return [path]
end

function projection_references(indices, original, calls, occurrences)
    paths = effect_paths(original)
    evidence = Set{String}()
    for path in paths[indices]
        refs = String[]
        for call in calls
            covered = any(call["source_occurrences"]) do ref
                at = occurrences[ref]
                length(at) >= length(path) && at[1:length(path)] == path
            end
            covered && push!(refs,call["definition_ref"])
        end
        isempty(refs) && return String[]
        union!(evidence,refs)
    end
    return sort!(collect(evidence))
end

function joint_model(compiled, program, original, definitions, calls, occurrences, before, after)
    isempty(calls) && return nothing
    expanded = expand_library_term(program, definitions)
    effects = compiled.output.effects
    terms = flatten_effect_terms(expanded)
    length(terms) == length(effects) || error("Published effects differ from the certified relation")
    int_value(term) = term["value"]::Int
    enclosed = enclosure_pairs(public_components(before))
    enclosed_targets = [item.target for item in enclosed]
    models = EffectModel[]
    moving = MotionShape[]
    for (effect, term, (pre, post)) in zip(effects, terms, compiled.roles)
        expected = decode_model_term(effect, pre, post)
        term == expected || error("A published effect does not use its typed binding")
        before_role = effect.before
        parameters = term["args"][3:end]
        values = effect.family in (:translation,:selection) ? int_value.(only(parameters)["args"]) : int_value.(parameters)
        if effect.family == :translation
            push!(moving, before_role)
        end
        meter = effect.family == :measurement ? effect.context.binding : nothing
        prototype = effect.family == :count ? effect.context.prototype :
            isnothing(meter) ? shape_template(before_role) : MotionShape()
        position = effect.family == :pigment ? anchor(before_role) : nothing
        visibility = effect.family == :count ? effect.context.visibility : ColorCell[]
        push!(models, EffectModel(effect.family, prototype, position, values, visibility,
            effect.family == :translation && before_role in enclosed_targets,meter))
    end
    anchors = anchor.(moving)
    spacing = isempty(anchors) ? Pixel[] : [a .- first(anchors) for a in anchors]
    old_support = Set(pixel for shape in moving for pixel in effect_points(shape))
    entering = Set{Pixel}()
    for (effect, model) in zip(effects, models)
        effect.family == :translation || continue
        dx,dy = model.values
        union!(entering, setdiff(Set((x+dx,y+dy) for (x,y,_) in effect.before), old_support))
    end
    entry_colors = sort!(unique(UInt8[before[y+1,x+1] for (x,y) in entering]))
    references = sort!(unique(String[call["definition_ref"] for call in calls]))
    id = "joint-" * content_hash(JSON.json([compiled.output.event_id, references, compiled.roles]))
    action = compiled.output.action["id"]
    event = compiled.output.event_id
    patch = frame_patch(compiled.output,before,after,anchors)
    joint = JointMechanism(id,action,models,references,event,anchors,spacing,entry_colors,nothing,patch)
    moved = findall(effect->effect.family == :translation,models)
    (isempty(moved) || length(moved) == length(models)) && return [joint]
    projected = projection_references(moved,original,calls,occurrences)
    isempty(projected) && return [joint]
    subid = "joint-" * content_hash(JSON.json([id,moved,projected]))
    return [joint,JointMechanism(subid,action,models[moved],projected,event,anchors,spacing,entry_colors,id,nothing)]
end

function decode_model_term(effect, pre, post)
    convert(term::Literal) = wire_const(term.sort, term.value)
    convert(term::Slot) = wire_slot(term.index)
    convert(term::Call) = wire_call(term.name, convert.(term.children))
    return convert(effect_program(effect, Slot(pre), Slot(post)))
end

function read_joint_mechanisms(published, corpus, pairs)
    bundle = published.bundle
    bundle["source_programs"] == corpus.programs && bundle["origins"] == corpus.origins ||
        error("Released training sources differ from public evidence")
    registry, definitions = registry_from(bundle["signature"], published.snapshot.entries)
    occurrences = Dict(row["occurrence_id"]=>row["expression_path"] for row in bundle["origins"])
    frames = Dict(post.event["event_id"]=>(last(pre.observation.frames),last(post.observation.frames))
        for (pre,post) in pairs)
    models = JointMechanism[]
    for (index, (text, compiled)) in enumerate(zip(bundle["rewritten_programs"], corpus.compiled))
        calls = filter(call -> call["program_index"] == index - 1, bundle["calls"])
        original = decode_program(corpus.programs[index],registry)
        learned = joint_model(compiled,decode_program(text,registry),original,definitions,calls,
            occurrences,frames[compiled.output.event_id]...)
        isnothing(learned) || append!(models,learned)
    end
    return models
end

binding_view(model) = model.enclosed ? "geometry-support" : "color-support"

function model_binding(model, groups, enclosed_targets)
    if model.enclosed
        candidates = filter(s -> geometry(s) == geometry(model.template), enclosed_targets)
    else
        expected = support_grid(model.template).canonical
        candidates = filter(s -> support_grid(s).canonical == expected, groups)
    end
    return length(candidates) == 1 ? only(candidates) : nothing
end

function model_count(model, frame, groups)
    all(cell -> checkbounds(Bool, frame, cell[2]+1,cell[1]+1) &&
        frame[cell[2]+1,cell[1]+1] == cell[3], model.visibility) || return nothing
    return count(s -> shape_template(s) == model.template, groups)
end

function result_model(model, before, groups, enclosure, action; meters=())
    if model.family == :translation
        bound = model_binding(model, groups, [role.target for role in enclosure])
        isnothing(bound) && return nothing
        source_unit, observed_unit = support_grid(model.template).unit, support_grid(bound).unit
        scaled = model.values .* observed_unit
        all(v -> mod(v,source_unit) == 0,scaled) || return nothing
        return (family=:translation, basis=bound, expected=Tuple(div.(scaled,source_unit)), value=anchor(bound))
    elseif model.family == :count
        n = model_count(model, before, groups)
        isnothing(n) && return nothing
        support = sort!(reduce(vcat,(part for part in groups if shape_template(part) == model.template);init=ColorCell[]))
        return (family=:count,basis=n,expected=n+only(model.values),value=n,token_support=support,
            instance=semantic_hash(["discrete-component-count",model.template]))
    elseif model.family == :measurement
        binding = match_meter(model.measurement,meters)
        isnothing(binding) && return nothing
        n = read_meter(before,binding)
        isnothing(n) && return nothing
        return (family=:measurement,basis=n,expected=n+only(model.values),value=n,binding,
            instance=meter_identity(binding))
    elseif model.family == :pigment
        x,y = model.position
        seen = [s for s in groups if anchor(s) == model.position && position_offsets(s) == position_offsets(model.template)]
        length(seen) == 1 || return nothing
        bound = only(seen)
        return (family=:pigment, basis=bound, expected=last(model.values), value=Int(before[y+1,x+1]))
    elseif model.family != :selection
        error("No joint consumer for " * string(model.family))
    end
    length(enclosure) == 1 || return nothing
    xy = (action["x"],action["y"])
    control_shape = only(enclosure).target
    targets = [shape for shape in groups if xy in effect_points(shape) &&
        geometry(shape) == geometry(model.template) &&
        position_offsets(shape) == position_offsets(control_shape)]
    length(targets) == 1 || return nothing
    return (family=:selection, basis=only(targets), expected=anchor(only(targets)), value=anchor(only(enclosure).target))
end

function evaluate_joint_rule(rule, before, groups, enclosure, action; meters=())
    fragments = [result_model(effect,before,groups,enclosure,action;meters) for effect in rule.effects]
    any(isnothing,fragments) && return (truth=unknown_truth, fragments, reason="incomplete_effect_binding")
    for (effect,fragment) in zip(rule.effects, fragments)
        if effect.family == :count && fragment.expected < 0
            return (truth=disproven, fragments, reason="resource_precondition")
        elseif effect.family == :measurement && !(0 <= fragment.expected <= meter_length(fragment.binding.face.box))
            return (truth=disproven,fragments,reason="resource_precondition")
        elseif effect.family == :pigment && fragment.value != first(effect.values)
            return (truth=disproven, fragments, reason="observed_color_precondition")
        elseif effect.family == :selection && fragment.expected == fragment.value
            return (truth=disproven, fragments, reason="selection_already_matches")
        end
    end
    movers = filter(item->item.family == :translation,fragments)
    anchors = [item.value for item in movers]
    if !isempty(anchors)
        spacing = [p .- first(anchors) for p in anchors]
        first_model = findfirst(effect -> effect.family == :translation,rule.effects)
        trained_unit = support_grid(rule.effects[first_model].template).unit
        bound_unit = support_grid(first(movers).basis).unit
        aligned = length(spacing) == length(rule.spacing) &&
            all(actual .* trained_unit == trained .* bound_unit for (actual,trained) in zip(spacing,rule.spacing))
        if !allunique(anchors) || !aligned
            return (truth=disproven, fragments, reason="joint_role_placement")
        end
        if any(part->part.family == :count, fragments) && anchors != rule.anchors
            return (truth=unknown_truth, fragments, reason="resource_interaction_scope")
        end
        prior = Set(pixel for item in movers for pixel in effect_points(item.basis))
        destination = Set((x+item.expected[1],y+item.expected[2]) for item in movers for (x,y,_) in item.basis)
        all(((x,y),)->checkbounds(Bool,before,y+1,x+1),destination) ||
            return (truth=unknown_truth,fragments,reason="unobserved_destination")
        colors = sort!(unique(UInt8[before[y+1,x+1] for (x,y) in setdiff(destination,prior)]))
        colors == rule.entry_colors || return (truth=disproven,fragments,reason="entry_colors_out_of_scope")
    end
    return (truth=proven, fragments, reason="published_joint_effects")
end

function scope_key(fragment)
    # Include the operand binding so two moving roles remain separate channels.
    match = fragment.family == :translation ? fragment.value :
        fragment.family in (:count,:measurement) ? fragment.instance :
        anchor(fragment.basis)
    return string(fragment.family) * "-" * (match isa Tuple ? join(match,"-") : string(match))
end

function plan_channels(fragments)
    scope = Dict{String,Any}()
    for part in fragments
        key = scope_key(part)
        haskey(scope,key) && return nothing
        scope[key] = part.expected
    end
    return scope
end

function judge_joint(models, denied, before, action)
    groups = filter(s -> length(s) <= 96, color_components(before).groups)
    enclosure = enclosure_pairs(groups)
    choices = []
    reasons = String[]
    for model in models
        model.action_id == action["id"] && model.id ∉ denied || continue
        evaluation = evaluate_joint_rule(model,before,groups,enclosure,action)
        push!(reasons,evaluation.reason)
        evaluation.truth == proven || continue
        channels = plan_channels(evaluation.fragments)
        isnothing(channels) || push!(choices,(; model, channels, evaluation.fragments))
    end
    isempty(choices) && return (choice=nothing, reason=join(sort!(unique(reasons)),","))
    if any(choice->choice.channels != first(choices).channels, choices)
        return (choice=nothing,reason="competing_effects")
    end
    return (choice=first(choices),reason="published_joint_effects")
end

function measure_joint(choice, after)
    groups = public_components(after)
    enclosure = enclosure_pairs(groups)
    actual = Dict{String,Any}()
    assessments = Dict{String,String}()
    for (model,part) in zip(choice.model.effects,choice.fragments)
        value = if part.family == :translation
            corresponding = model_binding(model,groups,[role.target for role in enclosure])
            isnothing(corresponding) ? nothing : anchor(corresponding) .- part.value
        elseif part.family == :count
            model_count(model,after,groups)
        elseif part.family == :measurement
            read_meter(after,part.binding)
        elseif part.family == :pigment
            matches = filter(s -> anchor(s) == model.position &&
                position_offsets(s) == position_offsets(model.template), groups)
            length(matches) == 1 ? Int(first(only(matches))[3]) : nothing
        elseif part.family == :selection
            length(enclosure) == 1 ? anchor(only(enclosure).target) : nothing
        else
            error("No public feedback semantics for " * string(part.family))
        end
        name = scope_key(part)
        actual[name] = value
        assessments[name] = isnothing(value) ? "unknown" : value == part.expected ? "supported" : "refuted"
    end
    return (; actual, assessments)
end
