const BEFORE_ROLE_COLUMN = ("RoleBefore","before")
const BEFORE_COLOR_COLUMN = ("Color","timeless")

"""
Build witnessed Boolean rectangles. An unknown cell is eligible for the
possible extent and can never enter the represented positive incidence.
"""
function relational_factors(objects,attributes,incidence,seeds)
    domains = collect(objects)
    vocabulary = collect(attributes)
    allunique(domains) && allunique(vocabulary) || throw(ArgumentError("Repeated factor binding"))
    known = Dict(attribute=>BitSet() for attribute in vocabulary)
    excluded = Dict(attribute=>BitSet() for attribute in vocabulary)
    for ((object,attribute),truth) in incidence
        object in eachindex(domains) && haskey(known,attribute) ||
            throw(ArgumentError("Factor incidence escaped its declared domain"))
        truth == proven && push!(known[attribute],object)
        truth == disproven && push!(excluded[attribute],object)
    end
    factors = NamedTuple[]
    covered = Set{Tuple{Int,eltype(vocabulary)}}()
    for seed in seeds
        extent = BitSet(seed)
        all(index->index in eachindex(domains),extent) || throw(ArgumentError("Unknown seed object"))
        isempty(extent) && continue
        intent = [attribute for attribute in vocabulary if issubset(extent,known[attribute])]
        isempty(intent) && continue
        closed = reduce(intersect,(known[attribute] for attribute in intent))
        length(closed) * length(intent) > length(closed) + length(intent) || continue
        possible = setdiff(BitSet(eachindex(domains)),
            reduce(union,(excluded[attribute] for attribute in intent)))
        factor = (;extent=collect(closed),intent,possible=collect(possible))
        factor in factors && continue
        union!(covered,((object,attribute) for object in closed for attribute in intent))
        push!(factors,factor)
    end
    residual = sort!([(object,attribute) for attribute in vocabulary for object in known[attribute]
        if (object,attribute) ∉ covered];by=repr)
    return (;factors,residual)
end

struct RelationPredicate <: MotionPredicate
    candidates::Vector{String}
    programs::Vector{String}
    signature::Dict{String,Any}
    certificate::Dict{String,Any}
    certificate_sha::String
    library::Vector{Dict{String,Any}}
    macro_refs::Vector{String}
end

predicate_record(p::RelationPredicate) = Dict("kind"=>"relation_predicate","definition_ids"=>p.candidates,
    "view"=>"color-support","certificate_sha256"=>p.certificate_sha,"search_macros"=>p.macro_refs)

function observed_relation_context(frame,binding,event; slot=0)
    scope = RelationScope("visible-frame",event,"components-exact","color-support","before")
    context = RelationEvaluation(scope,Dict(event=>0),1;slot)
    subjects = Dict{Int,Union{String,Nothing}}()
    for connectivity in (4,8)
        support = support_features(frame,binding.support;connectivity)
        subjects[connectivity] = support.subject
        observe_relation!(context,"adjacent-" * string(connectivity),[BEFORE_ROLE_COLUMN,BEFORE_ROLE_COLUMN],
            support.neighbor;event_reads=[event],domain_complete=true)
        observe_relation!(context,"color-" * string(connectivity),[BEFORE_ROLE_COLUMN,BEFORE_COLOR_COLUMN],
            support.colors;event_reads=[event],domain_complete=true)
    end
    return (; context,subjects)
end

function relation_condition!(signature,connectivity,pigment;slot=0,neighbor_count=nothing)
    edges = relation_atom!(signature,"adjacent-" * string(connectivity),[BEFORE_ROLE_COLUMN,BEFORE_ROLE_COLUMN];slot)
    colors = relation_atom!(signature,"color-" * string(connectivity),[BEFORE_ROLE_COLUMN,BEFORE_COLOR_COLUMN];slot)
    selected = relation_operator!(signature,"SelectEqual",[colors.sort],colors.sort;
        layout=Dict("left"=>1,"value"=>pigment))
    filtered = (; term=Call(selected,colors.term),sort=colors.sort)
    joined = relation_join!(signature,edges,filtered;shared=[(1,0)],output=[0,1,3])
    if !isnothing(neighbor_count)
        domain = relation_project!(signature,colors,[0])
        counts = relation_count_distinct!(signature,joined,domain;groups=[0],distinct=[1])
        matches = relation_operator!(signature,"SelectEqual",[counts.sort],counts.sort;
            layout=Dict("left"=>1,"value"=>neighbor_count))
        matched = (;term=Call(matches,counts.term),sort=counts.sort)
        return relation_project!(signature,matched,[0])
    end
    return relation_project!(signature,joined,[0])
end

function observed_neighbor_counts(observed,connectivity)
    subject = observed.subjects[connectivity]
    isnothing(subject) && return nothing
    suffix = string(connectivity)
    pigments = observed.context.atoms["color-" * suffix]
    colors = Dict(first(row)=>last(row) for row in keys(pigments.rows))
    counts = zeros(Int,16)
    cursor = nothing
    while true
        page = relation_page!(observed.context,"adjacent-" * suffix,(subject,nothing),64;cursor)
        page.execution == "completed" || return nothing
        for ((_,neighbor),_) in page.rows
            counts[colors[neighbor]+1] += 1
        end
        page.coverage == "complete" && return counts
        cursor = page.cursor
        isnothing(cursor) && return nothing
    end
end

function relation_definition(program,signature)
    registry,_ = registry_from(signature,[])
    input = decode_program(program,registry)
    sort = wire_sort(input,registry;slots=["SceneBefore"])
    function parameterize(term)
        term["kind"] == "Slot" && return wire_parameter(term["index"])
        term["kind"] == "Call" || return term
        return wire_call(term["operator"],parameterize.(term["args"]))
    end
    body = parameterize(input)
    data = Dict("temporary_name"=>"fn_0","arity"=>1,"parameter_sorts"=>["SceneBefore"],
        "result_sort"=>sort,"parameter_reads"=>[0],"body"=>body,"pattern_text"=>wire_text(body),
        "closed_lambda_text"=>lambda_text(body,1),"dependencies"=>String[],
        "body_cost"=>string(wire_cost(body)),"semantic_digest"=>definition_semantics(body,registry))
    return Dict("stable_id"=>definition_id(data),"definition"=>data)
end

function relation_truth(program, signature, observed, connectivity; library=[])
    ref = observed.subjects[connectivity]
    isnothing(ref) && return (; verdict=unknown_truth, witness=nothing)
    result = evaluate_relation(program,observed.context,signature;slots=["SceneBefore"],library)
    verdict = relation_member(result,(ref,))
    witness = verdict == proven ? result.rows[(ref,)] : result.completion_ref
    return (; verdict,witness)
end

function construct_relation(examples)
    length(examples) >= 2 || return nothing
    index = AssociationIndex()
    for example in examples
        index_association!(index,example)
    end
    recalled = recall_associations(index,last(examples))
    any(entry->entry.verdict == proven,recalled) && any(entry->entry.verdict == disproven,recalled) || return nothing
    contexts = [observed_relation_context(example.sample.before,example.binding,example.sample.before_id)
        for example in recalled]
    signature = Dict{String,Any}("schema_version"=>3,"signature_id"=>"observed-guard-v1",
        "sorts"=>Dict{String,Any}[],"operators"=>Dict{String,Any}[])
    candidates = []
    function test_candidate(connectivity,pigment;neighbor_count=nothing)
        query = relation_condition!(signature,connectivity,pigment;neighbor_count)
        term = render_term(query.term)
        judged = [relation_truth(term,signature,observed,connectivity) for observed in contexts]
        all(result.verdict == example.verdict for (result,example) in zip(judged,recalled)) || return
        entry = relation_definition(term,signature)
        push!(candidates,(;term,entry,connectivity,pigment,judged,neighbor_count))
    end
    for connectivity in (4,8), pigment in 0:15
        test_candidate(connectivity,pigment)
    end
    if isempty(candidates)
        for connectivity in (4,8)
            observations = [observed_neighbor_counts(context,connectivity) for context in contexts]
            any(isnothing,observations) && continue
            for pigment in 0:15
                counts = [row[pigment+1] for row in observations]
                supported = unique(counts[i] for i in eachindex(counts) if recalled[i].verdict == proven)
                length(supported) == 1 || continue
                neighbor_count = only(supported)
                all(counts[i] != neighbor_count for i in eachindex(counts) if recalled[i].verdict == disproven) || continue
                test_candidate(connectivity,pigment;neighbor_count)
            end
        end
    end
    isempty(candidates) && return nothing
    certificate = Dict("kind"=>"constructed-query",
        "recalled_events"=>[event.sample.event_id for event in recalled],
        "precise_ports"=>[association_port(event) for event in recalled],
        "comparison"=>[Dict("event_ref"=>entry.sample.event_id,"before_ref"=>entry.sample.before_id,
            "verdict"=>string(entry.verdict),"witnesses"=>[candidate.judged[i].witness for candidate in candidates],
            "dag"=>contexts[i].context.witnesses) for (i,entry) in enumerate(recalled)],
        "candidates"=>[begin
            certificate = Dict("program"=>candidate.term,"entry"=>candidate.entry,
                "connectivity"=>candidate.connectivity,"pigment"=>candidate.pigment)
            isnothing(candidate.neighbor_count) || (certificate["neighbor_count"] = candidate.neighbor_count)
            certificate
        end for candidate in candidates])
    return RelationPredicate([candidate.entry["stable_id"] for candidate in candidates],
        [candidate.term for candidate in candidates],signature,certificate,semantic_hash(certificate),
        Dict{String,Any}[],String[])
end

function persist_relation_certificates!(store, models)
    for model in models, predicate in model.condition.atoms
        predicate isa RelationPredicate || continue
        path = store_path(store,"publication","constructed",predicate.certificate_sha * ".json")
        isfile(path) && continue
        registry_from(predicate.signature,[candidate["entry"] for candidate in predicate.certificate["candidates"]])
        atomic_json(path,Dict("certificate"=>predicate.certificate,"signature"=>predicate.signature,
            "certificate_sha256"=>predicate.certificate_sha))
    end
end

function evaluate_predicate(predicate::RelationPredicate,frame,binding,delta,history)
    isnothing(binding) && return unknown_truth
    observed = observed_relation_context(frame,binding,"action-before")
    truth = [relation_truth(program,predicate.signature,observed,record["connectivity"];library=predicate.library).verdict
        for (program,record) in zip(predicate.programs,predicate.certificate["candidates"])]
    return all(==(first(truth)),truth) ? first(truth) : unknown_truth
end
