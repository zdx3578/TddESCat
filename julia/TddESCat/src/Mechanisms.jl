@enum Truth proven disproven unknown_truth

const MotionShape = Vector{ColorCell}

struct MotionExample
    event_id::String
    before_id::String
    action::Int
    before::Matrix{UInt8}
    after::Matrix{UInt8}
    previous_actions::Vector{Int}
    previous_transients::Union{Nothing,Set{UInt8}}
end

MotionExample(id,before_id,action,before,after,history) =
    MotionExample(id,before_id,action,before,after,history,nothing)

struct MotionBinding
    support::MotionShape
    anchor::Pixel
end

function receipt_transient_colors(frames)
    isempty(frames) && return nothing
    start,stop = first(frames),last(frames)
    all(frame->size(frame) == size(start),frames) || return nothing
    colors = Set{UInt8}()
    length(frames) <= 2 && return colors
    for frame in @view(frames[2:end-1]), index in eachindex(frame)
        color = frame[index]
        color != start[index] && color != stop[index] && push!(colors,color)
    end
    return colors
end

function motion_example(previous, current; history=Int[])
    current.event["before_ref"] == previous.event["event_id"] || error("Invalid motion predecessor")
    length(previous.observation.frames) > 0 && length(current.observation.frames) > 0 ||
        error("Missing public frames")
    return MotionExample(current.event["event_id"], previous.event["event_id"], current.observation.action["id"],
        last(previous.observation.frames), last(current.observation.frames), collect(Int, history),
        receipt_transient_colors(previous.observation.frames))
end

anchor(shape) = (minimum(first, shape), minimum(cell -> cell[2], shape))

function shape_template(shape)
    x0, y0 = anchor(shape)
    return [(x - x0, y - y0, color) for (x, y, color) in shape]
end

function bind_motion(frame, template)
    supports = support_candidates(frame)
    matched = [shape for shape in supports if length(shape) == length(template) && shape_template(shape) == template]
    length(matched) == 1 || return nothing
    shape = only(matched)
    return MotionBinding(shape, anchor(shape))
end

function effect_delta(frame, previous::MotionBinding, template)
    next = bind_motion(frame, template)
    isnothing(next) && return nothing
    return next.anchor .- previous.anchor
end

function extract_motion(previous, current)
    grounded = ground_event(previous, current)
    grounded.complete && grounded.changed isa AbstractVector || return nothing
    changed = Set((pixel.x, pixel.y) for pixel in grounded.changed)
    isempty(changed) && return nothing
    candidates = filter(grounded.candidates) do candidate
        candidate.delta != (0, 0) && candidate.full_after_candidate || return false
        before = Dict((x, y) => color for (x, y, color) in candidate.before)
        after = Dict((x, y) => color for (x, y, color) in candidate.after)
        all(key -> (get(before, key, nothing) != get(after, key, nothing)) == (key in changed),
            union(keys(before), keys(after))) && all(key -> haskey(before, key) || haskey(after, key), changed)
    end
    return length(candidates) == 1 ? only(candidates) : nothing
end

function typed_motion_signature(deltas)
    primitives = evidence_signature()
    operators = [
        Dict("symbol"=>name, "inputs"=>op.inputs, "output"=>op.output,
             "purity"=>"pure", "read_rule"=>op.reads .- 1, "binder_children"=>Int[],
             "semantic_version"=>"finite-pixel-v1")
        for (name, op) in sort!(collect(primitives); by=first)
    ]
    values = sort!(unique([value for delta in deltas for value in delta]))
    append!(operators, [
        Dict("symbol"=>"i" * string(value), "inputs"=>String[], "output"=>"Integer",
             "purity"=>"pure", "read_rule"=>Int[], "binder_children"=>Int[], "semantic_version"=>"integer-v1")
        for value in values
    ])
    append!(operators, [
        Dict("symbol"=>"color" * string(value), "inputs"=>String[], "output"=>"Color",
             "purity"=>"pure", "read_rule"=>Int[], "binder_children"=>Int[], "semantic_version"=>"color-v1")
        for value in 0:15
    ])
    return Dict("schema_version"=>3, "signature_id"=>"frame-motion-v1",
        "sorts"=>[Dict{String,Any}("id"=>name) for name in ("Integer", "Color", "Coord", "Delta", "RoleBefore", "RoleAfter", "Relation")],
        "operators"=>operators)
end

function motion_corpus(pairs)
    proposals = []
    for (previous, current) in pairs
        candidate = extract_motion(previous, current)
        isnothing(candidate) && continue
        push!(proposals, (candidate=candidate, sample=motion_example(previous, current)))
    end
    isempty(proposals) && error("No complete unambiguous motion was observed")
    programs = [render_term(historical_program(item.candidate)) for item in proposals]
    signature = typed_motion_signature(item.candidate.delta for item in proposals)
    registry, _ = registry_from(signature, [])
    origins = Dict{String,Any}[]
    bindings = Dict{String,Any}()
    for (index, item) in enumerate(proposals)
        event = item.sample.event_id
        binding = "binding-" * event
        bindings[binding] = Dict("before_event"=>item.sample.before_id, "after_event"=>event,
            "before"=>item.candidate.before, "after"=>item.candidate.after,
            "delta"=>item.candidate.delta)
        walk_wire(decode_program(programs[index], registry)) do _, path
            push!(origins, Dict("program_index"=>index - 1, "expression_path"=>path,
                "occurrence_id"=>"occ-" * join([index - 1; path], "."),
                "event_ref"=>event, "interpretation_ref"=>"finite-pixel-v1",
                "slot_bindings_ref"=>binding, "support_ref"=>binding))
        end
    end
    slots = [Dict("index"=>index - 1, "sort"=>sort,
        "time_role"=>role, "role_constraints"=>[]) for (index, (sort, role)) in
        enumerate((("RoleBefore", "before"), ("RoleAfter", "after")))]
    return (; programs, signature, origins, slots, bindings, proposals)
end

function expand_library_term(term, library; remaining=128)
    remaining > 0 || error("Motion definition expansion limit")
    term["kind"] == "Call" || return term
    args = [expand_library_term(item, library; remaining=remaining - 1) for item in term["args"]]
    name = term["operator"]
    return haskey(library, name) ? expand_library_term(
        instantiate_wire(library[name]["body"], args), library; remaining=remaining - 1) : wire_call(name, args)
end

struct MotionParameter
    value::Pixel
    reads::Vector{String}
    syntax::String
end

function motion_parameters(definition_ref, library, calls, samples; max_terms=32)
    terms = MotionParameter[]
    for call in calls
        call["definition_ref"] == definition_ref || continue
        expanded = expand_library_term(wire_call(definition_ref, call["argument_terms"]), library)
        expanded["kind"] == "Call" && expanded["operator"] == "link" || continue
        before, after, displacement = expanded["args"]
        before == wire_slot(0) && after == wire_slot(1) || continue
        displacement["kind"] == "Call" && displacement["operator"] == "vec" || continue
        all(t -> t["kind"] == "Const" && t["sort"] == "Integer" && strict_integer(t["value"]), displacement["args"]) ||
            continue
        delta = Tuple(Int(t["value"]) for t in displacement["args"])
        source = samples[call["program_index"] + 1].event_id
        any(term -> term.value == delta && term.reads == [source], terms) && continue
        length(terms) < max_terms || return (terms=terms, complete=false, next_source=source)
        push!(terms, MotionParameter(delta, [source], wire_text(displacement)))
    end
    return (terms=terms, complete=true, next_source=nothing)
end

function relation_outcome(sample, template, delta)
    bound = bind_motion(sample.before, template)
    isnothing(bound) && return unknown_truth
    actual = effect_delta(sample.after, bound, template)
    return isnothing(actual) ? unknown_truth : actual == delta ? proven : disproven
end
