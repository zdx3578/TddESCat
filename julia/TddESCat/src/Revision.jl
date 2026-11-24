struct MotionJudgment
    predicate::Truth
    expected::Union{Nothing,Pixel}
    bound::Union{Nothing,MotionBinding}
    reads::Vector{String}
    reason::String
end

mutable struct MotionController
    claim::MotionClaim
    samples::Vector{MotionExample}
    seen_events::Set{String}
    cache::Dict{Tuple{String,String,Int,Tuple},MotionJudgment}
    guard_limits::NamedTuple
end

function MotionController(claim, samples; guard_limits=(;))
    saved = collect(MotionExample, samples)
    seen = Set(row.event_id for row in saved)
    length(saved) == length(seen) || error("Duplicate training intervention")
    return MotionController(claim, saved, seen, Dict(), guard_limits)
end

struct FrozenMotionPolicy
    claim::MotionClaim
end

freeze_motion(controller::MotionController) = FrozenMotionPolicy(deepcopy(controller.claim))

truth_wire(t) = t == unknown_truth ? "unknown" : t == proven

function judge_motion(claim, action, frame, event_id, history; transients=nothing)
    reads = [event_id, claim.version, claim.definition]
    if action != claim.action
        return MotionJudgment(unknown_truth, nothing, nothing, reads, "uncovered_action")
    end
    if !claim.guard.feasible
        return MotionJudgment(unknown_truth, nothing, nothing, reads, "unresolved_condition")
    end
    bound = bind_motion(frame, claim.template)
    isnothing(bound) && return MotionJudgment(unknown_truth, nothing, nothing, reads, "ambiguous_or_missing_support")
    predicate = conjunction(claim.guard.atoms, frame, bound, claim.parameter.value, history;transients)
    predicate == proven && return MotionJudgment(proven, claim.parameter.value, bound, reads, "learned_support_translation")
    return MotionJudgment(predicate, nothing, bound, reads,
        predicate == disproven ? "condition_false" : "condition_evidence_unavailable")
end

cached_judgment(policy::FrozenMotionPolicy, action, frame, event_id, history; transients=nothing) =
    judge_motion(policy.claim, action, frame, event_id, history;transients)

function cached_judgment(controller, action, frame, event_id, history; transients=nothing)
    key = (controller.claim.version, event_id, action, Tuple(history))
    return get!(controller.cache, key) do
        judge_motion(controller.claim, action, frame, event_id, history;transients)
    end
end

function invalidate_motion!(controller, previous)
    invalidated = String[]
    for (key, judgment) in collect(controller.cache)
        if previous in judgment.reads
            push!(invalidated, key[2] * "-action-" * string(key[3]))
            delete!(controller.cache, key)
        end
    end
    return sort!(unique(invalidated))
end

function measure_motion(claim, sample)
    sample.action == claim.action || return nothing
    binding = bind_motion(sample.before, claim.template)
    return isnothing(binding) ? nothing : effect_delta(sample.after, binding, claim.template)
end

function response_verdict(judgment, actual)
    if isnothing(judgment.expected) || isnothing(actual)
        return "unknown"
    end
    return actual == judgment.expected ? "supported" : "refuted"
end

function assess_motion!(controller::MotionController, sample::MotionExample, judgment)
    sample.event_id in controller.seen_events && error("Feedback already processed")
    push!(controller.seen_events, sample.event_id)
    push!(controller.samples, sample)
    old = controller.claim
    actual = measure_motion(old, sample)
    verdict = response_verdict(judgment, actual)
    sample.action == old.action || return (status=verdict, actual=actual, revision=nothing)
    # Feedback can constrain a hypothesis even when the old version abstained.
    current = fit_motion_claim(old.definition, old.action, old.template,
        old.parameter, controller.samples; controller.guard_limits...)
    controller.claim = current
    current.version == old.version && return (status=verdict, actual=actual, revision=nothing)
    invalidated = invalidate_motion!(controller, old.version)
    kind, status = if !old.guard.feasible && current.guard.feasible
        "condition_recovered", "recovered"
    elseif verdict == "refuted"
        "effect_counterexample", "revised"
    else
        "new_public_evidence", "refined"
    end
    revision = Dict("kind"=>kind, "event_ref"=>sample.event_id, "withdrawn"=>old.version,
        "replacement"=>current.version, "invalidated"=>invalidated, "definition_ref"=>current.definition,
        "outstanding"=>claim_record(current)["outstanding"])
    return (; status, actual, revision)
end

function assess_motion!(policy::FrozenMotionPolicy, sample::MotionExample, judgment)
    actual = measure_motion(policy.claim, sample)
    return (status=response_verdict(judgment, actual), actual=actual, revision=nothing)
end

function factor_query(rows, abstraction, query)
    known = Dict()
    unknown_rows = []
    for row in rows
        value = query(row)
        if isnothing(value) || value === unknown_truth
            push!(unknown_rows, row)
            continue
        end
        key = abstraction(row)
        if haskey(known, key) && known[key].value != value
            return (witness=(known[key].row, row), unknown=unknown_rows)
        end
        known[key] = (; row, value)
    end
    return (witness=nothing, unknown=unknown_rows)
end
