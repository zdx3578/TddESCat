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
                family = Symbol(data["family"])
                expected = if family == :selection
                    binding = relative_click(data["values"],data["after"])
                    name = child["operator"]
                    step.layout["click_binding"] == "target-support-grid" &&
                        registry[name]["descriptor"] == click_descriptor(binding) ||
                        error("Click target frame changed after publication")
                    wire_call(name,[wire_slot.(collect(pair));wire_const.("Integer",collect(binding.offset))])
                else
                    local_effect = LocalEffect(family,MotionShape(),MotionShape(),collect(Int,data["values"]),Pixel[],(;))
                    decode_model_term(local_effect,pair...)
                end
                child == expected || error("Program effect changed after publication")
            end
        end
        any(program->program.definition == id,selected) && continue
        push!(selected,LearnedProgram(published.publication,id,bundle["definition_depths"][id],
            collect(String,scope["events"]),scope["steps"],scope["shared"]))
    end
    return selected
end

function record_program_assessment(job,assessment)
    atomic_json(joinpath(job,"assessment.json"),assessment)
    return merge(assessment,Dict("job"=>basename(job)))
end

function train_program_corpus!(knowledge,config,store,repo_root,corpus)
    isempty(corpus.programs) && return nothing
    settings = read_json(store_path(store,"supervision.json"))
    config_text = read(config.learning["policy_file"],String)
    content_hash(config_text) == settings["policy_sha256"] || error("Session policy changed since launch")
    current = read_published_stitch(store_path(store,"publication"))
    base = isnothing(current) ? LibrarySnapshot() : current.snapshot
    isnothing(current) || merge_semantic_signature!(corpus.signature,current.bundle["signature"])
    library = scoped_search_library(base,corpus.signature,corpus.programs,corpus.slots)
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
    status["policy_sha256"] == manifest["config_file"]["sha256"] &&
        status["binary_sha256"] == manifest["engine_pin"]["binary_sha256"] ||
        error("Program worker policy or binary differs")
    output = joinpath(job,"output")
    checked = isdir(output) ? read_stitch_rounds(joinpath(job,"input"),output) : nothing
    complete = !isnothing(checked) && !isempty(checked.verified) && status["code"] in (0,10) &&
        last(checked.verified)["round_outcome"] == "no_positive_gain"
    assessment = Dict{String,Any}("status"=>status,"search_complete"=>complete,
        "termination_reason"=>isnothing(checked) || isnothing(checked.summary) ? "worker_incomplete" :
            checked.summary["termination_reason"])
    if isnothing(checked) || isempty(checked.verified)
        return record_program_assessment(job,merge(assessment,Dict("result"=>"worker_incomplete")))
    end
    if isempty(last(checked.verified)["calls"])
        return record_program_assessment(job,merge(assessment,Dict("result"=>"no_proved_program")))
    end
    id = publish_stitch!(store_path(store,"publication"),checked;current_evidence=snapshot)
    released = read_published_stitch(store_path(store,"publication");publication=id)
    programs = read_program_macros(released,corpus)
    append!(knowledge.programs,programs)
    merge!(knowledge.definition_depths,released.bundle["definition_depths"])
    sort!(knowledge.programs;by=p->(-length(p.steps),-p.depth,p.definition))
    return record_program_assessment(job,merge(assessment,Dict("result"=>"published","publication"=>id,
        "programs"=>[program.definition for program in programs])))
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
    for size in sort!(collect(keys(groups)))
        train_program_corpus!(knowledge,config,store,repo_root,compile_sequence_corpus(groups[size]))
    end
    return nothing
end

function program_click_actions(knowledge,cursor,groups,available)
    actions = Dict{String,Int}[]
    6 in available || return actions
    steps = isnothing(cursor) ? [first(program.steps) for program in knowledge.programs] :
        [cursor.program.steps[cursor.next_step]]
    for step in steps
        step["action"]["id"] == 6 || continue
        selected = only(effect for effect in step["effects"] if effect["family"] == "selection")
        binding = relative_click(selected["values"],selected["after"])
        template = geometry(selected["after"])
        for shape in groups
            geometry(shape) == template || continue
            scaled = binding.offset .* support_grid(shape).unit
            all(d->mod(d,binding.denominator)==0,scaled) || continue
            x,y = anchor(shape) .+ div.(scaled,binding.denominator)
            (x,y) in effect_points(shape) || continue
            push!(actions,Dict("id"=>6,"x"=>x,"y"=>y))
        end
    end
    return unique!(actions)
end

program_input(fragment) = fragment.family == :count ?
    (count=fragment.basis,support=fragment.token_support) : fragment.basis

function current_program_step(cursor, decision)
    step = cursor.program.steps[cursor.next_step]
    action = step["action"]["id"]
    click = nothing
    for item in decision.ranked
        item.action["id"] == action && !isnothing(item.chosen) || continue
        effects = item.chosen.model.rule.effects
        raw = step["effects"]
        length(effects) == length(raw) || continue
        matches = all(zip(effects,raw,item.chosen.fragments)) do (left,right,bound)
            string(left.family) == right["family"] || return false
            left.family != :selection && return left.values == right["values"]
            xy = (item.action["x"],item.action["y"])
            return geometry(bound.basis) == geometry(right["after"]) &&
                relative_click(xy,bound.basis) == relative_click(right["values"],right["after"])
        end
        matches || continue
        if cursor.next_step > 1
            shared = cursor.program.shared[cursor.next_step-1]
            all(cursor.outputs[i+1] == program_input(item.chosen.fragments[j+1]) for (i,j) in shared) || continue
        end
        selected = merge(item,(reason="revalidated_learned_program",))
        action != 6 && return selected
        isnothing(click) || return nothing
        click = selected
    end
    return click
end

function program_feedback!(cursor, item, assessment, observed)
    !isempty(assessment.assessments) && all(==("supported"),values(assessment.assessments)) ||
        return "effect_refuted_or_unknown"
    observed.complete && isempty(observed.residual) || return "post_queries_unresolved"
    outputs = []
    for fragment in item.chosen.fragments
        matches = filter(observed.effects) do effect
            effect.family == fragment.family || return false
            fragment.family == :count && return (count=effect.context.before_count,support=effect.before) == program_input(fragment)
            fragment.family == :selection && return effect.after == fragment.basis
            return effect.before == fragment.basis
        end
        length(matches) == 1 || return "output_binding_unproved"
        effect = only(matches)
        push!(outputs,effect.family == :count ? (count=effect.context.after_count,support=effect.after) : effect.after)
    end
    cursor.outputs = outputs
    cursor.next_step += 1
    return cursor.next_step > length(cursor.program.steps) ? "completed" : "advance"
end
