struct LearnedProgram
    publication::String
    definition::String
    depth::Int
    sources::Vector{String}
    steps::Vector{Dict{String,Any}}
    shared::Vector
end

mutable struct ProgramCursor
    program::LearnedProgram
    next_step::Int
    outputs::Vector
end

function merge_semantic_signature!(signature, previous)
    for (key, identity) in (("sorts","id"),("operators","symbol"))
        existing = Dict(entry[identity]=>entry for entry in signature[key])
        for entry in previous[key]
            id = entry[identity]
            if haskey(existing,id)
                canonical_bytes(existing[id]) == canonical_bytes(entry) ||
                    error("Incompatible semantic signature extension at " * id)
            else
                push!(signature[key],entry)
                existing[id] = entry
            end
        end
    end
    return signature
end

function decode_program_steps(term, registry)
    term["kind"] == "Call" || error("Invalid program body")
    descriptor = registry[term["operator"]]["descriptor"]
    if descriptor["kind"] == "Seq"
        left,right = decode_program_steps.(term["args"],Ref(registry))
        return (steps=[left.steps;right.steps],
            shared=[left.shared;[descriptor["layout"]["shared"]];right.shared])
    elseif descriptor["kind"] == "Step"
        action,pre,effect,post = term["args"]
        action["kind"] == "Const" && action["sort"] == "Integer" || error("Invalid Step action")
        layout = descriptor["layout"]
        all(registry[node["operator"]]["descriptor"]["kind"] == "Atom" && node["args"][1]["kind"] == "Slot" &&
            registry[node["operator"]]["descriptor"]["layout"]["phase"] == phase
            for (node,phase) in ((pre,"before"),(post,"after"))) || error("Step relative phases differ")
        return (steps=[(;action=action["value"],effects=flatten_effect_terms(effect),layout)],shared=Any[])
    end
    error("Unsupported program operator")
end

function read_program_macros(published, corpus)
    bundle = published.bundle
    bundle["source_programs"] == corpus.programs || error("Program source changed after learning")
    registry,definitions = registry_from(bundle["signature"],published.snapshot.entries)
    selected = LearnedProgram[]
    for (i,(text,scope)) in enumerate(zip(bundle["rewritten_programs"],corpus.scopes))
        term = decode_program(text,registry)
        term["kind"] == "Call" || continue
        id = term["operator"]
        haskey(definitions,id) && startswith(definitions[id]["result_sort"],"prog_") || continue
        calls = filter(call->call["program_index"] == i-1 && isempty(call["call_path"]) &&
            call["definition_ref"] == id,bundle["calls"])
        length(calls) == 1 || error("Program root lacks a unique search witness")
        expanded = decode_program_steps(expand_library_term(term,definitions),registry)
        length(expanded.steps) == length(scope["steps"]) &&
            canonical_bytes(expanded.shared) == canonical_bytes(scope["shared"]) ||
            error("Program expansion changed trace length or shared ports")
        for (step,record,slots) in zip(expanded.steps,scope["steps"],scope["role_slots"])
            raw = record["effects"]
            step.action == record["action"]["id"] && length(step.effects) == length(raw) ||
                error("Program expansion changed public action or effect count")
            for (child,data,pair) in zip(step.effects,raw,slots)
                local_effect = LocalEffect(Symbol(data["family"]), MotionShape(),MotionShape(),
                    collect(Int,data["values"]),Pixel[],(;))
                child == decode_model_term(local_effect,pair...) || error("Program effect changed after publication")
            end
        end
        any(program->program.definition == id,selected) && continue
        push!(selected,LearnedProgram(published.publication,id,bundle["definition_depths"][id],
            collect(String,scope["events"]),scope["steps"],scope["shared"]))
    end
    return selected
end

function train_prior_programs!(knowledge,config,store,repo_root)
    directory = get(config.learning,"prior_evidence",nothing)
    isnothing(directory) && return
    episodes = [recover_run(RunStore(path);read_only=true) for path in readdir(directory;join=true)
        if isdir(joinpath(path,"commands"))]
    groups = Dict{Int,Vector{Any}}()
    for episode in episodes
        steps = count(item->item.observation.action["id"] != 0,episode)
        steps >= 2 && push!(get!(Vector{Any},groups,steps),episode)
    end
    settings = read_json(store_path(store,"supervision.json"))
    config_text = read(config.learning["policy_file"],String)
    content_hash(config_text) == settings["policy_sha256"] || error("Session policy changed since launch")
    for size in sort!(collect(keys(groups)))
        corpus = compile_sequence_corpus(groups[size])
        isempty(corpus.programs) && continue
        current = read_published_stitch(store_path(store,"publication"))
        library = isnothing(current) ? LibrarySnapshot() : current.snapshot
        isnothing(current) || merge_semantic_signature!(corpus.signature,current.bundle["signature"])
        refs = sort!(unique!([ref for scope in corpus.scopes for ref in scope["events"]]))
        snapshot = "sequence-" * semantic_hash([[step["event_ref"],step["response_blob"]]
            for scope in corpus.scopes for step in scope["steps"]])
        knowledge.learning_jobs += 1
        job = store_path(store,"learning","job-" * lpad(knowledge.learning_jobs,6,'0'))
        atomic_json(joinpath(job,"sequence-corpus.json"),corpus)
        manifest = freeze_stitch_job(joinpath(job,"input"),basename(job),snapshot,library,corpus.signature,
            corpus.programs,corpus.origins,corpus.slots;repo_root,config_text,
            engine_identity=settings["engine_identity"],input_scope_complete=isempty(corpus.obligations),
            intent="program",consumer="program-semantics",obligation_refs=refs)
        status = wait_worker(job,store_path(store))
        status["policy_sha256"] == manifest["config_file"]["sha256"] || error("Program worker policy differs")
        if status["code"] ∉ (0,10)
            atomic_json(joinpath(job,"assessment.json"),Dict("result"=>"worker_incomplete","status"=>status))
            continue
        end
        checked = read_stitch_rounds(joinpath(job,"input"),joinpath(job,"output"))
        isempty(checked.verified) && continue
        last(checked.verified)["round_outcome"] == "no_positive_gain" || continue
        if isempty(last(checked.verified)["calls"])
            atomic_json(joinpath(job,"assessment.json"),Dict("result"=>"no_proved_program","status"=>status))
            continue
        end
        id = publish_stitch!(store_path(store,"publication"),checked;current_evidence=snapshot)
        released = read_published_stitch(store_path(store,"publication");publication=id)
        programs = read_program_macros(released,corpus)
        append!(knowledge.programs,programs)
        merge!(knowledge.definition_depths,released.bundle["definition_depths"])
        atomic_json(joinpath(job,"assessment.json"),Dict("result"=>"published","publication"=>id,
            "programs"=>[program.definition for program in programs],"status"=>status))
    end
    sort!(knowledge.programs;by=p->(-length(p.steps),-p.depth,p.definition))
    return nothing
end

function current_program_step(cursor, decision)
    step = cursor.program.steps[cursor.next_step]
    action = step["action"]["id"]
    action == 6 && return nothing
    for item in decision.ranked
        item.action["id"] == action && !isnothing(item.chosen) || continue
        effects = item.chosen.model.rule.effects
        raw = step["effects"]
        length(effects) == length(raw) || continue
        all(string(left.family) == right["family"] && left.values == right["values"]
            for (left,right) in zip(effects,raw)) || continue
        if cursor.next_step > 1
            shared = cursor.program.shared[cursor.next_step-1]
            all(cursor.outputs[i+1] == item.chosen.fragments[j+1].basis for (i,j) in shared) || continue
        end
        return merge(item,(reason="revalidated_learned_program",))
    end
    return nothing
end

function program_feedback!(cursor, item, assessment, observed)
    !isempty(assessment.assessments) && all(==("supported"),values(assessment.assessments)) ||
        return "effect_refuted_or_unknown"
    observed.complete && isempty(observed.residual) || return "post_queries_unresolved"
    outputs = []
    for fragment in item.chosen.fragments
        matches = filter(observed.effects) do effect
            effect.family == fragment.family &&
                (fragment.family == :count ? effect.context.before_count == fragment.basis : effect.before == fragment.basis)
        end
        length(matches) == 1 || return "output_binding_unproved"
        effect = only(matches)
        push!(outputs,effect.family == :count ? effect.context.after_count : effect.after)
    end
    cursor.outputs = outputs
    cursor.next_step += 1
    return cursor.next_step > length(cursor.program.steps) ? "completed" : "advance"
end
