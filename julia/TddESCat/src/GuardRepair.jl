abstract type MotionPredicate end

struct ComponentColor <: MotionPredicate
    at::Pixel
    offsets::Vector{Pixel}
    pigment::UInt8
end

struct RelativeComponentColor <: MotionPredicate
    offset::Pixel
    offsets::Vector{Pixel}
    pigment::UInt8
end

struct DestinationColor <: MotionPredicate
    pigment::UInt8
end

struct TransientColor <: MotionPredicate
    pigment::UInt8
end

struct RecentAction <: MotionPredicate
    id::Int
end

struct HistorySuffix <: MotionPredicate
    actions::Vector{Int}
end

predicate_record(p::ComponentColor) = Dict("kind"=>"component_color", "position"=>p.at,
    "offsets"=>p.offsets, "color"=>Int(p.pigment))
predicate_record(p::RelativeComponentColor) = Dict("kind"=>"relative_component_color", "offset"=>p.offset,
    "offsets"=>p.offsets, "color"=>Int(p.pigment))
predicate_record(p::DestinationColor) = Dict("kind"=>"destination_entry_color", "color"=>Int(p.pigment))
predicate_record(p::TransientColor) = Dict("kind"=>"previous_response_transient_color", "color"=>Int(p.pigment))
predicate_record(p::RecentAction) = Dict("kind"=>"previous_public_action", "id"=>p.id)
predicate_record(p::HistorySuffix) = Dict("kind"=>"public_action_suffix", "actions"=>p.actions)
predicate_key(p) = JSON.json(predicate_record(p))

position_offsets(shape) = [(x, y) for (x, y, _) in shape_template(shape)]

function component_color_at(frame,parts,at,offsets,pigment)
    x, y = at
    checkbounds(Bool, frame, y + 1, x + 1) || return unknown_truth
    shape = parts.groups[parts.owner[y + 1, x + 1]]
    anchor(shape) == at && position_offsets(shape) == offsets || return unknown_truth
    return frame[y + 1, x + 1] == pigment ? proven : disproven
end

function evaluate_predicate(p::ComponentColor, frame, binding, delta, history, parts=color_components(frame))
    return component_color_at(frame,parts,p.at,p.offsets,p.pigment)
end

function evaluate_predicate(p::RelativeComponentColor, frame, binding, delta, history, parts=color_components(frame))
    isnothing(binding) && return unknown_truth
    return component_color_at(frame,parts,binding.anchor .+ p.offset,p.offsets,p.pigment)
end

evaluate_predicate(p::MotionPredicate, frame, binding, delta, history, parts) =
    evaluate_predicate(p,frame,binding,delta,history)

evaluate_predicate(p::MotionPredicate,frame,binding,delta,history,parts,transients) =
    isnothing(parts) ? evaluate_predicate(p,frame,binding,delta,history) :
        evaluate_predicate(p,frame,binding,delta,history,parts)

evaluate_predicate(::TransientColor,frame,binding,delta,history) = unknown_truth

function evaluate_predicate(p::TransientColor,frame,binding,delta,history,parts,transients)
    isnothing(transients) && return unknown_truth
    return p.pigment in transients ? proven : disproven
end

function destination_entry(frame, binding, delta)
    isnothing(binding) && return nothing
    dx, dy = delta
    support = Set((x, y) for (x, y, _) in binding.support)
    target = Set((x + dx, y + dy) for (x, y) in support)
    all(point -> checkbounds(Bool, frame, point[2] + 1, point[1] + 1), target) || return nothing
    entering = setdiff(target, support)
    isempty(entering) && return nothing
    return Set(frame[y + 1, x + 1] for (x, y) in entering)
end

function evaluate_predicate(p::DestinationColor, frame, binding, delta, history)
    colors = destination_entry(frame, binding, delta)
    isnothing(colors) && return unknown_truth
    return colors == Set([p.pigment]) ? proven : disproven
end

function evaluate_predicate(p::RecentAction, frame, binding, delta, history)
    isempty(history) && return unknown_truth
    return last(history) == p.id ? proven : disproven
end

function evaluate_predicate(p::HistorySuffix, frame, binding, delta, history)
    n = length(p.actions)
    length(history) >= n || return unknown_truth
    return history[end - n + 1:end] == p.actions ? proven : disproven
end

function in_context(shape, binding, radius)
    isnothing(binding) && return false
    x0, y0 = binding.anchor
    xmax = maximum(first, binding.support)
    ymax = maximum(cell -> cell[2], binding.support)
    return all(cell -> x0 - radius <= cell[1] <= xmax + radius &&
        y0 - radius <= cell[2] <= ymax + radius, shape)
end

function predicate_pool(samples, template, delta; max_atoms=nothing, context_radii=(1, 2, 4),
                        allow_full_frame=true, history_lengths=(1,),bindings=nothing,relative_support=())
    predicates = Dict{String,MotionPredicate}()
    relative_trials = BitSet(relative_support)
    relative_witnesses = Dict{Tuple{Pixel,UInt8,Vector{Pixel}},Pixel}()
    function add!(predicate)
        key = predicate_key(predicate)
        haskey(predicates, key) && return true
        !isnothing(max_atoms) && length(predicates) >= max_atoms && return false
        predicates[key] = predicate
        return true
    end
    for (index,sample) in enumerate(samples)
        bound = isnothing(bindings) ? bind_motion(sample.before,template) : bindings[index]
        colors = destination_entry(sample.before, bound, delta)
        if !isnothing(colors) && length(colors) == 1
            add!(DestinationColor(only(colors))) ||
                return (pool=collect(values(predicates)), complete=false)
        end
        for color in something(sample.previous_transients,())
            add!(TransientColor(color)) ||
                return (pool=collect(values(predicates)),complete=false)
        end
        for n in history_lengths
            0 < n <= length(sample.previous_actions) || continue
            suffix = sample.previous_actions[end - n + 1:end]
            add!(n == 1 ? RecentAction(only(suffix)) : HistorySuffix(suffix)) ||
                return (pool=collect(values(predicates)), complete=false)
        end
        for shape in color_components(sample.before).groups
            allow_full_frame || any(r -> in_context(shape, bound, r), context_radii) || continue
            at,offsets,color = anchor(shape),position_offsets(shape),first(shape)[3]
            add!(ComponentColor(at,offsets,color)) ||
                return (pool=collect(values(predicates)), complete=false)
            if index in relative_trials && !isnothing(bound) && at != bound.anchor
                offset = at .- bound.anchor
                first_role = get!(relative_witnesses,(offset,color,offsets),bound.anchor)
                if first_role != bound.anchor
                    add!(RelativeComponentColor(offset,offsets,color)) ||
                        return (pool=collect(values(predicates)),complete=false)
                end
            end
        end
    end
    return (pool=collect(values(predicates)), complete=true)
end

function conjunction(atoms, frame, binding, delta, history; transients=nothing)
    uncertain = false
    for predicate in atoms
        value = evaluate_predicate(predicate,frame,binding,delta,history,nothing,transients)
        value == disproven && return disproven
        uncertain |= value == unknown_truth
    end
    return uncertain ? unknown_truth : proven
end

struct GuardSearch
    atoms::Vector{MotionPredicate}
    support::Vector{String}
    excluded::Vector{String}
    unresolved::Vector{String}
    complete::Bool
    feasible::Bool
    visited::Int
end

function search_guards(ids, support, broken, pool, evaluate; max_atoms=nothing, max_work=nothing)
    S, B = BitSet(support), BitSet(broken)
    ideals = []
    distinct = Set{Tuple{BitSet,BitSet}}()
    for predicate in sort(pool; by=predicate_key)
        t = BitSet(i for i in S if evaluate(predicate, i) == proven)
        f = BitSet(i for i in B if evaluate(predicate, i) == disproven)
        (isempty(t) || isempty(f) || (t,f) in distinct) && continue
        push!(distinct,(t,f))
        push!(ideals,(predicate=predicate,t=t,f=f))
    end
    best = Ref{Any}(nothing)
    visited = 0
    complete = true
    function visit(first, selected, survivors, excluded)
        if !isnothing(max_work) && visited == max_work
            complete = false
            return
        end
        visited += 1
        if excluded == B
            rank = (-length(survivors), length(selected), Tuple(selected))
            if isnothing(best[]) || isless(rank, best[].rank)
                best[] = (; rank, selected, survivors, excluded)
            end
            return
        end
        !isnothing(max_atoms) && length(selected) == max_atoms && return
        if !isnothing(best[])
            rank = best[].rank
            (-length(survivors) > rank[1] || -length(survivors) == rank[1] &&
                length(selected) >= rank[2]) && return
        end
        for index in first:length(ideals)
            candidate = ideals[index]
            issubset(candidate.f,excluded) && continue
            new_support = intersect(survivors, candidate.t)
            isempty(new_support) && continue
            visit(index + 1, [selected; index], new_support, union(excluded, candidate.f))
            complete || break
        end
    end
    isempty(S) || visit(1, Int[], S, BitSet())
    if isnothing(best[])
        return GuardSearch(MotionPredicate[], String[], String[], ids[collect(B)], complete, false, visited)
    end
    entry = best[]
    return GuardSearch(MotionPredicate[ideals[i].predicate for i in entry.selected], ids[collect(entry.survivors)],
        ids[collect(entry.excluded)], ids[collect(setdiff(S, entry.survivors))], complete, true, visited)
end

struct MotionClaim
    version::String
    definition::String
    action::Int
    template::MotionShape
    parameter::MotionParameter
    guard::GuardSearch
    support::Vector{String}
    counterexamples::Vector{String}
    unknown_events::Vector{String}
end

function fit_motion_claim(definition, action, template, parameter, samples; max_guard_atoms=nothing,
                          max_guard_work=nothing, context_radii=(1, 2, 4), allow_full_frame=true,
                          history_lengths=(1,))
    rows = [sample for sample in samples if sample.action == action]
    ids = [row.event_id for row in rows]
    allunique(ids) || error("An intervention cannot be counted twice")
    all(ref -> ref in ids, parameter.reads) || error("Parameter provenance is outside this evidence version")
    outcomes = [relation_outcome(row, template, parameter.value) for row in rows]
    S = findall(==(proven), outcomes)
    B = findall(==(disproven), outcomes)
    U = findall(==(unknown_truth), outcomes)
    if isempty(B)
        guard = GuardSearch(MotionPredicate[], ids[S], String[], String[], true, !isempty(S), 1)
    else
        generated = predicate_pool(rows, template, parameter.value;
            max_atoms=max_guard_work, context_radii, allow_full_frame, history_lengths)
        bound = [bind_motion(row.before, template) for row in rows]
        components = [color_components(row.before) for row in rows]
        evaluate = (p, i) -> evaluate_predicate(p, rows[i].before, bound[i], parameter.value,
            rows[i].previous_actions,components[i],rows[i].previous_transients)
        result = search_guards(ids, S, B, generated.pool, evaluate; max_atoms=max_guard_atoms, max_work=max_guard_work)
        guard = GuardSearch(result.atoms, result.support, result.excluded, result.unresolved,
            generated.complete && result.complete, result.feasible, result.visited)
    end
    material = [definition, action, template, parameter.value, parameter.syntax,
        parameter.reads, predicate_record.(guard.atoms), guard.feasible, guard.complete]
    version = "mechanism-" * content_hash(JSON.json(material))
    return MotionClaim(version, definition, action, template, parameter, guard, ids[S], ids[B], ids[U])
end

function claim_record(claim)
    return Dict("version"=>claim.version, "definition_ref"=>claim.definition, "action"=>claim.action,
        "template"=>claim.template, "parameter"=>Dict("delta"=>claim.parameter.value, "syntax"=>claim.parameter.syntax,
        "reads"=>claim.parameter.reads), "condition"=>predicate_record.(claim.guard.atoms),
        "support"=>claim.support, "counterexamples"=>claim.counterexamples, "unknown"=>claim.unknown_events,
        "outstanding"=>unique([claim.guard.unresolved; claim.guard.excluded; claim.unknown_events]),
        "excluded_counterexamples"=>claim.guard.excluded, "search_complete"=>claim.guard.complete,
        "feasible"=>claim.guard.feasible, "query_scope"=>["bound_support_displacement"])
end

"""A finite set of equally consistent, role-relative one-cell boundary conditions."""
struct RoleBoundary <: MotionPredicate
    offsets::Vector{Tuple{Pixel,UInt8}}
    colors::Vector{UInt8}
    reads::Vector{String}
end

function role_boundary_condition(condition)
    at = findfirst(atom->atom isa RoleBoundary,condition.atoms)
    return isnothing(at) ? nothing : condition.atoms[at]
end

predicate_record(p::RoleBoundary) = Dict("kind"=>"motion_role_boundary","offsets"=>p.offsets,
    "witnessed_role_colors"=>p.colors)

function evaluate_predicate(p::RoleBoundary,frame,binding,delta,history)
    isnothing(binding) && return unknown_truth
    first(binding.support)[3] in p.colors || return unknown_truth
    answers = Set{Bool}()
    for ((dx,dy),pigment) in p.offsets
        x,y = binding.anchor .+ (dx,dy)
        checkbounds(Bool,frame,y+1,x+1) || return unknown_truth
        push!(answers,frame[y+1,x+1] == pigment)
        length(answers) == 1 || return unknown_truth
    end
    return only(answers) ? proven : disproven
end

function role_boundary_pixels(shape,frame)
    cells = Set(effect_points(shape))
    origin = anchor(shape)
    result = Set{Tuple{Pixel,UInt8}}()
    for point in cells, step in ((-1,0),(1,0),(0,-1),(0,1))
        x,y = point .+ step
        (x,y) in cells && continue
        checkbounds(Bool,frame,y+1,x+1) || continue
        push!(result,(((x,y) .- origin),frame[y+1,x+1]))
    end
    return result
end
