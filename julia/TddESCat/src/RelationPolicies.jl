function policy_edge_input(fact,agenda,writer,consumer,id,gained)
    fact.kind == :available_action && return fact.usage == :dispatch_legality && fact.action == id && gained
    fact.kind == :role_support && fact.output_port > 0 && !isnothing(writer) &&
        get(agenda.producers,fact.producer,nothing) === writer || return false
    fact.input_port == 0 && return fact.usage in (:selected_role,:omission_contrast)
    isnothing(consumer) && return false
    return fact.usage == :observed_input || (fact.usage == :task_read &&
        get(agenda.producers,fact.tested_producer,nothing) === consumer)
end

function active_policy_outcomes(agenda)
    active = Set{Tuple{Int,Int,Int}}()
    for witness in agenda.outcome_relations
        comparisons = witness.comparisons
        for input in relation_inputs(agenda,witness.outcome)
            input.usage == :omission_contrast && input.comparison in comparisons &&
                (input.writer=>input.producer) in witness.steps || continue
            push!(active,(witness.outcome,input.writer,input.comparison))
        end
    end
    return active
end

# Each writer must have its own matched intervention at the very same reader.
# Ambiguous alternatives and historical experiments alone do not bind a port.
function policy_preparation_inputs(agenda,index,active)
    incoming = relation_inputs(agenda,index)
    count(f->f.usage==:omission_contrast,incoming) >= 2 || return NamedTuple[]
    row = agenda.samples[index]
    facts = filter(incoming) do f
        f.usage == :omission_contrast && f.comparison > 0 && f.output_port > 0 || return false
        row.advanced && return (index,f.writer,f.comparison) in active
        comparison = agenda.samples[f.comparison]
        visits = get(agenda.visits,(comparison.context,action_key(row.effects.action)),Int[])
        return !any(visits) do i
            i > index && same_relation_response(row,agenda.samples[i]) &&
                relation_history_key(agenda,comparison.context,agenda.samples[i].preceding) ==
                    relation_history_key(agenda,comparison.context,comparison.preceding)
        end
    end
    length(facts) >= 2 && allunique(f.writer for f in facts) && allunique(f.comparison for f in facts) ||
        return NamedTuple[]
    return sort!(facts;by=f->f.writer)
end

"""Build policy edges from confirmed transfers and still-readable preparation facts."""
function witnessed_relation_steps(agenda,entries)
    by_ref = Dict(entry.event["event_id"]=>entry.observation for entry in entries)
    by_sample = Dict(index=>key for (key,producer) in agenda.producers for index in producer.support
        if !scene_translation_unresolved(agenda.samples[index].effects))
    descriptors = Dict{Int,Any}()
    links = Dict{Tuple{Int,Int},NamedTuple}()
    active_outcomes = active_policy_outcomes(agenda)
    outcomes_after = Dict{Int,Vector{NamedTuple}}()
    for outcome in agenda.outcomes
        haskey(by_ref,outcome.event) || continue
        prior = agenda.samples[outcome.index].preceding
        prior == 0 && continue
        push!(get!(Vector{NamedTuple},outcomes_after,prior),outcome)
    end
    for (index,row) in enumerate(agenda.samples)
        row.state == "GAME_OVER" && continue
        i = row.preceding
        i == 0 && continue
        left = agenda.samples[i]
        enabled = row.effects.action["id"] in observed_action_gain(left)
        isempty(left.effects.residual) || enabled || continue
        earlier = get(by_sample,i,nothing)
        same_stage = !left.advanced && left.attempt == row.attempt && left.level == row.level
        same_stage || continue
        if row.advanced
            # The terminal result is public even when its local preparation is
            # unidentified. A confounded trial cannot turn adjacency into that input.
            index in agenda.uses.rebound_receipts && !enabled && continue
            isnothing(earlier) && !enabled && continue
            left.next_context == row.context || continue
            row.effects.action["id"] == 6 && isnothing(row.binding) && continue
            haskey(by_ref,relation_ref(row)) || continue
            descriptors[index] = policy_step(row,String[])
            descriptors[i] = policy_step(left,isnothing(earlier) ? String[] : agenda.producers[earlier].relations)
            links[(i,index)] = (;layout=Dict("shared"=>Tuple{Int,Int}[]),reads=String[])
            continue
        end
        gained = observed_action_gain(row)
        key = get(by_sample,index,nothing)
        isnothing(key) && isempty(gained) && continue
        sharing = isnothing(earlier) || isnothing(key) ? Tuple{Int,Int}[] :
            public_role_links(left.effects,row.effects)
        inferred_history = any(pair->first(pair) == index,get(agenda.delayed,left.context,[]))
        # A positive delayed-effect witness needs a contrasting unchanged trial.
        connected = inferred_history || enabled || !isempty(sharing) || row.dependency == relation_ref(left)
        connected || continue
        (isnothing(earlier) && !inferred_history && !enabled) && continue
        only_meter = all(effect->effect.family == :measurement,row.effects.effects) &&
            all(effect->effect.family == :measurement,left.effects.effects)
        only_meter && !enabled && isempty(gained) && continue
        descriptors[index] = policy_step(row,isnothing(key) ? String[] : agenda.producers[key].relations)
        descriptors[i] = policy_step(left,isnothing(earlier) ? [] : agenda.producers[earlier].relations)
        links[(i,index)] = (;layout=Dict("shared"=>sharing),reads=String[])
    end
    for (index,row) in enumerate(agenda.samples)
        row.state == "GAME_OVER" && continue
        groups = Dict{Int,Vector{NamedTuple}}()
        incoming = relation_inputs(agenda,index)
        adjacent_contrast = any(f->f.writer==row.preceding && f.usage==:omission_contrast &&
            (!row.advanced || (index,f.writer,f.comparison) in active_outcomes),incoming)
        for fact in incoming
            # A witnessed omission retains all observed role bindings at that edge.
            fact.writer < row.preceding || adjacent_contrast || continue
            row.advanced && fact.usage == :omission_contrast &&
                (index,fact.writer,fact.comparison) ∉ active_outcomes && continue
            push!(get!(Vector{NamedTuple},groups,fact.writer),fact)
        end
        consumer = get(by_sample,index,nothing)
        public_result = row.advanced || !isempty(observed_action_gain(row))
        isnothing(consumer) && !public_result && continue
        for (writer,facts) in groups
            left = agenda.samples[writer]
            producer = get(by_sample,writer,nothing)
            gained = row.effects.action["id"] in observed_action_gain(left)
            isnothing(producer) && !gained && continue
            left.attempt == row.attempt && left.level == row.level && !left.advanced || continue
            # The compact program would dispatch its next instruction here.
            prepared = get(by_ref,relation_ref(left),nothing)
            isnothing(prepared) && continue
            row.effects.action["id"] in prepared.available_actions || continue
            writer_model = get(agenda.producers,producer,nothing)
            consumer_model = get(agenda.producers,consumer,nothing)
            valid = filter(f->policy_edge_input(f,agenda,writer_model,consumer_model,row.effects.action["id"],gained),facts)
            isempty(valid) && continue
            previous = get(links,(writer,index),nothing)
            sharing = [(f.output_port,f.input_port) for f in valid if f.input_port > 0]
            isnothing(previous) || append!(sharing,previous.layout["shared"])
            sort!(unique!(sharing))
            ports = sort!(unique([(f.output_port,string(f.usage)) for f in valid
                if f.output_port > 0 && f.input_port == 0]))
            layout = Dict{String,Any}("shared"=>sharing)
            isempty(ports) || (layout["required_outputs"] = ports)
            reads = unique([ref for f in valid for ref in f.reads])
            links[(writer,index)] = (;layout,reads)
            descriptors[index] = policy_step(row,isnothing(consumer) ? String[] : agenda.producers[consumer].relations)
            descriptors[writer] = policy_step(left,isnothing(producer) ? String[] : agenda.producers[producer].relations)
        end
    end
    joint = Dict{Int,Vector{NamedTuple}}()
    for index in keys(descriptors)
        facts = policy_preparation_inputs(agenda,index,active_outcomes)
        isempty(facts) && continue
        joint[index] = facts
    end
    followers = Dict{Int,Vector{Int}}()
    for (source,target) in sort!(collect(keys(links)))
        haskey(joint,target) || push!(get!(Vector{Int},followers,source),target)
    end
    source_producer = Dict(i=>agenda.producers[key] for (i,key) in by_sample)
    return (;descriptors,links,joint,followers,by_ref,outcomes_after,source_producer,active_outcomes)
end

function public_role_links(previous,current)
    return [(i,j) for (i,left) in enumerate(previous.effects) for (j,right) in enumerate(current.effects)
        if left.family ∉ (:measurement,:count) && right.family ∉ (:measurement,:count) &&
            left.after == right.before]
end

function policy_step(row,relations)
    role = isnothing(row.binding) ? nothing : row.binding.appearance
    descriptor = Dict{String,Any}("id"=>row.effects.action["id"],"role"=>role,
        "relations"=>relations,"wait"=>row.unchanged)
    row.advanced && (descriptor["public_outcome"] = "advancement")
    if !row.advanced && isempty(relations)
        granted = observed_action_gain(row)
        isempty(granted) || (descriptor["public_available"] = granted)
    end
    return descriptor
end

policy_step_key(step) = semantic_hash(step)

function source_policy_episodes(agenda,trace)
    families = Dict{String,Vector{Vector{Int}}}()
    descriptors = Dict(i=>policy_step_key(step) for (i,step) in trace.descriptors)
    identify(rows) = semantic_hash([[descriptors[i] for i in rows],
        [trace.links[pair].layout for pair in zip(rows,rows[2:end])]])
    for (writer,reader) in keys(trace.links)
        hasproperty(trace,:joint) && haskey(trace.joint,reader) && continue
        rows = [writer,reader]
        push!(get!(Vector{Vector{Int}},families,identify(rows)),rows)
    end
    # Multiple paths through the same evidence are one occurrence. Earliest
    # finishes maximize the number of independently witnessed intervals.
    function distinct_occurrences(proposals)
        independent = Vector{Vector{Int}}()
        for rows in sort!(proposals;by=rows->(last(rows),rows))
            (isempty(independent) || last(last(independent)) < first(rows)) && push!(independent,rows)
        end
        return independent
    end
    map!(distinct_occurrences,values(families))
    replicated = filter(pair->length(last(pair)) >= 2,families)
    pending = collect(values(replicated))
    while !isempty(pending)
        current = pop!(pending)
        # Keep each extension with independent witnesses. Sharing a prefix
        # can expose more than one valid continuation.
        extended = Dict{String,Vector{Vector{Int}}}()
        for rows in current
            # A receipt can have many valid later readers. Every pair is already
            # a seed. Extend each observed occurrence at its first actual use
            # only; all subsets of one run are not additional demonstrations.
            readers = get(trace.followers,last(rows),Int[])
            isempty(readers) && continue
            tail = first(readers)
            any(i->agenda.samples[i].context == agenda.samples[tail].context,rows) && continue
            interval = [rows;tail]
            push!(get!(Vector{Vector{Int}},extended,identify(interval)),interval)
        end
        map!(distinct_occurrences,values(extended))
        choices = [rows for rows in values(extended) if length(rows) >= 2]
        if isempty(choices)
            length(first(current)) > 2 && (replicated[identify(first(current))] = current)
        else
            append!(pending,choices)
        end
    end
    return replicated
end

function repeated_policy_occurrences(followers,members)
    by_start = Dict(first(rows)=>rows for rows in members)
    used = Set{Int}()
    repeats = Vector{Vector{Int}}()
    for rows in sort(members;by=first)
        first(rows) in used && continue
        repetition = copy(rows)
        push!(used,first(rows))
        while true
            readers = get(followers,last(repetition),Int[])
            next = findfirst(i->haskey(by_start,i) && i ∉ used,readers)
            isnothing(next) && break
            i = readers[next]
            append!(repetition,by_start[i])
            push!(used,i)
        end
        length(repetition) > length(rows) && push!(repeats,repetition)
    end
    return repeats
end

function policy_features!(cache,trace,ref)
    return get!(cache,ref) do
        obs = trace.by_ref[ref]
        Set(semantic_hash(shape_template(shape)) for shape in public_components(last(obs.frames))
            if 4length(shape) <= length(last(obs.frames)))
    end
end

function witnessed_policy_ports(row)
    return Any[effect.family in (:translation,:pigment,:selection) && !isempty(effect.after) ?
        effect.after : nothing for effect in row.effects.effects]
end

function separating_feature(positive,negative)
    (isempty(positive) || isempty(negative)) && return nothing
    present = setdiff(reduce(intersect,positive),reduce(union,negative))
    absent = setdiff(reduce(intersect,negative),reduce(union,positive))
    !isempty(present) && return Dict("feature"=>minimum(present),"present"=>true)
    return isempty(absent) ? nothing : Dict("feature"=>minimum(absent),"present"=>false)
end

policy_expr(kind, args...; layout=Dict{String,Any}()) = Dict{String,Any}(
    "kind"=>kind,"layout"=>layout,"children"=>collect(args))

function sequence_policy(trace,members)
    first = policy_expr("RelationTask";layout=trace.descriptors[members[1]])
    for (source,index) in zip(members,members[2:end])
        second = policy_expr("RelationTask";layout=trace.descriptors[index])
        first = policy_expr("RelationSequence",first,second;layout=trace.links[(source,index)].layout)
    end
    return first
end

function joint_preparation_episodes(agenda,entries,trace,continuity)
    # Independently contrasted inputs form one conjunction at the reader. The
    # observed ordering of the preparatory actions asserts no dependency between them.
    episodes = NamedTuple[]
    joined = Dict{String,Vector{NamedTuple}}()
    for (reader,inputs) in trace.joint
        all(f->haskey(trace.links,(f.writer,reader)),inputs) || continue
        members = [[f.writer for f in inputs];reader]
        body = policy_expr("RelationTask";layout=trace.descriptors[first(members)])
        for position in 2:length(members)
            source,consumer = members[position-1],members[position]
            edge = get(trace.links,(source,consumer),nothing)
            layout = isnothing(edge) ? Dict{String,Any}("shared"=>[]) : copy(edge.layout)
            if consumer == reader
                layout["preparations"] = map(enumerate(inputs)) do (i,f)
                    original = trace.links[(f.writer,reader)].layout
                    selected = any(p->first(p)==f.output_port && last(p)=="selected_role",
                        get(original,"required_outputs",[]))
                    shared = [j for (out,j) in original["shared"] if out==f.output_port]
                    (length(inputs)-i+1,f.output_port,selected,shared)
                end
                # All these roles, including the last writer, have explicit slots.
                delete!(layout,"required_outputs")
            end
            task = policy_expr("RelationTask";layout=trace.descriptors[consumer])
            body = policy_expr("RelationSequence",body,task;layout)
        end
        reads = unique([ref for input in inputs for ref in input.reads])
        evidence_only = setdiff(vcat(collect(first(members):reader),[f.comparison for f in inputs]),members)
        events = unique([reduce(vcat,relation_refs.(agenda.samples[members]));reads;
            relation_ref.(agenda.samples[evidence_only])])
        episode = (;body,members,structure="sequence",events,evidence_only,public_outcomes=NamedTuple[],
            preparations=[(f.writer,f.comparison) for f in inputs])
        verify_relation_episode(body,episode,agenda,entries;by_ref=trace.by_ref,
            source_producer=trace.source_producer,active_outcomes=trace.active_outcomes,continuity) || continue
        push!(get!(Vector{NamedTuple},joined,semantic_hash(body)),episode)
    end
    for occurrences in values(joined)
        last_reader = 0
        independent = NamedTuple[]
        for episode in sort!(occurrences;by=e->last(e.members))
            first(episode.members) > last_reader || continue
            push!(independent,episode)
            last_reader = last(episode.members)
        end
        length(independent) >= 2 && append!(episodes,independent)
    end
    return episodes
end

function policy_episodes(agenda,entries;solver=nothing,snapshot="trajectory")
    trace = witnessed_relation_steps(agenda,entries)
    families = source_policy_episodes(agenda,trace)
    isempty(families) && isempty(trace.joint) && return NamedTuple[]
    episodes = NamedTuple[]
    features = Dict{String,Set{String}}()
    continuity = Dict{Tuple{Int,Int},Bool}()
    atom_features = Dict{String,Dict{String,NamedTuple}}()
    role_features = Dict{Tuple{String,Int},Any}()
    function scene(ref)
        isnothing(solver) && return policy_features!(features,trace,ref)
        return get!(() -> policy_scene_atoms(trace.by_ref[ref]),atom_features,ref)
    end
    before(index) = scene(agenda.samples[index].effects.before_id)
    after(index) = scene(relation_ref(agenda.samples[index]))
    function after_preparation(previous)
        ref = relation_ref(agenda.samples[previous])
        if isnothing(solver) || isempty(trace.descriptors[previous]["relations"])
            return scene(ref)
        end
        return get!(role_features,(ref,previous)) do
            policy_role_context(trace.by_ref[ref],witnessed_policy_ports(agenda.samples[previous]);suggest=true)
        end
    end
    distinguish(a,b) = isnothing(solver) ? separating_feature(a,b) : typed_policy_guard(solver,a,b,snapshot)
    function emit(body,members,structure)
        rows = agenda.samples[members]
        outcomes = get(trace.outcomes_after,last(members),NamedTuple[])
        evidence_only = Int[]
        reads = String[]
        for (source,consumer) in zip(members,members[2:end])
            edge = get(trace.links,(source,consumer),nothing)
            isnothing(edge) && continue
            append!(reads,edge.reads)
            append!(evidence_only,source+1:consumer-1)
            append!(evidence_only,(f.comparison for f in relation_inputs(agenda,consumer)
                if f.writer == source && f.usage == :omission_contrast))
        end
        unique!(evidence_only)
        events = unique([reduce(vcat,relation_refs.(rows));reads;
            relation_ref.(agenda.samples[evidence_only]);[outcome.event for outcome in outcomes]])
        episode = (;body,members,structure,events,evidence_only,public_outcomes=outcomes)
        # Omitting observed intervening commands makes a testable candidate.
        # Reject one whose control flow already disagrees at the earlier observation.
        isempty(evidence_only) || verify_relation_episode(body,episode,agenda,entries;
            by_ref=trace.by_ref,source_producer=trace.source_producer,active_outcomes=trace.active_outcomes,continuity) || return
        push!(episodes,episode)
    end
    append!(episodes,joint_preparation_episodes(agenda,entries,trace,continuity))
    ordered = sort!(collect(families);by=first)
    for (_,members) in ordered
        representative = first(members)
        body = sequence_policy(trace,representative)
        for indices in members
            emit(body,indices,"sequence")
        end
        repeats = repeated_policy_occurrences(trace.followers,members)
        isempty(repeats) && continue
        width = length(representative)
        # Check the same carried ports at every iteration boundary and evaluate
        # the guard on the observation immediately after the compact body.
        carries = Dict{String,Vector{Vector{Int}}}()
        carry(rows,i) = trace.links[(rows[i-1],rows[i])].layout
        for rows in repeats
            boundaries = width+1:width:length(rows)
            layout = carry(rows,first(boundaries))
            all(i->carry(rows,i)==layout,boundaries) || continue
            push!(get!(Vector{Vector{Int}},carries,semantic_hash(layout)),rows)
        end
        for paths in values(carries)
            guard = distinguish([i == 1 ? before(first(rows)) : after(rows[i-1])
                for rows in paths for i in 1:width:length(rows)], [after(last(rows)) for rows in paths])
            isnothing(guard) && continue
            layout = Dict{String,Any}("observed_bound"=>maximum(length(rows) ÷ width for rows in paths))
            carried = carry(first(paths),width+1)
            isempty(carried["shared"]) && !haskey(carried,"required_outputs") || (layout["carry"]=carried)
            repeat = policy_expr("RelationRepeat",policy_expr("RelationTest";layout=guard),body;layout)
            for indices in paths
                emit(repeat,indices,"repeat")
            end
        end
    end
    # Compare witnessed continuations after a common prefix. An entry guard
    # can select a program before its first step when the entry separates it.
    for i in eachindex(ordered), j in i+1:length(ordered)
        left,right = last(ordered[i]),last(ordered[j])
        a,b = first(left),first(right)
        trace.descriptors[first(a)] == trace.descriptors[first(b)] || continue
        offset = findfirst(2:min(length(a),length(b))) do position
            trace.descriptors[a[position]] != trace.descriptors[b[position]] ||
                trace.links[(a[position-1],a[position])].layout != trace.links[(b[position-1],b[position])].layout
        end
        isnothing(offset) && continue
        position = offset + 1
        entry_guard = if position == 2
            distinguish([before(first(rows)) for rows in left],[before(first(rows)) for rows in right])
        end
        branch = if !isnothing(entry_guard)
            policy_expr("RelationBranch",policy_expr("RelationTest";layout=entry_guard),
                sequence_policy(trace,a),sequence_policy(trace,b))
        else
            guard = distinguish([after_preparation(rows[position-1]) for rows in left],
                [after_preparation(rows[position-1]) for rows in right])
            isnothing(guard) && continue
            prefix = sequence_policy(trace,a[1:position-1])
            layouts = [trace.links[(rows[position-1],rows[position])].layout for rows in (a,b)]
            arms = Dict{String,Any}("shared_by_branch"=>[layout["shared"] for layout in layouts])
            if any(layout->haskey(layout,"required_outputs"),layouts)
                arms["outputs_by_branch"] = [get(layout,"required_outputs",[]) for layout in layouts]
            end
            suffix = policy_expr("RelationBranch",policy_expr("RelationTest";layout=guard),
                sequence_policy(trace,a[position:end]),sequence_policy(trace,b[position:end]);
                layout=arms)
            policy_expr("RelationSequence",prefix,suffix;layout=Dict("shared"=>[]))
        end
        for rows in [left;right]
            emit(branch,rows,"branch")
        end
    end
    return episodes
end

function policy_corpus(agenda::RelationAgenda,entries;published=Set{String}(),solver=nothing,snapshot="trajectory")
    episodes = policy_episodes(agenda,entries;solver,snapshot)
    filter!(episode->semantic_hash(episode.body) ∉ published,episodes)
    isempty(episodes) && return nothing
    signature = typed_motion_signature(Pixel[])
    append!(signature["sorts"],[Dict{String,Any}("id"=>name) for name in ("SceneBefore","Boolean")])
    sort = semantic_sort!(signature,"prog",Dict("kind"=>"program","version"=>"public-relation-policy-v1",
        "input_ports"=>["SceneBefore"],"output_ports"=>["PublicRelations"]))
    function encode(node,slot)
        kind = node["kind"]
        children = node["children"]
        input_types = if kind in ("RelationTask","RelationTest")
            ["SceneBefore"]
        elseif kind == "RelationBranch"
            ["Boolean",sort,sort]
        elseif kind == "RelationRepeat"
            ["Boolean",sort]
        else
            [sort,sort]
        end
        op = semantic_operator!(signature,input_types,kind == "RelationTest" ? "Boolean" : sort,
            Dict("kind"=>kind,"layout"=>node["layout"]))
        return Call(op,isempty(children) ? ConceptTerm[slot] : ConceptTerm[encode(child,slot) for child in children])
    end
    programs = String[]
    slots = Dict{String,Any}[]
    origins = Dict{String,Any}[]
    for (index,episode) in enumerate(episodes)
        push!(slots,Dict("index"=>index-1,"sort"=>"SceneBefore","time_role"=>"before","role_constraints"=>[]))
        term = render_term(encode(episode.body,Slot(index-1)))
        push!(programs,term)
        ref = relation_ref(agenda.samples[first(episode.members)])
        scope = "relation-episode-" * string(index)
        registry,_ = registry_from(signature,[])
        walk_wire(decode_program(term,registry)) do _,path
            push!(origins,Dict("program_index"=>index-1,"expression_path"=>path,
                "occurrence_id"=>"relation-policy-" * join([index;path],"."),
                "event_ref"=>ref,"interpretation_ref"=>episode.structure,
                "slot_bindings_ref"=>scope,"support_ref"=>scope,"source_kind"=>"observed"))
        end
    end
    events = sort!(unique([ref for episode in episodes for ref in episode.events]))
    return (;signature,slots,programs,origins,episodes,events,model="public-relation-policy-v1")
end

function analyze_relation_policy(node,registry,slot)
    get(node,"kind",nothing) == "Call" || return nothing
    description = get(registry[node["operator"]],"descriptor",nothing)
    isnothing(description) && return nothing
    kind = description["kind"]
    layout = get(description,"layout",Dict())
    args = node["args"]
    if kind in ("RelationTask","RelationTest")
        length(args) == 1 && only(args) == slot || return nothing
        return policy_expr(kind;layout)
    end
    arity = kind == "RelationBranch" ? 3 :
        kind in ("RelationSequence","RelationRepeat") ? 2 : 0
    arity > 0 && length(args) == arity || return nothing
    children = [analyze_relation_policy(child,registry,slot) for child in args]
    any(isnothing,children) && return nothing
    ks = [child["kind"] for child in children]
    if kind in ("RelationBranch","RelationRepeat")
        first(ks) == "RelationTest" && all(!=("RelationTest"),ks[2:end]) || return nothing
    else
        all(!=("RelationTest"),ks) || return nothing
    end
    return policy_expr(kind,children...;layout)
end

function relation_policy_slot(node)
    get(node,"kind",nothing) == "Slot" && return node
    get(node,"kind",nothing) == "Call" || return nothing
    for child in node["args"]
        slot = relation_policy_slot(child)
        isnothing(slot) || return slot
    end
    return nothing
end

function relation_predicate(layout,scene,outputs=())
    haskey(layout,"guard_schema") && return evaluate_policy_guard(layout,scene,outputs)
    frame = scene isa PublicObservation ? last(scene.frames) : scene
    present = any(shape->4length(shape) <= length(frame) &&
        semantic_hash(shape_template(shape)) == layout["feature"],public_components(frame))
    return present == layout["present"]
end

mutable struct RelationPolicyCursor
    policy::LearnedPolicy
    pending::Vector{NamedTuple}
    observed::Vector{String}
    outputs::Vector{Any}
    output_history::Vector{Vector{Any}}
    max_lookback::Int
    loop_states::Set{Tuple{String,String}}
    purpose::Union{Nothing,NamedTuple}
end

function preparation_lookback(node)
    here = maximum((first(slot) for slot in get(node["layout"],"preparations",[]));init=0)
    return maximum(preparation_lookback,node["children"];init=here)
end

function save_policy_outputs!(cursor,outputs)
    cursor.outputs = outputs
    cursor.max_lookback == 0 && return
    push!(cursor.output_history,cursor.outputs)
    length(cursor.output_history) > cursor.max_lookback && popfirst!(cursor.output_history)
end

RelationPolicyCursor(policy) = RelationPolicyCursor(policy,
    [(node=policy.body["tree"],iteration=0,shared=Any[])],String[],Any[],Vector{Any}[],
    get(()->preparation_lookback(policy.body["tree"]),policy.body,"preparation_lookback"),Set{Tuple{String,String}}(),nothing)

function peek_relation_instruction(cursor,scene)
    candidate = RelationPolicyCursor(cursor.policy,copy(cursor.pending),copy(cursor.observed),
        copy(cursor.outputs),copy(cursor.output_history),cursor.max_lookback,copy(cursor.loop_states),cursor.purpose)
    result = next_relation_instruction!(candidate,scene)
    return merge(result,(;cursor=candidate))
end

function next_relation_instruction!(cursor,scene)
    branches = NamedTuple[]
    while !isempty(cursor.pending)
        instruction = pop!(cursor.pending)
        node = instruction.node
        kind,layout,children = node["kind"],node["layout"],node["children"]
        if kind == "RelationTask"
            return (;instruction,branches,status=:task)
        elseif kind == "RelationSequence"
            push!(cursor.pending,(node=children[2],iteration=0,shared=layout["shared"],
                required_outputs=get(layout,"required_outputs",[]),preparations=get(layout,"preparations",[])))
            push!(cursor.pending,merge(instruction,(node=children[1],iteration=0)))
        elseif kind == "RelationBranch"
            yes = relation_predicate(first(children)["layout"],scene,cursor.outputs)
            isnothing(yes) && return (;instruction=nothing,branches,status=:unknown_guard)
            push!(branches,(control=:branch,outcome=yes))
            shared = haskey(layout,"shared_by_branch") ?
                layout["shared_by_branch"][yes ? 1 : 2] : instruction.shared
            outputs = haskey(layout,"outputs_by_branch") ?
                layout["outputs_by_branch"][yes ? 1 : 2] : get(instruction,:required_outputs,[])
            push!(cursor.pending,merge(instruction,(node=children[yes ? 2 : 3],iteration=0,shared,required_outputs=outputs)))
        elseif kind == "RelationRepeat"
            yes = relation_predicate(first(children)["layout"],scene,cursor.outputs)
            isnothing(yes) && return (;instruction=nothing,branches,status=:unknown_guard)
            push!(branches,(control=:repeat,outcome=yes,iteration=instruction.iteration))
            yes || continue
            context = scene isa PublicObservation ? relation_context(scene) : content_hash(vec(scene))
            guard_scope = (semantic_hash(node),context)
            guard_scope in cursor.loop_states &&
                return (;instruction=nothing,branches,status=:unresolved_repeat_progress)
            push!(cursor.loop_states,guard_scope)
            push!(cursor.pending,merge(instruction,(iteration=instruction.iteration+1,)))
            if instruction.iteration > 0 && haskey(layout,"carry")
                carried = layout["carry"]
                push!(cursor.pending,(node=children[2],iteration=0,shared=carried["shared"],
                    required_outputs=get(carried,"required_outputs",[])))
            else
                push!(cursor.pending,merge(instruction,(node=children[2],iteration=0)))
            end
        end
    end
    return (;instruction=nothing,branches,status=:stopped)
end

function required_policy_outputs(instruction,outputs,groups,action)
    return all(get(instruction,:required_outputs,[])) do (port,usage)
        checkbounds(Bool,outputs,port) || return false
        support = outputs[port]
        support isa MotionShape && !isempty(support) || return false
        support in groups || return false
        usage == "omission_contrast" && return true
        usage == "selected_role" && action["id"] == 6 || return false
        return point_component(groups,action_key(action)[2:3]) == support
    end
end

function policy_edge_continues(agenda,writer,index,facts,by_ref)
    row = agenda.samples[index]
    ports = unique([f.output_port for f in facts if f.kind == :role_support])
    outputs = witnessed_policy_ports(agenda.samples[writer])
    all(port -> checkbounds(Bool,outputs,port) && outputs[port] isa MotionShape,ports) || return false
    permission = any(f->f.kind==:available_action,facts)
    at = row.preceding
    prev_ref = row.effects.before_id
    while at != writer
        0 < at < index || return false
        skipped = agenda.samples[at]
        ref = relation_ref(skipped)
        skipped.attempt == row.attempt && skipped.level == row.level && ref == prev_ref || return false
        obs = get(by_ref,ref,nothing)
        isnothing(obs) && return false
        obs.state == "NOT_FINISHED" && !skipped.advanced || return false
        permission && row.effects.action["id"] ∉ obs.available_actions && return false
        if !isempty(ports)
            for frame in obs.frames
                groups = public_components(frame)
                all(port -> outputs[port] in groups,ports) || return false
            end
        end
        prev_ref = skipped.effects.before_id
        at = skipped.preceding
    end
    return relation_ref(agenda.samples[writer])==prev_ref
end

function verify_relation_episode(tree,episode,agenda,entries;
        by_ref=Dict(entry.event["event_id"]=>entry.observation for entry in entries),
        source_producer=Dict(i=>p for p in values(agenda.producers) for i in p.support),
        continuity=Dict{Tuple{Int,Int},Bool}(),active_outcomes=active_policy_outcomes(agenda))
    cursor = RelationPolicyCursor(LearnedPolicy("","",0,"",Dict("tree"=>tree),String[],""))
    for outcome in get(episode,:public_outcomes,NamedTuple[])
        sample = agenda.samples[outcome.index]
        after = get(by_ref,outcome.event,nothing)
        isnothing(after) && return false
        sample.preceding == last(episode.members) && relation_ref(sample) == outcome.event || return false
        after.state == sample.state && outcome in agenda.outcomes || return false
    end
    earlier = nothing
    prior_index = 0
    for (position,index) in enumerate(episode.members)
        row = agenda.samples[index]
        before = by_ref[row.effects.before_id]
        skipped = prior_index != 0 && row.preceding != prior_index
        prepared = skipped ? by_ref[relation_ref(earlier)] : before
        next = next_relation_instruction!(cursor,prepared)
        next.status == :task || return false
        producer = get(source_producer,index,nothing)
        descriptor = policy_step(row,isnothing(producer) ? [] : producer.relations)
        canonical_bytes(next.instruction.node["layout"]) == canonical_bytes(descriptor) || return false
        if haskey(descriptor,"public_outcome")
            before = by_ref[row.effects.before_id]
            after = by_ref[relation_ref(row)]
            after.levels_completed > before.levels_completed || return false
        end
        if !isempty(get(next.instruction,:required_outputs,[]))
            groups = public_components(last(prepared.frames))
            required_policy_outputs(next.instruction,cursor.outputs,groups,row.effects.action) || return false
        end
        inputs = policy_preparation_inputs(agenda,index,active_outcomes)
        slots = get(next.instruction,:preparations,[])
        if !isempty(slots) || !isempty(inputs)
            length(slots) == length(inputs) > 1 || return false
            groups = public_components(last(prepared.frames))
            for ((back,port,selected,shared),input) in zip(slots,inputs)
                0 < back < position && episode.members[position-back]==input.writer &&
                    port == input.output_port || return false
                outputs = cursor.output_history[end-back+1]
                checkbounds(Bool,outputs,port) && outputs[port] in groups || return false
                links = filter(f->f.writer==input.writer && f.output_port==port,relation_inputs(agenda,index))
                selected == any(f->f.usage==:selected_role,links) || return false
                if selected
                    row.effects.action["id"]==6 && point_component(groups,action_key(row.effects.action)[2:3])==outputs[port] || return false
                end
                valid = filter(f->policy_edge_input(f,agenda,get(source_producer,input.writer,nothing),producer,
                    row.effects.action["id"],false),links)
                shared == sort!(unique([f.input_port for f in valid if f.input_port > 0])) || return false
                all(j->j<=length(row.effects.effects) && outputs[port]==row.effects.effects[j].before,shared) || return false
                policy_edge_continues(agenda,input.writer,index,(input,),by_ref) || return false
            end
        end
        if skipped
            row.effects.action["id"] in prepared.available_actions || return false
            writer_model = get(source_producer,prior_index,nothing)
            id = row.effects.action["id"]
            gained = id in observed_action_gain(earlier)
            inputs = filter(relation_inputs(agenda,index)) do f
                f.writer == prior_index && (!row.advanced || f.usage != :omission_contrast ||
                    (index,prior_index,f.comparison) in active_outcomes) &&
                    policy_edge_input(f,agenda,writer_model,producer,id,gained)
            end
            # Two independently contrasted preparers need no edge to each other.
            # Rebind the next preparer on the earlier public observation instead.
            independent = isempty(inputs) && hasproperty(episode,:preparations) &&
                any(pair->first(pair)==index,episode.preparations) && !isnothing(producer)
            isempty(inputs) && !independent && return false
            intact = independent || get!(continuity,(prior_index,index)) do
                policy_edge_continues(agenda,prior_index,index,inputs,by_ref)
            end
            intact || return false
            shared = sort!(unique([(f.output_port,f.input_port) for f in inputs if f.input_port > 0]))
            canonical_bytes(shared) == canonical_bytes(next.instruction.shared) || return false
            required = sort!(unique([(f.output_port,string(f.usage)) for f in inputs
                if f.output_port > 0 && f.input_port==0]))
            isempty(slots) && canonical_bytes(required)!=canonical_bytes(get(next.instruction,:required_outputs,[])) && return false
            groups = public_components(last(prepared.frames))
            if !isnothing(producer)
                check = evaluate_joint_rule(producer.rule,last(prepared.frames),groups,enclosure_pairs(groups),
                    row.effects.action;relative_transfer=true)
                check.truth == proven || return false
                for (out,input) in shared
                    input <= length(check.fragments) && out <= length(cursor.outputs) || return false
                    cursor.outputs[out] == check.fragments[input].basis || return false
                end
            elseif row.effects.action["id"] == 6
                matches_outcome_binding(row,row.effects.action,groups) || return false
            end
        elseif !isempty(next.instruction.shared)
            isnothing(earlier) && return false
            canonical_bytes(next.instruction.shared) ==
                canonical_bytes(public_role_links(earlier.effects,row.effects)) || return false
        end
        save_policy_outputs!(cursor,isnothing(producer) ? Any[] : witnessed_policy_ports(row))
        earlier = row
        prior_index = index
    end
    return next_relation_instruction!(cursor,by_ref[relation_ref(earlier)]).status == :stopped
end

function trajectory_reads(corpus,agenda)
    indices = unique([index for episode in corpus.episodes for index in
        [episode.members; get(episode,:evidence_only,Int[]); [outcome.index for outcome in get(episode,:public_outcomes,NamedTuple[])]]])
    return [begin
        row = agenda.samples[index]
        scope = history_scope(agenda,row.context)
        (;event=relation_ref(row),context=row.context,action=action_key(row.effects.action),
            previous=previous_key(agenda,row.preceding),after=row.next_context,
            state=row.state,advanced=row.advanced,history_width=scope.width,history_receipts=scope.receipts,
            history=relation_history_key(agenda,row.context,row.preceding))
    end for index in indices]
end

function trajectory_counterexamples(reads,cutoff,agenda)
    conflicts = Set{String}()
    for read in reads, index in get(agenda.visits,(read.context,read.action),Int[])
        index > cutoff || continue
        row = agenda.samples[index]
        scope = RelationHistoryScope(get(read,:history_width,1),get(read,:history_receipts,false))
        same_history = hasproperty(read,:history) ?
            relation_history_key(agenda,row.context,row.preceding;scope) == read.history :
            previous_key(agenda,row.preceding) == read.previous
        same_history || continue
        (row.next_context,row.state,row.advanced) == (read.after,read.state,read.advanced) && continue
        push!(conflicts,relation_ref(row))
    end
    return sort!(collect(conflicts))
end

function policy_task_options(agenda,instruction,obs,decision;meters=(),test_precondition=false,preparers=())
    op = instruction.node["layout"]
    id = op["id"]
    id in obs.available_actions || return NamedTuple[]
    actions = [row.action for row in decision.ranked if row.action["id"] == id]
    context = relation_context(obs)
    condition_view = get(decision,:condition_view,nothing)
    options = NamedTuple[]
    for action in actions
        observed_failure(agenda,context,action_key(action),agenda.previous) && continue
        if id == 6
            point = action_key(action)[2:3]
            support = point_component(decision.groups,point)
            isnothing(support) && continue
            click_profile(support,point) == op["role"] || continue
        end
        tests = if op["wait"]
            NamedTuple[]
        else
            sought = op["relations"]
            allowed = reduce(intersect,(Set(get(agenda.by_relation,relation,String[])) for relation in sought))
            observed = prepare_relation_tests(agenda,context,obs,decision.groups,action;meters,condition_view)
            [test for test in observed if test.key in allowed && test.relations == sought &&
                (test.scope in (:bound,:replicated) || (test_precondition || test.key in preparers) && test.scope==:unverified &&
                    !unverified_competing_role(test)) &&
                all(other->other.expected == test.expected,observed)]
        end
        op["wait"] || !isempty(tests) || continue
        push!(options,(;action,tests))
    end
    return options
end

function bind_policy_availability(cursor,op,obs,decision,agenda)
    required = op["public_available"]
    all(in(obs.available_actions),required) && return nothing
    training = Set(cursor.policy.training)
    domain = Set(obs.available_actions)
    context = relation_context(obs)
    history = relation_history_key(agenda,context,agenda.previous)
    scene = op["id"] == 6 ? nothing : visible_role_multiset(decision.groups)
    for item in decision.ranked
        action = item.action
        key = action_key(action)
        first(key) == op["id"] && first(key) in domain || continue
        observed_failure(agenda,context,key,agenda.previous) && continue
        seen = get(agenda.visits,(context,key),Int[])
        disproven = any(seen) do index
            row = agenda.samples[index]
            row.state == "NOT_FINISHED" && !row.advanced &&
                relation_history_key(agenda,context,row.preceding) == history &&
                !all(in(observed_action_gain(row)),required)
        end
        disproven && continue
        for index in sort!(collect(keys(agenda.preparation_roles));rev=true)
            row = agenda.samples[index]
            relation_ref(row) in training && Set(row.available) == domain || continue
            all(in(observed_action_gain(row)),required) || continue
            matches_outcome_binding(row,action,decision.groups) || continue
            if row.context == context
                relation_history_key(agenda,context,row.preceding) == history || continue
            elseif !isnothing(scene)
                agenda.preparation_roles[index] == scene || continue
            end
            source = relation_ref(row)
            reads = unique([cursor.policy.training;cursor.policy.available_after;cursor.observed;relation_refs(row)])
            obligation = (;definition=cursor.policy.definition,wait=false,sought=String[],shared=[],
                public_available=required,source,source_index=index,
                scope=row.context == context ? :observed_instance : :hypothesis)
            return (;action,intent=:execute_relation_policy,tests=NamedTuple[],reads,obligation)
        end
    end
    return nothing
end

function witnessed_policy_availability(cursor,agenda,training,matches,action)
    for result in Iterators.reverse(agenda.outcomes)
        result.result in (:advancement,:win) && result.event in training || continue
        observed = agenda.samples[result.index]
        matches(observed,action) && !isempty(result.requirements) || continue
        live = frontier_prior(agenda,agenda.previous,length(result.requirements))
        length(live) == length(result.requirements) <= length(cursor.observed) || continue
        relation_ref.(agenda.samples[live]) == cursor.observed[end-length(live)+1:end] || continue
        matched = all(zip(live,result.requirements)) do (index,required)
            row,source = agenda.samples[index],agenda.samples[required.index]
            row.effects.action["id"] == source.effects.action["id"] &&
                Set(row.available) == Set(source.available) && required.action in observed_action_gain(row)
        end
        matched && return observed
    end
    return nothing
end

function bind_policy_outcome(cursor,op,obs,decision,agenda)
    op["public_outcome"] == "advancement" || return nothing
    op["id"] in obs.available_actions || return nothing
    previous = agenda.previous
    (previous == 0 || isempty(cursor.observed)) && return nothing
    prior = agenda.samples[previous]
    preparation = relation_ref(prior)
    context = relation_context(obs)
    last(cursor.observed) == preparation && prior.next_context == context || return nothing
    training = Set(cursor.policy.training)
    available = Set(obs.available_actions)
    history = relation_history_key(agenda,context,previous)
    matches(row,action) = (op["id"] != 6 || !isnothing(row.binding) && row.binding.appearance == op["role"]) &&
        matches_outcome_binding(row,action,decision.groups)
    for item in decision.ranked
        action = item.action
        action["id"] == op["id"] || continue
        key = action_key(action)
        visits = get(agenda.visits,(context,key),Int[])
        comparisons = String[]
        exact = filter(index->relation_history_key(agenda,context,agenda.samples[index].preceding) == history,visits)
        if cursor.max_lookback > 0 && any(i->!agenda.samples[i].advanced,exact)
            continue
        end
        if !isempty(exact) && cursor.max_lookback == 0
            all(index->agenda.samples[index].advanced,exact) || continue
            recorded = findlast(exact) do index
                row = agenda.samples[index]
                relation_ref(row) in training && matches(row,action)
            end
            isnothing(recorded) && continue
            scope, outcome, comparison = :observed_instance, agenda.samples[exact[recorded]], nothing
        else
            match = findlast(agenda.outcome_relations) do witness
                observed = agenda.samples[witness.outcome]
                relation_ref(observed) in training && Set(observed.available) == available &&
                    matches(observed,action) || return false
                cursor.max_lookback == 0 || length(witness.steps) == cursor.max_lookback &&
                    length(witness.comparisons) == cursor.max_lookback || return false
                live = frontier_prior(agenda,previous,length(witness.steps))
                length(live) == length(witness.steps) <= length(cursor.observed) || return false
                relation_ref.(agenda.samples[live]) == cursor.observed[end-length(live)+1:end] || return false
                return all(index in agenda.producers[producer].support
                    for (index,(_,producer)) in zip(live,witness.steps))
            end
            scope = :hypothesis
            if isnothing(match)
                cursor.max_lookback == 0 || continue
                outcome = witnessed_policy_availability(cursor,agenda,training,matches,action)
                isnothing(outcome) && continue
                comparison = nothing
            else
                witness = agenda.outcome_relations[match]
                outcome, comparison = agenda.samples[[witness.outcome,witness.comparison]]
                cursor.max_lookback == 0 || append!(comparisons,relation_ref.(agenda.samples[witness.comparisons]))
            end
        end
        reads = unique([cursor.policy.training;cursor.policy.available_after;cursor.observed;
            relation_refs(outcome);comparisons;isnothing(comparison) ? String[] : relation_refs(comparison)])
        obligation = (;definition=cursor.policy.definition,wait=false,sought=String[],shared=[],
            public_outcome=op["public_outcome"],scope,preparation,outcome=relation_ref(outcome),
            comparison=isnothing(comparison) ? nothing : relation_ref(comparison))
        isempty(comparisons) || (obligation=merge(obligation,(;comparisons)))
        return (;action,intent=:execute_relation_policy,tests=NamedTuple[],reads,obligation)
    end
    return nothing
end

function bound_policy_preparations(instruction,cursor,agenda,groups)
    reads = NamedTuple[]
    for (back,port,_,_) in get(instruction,:preparations,[])
        0 < back <= length(cursor.output_history) && back <= length(cursor.observed) || return nothing
        outputs = cursor.output_history[end-back+1]
        checkbounds(Bool,outputs,port) || return nothing
        support = outputs[port]
        support isa MotionShape && support in groups || return nothing
        # A role that disappeared and later reappeared has a different origin.
        fact = get(agenda.uses.roles,support,nothing)
        writer = cursor.observed[end-back+1]
        !isnothing(fact) && fact.output_port == port &&
            relation_ref(agenda.samples[fact.writer]) == writer || return nothing
        push!(reads,(;writer,port,usage="omission_contrast",support=semantic_hash(support)))
    end
    return reads
end

function bind_relation_instruction(cursor,instruction,obs,decision,agenda;meters=())
    isempty(get(instruction,:preparations,())) && return bind_policy_task(cursor,instruction,obs,decision,agenda;meters)
    roles = bound_policy_preparations(instruction,cursor,agenda,decision.groups)
    isnothing(roles) && return nothing
    proposal = bind_policy_task(cursor,instruction,obs,decision,agenda;meters)
    isnothing(proposal) && return nothing
    return merge(proposal,(obligation=merge(proposal.obligation,(role_reads=roles,)),))
end

# On a novel binding, corroborated preparation rules can be tested before a
# policy reaches its target. Every prediction stays unverified until its receipt.
function policy_preparer_trials(cursor,agenda)
    position = length(cursor.observed)+1
    width = cursor.max_lookback
    0 < position <= width || return ()
    support = Dict{String,Vector{Int}}()
    training = Set(cursor.policy.training)
    function record(reader,facts)
        length(facts)==width || return
        relation_ref(agenda.samples[reader]) in training || return
        fact = facts[position]
        fact.writer_event in training && relation_ref(agenda.samples[fact.comparison]) in training || return
        push!(get!(Vector{Int},support,fact.producer),reader)
    end
    for witness in agenda.outcome_relations
        length(witness.steps)==width && length(witness.comparisons)==width || continue
        facts = sort!([f for f in relation_inputs(agenda,witness.outcome)
            if f.usage==:omission_contrast && f.comparison in witness.comparisons &&
                (f.writer=>f.producer) in witness.steps];by=f->f.writer)
        record(witness.outcome,facts)
    end
    for source in get(cursor.policy.body,"preparation_trials",[])
        reader = policy_atom_field(source,:reader)
        checkbounds(Bool,agenda.samples,reader) || continue
        facts = policy_preparation_inputs(agenda,reader,())
        [(f.writer,f.comparison) for f in facts] == Tuple.(policy_atom_field(source,:inputs)) || continue
        record(reader,facts)
    end
    return [model for (model,readers) in support if length(unique(readers)) >= 2]
end

function bind_policy_task(cursor,instruction,obs,decision,agenda;meters=())
    op = instruction.node["layout"]
    slots = get(instruction,:preparations,[])
    function required(action)
        isempty(slots) && isempty(get(instruction,:required_outputs,())) && return true
        required_policy_outputs(instruction,cursor.outputs,decision.groups,action) || return false
        return all(slots) do (back,port,selected,_)
            !selected || action["id"]==6 && point_component(decision.groups,action_key(action)[2:3]) ==
                cursor.output_history[end-back+1][port]
        end
    end
    if haskey(op,"public_outcome") || haskey(op,"public_available")
        options = filter(row->required(row.action),decision.ranked)
        isempty(options) && return nothing
        current = merge(decision,(ranked=options,))
        return haskey(op,"public_outcome") ? bind_policy_outcome(cursor,op,obs,current,agenda) :
            bind_policy_availability(cursor,op,obs,current,agenda)
    end
    # A paired omission can justify a local experiment at the compact
    # observation. Keep the original unverified scope on the dispatched test.
    purpose = cursor.purpose
    test_precondition = !isnothing(purpose) && purpose.kind==:test_policy_precondition &&
        purpose.action==op["id"] && (!isempty(get(instruction,:preparations,[])) ||
            any(p->first(p)==purpose.output_port && last(p)=="omission_contrast",get(instruction,:required_outputs,[])))
    preparers = policy_preparer_trials(cursor,agenda)
    options = policy_task_options(agenda,instruction,obs,decision;meters,test_precondition,preparers)
    filter!(options) do option
        required(option.action) && all(slots) do (back,port,_,shared)
            all(option.tests) do test
                all(j->j<=length(test.fragments) && test.fragments[j].basis==cursor.output_history[end-back+1][port],shared)
            end
        end
    end
    if test_precondition
        if hasproperty(purpose,:reader)
            inputs = policy_preparation_inputs(agenda,purpose.reader,())
            [relation_ref(agenda.samples[f.comparison]) for f in inputs] == purpose.comparisons || return nothing
        end
        filter!(row->(:policy_precondition,purpose.trial,action_key(row.action)) ∉ agenda.checked_effects,options)
    end
    sharing = instruction.shared
    if !isempty(sharing)
        filter!(options) do option
            !isempty(option.tests) && all(test->all(sharing) do (i,j)
                i <= length(cursor.outputs) && j <= length(test.fragments) &&
                    cursor.outputs[i] == test.fragments[j].basis
            end,option.tests)
        end
    end
    isempty(options) && return nothing
    context = relation_context(obs)
    option = argmin(options) do row
        bound = any(test->test.scope == :bound,row.tests)
        witnesses = length(get(agenda.visits,(context,action_key(row.action)),Int[]))
        (!bound,-witnesses,action_key(row.action))
    end
    source = unique([cursor.policy.training;cursor.policy.available_after;cursor.observed])
    return (action=option.action,intent=:execute_relation_policy,tests=option.tests,reads=source,
        obligation=(definition=cursor.policy.definition,wait=instruction.node["layout"]["wait"],
            sought=instruction.node["layout"]["relations"],shared=sharing))
end

function policy_outcome_steps(node)
    kind = node["kind"]
    if kind == "RelationTask"
        return get(node["layout"],"public_outcome",nothing) == "advancement" ? [node["layout"]] : []
    elseif kind == "RelationBranch"
        return reduce(vcat,policy_outcome_steps.(node["children"][2:end]);init=[])
    elseif kind == "RelationTest"
        return []
    end
    return policy_outcome_steps(last(node["children"]))
end

function policy_advancement_purpose(candidate,ends,agenda,obs,decision)
    training = Set(candidate.cursor.policy.training)
    available = Set(obs.available_actions)
    for witness in Iterators.reverse(agenda.outcome_relations)
        outcome = agenda.samples[witness.outcome]
        relation_ref(outcome) in training || continue
        id = outcome.effects.action["id"]
        role = isnothing(outcome.binding) ? nothing : outcome.binding.appearance
        any(op->op["id"] == id && op["role"] == role,ends) || continue
        width = candidate.cursor.max_lookback
        width == 0 || length(witness.steps) == width && length(witness.comparisons) == width || continue
        at,producer = first(witness.steps)
        Set(agenda.samples[at].available) == available || continue
        matched = findfirst(test->test.key == producer,candidate.proposal.tests)
        isnothing(matched) && continue
        sources = [agenda.samples[index] for (index,_) in witness.steps]
        all(row->relation_ref(row) in training,sources) || continue
        target = rebound_outcome_action(outcome,decision)
        isnothing(target) && continue
        comparison = agenda.samples[witness.comparison]
        purpose = (;kind=:establish_public_outcome,scope=:hypothesis,target,producer,
            sought=candidate.proposal.tests[matched].relations,
            outcome=relation_ref(outcome),comparison=relation_ref(comparison))
        comparisons = width == 0 ? [witness.comparison] : witness.comparisons
        reads = unique([relation_refs(outcome);reduce(vcat,relation_refs.(agenda.samples[comparisons]));
            reduce(vcat,relation_refs.(sources))])
        if width > 0
            purpose = merge(purpose,(comparisons=relation_ref.(agenda.samples[comparisons]),))
        end
        return (;purpose,reads)
    end
    return nothing
end

function policy_comparison_purpose(proposal,relation,agenda,obs,context)
    if !isnothing(relation) && proposal.action == relation.action && relation.intent in
            (:establish_preparation,:test_delayed_effect,:test_history_response,:distinguish_changed_context,
                :test_concrete_effect)
        same_effect = if isempty(relation.tests)
            proposal.obligation.wait
        else
            all(wanted->any(test->test.key == wanted.key && test.expected == wanted.expected,proposal.tests),
                relation.tests)
        end
        if same_effect
            purpose = (;kind=:distinguish_relation,comparison=relation.intent,relation=relation.obligation)
            return (;purpose,reads=relation.reads)
        end
    end
    history = relation_history_key(agenda,context,agenda.previous)
    action = action_key(proposal.action)
    pending = filter(proposal.tests) do test
        test.scope == :replicated &&
            effect_experiment_scope(obs.levels_completed,action,history,test) ∉ agenda.checked_effects
    end
    isempty(pending) && return nothing
    # The known effect has yet to be checked at this role and history.
    purpose = (;kind=:distinguish_relation,comparison=:effect_at_bound_condition,
        producers=[test.key for test in pending],history)
    return (;purpose,reads=String[])
end

function policy_entry_actions(node)
    kind,children = node["kind"],node["children"]
    if kind == "RelationTask"
        return [node["layout"]["id"]]
    elseif kind == "RelationSequence"
        return policy_entry_actions(first(children))
    elseif kind == "RelationBranch"
        return union(policy_entry_actions(children[2]),policy_entry_actions(children[3]))
    elseif kind == "RelationRepeat"
        return policy_entry_actions(last(children))
    end
    return Int[]
end

function policy_action_precondition(candidate,agenda,obs)
    cursor = candidate.cursor
    isempty(cursor.pending) && return nothing
    needed = setdiff(policy_entry_actions(last(cursor.pending).node),obs.available_actions)
    isempty(needed) && return nothing
    training = Set(cursor.policy.training)
    available = Set(obs.available_actions)
    context = candidate.context
    history = relation_history_key(agenda,context,agenda.previous)
    contradicted = Set{Int}()
    for index in get(agenda.visits,(context,action_key(candidate.proposal.action)),Int[])
        row = agenda.samples[index]
        row.state == "NOT_FINISHED" && !row.advanced || continue
        relation_history_key(agenda,context,row.preceding) == history || continue
        delta = get(row.effects.public_delta,"available_actions",nothing)
        exposed = isnothing(delta) ? row.available : delta["after"]
        union!(contradicted,(action for action in needed if action ∉ exposed))
    end
    obligation = candidate.proposal.obligation
    supports = if hasproperty(obligation,:public_available)
        [(obligation.source_index,nothing)]
    else
        [(index,test.key) for test in candidate.proposal.tests
            for index in Iterators.reverse(agenda.producers[test.key].support)]
    end
    for (index,producer) in supports
        index < length(agenda.samples) || continue
        source,following = agenda.samples[index],agenda.samples[index+1]
        following.preceding == index && !source.advanced || continue
        relation_ref(source) in training && relation_ref(following) in training || continue
        Set(source.available) == available || continue
        action = following.effects.action["id"]
        action in needed && action ∉ contradicted || continue
        action in observed_action_gain(source) || continue
        purpose = (;kind=:enable_policy_action,action,source=relation_ref(source),
            consumer=relation_ref(following),producer)
        return (;purpose,reads=unique([relation_refs(source);relation_refs(following)]))
    end
    return nothing
end

function observed_policy_preconditions(episode,agenda)
    facts = NamedTuple[]
    for (writer,consumer) in zip(episode.members,episode.members[2:end])
        for input in relation_inputs(agenda,consumer)
            input.writer == writer && input.usage == :omission_contrast || continue
            candidate = agenda.samples[consumer]
            candidate.state == "NOT_FINISHED" && !candidate.advanced || continue
            push!(facts,(;producer=input.producer,output_port=input.output_port,
                source=relation_ref(agenda.samples[writer]),consumer=relation_ref(candidate),
                comparison=relation_ref(agenda.samples[input.comparison]),action=candidate.effects.action["id"],
                reads=input.reads))
        end
    end
    return facts
end

function joint_effect_precondition(candidate,agenda,obs)
    policy = candidate.cursor.policy
    for source in get(policy.body,"preparation_trials",[])
        index = policy_atom_field(source,:reader)
        checkbounds(Bool,agenda.samples,index) || continue
        row = agenda.samples[index]
        event = policy_atom_field(source,:event)
        relation_ref(row) == event || continue
        current = policy_preparation_inputs(agenda,index,())
        [(f.writer,f.comparison) for f in current] == Tuple.(policy_atom_field(source,:inputs)) || continue
        initial = first(current)
        any(test->test.key==initial.producer,candidate.proposal.tests) || continue
        id = row.effects.action["id"]
        id in obs.available_actions || continue
        comparisons = [relation_ref(agenda.samples[f.comparison]) for f in current]
        trial = semantic_hash([policy.body["scope"],event,comparisons,candidate.context,
            relation_history_key(agenda,candidate.context,agenda.previous),action_key(candidate.proposal.action)])
        id != 6 && (:policy_precondition,trial,action_key(Dict("id"=>id))) in agenda.checked_effects && continue
        purpose = (;kind=:test_policy_precondition,scope=:hypothesis,trial,action=id,
            producer=initial.producer,output_port=initial.output_port,source=initial.writer_event,
            consumer=event,comparison=first(comparisons),comparisons,reader=index)
        return (;purpose,reads=unique([event;[ref for f in current for ref in f.reads]]))
    end
    return nothing
end

function policy_effect_precondition(candidate,agenda,obs)
    cursor = candidate.cursor
    cursor.max_lookback > 0 && return joint_effect_precondition(candidate,agenda,obs)
    isempty(cursor.pending) && return nothing
    next = last(cursor.pending)
    ports = [port for (port,kind) in get(next,:required_outputs,[]) if kind == "omission_contrast"]
    isempty(ports) && return nothing
    actions = policy_entry_actions(next.node)
    for evidence in get(cursor.policy.body,"effect_preconditions",[])
        field(key) = policy_atom_field(evidence,key)
        any(result->result.event==field(:consumer),agenda.outcomes) && continue
        action,port,producer = field(:action),field(:output_port),field(:producer)
        action in actions && action in obs.available_actions || continue
        port in ports && any(test->test.key == producer,candidate.proposal.tests) || continue
        conditions = [model.version for test in candidate.proposal.tests for model in get(test,:conditions,())]
        trial = semantic_hash([cursor.policy.body["scope"],producer,port,candidate.context,
            relation_history_key(agenda,candidate.context,agenda.previous),action_key(candidate.proposal.action),
            action,sort!(unique!(conditions))])
        # A primitive has one binding. A click can still choose a different target.
        if action != 6 && (:policy_precondition,trial,action_key(Dict("id"=>action))) in agenda.checked_effects
            continue
        end
        purpose = (;kind=:test_policy_precondition,scope=:hypothesis,trial,action,producer,
            source=field(:source),consumer=field(:consumer),comparison=field(:comparison),output_port=port)
        return (;purpose,reads=unique([field(:reads);purpose.comparison;purpose.consumer]))
    end
    return nothing
end

function assign_policy_purpose(candidate,purpose,reads=get(purpose,:reads,String[]))
    purpose = merge(purpose,(;reads))
    candidate.cursor.purpose = purpose
    task = candidate.proposal
    proposal = merge(task,(;obligation=merge(task.obligation,(;purpose)),reads=unique([task.reads;reads])))
    return merge(candidate,(;proposal))
end

function relation_policy_choice(policies,cursor,attempted,agenda,obs,decision;meters=(),relation=nothing)
    context = relation_context(obs)
    function ready(candidate)
        next = peek_relation_instruction(candidate,obs)
        next.status == :task || return nothing
        proposal = bind_relation_instruction(next.cursor,next.instruction,obs,decision,agenda;meters)
        isnothing(proposal) && return nothing
        required = get(next.instruction,:required_outputs,[])
        if !isempty(required)
            isempty(next.cursor.observed) && return nothing
            writer = last(next.cursor.observed)
            role_reads = [get(proposal.obligation,:role_reads,NamedTuple[]);
                [(;writer,port,usage,support=semantic_hash(next.cursor.outputs[port])) for (port,usage) in required]]
            proposal = merge(proposal,(;obligation=merge(proposal.obligation,(;role_reads))))
        end
        candidate = (;cursor=next.cursor,proposal,next.branches,context)
        return isnothing(next.cursor.purpose) ? candidate : assign_policy_purpose(candidate,next.cursor.purpose)
    end

    choices = [policy for policy in Iterators.reverse(policies) if haskey(policy.body,"tree") &&
        (policy.body["scope"],context) ∉ attempted]
    if !isnothing(cursor)
        current = ready(cursor)
        isnothing(current) && return nothing
        cursor.policy.body["structure"] == "sequence" || return current
        # A guarded branch can reuse the current dispatch when it preserves
        # the remaining sequence or extends it after its last task.
        for policy in choices
            policy.body["structure"] == "branch" || continue
            next = ready(RelationPolicyCursor(policy))
            isnothing(next) && continue
            a,b = current.proposal,next.proposal
            a.action == b.action && a.obligation.wait == b.obligation.wait &&
                a.obligation.sought == b.obligation.sought || continue
            a_effects = Set(semantic_hash(test.expected) for test in a.tests)
            b_effects = Set(semantic_hash(test.expected) for test in b.tests)
            a_effects == b_effects || continue
            (isempty(current.cursor.pending) || current.cursor.pending == next.cursor.pending) || continue
            next.cursor.max_lookback <= current.cursor.max_lookback || continue
            next.cursor.observed = copy(current.cursor.observed)
            next.cursor.outputs = copy(current.cursor.outputs)
            next.cursor.output_history = copy(current.cursor.output_history)
            next.cursor.loop_states = copy(current.cursor.loop_states)
            proposal = merge(b,(reads=unique([a.reads;b.reads]),))
            replacement = merge(next,(;proposal))
            return isnothing(cursor.purpose) ? replacement : assign_policy_purpose(replacement,cursor.purpose)
        end
        return current
    end
    sort!(choices;by=policy->(!haskey(policy.body,"preparation_trials"),policy.body["structure"] == "sequence"))
    preparation = nothing
    comparison = nothing
    for policy in choices
        ends = get(() -> policy_outcome_steps(policy.body["tree"]),policy.body,"public_outcomes")
        isempty(ends) && !isnothing(preparation) && continue
        next = ready(RelationPolicyCursor(policy))
        isnothing(next) && continue
        if !isempty(ends)
            goal = policy_advancement_purpose(next,ends,agenda,obs,decision)
            isnothing(goal) || return assign_policy_purpose(next,goal.purpose,goal.reads)
        end
        if isnothing(preparation)
            precondition = policy_action_precondition(next,agenda,obs)
            isnothing(precondition) && (precondition = policy_effect_precondition(next,agenda,obs))
            isnothing(precondition) || (preparation = assign_policy_purpose(next,precondition.purpose,precondition.reads))
        end
        if isnothing(preparation) && isnothing(comparison)
            trial = policy_comparison_purpose(next.proposal,relation,agenda,obs,context)
            isnothing(trial) || (comparison = assign_policy_purpose(next,trial.purpose,trial.reads))
        end
    end
    return isnothing(preparation) ? comparison : preparation
end

function observed_policy_port(effects,fragment)
    matches = [effect.after for effect in effects.effects if effect.family == fragment.family &&
        effect.before == fragment.basis]
    return length(matches) == 1 && !isempty(only(matches)) ? only(matches) : nothing
end

function confirm_relation_policy!(selection,agenda,feedback,after)
    cursor = selection.cursor
    row = last(agenda.samples)
    check_precondition = isempty(cursor.observed) && !isnothing(cursor.purpose) &&
        cursor.purpose.kind == :enable_policy_action
    push!(cursor.observed,relation_ref(row))
    task = selection.proposal
    success = if get(task.obligation,:public_outcome,nothing) == "advancement"
        row.advanced
    elseif task.obligation.wait
        row.unchanged
    else
        !isnothing(feedback.feedback) && feedback.feedback.result == :established
    end
    if check_precondition && !row.advanced
        success &= cursor.purpose.action in after.observation.available_actions
    end
    experiment_after = row.state == "NOT_FINISHED" && !row.advanced ? relation_ref(row) : nothing
    if !success || row.state == "GAME_OVER"
        if !isnothing(cursor.purpose) && cursor.purpose.kind==:test_policy_precondition &&
                haskey(task.obligation,:role_reads)
            push!(agenda.checked_effects,(:policy_precondition,cursor.purpose.trial,action_key(task.action)))
        end
        return (;cursor=nothing,result=:withdrawn,branches=NamedTuple[],experiment_after)
    end
    row.advanced && return (;cursor=nothing,result=:stopped_at_public_advance,branches=NamedTuple[],experiment_after)
    outputs = if isempty(task.tests)
        []
    else
        [observed_policy_port(row.effects,part) for part in first(task.tests).fragments]
    end
    save_policy_outputs!(cursor,outputs)
    # Peek through zero-action control nodes only after the receipt.
    next = next_relation_instruction!(cursor,after.observation)
    if next.status == :task
        push!(cursor.pending,next.instruction)
        return (;cursor,result=:continue,branches=next.branches,experiment_after=nothing)
    end
    return (;cursor=nothing,result=next.status,branches=next.branches,experiment_after)
end
