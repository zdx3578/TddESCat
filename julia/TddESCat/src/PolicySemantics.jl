struct LearnedPolicy
    publication::String
    definition::String
    depth::Int
    model::String
    body::Dict{String,Any}
    training::Vector{String}
    available_after::String
end

function policy_episode(samples, changes)
    entered = filter(sample->sample.entered,samples)
    isempty(entered) && return nothing
    last(entered).advanced || return nothing
    actions = NamedTuple[]
    for (i,row) in enumerate(entered)
        binding = row.contact
        before = Set(first.(binding.facts.remaining))
        binding.point in before || return nothing
        if row.advanced
            i == length(entered) || return nothing
            push!(actions,(kind="advance",input=length(before),event=binding.event,
                proof=binding.event))
            continue
        end
        proof = get(changes,binding.event,nothing)
        (isnothing(proof) || i == length(entered)) && return nothing
        after = Set(first.(entered[i+1].contact.facts.remaining))
        after == setdiff(before,[binding.point]) || return nothing
        push!(actions,(kind="resolve_site",input=length(before),event=binding.event,
            proof=proof.observed))
    end
    refs = unique([ref for row in entered for ref in progress_witnesses(row.contact)])
    append!(refs,[row.proof for row in actions])
    return (episode=last(entered).contact.event,actions,events=unique(refs))
end

function policy_corpus(control)
    entries = Dict{Int,Vector{GoalSample}}()
    for row in control.goal_samples
        push!(get!(Vector{GoalSample},entries,row.attempt),row)
    end
    episodes = filter(!isnothing,[policy_episode(entries[key],control.site_completions)
        for key in sort!(collect(keys(entries)))])
    length(unique(length(scope.actions) for scope in episodes)) > 1 || return nothing
    fit = fit_progress_relations([row.contact for row in control.goal_samples])
    length(fit.rules) == 1 && only(fit.rules).variable == :remaining_sites || return nothing
    rule = only(fit.rules)
    rows = Dict(rule.rows)
    all(get(rows,action.input,nothing) == (action.kind == "advance")
        for episode in episodes for action in episode.actions) || return nothing

    signature = typed_motion_signature(Pixel[])
    append!(signature["sorts"],[Dict{String,Any}("id"=>name) for name in ("SceneBefore","Boolean")])
    sort = semantic_sort!(signature,"prog",Dict("kind"=>"program","version"=>"contact-relationship-policy-v1",
        "input_ports"=>["SceneBefore"],"output_ports"=>["PublicAdvancement"]))
    flag = semantic_operator!(signature,["SceneBefore"],"Boolean",
        Dict("kind"=>"PolicyTest","layout"=>Dict("relation"=>"learned_advancement",
            "model"=>fit.model,"rows"=>rule.rows)))
    advance = semantic_operator!(signature,["SceneBefore"],sort,
        Dict("kind"=>"PolicyTask","layout"=>Dict("relation"=>"public_advancement")))
    resolve = semantic_operator!(signature,["SceneBefore"],sort,
        Dict("kind"=>"PolicyTask","layout"=>Dict("relation"=>"observed_site_change")))
    branch = semantic_operator!(signature,["Boolean",sort,sort],sort,Dict("kind"=>"PolicyBranch"))
    stop = semantic_operator!(signature,["SceneBefore"],"Boolean",
        Dict("kind"=>"PolicyStop","layout"=>Dict("relation"=>"confirmed_public_advance")))
    repeat = semantic_operator!(signature,[sort,"Boolean"],sort,
        Dict("kind"=>"PolicyRepeat","layout"=>Dict("variant"=>"strict_visible_site_subset",
            "scope"=>CONTACT_DOMAIN)))
    slots = Dict{String,Any}[]
    programs = String[]
    origins = Dict{String,Any}[]
    registry,_ = registry_from(signature,[])
    for (index,episode) in enumerate(episodes)
        slot = Slot(index-1)
        push!(slots,Dict("index"=>index-1,"sort"=>"SceneBefore","time_role"=>"before",
            "role_constraints"=>[]))
        term = Call(repeat,Call(branch,Call(flag,slot),Call(advance,slot),Call(resolve,slot)),Call(stop,slot))
        text = render_term(term)
        push!(programs,text)
        scope = "task-episode-" * string(index)
        walk_wire(decode_program(text,registry)) do _,path
            push!(origins,Dict("program_index"=>index-1,"expression_path"=>path,
                "occurrence_id"=>"policy-" * join([index;path],"."),
                "event_ref"=>episode.episode,"interpretation_ref"=>"verified-relationship-task",
                "slot_bindings_ref"=>scope,"support_ref"=>scope,"source_kind"=>"observed"))
        end
    end
    events = sort!(unique([fit.reads;[ref for episode in episodes for ref in episode.events]]))
    return (;signature,slots,programs,origins,episodes,events,model=fit.model)
end

function analyze_policy_body(body,registry)
    slot = relation_policy_slot(body)
    if !isnothing(slot)
        tree = analyze_relation_policy(body,registry,slot)
        isnothing(tree) || return (;tree)
    end
    get(body,"kind",nothing) == "Call" || return nothing
    head(node) = registry[node["operator"]]["descriptor"]
    kind(node) = head(node)["kind"]
    kind(body) == "PolicyRepeat" || return nothing
    repeat,stop = body["args"]
    kind(repeat) == "PolicyBranch" && kind(stop) == "PolicyStop" || return nothing
    test,positive,negative = repeat["args"]
    kind(test) == "PolicyTest" && all(node->kind(node) == "PolicyTask",(positive,negative)) ||
        return nothing
    ports = only(test["args"])
    all(node->only(node["args"]) == ports,(positive,negative,stop)) ||
        error("Policy lost its shared role binding")
    return (;model=head(test)["layout"]["model"],
        rows=Dict(Int(input)=>Bool(outcome) for (input,outcome) in head(test)["layout"]["rows"]),
        positive=head(positive)["layout"]["relation"],negative=head(negative)["layout"]["relation"],
        stop=head(stop)["layout"]["relation"],variant=head(body)["layout"]["variant"])
end

function prepare_policy_learning!(knowledge,config,store,root,control;
        completed=Set{String}(),entries=nothing,solver=nothing,snapshot="trajectory",proposal=nothing,
        live_agenda=control)
    corpus = if !isnothing(proposal)
        proposal
    elseif isnothing(entries)
        policy_corpus(control)
    else
        published = Set(row.body["scope"] for row in knowledge.policies if haskey(row.body,"scope"))
        policy_corpus(control,entries;published,solver,snapshot)
    end
    isnothing(corpus) && return nothing
    key = semantic_hash([corpus.model,corpus.programs])
    key in completed && return nothing
    current = read_published_stitch(store_path(store,"publication"))
    base = isnothing(current) ? LibrarySnapshot() : current.snapshot
    isnothing(current) || merge_semantic_signature!(corpus.signature,current.bundle["signature"])
    library = scoped_search_library(base,corpus.signature,corpus.programs,corpus.slots)
    knowledge.learning_jobs += 1
    job = store_path(store,"learning","job-" * lpad(knowledge.learning_jobs,6,'0'))
    cutoff = isnothing(entries) ? 0 : length(control.samples)
    reads = isnothing(entries) ? NamedTuple[] : trajectory_reads(corpus,control)
    if !isempty(reads)
        conflicts = trajectory_counterexamples(reads,cutoff,live_agenda)
        if !isempty(conflicts)
            atomic_json(joinpath(job,"policy-rejection.json"),
                (;key,cutoff,reads,conflicts,reason="trajectory_dependencies_changed"))
            return nothing
        end
    end
    settings = read_json(store_path(store,"supervision.json"))
    policy = read(config.learning["policy_file"],String)
    content_hash(policy) == settings["policy_sha256"] || error("Session learning policy changed")
    snapshot = "policy-" * key
    manifest = freeze_stitch_job(joinpath(job,"input"),basename(job),snapshot,library,
        corpus.signature,corpus.programs,corpus.origins,corpus.slots;repo_root=root,
        config_text=policy,engine_identity=settings["engine_identity"],intent="program",
        consumer="policy-semantics",obligation_refs=corpus.events)
    atomic_json(joinpath(job,"policy-corpus.json"),merge(corpus,(;cutoff,reads)))
    return (;job,manifest,corpus,snapshot,key,agenda=isnothing(entries) ? nothing : control,entries,reads,cutoff)
end

function collect_policy_learning!(knowledge,store,prepared,status;available_after,live_agenda=nothing)
    (;job,manifest,corpus,snapshot,key) = prepared
    status["policy_sha256"] == manifest["config_file"]["sha256"] &&
        status["binary_sha256"] == manifest["engine_pin"]["binary_sha256"] ||
        error("Policy worker identity differs")
    output = joinpath(job,"output")
    checked = isdir(output) ? read_stitch_rounds(joinpath(job,"input"),output) : nothing
    complete = !isnothing(checked) && !isempty(checked.verified) && status["code"] in (0,10) &&
        last(checked.verified)["round_outcome"] == "no_positive_gain"
    assessment = Dict{String,Any}("kind"=>"policy","key"=>key,"status"=>status,"search_complete"=>complete)
    if !isnothing(live_agenda) && !isempty(prepared.reads)
        conflicts = trajectory_counterexamples(prepared.reads,prepared.cutoff,live_agenda)
        isempty(conflicts) || return record_program_assessment(job,merge(assessment,Dict(
            "result"=>"trajectory_dependencies_changed","counterexamples"=>conflicts)))
    end
    if isnothing(checked) || isempty(checked.verified) || isempty(last(checked.verified)["calls"])
        return record_program_assessment(job,merge(assessment,Dict("result"=>"policy_not_discovered")))
    end
    checked.manifest["evidence_snapshot_id"] == snapshot && checked.text == corpus.programs &&
        canonical_bytes(checked.signature) == canonical_bytes(corpus.signature) ||
        error("The policy search input differs from its submitted corpus")
    selected = Dict{String,LearnedPolicy}()
    confirmed = Ref{Dict{String,Int}}()
    id = publish_stitch!(store_path(store,"publication"),checked;current_evidence=snapshot,
        validate_consumer=released->begin
            validate_policy_bodies!(selected,released,prepared,available_after)
            confirmed[] = Dict{String,Int}(released.bundle["definition_depths"])
            !isempty(selected)
        end)
    isnothing(id) && return record_program_assessment(job,merge(assessment,Dict(
        "result"=>"no_verified_policy_body")))
    verified = [selected[id] for id in sort!(collect(keys(selected)))]
    for policy in verified
        if !haskey(policy.body,"scope")
            union!(policy.training,corpus.events)
        end
    end
    atomic_json(joinpath(job,"policy-publication.json"),Dict("publication"=>id,"available_after"=>available_after,
        "snapshot"=>snapshot,"input_sha256"=>checked.input_sha,"policies"=>verified))
    for policy in verified
        if haskey(policy.body,"scope")
            filter!(old->get(old.body,"scope",nothing) != policy.body["scope"],knowledge.policies)
        end
        push!(knowledge.policies,policy)
    end
    merge!(knowledge.definition_depths,confirmed[])
    return record_program_assessment(job,merge(assessment,Dict("result"=>"published","publication"=>id)))
end

function validate_policy_bodies!(selected,released,prepared,available_after)
    corpus = prepared.corpus
    id = released.publication
    registry,definitions = registry_from(corpus.signature,released.snapshot.entries)
    validation = if !isnothing(prepared.agenda)
        (;by_ref=Dict(entry.event["event_id"]=>entry.observation for entry in prepared.entries),
            source_producer=Dict(i=>p for p in values(prepared.agenda.producers) for i in p.support),
            active_outcomes=active_policy_outcomes(prepared.agenda),continuity=Dict{Tuple{Int,Int},Bool}())
    end
    for (i,text) in enumerate(released.bundle["rewritten_programs"])
        call = decode_program(text,registry)
        definition = get(call,"operator",nothing)
        calls = [row for row in released.bundle["calls"] if row["program_index"] == i-1]
        isempty(calls) && continue
        body = expand_library_term(call,definitions)
        body == decode_program(corpus.programs[i],registry) || error("Policy expansion changed its source")
        policy = analyze_policy_body(body,registry)
        isnothing(policy) && continue
        if hasproperty(policy,:tree)
            episode = corpus.episodes[i]
            verify_relation_episode(policy.tree,episode,prepared.agenda,prepared.entries;validation...) ||
                error("Policy does not reproduce its observed relation trajectory")
            refs = sort!(unique([row["definition_ref"] for row in calls]))
            depths = released.bundle["definition_depths"]
            definition = argmax(ref->depths[ref],refs)
            scope = semantic_hash(policy.tree)
            body_record = Dict("tree"=>policy.tree,"definitions"=>refs,"scope"=>scope,
                "structure"=>episode.structure,"structure_source"=>"confirmed_task_trajectory",
                "public_outcomes"=>policy_outcome_steps(policy.tree),"preparation_lookback"=>preparation_lookback(policy.tree))
            result = get!(selected,scope,LearnedPolicy(id,definition,depths[definition],corpus.model,
                body_record,String[],available_after))
            if any(>(1),diff(episode.members))
                result.body["dependency_source"] = "witnessed_role_dependency"
            end
            if hasproperty(episode,:preparations)
                reader = last(episode.members)
                row = prepared.agenda.samples[reader]
                if !row.advanced
                    input = (;reader,event=relation_ref(row),inputs=episode.preparations)
                    push!(get!(Vector{NamedTuple},result.body,"preparation_trials"),input)
                end
            end
            preconditions = observed_policy_preconditions(episode,prepared.agenda)
            if !isempty(preconditions)
                union!(get!(Vector{NamedTuple},result.body,"effect_preconditions"),preconditions)
            end
            union!(result.training,episode.events)
            continue
        end
        haskey(definitions,definition) || continue
        any(row->isempty(row["call_path"]) && row["definition_ref"] == definition,calls) ||
            error("Policy call is absent from the search proof")
        for action in corpus.episodes[i].actions
            expected = action.kind == "advance" ? "public_advancement" : "observed_site_change"
            actual = get(policy.rows,action.input,nothing)
            isnothing(actual) && error("Policy cannot reproduce its public branch")
            (actual ? policy.positive : policy.negative) == expected ||
                error("Policy branch differs from its public task")
        end
        prior = get!(selected,definition,LearnedPolicy(id,definition,
            released.bundle["definition_depths"][definition],policy.model,Dict(
                "rows"=>[(input,outcome) for (input,outcome) in sort!(collect(policy.rows);by=first)],
                "positive"=>policy.positive,"negative"=>policy.negative,
                "stop"=>policy.stop,"variant"=>policy.variant),String[],available_after))
        union!(prior.training,corpus.episodes[i].events)
    end
    return nothing
end

function active_policy(policies,goal)
    isnothing(goal) && return nothing
    for policy in Iterators.reverse(policies)
        policy.model == goal.model || continue
        input = length(goal.facts.remaining)
        row = findfirst(row->first(row) == input,policy.body["rows"])
        relation = isnothing(row) ? "discriminate" :
            policy.body["rows"][row][2] ? policy.body["positive"] : policy.body["negative"]
        return (policy=policy,input,relation,reads=unique([policy.training;policy.available_after;goal.reads]))
    end
    return nothing
end

function policy_task_record(selected,goal,choice,blocked)
    (isnothing(selected) || isnothing(choice)) && return nothing
    selected.policy.definition in blocked && return nothing
    plan = get(choice,:contact,nothing)
    isnothing(plan) && return nothing
    expected = selected.relation == "public_advancement" ? :progress :
        selected.relation == "observed_site_change" ? :enter_only : :unknown
    plan.progress.judgment == expected || return nothing
    plan.progress.model == goal.model || return nothing
    return (definition=selected.policy.definition,publication=selected.policy.publication,
        available_after=selected.policy.available_after,source=selected.policy.training,
        relation=selected.relation,condition_depth=1,repeat_depth=1,
        before=goal.before,targets=sort!(collect(goal.targets)),site=plan.point,
        recheck=choice.executes_contact,reads=selected.reads,model=goal.model)
end

function policy_task_feedback(record,contact,before,after,changes,control)
    isnothing(record) && return nothing
    crossed = after.observation.levels_completed > before.observation.levels_completed
    same_site = !isnothing(contact) && contact.point == record.site
    result = if record.recheck && same_site && crossed
        record.relation == "public_advancement" ? :stopped : :refuted_branch
    elseif record.recheck && (!same_site || contact.outcome == :blocked)
        :refuted_branch
    elseif record.recheck && same_site && record.relation == "public_advancement"
        :refuted_branch
    elseif crossed
        :invalidated_variant
    elseif any(row->row.point == record.site && row.status in (:changed,:disappeared),changes)
        expected = setdiff(Set(record.targets),[record.site])
        actual = Set(first.(contact_facts(control,after.observation.action["id"]).remaining))
        actual == expected ? :decreased : :invalidated_variant
    elseif record.recheck && same_site
        :awaiting_visible_result
    else
        :continue
    end
    return (;result,event=after.event["event_id"],advanced=crossed,definition=record.definition,
        relation=record.relation,site=record.site)
end
