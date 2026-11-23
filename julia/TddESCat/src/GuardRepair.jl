abstract type MotionPredicate end

struct ComponentColor <: MotionPredicate
    at::Pixel
    offsets::Vector{Pixel}
    pigment::UInt8
end

struct DestinationColor <: MotionPredicate
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
predicate_record(p::DestinationColor) = Dict("kind"=>"destination_entry_color", "color"=>Int(p.pigment))
predicate_record(p::RecentAction) = Dict("kind"=>"previous_public_action", "id"=>p.id)
predicate_record(p::HistorySuffix) = Dict("kind"=>"public_action_suffix", "actions"=>p.actions)
predicate_key(p) = JSON.json(predicate_record(p))

position_offsets(shape) = [(x, y) for (x, y, _) in shape_template(shape)]

function evaluate_predicate(p::ComponentColor, frame, binding, delta, history)
    parts = color_components(frame)
    x, y = p.at
    checkbounds(Bool, frame, y + 1, x + 1) || return unknown_truth
    shape = parts.groups[parts.owner[y + 1, x + 1]]
    anchor(shape) == p.at && position_offsets(shape) == p.offsets || return unknown_truth
    return frame[y + 1, x + 1] == p.pigment ? proven : disproven
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

function predicate_pool(samples, template, delta; max_atoms=192, context_radii=(1, 2, 4),
                        allow_full_frame=true, history_lengths=(1,))
    predicates = Dict{String,MotionPredicate}()
    function add!(predicate)
        key = predicate_key(predicate)
        haskey(predicates, key) && return true
        length(predicates) >= max_atoms && return false
        predicates[key] = predicate
        return true
    end
    for sample in samples
        bound = bind_motion(sample.before, template)
        colors = destination_entry(sample.before, bound, delta)
        if !isnothing(colors) && length(colors) == 1
            add!(DestinationColor(only(colors))) ||
                return (pool=collect(values(predicates)), complete=false)
        end
        for n in history_lengths
            0 < n <= length(sample.previous_actions) || continue
            suffix = sample.previous_actions[end - n + 1:end]
            add!(n == 1 ? RecentAction(only(suffix)) : HistorySuffix(suffix)) ||
                return (pool=collect(values(predicates)), complete=false)
        end
        for shape in color_components(sample.before).groups
            1 <= length(shape) <= 96 || continue
            allow_full_frame || any(r -> in_context(shape, bound, r), context_radii) || continue
            add!(ComponentColor(anchor(shape), position_offsets(shape), first(shape)[3])) ||
                return (pool=collect(values(predicates)), complete=false)
        end
    end
    return (pool=collect(values(predicates)), complete=true)
end

function conjunction(atoms, frame, binding, delta, history)
    uncertain = false
    for predicate in atoms
        value = evaluate_predicate(predicate, frame, binding, delta, history)
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

function search_guards(ids, support, broken, pool, evaluate; max_atoms=2, max_work=4096)
    S, B = BitSet(support), BitSet(broken)
    ideals = []
    for predicate in sort(pool; by=predicate_key)
        t = BitSet(i for i in S if evaluate(predicate, i) == proven)
        f = BitSet(i for i in B if evaluate(predicate, i) == disproven)
        isempty(t) || isempty(f) || push!(ideals, (predicate=predicate, t=t, f=f))
    end
    best = Ref{Any}(nothing)
    remaining = max_work
    complete = true
    function visit(first, selected, survivors, excluded)
        if remaining == 0
            complete = false
            return
        end
        remaining -= 1
        if excluded == B
            rank = (-length(survivors), length(selected), Tuple(selected))
            if isnothing(best[]) || isless(rank, best[].rank)
                best[] = (; rank, selected, survivors, excluded)
            end
            return
        end
        length(selected) < max_atoms || return
        for index in first:length(ideals)
            candidate = ideals[index]
            new_support = intersect(survivors, candidate.t)
            isempty(new_support) && continue
            visit(index + 1, [selected; index], new_support, union(excluded, candidate.f))
            complete || break
        end
    end
    isempty(S) || visit(1, Int[], S, BitSet())
    visited = max_work - remaining
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

function fit_motion_claim(definition, action, template, parameter, samples; max_guard_atoms=2,
                          max_guard_work=4096, context_radii=(1, 2, 4), allow_full_frame=true,
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
        evaluate = (p, i) -> evaluate_predicate(p, rows[i].before, bound[i], parameter.value, rows[i].previous_actions)
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
