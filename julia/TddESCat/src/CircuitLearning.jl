mutable struct HistoryLearning
    job::Union{Nothing,Task}
    submitted::Int
    needed::Bool
    scope::Union{Nothing,String}
    model::Union{Nothing,Dict{String,Any}}
end

HistoryLearning() = HistoryLearning(nothing,0,false,nothing,nothing)

mutable struct ResponseLearning
    job::Union{Nothing,Task}
    submitted::Int
    summaries::Dict{Tuple{Int,Int},Vector{Float64}}
    scope::Union{Nothing,String}
    history::HistoryLearning
    level::Int
    dimensions::Tuple
    contrasts::Dict{Tuple{String,Int},Dict{Int,Set{Int}}}
    revision::Int
end

ResponseLearning() = ResponseLearning(nothing,0,Dict(),nothing,HistoryLearning(),-1,(7,4),Dict(),0)

function response_class(row)
    row.state == "GAME_OVER" && return 3
    row.advanced && return 2
    return row.unchanged ? 0 : 1
end

response_action(row) = row.effects.action["id"]
history_action(action) = join(action_key(action),":")
history_response(row) = string(response_class(row),':',row.next_context)
history_step(row) = (input=history_action(row.effects.action),output=history_response(row),event=relation_ref(row))

function response_history_task(agenda,level)
    starts = Dict{Tuple{Int,Int},Vector{NamedTuple}}()
    origins = Dict{Tuple{Int,Int},String}()
    for row in agenda.samples
        row.level == level || continue
        key = (row.attempt,row.level)
        get!(origins,key,row.context)
        steps = get!(Vector{NamedTuple},starts,key)
        push!(steps,history_step(row))
    end
    isempty(starts) && return nothing
    active = (last(agenda.samples).attempt,level)
    haskey(origins,active) || return nothing
    scope = origins[active]
    episodes = [(;origin=scope,steps=starts[key]) for key in sort!(collect(keys(starts)))
        if origins[key] == scope]
    length(episodes) >= 2 || return nothing
    return (;episodes)
end

function invalidate_response_scores!(memory)
    memory.revision += 1
    empty!(memory.summaries)
    memory.scope = nothing
end

function observe_response!(memory,agenda;refinement=nothing)
    row = last(agenda.samples)
    if row.level != memory.level
        memory.level = row.level
        memory.dimensions = (7,4)
        empty!(memory.contrasts)
        invalidate_response_scores!(memory)
        memory.history.needed = false
        memory.history.model = nothing
        memory.history.scope = nothing
    end
    histories = get!(Dict{Int,Set{Int}},memory.contrasts,(row.context,response_action(row)))
    previous = first(previous_key(agenda,row.preceding))
    seen = get!(Set{Int},histories,previous)
    outcome = response_class(row)
    if !isempty(seen) && !(outcome in seen)
        invalidate_response_scores!(memory)
    end
    push!(seen,outcome)
    if length(memory.dimensions) == 2 &&
            length(unique(only(outcomes) for outcomes in values(histories) if length(outcomes) == 1)) > 1
        memory.dimensions = (7,8,4)
        invalidate_response_scores!(memory)
    end
    memory.history.needed |= length(memory.dimensions) == 3 || !isnothing(refinement)
    if !isnothing(memory.history.model)
        observed = current_history_state(memory.history.model,agenda,row.next_context)
        if observed.status == :contradicted
            memory.history.model = nothing
            memory.history.scope = nothing
            memory.history.needed = true
        end
    end
    if row.advanced
        invalidate_response_scores!(memory)
    end
    return nothing
end

function request_response_model!(memory,worker,agenda,snapshot,batch)
    isnothing(memory.job) || return
    n = length(agenda.samples)
    n-memory.submitted >= batch || return
    dimensions,level,revision = memory.dimensions,memory.level,memory.revision
    last(agenda.samples).advanced && return
    rows = map(filter(row->row.level == level,agenda.samples)) do row
        act = response_action(row)-1
        previous = first(previous_key(agenda,row.preceding))
        vals = length(dimensions) == 3 ? [act,previous,response_class(row)] : [act,response_class(row)]
        (;event=relation_ref(row),values=vals)
    end
    # A changed variable layout re-encodes every prior confirmed event.
    length(rows) >= max(batch,4) || return
    held_out = max(2,length(rows)÷5)
    training, validation = rows[1:end-held_out],rows[end-held_out+1:end]
    length(unique(row.values[end] for row in training)) >= 2 || return
    memory.submitted = n
    memory.job = @async begin
        result = compute_request!(worker,snapshot,"train_circuit",
            (;dimensions,units=2,steps=24,samples=training,seed=0))
        result.execution == "completed" && result.answer == "value" &&
            result.value["status"] == "fitted" || return nothing
        model = result.value
        model["events"] == [row.event for row in training] ||
            error("Circuit training discarded confirmed events")
        model["sample_count"] == length(training) || error("Circuit training changed event count")
        conditions = [(previous,id) for previous in (length(dimensions)==3 ? (0:7) : (0:0))
            for id in 1:7]
        evidence = [length(dimensions)==3 ? [id-1,previous,nothing] : [id-1,nothing]
            for (previous,id) in conditions]
        evaluated = compute_request!(worker,snapshot,"query_circuit",
            (;artifact=model["artifact"],evidence,target=length(dimensions)-1))
        evaluated.execution == "completed" && evaluated.answer == "value" &&
            evaluated.value["status"] == "supported" || return nothing
        predictions = evaluated.value["rows"]
        scores = Dict{Tuple{Int,Int},Vector{Float64}}()
        for (key,row) in zip(conditions,predictions)
            row["status"] == "supported" || continue
            values = row["probabilities"]
            length(values) == last(dimensions) || continue
            total = normalized_probability_total(values)
            isnothing(total) || (scores[key] = Float64.(values)./total)
        end
        key_of(row) = length(dimensions)==3 ? (row.values[2],row.values[1]+1) : (0,row.values[1]+1)
        trained_keys = Set(key_of.(training))
        filter!(pair->first(pair) in trained_keys,scores)
        baseline = ones(last(dimensions))
        for row in training
            baseline[last(row.values)+1] += 1
        end
        baseline ./= sum(baseline)
        evaluations = NamedTuple[]
        for row in validation
            distribution = get(scores,key_of(row),nothing)
            isnothing(distribution) && continue
            target = last(row.values)+1
            push!(evaluations,(event=row.event,model_loss=-log(max(distribution[target],eps())),
                baseline_loss=-log(baseline[target])))
        end
        accepted = length(evaluations) == length(validation) &&
            sum(row.model_loss for row in evaluations) < sum(row.baseline_loss for row in evaluations)
        calibration = (;accepted,events=[row.event for row in validation],evaluations)
        return (;model,scores,dimensions,level,snapshot,calibration,revision)
    end
    return nothing
end

function collect_response_model!(memory,store,agenda)
    isnothing(memory.job) && return
    istaskdone(memory.job) || return
    result = fetch(memory.job)
    memory.job = nothing
    isnothing(result) && return
    # Evidence appended under a changed feature schema requires a full fit.
    applicable = result.revision == memory.revision && result.level == memory.level &&
        result.dimensions == memory.dimensions &&
        !last(agenda.samples).advanced
    if applicable
        memory.summaries = result.calibration.accepted ? result.scores : Dict()
        memory.scope = result.calibration.accepted ? result.snapshot : nothing
    end
    atomic_json(store_path(store,"learning","circuits",result.snapshot * ".json"),
        (;result.dimensions,result.level,result.snapshot,result.model,result.calibration,
            result.revision,applicable))
    return nothing
end

function circuit_experiment_scores(memory,agenda)
    previous = first(previous_key(agenda,agenda.previous))
    scores = Dict{Int,Float64}()
    for id in 1:7
        distribution = get(memory.summaries,(previous,id),get(memory.summaries,(0,id),nothing))
        isnothing(distribution) && continue
        # Only use observational predictions for ranking learning experiments.
        entropy = -sum(p>0 ? p*log(p) : 0.0 for p in distribution)
        scores[id] = entropy
    end
    return scores
end

function history_walk(model,steps)
    state = model["initial"]
    for step in steps
        edge = get(model["edges"][string(state)],step.input,nothing)
        isnothing(edge) && return (;status=:unknown,state,event=step.event)
        edge["output"] == step.output || return (;status=:contradicted,state,event=step.event)
        state = edge["state"]
    end
    return (;status=:supported,state,event=nothing)
end

function current_history_state(model,agenda,context)
    from = agenda.previous
    while from != 0
        earlier = agenda.samples[from].preceding
        (earlier == 0 || agenda.samples[earlier].advanced) && break
        from = earlier
    end
    rows = from == 0 ? @view(agenda.samples[1:0]) : @view(agenda.samples[from:agenda.previous])
    origin = isempty(rows) ? context : first(rows).context
    origin == model["origin"] || return (;status=:out_of_scope,state=nothing,event=nothing)
    return history_walk(model,(history_step(row) for row in rows))
end

function request_history_model!(memory,worker,agenda,snapshot,batch;priority=false)
    fit = memory.history
    fit.needed && isnothing(fit.job) || return
    n = length(agenda.samples)
    n > fit.submitted && (priority || n-fit.submitted >= batch) || return
    fit.submitted = n
    level = memory.level
    corpus = response_history_task(agenda,level)
    isnothing(corpus) && return
    fit.job = Threads.@spawn begin
        response = compute_request!(worker,snapshot,"learn_history",corpus)
        return (;snapshot,level,corpus,response)
    end
    return nothing
end

function collect_history_model!(memory,store,agenda)
    fit = memory.history
    (isnothing(fit.job) || !istaskdone(fit.job)) && return
    result = fetch(fit.job)
    fit.job = nothing
    reply = result.response
    learned = reply.execution == "completed" && reply.answer == "value" && reply.value["status"] == "learned"
    model = learned ? reply.value : nothing
    corpus = learned && result.level == memory.level ? response_history_task(agenda,result.level) : nothing
    applicable = if !isnothing(corpus)
        reads = sort!([step.event for ep in result.corpus.episodes for step in ep.steps])
        model["read_events"] == reads || error("History learner changed the source evidence")
        all(ep->ep.origin == model["origin"] && history_walk(model,ep.steps).status != :contradicted,corpus.episodes)
    else
        false
    end
    if applicable
        fit.model = model
        fit.scope = result.snapshot
    end
    atomic_json(store_path(store,"learning","histories",result.snapshot * ".json"),
        (;result.snapshot,result.level,model,applicable,reply.execution,reply.answer,reply.detail))
    return nothing
end

function history_experiment(memory,agenda,context,level)
    fit = memory.history
    (isnothing(fit.model) || level != memory.level) && return nothing
    binding = current_history_state(fit.model,agenda,context)
    binding.status == :supported || return nothing
    edges = fit.model["edges"][string(binding.state)]
    return (;scope=fit.scope,state=binding.state,edges)
end
