const BEFORE_ROLE_COLUMN = ("RoleBefore","before")
const BEFORE_COLOR_COLUMN = ("Color","timeless")

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

function relation_condition!(signature,connectivity,pigment;slot=0)
    edges = relation_atom!(signature,"adjacent-" * string(connectivity),[BEFORE_ROLE_COLUMN,BEFORE_ROLE_COLUMN];slot)
    colors = relation_atom!(signature,"color-" * string(connectivity),[BEFORE_ROLE_COLUMN,BEFORE_COLOR_COLUMN];slot)
    selected = relation_operator!(signature,"SelectEqual",[colors.sort],colors.sort;
        layout=Dict("left"=>1,"value"=>pigment))
    filtered = (; term=Call(selected,colors.term),sort=colors.sort)
    joined = relation_join!(signature,edges,filtered;shared=[(1,0)],output=[0,1,3])
    return relation_project!(signature,joined,[0])
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
    for connectivity in (4,8), pigment in 0:15
        query = relation_condition!(signature,connectivity,pigment)
        term = render_term(query.term)
        judged = [relation_truth(term,signature,observed,connectivity) for observed in contexts]
        all(result.verdict == example.verdict for (result,example) in zip(judged,recalled)) || continue
        entry = relation_definition(term,signature)
        push!(candidates,(; term,entry,connectivity,pigment,judged))
    end
    isempty(candidates) && return nothing
    certificate = Dict("kind"=>"constructed-query",
        "recalled_events"=>[event.sample.event_id for event in recalled],
        "precise_ports"=>[association_port(event) for event in recalled],
        "comparison"=>[Dict("event_ref"=>entry.sample.event_id,"before_ref"=>entry.sample.before_id,
            "verdict"=>string(entry.verdict),"witnesses"=>[candidate.judged[i].witness for candidate in candidates],
            "dag"=>contexts[i].context.witnesses) for (i,entry) in enumerate(recalled)],
        "candidates"=>[Dict("program"=>candidate.term,"entry"=>candidate.entry,
            "connectivity"=>candidate.connectivity,"pigment"=>candidate.pigment) for candidate in candidates])
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
