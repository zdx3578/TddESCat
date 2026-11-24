function selected_relation_corpus(predicate)
    comparisons = predicate.certificate["comparison"]
    count(row->row["verdict"] == "proven",comparisons) >= 2 || return nothing
    signature = deepcopy(predicate.signature)
    registry,_ = registry_from(signature,[])
    source = first(predicate.programs)
    slots = [Dict("index"=>i-1,"sort"=>"SceneBefore","time_role"=>"before","role_constraints"=>[])
        for i in eachindex(comparisons)]
    programs = [replace(source,render_term(Slot(0))=>render_term(Slot(i-1))) for i in eachindex(comparisons)]
    origins = Dict{String,Any}[]
    for (index,(text,row)) in enumerate(zip(programs,comparisons))
        walk_wire(decode_program(text,registry)) do _,path
            push!(origins,Dict("program_index"=>index-1,"expression_path"=>path,
                "occurrence_id"=>"relation-occ-" * join([index-1;path],"."),
                "event_ref"=>row["event_ref"],"interpretation_ref"=>"observed-guard-v1",
                "slot_bindings_ref"=>row["before_ref"],"support_ref"=>row["before_ref"]))
        end
    end
    return (;signature,slots,programs,origins,comparisons)
end

function train_prior_relations!(knowledge,config,store,repo_root)
    settings = read_json(store_path(store,"supervision.json"))
    policy = read(config.learning["policy_file"],String)
    content_hash(policy) == settings["policy_sha256"] || error("Session policy changed since launch")
    publications = Dict{String,Any}()
    directory = store_path(store,"publication")
    for (index,model) in enumerate(knowledge.active)
        atoms = model.condition.atoms
        relation_index = findfirst(atom->atom isa RelationPredicate,atoms)
        isnothing(relation_index) && continue
        predicate = atoms[relation_index]
        corpus = selected_relation_corpus(predicate)
        isnothing(corpus) && continue
        if !haskey(publications,predicate.certificate_sha)
            current = read_published_stitch(directory)
            base = isnothing(current) ? LibrarySnapshot() : current.snapshot
            isnothing(current) || merge_semantic_signature!(corpus.signature,current.bundle["signature"])
            knowledge.learning_jobs += 1
            job = store_path(store,"learning","job-" * lpad(knowledge.learning_jobs,6,'0'))
            snapshot = "association-" * predicate.certificate_sha
            refs = [row["event_ref"] for row in corpus.comparisons]
            atomic_json(joinpath(job,"relation-corpus.json"),Dict("certificate"=>predicate.certificate_sha,
                "events"=>refs,"source_programs"=>corpus.programs))
            manifest = freeze_stitch_job(joinpath(job,"input"),basename(job),snapshot,base,corpus.signature,
                corpus.programs,corpus.origins,corpus.slots;repo_root,config_text=policy,
                engine_identity=settings["engine_identity"],intent="relation",consumer="relation-predicate",obligation_refs=refs)
            status = wait_worker(job,store_path(store))
            status["policy_sha256"] == manifest["config_file"]["sha256"] || error("Relation worker policy differs")
            if status["code"] != 0
                atomic_json(joinpath(job,"assessment.json"),Dict("result"=>"worker_incomplete","status"=>status))
                continue
            end
            checked = read_stitch_rounds(joinpath(job,"input"),joinpath(job,"output"))
            final = last(checked.verified)
            root_call = findfirst(call->call["program_index"] == 0 && isempty(call["call_path"]),final["calls"])
            if isnothing(root_call)
                atomic_json(joinpath(job,"assessment.json"),Dict("result"=>"no_reusable_relation_root","status"=>status))
                continue
            end
            id = publish_stitch!(directory,checked;current_evidence=snapshot)
            released = read_published_stitch(directory;publication=id)
            rewrite = first(released.bundle["rewritten_programs"])
            root = only(call["definition_ref"] for call in released.bundle["calls"]
                if call["program_index"] == 0 && isempty(call["call_path"]))
            merge!(knowledge.definition_depths,released.bundle["definition_depths"])
            evidence = Dict("program"=>rewrite,"library"=>released.snapshot.entries,
                "signature"=>released.bundle["signature"],"definition"=>root,"publication"=>id)
            publications[predicate.certificate_sha] = evidence
            atomic_json(joinpath(job,"assessment.json"),Dict("result"=>"published","publication"=>id,
                "definition"=>root,"status"=>status))
        end
        learned = publications[predicate.certificate_sha]
        programs = copy(predicate.programs)
        programs[1] = learned["program"]
        replaced = RelationPredicate(predicate.candidates,programs,learned["signature"],predicate.certificate,
            predicate.certificate_sha,learned["library"],String[learned["definition"]])
        condition = model.condition
        updated = copy(atoms)
        updated[relation_index] = replaced
        active = GuardSearch(updated,condition.support,condition.excluded,condition.unresolved,
            condition.complete,condition.feasible,condition.visited)
        knowledge.active[index] = ActiveMechanism(model.rule,active,model.counterexamples,model.unknown)
    end
    return nothing
end
