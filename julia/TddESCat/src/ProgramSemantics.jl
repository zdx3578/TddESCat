struct LearnedProgram
    publication::String
    definition::String
    depth::Int
    sources::Vector{String}
    steps::Vector{Dict{String,Any}}
    shared::Vector
    available_after::Union{Nothing,String}
end

function recorded_effect_relation(effect)
    family = Symbol(effect["family"])
    family == :measurement && return nothing
    context = effect["context"]
    prototype = if family == :count
        context isa NamedTuple ? context.prototype : context["prototype"]
    else
        shape_template(effect["before"])
    end
    values = family == :selection ? Tuple(relative_click(effect["values"],effect["after"])) : effect["values"]
    return effect_relation(family,prototype,values)
end

function witnessed_program_contract(program)
    later = Set{Pixel}()
    produced = String[]
    for step in Iterators.reverse(program.steps)
        for effect in step["effects"]
            relation = recorded_effect_relation(effect)
            isnothing(relation) && continue
            # Later writes can invalidate an earlier relation on the same
            # role. Count witnesses are asserted only at the final step.
            effect["family"] == "count" && step !== last(program.steps) && continue
            isdisjoint(later,Tuple.(effect["changed"])) && push!(produced,relation)
        end
        for effect in step["effects"]
            union!(later,Tuple.(effect["changed"]))
        end
    end
    first_step = first(program.steps)
    return (before=first_step["before_ref"],action=first_step["action"]["id"],
        preconditions=[(family=effect["family"],basis=effect["before"]) for effect in first_step["effects"]],
        postconditions=sort!(unique!(produced)),shared=program.shared,source_events=program.sources)
end

function programs_for_relations(knowledge,needs)
    isempty(needs) && return knowledge.programs
    keys = unique([rel for need in needs for rel in need.relations])
    matches = unique([program for relation in keys for program in get(knowledge.program_producers,relation,Any[])])
    sort!(matches;by=program->(-length(program.steps),program.definition))
    return union(matches,knowledge.programs)
end

mutable struct ProgramCursor
    program::LearnedProgram
    next_step::Int
    outputs::Vector
end

function program_relation_contract(program,forecast)
    inputs = first(forecast.path).item.chosen
    outputs = last(forecast.path).item.chosen
    regression = get(forecast,:regression,nothing)
    return (definition=program.definition,publication=program.publication,
        preconditions=predicate_record.(inputs.model.condition.atoms),
        postconditions=outputs.expected,port_bindings=program_input.(inputs.fragments),
        scope=[step.item.projection_contract.version for step in forecast.path],
        shared=program.shared,goal_effect=isnothing(regression) ? nothing : regression.established,
        source_events=copy(program.sources),available_after=program.available_after)
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
        layout = descriptor["layout"]
        if get(layout,"encoding",nothing) == "bound-effects-v1"
            action = first(term["args"])
            action["kind"] == "Const" && action["sort"] == "Integer" || error("Invalid bound Step action")
            return (steps=[(;action=action["value"],effects=term["args"][2:end],layout)],shared=Any[])
        end
        action,pre,effect,post = term["args"]
        action["kind"] == "Const" && action["sort"] == "Integer" || error("Invalid Step action")
        all(registry[node["operator"]]["descriptor"]["kind"] == "Atom" && node["args"][1]["kind"] == "Slot" &&
            registry[node["operator"]]["descriptor"]["layout"]["phase"] == phase
            for (node,phase) in ((pre,"before"),(post,"after"))) || error("Step relative phases differ")
        return (steps=[(;action=action["value"],effects=flatten_effect_terms(effect),layout)],shared=Any[])
    end
    error("Unsupported program operator")
end

function verify_program_interval(expanded, registry, scope, first_step, last_step)
    interval = first_step:last_step
    shared = scope["shared"][first_step:last_step-1]
    canonical_bytes(expanded.shared) == canonical_bytes(shared) ||
        error("Program expansion changed trace sharing")
    for (step,record,slots) in zip(expanded.steps,scope["steps"][interval],scope["role_slots"][interval])
        raw = record["effects"]
        if get(step.layout,"encoding",nothing) == "bound-effects-v1"
            contracts = [step_effect_contract(Symbol(row["family"]),row["values"],row["after"]) for row in raw]
            families = [row["family"] for row in raw]
            steps = [wire_const(arg.sort,arg.value) for part in contracts for arg in part.args]
            step.action == record["action"]["id"] &&
                step.layout["effects"] == [item.descriptor for item in contracts] &&
                step.layout["input_ports"] == step.layout["output_ports"] == families &&
                step.effects == steps || error("Bound Step changed its typed public effect")
            continue
        end
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
                effect = LocalEffect(family,MotionShape(),MotionShape(),collect(Int,data["values"]),Pixel[],(;))
                decode_model_term(effect,pair...)
            end
            child == expected || error("Program effect changed after publication")
        end
    end
    return shared
end

function read_program_macros(published, corpus; available_after=nothing)
    bundle = published.bundle
    bundle["source_programs"] == corpus.programs || error("Program source changed after learning")
    registry,definitions = registry_from(bundle["signature"],published.snapshot.entries)
    selected = LearnedProgram[]
    for (i,(text,scope)) in enumerate(zip(bundle["rewritten_programs"],corpus.scopes))
        cases = Dict(Tuple(call["call_path"])=>call for call in bundle["calls"]
            if call["program_index"] == i-1)
        function visit(node, path, lo)
            node["kind"] == "Call" || error("Invalid program partition")
            id = node["operator"]
            if haskey(definitions,id)
                startswith(definitions[id]["result_sort"],"prog_") || error("Unexpected program sort")
                witness = cases[path]
                witness["definition_ref"] == id || error("Program call lacks a search witness")
                expanded = decode_program_steps(expand_library_term(node,definitions),registry)
                hi = lo + length(expanded.steps) - 1
                hi <= length(scope["steps"]) || error("Program escaped its source interval")
                shared = verify_program_interval(expanded,registry,scope,lo,hi)
                if lo < hi
                    push!(selected,LearnedProgram(published.publication,id,bundle["definition_depths"][id],
                        collect(String,scope["events"][lo:hi]),scope["steps"][lo:hi],shared,available_after))
                end
                return hi+1
            end
            kind = registry[id]["descriptor"]["kind"]
            kind == "Step" && return lo+1
            kind == "Seq" || error("Unknown program partition")
            boundary = visit(node["args"][1],(path...,0),lo)
            return visit(node["args"][2],(path...,1),boundary)
        end
        visit(decode_program(text,registry),(),1) == length(scope["steps"])+1 ||
            error("A rewritten program changed the source interval")
    end
    return selected
end

function record_program_assessment(job,assessment)
    atomic_json(joinpath(job,"assessment.json"),assessment)
    return merge(assessment,Dict("job"=>basename(job)))
end

function program_corpus_key(corpus)
    return semantic_hash(parse_json(JSON.json([corpus.programs,corpus.slots,corpus.scopes])))
end

function program_cohorts(complete)
    cohorts = Dict{String,Vector{Tuple{Int,Int,Int}}}()
    for (index,scope) in enumerate(complete.scopes)
        contracts = program_step_key.(scope["steps"])
        for start in eachindex(contracts), stop in start+1:length(contracts)
            key = semantic_hash([contracts[start:stop],scope["shared"][start:stop-1]])
            members = get!(Vector{Tuple{Int,Int,Int}},cohorts,key)
            if isempty(members) || last(members)[1] != index || last(members)[3] < start
                push!(members,(index,start,stop))
            end
        end
    end
    eligible = filter(row->length(last(row)) > 1,collect(cohorts))
    sort!(eligible;by=row->begin
        _,lo,hi = first(last(row))
        (hi-lo,-length(last(row)),first(row))
    end)
    return eligible
end

function next_program_corpus(complete,events,observations,submitted,learned)
    any(step->any(effect->effect["family"] == "measurement",step["effects"]),
        Iterators.flatten(scope["steps"] for scope in complete.scopes)) || return complete
    by_ref = Dict(item.event["event_id"]=>item for item in events)
    for (key,members) in program_cohorts(complete)
        key in learned && continue
        episodes = []
        for (index,lo,hi) in members
            rows = complete.scopes[index]["steps"][lo:hi]
            push!(episodes,[by_ref[first(rows)["before_ref"]];[by_ref[row["event_ref"]] for row in rows]])
        end
        corpus = compile_sequence_corpus(episodes;observations)
        isempty(corpus.programs) && continue
        program_corpus_key(corpus) in submitted && continue
        return merge(corpus,(cohort=key,))
    end
    return nothing
end

function program_cohort_ledger(store,corpus)
    attempts = Dict{String,Vector{Dict{String,Any}}}()
    for job in learning_jobs(store)
        input = joinpath(job,"program-submission.json")
        isfile(input) || continue
        submission = read_json(input)
        result = joinpath(job,"assessment.json")
        assessment = isfile(result) ? read_json(result) : Dict()
        key = get(submission,"cohort",get(assessment,"cohort",nothing))
        isnothing(key) && continue
        push!(get!(Vector{Dict{String,Any}},attempts,key),Dict(
            "job"=>basename(job),"snapshot"=>submission["snapshot"],
            "source_events"=>submission["evidence"],
            "search_complete"=>get(assessment,"search_complete",false),
            "publication"=>get(assessment,"publication",nothing),
            "result"=>get(assessment,"result","submitted"),
            "termination"=>get(get(assessment,"status",Dict()),"termination_reason",
                get(assessment,"termination_reason",nothing))))
    end
    rows = []
    for (id,intervals) in program_cohorts(corpus)
        members = [corpus.scopes[scope]["events"][lo:hi] for (scope,lo,hi) in intervals]
        jobs = get(attempts,id,[])
        seen = Set(ref for job in jobs for ref in job["source_events"])
        status = isempty(jobs) ? "unsubmitted" :
            last(jobs)["search_complete"] ? "search_complete" : "search_incomplete"
        push!(rows,Dict("id"=>id,"steps"=>length(first(members)),"members"=>members,
            "status"=>status,"new_members"=>[refs for refs in members if !issubset(refs,seen)],
            "attempts"=>jobs))
    end
    return Dict("groups"=>rows,"unsubmitted"=>count(row->row["status"] == "unsubmitted",rows),
        "search_incomplete"=>count(row->row["status"] == "search_incomplete",rows),
        "search_complete"=>count(row->row["status"] == "search_complete",rows))
end

function prepare_program_learning!(knowledge,config,store,repo_root,corpus;retry_of=nothing)
    isempty(corpus.programs) && return nothing
    settings = read_json(store_path(store,"supervision.json"))
    config_text = read(config.learning["policy_file"],String)
    content_hash(config_text) == settings["policy_sha256"] || error("Session policy changed since launch")
    current = read_published_stitch(store_path(store,"publication"))
    base = isnothing(current) ? LibrarySnapshot() : current.snapshot
    isnothing(current) || merge_semantic_signature!(corpus.signature,current.bundle["signature"])
    library = scoped_search_library(base,corpus.signature,corpus.programs,corpus.slots)
    refs = sort!(unique!([ref for scope in corpus.scopes for ref in scope["events"]]))
    key = program_corpus_key(corpus)
    snapshot = "sequence-" * key
    knowledge.learning_jobs += 1
    job = store_path(store,"learning","job-" * lpad(knowledge.learning_jobs,6,'0'))
    atomic_json(joinpath(job,"sequence-corpus.json"),corpus)
    manifest = freeze_stitch_job(joinpath(job,"input"),basename(job),snapshot,library,corpus.signature,
        corpus.programs,corpus.origins,corpus.slots;repo_root,config_text,
        engine_identity=settings["engine_identity"],input_scope_complete=isempty(corpus.obligations),
        intent="program",consumer="program-semantics",obligation_refs=refs)
    atomic_json(joinpath(job,"program-submission.json"),Dict(
        "snapshot"=>snapshot,"key"=>key,"retry_of"=>retry_of,"evidence"=>refs,
        "cohort"=>get(corpus,:cohort,nothing)))
    return (;job,manifest,snapshot,corpus,key)
end

function collect_program_learning!(knowledge,store,prepared,status; available_after=nothing)
    (;job,manifest,snapshot,corpus,key) = prepared
    status["policy_sha256"] == manifest["config_file"]["sha256"] &&
        status["binary_sha256"] == manifest["engine_pin"]["binary_sha256"] ||
        error("Program worker policy or binary differs")
    output = joinpath(job,"output")
    checked = isdir(output) ? read_stitch_rounds(joinpath(job,"input"),output) : nothing
    complete = !isnothing(checked) && !isempty(checked.verified) && status["code"] in (0,10) &&
        last(checked.verified)["round_outcome"] == "no_positive_gain"
    assessment = Dict{String,Any}("status"=>status,"key"=>key,"search_complete"=>complete,
        "termination_reason"=>isnothing(checked) || isnothing(checked.summary) ? "worker_incomplete" :
            checked.summary["termination_reason"])
    hasproperty(corpus,:cohort) && (assessment["cohort"] = corpus.cohort)
    if isnothing(checked) || isempty(checked.verified)
        return record_program_assessment(job,merge(assessment,Dict("result"=>"worker_incomplete")))
    end
    checked.manifest["evidence_snapshot_id"] == snapshot && checked.text == corpus.programs &&
        canonical_bytes(checked.signature) == canonical_bytes(corpus.signature) ||
        error("The program search input does not agree with its submitted corpus")
    atomic_json(joinpath(job,"program-verification.json"),Dict(
        "snapshot"=>snapshot,"input_sha256"=>checked.input_sha,
        "verified_rounds"=>length(checked.verified),"search_complete"=>complete))
    if isempty(last(checked.verified)["calls"])
        return record_program_assessment(job,merge(assessment,Dict("result"=>"no_proved_program")))
    end
    directory = store_path(store,"publication")
    activation = joinpath(job,"program-publication.json")
    old = isfile(activation) ? read_json(activation) : nothing
    head = read_published_stitch(directory)
    id = if !isnothing(old)
        old["input_sha256"] == checked.input_sha || error("The program activation has a different input")
        available_after = old["available_after"]
        old["publication"]
    elseif !isnothing(head) && head.bundle["input_sha256"] == checked.input_sha
        head.publication
    else
        publish_stitch!(directory,checked;current_evidence=snapshot)
    end
    released = read_published_stitch(directory;publication=id)
    released.bundle["input_sha256"] == checked.input_sha || error("The published program has a different input")
    programs = read_program_macros(released,corpus;available_after)
    contracts = [(definition=program.definition,contract=witnessed_program_contract(program)) for program in programs]
    atomic_json(activation,Dict("publication"=>id,"available_after"=>available_after,
        "snapshot"=>snapshot,"input_sha256"=>checked.input_sha,"relation_contracts"=>contracts))
    for (program,row) in zip(programs,contracts)
        any(p->p.definition == program.definition && p.sources == program.sources,knowledge.programs) && continue
        push!(knowledge.programs,program)
        for relation in row.contract.postconditions
            push!(get!(Vector{Any},knowledge.program_producers,relation),program)
        end
    end
    merge!(knowledge.definition_depths,released.bundle["definition_depths"])
    sort!(knowledge.programs;by=p->(-length(p.steps),p.definition))
    return record_program_assessment(job,merge(assessment,Dict("result"=>"published","publication"=>id,
        "available_after"=>available_after,"programs"=>unique([program.definition for program in programs]))))
end

function program_jobs_by_snapshot(store)
    jobs = Dict{String,String}()
    for job in learning_jobs(store)
        path = joinpath(job,"sequence-corpus.json")
        isfile(path) || continue
        corpus = read_json(path)
        parsed = (;programs=corpus["programs"],slots=corpus["slots"],scopes=corpus["scopes"])
        jobs[program_corpus_key(parsed)] = job
    end
    return jobs
end

function program_job_complete(job)
    file = joinpath(job,"assessment.json")
    return isfile(file) && get(read_json(file),"search_complete",false)
end

function pending_program_jobs(store)
    return sort!([basename(job) for job in values(program_jobs_by_snapshot(store))
        if !program_job_complete(job)])
end

function recover_program_jobs!(knowledge,config,store,repo_root,records,available_after;published_only=false)
    for (key,job) in sort!(collect(program_jobs_by_snapshot(store));by=last)
        program_job_complete(job) && continue
        published_only && !isfile(joinpath(job,"program-publication.json")) && continue
        raw = read_json(joinpath(job,"sequence-corpus.json"))
        corpus = (;(Symbol(field)=>value for (field,value) in raw)...)
        for scope in corpus.scopes, step in scope["steps"]
            before = records[step["before_ref"]]
            after = records[step["event_ref"]]
            interpreted = sequence_evidence(before,after,knowledge.observations[step["event_ref"]])
            canonical_bytes(parse_json(JSON.json(interpreted))) == canonical_bytes(step) ||
                error("Recovered sequence differs from the confirmed raw receipts")
        end
        manifest_file = joinpath(job,"input","manifest.json")
        assessment_file = joinpath(job,"assessment.json")
        if isfile(manifest_file) && !isfile(assessment_file)
            manifest = read_json(manifest_file)
            snapshot = manifest["evidence_snapshot_id"]
            assessment = collect_program_learning!(knowledge,store,(;job,manifest,snapshot,corpus,key),
                wait_worker(job,store_path(store));available_after)
            assessment["search_complete"] && continue
        end
        published_only && continue
        prepared = prepare_program_learning!(knowledge,config,store,repo_root,corpus;retry_of=basename(job))
        isnothing(prepared) && continue
        collect_program_learning!(knowledge,store,prepared,wait_worker(prepared.job,store_path(store));available_after)
    end
end

function train_program_corpus!(knowledge,config,store,repo_root,corpus; available_after=nothing)
    prepared = prepare_program_learning!(knowledge,config,store,repo_root,corpus)
    isnothing(prepared) && return nothing
    status = wait_worker(prepared.job,store_path(store))
    return collect_program_learning!(knowledge,store,prepared,status;available_after)
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
        train_program_corpus!(knowledge,config,store,repo_root,
            compile_sequence_corpus(groups[size];observations=knowledge.observations))
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

function program_step_key(action, effects::Vector{EffectModel})
    return semantic_hash([action["id"],
        [[string(effect.family),effect.family == :selection ? Int[] : effect.values] for effect in effects]])
end

function program_step_key(step)
    return semantic_hash([step["action"]["id"],
        [[effect["family"],effect["family"] == "selection" ? Int[] : effect["values"]]
        for effect in step["effects"]]])
end

function program_input(fragment)
    fragment.family == :measurement && return (instance=fragment.instance,value=fragment.basis)
    fragment.family == :count && return (instance=fragment.instance,count=fragment.basis,support=fragment.token_support)
    return fragment.basis
end

function observed_port(effect,after)
    if effect.family == :measurement
        return (instance=effect.context.instance,value=after ? effect.context.after_value : effect.context.before_value)
    elseif effect.family == :count
        return (instance=semantic_hash(["discrete-component-count",effect.context.prototype]),
            count=after ? effect.context.after_count : effect.context.before_count,
            support=after ? effect.after : effect.before)
    end
    return after || effect.family == :selection ? effect.after : effect.before
end

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
            return observed_port(effect,false) == program_input(fragment)
        end
        length(matches) == 1 || return "output_binding_unproved"
        effect = only(matches)
        push!(outputs,observed_port(effect,true))
    end
    cursor.outputs = outputs
    cursor.next_step += 1
    return cursor.next_step > length(cursor.program.steps) ? "completed" : "advance"
end
