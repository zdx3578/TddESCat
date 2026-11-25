struct ProjectionTrial
    event::String
    before_ref::String
    before::Matrix{UInt8}
    history::Vector{Int}
    quantities::Vector{Int}
    outcome::String
    correction::Vector{NTuple{5,Int}}
end

struct ProjectionScope
    version::String
    trials::Vector{ProjectionTrial}
    conditions::Vector
    corrections::Dict{String,Vector{NTuple{5,Int}}}
    disputed::Bool
end

mutable struct ProjectionMemory
    identities::Dict{String,String}
    scopes::Dict{String,ProjectionScope}
end

ProjectionMemory() = ProjectionMemory(Dict(),Dict())

function projection_identity(memory,rule)
    return get!(memory.identities,rule.id) do
        "projection-" * semantic_hash(["public-frame-patch-v1",mechanism_key(rule;composing=true)])
    end
end

function projection_feature(feature, frame, history, quantities)
    kind,index = feature
    if kind == "pixel"
        x,y = index
        return checkbounds(Bool,frame,y+1,x+1) ? Int(frame[y+1,x+1]) : nothing
    elseif kind == "history"
        return length(history) < index ? nothing : Tuple(last(history,index))
    end
    return index <= length(quantities) ? quantities[index] : nothing
end

projection_feature(feature,trial::ProjectionTrial) =
    projection_feature(feature,trial.before,trial.history,trial.quantities)

function fit_projection_scope(trials, history_lengths)
    corrections = Dict(trial.outcome=>trial.correction for trial in trials if trial.outcome != "unresolved")
    outcomes = [trial.outcome for trial in trials]
    disputed = any(!=("unchanged"),outcomes)
    variables = Set{Tuple{String,Any}}(("pixel",(change[1],change[2]))
        for trial in trials for change in trial.correction)
    for length in history_lengths
        length > 0 && push!(variables,("history",length))
    end
    for index in 1:minimum(length(trial.quantities) for trial in trials)
        push!(variables,("quantity",index))
    end
    conditions = NamedTuple[]
    if disputed && !allequal(outcomes)
        witnesses = [[trial.before_ref,trial.event] for trial in trials]
        for feature in sort!(collect(variables);by=repr)
            values = Any[projection_feature(feature,trial) for trial in trials]
            (any(isnothing,values) || allequal(values)) && continue
            relation = empirical_relation(values,outcomes,witnesses)
            isnothing(relation) && continue
            # A distinct reading for every observation gives no evidence for reusing a condition.
            repeated = Dict{Any,Set{String}}()
            for (value,trial) in zip(values,trials)
                push!(get!(Set{String},repeated,value),frame_key(trial.before))
            end
            any(rows->length(rows)>1,Base.values(repeated)) || continue
            push!(conditions,(;feature,relation,repeated))
        end
    end
    rows = [(item.feature,sort!(collect(keys(item.relation.evidence));by=repr),
        sort!([key for (key,rows) in item.repeated if length(rows) > 1];by=repr)) for item in conditions]
    version = "projection-scope-" * semantic_hash([disputed,sort!(unique(outcomes)),rows])
    return ProjectionScope(version,trials,conditions,corrections,disputed)
end

function projection_applicability(memory, id, before, history, quantities)
    scope = get(memory.scopes,id,nothing)
    (isnothing(scope) || !scope.disputed) &&
        return (status="witnessed_base",version=id,reads=String[],correction=NTuple{5,Int}[])
    unresolved = (;status="unproved_projection_scope",version=scope.version,
        reads=sort!(unique([ref for row in scope.trials for ref in (row.before_ref,row.event)])),
        correction=NTuple{5,Int}[])
    isempty(scope.conditions) && return unresolved
    outcomes = String[]
    for item in scope.conditions
        input = projection_feature(item.feature,before,history,quantities)
        value = empirical_successor(item.relation,input)
        isnothing(value) && return unresolved
        length(item.repeated[input]) > 1 || return unresolved
        push!(outcomes,value)
    end
    allequal(outcomes) && haskey(scope.corrections,first(outcomes)) || return unresolved
    return merge(unresolved,(status="conditioned_projection",correction=scope.corrections[first(outcomes)]))
end

function projection_patch(choice,before)
    rule = choice.model.rule
    patch = rule.patch
    (isnothing(patch) || !choice.model.condition.complete) && return nothing
    size(before) == patch.shape || return nothing
    moved = filter(part -> part.family == :translation, choice.fragments)
    shift = (0,0)
    if !isempty(moved)
        offsets = [part.value .- source for (part,source) in zip(moved,rule.anchors)]
        length(offsets) == length(moved) == length(rule.anchors) || return nothing
        allequal(offsets) || return nothing
        shift = first(moved).value
    end
    target = copy(before)
    touched = Set{Pixel}()
    for (changes,(dx,dy)) in ((patch.moving,shift),(patch.fixed,(0,0)))
        for (u,v,old,new) in changes
            x,y = u+dx,v+dy
            checkbounds(Bool,before,y+1,x+1) && before[y+1,x+1] == old || return nothing
            (x,y) ∉ touched || return nothing
            push!(touched,(x,y))
            target[y+1,x+1] = new
        end
    end
    quantities = Int[]
    binding_reads = Set{Pixel}()
    bindings = []
    for part in choice.fragments
        push!(bindings,(family=string(part.family),port=program_input(part)))
        if part.family == :measurement
            box = part.binding.face.box
            for x in box.x-1:box.x+box.width, y in box.y-1:box.y+box.height
                push!(binding_reads,(x,y))
            end
            affected = meter_pixels(part.binding,part.basis,part.expected)
            isdisjoint(touched,affected) && render_meter!(target,part.binding,part.expected) || return nothing
            union!(touched,affected)
            push!(quantities,part.basis)
        elseif part.family == :count
            union!(binding_reads,effect_points(part.token_support))
            push!(quantities,part.basis)
        else
            union!(binding_reads,effect_points(part.basis))
        end
    end
    observed = measure_joint((model=rule,fragments=choice.fragments),target)
    !isempty(observed.assessments) && all(==("supported"),values(observed.assessments)) || return nothing
    return (;frame=target,writes=sort!(collect(touched)),binding_reads=sort!(collect(binding_reads)),
        bindings,quantities)
end

function projected_contract(memory,choice,before,history)
    patch = projection_patch(choice,before)
    isnothing(patch) && return nothing
    id = projection_identity(memory,choice.model.rule)
    scope = projection_applicability(memory,id,before,history,patch.quantities)
    target = copy(patch.frame)
    status = scope.status
    for (x,y,old,base,new) in scope.correction
        if !checkbounds(Bool,before,y+1,x+1) || before[y+1,x+1] != old || target[y+1,x+1] != base
            status = "projection_condition_binding_unknown"
            target = copy(patch.frame)
            break
        end
        target[y+1,x+1] = UInt8(new)
    end
    if status == "conditioned_projection"
        allowed = measure_joint((model=choice.model.rule,fragments=choice.fragments),target)
        if !all(==("supported"),values(allowed.assessments))
            status = "projection_condition_binding_unknown"
            target = copy(patch.frame)
        end
    end
    writes = copy(patch.writes)
    if status == "conditioned_projection"
        append!(writes,[(x,y) for (x,y,_,_,_) in scope.correction])
        sort!(unique!(writes))
    end
    return (;id,scope.version,status,scope.reads,frame=target,base=patch.frame,writes,
        base_scope=patch.writes,
        patch.bindings,patch.binding_reads,patch.quantities,history=copy(history),
        mechanism=active_id(choice.model),rule=choice.model.rule.id,
        training=choice.model.rule.training_event,body=choice.model.rule.patch,
        conditions=predicate_record.(choice.model.condition.atoms))
end

projection_allowed(projection) = !isnothing(projection) &&
    projection.status in ("witnessed_base","conditioned_projection")

function projection_changes(before,after)
    size(before) == size(after) || return nothing
    result = NTuple{4,Int}[]
    for y in axes(before,1), x in axes(before,2)
        before[y,x] != after[y,x] && push!(result,(x-1,y-1,Int(before[y,x]),Int(after[y,x])))
    end
    return result
end

function projection_record(projection,before)
    return Dict(
        "contract"=>projection.id,"version"=>projection.version,"status"=>projection.status,
        "rule"=>projection.rule,"rule_training_event"=>projection.training,"mechanism"=>projection.mechanism,
        "mechanism_patch"=>projection.body,
        "conditions"=>projection.conditions,"condition_reads"=>projection.reads,
        "history"=>projection.history,"quantities"=>projection.quantities,
        "bindings"=>projection.bindings,"binding_reads"=>projection.binding_reads,
        "writes"=>projection.writes,"base_scope"=>projection.base_scope,
        "invariance"=>"all_undeclared_cells_and_public_state",
        "base_writes"=>projection_changes(before,projection.base),
        "projected_writes"=>projection_changes(before,projection.frame),
        "base_sha256"=>frame_key(projection.base),"projected_sha256"=>frame_key(projection.frame))
end

function projection_outcome(projection,before,after,local_supported,complete,public_changes)
    discrepancy = projection_changes(projection.frame,after)
    base_changes = projection_changes(projection.base,after)
    correction = NTuple{5,Int}[]
    if !isnothing(base_changes) && local_supported && complete && isempty(public_changes)
        correction = [(x,y,Int(before[y+1,x+1]),expected,actual) for (x,y,expected,actual) in base_changes]
    end
    outcome = if isnothing(base_changes) || !local_supported || !complete || !isempty(public_changes)
        "unresolved"
    elseif isempty(correction)
        "unchanged"
    else
        semantic_hash(correction)
    end
    declared = Set(projection.writes)
    discrepancy = something(discrepancy,NTuple{4,Int}[])
    matching = size(projection.frame) == size(after) && isempty(discrepancy) && isempty(public_changes)
    return (;outcome,correction,matching,
        inside_writes=[row for row in discrepancy if (row[1],row[2]) in declared],
        outside_writes=[row for row in discrepancy if (row[1],row[2]) ∉ declared],
        binding_or_visibility_unresolved=!local_supported || !complete,
        dimensions_match=size(projection.frame) == size(after),public_changes=sort!(collect(public_changes)))
end

function observe_projection!(memory, id, trial, history_lengths)
    existing = get(memory.scopes,id,nothing)
    history = isnothing(existing) ? [trial] : [existing.trials;trial]
    updated = fit_projection_scope(history,history_lengths)
    memory.scopes[id] = updated
    return updated
end

function check_projection!(memory, projection, before, after, effects, assessment, history_lengths; frozen)
    supported = !isempty(assessment.assessments) && all(==("supported"),values(assessment.assessments))
    eligible = effects.complete && isempty(effects.residual)
    changes = [key for key in keys(effects.public_delta) if key != "response_trace"]
    observed = projection_outcome(projection,before,after,supported,eligible,changes)
    revision = nothing
    if !frozen
        old = get(memory.scopes,projection.id,nothing)
        trial = ProjectionTrial(effects.event_id,effects.before_id,before,projection.history,
            projection.quantities,observed.outcome,observed.correction)
        updated = observe_projection!(memory,projection.id,trial,history_lengths)
        previous = isnothing(old) ? projection.id : old.version
        if updated.version != previous && (updated.disputed || !isnothing(old) && old.disputed)
            revision = (withdrawn=previous,replacement=updated.version,
                conditions=[(feature=row.feature,rows=sort!(collect(keys(row.relation.evidence));by=repr))
                    for row in updated.conditions],
                supporting=[row.event for row in updated.trials if row.outcome == "unchanged"],
                counterexamples=[row.event for row in updated.trials if row.outcome != "unchanged"])
        end
    end
    return merge(observed,(;contract=projection.id,version=projection.version,
        observed_sha256=frame_key(after),local_supported=supported,hypothesis_complete=eligible,revision))
end

function projection_frame_from_writes(before,changes,digest)
    frame = copy(before)
    seen = Set{Pixel}()
    for (x,y,old,new) in changes
        checkbounds(Bool,before,y+1,x+1) && before[y+1,x+1] == old && (x,y) ∉ seen ||
            error("Projection write does not match its confirmed input")
        frame[y+1,x+1] = UInt8(new)
        push!(seen,(x,y))
    end
    frame_key(frame) == digest || error("Projection frame digest differs from its writes")
    return frame
end

function replay_projection_feedback!(memory,directory,events,observations,history_lengths)
    prefix_actions = Int[]
    for (prior,current) in zip(events,Iterators.drop(events,1))
        previous_action = prior.observation.action["id"]
        previous_action == 0 && empty!(prefix_actions)
        push!(prefix_actions,previous_action)
        current.observation.action["id"] == 0 && continue
        ref = current.event["event_id"]
        command = current.event["command_ref"] * ".json"
        decision_path = joinpath(directory,"decisions",command)
        isfile(decision_path) || continue
        decision = read_json(decision_path)
        claim = get(decision,"projection",nothing)
        isnothing(claim) && continue
        prior.event["event_id"] == current.event["before_ref"] == decision["before_ref"] ||
            error("Replayed projection lacks its confirmed input")
        before,after = last(prior.observation.frames),last(current.observation.frames)
        base = projection_frame_from_writes(before,claim["base_writes"],claim["base_sha256"])
        forecast = projection_frame_from_writes(before,claim["projected_writes"],claim["projected_sha256"])
        id = claim["contract"]
        history = collect(Int,claim["history"])
        history == prefix_actions || error("Projection action history differs from the public prefix")
        quantities = collect(Int,claim["quantities"])
        scoped = projection_applicability(memory,id,before,history,quantities)
        status = claim["status"]
        scoped.version == claim["version"] && scoped.reads == claim["condition_reads"] ||
            error("Projection claim used a different evidence prefix")
        if status in ("witnessed_base","conditioned_projection")
            scoped.status == status || error("Projection scope was unavailable at execution")
            expected = copy(base)
            for (x,y,old,from,to) in scoped.correction
                before[y+1,x+1] == old && expected[y+1,x+1] == from ||
                    error("Replayed projection correction is outside its binding")
                expected[y+1,x+1] = UInt8(to)
            end
            forecast == expected || error("Projection correction differs from its learned scope")
        elseif forecast != base
            error("Unproved projection recorded a non-base forecast")
        end
        check_path = joinpath(directory,"checks",command)
        feedback = isfile(check_path) ? get(read_json(check_path),"projection",nothing) : nothing
        effects = observations[ref]
        complete = effects.complete && isempty(effects.residual)
        changes = [key for key in keys(effects.public_delta) if key != "response_trace"]
        definition = (frame=forecast,base,writes=Tuple.(claim["writes"]))
        observed = projection_outcome(definition,before,after,
            !isnothing(feedback) && feedback["local_supported"],complete,changes)
        if !isnothing(feedback)
            keys_to_check = ("outcome","matching","inside_writes","outside_writes","public_changes","correction")
            all(semantic_hash(getproperty(observed,Symbol(key))) == semantic_hash(feedback[key])
                for key in keys_to_check) || error("Projection feedback differs from the public replay")
            feedback["observed_sha256"] == frame_key(after) || error("Projection feedback received a different frame")
        end
        trial = ProjectionTrial(ref,prior.event["event_id"],before,history,quantities,observed.outcome,observed.correction)
        observe_projection!(memory,id,trial,history_lengths)
    end
    return memory
end

function persist_projection_scopes!(store,memory)
    path = store_path(store,"learning","projection-scopes.json")
    rows = Dict(id=>Dict("version"=>scope.version,"disputed"=>scope.disputed,
        "conditions"=>[(feature=row.feature,rows=[(input=input,outcome=outcome,reads=sort!(collect(reads)),
            repeated=length(row.repeated[input]) > 1)
            for ((input,outcome),reads) in sort!(collect(row.relation.evidence);by=entry->repr(first(entry)))]
            ) for row in scope.conditions],
        "outcomes"=>[Dict("event"=>trial.event,"before_ref"=>trial.before_ref,"outcome"=>trial.outcome)
            for trial in scope.trials],"corrections"=>scope.corrections) for (id,scope) in memory.scopes)
    atomic_json(path,rows)
    return length(rows)
end
