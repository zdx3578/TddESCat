function sequence_observation_key(obs)
    return semantic_hash([obs.levels_completed,obs.available_actions,JSON.json(last(obs.frames))])
end

function confirmed_segments(events; close_revisits=false)
    segments = Vector{Tuple}[]
    pending = Tuple[]
    boundaries = Dict{String,Any}[]
    previous = nothing
    seen = Dict{String,Int}()
    for current in events
        ref = current.event["event_id"]
        action = current.observation.action["id"]
        adjacent = !isnothing(previous) && current.event["before_ref"] == previous.event["event_id"] &&
            current.observation.guid == previous.observation.guid &&
            current.event["sequence"] == previous.event["sequence"] + 1
        if action == 0 || !adjacent
            isempty(pending) || push!(segments,pending)
            pending = Tuple[]
            empty!(seen)
            push!(boundaries,Dict("event_ref"=>ref,"reason"=>action == 0 ? "reset" : "missing_predecessor"))
        else
            a,b = previous.observation,current.observation
            if close_revisits && isempty(pending)
                seen[sequence_observation_key(a)] = 0
            end
            push!(pending,(previous,current))
            reason = b.levels_completed != a.levels_completed ? "level_changed" :
                b.state in ("WIN","GAME_OVER") ? "terminal" :
                a.available_actions != b.available_actions ? "action_domain_changed" : nothing
            if !isnothing(reason)
                push!(segments,pending)
                pending = Tuple[]
                empty!(seen)
                push!(boundaries,Dict("event_ref"=>ref,"reason"=>reason))
            elseif close_revisits
                key = sequence_observation_key(b)
                start = get!(seen,key,length(pending))
                if length(pending)-start >= 2
                    start == 0 || push!(segments,pending[1:start])
                    push!(segments,pending[start+1:end])
                    pending = Tuple[]
                    empty!(seen)
                    push!(boundaries,Dict("event_ref"=>ref,"reason"=>"observed_revisit"))
                end
            end
        end
        previous = current
    end
    isempty(pending) || push!(segments,pending)
    return (; segments,boundaries,pending)
end

function compile_evidence_sequences(directory, destination)
    locations = isdir(joinpath(directory,"commands")) ? [directory] :
        [path for path in readdir(directory;join=true) if isdir(joinpath(path,"commands"))]
    isempty(locations) && error("No confirmed evidence directories for sequence compilation")
    episodes = [recover_run(RunStore(path);read_only=true) for path in locations]
    return persist_sequence_corpus(episodes,destination)
end

function persist_sequence_corpus(episodes,destination; corpus=compile_sequence_corpus(episodes))
    sources, context = describe_learning_context(corpus.signature,[],corpus.programs,corpus.origins,corpus.slots;
        intent="program",consumer="sequence-corpus",obligation_refs=String[])
    records = [record for episode in episodes for record in episode if record.observation.action["id"] != 0]
    qualified = Set(ref for scope in corpus.scopes for ref in scope["events"])
    unresolved = Set(item["event_ref"] for item in corpus.obligations)
    allunique(record.event["event_id"] for record in records) || error("Repeated source event across sequence episodes")
    for record in records
        ref = record.event["event_id"]
        ref in qualified || ref in unresolved || push!(corpus.obligations,Dict("event_ref"=>ref,
            "reason"=>"missing_verified_predecessor"))
    end
    artifact = merge(corpus,(;origins=sources,semantic_context=context))
    atomic_json(destination,artifact)
    return (; episode_count=length(episodes),confirmed_actions=length(records),
        approved_program_actions=corpus.confirmed_program_actions,programs=length(corpus.programs),
        pending_actions=length(setdiff(Set(record.event["event_id"] for record in records),qualified)))
end

program_sort!(signature, before, after) = semantic_sort!(signature,"prog",
    Dict("kind"=>"program","version"=>"program-ports-v1","before"=>before,"after"=>after))

function add_sequence_slot!(slots,positions,sort,phase,offset,port=0)
    index = get!(positions,(offset,sort,port)) do
        index = length(slots)
        push!(slots,Dict("index"=>index,"sort"=>sort,"time_role"=>phase,"role_constraints"=>[]))
        index
    end
    return Slot(index)
end

function relative_click(xy,shape)
    offset = Tuple(xy) .- anchor(shape)
    unit = support_grid(shape).unit
    divisor = gcd(unit,offset...)
    return (;offset=div.(offset,divisor),denominator=div(unit,divisor))
end

click_descriptor(binding) = Dict("kind"=>"ClickBinding",
    "layout"=>Dict("view"=>"target-support-grid","denominator"=>binding.denominator))

function step_effect_contract(family,values,after)
    descriptor = Dict{String,Any}("family"=>string(family),
        "before_sort"=>effect_sort(family,false),"after_sort"=>effect_sort(family,true))
    if family == :selection
        binding = relative_click(values,after)
        descriptor["click"] = click_descriptor(binding)
        values = collect(binding.offset)
    elseif family == :measurement
        descriptor["measurement"] = meter_contract()
    elseif family ∉ (:translation,:pigment,:count)
        error("No typed program port for " * string(family))
    end
    sort = family == :pigment ? "Color" : "Integer"
    return (;descriptor,sorts=fill(sort,length(values)),args=[Literal(sort,value) for value in values])
end

function measured_sequence_step!(signature,slots,positions,output,action,offset,ports)
    contracts = [step_effect_contract(effect.family,effect.values,effect.after) for effect in output.effects]
    layout = Dict("encoding"=>"bound-effects-v1","input_ports"=>ports,"output_ports"=>ports,
        "effects"=>[item.descriptor for item in contracts])
    role_slots = [(add_sequence_slot!(slots,positions,effect_sort(effect.family,false),"before",offset,i).index,
        add_sequence_slot!(slots,positions,effect_sort(effect.family,true),"after",offset,i).index)
        for (i,effect) in enumerate(output.effects)]
    sort = program_sort!(signature,ports,ports)
    parameters = reduce(vcat,(item.sorts for item in contracts);init=String[])
    op = semantic_operator!(signature,["Integer";parameters],sort,
        Dict("kind"=>"Step","layout"=>layout);version="sequence-operators-v2")
    args = reduce(vcat,(item.args for item in contracts);init=Literal[])
    return (;term=Call(op,Literal("Integer",action["id"]),args...),sort,output,
        input_ports=ports,output_ports=ports,role_slots,first_step=offset,last_step=offset)
end

function sequence_step!(signature, slots, positions, output, action, offset)
    ports = [string(effect.family) for effect in output.effects]
    if :measurement in (effect.family for effect in output.effects)
        return measured_sequence_step!(signature,slots,positions,output,action,offset,ports)
    end
    before = add_sequence_slot!(slots,positions,"SceneBefore","before",offset)
    after = add_sequence_slot!(slots,positions,"SceneAfter","after",offset)
    pre = relation_atom!(signature,"step-inputs",[(effect_sort(effect.family,false),"before")
        for effect in output.effects];slot=before.index)
    post = relation_atom!(signature,"step-results",[(effect_sort(effect.family,true),"after")
        for effect in output.effects];
        phase="after",slot=after.index)
    action_term = Literal("Integer",action["id"])
    effects = ConceptTerm[]
    role_slots = Tuple{Int,Int}[]
    for (i,effect) in enumerate(output.effects)
        input = add_sequence_slot!(slots,positions,effect_sort(effect.family,false),"before",offset,i)
        result = add_sequence_slot!(slots,positions,effect_sort(effect.family,true),"after",offset,i)
        push!(role_slots,(input.index,result.index))
        term = if effect.family == :selection
            binding = relative_click(effect.values,effect.after)
            op = semantic_operator!(signature,["RoleBefore","RoleAfter","Integer","Integer"],"Relation",
                click_descriptor(binding);version="sequence-operators-v1")
            Call(op,input,result,(Literal("Integer",d) for d in binding.offset)...)
        else
            effect_program(effect,input,result)
        end
        push!(effects,term)
    end
    sort = program_sort!(signature,ports,ports)
    layout = Dict("input_ports"=>ports,"output_ports"=>ports,"click_binding"=>
        action["id"] == 6 ? "target-support-grid" : nothing)
    op = semantic_operator!(signature,["Integer",pre.sort,"Relation",post.sort],sort,
        Dict("kind"=>"Step","layout"=>layout);version="sequence-operators-v1")
    return (; term=Call(op,action_term,pre.term,compose_effects(effects),post.term),sort, output,
        input_ports=ports,output_ports=ports,role_slots,first_step=offset,last_step=offset)
end

function shared_sequence_ports(left, right)
    pairs = Tuple{Int,Int}[]
    for (i,outgoing) in enumerate(left.effects), (j,incoming) in enumerate(right.effects)
        incoming.family == :selection && continue
        (outgoing.family == incoming.family || outgoing.family == :selection && incoming.family == :translation) || continue
        if outgoing.family == :measurement
            outgoing.context.instance == incoming.context.instance &&
                outgoing.context.after_value == incoming.context.before_value || continue
        else
            !isempty(outgoing.after) && outgoing.after == incoming.before || continue
        end
        push!(pairs,(i-1,j-1))
    end
    allunique(first.(pairs)) && allunique(last.(pairs)) || return nothing
    return pairs
end

function sequence_term!(signature, steps, shared, lo=firstindex(steps), hi=lastindex(steps))
    lo == hi && return steps[lo]
    middle = (lo + hi) ÷ 2
    left = sequence_term!(signature,steps,shared,lo,middle)
    right = sequence_term!(signature,steps,shared,middle+1,hi)
    bridges = shared[middle]
    sort = program_sort!(signature,left.input_ports,right.output_ports)
    op = semantic_operator!(signature,[left.sort,right.sort],sort,
        Dict("kind"=>"Seq","layout"=>Dict("shared"=>bridges,
            "left_output"=>left.output_ports,"right_input"=>right.input_ports));version="sequence-operators-v1")
    return (; term=Call(op,left.term,right.term),sort,input_ports=left.input_ports,
        output_ports=right.output_ports,first_step=left.first_step,last_step=right.last_step)
end

function sequence_evidence(before,after,result)
    return Dict("before_ref"=>before.event["event_id"],"event_ref"=>after.event["event_id"],
        "response_blob"=>after.event["response_blob"],"action"=>after.observation.action,
        "frame_count"=>length(after.observation.frames),"read_cutoff"=>after.event["sequence"],
        "before_frame"=>result.frame_before,"after_frame"=>result.frame_after,
        "level"=>before.observation.levels_completed,"action_domain"=>before.observation.available_actions,
        "effects"=>effect_record.(result.effects),"unexplained"=>result.residual,
        "public_changes"=>result.public_delta,"alternatives"=>result.alternatives)
end

function compile_sequence_corpus(episodes; observations=Dict{String,PublicEffects}(),
        close_revisits=false, include_open=true)
    partitions = []
    obligations = Dict{String,Any}[]
    boundaries = Dict{String,Any}[]
    values = Set(-64:64)
    replay_effects!(observations,episodes)
    for events in episodes
        chained = confirmed_segments(events;close_revisits)
        append!(boundaries,chained.boundaries)
        for segment in chained.segments
            ready = []
            for (before,after) in segment
                result = observations[after.event["event_id"]]
                raw = sequence_evidence(before,after,result)
                if !result.complete || !isempty(result.residual) || isempty(result.effects) ||
                        (result.action["id"] == 6 && !any(effect->effect.family == :selection,result.effects))
                    isempty(ready) || push!(partitions,ready)
                    ready = []
                    push!(obligations,merge(raw,Dict("reason"=>"step_effect_or_binding_unresolved")))
                    continue
                end
                for effect in result.effects, value in effect.values
                    push!(values,value)
                end
                if !isempty(ready) && isnothing(shared_sequence_ports(last(ready).result,result))
                    push!(partitions,ready)
                    ready = []
                    push!(obligations,merge(raw,Dict("reason"=>"ambiguous_shared_role")))
                end
                push!(ready,(; before,after,result,raw))
            end
            if (include_open || segment !== chained.pending) && !isempty(ready)
                push!(partitions,ready)
            end
        end
    end
    signature = typed_motion_signature(((i,0) for i in values))
    slot_context = Dict{String,Any}[]
    positions = Dict{Tuple{Int,String,Int},Int}()
    programs = String[]
    origins = Dict{String,Any}[]
    scopes = Dict{String,Any}[]
    independent = Set{String}()
    for rows in partitions
        length(rows) >= 2 || begin
            push!(obligations,merge(only(rows).raw,Dict("reason"=>"no_verified_neighbor")))
            continue
        end
        share = [shared_sequence_ports(rows[i].result,rows[i+1].result) for i in 1:length(rows)-1]
        steps = [sequence_step!(signature,slot_context,positions,row.result,row.after.observation.action,i)
            for (i,row) in enumerate(rows)]
        syntax = sequence_term!(signature,steps,share)
        text = render_term(syntax.term)
        index = length(programs)
        push!(programs,text)
        ids = String[row.raw["event_ref"] for row in rows]
        isdisjoint(independent,ids) || error("Overlapping sequence coverage in the same corpus")
        union!(independent,ids)
        scope_ref = "program-scope-" * semantic_hash(ids)
        function trace(term,path,lo,hi)
            row = rows[lo]
            push!(origins,Dict("program_index"=>index,"expression_path"=>path,
                "occurrence_id"=>"program-occ-" * join([index;path],"."),
                "event_ref"=>row.raw["event_ref"],"interpretation_ref"=>"sequence-evidence-v1",
                "slot_bindings_ref"=>scope_ref,"support_ref"=>row.raw["before_ref"]))
            term isa Call || return
            if lo == hi
                for (arg,child) in enumerate(term.children)
                    trace(child,[path;arg-1],lo,hi)
                end
            else
                middle = (lo + hi) ÷ 2
                trace(term.children[1],[path;0],lo,middle)
                trace(term.children[2],[path;1],middle+1,hi)
            end
        end
        trace(syntax.term,Int[],1,length(steps))
        push!(scopes,Dict("scope_ref"=>scope_ref,"events"=>ids,"steps"=>[row.raw for row in rows],
            "shared"=>share,"role_slots"=>[step.role_slots for step in steps],
            "program_sort"=>syntax.sort,"covered_interval"=>[1,length(steps)],
            "candidate_intervals"=>length(steps)*(length(steps)+1)÷2))
    end
    return (; signature,programs,origins,slots=slot_context,scopes,obligations,boundaries,
        confirmed_program_actions=length(independent))
end
