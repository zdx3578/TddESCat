struct VisualSite
    field::VisualField
    value::VisualValue
    event::String
end

struct ContactFacts
    # These candidates were bound in the current instance. Visibility does not
    # certify that the set contains every site in the environment.
    remaining::Vector{Tuple{Pixel,VisualSite}}
    previous_action::Int
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
    facts::ContactFacts
    public_state::String
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

const PROGRESS_VARIABLES = (:remaining_sites, :action, :previous_action)

function progress_value(variable, facts, action)
    variable == :remaining_sites && return length(facts.remaining)
    return variable == :action ? action : facts.previous_action
end

function progress_witnesses(sample)
    return unique([sample.before;sample.event;[site.event for (_,site) in sample.facts.remaining]])
end

function fit_progress_relations(samples)
    # A blocked move answers the admission question. An actual entry can
    # distinguish advancement from completing only an intermediate step.
    entries = filter(sample->sample.outcome in (:entered,:progress),samples)
    outcomes = Bool[sample.outcome == :progress for sample in entries]
    models = Pair{Symbol,FiniteRelation{Int,Bool}}[]
    witnesses = progress_witnesses.(entries)
    reads = sort!(unique!(reduce(vcat,witnesses;init=String[])))
    if any(outcomes) && !all(outcomes)
        for variable in PROGRESS_VARIABLES
            values = [progress_value(variable,sample.facts,sample.action) for sample in entries]
            relation = empirical_relation(values,outcomes,witnesses)
            isnothing(relation) || push!(models,variable=>relation)
        end
    end
    rules = [(variable=variable,rows=sort!(collect(keys(relation.evidence))))
        for (variable,relation) in models]
    model = isempty(models) ? nothing : "progress-" * semantic_hash(
        [[string(row.variable),row.rows] for row in rules])
    return (;models,rules,model,reads,samples=[sample.event for sample in entries])
end

function progress_conditions(fit, facts, action)
    results = [empirical_successor(relation,progress_value(variable,facts,action))
        for (variable,relation) in fit.models]
    verdict = if isempty(results) || any(isnothing,results) || !allequal(results)
        :unknown
    else
        first(results) ? :progress : :enter_only
    end
    return (judgment=verdict,facts,action,model=fit.model,rules=fit.rules,
        sample_events=fit.samples,reads=unique([fit.reads;[site.event for (_,site) in facts.remaining]]))
end
