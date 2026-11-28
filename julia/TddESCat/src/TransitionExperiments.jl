mutable struct TransitionCandidate
    rule::EndpointTransform
    version::String
    witnesses::Vector{String}
    observed::Dict{String,String}
    blocked::Dict{String,String}
    confirmed_contexts::Dict{Tuple{String,String},String}
    contradicted_contexts::Set{Tuple{String,String}}
    restricted::Bool
    checked::Set{String}
    supported::Bool
end

struct TransitionMemory
    candidates::Dict{String,TransitionCandidate}
    triggers::Dict{Tuple{Int,Int,String},Vector{String}}
    actions::Dict{Int,Set{PublicActionKey}}
end
TransitionMemory() = TransitionMemory(Dict(),Dict(),Dict())

function transition_binding(action,groups)
    id,x,y = action_key(action)
    id!=6 && return (;profile=primitive_profile(id),origin=(0,0))
    group = point_component(groups,(x,y))
    isnothing(group) && return nothing
    return (;profile=click_profile(group,(x,y)),origin=(x,y))
end

function transition_trials(memory,obs,action,view,context)
    binding = transition_binding(action,view.groups)
    isnothing(binding) && return NamedTuple[]
    trigger = (obs.levels_completed,action["id"],binding.profile)
    trials = NamedTuple[]
    for key in get(memory.triggers,trigger,String[])
        candidate = memory.candidates[key]
        rule = candidate.rule
        input = endpoint_input(rule,view,binding.origin)
        isnothing(input) && continue
        signature = semantic_hash(input)
        location = (signature,context)
        location in candidate.contradicted_contexts && continue
        conflicted = haskey(candidate.blocked,signature)
        conflicted && !haskey(candidate.confirmed_contexts,location) && continue
        candidate.restricted && !haskey(candidate.observed,signature) && continue
        expected = endpoint_expectation(rule,input,view,binding.origin)
        isnothing(expected) && continue
        partial = expected.known < expected.total
        contrast = signature ∉ candidate.checked && (!candidate.supported || partial)
        reads = copy(candidate.witnesses)
        seen = conflicted ? candidate.confirmed_contexts[location] : get(candidate.observed,signature,nothing)
        isnothing(seen) || push!(reads,seen)
        conflicted && push!(reads,candidate.blocked[signature])
        scope = conflicted ? :observed_context : candidate.restricted ? :observed_input : :hypothesis
        unique!(reads)
        version = candidate.restricted ? semantic_hash([candidate.version,string(scope),signature,reads]) : candidate.version
        push!(trials,(;key,version,signature,expected,contrast,scope,reads))
    end
    return trials
end

function transition_experiment(agenda,obs,decision,context)
    memory = agenda.transitions
    actions = get(memory.actions,obs.levels_completed,nothing)
    isnothing(actions) && return nothing
    # Only a still-open question can originate a dispatch. Completed hypotheses
    # remain observable when another consumer independently selects their action.
    pending(key) = !memory.candidates[key].supported || open_correspondences(memory.candidates[key].rule)
    any(((trigger,keys),)->trigger[1] == obs.levels_completed && any(pending,keys),memory.triggers) || return nothing
    view = EndpointView(last(obs.frames),decision.groups)
    candidates = unique([sort!(collect(actions));[action_key(row.action) for row in decision.ranked]])
    for key in candidates
        first(key) in obs.available_actions || continue
        observed_failure(agenda,context,key,agenda.previous) && continue
        action = concrete_action(key)
        trials = transition_trials(memory,obs,action,view,context)
        any(row->row.contrast,trials) || continue
        return (;action,intent=:test_endpoint_transform,tests=NamedTuple[],
            reads=unique!(reduce(vcat,(t.reads for t in trials))),obligation=nothing,transitions=trials)
    end
    return nothing
end

function bind_transition_trials(agenda,proposal,obs,action,groups;context=relation_context(obs))
    if !isnothing(proposal) && (hasproperty(proposal,:transitions) || proposal.intent == :test_rebound_omission)
        return proposal
    end
    actions = get(agenda.transitions.actions,obs.levels_completed,nothing)
    (isnothing(actions) || !any(k->first(k)==action["id"],actions)) && return proposal
    trials = transition_trials(agenda.transitions,obs,action,EndpointView(last(obs.frames),groups),context)
    isempty(trials) && return proposal
    isnothing(proposal) && (proposal=(;action,intent=:apply_endpoint_transform,tests=NamedTuple[],
        reads=String[],obligation=nothing))
    reads = unique([proposal.reads;reduce(vcat,(t.reads for t in trials))])
    return merge(proposal,(;reads,transitions=trials))
end

function restrict_transition!(candidate,event,signature,context)
    (signature,context) in candidate.contradicted_contexts && return
    candidate.supported = false
    empty!(candidate.checked)
    candidate.blocked[signature] = event
    push!(candidate.contradicted_contexts,(signature,context))
    candidate.restricted || push!(candidate.witnesses,event)
    candidate.restricted = true
end

function register_transition!(candidate,key,trigger,origin,input,output,context,refs,learned;created=false)
    signature = semantic_hash(input)
    updated = refine_endpoint(candidate.rule,input,output)
    if isnothing(updated)
        restrict_transition!(candidate,last(refs),signature,context)
        return :refuted
    end
    refined = updated !== candidate.rule
    if refined
        candidate.rule = updated
        candidate.version = endpoint_version(updated,key)
        append!(candidate.witnesses,refs)
        unique!(candidate.witnesses)
    end
    get!(candidate.observed,signature,last(refs))
    get!(candidate.confirmed_contexts,(signature,context),last(refs))
    if created || refined
        push!(learned,(;key,candidate.version,trigger,origin,rule=candidate.rule,reads=copy(candidate.witnesses)))
    end
    return :compatible
end

function observe_transitions!(memory,prev,next,event,before_ref,proposal,groups,after_groups;context=relation_context(prev))
    trials = isnothing(proposal) ? () : get(proposal,:transitions,())
    checks,learned = NamedTuple[],NamedTuple[]
    left,right = last(prev.frames),last(next.frames)
    if prev.levels_completed != next.levels_completed || next.state != "NOT_FINISHED" ||
            size(left) != size(right) || next.action["id"] == 0
        for trial in trials
            push!(checks,(;trial.key,trial.version,status=:unresolved,actual=nothing))
        end
        return (;checks,learned)
    end
    changed = left != right
    isempty(trials) && !changed && return (;checks,learned)
    before = EndpointView(left,isnothing(groups) ? public_components(left) : groups)
    binding = transition_binding(next.action,before.groups)
    isnothing(binding) && return (;checks,learned)
    after = changed ? EndpointView(right,isnothing(after_groups) ? public_components(right) : after_groups) : before
    trigger = (prev.levels_completed,next.action["id"],binding.profile)
    measured = Set{String}()
    for trial in trials
        candidate = memory.candidates[trial.key]
        push!(candidate.checked,trial.signature)
        result = endpoint_agreement(candidate.rule,trial.expected,before,after)
        status = result.status
        if status == :refuted
            restrict_transition!(candidate,event,trial.signature,context)
        else
            # Unchanged displays also constrain a permutation. Check even the
            # slots whose individual colors could not be forecast at dispatch.
            input = endpoint_input(candidate.rule,before,binding.origin)
            output = endpoint_input(candidate.rule,after,binding.origin)
            if isnothing(output)
                restrict_transition!(candidate,event,trial.signature,context)
                status = :refuted
            else
                fit = register_transition!(candidate,trial.key,trigger,binding.origin,input,output,
                    context,[before_ref,event],learned)
                fit == :refuted && (status = :refuted)
            end
            push!(measured,trial.key)
        end
        status == :established && (candidate.supported = true)
        push!(checks,(;trial.key,trial.version,status,result.actual,query_status=result.status))
    end
    changed || return (;checks,learned)
    for example in endpoint_examples(before,after,binding.origin)
        key = semantic_hash([trigger,example.identity])
        key in measured && continue
        created = !haskey(memory.candidates,key)
        candidate = get!(memory.candidates,key) do
            push!(get!(Vector{String},memory.triggers,trigger),key)
            push!(get!(Set{PublicActionKey},memory.actions,prev.levels_completed),action_key(next.action))
            TransitionCandidate(example.rule,key,[before_ref,event],Dict(),Dict(),Dict(),Set(),false,Set(),false)
        end
        register_transition!(candidate,key,trigger,binding.origin,example.input,example.output,
            context,[before_ref,event],learned;created)
    end
    return (;checks,learned)
end
