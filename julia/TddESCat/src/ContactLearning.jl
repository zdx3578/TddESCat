struct VisualSite
    field::VisualField
    value::VisualValue
    event::String
end

struct ContactSample
    level::Int
    point::Pixel
    context::VisualValue
    site::VisualSite
    field::VisualField
    origin::Pixel
    action::Int
    outcome::Symbol
    before::String
    event::String
    role::MotionShape
    motion_event::String
end

const CONTACT_COMPARISONS = (:extent, :support, :pigment, :cardinality)

function contact_signature(a::VisualValue, b::VisualValue)
    tests = ((a.width,a.height) == (b.width,b.height),
        (a.width,a.height,a.mask) == (b.width,b.height,b.mask),
        a.pigment == b.pigment, count_ones(a.mask) == count_ones(b.mask))
    return sum(Int(value) << (i-1) for (i,value) in enumerate(tests))
end

struct ContactGuard
    same::Int
    different::Int
end

contact_accepts(guard::ContactGuard, signature) =
    signature & guard.same == guard.same && iszero(signature & guard.different)

const CONTACT_GUARDS = [ContactGuard(same,different)
    for same in 0:(1<<length(CONTACT_COMPARISONS))-1
    for different in 0:(1<<length(CONTACT_COMPARISONS))-1 if iszero(same & different)]

function fit_contact_guards(samples)
    examples = Dict{Tuple{Int,Bool},ContactSample}()
    for sample in samples
        key = (contact_signature(sample.context,sample.site.value),sample.outcome != :blocked)
        get!(examples,key,sample)
    end
    rules = filter(CONTACT_GUARDS) do guard
        all(contact_accepts(guard,signature) == allowed for (signature,allowed) in keys(examples))
    end
    reads = sort!(unique!([ref for sample in values(examples)
        for ref in (sample.before,sample.event,sample.site.event,sample.motion_event)]))
    judgments = map(0:(1<<length(CONTACT_COMPARISONS))-1) do signature
        (isempty(examples) || isempty(rules)) && return :unknown
        votes = count(rule->contact_accepts(rule,signature),rules)
        return votes == 0 ? :blocked : votes == length(rules) ? :admitted : :unknown
    end
    return (;rules,reads,examples,judgments)
end

contact_judgment(fitted, signature) = fitted.judgments[signature+1]

function contact_conditions(fitted, signature)
    judgment = contact_judgment(fitted,signature)
    return (;judgment,signature,
        rules=[(;same=[key for (i,key) in enumerate(CONTACT_COMPARISONS) if !iszero(rule.same & (1<<(i-1)))],
            different=[key for (i,key) in enumerate(CONTACT_COMPARISONS) if !iszero(rule.different & (1<<(i-1)))])
            for rule in fitted.rules],
        sample_events=sort!([sample.event for sample in values(fitted.examples)]),
        reads=fitted.reads)
end

function contact_observed(samples, level, point, context, value)
    return any(sample->sample.level == level && sample.point == point &&
        sample.context == context && sample.site.value == value,samples)
end
