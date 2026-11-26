struct VisualSite
    field::VisualField
    value::VisualValue
    event::String
end

const CONTACT_DOMAIN = "observed-site-obligations-v3"

struct ContactFacts
    # These candidates were bound in the current instance. Visibility does not
    # certify that the set contains every site in the environment.
    remaining::Vector{Tuple{Pixel,VisualSite}}
    previous_action::Int
    domain_version::String
    domain_reads::Vector{String}
end

ContactFacts(remaining,previous_action,reads=String[]) = ContactFacts(remaining,previous_action,CONTACT_DOMAIN,reads)

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

admission_witnesses(sample) = unique([sample.before,sample.event,sample.site.event,sample.motion_event])

function scoped_admission_value(variable, signature, facts, action)
    return (signature, variable == :signature ? 0 : progress_value(variable,facts,action))
end

function fit_scoped_admission(samples)
    outcomes = Bool[sample.outcome != :blocked for sample in samples]
    witnesses = [unique([admission_witnesses(sample);progress_witnesses(sample)]) for sample in samples]
    signatures = [contact_signature(sample.context,sample.site.value) for sample in samples]
    models = Pair{Symbol,FiniteRelation{Tuple{Int,Int},Bool}}[]
    for variable in (:signature,PROGRESS_VARIABLES...)
        values = [scoped_admission_value(variable,signature,sample.facts,sample.action)
            for (signature,sample) in zip(signatures,samples)]
        relation = empirical_relation(values,outcomes,witnesses)
        isnothing(relation) && continue
        push!(models,variable=>relation)
        variable == :signature && break
    end
    return models,sort!(unique!(reduce(vcat,witnesses;init=String[])))
end

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
    scope_samples = isempty(rules) ? samples : ContactSample[]
    scoped, scope_reads = isempty(scope_samples) ?
        (Pair{Symbol,FiniteRelation{Tuple{Int,Int},Bool}}[],String[]) : fit_scoped_admission(scope_samples)
    return (;rules,reads=sort!(unique!([reads;scope_reads])),examples,judgments,
        scoped,scope_samples,scope_reads)
end

function contact_judgment(fitted, signature, facts=nothing, action=0)
    if isempty(fitted.scoped) || isnothing(facts)
        return fitted.judgments[signature+1]
    end
    votes = [empirical_successor(relation,scoped_admission_value(variable,signature,facts,action))
        for (variable,relation) in fitted.scoped]
    (any(isnothing,votes) || !allequal(votes)) && return :unknown
    return first(votes) ? :admitted : :blocked
end

function contact_conditions(fitted, signature, facts, action)
    judgment = contact_judgment(fitted,signature,facts,action)
    return (;judgment,signature,
        rules=[(;same=[key for (i,key) in enumerate(CONTACT_COMPARISONS) if !iszero(rule.same & (1<<(i-1)))],
            different=[key for (i,key) in enumerate(CONTACT_COMPARISONS) if !iszero(rule.different & (1<<(i-1)))])
            for rule in fitted.rules],
        sample_events=sort!([sample.event for sample in values(fitted.examples)]),
        scope_events=[sample.event for sample in fitted.scope_samples],
        scope_rules=[(variable=variable,rows=sort!(collect(keys(relation.evidence))))
            for (variable,relation) in fitted.scoped],reads=fitted.reads)
end

function contact_observed(samples, level, point, context, value; facts=nothing, action=0)
    return any(samples) do sample
        same = sample.level == level && sample.point == point &&
            sample.context == context && sample.site.value == value
        return same && (isnothing(facts) ||
            (sample.facts.previous_action == facts.previous_action && sample.action == action &&
                length(sample.facts.remaining) == length(facts.remaining)))
    end
end

const PROGRESS_VARIABLES = (:remaining_sites, :action, :previous_action)
const JOINT_PROGRESS_VARIABLES = [(PROGRESS_VARIABLES[i],PROGRESS_VARIABLES[j])
    for i in eachindex(PROGRESS_VARIABLES) for j in i+1:length(PROGRESS_VARIABLES)]

function progress_value(variable, facts, action)
    variable == :remaining_sites && return length(facts.remaining)
    return variable == :action ? action : facts.previous_action
end

progress_value(variables::Tuple, facts, action) =
    Tuple(progress_value(variable,facts,action) for variable in variables)
uses_progress_history(variable::Symbol) = variable == :previous_action
uses_progress_history(variables::Tuple) = :previous_action in variables

function progress_witnesses(sample)
    return unique([sample.before;sample.event;sample.facts.domain_reads;
        [site.event for (_,site) in sample.facts.remaining]])
end

function fit_progress_relations(samples)
    # A blocked move answers the admission question. An actual entry can
    # distinguish advancement from completing only an intermediate step.
    entries = filter(samples) do sample
        sample.outcome in (:entered,:progress) && sample.point in first.(sample.facts.remaining)
    end
    outcomes = Bool[sample.outcome == :progress for sample in entries]
    models = Pair{Any,FiniteRelation}[]
    witnesses = progress_witnesses.(entries)
    reads = sort!(unique!(reduce(vcat,witnesses;init=String[])))
    if any(outcomes) && !all(outcomes)
        for variables in (PROGRESS_VARIABLES,JOINT_PROGRESS_VARIABLES)
            for variable in variables
                values = [progress_value(variable,sample.facts,sample.action) for sample in entries]
                relation = empirical_relation(values,outcomes,witnesses)
                isnothing(relation) || push!(models,variable=>relation)
            end
            isempty(models) || break
        end
    end
    rules = [(variable=variable,rows=sort!(collect(keys(relation.evidence))))
        for (variable,relation) in models]
    model = isempty(models) ? nothing : "progress-" * semantic_hash(
        [CONTACT_DOMAIN,[[row.variable isa Tuple ? string.(row.variable) : string(row.variable),row.rows]
            for row in rules]])
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
        sample_events=fit.samples,reads=unique([fit.reads;facts.domain_reads;
            [site.event for (_,site) in facts.remaining]]))
end
