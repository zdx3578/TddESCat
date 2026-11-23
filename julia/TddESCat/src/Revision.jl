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
    cache::Dict{Tuple{String,String,Int,Tuple},MotionJudgment}
end

MotionController(claim, samples) = MotionController(claim, collect(MotionExample, samples), Dict())

truth_wire(t) = t == unknown_truth ? "unknown" : t == proven

function judge_motion(claim, action, frame, event_id, history)
    reads = [event_id, claim.version, claim.definition]
    if action != claim.action || !claim.guard.feasible
        return MotionJudgment(unknown_truth, nothing, nothing, reads, "uncovered_action")
    end
    bound = bind_motion(frame, claim.template)
    isnothing(bound) && return MotionJudgment(unknown_truth, nothing, nothing, reads, "ambiguous_or_missing_support")
    predicate = conjunction(claim.guard.atoms, frame, bound, claim.parameter.value, history)
    predicate == proven && return MotionJudgment(proven, claim.parameter.value, bound, reads, "learned_support_translation")
    return MotionJudgment(predicate, nothing, bound, reads,
        predicate == disproven ? "condition_false" : "condition_evidence_unavailable")
end

function cached_judgment(controller, action, frame, event_id, history)
    key = (controller.claim.version, event_id, action, Tuple(history))
    return get!(controller.cache, key) do
        judge_motion(controller.claim, action, frame, event_id, history)
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

function observed_check(controller, action, judgment, previous, after, history)
    sample = motion_example(previous, after; history)
    if isnothing(judgment.expected)
        action == controller.claim.action && push!(controller.samples, sample)
        return (status="unknown", actual=nothing, revision=nothing)
    end
    actual = effect_delta(sample.after, judgment.bound, controller.claim.template)
    isnothing(actual) && return (status="unknown", actual=nothing, revision=nothing)
    push!(controller.samples, sample)
    actual == judgment.expected && return (status="supported", actual=actual, revision=nothing)
    old = controller.claim
    current = fit_motion_claim(old.definition, action, old.template, old.parameter, controller.samples)
    invalidated = invalidate_motion!(controller, old.version)
    controller.claim = current
    revision = Dict("kind"=>"effect_counterexample", "event_ref"=>sample.event_id, "withdrawn"=>old.version,
        "replacement"=>current.version, "invalidated"=>invalidated, "definition_ref"=>current.definition,
        "outstanding"=>claim_record(current)["outstanding"])
    return (status="revised", actual=actual, revision=revision)
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
